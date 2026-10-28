//! Durable execution handoff. A dispatch receipt never satisfies the task contract.
const std = @import("std");

pub const State = enum { prepared, queued, starting, running, waiting, cancelled, completed, superseded };

pub const Record = struct {
    version: []const u8 = "omos.background-contract/v1",
    workspace: []const u8,
    task: []const u8,
    operation: []const u8,
    request_sha256: []const u8,
    dispatcher_session: []const u8,
    contract_version: u32,
    contract_sha256: []const u8,
    state: State = .prepared,
    source_revision: ?[]const u8 = null,
    worker_session: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    generation: u64 = 0,
    invocations: u32 = 0,
    cancel_requested: bool = false,
    publication_revision: ?[]const u8 = null,
    updated_ms: i64,
    reason: []const u8 = "",
};

pub const Operation = struct {
    version: []const u8 = "omos.background-operation/v1",
    workspace: []const u8,
    task: []const u8,
    operation: []const u8,
    request_sha256: []const u8,
    generation: u64,
    state: State,
};

pub fn validateOperation(operation: Operation) !void {
    if (!std.mem.eql(u8, operation.version, "omos.background-operation/v1") or !hex(operation.workspace, 64) or !hex(operation.task, 64) or !hex(operation.operation, 64) or !hex(operation.request_sha256, 64)) return error.InvalidBackgroundOperation;
}

pub const Fence = struct { owner: []const u8, generation: u64 };

