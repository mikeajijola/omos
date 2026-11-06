//! Instance-owned workers. No actor borrows a foreground turn or its allocator.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const domain = @import("background_contract.zig");
const dispatch = @import("background_dispatch.zig");
const control = @import("background_control.zig");
const records = @import("../shared/record_json.zig");
const execution = @import("contract_execution.zig");

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
                // Record the failure before considering bounded recovery on a
                // later tick. Recovery resumes evidence, never a raw tool call.
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
                self.advance(manager, entry, owner) catch |err| {
                    // A single stale or unavailable contract must not stop the
                    // queue or cancel other workers. CAS preserves newer state.
                    if (err == error.WorkspaceBusy or err == error.WorkspaceExecutionBusy or err == error.StaleBackgroundRecord) continue;
                    const current = (manager.backgroundRecord(entry.task) catch continue) orelse continue;
                    if (current.generation != entry.generation or current.state == .completed or current.state == .cancelled or current.state == .superseded) continue;
                    var failed = current;
                    failed.state = .waiting;
                    failed.reason = @errorName(err);
                    failed.updated_ms = io.milliTimestamp();
                    failed.retry = domain.retryFor(@errorName(err), current.recoveries, failed.updated_ms);
                    failed.wait_condition = null;
                    manager.saveBackgroundRecord(failed, dispatch.digest(manager, current) catch continue) catch {};
                };
            }
            if (page.len < 32) break;
        }
    }

    fn advance(self: *Worker, manager: workspace.Manager, entry: domain.Record, owner: []const u8) !void {
        if (entry.state == .prepared or entry.state == .completed or entry.state == .superseded) return;
        // Portable records cannot grant execution authority on another host.
        const authority = (try control.activation(manager, entry)) orelse return;
        const lease = (try manager.tryTaskExecutionLease(entry.task)) orelse return;
        var leased = true;
        defer if (leased) lease.release();
        const task = try manager.loadTask(entry.task);
        const decision = try execution.inspect(manager, task, entry);
        if (decision.next == .reconcile) {
            const next = try domain.reconcilePublished(entry, @import("definition.zig").text(try manager.publicationSummary(task), "revision"), io.milliTimestamp());
            try manager.saveBackgroundRecord(next, try dispatch.digest(manager, entry));
            return;
        }
        if ((entry.state == .running or entry.state == .starting) and (decision.phase == .cancelled or decision.phase == .attention)) {
            const next = try domain.wait(entry, .{ .owner = entry.owner.?, .generation = entry.generation }, decision.reason, io.milliTimestamp());
            try manager.saveBackgroundRecord(next, try dispatch.digest(manager, entry));
            return;
        }
        if (decision.phase == .cancelled or decision.phase == .attention or decision.phase == .retry_wait) return;
        var free: ?usize = null;
        for (self.slots, 0..) |slot, index| if (slot == null) {
            free = index;
            break;
        };
        // Do not repeatedly validate queued work while every slot is occupied.
        // Publication and recovery still advance independently of actor slots.
        if (decision.next == .execute and free == null) return;
        try control.verifyLiveAuthority(manager, authority);
        try manager.validateTaskBasis(task);
        if (decision.next == .publish) {
            publish(manager, task, entry) catch |err| {
                // Persist the wake-up before yielding. Restarting the host
                // neither resets the attempt count nor loses the deadline.
                var next = entry;
                next.state = .waiting;
                next.wait_condition = null;
                next.reason = @errorName(err);
                next.updated_ms = io.milliTimestamp();
                next.retry = .{ .kind = .publication, .due_ms = next.updated_ms +| domain.retryDelay(entry.recoveries) };
                next.recoveries = std.math.add(u32, entry.recoveries, 1) catch return error.BackgroundRecoveryUnavailable;
                try manager.saveBackgroundRecord(next, try dispatch.digest(manager, entry));
                return;
            };
            return;
        }
        if (entry.state == .running or entry.state == .starting) {
            // No slot owns it and we acquired its task lease: the old process
            // is gone. A quiet event stream alone never triggers this recovery.
            var abandoned = try domain.wait(entry, .{ .owner = entry.owner.?, .generation = entry.generation }, "The previous worker stopped. Resume retained work and reconcile uncertain effects.", io.milliTimestamp());
            if (!abandoned.cancel_requested)
                abandoned.retry = .{ .kind = .interrupted, .due_ms = abandoned.updated_ms +| domain.retryDelay(entry.recoveries) };
            try manager.saveBackgroundRecord(abandoned, try dispatch.digest(manager, entry));
            return;
        }
        if (decision.next == .recover) {
            const recovered = try domain.recover(entry, decision.recovery_limit, io.milliTimestamp());
            try manager.saveBackgroundRecord(recovered, try dispatch.digest(manager, entry));
            return;
        }
        if (decision.next != .execute) return;
        const index = free orelse return;
        // The executor claims its own task lease and generation before running.
        lease.release();
        leased = false;
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

    fn publish(manager: workspace.Manager, task: workspace.Task, entry: domain.Record) !void {
        _ = (try manager.retryPublication(task)) orelse return error.WorkspaceRecoveryRequired;
        const published = try manager.loadTask(entry.task);
        if (published.state != .accepted) return error.WorkspacePublicationRequired;
        const next = try domain.reconcilePublished(entry, @import("definition.zig").text(try manager.publicationSummary(published), "revision"), io.milliTimestamp());
        // Clear pending delivery only after the retained receipt is verified.
        // A crash after acknowledgement is reconciled on the next queue scan.
        try manager.acknowledge(published);
        try manager.saveBackgroundRecord(next, try dispatch.digest(manager, entry));
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
