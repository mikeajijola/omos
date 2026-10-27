//! Public native actor delivery. Activity is untrusted projection data, never
//! an execution receipt or independent completion evidence.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const ownership = @import("company_execution.zig");
const scope = @import("company_task_scope.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const manifest = @import("fossil_manifest.zig");
const io = @import("../shared/io.zig");

pub const prefix = "company/activity/";
const max_position: u64 = 9007199254740991;
pub const Request = struct {
    version: []const u8 = "omos.company-activity-write/v1",
    action: enum { inspect, append },
    view: []const u8,
    execution: ownership.Fence,
    offset: u64 = 0,
    events: []const []const u8 = &.{},
};
pub const Record = struct {
    version: []const u8 = "omos.company-activity/v1",
    workspace: []const u8,
    task: []const u8,
    view: []const u8,
    actor: []const u8,
    grant: []const u8,
    runtime: []const u8,
    generation: u64,
    kind: enum { head, event },
    offset: u64,
    at_ms: i64,
    paths: []const []const u8 = &.{},
    payload: ?[]const u8 = null,
    ended: bool = false,
    authority: []const u8 = "actor_public_activity_only",
};
fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn directory(alloc: std.mem.Allocator, task: []const u8, generation: u64) ![]const u8 {
    if (!authority.safeIdentity(task) or generation == 0 or generation > max_position) return error.InvalidCompanyActivity;
    return alloc.print("{s}{s}/{d}", .{ prefix, task, generation });
}
fn filename(alloc: std.mem.Allocator, row: Record) ![]const u8 {
    const parent = try directory(alloc, row.task, row.generation);
    return if (row.kind == .head) alloc.print("{s}/head.json", .{parent}) else alloc.print("{s}/{d}.json", .{ parent, row.offset });
}

/// The transport accepts only the public native event fields used by the UI.
/// Provider replay, reasoning, credentials, and arbitrary extra fields fail.
pub fn validateEvent(alloc: std.mem.Allocator, raw: []const u8) !std.json.Value {
    if (raw.len == 0 or raw.len > 16384) return error.InvalidCompanyActivity;
    const event = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
    if (event != .object) return error.InvalidCompanyActivity;
    const kind = model.text(event, "type");
    const allowed: []const []const u8 = if (std.mem.eql(u8, kind, "assistant_started") or std.mem.eql(u8, kind, "assistant_restarted") or std.mem.eql(u8, kind, "turn_start")) &.{"type"} else if (std.mem.eql(u8, kind, "text_delta") or std.mem.eql(u8, kind, "notice")) &.{ "type", "text" } else if (std.mem.eql(u8, kind, "tool_start")) &.{ "type", "call_id", "name", "path", "action" } else if (std.mem.eql(u8, kind, "tool_progress")) &.{ "type", "call_id", "text" } else if (std.mem.eql(u8, kind, "tool_end")) &.{ "type", "call_id", "outcome", "text" } else if (std.mem.eql(u8, kind, "command_output")) &.{ "type", "call_id", "stream", "text" } else if (std.mem.eql(u8, kind, "turn_end")) &.{ "type", "exit_code" } else if (std.mem.eql(u8, kind, "error")) &.{ "type", "code" } else if (std.mem.eql(u8, kind, "input_required")) &.{ "type", "kind", "request_id", "prompt", "questions" } else return error.InvalidCompanyActivity;
    var fields = event.object.iterator();
    while (fields.next()) |entry| {
        var permitted = false;
        for (allowed) |name| permitted = permitted or std.mem.eql(u8, name, entry.key_ptr.*);
        if (!permitted) return error.InvalidCompanyActivity;
        if (entry.value_ptr.* == .string and !std.unicode.utf8ValidateSlice(entry.value_ptr.string)) return error.InvalidCompanyActivity;
    }
    for ([_][]const u8{ "call_id", "name", "path", "action", "outcome", "text", "stream", "code", "kind", "prompt" }) |name| if (model.field(event, name)) |value| {
        if (value != .null and value != .string) return error.InvalidCompanyActivity;
    };
    if (std.mem.eql(u8, kind, "text_delta") or std.mem.eql(u8, kind, "notice") or std.mem.eql(u8, kind, "tool_progress") or std.mem.eql(u8, kind, "command_output")) {
        if ((model.field(event, "text") orelse return error.InvalidCompanyActivity) != .string) return error.InvalidCompanyActivity;
    }
    if (std.mem.startsWith(u8, kind, "tool_")) {
        const call_id = model.text(event, "call_id");
        if (call_id.len == 0 or call_id.len > 256) return error.InvalidCompanyActivity;
    }
    if (std.mem.eql(u8, kind, "tool_start") and (model.text(event, "name").len == 0 or model.text(event, "name").len > 256)) return error.InvalidCompanyActivity;
    if (std.mem.eql(u8, kind, "turn_end") and model.field(event, "exit_code") == null) return error.InvalidCompanyActivity;
    if (std.mem.eql(u8, kind, "input_required")) {
        const input_kind = model.text(event, "kind");
        if (model.field(event, "request_id") == null or (!std.mem.eql(u8, input_kind, "approval") and !std.mem.eql(u8, input_kind, "question"))) return error.InvalidCompanyActivity;
        if (std.mem.eql(u8, input_kind, "approval") and model.text(event, "prompt").len == 0) return error.InvalidCompanyActivity;
        if (std.mem.eql(u8, input_kind, "question") and model.field(event, "questions") == null) return error.InvalidCompanyActivity;
    }
    if (model.field(event, "request_id")) |value| if (value != .integer or value.integer < 1 or value.integer > max_position) return error.InvalidCompanyActivity;
    if (model.field(event, "exit_code")) |value| if (value != .integer or value.integer < 0 or value.integer > 255) return error.InvalidCompanyActivity;
    if (model.field(event, "questions")) |value| {
        if (value != .array or value.array.items.len == 0 or value.array.items.len > 4) return error.InvalidCompanyActivity;
        const Question = struct { question: []const u8, options: []const struct { label: []const u8, description: ?[]const u8 = null } = &.{}, header: ?[]const u8 = null, id: ?[]const u8 = null };
        _ = try records.decode([]const Question, alloc, try json(alloc, value), .{});
    }
    return event;
}
pub fn validateStored(alloc: std.mem.Allocator, row: Record, path: []const u8) !void {
    if (!std.mem.eql(u8, row.version, "omos.company-activity/v1") or !std.mem.eql(u8, row.authority, "actor_public_activity_only") or row.at_ms < 0 or row.offset > max_position or !std.mem.eql(u8, path, try filename(alloc, row))) return error.InvalidCompanyActivity;
    _ = try authority.hexBytes(32, row.workspace);
    for ([_][]const u8{ row.task, row.view, row.actor, row.grant, row.runtime }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyActivity;
    if (row.kind == .head) {
        if (row.payload != null or row.paths.len == 0 or row.paths.len > 32) return error.InvalidCompanyActivity;
        for (row.paths) |path_value| if (!authority.validPath(path_value, std.mem.endsWith(u8, path_value, "/"))) return error.InvalidCompanyActivity;
    } else {
        if (row.paths.len != 0 or row.payload == null or row.ended) return error.InvalidCompanyActivity;
        _ = try validateEvent(alloc, row.payload.?);
    }
}
fn optional(manager: workspace.Manager, path: []const u8, revision: []const u8) !?Record {
    if (!try manager.companyRecordExists(path, revision)) return null;
    const row = try records.decode(Record, manager.alloc, try manager.contentAt(path, revision), .{});
    try validateStored(manager.alloc, row, path);
    return row;
}
fn permits(manager: workspace.Manager, row: Record, task: workspace.Task, grant: authority.Grant, view: []const u8) !void {
    if (!std.mem.eql(u8, row.workspace, manager.manifest.id) or !std.mem.eql(u8, row.task, task.id) or !std.mem.eql(u8, row.view, view) or !std.mem.eql(u8, row.actor, grant.actor) or !std.mem.eql(u8, row.grant, grant.id)) return error.CompanyAccessDenied;
    for (row.paths) |selector| if (!authority.permitsSelector(grant, selector)) return error.CompanyAccessDenied;
}
pub fn execute(original: workspace.Manager, request: Request) ![]const u8 {
    var manager = original;
    if (!manager.company_operation_held and !(request.action == .inspect and manager.company_read_revision != null)) return error.CompanyOperationLeaseRequired;
    if (!std.mem.eql(u8, request.version, "omos.company-activity-write/v1") or !authority.safeIdentity(request.view) or request.offset > max_position or request.events.len > 8 or (request.action == .inspect and (request.offset != 0 or request.events.len != 0)) or (request.action == .append and request.events.len == 0)) return error.InvalidCompanyActivity;
    const View = struct { id: []const u8, actor: []const u8, grant: []const u8, task: []const u8 };
    const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{request.view})), .{ .ignore_unknown_fields = true });
    const snapshot = if (manager.company_read_revision != null) try manager.taskStatusSnapshot(view.task) else null;
    const task = if (snapshot) |selected| selected.task else try manager.refreshTaskContext(try manager.loadTask(view.task));
    if (snapshot) |selected| manager.task_read_revision = .{ .branch = task.branch, .revision = selected.revision };
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const grant = try scope.forTask(manager, task, try authority.liveGrant(state, binding.grant, io.milliTimestamp()));
    if (!std.mem.eql(u8, view.id, request.view) or !std.mem.eql(u8, binding.actor, grant.actor) or !std.mem.eql(u8, view.actor, grant.actor) or !std.mem.eql(u8, view.grant, grant.id)) return error.CompanyAccessDenied;
    try authority.authorizeExecution(manager, task);
    const execution = try records.decode(ownership.Record, manager.alloc, try manager.companyContent(try ownership.path(manager.alloc, request.view)), .{});
    try ownership.validate(execution, request.view, task.id, grant);
    try ownership.require(execution, request.execution, io.milliTimestamp());
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    var head: Record = .{ .workspace = manager.manifest.id, .task = task.id, .view = view.id, .actor = grant.actor, .grant = grant.id, .runtime = request.execution.runtime, .generation = request.execution.generation, .kind = .head, .offset = 0, .at_ms = io.milliTimestamp(), .paths = grant.paths };
    const head_path = try filename(manager.alloc, head);
    if (try optional(manager, head_path, revision)) |saved| {
        try permits(manager, saved, task, grant, view.id);
        if (!std.mem.eql(u8, saved.runtime, request.execution.runtime)) return error.CompanyExecutionFenced;
        head = saved;
    }
    var files: std.ArrayList(workspace.Manager.CompanyFile) = .empty;
    if (request.action == .append) {
        if (request.events.len > max_position - request.offset or request.offset > head.offset or (request.offset < head.offset and request.events.len > head.offset - request.offset) or (request.offset == head.offset and head.ended)) return error.CompanyActivityConflict;
        for (request.events, 0..) |raw, index| {
            const event = try validateEvent(manager.alloc, raw);
            if (head.ended and request.offset == head.offset) return error.CompanyActivityConflict;
            var row = head;
            row.kind = .event;
            row.offset = request.offset + index;
            row.paths = &.{};
            row.payload = raw;
            row.ended = false;
            row.at_ms = 0; // The native event order is authoritative; the head records host arrival time.
            const path = try filename(manager.alloc, row);
            const bytes = try json(manager.alloc, row);
            if (request.offset < head.offset) {
                const before = try manager.contentAt(path, revision);
                if (!std.mem.eql(u8, before, bytes)) return error.CompanyActivityConflict;
            } else {
                try files.append(manager.alloc, .{ .path = path, .content = bytes });
                if (std.mem.eql(u8, model.text(event, "type"), "turn_end")) {
                    if (index + 1 != request.events.len) return error.CompanyActivityConflict;
                    head.ended = true;
                }
            }
        }
        if (request.offset == head.offset) {
            head.offset += request.events.len;
            head.at_ms = io.milliTimestamp();
            try files.append(manager.alloc, .{ .path = head_path, .content = try json(manager.alloc, head) });
        }
    }
    const after = if (files.items.len > 0) try manager.companyWrite(revision, files.items) else revision;
    return json(manager.alloc, .{ .version = "omos.company-activity-outcome/v1", .workspace = manager.manifest.id, .view = view.id, .task = task.id, .generation = head.generation, .revision = after, .next_offset = if (request.action == .inspect) head.offset else request.offset + request.events.len, .ended = head.ended });
}
pub fn page(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, view: []const u8, request: authority.Request) ![]const u8 {
    if (request.limit == 0 or request.limit > 16384 or request.offset > max_position) return error.InvalidCompanyActivity;
    const current = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const revision = request.revision orelse current;
    if (!manifest.validHash(revision) or !try manager.revisionDescendsFrom(current, revision)) return error.CompanyAccessDenied;
    const generation = if (request.record_id) |raw| std.fmt.parseInt(u64, raw, 10) catch return error.InvalidCompanyActivity else 1;
    const execution_path = try ownership.path(manager.alloc, view);
    const execution = if (try manager.companyRecordExists(execution_path, revision)) try records.decode(ownership.Record, manager.alloc, try manager.contentAt(execution_path, revision), .{}) else null;
    if (execution) |pinned| try ownership.validate(pinned, view, task.id, grant);
    const last_generation = if (execution) |pinned| pinned.generation else 0;
    if (generation == 0 or (generation > last_generation and !(last_generation == 0 and generation == 1))) return error.InvalidCompanyActivity;
    const parent = try directory(manager.alloc, task.id, generation);
    const head = try optional(manager, try manager.alloc.print("{s}/head.json", .{parent}), revision);
    var rows: std.ArrayList(std.json.Value) = .empty;
    var end: u64 = request.offset;
    if (head) |saved| {
        try permits(manager, saved, task, grant, view);
        if (request.offset > saved.offset) return error.InvalidCompanyActivity;
        while (end < saved.offset and rows.items.len < @min(request.limit, 2)) : (end += 1) {
            const path = try manager.alloc.print("{s}/{d}.json", .{ parent, end });
            const row = (try optional(manager, path, revision)) orelse return error.CompanyActivityIncomplete;
            try permits(manager, row, task, grant, view);
            try rows.append(manager.alloc, .{ .object = blk: {
                var object: std.json.ObjectMap = .empty;
                try object.put(manager.alloc, "offset", .{ .integer = @intCast(end) });
                try object.put(manager.alloc, "data", try validateEvent(manager.alloc, row.payload.?));
                break :blk object;
            } });
        }
    } else if (request.offset != 0) return error.InvalidCompanyActivity;
    const count = if (head) |saved| saved.offset else 0;
    return json(manager.alloc, .{ .version = "omos.company-activity-page/v1", .workspace = manager.manifest.id, .view = view, .generation = generation, .index_revision = revision, .event_count = count, .current_generation = last_generation, .events = rows.items, .next_offset = if (end < count) @as(?u64, end) else null, .resume_offset = end, .next_generation = if (end == count and generation < last_generation) @as(?u64, generation + 1) else null, .ended = if (head) |saved| saved.ended else false, .authority = "actor_public_activity_only" });
}

test "company activity accepts public event fields and rejects replay and private payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = try validateEvent(alloc, "{\"type\":\"text_delta\",\"text\":\"Visible progress\"}");
    _ = try validateEvent(alloc, "{\"type\":\"tool_end\",\"call_id\":\"tool-1\",\"outcome\":\"success\"}");
    for ([_][]const u8{ "{\"type\":\"reasoning\",\"text\":\"private\"}", "{\"type\":\"text_delta\",\"text\":\"Visible\",\"provider_state\":{}}", "{\"type\":\"tool_start\",\"arguments\":{}}", "{\"type\":\"turn_end\",\"exit_code\":-1}" }) |raw| try std.testing.expectError(error.InvalidCompanyActivity, validateEvent(alloc, raw));
}
