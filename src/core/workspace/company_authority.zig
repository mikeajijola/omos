//! Live company authority. Content revisions remain pinned while grants and
//! revocation are checked again for every operation, including publication.
const std = @import("std");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");

pub const Action = enum { discover, read, create_view, checkpoint, submit, status, export_scope, delegate, reconcile, query, record, execution };

pub fn isMutation(action: Action) bool {
    return switch (action) {
        .create_view, .checkpoint, .submit, .delegate, .reconcile, .record, .execution => true,
        .discover, .read, .status, .export_scope, .query => false,
    };
}
pub const Grant = struct {
    id: []const u8,
    actor: []const u8,
    public_key: []const u8,
    paths: []const []const u8,
    actions: []const Action,
    expires_ms: i64,
    parent: ?[]const u8 = null,
    revoked: bool = false,
    human_approval: bool = false,
};
pub const State = struct {
    version: []const u8 = "omos.company-authority/v1",
    workspace: []const u8,
    epoch: u64 = 1,
    issuer: []const u8,
    grants: []const Grant = &.{},
};
pub const Binding = struct { actor: []const u8, grant: []const u8 };
pub const Envelope = struct { payload: []const u8, signature: []const u8 };
pub const Upload = struct { sha256: []const u8, bytes: usize };
pub const CapabilitySelection = struct { capability: []const u8, realisation: ?[]const u8 = null };
pub const Request = struct {
    version: []const u8,
    workspace: []const u8,
    actor: []const u8,
    grant: []const u8,
    operation: []const u8,
    expires_ms: i64,
    action: Action,
    view: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    path: ?[]const u8 = null,
    offset: usize = 0,
    limit: usize = 16384,
    content: ?[]const u8 = null,
    encoding: enum { utf8, base64 } = .utf8,
    remove: bool = false,
    previous_hash: ?[]const u8 = null,
    executable: ?bool = null,
    previous_executable: ?bool = null,
    upload: ?Upload = null,
    objective: ?[]const u8 = null,
    candidate: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    delegated_grant: ?Grant = null,
    delegated_capabilities: ?[]const []const u8 = null,
    entity: ?[]const u8 = null,
    capability: ?[]const u8 = null,
    realisation: ?[]const u8 = null,
    capability_selections: ?[]const CapabilitySelection = null,
    scope: ?[]const []const u8 = null,
    record_id: ?[]const u8 = null,
    progress_cursor: ?[]const u8 = null,
    execution: ?@import("company_execution.zig").Fence = null,
    execution_change: ?@import("company_execution.zig").Change = null,
    execution_lease_ms: ?u32 = null,
};

/// Version 2 adds authenticated file attributes to read-only file operations.
/// Existing mutation and record protocols retain their version 1 semantics.
pub fn supportedRequestVersion(request: Request) bool {
    if (std.mem.eql(u8, request.version, "omos.company/v1")) return true;
    if (!std.mem.eql(u8, request.version, "omos.company/v2")) return false;
    return request.action == .discover or request.action == .read or request.action == .export_scope;
}

pub fn hexBytes(comptime size: usize, value: []const u8) ![size]u8 {
    if (value.len != size * 2) return error.InvalidCompanyIdentity;
    var bytes: [size]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, value) catch return error.InvalidCompanyIdentity;
    return bytes;
}

