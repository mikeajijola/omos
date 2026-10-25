//! Durable ownership for external runtimes sharing a company view. The company
//! operation lease serializes these transitions with every scoped mutation.
const std = @import("std");
const authority = @import("company_authority.zig");

pub const Fence = struct { runtime: []const u8, generation: u64 };
pub const Record = struct {
    version: []const u8 = "omos.company-execution/v1",
    view: []const u8,
    task: []const u8,
    actor: []const u8,
    grant: []const u8,
    runtime: ?[]const u8 = null,
    generation: u64 = 0,
    expires_ms: i64 = 0,
    operation: []const u8,
    request_hash: []const u8,
};
pub const Change = enum { claim, renew, release };
pub const maximum_lease_ms = 300000;

pub fn path(alloc: std.mem.Allocator, view: []const u8) ![]const u8 {
    if (!authority.safeIdentity(view)) return error.InvalidCompanyIdentity;
    return alloc.print("company/execution/{s}.json", .{view});
}

pub fn validate(record: Record, view: []const u8, task: []const u8, grant: authority.Grant) !void {
    if (!std.mem.eql(u8, record.version, "omos.company-execution/v1") or !std.mem.eql(u8, record.view, view) or !std.mem.eql(u8, record.task, task) or !std.mem.eql(u8, record.actor, grant.actor) or !std.mem.eql(u8, record.grant, grant.id) or record.generation == 0) return error.InvalidCompanyExecution;
    if (record.runtime) |runtime| if (!authority.safeIdentity(runtime) or record.expires_ms <= 0) return error.InvalidCompanyExecution;
}

