//! Trusted CLI/UI controls. Models can inspect workers but cannot answer their
//! own permission prompts or manufacture completion receipts.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const domain = @import("background_contract.zig");
const control = @import("background_control.zig");
const dispatch = @import("background_dispatch.zig");

pub const Request = struct {
    action: enum { host, list, show, events, steer, cancel, @"resume", input, validation, receipt, stop } = .list,
    task: ?[]const u8 = null,
    generation: ?u64 = null,
    operation: ?[]const u8 = null,
    offset: usize = 0,
    text: []const u8 = "",
    request_id: usize = 0,
    approved: ?bool = null,
    answers: ?[]const []const u8 = null,
    receipt: ?std.json.Value = null,
};

fn value(manager: workspace.Manager, data: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, data, .{}), .{});
}

pub fn execute(manager: workspace.Manager, request: Request) !std.json.Value {
    if (request.action == .host) {
        var lock = try std.Io.Dir.createFileAbsolute(io.getIo(), try control.path(manager, "", "host.lock"), .{ .truncate = false, .permissions = .fromMode(0o600) });
        defer lock.close(io.getIo());
        const acquired = try lock.tryLock(io.getIo(), .exclusive);
        if (acquired) lock.unlock(io.getIo());
        return value(manager, .{ .running = !acquired });
    }
    if (request.action == .list) {
        const entries = try manager.backgroundRecords(request.offset);
        var workers: std.ArrayList(std.json.Value) = .empty;
        for (entries) |entry| {
            const authority = try control.activation(manager, entry);
            const execution = try @import("contract_execution.zig").inspect(manager, try manager.loadTask(entry.task), entry);
            try workers.append(manager.alloc, try value(manager, .{ .record = entry, .execution = execution, .session = if (authority) |local| @as(?[]const u8, local.source_session) else null, .locally_activated = authority != null }));
        }
        return value(manager, .{ .version = "omos.background-contracts/v1", .workers = workers.items, .next_offset = if (entries.len == 32) request.offset + entries.len else @as(?usize, null) });
    }
    if (request.action == .stop) {
        try io.writeFileAtomic(manager.alloc, try control.path(manager, "", "stop"), "Stop requested by the local operator.");
        return value(manager, .{ .accepted = true, .fulfilled = false });
    }
    const entry = (try manager.backgroundRecord(request.task orelse return error.MissingTaskId)) orelse return error.BackgroundDispatchRequired;
    if (request.action == .show) {
        var result = try value(manager, entry);
        try result.object.put(manager.alloc, "execution", try value(manager, try @import("contract_execution.zig").inspect(manager, try manager.loadTask(entry.task), entry)));
        try result.object.put(manager.alloc, "activity", try activity(manager, entry));
        return result;
    }
    if (request.action == .events) return events(manager, entry, request.generation orelse entry.generation, request.offset);
    if (request.action == .receipt) {
        const operation = request.operation orelse return error.BackgroundOperationRequired;
        if (try manager.backgroundOperation(operation)) |retained| {
            if (!std.mem.eql(u8, retained.task, entry.task)) return error.BackgroundOperationConflict;
            return value(manager, .{ .accepted = true, .fulfilled = false, .receipt = retained });
        }
        const result = control.read(manager, try control.path(manager, "receipts", operation)) catch |err| switch (err) {
            error.FileNotFound => return value(manager, .{ .operation = operation, .pending = true, .note = "Do not replay a claimed operation without reconciling its outcome." }),
            else => return err,
        };
        return std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, result, .{});
    }
    if (request.action == .@"resume" or request.action == .cancel) {
        if (request.operation) |id| if (try manager.backgroundOperation(id)) |previous| {
            if (!std.mem.eql(u8, previous.request_sha256, try workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, request, .{})))) return error.BackgroundOperationConflict;
            return value(manager, .{ .accepted = true, .fulfilled = false, .operation = previous.operation, .already_accepted = true });
        };
    }
    if (request.generation == null or request.generation.? != entry.generation) return error.StaleBackgroundOwner;
    if (request.action == .@"resume") {
        const lease = (try manager.tryTaskExecutionLease(entry.task)) orelse return error.WorkspaceExecutionBusy;
        defer lease.release();
        const task = try manager.loadTask(entry.task);
        if (task.state == .accepted and !try manager.publicationPending(task)) {
            const next = try domain.reconcilePublished(entry, @import("definition.zig").text(try manager.publicationSummary(task), "revision"), io.milliTimestamp());
            try saveOperation(manager, entry, next, request);
            return value(manager, .{ .accepted = true, .fulfilled = true, .record = next });
        }
        const activation = (try control.activation(manager, entry)) orelse return error.BackgroundActivationRequired;
        try control.verifyLiveAuthority(manager, activation);
        try manager.validateTaskBasis(task);
        const next = try domain.resumeRecord(entry, io.milliTimestamp());
        if (task.state == .conflict) try manager.reconcileConflict(task);
        try control.ensureHost(manager);
        try saveOperation(manager, entry, next, request);
        return value(manager, .{ .accepted = true, .fulfilled = false, .record = next });
    }
    if (request.action == .cancel and (entry.state == .queued or entry.state == .waiting or entry.state == .starting)) {
        var next = entry;
        if (entry.state != .starting) next.state = .cancelled;
        next.cancel_requested = true;
        next.retry = null;
        next.wait_condition = null;
        next.reason = "Cancelled by the user. Work and evidence remain retained.";
        next.updated_ms = io.milliTimestamp();
        try saveOperation(manager, entry, next, request);
        return value(manager, .{ .accepted = true, .fulfilled = false, .record = next });
    }
    _ = (try control.activation(manager, entry)) orelse return error.BackgroundActivationRequired;
    const command: control.Command = .{
        .operation = request.operation orelse return error.BackgroundOperationRequired,
        .workspace = manager.manifest.id,
        .task = entry.task,
        .generation = request.generation.?,
        .action = switch (request.action) {
            .steer => .steer,
            .cancel => .cancel,
            .input => .answer,
            .validation => .validation,
            else => return error.InvalidBackgroundControl,
        },
        .text = request.text,
        .request_id = request.request_id,
        .approved = request.approved,
        .answers = request.answers,
        .receipt = request.receipt,
    };
    try control.enqueue(manager, command);
    return value(manager, .{ .accepted = true, .operation = command.operation, .fulfilled = false });
}