pub fn safeIdentity(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

fn permittedRoot(path: []const u8) bool {
    for ([_][]const u8{ "memory/", "skills/", "documents/", "artifacts/", "ui/", "records/" }) |root| if (std.mem.startsWith(u8, path, root)) return true;
    return false;
}

pub fn validPath(path: []const u8, prefix: bool) bool {
    if (path.len == 0 or path.len > 240 or !permittedRoot(path) or !std.unicode.utf8ValidateSlice(path)) return false;
    const selected = if (prefix and std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    var parts = std.mem.splitScalar(u8, selected, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.') return false;
        for (part) |ch| if (ch < 32 or ch == 127 or ch == '\\') return false;
    }
    return true;
}

pub fn permitsPath(grant: Grant, path: []const u8) bool {
    if (!validPath(path, false)) return false;
    return permitsSelector(grant, path);
}

/// A directory selector requires a grant covering its entire subtree.
pub fn permitsSelector(grant: Grant, path: []const u8) bool {
    if (!validPath(path, std.mem.endsWith(u8, path, "/"))) return false;
    for (grant.paths) |scope| {
        if (std.mem.endsWith(u8, scope, "/")) {
            if (std.mem.startsWith(u8, path, scope)) return true;
        } else if (std.mem.eql(u8, path, scope)) return true;
    }
    return false;
}

pub fn permitsAction(grant: Grant, action: Action) bool {
    for (grant.actions) |allowed| if (allowed == action) return true;
    return false;
}

pub fn liveGrant(state: State, id: []const u8, now: i64) !Grant {
    var selected: ?Grant = null;
    var cursor = id;
    for (0..17) |_| {
        const current = for (state.grants) |grant| {
            if (std.mem.eql(u8, grant.id, cursor)) break grant;
        } else return error.CompanyAccessDenied;
        if (current.revoked or current.expires_ms <= now) return error.CompanyAccessRevoked;
        if (selected == null) selected = current;
        if (current.parent) |parent| cursor = parent else return selected.?;
    }
    return error.InvalidCompanyDelegation;
}

pub fn validateGrant(state: State, grant: Grant, now: i64) !void {
    if (!safeIdentity(grant.id) or !safeIdentity(grant.actor) or grant.expires_ms <= now or grant.paths.len == 0 or grant.paths.len > 128 or grant.actions.len == 0) return error.InvalidCompanyGrant;
    _ = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try hexBytes(32, grant.public_key));
    for (grant.paths) |path| if (!validPath(path, true)) return error.InvalidCompanyScope;
    if (grant.parent) |id| {
        const parent = try liveGrant(state, id, now);
        if (!permitsAction(parent, .delegate) or grant.expires_ms > parent.expires_ms or (parent.human_approval and !grant.human_approval)) return error.CompanyDelegationDenied;
        for (grant.actions) |action| if (!permitsAction(parent, action)) return error.CompanyDelegationDenied;
        for (grant.paths) |path| {
            const covered = for (parent.paths) |scope| {
                if (std.mem.eql(u8, path, scope) or (std.mem.endsWith(u8, scope, "/") and std.mem.startsWith(u8, path, scope))) break true;
            } else false;
            if (!covered) return error.CompanyDelegationDenied;
        }
    }
}

pub fn authenticate(alloc: std.mem.Allocator, state: State, raw: []const u8, now: i64) !Request {
    return authenticateRequest(alloc, state, raw, now, false);
}

/// A fresh signed reconciliation request authorizes an already recorded
/// operation. Its original signature and current grant still apply; an expired
/// transport request cannot authorize a new action by itself.
pub fn authenticateRetained(alloc: std.mem.Allocator, state: State, raw: []const u8, fresh: Request, now: i64) !Request {
    if (fresh.action != .reconcile) return error.CompanyAccessDenied;
    const original = try authenticateRequest(alloc, state, raw, now, true);
    if (!std.mem.eql(u8, fresh.actor, original.actor) or !std.mem.eql(u8, fresh.grant, original.grant) or fresh.outcome == null or !std.mem.eql(u8, fresh.outcome.?, original.operation)) return error.CompanyAccessDenied;
    if (original.action != .create_view and original.action != .checkpoint and original.action != .record and original.action != .submit and original.action != .delegate and original.action != .execution) return error.CompanyRecoveryActionDenied;
    return original;
}

fn authenticateRequest(alloc: std.mem.Allocator, state: State, raw: []const u8, now: i64, retained: bool) !Request {
    if (raw.len > 1024 * 1024) return error.ServiceRequestTooLarge;
    const envelope = try records.decode(Envelope, alloc, raw, .{});
    const request = try records.decode(Request, alloc, envelope.payload, .{});
    if (!supportedRequestVersion(request) or !std.mem.eql(u8, request.workspace, state.workspace)) return error.WorkspaceIdentityMismatch;
    if (!safeIdentity(request.operation) or !safeIdentity(request.actor)) return error.InvalidCompanyIdentity;
    if (!retained and (request.expires_ms <= now or request.expires_ms > now + 300000)) return error.CompanyRequestExpired;
    const grant = try liveGrant(state, request.grant, now);
    if (!std.mem.eql(u8, grant.actor, request.actor) or !permitsAction(grant, request.action)) return error.CompanyAccessDenied;
    const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try hexBytes(32, grant.public_key));
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(try hexBytes(64, envelope.signature));
    signature.verifyStrict(envelope.payload, public) catch return error.CompanySignatureRejected;
    return request;
}

pub fn authorizeTask(manager: workspace.Manager, task: workspace.Task) !void {
    return authorizeTaskFor(manager, task, true);
}

