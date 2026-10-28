//! Host operations for handing an unchanged task contract to a worker.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const background = @import("background_contract.zig");
const io = @import("../shared/io.zig");

pub fn digest(manager: workspace.Manager, record: background.Record) ![]const u8 {
    return workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, record, .{}));
}

pub fn prepare(manager: workspace.Manager, task: workspace.Task, session: []const u8, call_id: []const u8) !background.Record {
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    if (task.parent_task_id != null) return error.BackgroundRootTaskRequired;
    if (task.state != .active or call_id.len == 0) return error.BackgroundActiveTaskRequired;
    try manager.validateTaskBasis(task);
    const contract_bytes = try std.json.Stringify.valueAlloc(manager.alloc, task.definition, .{});
    const contract_hash = try workspace.hash(manager.alloc, contract_bytes);
    const operation = try workspace.hash(manager.alloc, try manager.alloc.print("{s}:dispatch:{s}", .{ task.id, call_id }));
    const dispatcher = try workspace.hash(manager.alloc, session);
    const request_hash = try workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .task = task.id, .contract = contract_hash, .basis = task.model_basis, .dispatcher = dispatcher }, .{}));
    if (try manager.backgroundRecord(task.id)) |previous| {
        if (previous.state != .superseded) {
            if (!std.mem.eql(u8, previous.operation, operation) or !std.mem.eql(u8, previous.request_sha256, request_hash)) return error.BackgroundOperationConflict;
            return previous;
        }
    }
    const record: background.Record = .{
        .workspace = manager.manifest.id,
        .task = task.id,
        .operation = operation,
        .request_sha256 = request_hash,
        .dispatcher_session = dispatcher,
        .contract_version = task.definition.version,
        .contract_sha256 = contract_hash,
        .updated_ms = io.milliTimestamp(),
    };
    return record;
}

/// Called after the foreground has checkpointed all tool batches. It still
/// owns the task lease until finalization returns, so no worker can start early.
pub fn seal(manager: workspace.Manager, task: workspace.Task, session: []const u8) !background.Record {
    const previous = (try manager.backgroundRecord(task.id)) orelse return error.BackgroundDispatchRequired;
    if (!std.mem.eql(u8, previous.dispatcher_session, try workspace.hash(manager.alloc, session))) return error.BackgroundDispatcherChanged;
    const current = try manager.loadTask(task.id);
    const contract_hash = try workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, current.definition, .{}));
    if (current.definition.version != previous.contract_version or !std.mem.eql(u8, contract_hash, previous.contract_sha256)) return error.StaleWorkContract;
    const record = try background.seal(previous, try manager.revision(task.branch), io.milliTimestamp());
    try manager.saveBackgroundHandoff(record, try digest(manager, previous), session);
    return record;
}

pub fn reserve(manager: workspace.Manager, previous: background.Record, owner: []const u8) !?background.Record {
    const lease = (try manager.tryTaskExecutionLease(previous.task)) orelse return null;
    defer lease.release();
    try validateClaim(manager, previous);
    const next = try background.reserve(previous, owner, io.milliTimestamp());
    try manager.saveBackgroundRecord(next, try digest(manager, previous));
    return next;
}

fn validateClaim(manager: workspace.Manager, previous: background.Record) !void {
    const task = try manager.refreshTaskContext(try manager.loadTask(previous.task));
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    if (task.state == .accepted or task.state == .publication_pending or task.state == .conflict) return error.BackgroundTaskUnavailable;
    try manager.validateTaskBasis(task);
    if (task.definition.version < previous.contract_version or !try manager.revisionDescendsFrom(try manager.revision(task.branch), previous.source_revision orelse return error.BackgroundCheckpointRequired)) return error.StaleWorkContract;
}

pub fn bind(manager: workspace.Manager, previous: background.Record, owner: []const u8, session: []const u8) !background.Record {
    const lease = (try manager.tryTaskExecutionLease(previous.task)) orelse return error.WorkspaceExecutionBusy;
    defer lease.release();
    try validateClaim(manager, previous);
    const current = (try manager.backgroundRecord(previous.task)) orelse return error.BackgroundDispatchRequired;
    const next = try background.bind(current, .{ .owner = owner, .generation = previous.generation }, session, io.milliTimestamp());
    try manager.saveBackgroundRecord(next, try digest(manager, current));
    return next;
}

pub fn finish(manager: workspace.Manager, previous: background.Record, fence: background.Fence, reason: []const u8) !background.Record {
    const task = try manager.loadTask(previous.task);
    const current = (try manager.backgroundRecord(previous.task)) orelse return error.BackgroundDispatchRequired;
    if (!background.owns(current, fence)) return error.StaleBackgroundOwner;
    const next = if (task.state == .accepted and !try manager.publicationPending(task))
        try background.complete(current, fence, @import("definition.zig").text(try manager.publicationSummary(task), "revision"), io.milliTimestamp())
    else
        try background.wait(current, fence, reason, io.milliTimestamp());
    try manager.saveBackgroundRecord(next, try digest(manager, current));
    return next;
}
