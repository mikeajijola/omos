//! Authenticated task input and cancellation. Worker activity cannot authorize
//! control; signed compute authority is checked before recording a command.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const ownership = @import("company_execution.zig");
const activity = @import("company_activity.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const io = @import("../shared/io.zig");

pub const prefix = "company/controls/";
const maximum: u64 = 9007199254740991;
pub const Command = struct {
    version: []const u8 = "omos.company-task-control/v1",
    mode: enum { input, cancel },
    event_offset: ?u64 = null,
    request_id: ?u64 = null,
    approved: ?bool = null,
    answers: ?[]const []const u8 = null,
};
pub const Record = struct {
    version: []const u8 = "omos.company-task-input/v1",
    workspace: []const u8,
    task: []const u8,
    view: []const u8,
    actor: []const u8,
    grant: []const u8,
    execution: ownership.Fence,
    contract_sha256: []const u8,
    operation: []const u8,
    request_hash: []const u8,
    expires_ms: i64,
    command: Command,
    state: enum { pending, dispatching, applied, failed } = .pending,
    delivery: ?[]const u8 = null,
};
pub const Request = struct {
    version: []const u8 = "omos.company-input-owner/v1",
    action: enum { inspect, claim, acknowledge },
    view: []const u8,
    execution: ownership.Fence,
    event_offset: ?u64 = null,
    delivery: ?[]const u8 = null,
    outcome: ?enum { applied, failed } = null,
};
fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn path(alloc: std.mem.Allocator, task: []const u8, generation: u64, offset: u64) ![]const u8 {
    if (!authority.safeIdentity(task) or generation == 0 or generation > maximum or offset > maximum) return error.InvalidCompanyTaskControl;
    return alloc.print("{s}{s}/{d}/{d}.json", .{ prefix, task, generation, offset });
}
fn contractHash(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    return workspace.hash(manager.alloc, try json(manager.alloc, .{ task.definition, task.model_basis }));
}
fn validate(command: Command) !void {
    if (!std.mem.eql(u8, command.version, "omos.company-task-control/v1")) return error.InvalidCompanyTaskControl;
    if (command.mode == .cancel) {
        if (command.event_offset != null or command.request_id != null or command.approved != null or command.answers != null) return error.InvalidCompanyTaskControl;
        return;
    }
    if (command.event_offset == null or command.event_offset.? > maximum or command.request_id == null or command.request_id.? == 0 or command.request_id.? > maximum or ((command.approved != null) == (command.answers != null))) return error.InvalidCompanyTaskControl;
    if (command.answers) |answers| {
        if (answers.len == 0 or answers.len > 4) return error.InvalidCompanyTaskControl;
        var bytes: usize = 0;
        for (answers) |answer| {
            bytes += answer.len;
            if (answer.len == 0 or !std.unicode.utf8ValidateSlice(answer)) return error.InvalidCompanyTaskControl;
        }
        if (bytes > 16384) return error.InvalidCompanyTaskControl;
    }
}
pub fn supported(declaration: model.Declaration) bool {
    return model.hasOperation(declaration, "omos_company_task_control") and model.hasOperation(declaration, "omos_company_input_admin") and model.hasOperation(declaration, "omos_company_input_read");
}

pub fn parseCommand(alloc: std.mem.Allocator, raw: []const u8) !Command {
    if (raw.len == 0 or raw.len > 24576) return error.InvalidCompanyTaskControl;
    const command = try records.decode(Command, alloc, raw, .{});
    try validate(command);
    if (command.answers) |answers| for (answers) |answer| {
        const masked = try @import("../shared/text_utils.zig").maskSecrets(alloc, answer);
        if (!std.mem.eql(u8, masked, answer)) return error.CompanyInputNotPortable;
    };
    return command;
}

pub fn rejected(err: anyerror) bool {
    return ownership.rejected(err) or switch (err) {
        error.InvalidCompanyTaskControl, error.CompanyInputAlreadyAnswered, error.CompanyInputExpired, error.CompanyInputNotPortable, error.TaskReviewInProgress, error.CompanyWorkerNotQueued => true,
        else => false,
    };
}

pub fn validateStored(alloc: std.mem.Allocator, row: Record, filename: []const u8) !void {
    try validate(row.command);
    if (row.command.mode != .input or !std.mem.eql(u8, row.version, "omos.company-task-input/v1") or row.expires_ms <= 0) return error.InvalidCompanyTaskControl;
    for ([_][]const u8{ row.workspace, row.task, row.view, row.actor, row.grant, row.operation, row.execution.runtime }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyTaskControl;
    _ = try authority.hexBytes(32, row.contract_sha256);
    _ = try authority.hexBytes(32, row.request_hash);
    if (!std.mem.eql(u8, filename, try path(alloc, row.task, row.execution.generation, row.command.event_offset.?))) return error.InvalidCompanyTaskControl;
    if ((row.state == .pending) != (row.delivery == null)) return error.InvalidCompanyTaskControl;
    if (row.delivery) |delivery| if (!authority.safeIdentity(delivery)) return error.InvalidCompanyTaskControl;
}
fn execution(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, view: []const u8, fence: ownership.Fence) !void {
    try authority.authorizeExecution(manager, task);
    try manager.validateTaskBasis(task);
    const current = try records.decode(ownership.Record, manager.alloc, try manager.companyContent(try ownership.path(manager.alloc, view)), .{});
    try ownership.validate(current, view, task.id, grant);
    try ownership.require(current, fence, io.milliTimestamp());
}

/// The caller authenticates execute_task separately from the actor tool broker.
/// Controls do not inherit authority from text, tool output, or a UI projection.
pub fn submit(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, view: []const u8, request: authority.Request, request_hash: []const u8) ![]const u8 {
    if (!manager.company_operation_held or !authority.permitsAction(grant, .execute_task)) return error.CompanyAccessDenied;
    const raw = request.content orelse return error.InvalidCompanyTaskControl;
    const command = try parseCommand(manager.alloc, raw);
    if (request.revision == null or !std.mem.eql(u8, request.revision.?, try manager.currentRevision(task))) return error.WorkspaceRevisionChanged;
    try authority.authorizeExecution(manager, task);
    try manager.validateTaskBasis(task);
    if (task.state == .accepted or task.state == .publication_pending) return error.TaskIsReadOnly;
    if (task.review_job) |id| {
        const job = try manager.loadReviewJob(task, id);
        if (job.state == .queued or job.state == .running) return error.TaskReviewInProgress;
    }
    if (command.mode == .cancel) {
        const job = (try @import("company_runtime.zig").taskJob(manager, view)) orelse return error.CompanyWorkerNotQueued;
        if (job.state == .running or request.execution != null) try execution(manager, task, grant, view, request.execution orelse return error.CompanyExecutionFenceRequired);
        _ = try @import("company_worker_jobs.zig").administer(manager, .{ .change = .cancel, .view = view, .operation = request.operation, .expected_sha256 = try workspace.hash(manager.alloc, try manager.companyContent(try @import("company_worker_jobs.zig").path(manager.alloc, job.id))) });
        return json(manager.alloc, .{ .version = "omos.company-task-control-outcome/v1", .view = view, .generation = job.generation, .state = "cancelled", .operation = request.operation });
    }
    const fence = request.execution orelse return error.CompanyExecutionFenceRequired;
    try execution(manager, task, grant, view, fence);
    const filename = try path(manager.alloc, task.id, fence.generation, command.event_offset.?);
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (try manager.companyRecordExists(filename, revision)) {
        const saved = try records.decode(Record, manager.alloc, try manager.contentAt(filename, revision), .{});
        try validateStored(manager.alloc, saved, filename);
        if (!std.mem.eql(u8, saved.request_hash, request_hash)) return error.CompanyInputAlreadyAnswered;
        return json(manager.alloc, saved);
    }
    const event_path = try manager.alloc.print("company/activity/{s}/{d}/{d}.json", .{ task.id, fence.generation, command.event_offset.? });
    const event = try records.decode(activity.Record, manager.alloc, try manager.contentAt(event_path, revision), .{});
    try activity.validateStored(manager.alloc, event, event_path);
    if (!std.mem.eql(u8, event.workspace, manager.manifest.id) or !std.mem.eql(u8, event.view, view) or !std.mem.eql(u8, event.actor, grant.actor) or !std.mem.eql(u8, event.grant, grant.id) or !std.mem.eql(u8, event.runtime, fence.runtime)) return error.CompanyAccessDenied;
    const payload = try activity.validateEvent(manager.alloc, event.payload orelse return error.InvalidCompanyTaskControl);
    const id = model.field(payload, "request_id") orelse return error.InvalidCompanyTaskControl;
    if (!std.mem.eql(u8, model.text(payload, "type"), "input_required") or id != .integer or @as(u64, @intCast(id.integer)) != command.request_id.?) return error.InvalidCompanyTaskControl;
    const question = std.mem.eql(u8, model.text(payload, "kind"), "question");
    if (question != (command.answers != null)) return error.InvalidCompanyTaskControl;
    if (question and command.answers.?.len != model.items(payload, "questions").len) return error.InvalidCompanyTaskControl;
    const row: Record = .{ .workspace = manager.manifest.id, .task = task.id, .view = view, .actor = grant.actor, .grant = grant.id, .execution = fence, .contract_sha256 = try contractHash(manager, task), .operation = request.operation, .request_hash = request_hash, .expires_ms = @min(request.expires_ms, grant.expires_ms), .command = command };
    _ = try manager.companyWrite(revision, &.{.{ .path = filename, .content = try json(manager.alloc, row) }});
    return json(manager.alloc, row);
}

pub fn read(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, view: []const u8, request: authority.Request) ![]const u8 {
    const generation = std.fmt.parseInt(u64, request.record_id orelse return error.InvalidCompanyTaskControl, 10) catch return error.InvalidCompanyTaskControl;
    const filename = try path(manager.alloc, task.id, generation, request.offset);
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (!try manager.companyRecordExists(filename, revision)) return json(manager.alloc, .{ .version = "omos.company-task-input-state/v1", .view = view, .generation = generation, .event_offset = request.offset, .state = "unanswered" });
    const row = try records.decode(Record, manager.alloc, try manager.contentAt(filename, revision), .{});
    try validateStored(manager.alloc, row, filename);
    if (!std.mem.eql(u8, row.workspace, manager.manifest.id) or !std.mem.eql(u8, row.view, view) or !std.mem.eql(u8, row.actor, grant.actor) or !std.mem.eql(u8, row.grant, grant.id)) return error.CompanyAccessDenied;
    return json(manager.alloc, .{ .version = "omos.company-task-input-state/v1", .view = view, .generation = generation, .event_offset = request.offset, .state = @tagName(row.state), .expired = row.expires_ms <= io.milliTimestamp() });
}

pub fn administer(manager: workspace.Manager, request: Request) ![]const u8 {
    if (!manager.company_operation_held or !std.mem.eql(u8, request.version, "omos.company-input-owner/v1") or !authority.safeIdentity(request.view)) return error.InvalidCompanyTaskControl;
    const View = struct { id: []const u8, task: []const u8, actor: []const u8, grant: []const u8 };
    const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{request.view})), .{ .ignore_unknown_fields = true });
    const task = try manager.refreshTaskContext(try manager.loadTask(view.task));
    const current = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const grant = try @import("company_task_scope.zig").forTask(manager, task, try authority.liveGrant(current, view.grant, io.milliTimestamp()));
    if (!std.mem.eql(u8, view.actor, grant.actor) or !authority.permitsAction(grant, .execute_task)) return error.CompanyAccessDenied;
    try execution(manager, task, grant, view.id, request.execution);
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const hash = try contractHash(manager, task);
    if (request.action == .inspect) {
        if (request.event_offset != null or request.delivery != null or request.outcome != null) return error.InvalidCompanyTaskControl;
        const paths = try records.decode([]const struct { filename: []const u8 }, manager.alloc, try manager.companyInputPaths(task.id, request.execution.generation, revision), .{});
        var rows: std.ArrayList(Record) = .empty;
        for (paths) |item| {
            const row = try records.decode(Record, manager.alloc, try manager.contentAt(item.filename, revision), .{});
            try validateStored(manager.alloc, row, item.filename);
            if (!std.mem.eql(u8, row.workspace, manager.manifest.id) or !std.mem.eql(u8, row.actor, grant.actor) or !std.mem.eql(u8, row.grant, grant.id) or !std.mem.eql(u8, row.view, view.id) or !std.mem.eql(u8, row.execution.runtime, request.execution.runtime) or !std.mem.eql(u8, row.contract_sha256, hash)) return error.CompanyAccessDenied;
            if (row.expires_ms > io.milliTimestamp()) try rows.append(manager.alloc, row);
        }
        return json(manager.alloc, .{ .version = "omos.company-input-owner-outcome/v1", .view = view.id, .generation = request.execution.generation, .commands = rows.items });
    }
    const filename = try path(manager.alloc, task.id, request.execution.generation, request.event_offset orelse return error.InvalidCompanyTaskControl);
    var row = try records.decode(Record, manager.alloc, try manager.contentAt(filename, revision), .{});
    try validateStored(manager.alloc, row, filename);
    if (!std.mem.eql(u8, row.workspace, manager.manifest.id) or !std.mem.eql(u8, row.actor, grant.actor) or !std.mem.eql(u8, row.grant, grant.id) or !std.mem.eql(u8, row.view, view.id) or !std.mem.eql(u8, row.execution.runtime, request.execution.runtime)) return error.CompanyAccessDenied;
    if (!std.mem.eql(u8, row.contract_sha256, hash) or row.expires_ms <= io.milliTimestamp()) return error.CompanyInputExpired;
    const delivery = request.delivery orelse return error.InvalidCompanyTaskControl;
    if (!authority.safeIdentity(delivery)) return error.InvalidCompanyTaskControl;
    if (request.action == .claim) {
        if (request.outcome != null) return error.InvalidCompanyTaskControl;
        if (row.state == .pending) {
            row.state = .dispatching;
            row.delivery = delivery;
        } else if (row.state != .dispatching or !std.mem.eql(u8, row.delivery.?, delivery)) return error.CompanyInputOutcomeUncertain;
    } else {
        if (row.delivery == null or !std.mem.eql(u8, row.delivery.?, delivery)) return error.CompanyInputOutcomeUncertain;
        const next: @FieldType(Record, "state") = switch (request.outcome orelse return error.InvalidCompanyTaskControl) {
            .applied => .applied,
            .failed => .failed,
        };
        if (row.state != .dispatching and row.state != next) return error.CompanyInputOutcomeUncertain;
        row.state = next;
    }
    _ = try manager.companyWrite(revision, &.{.{ .path = filename, .content = try json(manager.alloc, row) }});
    return json(manager.alloc, .{ .version = "omos.company-input-owner-outcome/v1", .view = view.id, .generation = request.execution.generation, .commands = .{row} });
}

test "company task control keeps input decisions separate from cancellation and bounds answers" {
    try validate(.{ .mode = .cancel });
    try validate(.{ .mode = .input, .event_offset = 4, .request_id = 2, .approved = false });
    try validate(.{ .mode = .input, .event_offset = 4, .request_id = 2, .answers = &.{"Selected answer"} });
    try std.testing.expectError(error.InvalidCompanyTaskControl, validate(.{ .mode = .input, .event_offset = 4, .request_id = 2, .approved = true, .answers = &.{"Injected"} }));
    try std.testing.expectError(error.InvalidCompanyTaskControl, validate(.{ .mode = .cancel, .approved = true }));
    try std.testing.expectError(error.InvalidCompanyTaskControl, validate(.{ .mode = .input, .event_offset = 4, .request_id = 0, .approved = true }));
}