pub fn validateStored(alloc: std.mem.Allocator, record: Record, record_path: []const u8) !void {
    if (!std.mem.eql(u8, record.version, "omos.company-execution/v1") or record.generation == 0 or record.expires_ms < 0) return error.InvalidCompanyExecution;
    for ([_][]const u8{ record.view, record.task, record.actor, record.grant, record.operation }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyExecution;
    if (record.runtime) |runtime| {
        if (!authority.safeIdentity(runtime) or record.expires_ms == 0) return error.InvalidCompanyExecution;
    } else if (record.expires_ms != 0) return error.InvalidCompanyExecution;
    _ = try authority.hexBytes(32, record.request_hash);
    if (!std.mem.eql(u8, record_path, try path(alloc, record.view)) and !std.mem.eql(u8, record_path, try alloc.print("company/execution/{s}/{s}.json", .{ record.view, record.request_hash }))) return error.InvalidCompanyExecution;
}

pub fn rejected(err: anyerror) bool {
    return switch (err) {
        error.InvalidCompanyExecution, error.InvalidCompanyExecutionLease, error.CompanyExecutionNotClaimed, error.CompanyExecutionFenceRequired, error.CompanyExecutionFenced, error.CompanyExecutionExpired, error.CompanyExecutionBusy, error.CompanyExecutionGenerationExhausted, error.TaskIsReadOnly => true,
        else => false,
    };
}

/// A tombstone continues to require a new claim. Expiry never restores an
/// unfenced mutation path, and a former owner cannot renew after expiry.
pub fn require(record: ?Record, fence: ?Fence, now: i64) !void {
    const current = record orelse {
        if (fence != null) return error.CompanyExecutionNotClaimed;
        return;
    };
    const supplied = fence orelse return error.CompanyExecutionFenceRequired;
    if (!authority.safeIdentity(supplied.runtime) or current.runtime == null or current.generation != supplied.generation or !std.mem.eql(u8, current.runtime.?, supplied.runtime)) return error.CompanyExecutionFenced;
    if (current.expires_ms <= now) return error.CompanyExecutionExpired;
}

pub fn change(previous: ?Record, mode: Change, fence: Fence, lease_ms: ?u32, now: i64, grant: authority.Grant, view: []const u8, task: []const u8, operation: []const u8, request_hash: []const u8) !Record {
    if (!authority.safeIdentity(fence.runtime)) return error.InvalidCompanyIdentity;
    if (previous) |current| try validate(current, view, task, grant);
    var next = previous orelse Record{ .view = view, .task = task, .actor = grant.actor, .grant = grant.id, .operation = operation, .request_hash = request_hash };
    // Recover a committed transition by its exact request identity. Replaying
    // it doesn't renew its expiry or acquire a newer generation.
    if (previous != null and std.mem.eql(u8, next.operation, operation)) {
        if (!std.mem.eql(u8, next.request_hash, request_hash)) return error.CompanyOperationConflict;
        return next;
    }
    if (mode == .claim) {
        if (fence.generation != next.generation) return error.CompanyExecutionFenced;
        if (next.runtime != null and next.expires_ms > now) return error.CompanyExecutionBusy;
        next.generation = std.math.add(u64, next.generation, 1) catch return error.CompanyExecutionGenerationExhausted;
        next.runtime = fence.runtime;
    } else {
        try require(previous, fence, now);
        if (previous == null) return error.CompanyExecutionNotClaimed;
    }
    if (mode == .release) {
        if (lease_ms != null) return error.InvalidCompanyExecutionLease;
        next.runtime = null;
        next.expires_ms = 0;
    } else {
        const duration = lease_ms orelse return error.InvalidCompanyExecutionLease;
        if (duration == 0 or duration > maximum_lease_ms) return error.InvalidCompanyExecutionLease;
        next.expires_ms = @min(std.math.add(i64, now, duration) catch return error.InvalidCompanyExecutionLease, grant.expires_ms);
        if (next.expires_ms <= now) return error.CompanyAccessRevoked;
    }
    next.operation = operation;
    next.request_hash = request_hash;
    return next;
}

test "company execution ownership expires, transfers and fences every former runtime" {
    const grant: authority.Grant = .{ .id = "grant", .actor = "actor", .public_key = "public", .paths = &.{"documents/"}, .actions = &.{.checkpoint}, .expires_ms = 10000 };
    const first = try change(null, .claim, .{ .runtime = "first", .generation = 0 }, 1000, 100, grant, "view", "task", "claim-first", "hash-first");
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expectError(error.CompanyExecutionFenceRequired, require(first, null, 101));
    try require(first, .{ .runtime = "first", .generation = 1 }, 101);
    try std.testing.expectError(error.CompanyExecutionBusy, change(first, .claim, .{ .runtime = "second", .generation = 1 }, 1000, 101, grant, "view", "task", "claim-second", "hash-second"));
    try std.testing.expectError(error.CompanyExecutionExpired, require(first, .{ .runtime = "first", .generation = 1 }, 1100));
    try std.testing.expectError(error.CompanyExecutionExpired, change(first, .renew, .{ .runtime = "first", .generation = 1 }, 1000, 1100, grant, "view", "task", "late-renewal", "hash-late"));
    const second = try change(first, .claim, .{ .runtime = "second", .generation = 1 }, 1000, 1100, grant, "view", "task", "claim-second", "hash-second");
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectError(error.CompanyExecutionFenced, require(second, .{ .runtime = "first", .generation = 1 }, 1101));
    const released = try change(second, .release, .{ .runtime = "second", .generation = 2 }, null, 1101, grant, "view", "task", "release", "hash-release");
    try std.testing.expectError(error.CompanyExecutionFenceRequired, require(released, null, 1102));
    const third = try change(released, .claim, .{ .runtime = "third", .generation = 2 }, 1000, 1102, grant, "view", "task", "claim-third", "hash-third");
    try std.testing.expectEqual(@as(u64, 3), third.generation);
    const retried = try change(third, .claim, .{ .runtime = "third", .generation = 2 }, 1000, 1200, grant, "view", "task", "claim-third", "hash-third");
    try std.testing.expectEqual(third.expires_ms, retried.expires_ms);
    try std.testing.expectError(error.CompanyOperationConflict, change(third, .claim, .{ .runtime = "third", .generation = 2 }, 1000, 1200, grant, "view", "task", "claim-third", "different"));
    try std.testing.expectError(error.CompanyExecutionFenced, require(third, .{ .runtime = "second", .generation = 2 }, 1200));
}
