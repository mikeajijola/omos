//! Starts scheduled contracts through the native saved-session runtime.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const scheduling = @import("scheduling.zig");
const sessions = @import("../session/session_store.zig");
const io = @import("../shared/io.zig");
const interaction = @import("ui_session.zig");

pub const Executor = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, workspace.Manager, scheduling.Schedule, *std.atomic.Value(bool)) anyerror!void,
    available: ?*const fn (*anyopaque) bool = null,
};

pub const Scheduler = struct {
    manager: workspace.Manager,
    executor: Executor,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn loop(self: *Scheduler) void {
        const owner = ownerIdentity();
        while (!self.stopping.load(.acquire)) {
            self.tick(&owner) catch |err| {
                @import("../shared/debug_trace.zig").logf("workspace", "schedule worker failed error={s}", .{@errorName(err)});
            };
            std.Io.sleep(io.getIo(), .fromSeconds(1), .awake) catch {};
        }
    }

    pub fn tick(self: *Scheduler, owner: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var manager = self.manager;
        manager.alloc = arena.allocator();
        if (!try manager.hasDueSchedules() and !try manager.hasDueScheduleSeries()) return;
        if (self.executor.available) |available| if (!available(self.executor.context)) return;
        const lease = (try manager.tryExecutionLease()) orelse return;
        defer lease.release();
        _ = try manager.materializeScheduleSeries(&lease);
        const schedule = (try manager.claimSchedule(owner)) orelse return;
        var heartbeat: Heartbeat = .{ .manager = self.manager, .schedule = schedule, .host_stopping = &self.stopping };
        var monitor: ?std.Thread = try std.Thread.spawn(.{}, Heartbeat.loop, .{&heartbeat});
        defer heartbeat.stop(&monitor);
        const before = manager.loadTask(schedule.task) catch |err| {
            heartbeat.stop(&monitor);
            try manager.finishSchedule(schedule, .failed, @errorName(err));
            return;
        };
        if (before.state == .accepted and !try manager.publicationPending(before)) {
            heartbeat.stop(&monitor);
            try manager.finishSchedule(schedule, .completed, "The contract already has a verified publication.");
            return;
        }
        self.executor.run(self.executor.context, manager, schedule, &heartbeat.cancel) catch |err| {
            heartbeat.stop(&monitor);
            try manager.finishSchedule(schedule, failureState(err), @errorName(err));
            return;
        };
        const task = try manager.loadTask(schedule.task);
        heartbeat.stop(&monitor);
        const state: scheduling.State = if (task.state == .accepted and !try manager.publicationPending(task)) .completed else .waiting;
        try manager.finishSchedule(schedule, state, if (state == .completed) "Verified publication accepted." else if (task.state == .conflict) "Resolve the retained workspace conflict before continuing." else if (task.state == .publication_pending) "Verified publication is pending recovery." else "Work and evidence are retained. Continue the task to resolve its remaining requirements.");
    }
};

fn ownerIdentity() [64]u8 {
    var bytes: [32]u8 = undefined;
    io.getIo().random(&bytes);
    return std.fmt.bytesToHex(&bytes, .lower);
}

const Heartbeat = struct {
    manager: workspace.Manager,
    schedule: scheduling.Schedule,
    host_stopping: *const std.atomic.Value(bool),
    finished: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),

    fn stop(self: *Heartbeat, thread: *?std.Thread) void {
        if (thread.*) |running| {
            self.finished.store(true, .release);
            running.join();
            thread.* = null;
        }
    }

    fn loop(self: *Heartbeat) void {
        var renew_at = io.milliTimestamp() + 10_000;
        while (!self.finished.load(.acquire)) {
            if (self.host_stopping.load(.acquire)) {
                self.cancel.store(true, .release);
                return;
            }
            if (io.milliTimestamp() >= renew_at) {
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                var manager = self.manager;
                manager.alloc = arena.allocator();
                manager.renewSchedule(self.schedule) catch |err| {
                    @import("../shared/debug_trace.zig").logf("workspace", "schedule lease renewal failed error={s}", .{@errorName(err)});
                    self.cancel.store(true, .release);
                    return;
                };
                renew_at = io.milliTimestamp() + 10_000;
            }
            io.sleep(100 * std.time.ns_per_ms);
        }
    }
};

