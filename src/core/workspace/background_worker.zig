//! Instance-owned workers. No actor borrows a foreground turn or its allocator.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const domain = @import("background_contract.zig");
const dispatch = @import("background_dispatch.zig");
const control = @import("background_control.zig");
const records = @import("../shared/record_json.zig");

pub const Executor = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, workspace.Manager, domain.Record, control.Authority, []const u8, *std.atomic.Value(bool)) anyerror!void,
};

pub const Worker = struct {
    manager: workspace.Manager,
    executor: Executor,
    stopping: std.atomic.Value(bool) = .init(false),
    slots: [4]?*Slot = @splat(null),

    const Slot = struct {
        worker: *Worker,
        arena: std.heap.ArenaAllocator,
        entry: domain.Record,
        authority: control.Authority,
        thread: ?std.Thread = null,
        cancelled: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *Slot, owner: []const u8) void {
            defer self.finished.store(true, .release);
            var manager = self.worker.manager;
            manager.alloc = self.arena.allocator();
            self.worker.executor.run(self.worker.executor.context, manager, self.entry, self.authority, owner, &self.cancelled) catch |err| {
                // A startup failure or interruption requires explicit resumption.
                // Never loop through a partially accepted provider operation.
                if (manager.backgroundRecord(self.entry.task) catch null) |current| {
                    const next = if (domain.owns(current, .{ .owner = owner, .generation = self.entry.generation + 1 }))
                        domain.wait(current, .{ .owner = owner, .generation = self.entry.generation + 1 }, @errorName(err), io.milliTimestamp()) catch return
                    else if (current.state == .queued)
                        domain.didNotStart(current, @errorName(err), io.milliTimestamp()) catch return
                    else
                        return;
                    manager.saveBackgroundRecord(next, dispatch.digest(manager, current) catch return) catch {};
                }
            };
        }

        fn destroy(self: *Slot) void {
            if (self.thread) |thread| thread.join();
            self.arena.deinit();
            std.heap.c_allocator.destroy(self);
        }
    };

    pub fn deinit(self: *Worker) void {
        for (self.slots) |slot| if (slot) |active| active.cancelled.store(true, .release);
        for (&self.slots) |*slot| if (slot.*) |active| {
            active.destroy();
            slot.* = null;
        };
    }

    fn occupies(self: *Worker, task: []const u8) bool {
        for (self.slots) |slot| if (slot) |active| if (std.mem.eql(u8, task, active.entry.task)) return true;
        return false;
    }

    pub fn tick(self: *Worker, owner: []const u8) !void {
        for (&self.slots) |*slot| if (slot.*) |active| {
            if (active.finished.load(.acquire)) {
                active.destroy();
                slot.* = null;
            }
        };
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var manager = self.manager;
        manager.alloc = arena.allocator();
        var offset: usize = 0;
        while (true) : (offset += 32) {
            const page = try manager.backgroundRecords(offset);
            for (page) |entry| {
                if (self.occupies(entry.task)) continue;
                // Restored portable state requires explicit local activation.
                const authority = (try control.activation(manager, entry)) orelse continue;
                if (entry.state == .running or entry.state == .starting) {
                    const lease = (try manager.tryTaskExecutionLease(entry.task)) orelse continue;
                    defer lease.release();
                    var task = try manager.loadTask(entry.task);
                    if (task.state == .publication_pending or task.state == .accepted) {
                        if (try manager.publicationPending(task)) _ = try manager.retryPublication(task);
                        task = try manager.loadTask(entry.task);
                        if (task.state == .accepted and entry.state == .running) {
                            _ = try dispatch.finish(manager, entry, .{ .owner = entry.owner.?, .generation = entry.generation }, "Recovered verified publication.");
                            continue;
                        }
                    }
                    var abandoned = try domain.wait(entry, .{ .owner = entry.owner.?, .generation = entry.generation }, "The worker host stopped. Retained work requires recovery; uncertain effects were not replayed.", io.milliTimestamp());
                    const limit = if (task.model_basis) |basis| basis.execution.defaults.stalled_checks else 3;
                    if (entry.worker_session != null and task.state != .blocked and task.state != .conflict and task.state != .accepted and task.state != .publication_pending)
                        abandoned = domain.recover(abandoned, limit, io.milliTimestamp()) catch abandoned;
                    try manager.saveBackgroundRecord(abandoned, try dispatch.digest(manager, entry));
                    continue;
                }
                if (entry.state == .waiting and !entry.cancel_requested and io.milliTimestamp() - entry.updated_ms >= 5000 and
                    (std.mem.eql(u8, entry.reason, "verification_pending") or std.mem.eql(u8, entry.reason, "OutputTruncated") or std.mem.eql(u8, entry.reason, "ContractReviewPending") or std.mem.eql(u8, entry.reason, "Timeout") or std.mem.eql(u8, entry.reason, "IncompleteStream") or std.mem.eql(u8, entry.reason, "RequiredToolMissing")))
                {
                    const task = try manager.loadTask(entry.task);
                    const limit = if (task.model_basis) |basis| basis.execution.review.max_attempts else 1;
                    if (task.model_basis) |basis| if (basis.execution.review.max_tokens != null) continue;
                    if (task.state != .blocked and task.state != .conflict and try manager.retainedReviewCandidate(task) != null) {
                        const recovered = domain.recover(entry, limit, io.milliTimestamp()) catch continue;
                        try manager.saveBackgroundRecord(recovered, try dispatch.digest(manager, entry));
                    }
                    continue;
                }
                if (entry.state != .queued) continue;
                var free: ?usize = null;
                for (self.slots, 0..) |slot, index| if (slot == null) {
                    free = index;
                    break;
                };
                const index = free orelse return;
                // A queued handoff may still be releasing its foreground lease.
                const lease = (try manager.tryTaskExecutionLease(entry.task)) orelse continue;
                lease.release();
                const slot = try std.heap.c_allocator.create(Slot);
                errdefer std.heap.c_allocator.destroy(slot);
                slot.* = .{ .worker = self, .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator), .entry = undefined, .authority = undefined };
                errdefer slot.arena.deinit();
                const alloc = slot.arena.allocator();
                slot.entry = try records.decode(domain.Record, alloc, try std.json.Stringify.valueAlloc(alloc, entry, .{}), .{});
                slot.authority = try records.decode(control.Authority, alloc, try std.json.Stringify.valueAlloc(alloc, authority, .{}), .{});
                const owned_owner = try alloc.dupe(u8, owner);
                slot.thread = try std.Thread.spawn(.{}, Slot.run, .{ slot, owned_owner });
                self.slots[index] = slot;
            }
            if (page.len < 32) break;
        }
    }

    /// The caller holds the private instance host lock until all slots join.
    pub fn loop(self: *Worker) !void {
        var nonce: [32]u8 = undefined;
        io.getIo().random(&nonce);
        const owner = std.fmt.bytesToHex(nonce, .lower);
        const stop_path = try control.path(self.manager, "", "stop");
        while (!self.stopping.load(.acquire)) {
            if (std.Io.Dir.openFileAbsolute(io.getIo(), stop_path, .{ .follow_symlinks = false })) |file| {
                file.close(io.getIo());
                break;
            } else |err| if (err != error.FileNotFound) return err;
            {
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                _ = (try workspace.configured(arena.allocator())) orelse return error.WorkspaceBindingChanged;
            }
            self.tick(&owner) catch |err| switch (err) {
                // Foreground commits may outlast the bounded writer-lease wait.
                // Keep ownership of the host and retry the queue scan on the
                // normal cadence; claimed workers retain their own slots.
                error.WorkspaceBusy => {},
                else => return err,
            };
            // Canonical scans are bounded by a host cadence, never tied to
            // animation frames or individual model tokens.
            io.sleep(std.time.ns_per_s);
        }
    }
};