fn events(manager: workspace.Manager, entry: domain.Record, generation: u64, offset: usize) !std.json.Value {
    if (generation == 0 or generation > entry.generation) return value(manager, .{ .events = .{}, .next_offset = offset, .active = entry.state == .queued });
    const name = try manager.alloc.print("background-{s}-{d}.ndjson", .{ entry.task, generation });
    const file_path = try control.path(manager, "events", name);
    var file = std.Io.Dir.openFileAbsolute(io.getIo(), file_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return value(manager, .{ .events = .{}, .next_offset = offset, .active = entry.state == .queued or entry.state == .starting or entry.state == .running, .journal_unavailable = true }),
        else => return err,
    };
    defer file.close(io.getIo());
    if (offset > (try file.stat(io.getIo())).size) return error.InvalidEventCursor;
    const buffer = try manager.alloc.alloc(u8, 2 * 1024 * 1024);
    var reader = file.reader(io.getIo(), buffer);
    const aligned = try alignEventOffset(&reader, offset);
    var result: std.ArrayList(std.json.Value) = .empty;
    var next = aligned;
    for (0..32) |_| {
        const line = try completeLine(&reader.interface) orelse break;
        const event = std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, line, .{}) catch return error.InvalidEventRecord;
        try result.append(manager.alloc, event);
        next += line.len + 1;
    }
    return value(manager, .{ .events = result.items, .requested_offset = offset, .aligned_offset = aligned, .next_offset = next, .offset_unit = "bytes", .active = generation == entry.generation and entry.state == .running, .record = entry });
}