fn hex(value: []const u8, length: usize) bool {
    if (value.len != length) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn revision(value: []const u8) bool {
    return hex(value, 40) or hex(value, 64);
}

pub fn validate(record: Record) !void {
    if (!std.mem.eql(u8, record.version, "omos.background-contract/v1") or
        !hex(record.workspace, 64) or !hex(record.task, 64) or
        !hex(record.operation, 64) or !hex(record.request_sha256, 64) or
        !hex(record.dispatcher_session, 64) or !hex(record.contract_sha256, 64) or
        record.contract_version == 0 or record.updated_ms < 0 or
        record.reason.len > 2048 or !std.unicode.utf8ValidateSlice(record.reason)) return error.InvalidBackgroundContract;
    if (record.source_revision) |source| {
        if (!revision(source)) return error.InvalidBackgroundContract;
    } else if (record.state != .prepared and record.state != .superseded) return error.BackgroundCheckpointRequired;
    if (record.worker_session) |session| {
        if (session.len == 0 or session.len > 128) return error.InvalidBackgroundContract;
        for (session) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidBackgroundContract;
    }
    if (record.owner) |owner| {
        if (!hex(owner, 64) or record.generation == 0) return error.InvalidBackgroundContract;
    } else if (record.state == .running or record.state == .starting) return error.BackgroundOwnerRequired;
    if (record.state == .running and (record.worker_session == null or record.invocations == 0)) return error.BackgroundSessionRequired;
    if (record.publication_revision) |published| {
        if (!revision(published) or record.state != .completed) return error.InvalidBackgroundPublication;
    } else if (record.state == .completed) return error.BackgroundPublicationRequired;
}

pub fn owns(record: Record, fence: Fence) bool {
    return (record.state == .running or record.state == .starting) and record.generation == fence.generation and
        record.owner != null and std.mem.eql(u8, record.owner.?, fence.owner);
}

/// The caller seals the completed foreground checkpoint before releasing its
/// task lease. Workers must obtain that same task lease before claiming it.
pub fn seal(previous: Record, source: []const u8, now: i64) !Record {
    try validate(previous);
    if (previous.state != .prepared or !revision(source)) return error.InvalidBackgroundTransition;
    var next = previous;
    next.state = .queued;
    next.source_revision = source;
    next.updated_ms = now;
    try validate(next);
    return next;
}

pub fn reserve(previous: Record, owner: []const u8, now: i64) !Record {
    try validate(previous);
    if (previous.state != .queued or previous.cancel_requested) return error.BackgroundNotQueued;
    var next = previous;
    next.state = .starting;
    next.owner = owner;
    next.generation = std.math.add(u64, previous.generation, 1) catch return error.BackgroundGenerationExhausted;
    next.invocations = std.math.add(u32, previous.invocations, 1) catch return error.BackgroundInvocationExhausted;
    next.updated_ms = now;
    next.reason = "";
    try validate(next);
    return next;
}

pub fn bind(previous: Record, fence: Fence, session: []const u8, now: i64) !Record {
    try validate(previous);
    if (previous.state != .starting or !owns(previous, fence)) return error.StaleBackgroundOwner;
    if (previous.cancel_requested) return error.Cancelled;
    var next = previous;
    next.state = .running;
    next.worker_session = session;
    next.updated_ms = now;
    try validate(next);
    return next;
}

pub fn claim(previous: Record, owner: []const u8, session: []const u8, now: i64) !Record {
    const starting = try reserve(previous, owner, now);
    return bind(starting, .{ .owner = owner, .generation = starting.generation }, session, now);
}

pub fn wait(previous: Record, fence: Fence, reason: []const u8, now: i64) !Record {
    try validate(previous);
    if (!owns(previous, fence)) return error.StaleBackgroundOwner;
    var next = previous;
    next.state = if (previous.cancel_requested) .cancelled else .waiting;
    next.updated_ms = now;
    next.reason = reason;
    try validate(next);
    return next;
}

/// Called only after the native manager has independently verified the task's
/// publication receipt. Neither a successful tool nor a dispatch is a receipt.
pub fn complete(previous: Record, fence: Fence, publication: []const u8, now: i64) !Record {
    try validate(previous);
    if (previous.state != .running) return error.BackgroundSessionRequired;
    if (!owns(previous, fence)) return error.StaleBackgroundOwner;
    if (!revision(publication)) return error.BackgroundPublicationRequired;
    var next = previous;
    next.state = .completed;
    next.publication_revision = publication;
    next.cancel_requested = false;
    next.updated_ms = now;
    next.reason = "Verified task publication accepted.";
    try validate(next);
    return next;
}

pub fn resumeRecord(previous: Record, now: i64) !Record {
    try validate(previous);
    if (previous.state != .waiting and previous.state != .cancelled) return error.InvalidBackgroundTransition;
    var next = previous;
    next.state = .queued;
    next.cancel_requested = false;
    next.owner = null;
    next.updated_ms = now;
    next.reason = "";
    try validate(next);
    return next;
}

pub fn didNotStart(previous: Record, reason: []const u8, now: i64) !Record {
    try validate(previous);
    if (previous.state != .queued) return error.InvalidBackgroundTransition;
    var next = previous;
    next.state = .waiting;
    next.reason = reason;
    next.updated_ms = now;
    try validate(next);
    return next;
}

test "background work cannot run before its foreground checkpoint or claim completion without publication" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const prepared: Record = .{ .workspace = hash, .task = hash, .operation = hash, .request_sha256 = hash, .dispatcher_session = hash, .contract_version = 3, .contract_sha256 = hash, .updated_ms = 1 };
    try std.testing.expectError(error.BackgroundNotQueued, claim(prepared, hash, "worker-session", 2));
    const queued = try seal(prepared, hash, 2);
    try std.testing.expect(queued.state == .queued);
    const running = try claim(queued, hash, "worker-session", 3);
    try std.testing.expectEqual(@as(u32, 3), running.contract_version);
    try std.testing.expectError(error.BackgroundNotQueued, claim(running, hash, "other-session", 4));
    const fence: Fence = .{ .owner = hash, .generation = 1 };
    try std.testing.expectError(error.BackgroundPublicationRequired, complete(running, fence, "tool succeeded", 4));
    const accepted = try complete(running, fence, hash, 4);
    try std.testing.expect(accepted.state == .completed);
    try std.testing.expectError(error.InvalidBackgroundTransition, resumeRecord(accepted, 5));
}

