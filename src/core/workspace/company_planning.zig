//! Read-only company planning shares durable auxiliary leases and never owns an
//! actor executor. A plan strengthens the original contract before dispatch.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const jobs = @import("review_job.zig");
const managed = @import("managed_task.zig");
const governance = @import("task_governance.zig");
const model = @import("definition.zig");
const streams = @import("../agent/stream_provider.zig");
const records = @import("../shared/record_json.zig");
const io = @import("../shared/io.zig");

pub fn supported(declaration: model.Declaration) bool {
    for (model.items(model.spec(declaration.value), "operations")) |operation| if (std.mem.eql(u8, model.text(operation, "id"), "omos_record_review_job")) {
        const input = model.field(operation, "input") orelse return false;
        const properties = model.field(input, "properties") orelse return false;
        return model.field(properties, "kind") != null and model.field(properties, "planning_definition") != null and model.field(properties, "planning_contract_sha256") != null;
    };
    return false;
}

fn discard(_: *anyopaque, _: streams.Event) void {}

pub fn perform(original: workspace.Manager, job: jobs.Job, provider: anytype) !void {
    if (job.kind != .planning) return error.InvalidReviewJob;
    var manager = original;
    manager.expected_revision = null;
    manager.review_fence = .{ .task = job.task, .job = job.id, .generation = job.generation, .owner = job.owner };
    const execution = (try manager.tryTaskExecutionLease(job.task)) orelse return error.WorkspaceExecutionBusy;
    defer execution.release();
    var task = try manager.refreshTaskContext(try manager.loadTask(job.task));
    try manager.validateTaskBasis(task);
    try @import("company_authority.zig").authorizeExecution(manager, task);
    const basis = task.model_basis orelse return error.WorkspaceMigrationRequired;
    if (!std.mem.eql(u8, basis.definition_hash, job.definition_hash)) return error.StaleWorkspaceDefinition;
    // A crash after the atomic plan/job commit needs no second model call.
    if (basis.capability != null) {
        try manager.finishPlanning(job);
        return;
    }
    const policy = basis.execution.review;
    const remaining_ms = @max(1, @as(i64, policy.total_timeout_ms) - @max(0, io.milliTimestamp() - job.started_ms));
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(@min(remaining_ms, policy.attempt_timeout_ms)) });
    manager.operation_control = .{ .cancel = provider.cancel, .deadline = deadline };
    if (!try manager.beginReviewAttempt(job)) return;
    var turn: managed.Turn = .{ .manager = manager, .task = task };
    const authority = @import("company_authority.zig");
    const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const grant = try @import("company_task_scope.zig").forTask(manager, task, try authority.liveGrant(state, task.authority.?.grant, io.milliTimestamp()));
    const packet = try std.json.Stringify.valueAlloc(manager.alloc, .{ .originalRequest = try manager.originalRequest(task), .amendments = task.amendments, .contract = task.definition, .model = try manager.definitionSnapshot(task), .step = @as(usize, 0), .authority = .{ .scope = "company_task", .paths = grant.paths, .actor_execution = "not_started" } }, .{});
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    const reply = try governance.plan(manager.alloc, provider.provider, .{
        .credential = provider.credential,
        .model = provider.model,
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .required,
        .provider_options = .{},
        .trace_ctx = .{},
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = discard },
        .cancel_flag = provider.cancel,
        .content_capture_limit = 64 * 1024,
    }, provider.provider_id, packet, turn.journal());
    const reported = job.reported_tokens +| (reply.usage.input_tokens orelse 0) +| (reply.usage.output_tokens orelse 0);
    try turn.journal().record("review_usage", try std.json.Stringify.valueAlloc(manager.alloc, .{ .reported_tokens = reported }, .{}));
    if (policy.max_tokens) |limit| if (reported > limit) return error.TaskGovernancePending;
    const plan = try records.decode(governance.Plan, manager.alloc, reply.raw, .{});
    try manager.validateTaskBasis(task);
    try @import("company_authority.zig").authorizeExecution(manager, task);
    task = try manager.setPlan(task, plan.capability, plan.summary, plan.obligations, plan.checks);
    turn.task = task;
    _ = try manager.checkpoint(task);
    try manager.finishPlanning(job);
}