fn saveOperation(manager: workspace.Manager, previous: domain.Record, next: domain.Record, request: Request) !void {
    const operation: domain.Operation = .{ .workspace = manager.manifest.id, .task = next.task, .operation = request.operation orelse return error.BackgroundOperationRequired, .request_sha256 = try workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, request, .{})), .generation = next.generation, .state = next.state };
    try manager.saveBackgroundOperation(next, try dispatch.digest(manager, previous), operation);
}

/// Bounded journal tail; absence of recent events does not prove inactivity.
/// Return public event metadata only, never tool payloads or inferred outcomes.
pub fn activity(manager: workspace.Manager, entry: domain.Record) !std.json.Value {
    const model = @import("definition.zig");
    const name = try manager.alloc.print("background-{s}-{d}.ndjson", .{ entry.task, entry.generation });
    const path = try control.path(manager, "events", name);
    var file = std.Io.Dir.openFileAbsolute(io.getIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return value(manager, .{ .journal_available = false }),
        else => return err,
    };
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    const start = stat.size - @min(stat.size, 65536);
    const buffer = try manager.alloc.alloc(u8, @intCast(stat.size - start));
    const bytes = buffer[0..try file.readPositionalAll(io.getIo(), buffer, start)];
    // Inspect only this snapshot's bytes; concurrent appends cannot extend it.
    var cursor: usize = if (start > 0) if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| end + 1 else bytes.len else 0;
    var recent: std.ArrayList(std.json.Value) = .empty;
    while (std.mem.indexOfScalarPos(u8, bytes, cursor, '\n')) |end| {
        const line = bytes[cursor..end];
        cursor = end + 1;
        const event = std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, line, .{}) catch continue;
        const data = model.field(event, "data") orelse continue;
        if (recent.items.len == 16) _ = recent.orderedRemove(0);
        try recent.append(manager.alloc, try value(manager, .{
            .cursor = model.field(event, "cursor"),
            .timestamp_ms = model.field(event, "timestamp_ms"),
            .type = model.text(data, "type"),
            .call_id = model.text(data, "call_id"),
            .tool = model.text(data, "name"),
        }));
    }
    return value(manager, .{
        .journal_available = true,
        .generation = entry.generation,
        .journal_updated_ms = stat.mtime.toMilliseconds(),
        .next_offset = stat.size,
        .offset_unit = "bytes",
        .tail_only = true,
        .tail_start_offset = start,
        .recent_events = recent.items,
        .note = "A running record or a quiet journal does not prove progress. Unmatched tool events in this bounded tail do not establish a pending operation. Inspect receipts for outcomes; reconcile uncertain effects before retrying.",
    });
}

// A partially written final line is not an event yet. Do not advance its cursor.
fn completeLine(reader: *std.Io.Reader) !?[]const u8 {
    const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    return line[0 .. line.len - 1];
}

// A caller may seek into a large journal without knowing every line boundary.
// Skip only the partial prefix and report the aligned byte position explicitly.
fn alignEventOffset(reader: *std.Io.File.Reader, offset: u64) !u64 {
    if (offset == 0) {
        try reader.seekTo(0);
        return 0;
    }
    try reader.seekTo(offset - 1);
    if (try reader.interface.takeByte() == '\n') return offset;
    const fragment = try completeLine(&reader.interface) orelse return offset;
    return offset + fragment.len + 1;
}

test "journal paging retains an incomplete final event for a later read" {
    var reader = std.Io.Reader.fixed("{\"cursor\":1}\n{\"cursor\":2}");
    try std.testing.expectEqualStrings("{\"cursor\":1}", (try completeLine(&reader)).?);
    try std.testing.expect((try completeLine(&reader)) == null);
}