test "background resumption fences old runtimes and retains contract and invocation history" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const prepared: Record = .{ .workspace = hash, .task = hash, .operation = hash, .request_sha256 = hash, .dispatcher_session = hash, .contract_version = 2, .contract_sha256 = hash, .updated_ms = 1 };
    const first = try claim(try seal(prepared, hash, 2), hash, "worker-session", 3);
    const old: Fence = .{ .owner = hash, .generation = 1 };
    const paused = try wait(first, old, "External effect requires reconciliation.", 4);
    const resumed = try claim(try resumeRecord(paused, 5), hash, "worker-session", 6);
    try std.testing.expectEqual(@as(u64, 2), resumed.generation);
    try std.testing.expectEqual(@as(u32, 2), resumed.invocations);
    try std.testing.expectEqualStrings(first.contract_sha256, resumed.contract_sha256);
    try std.testing.expectEqualStrings(first.worker_session.?, resumed.worker_session.?);
    try std.testing.expectError(error.StaleBackgroundOwner, complete(resumed, old, hash, 7));
    try std.testing.expectError(error.StaleBackgroundOwner, wait(resumed, old, "late old result", 7));
}

/// A crash may follow verified task publication but precede delivery of its
/// worker outcome. Reconcile the receipt without another actor invocation.
pub fn reconcilePublished(previous: Record, publication: []const u8, now: i64) !Record {
    try validate(previous);
    if (previous.state == .prepared or previous.state == .superseded or !revision(publication)) return error.InvalidBackgroundTransition;
    if (previous.state == .completed and !std.mem.eql(u8, previous.publication_revision.?, publication)) return error.InvalidBackgroundPublication;
    var next = previous;
    next.state = .completed;
    next.publication_revision = publication;
    next.cancel_requested = false;
    next.updated_ms = now;
    next.reason = "Verified publication reconciled without repeating execution.";
    try validate(next);
    return next;
}

test "background recovery reconciles an existing publication without another invocation" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const prepared: Record = .{ .workspace = hash, .task = hash, .operation = hash, .request_sha256 = hash, .dispatcher_session = hash, .contract_version = 1, .contract_sha256 = hash, .updated_ms = 1 };
    const running = try claim(try seal(prepared, hash, 2), hash, "worker-session", 3);
    const paused = try wait(running, .{ .owner = hash, .generation = 1 }, "Publication outcome was not delivered.", 4);
    const reconciled = try reconcilePublished(paused, hash, 5);
    try std.testing.expect(reconciled.state == .completed);
    try std.testing.expectEqual(paused.invocations, reconciled.invocations);
    try std.testing.expectEqual(paused.generation, reconciled.generation);
    try std.testing.expectError(error.InvalidBackgroundTransition, reconcilePublished(paused, "success", 5));
}

test "background startup failures consume their invocation identity before another retry" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const prepared: Record = .{ .workspace = hash, .task = hash, .operation = hash, .request_sha256 = hash, .dispatcher_session = hash, .contract_version = 1, .contract_sha256 = hash, .updated_ms = 1 };
    const first = try reserve(try seal(prepared, hash, 2), hash, 3);
    try std.testing.expect(first.worker_session == null);
    const failed = try wait(first, .{ .owner = hash, .generation = 1 }, "Provider preparation failed before opening a session.", 4);
    const second = try reserve(try resumeRecord(failed, 5), hash, 6);
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(u32, 2), second.invocations);
    try std.testing.expectError(error.StaleBackgroundOwner, bind(second, .{ .owner = hash, .generation = 1 }, "old-session", 7));
    var cancelled = second;
    cancelled.cancel_requested = true;
    try std.testing.expectError(error.Cancelled, bind(cancelled, .{ .owner = hash, .generation = 2 }, "new-session", 7));
}