pub fn authorizeExecution(manager: workspace.Manager, task: workspace.Task) !void {
    return authorizeTaskFor(manager, task, false);
}

fn authorizeTaskFor(manager: workspace.Manager, task: workspace.Task, publication: bool) !void {
    const binding = task.authority orelse return;
    const state = try records.decode(State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    _ = try @import("company_keys.zig").current(manager, state.epoch, state.issuer);
    const grant = try @import("company_task_scope.zig").forTask(manager, task, try liveGrant(state, binding.grant, @import("../shared/io.zig").milliTimestamp()));
    if (!std.mem.eql(u8, binding.actor, grant.actor) or !permitsAction(grant, if (publication) .submit else .execution)) return error.CompanyAccessDenied;
    if (publication and grant.human_approval) _ = try @import("company_approval.zig").authorize(manager, task, try manager.currentRevision(task), (try manager.companyRevision()).?, state, @import("../shared/io.zig").milliTimestamp());
    for (try manager.changedPaths(task.base_revision, try manager.currentRevision(task))) |path| {
        if (!permittedRoot(path)) continue;
        // A long signed objective is retained by the host as an immutable
        // request artifact. It is contract data, not an actor content mutation.
        if (task.request_artifact) |request| if (std.mem.eql(u8, request, path)) continue;
        if (!permitsPath(grant, path)) return error.CompanyAccessDenied;
    }
}

test "company authority enforces boundaries, delegation, ancestor revocation and request signatures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(7));
    const public = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    const grant: Grant = .{ .id = "root", .actor = "alice", .public_key = &public, .paths = &.{"documents/team/"}, .actions = &.{ .read, .delegate, .checkpoint }, .expires_ms = 10000 };
    var state: State = .{ .workspace = "company", .issuer = &public, .grants = &.{grant} };
    try validateGrant(state, grant, 1);
    try std.testing.expect(permitsPath(grant, "documents/team/report.md"));
    try std.testing.expect(permitsSelector(grant, "documents/team/"));
    try std.testing.expect(!permitsSelector(grant, "documents/"));
    try std.testing.expect(!permitsPath(grant, "documents/team/"));
    try std.testing.expect(!permitsPath(grant, "documents/team-private/report.md"));
    try std.testing.expect(!permitsPath(grant, "documents/team/../secret.md"));
    var child = grant;
    child.id = "child";
    child.actor = "bob";
    child.parent = "root";
    child.paths = &.{"documents/team/report.md"};
    try validateGrant(state, child, 1);
    child.paths = &.{"documents/other/"};
    try std.testing.expectError(error.CompanyDelegationDenied, validateGrant(state, child, 1));
    child.paths = &.{"documents/team/report.md"};
    const grants = try alloc.dupe(Grant, &.{ grant, child });
    state.grants = grants;
    grants[0].revoked = true;
    try std.testing.expectError(error.CompanyAccessRevoked, liveGrant(state, "child", 1));
    grants[0].revoked = false;
    const payload = try std.json.Stringify.valueAlloc(alloc, Request{ .version = "omos.company/v1", .workspace = "company", .actor = "alice", .grant = "root", .operation = "once", .expires_ms = 5000, .action = .read }, .{});
    const signed = try key.sign(payload, null);
    const signature = std.fmt.bytesToHex(signed.toBytes(), .lower);
    const envelope = try std.json.Stringify.valueAlloc(alloc, Envelope{ .payload = payload, .signature = &signature }, .{});
    _ = try authenticate(alloc, state, envelope, 1);
    try std.testing.expectError(error.CompanyRequestExpired, authenticate(alloc, state, envelope, 5000));
    const bad = try std.json.Stringify.valueAlloc(alloc, Envelope{ .payload = try alloc.print("{s} ", .{payload}), .signature = &signature }, .{});
    try std.testing.expectError(error.CompanySignatureRejected, authenticate(alloc, state, bad, 1));
}

test "company authority limits version 2 to file metadata reads" {
    var request: Request = .{ .version = "omos.company/v2", .workspace = "company", .actor = "alice", .grant = "grant", .operation = "read", .expires_ms = 10000, .action = .read };
    try std.testing.expect(supportedRequestVersion(request));
    request.action = .checkpoint;
    try std.testing.expect(!supportedRequestVersion(request));
    request.version = "omos.company/v1";
    try std.testing.expect(supportedRequestVersion(request));
    request.version = "omos.company/v3";
    try std.testing.expect(!supportedRequestVersion(request));
}
