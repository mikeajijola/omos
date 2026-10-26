//! Resume only independent verification of a retained company candidate.
//! Admission survives interruption without another actor invocation.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const io = @import("../shared/io.zig");

pub const prefix = "company/review-resumes/";
pub const Record = struct {
    version: []const u8 = "omos.company-review-resume/v1",
    workspace: []const u8,
    task: []const u8,
    view: []const u8,
    actor: []const u8,
    grant: []const u8,
    operation: []const u8,
    request_hash: []const u8,
    revision: []const u8,
    contract_sha256: []const u8,
    review: struct { id: []const u8, generation: u64, budget_epoch: u64, candidate_hash: []const u8, allocate_budget: bool },
};
fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn path(alloc: std.mem.Allocator, task: []const u8, request_hash: []const u8) ![]const u8 {
    if (!authority.safeIdentity(task)) return error.InvalidCompanyReviewResume;
    _ = try authority.hexBytes(32, request_hash);
    return alloc.print("{s}{s}/{s}.json", .{ prefix, task, request_hash });
}
pub fn supported(declaration: model.Declaration) bool {
    if (!model.hasOperation(declaration, "omos_company_resume_verification")) return false;
    for (declaration.semantic.entityTypes) |entity| if (std.mem.eql(u8, entity.id, "omos_company_review_resume")) return true;
    return false;
}
pub fn validateStored(alloc: std.mem.Allocator, value: Record, filename: []const u8) !void {
    if (!std.mem.eql(u8, value.version, "omos.company-review-resume/v1") or value.review.budget_epoch == 0) return error.InvalidCompanyReviewResume;
    for ([_][]const u8{ value.workspace, value.task, value.view, value.actor, value.grant, value.operation }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyReviewResume;
    for ([_][]const u8{ value.revision, value.contract_sha256, value.review.id, value.review.candidate_hash }) |digest| _ = try authority.hexBytes(32, digest);
    if (!std.mem.eql(u8, filename, try path(alloc, value.task, value.request_hash))) return error.InvalidCompanyReviewResume;
}
pub fn eligible(manager: workspace.Manager, task: workspace.Task) !bool {
    if (task.revision_pending or task.state == .accepted or task.state == .publication_pending or task.state == .conflict) return false;
    const review = try manager.loadReviewJob(task, task.review_job orelse return false);
    return review.kind == .completion and (review.state == .pending or review.state == .failed or review.state == .queued or review.state == .running);
}
pub fn admitted(manager: workspace.Manager, task: workspace.Task, view: []const u8, request: authority.Request, request_hash: []const u8) !bool {
    const filename = try path(manager.alloc, task.id, request_hash);
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (!try manager.companyRecordExists(filename, control)) return false;
    const value = try records.decode(Record, manager.alloc, try manager.contentAt(filename, control), .{});
    try validateStored(manager.alloc, value, filename);
    return std.mem.eql(u8, value.workspace, manager.manifest.id) and std.mem.eql(u8, value.view, view) and std.mem.eql(u8, value.actor, request.actor) and std.mem.eql(u8, value.grant, request.grant) and std.mem.eql(u8, value.operation, request.operation);
}
pub fn pending(manager: workspace.Manager, task: workspace.Task, view: []const u8, operation: []const u8) !bool {
    const binding = task.authority orelse return false;
    const filename = try manager.alloc.print("company/operations/{s}.json", .{try workspace.hash(manager.alloc, try json(manager.alloc, .{ binding.actor, operation }))});
    const journal = try records.decode(struct { request: ?[]const u8 = null }, manager.alloc, try manager.companyContent(filename), .{ .ignore_unknown_fields = true });
    const envelope = try records.decode(authority.Envelope, manager.alloc, journal.request orelse return false, .{});
    const request = try records.decode(authority.Request, manager.alloc, envelope.payload, .{});
    if (request.action != .execute_task or request.content != null or request.view == null or !std.mem.eql(u8, request.view.?, view)) return false;
    return admitted(manager, task, view, request, try workspace.hash(manager.alloc, envelope.payload));
}
fn contractHash(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    return workspace.hash(manager.alloc, try json(manager.alloc, .{ task.definition, task.model_basis }));
}
fn fault() !void {
    if (comptime @import("build_options").libfx) return;
    if (io.getenv("FX_E2E_FOSSIL_FAULT")) |point| if (std.mem.eql(u8, point, "company-review-resume-intent")) return error.WorkspaceInjectedFailure;
}
pub fn submit(manager: workspace.Manager, original: workspace.Task, grant: authority.Grant, view: []const u8, request: authority.Request, request_hash: []const u8) ![]const u8 {
    if (!manager.company_operation_held or !authority.permitsAction(grant, .execute_task) or !authority.permitsAction(grant, .submit)) return error.CompanyAccessDenied;
    try authority.authorizePlanning(manager, original);
    try manager.validateTaskBasis(original);
    const filename = try path(manager.alloc, original.id, request_hash);
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    var saved: Record = undefined;
    if (try manager.companyRecordExists(filename, control)) {
        saved = try records.decode(Record, manager.alloc, try manager.contentAt(filename, control), .{});
        try validateStored(manager.alloc, saved, filename);
        if (!std.mem.eql(u8, saved.view, view) or !std.mem.eql(u8, saved.actor, grant.actor) or !std.mem.eql(u8, saved.grant, grant.id) or !std.mem.eql(u8, saved.operation, request.operation)) return error.CompanyOperationConflict;
    } else {
        if (request.revision == null or !std.mem.eql(u8, request.revision.?, try manager.currentRevision(original))) return error.WorkspaceRevisionChanged;
        if (!try eligible(manager, original)) return error.InvalidCompanyReviewResume;
        const review = try manager.loadReviewJob(original, original.review_job.?);
        const candidate = (try manager.retainedReviewCandidate(original)) orelse return error.InvalidCompanyReviewResume;
        if (!std.mem.eql(u8, review.candidate_hash, try workspace.hash(manager.alloc, candidate))) return error.InvalidCompanyReviewResume;
        saved = .{ .workspace = manager.manifest.id, .task = original.id, .view = view, .actor = grant.actor, .grant = grant.id, .operation = request.operation, .request_hash = request_hash, .revision = request.revision.?, .contract_sha256 = try contractHash(manager, original), .review = .{ .id = review.id, .generation = review.generation, .budget_epoch = review.budget_epoch, .candidate_hash = review.candidate_hash, .allocate_budget = review.state == .pending or review.state == .failed } };
        _ = try manager.companyWrite(control, &.{.{ .path = filename, .content = try json(manager.alloc, saved) }});
    }
    try fault();
    const lease: ?workspace.ExecutionLease = if (saved.review.allocate_budget) (try manager.tryTaskExecutionLease(original.id)) orelse return error.WorkspaceExecutionBusy else null;
    defer if (lease) |held| held.release();
    const task = try manager.refreshTaskContext(try manager.loadTask(original.id));
    if (!std.mem.eql(u8, saved.contract_sha256, try contractHash(manager, task))) return error.StaleWorkContract;
    var review = try manager.loadReviewJob(task, task.review_job orelse saved.review.id);
    if (review.kind != .completion or !std.mem.eql(u8, review.candidate_hash, saved.review.candidate_hash) or review.contract_version != task.definition.version) return error.InvalidCompanyReviewResume;
    const advanced = !std.mem.eql(u8, review.id, saved.review.id) or review.generation > saved.review.generation or review.budget_epoch > saved.review.budget_epoch;
    if (saved.review.allocate_budget and !advanced and task.state != .accepted and task.state != .publication_pending and task.state != .conflict and review.state != .published) {
        if (review.state != .pending and review.state != .failed) return error.InvalidCompanyReviewResume;
        review = try manager.queueReview(task);
    }
    var outcome = try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try @import("company_runtime.zig").taskStatus(manager, grant, task, view), .{});
    try outcome.object.put(manager.alloc, "verification", try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try json(manager.alloc, .{ .id = review.id, .state = @tagName(review.state), .generation = review.generation, .budget_epoch = review.budget_epoch }), .{}));
    const bytes = try json(manager.alloc, outcome);
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    try model.validateOperation(manager.alloc, declaration, "omos_company_resume_verification", outcome, .output);
    return bytes;
}
