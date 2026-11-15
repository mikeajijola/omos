//! One contract-derived decision for scheduling and channel status. Publication
//! receipts outrank worker bookkeeping; ownership still requires the task lease.
const std = @import("std");
const background = @import("background_contract.zig");
const workspace = @import("fossil_workspace.zig");
const io = @import("../shared/io.zig");

pub const Decision = struct {
    version: []const u8 = "omos.contract-execution/v1",
    phase: enum { preparing, queued, executing, awaiting_input, awaiting_validation, reviewing, publishing, retry_wait, attention, cancelled, superseded, completed },
    next: enum { none, execute, recover, publish, reconcile },
    reason: []const u8,
    retry_at_ms: ?i64 = null,
    recovery_attempts: u32,
    recovery_limit: usize,
    state_since_ms: i64,
};

const Facts = struct {
    task_state: @FieldType(workspace.Task, "state"),
    publication_pending: bool = false,
    review_candidate: bool = false,
    recovery_limit: usize = 3,
    review_retry_allowed: bool = true,
};

pub fn inspect(manager: workspace.Manager, task: workspace.Task, entry: background.Record) !Decision {
    var facts: Facts = .{ .task_state = task.state };
    if (task.state == .accepted or task.state == .publication_pending)
        facts.publication_pending = try manager.publicationPending(task);
    const retry = entry.retry orelse background.retryFor(entry.reason, entry.recoveries, entry.updated_ms);
    if (task.model_basis) |basis| {
        facts.recovery_limit = if (retry != null and retry.?.kind == .review) basis.execution.review.max_attempts else basis.execution.defaults.stalled_checks;
        facts.review_retry_allowed = basis.execution.review.max_tokens == null;
    }
    // Candidate inspection can scan retained evidence. Only a review retry
    // needs it; execution resumes reconcile the same evidence in the agent loop.
    if (entry.state == .waiting and retry != null and retry.?.kind == .review and
        task.state != .blocked and task.state != .conflict and task.state != .accepted and task.state != .publication_pending)
        facts.review_candidate = try manager.retainedReviewCandidate(task) != null;
    return decide(entry, facts, io.milliTimestamp());
}

fn decide(entry: background.Record, facts: Facts, now: i64) Decision {
    var result: Decision = .{ .phase = .attention, .next = .none, .reason = "Work is retained and needs a changed approach or new input.", .recovery_attempts = entry.recoveries, .recovery_limit = facts.recovery_limit, .state_since_ms = entry.updated_ms };
    if (facts.task_state == .accepted and !facts.publication_pending) {
        result.phase = .completed;
        result.next = if (entry.state == .completed) .none else .reconcile;
        result.reason = "The contract has a verified publication; no execution is needed.";
        return result;
    }
    if (entry.state == .superseded) {
        result.phase = .superseded;
        result.reason = "A newer contract owns this work.";
        return result;
    }
    if (entry.cancel_requested or entry.state == .cancelled) {
        result.phase = .cancelled;
        result.reason = "Execution was cancelled. Retained results remain available.";
        return result;
    }
    if (facts.task_state == .blocked or facts.task_state == .conflict) {
        result.reason = if (facts.task_state == .conflict) "Publication conflicts with current workspace state. Resolve the conflict before resuming." else "The contract is blocked and needs input before execution can continue.";
        return result;
    }
    if (entry.state == .prepared) {
        result.phase = .preparing;
        result.reason = "Waiting for the foreground checkpoint before dispatch.";
        return result;
    }
    const retry = entry.retry orelse background.retryFor(entry.reason, entry.recoveries, entry.updated_ms);
    if (facts.publication_pending or facts.task_state == .publication_pending) {
        result.phase = .publishing;
        result.next = .publish;
        result.reason = "The reviewed result is retained. Finish publication without repeating actor actions.";
        if (retry) |pending| if (pending.kind == .publication) {
            if (entry.recoveries >= facts.recovery_limit) {
                result.phase = .attention;
                result.next = .none;
                result.reason = "Publication retries reached the contract's recovery limit. Results are retained.";
            } else if (now < pending.due_ms) {
                result.phase = .retry_wait;
                result.next = .none;
                result.retry_at_ms = pending.due_ms;
                result.reason = "Waiting for the scheduled publication retry; no worker slot is occupied.";
            }
        };
        return result;
    }
    switch (entry.state) {
        .queued => {
            result.phase = .queued;
            result.next = .execute;
            result.reason = "The contract is queued, waiting for a worker slot and its task lease.";
        },
        .starting, .running => {
            result.phase = .executing;
            result.reason = "An invocation owns this work. The host checks its task lease before any recovery.";
            if (entry.wait_condition) |condition| {
                result.phase = if (condition == .input) .awaiting_input else .awaiting_validation;
                result.reason = if (condition == .input) "The worker needs your answer before it can continue." else "The worker is waiting for interface validation.";
            }
        },
        .waiting => if (retry) |pending| {
            if (entry.recoveries >= facts.recovery_limit) {
                result.reason = "Automatic recovery reached the contract's limit. Work and evidence are retained.";
            } else if (pending.kind == .review and (!facts.review_candidate or !facts.review_retry_allowed)) {
                result.reason = "Review needs a retained candidate and available contract review budget.";
            } else if (pending.kind == .execution and entry.worker_session == null) {
                result.reason = "No retained session exists to reconcile interrupted execution.";
            } else {
                result.phase = if (now < pending.due_ms) .retry_wait else if (pending.kind == .review) .reviewing else .queued;
                result.next = if (now < pending.due_ms) .none else .recover;
                result.retry_at_ms = pending.due_ms;
                result.reason = if (pending.kind == .review) "Retry independent review of the retained answer without repeating actor work." else "Resume retained execution and reconcile uncertain outcomes before any new action.";
            }
        },
        else => {},
    }
    return result;
}

