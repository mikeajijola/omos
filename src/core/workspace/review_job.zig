//! Durable review scheduling identities. Model output cannot acquire a lease
//! or authorize publication. The manager persists and fences these records.
const std = @import("std");
const contract = @import("../agent/runtime/work_contract.zig");

pub const Job = struct {
    version: []const u8 = "omos.review-job/v1",
    id: []const u8,
    task: []const u8,
    contract_version: u32,
    definition_hash: []const u8,
    candidate_hash: []const u8,
    kind: enum { completion, planning } = .completion,
    planning_contract_sha256: ?[]const u8 = null,
    planning_definition: ?contract.Definition = null,
    planning_amendments: ?usize = null,
    workspace_definition_hash: []const u8 = "",
    workspace_definition_revision: []const u8 = "",
    state: enum { queued, running, pending, changes_required, blocked, published, failed, planned } = .queued,
    generation: u64 = 0,
    owner: []const u8 = "",
    lease_expires_ms: i64 = 0,
    attempts: usize = 0,
    reason: []const u8 = "",
    review_attempts: usize = 0,
    reported_tokens: u64 = 0,
    started_ms: i64 = 0,
    budget_epoch: u64 = 1,
};

pub const Fence = struct { task: []const u8, job: []const u8, owner: []const u8, generation: u64 };

pub fn owns(job: Job, fence: Fence, now_ms: i64) bool {
    return job.state == .running and std.mem.eql(u8, job.task, fence.task) and std.mem.eql(u8, job.id, fence.job) and
        std.mem.eql(u8, job.owner, fence.owner) and job.generation == fence.generation and job.lease_expires_ms > now_ms;
}

test "review jobs reject stale generations and expired publication leases" {
    var job: Job = .{ .id = "job", .task = "task", .contract_version = 1, .definition_hash = "definition", .candidate_hash = "candidate", .state = .running, .generation = 2, .owner = "worker", .lease_expires_ms = 100 };
    const fence: Fence = .{ .task = "task", .job = "job", .owner = "worker", .generation = 2 };
    try std.testing.expect(owns(job, fence, 99));
    try std.testing.expect(!owns(job, fence, 100));
    job.generation = 3;
    try std.testing.expect(!owns(job, fence, 99));
    job.generation = 2;
    job.state = .published;
    try std.testing.expect(!owns(job, fence, 99));
}