fn failureState(err: anyerror) scheduling.State {
    return switch (err) {
        error.Cancelled, error.ExecutionBusy, error.WorkspaceExecutionBusy, error.LocalSeriesAuthorityRequired, error.NativeSessionUnavailable, error.TaskProjectMismatch, error.WorkspaceMergeConflict, error.WorkspaceRecoveryRequired, error.WorkspaceBindingMismatch, error.StaleExecutionPolicy, error.UnboundCapability, error.ScheduledInputRequired, error.ScheduledContinuationRequired, error.ScheduledTurnAcceptanceUncertain, error.ModelRequestsBlocked, error.MissingCredentials, error.StaleWorkContract, error.StaleWorkspaceDefinition => .waiting,
        else => .failed,
    };
}

pub fn errorFromCode(code: ?[]const u8) anyerror {
    const value = code orelse return error.ScheduledRunFailed;
    for ([_][]const u8{ "contract_blocked", "verification_pending", "workspace_invocation_budget", "workspace_progress_paused", "workspace_governance_pending", "workspace_preparation_pending", "workspace_publication_pending", "step_limit" }) |pending| {
        if (std.mem.eql(u8, value, pending)) return error.ScheduledContinuationRequired;
    }
    inline for (.{ error.Cancelled, error.WorkspaceExecutionBusy, error.TaskProjectMismatch, error.WorkspaceMergeConflict, error.WorkspaceRecoveryRequired, error.WorkspaceBindingMismatch, error.StaleExecutionPolicy, error.UnboundCapability, error.ModelRequestsBlocked, error.MissingCredentials, error.StaleWorkContract, error.StaleWorkspaceDefinition }) |err| {
        if (std.mem.eql(u8, value, @errorName(err))) return err;
    }
    return error.ScheduledRunFailed;
}

pub const Invocation = struct {
    task: workspace.Task,
    session: []const u8,
    prompt: []const u8 = "continue",
};

/// Resolves the saved native session without putting private runtime state in Fossil.
/// The returned strings use manager.alloc and belong to the caller.
pub fn prepare(manager: workspace.Manager, schedule: scheduling.Schedule) !Invocation {
    const task = try manager.loadTask(schedule.task);
    try manager.validateTaskBasis(task);
    var store = try sessions.Store.initReadOnly(manager.alloc, task.project_root);
    defer store.deinit(manager.alloc);
    if (try manager.scheduledOccurrence(schedule.id)) |occurrence| {
        if (!std.mem.eql(u8, occurrence.task, task.id) or !std.mem.eql(u8, task.session, try workspace.hash(manager.alloc, occurrence.session))) return error.RecurringTaskBindingMismatch;
        var native = store.loadReadOnly(manager.alloc, occurrence.session) catch |err| return if (err == error.SessionNotFound or err == error.FileNotFound) error.NativeSessionUnavailable else err;
        defer native.deinit(manager.alloc);
        const fresh = native.history.len == 0 and native.recovery_checkpoint == null;
        _ = try manager.resumeTask(occurrence.session, task.id, task.project_root);
        return .{ .task = task, .session = try manager.alloc.dupe(u8, occurrence.session), .prompt = if (fresh) try manager.originalRequest(task) else "continue" };
    }
    var candidates = try store.list(manager.alloc);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(manager.alloc);
        candidates.deinit(manager.alloc);
    }
    for (candidates.items) |candidate| {
        const digest = try workspace.hash(manager.alloc, candidate.id);
        defer manager.alloc.free(digest);
        if (!std.mem.eql(u8, digest, task.session)) continue;
        const id = try manager.alloc.dupe(u8, candidate.id);
        _ = try manager.resumeTask(id, task.id, task.project_root);
        return .{ .task = task, .session = id };
    }
    return error.NativeSessionUnavailable;
}