test "contract execution publication outranks stale worker state" {
    const entry: background.Record = .{ .workspace = "", .task = "", .operation = "", .request_sha256 = "", .dispatcher_session = "", .contract_version = 1, .contract_sha256 = "", .updated_ms = 1, .state = .waiting };
    const published = decide(entry, .{ .task_state = .accepted }, 2);
    try std.testing.expectEqual(.reconcile, published.next);
    try std.testing.expectEqual(.completed, published.phase);
    const pending = decide(entry, .{ .task_state = .publication_pending, .publication_pending = true }, 2);
    try std.testing.expectEqual(.publish, pending.next);
}

test "contract execution retries respect due time cancellation and pinned limits" {
    var entry: background.Record = .{ .workspace = "", .task = "", .operation = "", .request_sha256 = "", .dispatcher_session = "", .contract_version = 1, .contract_sha256 = "", .updated_ms = 1, .state = .waiting, .worker_session = "session", .retry = .{ .kind = .execution, .due_ms = 100 } };
    try std.testing.expectEqual(.retry_wait, decide(entry, .{ .task_state = .paused }, 99).phase);
    try std.testing.expectEqual(.recover, decide(entry, .{ .task_state = .paused }, 100).next);
    entry.recoveries = 3;
    try std.testing.expectEqual(.none, decide(entry, .{ .task_state = .paused }, 100).next);
    entry.recoveries = 0;
    entry.cancel_requested = true;
    try std.testing.expectEqual(.cancelled, decide(entry, .{ .task_state = .publication_pending }, 100).phase);
    entry.cancel_requested = false;
    try std.testing.expectEqual(.none, decide(entry, .{ .task_state = .blocked }, 100).next);
    try std.testing.expectEqual(.none, decide(entry, .{ .task_state = .conflict }, 100).next);
}

test "contract execution review requires retained evidence and budget" {
    const entry: background.Record = .{ .workspace = "", .task = "", .operation = "", .request_sha256 = "", .dispatcher_session = "", .contract_version = 1, .contract_sha256 = "", .updated_ms = 1, .state = .waiting, .retry = .{ .kind = .review, .due_ms = 100 } };
    try std.testing.expectEqual(.none, decide(entry, .{ .task_state = .paused }, 100).next);
    try std.testing.expectEqual(.recover, decide(entry, .{ .task_state = .paused, .review_candidate = true }, 100).next);
    try std.testing.expectEqual(.none, decide(entry, .{ .task_state = .paused, .review_candidate = true, .review_retry_allowed = false }, 100).next);
}
