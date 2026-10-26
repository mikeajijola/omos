//! Authenticated company task updates retain intent before stopping an old
//! execution owner. Independent planning revises the canonical contract.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const jobs = @import("company_worker_jobs.zig");
const runtimes = @import("company_runtime.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const ownership = @import("company_execution.zig");
const io = @import("../shared/io.zig");

pub const prefix = "company/amendments/";
const Command = struct { version: []const u8, text: []const u8 };
pub const Record = struct {
    version: []const u8 = "omos.company-task-amendment/v1",
    workspace: []const u8,
    task: []const u8,
    view: []const u8,
    actor: []const u8,
    grant: []const u8,
    operation: []const u8,
    request_hash: []const u8,
    revision: []const u8,
    contract_sha256: []const u8,
    worker_sha256: []const u8,
    amendment_count: usize,
    text: []const u8,
};
fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn path(alloc: std.mem.Allocator, task: []const u8, request_hash: []const u8) ![]const u8 {
    if (!authority.safeIdentity(task)) return error.InvalidCompanyTaskAmendment;
    _ = try authority.hexBytes(32, request_hash);
    return alloc.print("{s}{s}/{s}.json", .{ prefix, task, request_hash });
}
pub fn selected(alloc: std.mem.Allocator, raw: []const u8) !bool {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
    return std.mem.eql(u8, model.text(value, "version"), "omos.company-task-amend/v1");
}
pub fn command(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or raw.len > 24576) return error.InvalidCompanyTaskAmendment;
    const value = try records.decode(Command, alloc, raw, .{});
    if (!std.mem.eql(u8, value.version, "omos.company-task-amend/v1") or value.text.len > 16384 or !std.unicode.utf8ValidateSlice(value.text)) return error.InvalidCompanyTaskAmendment;
    const text = std.mem.trim(u8, value.text, " \t\r\n");
    if (text.len == 0 or std.ascii.eqlIgnoreCase(text, "continue")) return error.InvalidCompanyTaskAmendment;
    const portable = try @import("../shared/text_utils.zig").maskSecrets(alloc, text);
    if (!std.mem.eql(u8, portable, text)) return error.CompanyInputNotPortable;
    return text;
}
pub fn validateStored(alloc: std.mem.Allocator, record: Record, filename: []const u8) !void {
    if (!std.mem.eql(u8, record.version, "omos.company-task-amendment/v1") or record.amendment_count == 0 or record.amendment_count > 32 or record.text.len == 0 or record.text.len > 16384 or !std.unicode.utf8ValidateSlice(record.text)) return error.InvalidCompanyTaskAmendment;
    for ([_][]const u8{ record.workspace, record.task, record.view, record.actor, record.grant, record.operation }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyTaskAmendment;
    _ = try authority.hexBytes(32, record.revision);
    _ = try authority.hexBytes(32, record.contract_sha256);
    _ = try authority.hexBytes(32, record.worker_sha256);
    if (!std.mem.eql(u8, filename, try path(alloc, record.task, record.request_hash))) return error.InvalidCompanyTaskAmendment;
}

pub fn pending(manager: workspace.Manager, task: workspace.Task, view: []const u8, operation: []const u8) !bool {
    const binding = task.authority orelse return false;
    const filename = try manager.alloc.print("company/operations/{s}.json", .{try workspace.hash(manager.alloc, try json(manager.alloc, .{ binding.actor, operation }))});
    const journal = try records.decode(struct { request: ?[]const u8 = null }, manager.alloc, try manager.companyContent(filename), .{ .ignore_unknown_fields = true });
    const raw = journal.request orelse return false;
    const envelope = try records.decode(authority.Envelope, manager.alloc, raw, .{});
    const request = try records.decode(authority.Request, manager.alloc, envelope.payload, .{});
    if (request.action != .execute_task or request.content == null or request.view == null) return false;
    if (!std.mem.eql(u8, request.workspace, manager.manifest.id) or !std.mem.eql(u8, request.actor, binding.actor) or !std.mem.eql(u8, request.grant, binding.grant) or !std.mem.eql(u8, request.view.?, view) or !std.mem.eql(u8, request.operation, operation)) return error.CompanyOperationConflict;
    return selected(manager.alloc, request.content.?);
}

pub fn admitted(manager: workspace.Manager, task: workspace.Task, view: []const u8, request: authority.Request, request_hash: []const u8) !bool {
    const filename = try path(manager.alloc, task.id, request_hash);
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (!try manager.companyRecordExists(filename, control)) return false;
    const saved = try records.decode(Record, manager.alloc, try manager.contentAt(filename, control), .{});
    try validateStored(manager.alloc, saved, filename);
    return std.mem.eql(u8, saved.workspace, manager.manifest.id) and std.mem.eql(u8, saved.view, view) and std.mem.eql(u8, saved.actor, request.actor) and std.mem.eql(u8, saved.grant, request.grant) and std.mem.eql(u8, saved.operation, request.operation);
}
fn fault(point: []const u8) !void {
    if (comptime @import("build_options").libfx) return;
    if (io.getenv("FX_E2E_FOSSIL_FAULT")) |selected_point| if (std.mem.eql(u8, selected_point, point)) return error.WorkspaceInjectedFailure;
}

pub fn submit(manager: workspace.Manager, original: workspace.Task, grant: authority.Grant, view: []const u8, request: authority.Request, request_hash: []const u8) ![]const u8 {
    if (!manager.company_operation_held or !authority.permitsAction(grant, .execute_task) or !authority.permitsAction(grant, .submit)) return error.CompanyAccessDenied;
    try authority.authorizeExecution(manager, original);
    try manager.validateTaskBasis(original);
    const text = try command(manager.alloc, request.content orelse return error.InvalidCompanyTaskAmendment);
    const filename = try path(manager.alloc, original.id, request_hash);
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    var saved: Record = undefined;
    if (try manager.companyRecordExists(filename, control)) {
        saved = try records.decode(Record, manager.alloc, try manager.contentAt(filename, control), .{});
        try validateStored(manager.alloc, saved, filename);
        if (!std.mem.eql(u8, saved.view, view) or !std.mem.eql(u8, saved.actor, grant.actor) or !std.mem.eql(u8, saved.grant, grant.id) or !std.mem.eql(u8, saved.operation, request.operation) or !std.mem.eql(u8, saved.text, text)) return error.CompanyOperationConflict;
    } else {
        if (request.revision == null or !std.mem.eql(u8, request.revision.?, try manager.currentRevision(original))) return error.WorkspaceRevisionChanged;
        if (original.revision_pending or original.authority.?.desired != null) return error.InvalidCompanyTaskAmendment;
        if (original.state == .accepted or original.state == .publication_pending or original.state == .conflict) return error.TaskIsReadOnly;
        if (original.review_job) |id| {
            const review = try manager.loadReviewJob(original, id);
            if (review.state == .queued or review.state == .running) return error.TaskReviewInProgress;
        }
        if (original.amendments.len >= 32 or std.mem.eql(u8, text, try manager.originalRequest(original))) return error.InvalidCompanyTaskAmendment;
        for (original.amendments) |previous| if (std.mem.eql(u8, previous, text)) return error.InvalidCompanyTaskAmendment;
        const job = (try runtimes.taskJob(manager, view)) orelse return error.CompanyWorkerNotQueued;
        if (job.state == .completed or job.state == .cancelled) return error.TaskIsReadOnly;
        if (job.invocations >= job.max_invocations) return error.CompanyWorkerInvocationBudget;
        const contract = try workspace.hash(manager.alloc, try json(manager.alloc, .{ .definition = original.definition, .amendments = original.amendments, .request_artifact = original.request_artifact }));
        if (!std.mem.eql(u8, contract, job.binding.contract_sha256)) return error.InvalidCompanyTaskAmendment;
        if (job.state == .running or request.execution != null) {
            const current = try records.decode(ownership.Record, manager.alloc, try manager.companyContent(try ownership.path(manager.alloc, view)), .{});
            try ownership.validate(current, view, original.id, grant);
            try ownership.require(current, request.execution orelse return error.CompanyExecutionFenceRequired, io.milliTimestamp());
        }
        saved = .{ .workspace = manager.manifest.id, .task = original.id, .view = view, .actor = grant.actor, .grant = grant.id, .operation = request.operation, .request_hash = request_hash, .revision = request.revision.?, .contract_sha256 = job.binding.contract_sha256, .worker_sha256 = try workspace.hash(manager.alloc, try manager.companyContent(try jobs.path(manager.alloc, job.id))), .amendment_count = original.amendments.len + 1, .text = text };
        _ = try manager.companyWrite(control, &.{.{ .path = filename, .content = try json(manager.alloc, saved) }});
    }
    try fault("company-amendment-intent");
    // This internal transition preserves the invocation allowance, releases the
    // old execution fence, and is recoverable by its own immutable operation.
    _ = try jobs.administer(manager, .{ .change = .amend, .view = view, .operation = try workspace.hash(manager.alloc, try manager.alloc.print("amend:{s}", .{request_hash})), .expected_sha256 = saved.worker_sha256 });
    try fault("company-amendment-fenced");
    var task = try manager.refreshTaskContext(try manager.loadTask(original.id));
    if (task.amendments.len < saved.amendment_count) task = try manager.amend(task, text);
    if (task.amendments.len != saved.amendment_count or !std.mem.eql(u8, task.amendments[saved.amendment_count - 1], text)) return error.CompanyOperationConflict;
    try fault("company-amendment-applied");
    const planning = try manager.queuePlanning(task, saved.contract_sha256, false);
    return json(manager.alloc, .{ .version = "omos.company-task-amendment-outcome/v1", .view = view, .operation = request.operation, .revision = try manager.currentRevision(task), .state = "planning", .planning_job = planning.id });
}

test "company task amendments require portable explicit updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("Use blue", try command(alloc, "{\"version\":\"omos.company-task-amend/v1\",\"text\":\" Use blue \"}"));
    for ([_][]const u8{ "", "continue", "   " }) |text| try std.testing.expectError(error.InvalidCompanyTaskAmendment, command(alloc, try json(alloc, Command{ .version = "omos.company-task-amend/v1", .text = text })));
    try std.testing.expectError(error.UnknownField, command(alloc, "{\"version\":\"omos.company-task-amend/v1\",\"text\":\"Use blue\",\"grant\":\"owner\"}"));
}