/// Arguments retain the saved session and let the normal runtime recover publication.
/// The caller owns the arguments and strings through alloc.
pub fn promptArgs(alloc: std.mem.Allocator, session: []const u8, prompt: []const u8) ![]const [:0]const u8 {
    const args = try alloc.alloc([:0]const u8, 6);
    const values = [_][]const u8{ "--json", "--prompt-permissions", "--resume-id", session, "--", prompt };
    var count: usize = 0;
    errdefer {
        for (args[0..count]) |arg| alloc.free(arg);
        alloc.free(args);
    }
    for (values, 0..) |arg, index| {
        args[index] = try alloc.dupeSentinel(u8, arg, 0);
        count += 1;
    }
    return args;
}

pub const Cancellation = struct {
    ui: *interaction.Host,
    source: *const std.atomic.Value(bool),
    finished: std.atomic.Value(bool) = .init(false),

    pub fn loop(self: *Cancellation) void {
        while (!self.finished.load(.acquire)) {
            if (self.source.load(.acquire) or self.ui.cancel.load(.acquire)) {
                self.ui.stop();
                return;
            }
            io.sleep(20 * std.time.ns_per_ms);
        }
    }
};

/// A service without an input transport retains work whenever user input is needed.
pub const Headless = struct {
    alloc: std.mem.Allocator,
    ui: interaction.Host = undefined,
    blocked: std.atomic.Value(bool) = .init(false),
    error_code: ?[]const u8 = null,

    pub fn init(self: *Headless, project: []const u8) void {
        self.ui = .{ .context = self, .emit_fn = emit, .project_root = project, .execution_lease_held = true };
    }

    fn emit(raw: *anyopaque, bytes: []const u8) !void {
        const self: *Headless = @ptrCast(@alignCast(raw));
        const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, bytes, .{});
        defer parsed.deinit();
        const model = @import("definition.zig");
        const kind = model.text(parsed.value, "type");
        if (std.mem.eql(u8, kind, "input_required") or std.mem.eql(u8, kind, "validate_ui")) {
            self.blocked.store(true, .release);
            // Question emission may hold the host mutex. The cancellation monitor
            // calls stop after that emission releases it.
            self.ui.cancel.store(true, .release);
        }
        if (std.mem.eql(u8, kind, "result")) {
            const data = model.field(parsed.value, "data") orelse return;
            const code = model.text(data, "error");
            if (code.len > 0) self.error_code = try self.alloc.dupe(u8, code);
        }
    }
};

test "scheduled execution holds input and ambiguous continuation failures" {
    try std.testing.expectEqual(scheduling.State.waiting, failureState(error.NativeSessionUnavailable));
    try std.testing.expectEqual(scheduling.State.waiting, failureState(error.ScheduledInputRequired));
    try std.testing.expectEqual(scheduling.State.failed, failureState(error.InvalidSessionFormat));
    try std.testing.expectEqual(scheduling.State.waiting, failureState(errorFromCode("contract_blocked")));
    try std.testing.expectEqual(scheduling.State.waiting, failureState(errorFromCode("workspace_governance_pending")));
    try std.testing.expectEqual(scheduling.State.waiting, failureState(errorFromCode("workspace_preparation_pending")));
}

test "schedule workers generate an owner accepted by the durable claim fence" {
    const owner = ownerIdentity();
    try std.testing.expect(scheduling.validOwner(&owner));
    try std.testing.expect(!scheduling.validOwner(owner[0..32]));
}

test "headless scheduled permission prompts preserve the unresolved approval" {
    var host: Headless = .{ .alloc = std.testing.allocator };
    host.init("/Users/example/project");
    defer host.ui.deinit();
    try std.testing.expect(!try host.ui.approve("Write the requested report"));
    try std.testing.expect(host.blocked.load(.acquire));
    try std.testing.expect(host.ui.cancel.load(.acquire));
}
