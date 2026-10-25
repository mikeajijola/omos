//! Capability metadata scopes are host-owned authority. Declaring a capability
//! cannot grant discovery, file retrieval, or execution permissions.
const std = @import("std");
const authority = @import("company_authority.zig");
const model = @import("definition.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");

pub const path = "authority/capabilities.json";
const Entry = struct { grant: []const u8, grant_hash: []const u8, epoch: u64, capabilities: []const []const u8 };
pub const Policy = struct { version: []const u8 = "omos.company-capabilities/v1", workspace: []const u8, entries: []const Entry = &.{} };

fn grantHash(alloc: std.mem.Allocator, grant: authority.Grant) ![]const u8 {
    // Keep this projection stable when other grant representations evolve.
    return workspace.hash(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.capability-grant-binding/v1", .id = grant.id, .actor = grant.actor, .public_key = grant.public_key, .paths = grant.paths, .actions = grant.actions, .expires_ms = grant.expires_ms, .parent = grant.parent, .human_approval = grant.human_approval }, .{}));
}

pub fn decode(alloc: std.mem.Allocator, expected_workspace: []const u8, raw: []const u8) !Policy {
    const policy = try records.decode(Policy, alloc, raw, .{});
    if (!std.mem.eql(u8, policy.version, "omos.company-capabilities/v1") or !std.mem.eql(u8, policy.workspace, expected_workspace) or policy.entries.len > 1024) return error.InvalidCapabilityAuthority;
    for (policy.entries, 0..) |entry, index| {
        if (!authority.safeIdentity(entry.grant) or entry.epoch == 0 or entry.grant_hash.len != 64 or entry.capabilities.len > 256) return error.InvalidCapabilityAuthority;
        for (entry.grant_hash) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidCapabilityAuthority;
        for (policy.entries[0..index]) |previous| if (std.mem.eql(u8, previous.grant, entry.grant)) return error.InvalidCapabilityAuthority;
        for (entry.capabilities, 0..) |capability, selected| {
            if (!authority.safeIdentity(capability)) return error.InvalidCapabilityAuthority;
            for (entry.capabilities[0..selected]) |previous| if (std.mem.eql(u8, previous, capability)) return error.InvalidCapabilityAuthority;
        }
    }
    return policy;
}

pub fn load(manager: workspace.Manager) !Policy {
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision)) |name| if (std.mem.eql(u8, name, path)) return decode(manager.alloc, manager.manifest.id, try manager.contentAt(path, revision));
    // Legacy grants acquire no new metadata authority implicitly.
    return .{ .workspace = manager.manifest.id };
}

pub fn permits(alloc: std.mem.Allocator, policy: Policy, state: authority.State, id: []const u8, capability: []const u8, now: i64) !bool {
    if (!std.mem.eql(u8, policy.workspace, state.workspace)) return error.WorkspaceIdentityMismatch;
    var cursor = id;
    for (0..17) |_| {
        const grant = authority.liveGrant(state, cursor, now) catch return false;
        if (!authority.permitsAction(grant, .discover)) return false;
        const entry = for (policy.entries) |candidate| {
            if (std.mem.eql(u8, candidate.grant, grant.id)) break candidate;
        } else return false;
        if (entry.epoch != state.epoch or !std.mem.eql(u8, entry.grant_hash, try grantHash(alloc, grant))) return false;
        const allowed = for (entry.capabilities) |selected| {
            if (std.mem.eql(u8, selected, capability)) break true;
        } else false;
        if (!allowed) return false;
        cursor = grant.parent orelse return true;
    }
    return error.InvalidCompanyDelegation;
}

/// Retried delegation must not overwrite a scope changed after its first commit.
pub fn matchesAssignment(alloc: std.mem.Allocator, policy: Policy, state: authority.State, id: []const u8, capabilities: []const []const u8, now: i64) !bool {
    const grant = try authority.liveGrant(state, id, now);
    const selected = for (policy.entries) |entry| {
        if (std.mem.eql(u8, entry.grant, id)) break entry;
    } else return capabilities.len == 0;
    if (selected.epoch != state.epoch or !std.mem.eql(u8, selected.grant_hash, try grantHash(alloc, grant)) or selected.capabilities.len != capabilities.len) return false;
    for (capabilities, 0..) |capability, index| {
        for (capabilities[0..index]) |previous| if (std.mem.eql(u8, previous, capability)) return false;
        if (!try permits(alloc, policy, state, id, capability, now)) return false;
    }
    return true;
}

/// An operator can narrow a metadata scope to an empty list. Delegated scopes
/// also require every live ancestor's matching scope before installation.
pub fn assign(alloc: std.mem.Allocator, policy: Policy, state: authority.State, declaration: model.Declaration, grant_id: []const u8, capabilities: []const []const u8, now: i64) !Policy {
    if (!std.mem.eql(u8, policy.workspace, state.workspace) or capabilities.len > 256) return error.InvalidCapabilityAuthority;
    const grant = try authority.liveGrant(state, grant_id, now);
    if (!authority.permitsAction(grant, .discover)) return error.CompanyAccessDenied;
    for (capabilities, 0..) |capability, index| {
        const known = for (model.items(model.spec(declaration.value), "capabilities")) |row| {
            if (std.mem.eql(u8, model.text(row, "id"), capability)) break true;
        } else false;
        if (!known) return error.UnknownCapability;
        for (capabilities[0..index]) |previous| if (std.mem.eql(u8, previous, capability)) return error.DuplicateCapabilitySelection;
        if (grant.parent) |parent| if (!try permits(alloc, policy, state, parent, capability, now)) return error.CompanyDelegationDenied;
    }
    var entries: std.ArrayList(Entry) = .empty;
    for (policy.entries) |entry| if (!std.mem.eql(u8, entry.grant, grant_id)) try entries.append(alloc, entry);
    if (entries.items.len >= 1024) return error.InvalidCapabilityAuthority;
    try entries.append(alloc, .{ .grant = grant.id, .grant_hash = try grantHash(alloc, grant), .epoch = state.epoch, .capabilities = try alloc.dupe([]const u8, capabilities) });
    return .{ .workspace = policy.workspace, .entries = entries.items };
}

test "company capability scopes require explicit grants and follow delegation, scope removal, identity and epoch changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = authority.Grant{ .id = "root", .actor = "owner", .public_key = "root-key", .paths = &.{"skills/"}, .actions = &.{ .discover, .delegate }, .expires_ms = 10000 };
    var child = root;
    child.id = "child";
    child.actor = "worker";
    child.parent = root.id;
    const state = authority.State{ .workspace = "company", .issuer = "issuer", .grants = &.{ root, child } };
    const declaration = try model.parse(a, model.seed);
    var policy = Policy{ .workspace = state.workspace };
    try std.testing.expect(!try permits(a, policy, state, root.id, "general_task", 1));
    try std.testing.expectError(error.CompanyDelegationDenied, assign(a, policy, state, declaration, child.id, &.{"general_task"}, 1));
    policy = try assign(a, policy, state, declaration, root.id, &.{ "general_task", "coding_task" }, 1);
    policy = try assign(a, policy, state, declaration, child.id, &.{"general_task"}, 1);
    try std.testing.expect(try permits(a, policy, state, child.id, "general_task", 1));
    try std.testing.expect(!try permits(a, policy, state, child.id, "coding_task", 1));
    try std.testing.expect(try matchesAssignment(a, policy, state, child.id, &.{"general_task"}, 1));
    policy = try assign(a, policy, state, declaration, child.id, &.{ "general_task", "coding_task" }, 1);
    try std.testing.expect(!try matchesAssignment(a, policy, state, child.id, &.{ "general_task", "general_task" }, 1));
    try std.testing.expect(try matchesAssignment(a, policy, state, child.id, &.{ "coding_task", "general_task" }, 1));
    policy = try assign(a, policy, state, declaration, child.id, &.{"general_task"}, 1);
    try std.testing.expect(!try matchesAssignment(a, policy, state, child.id, &.{ "coding_task", "general_task" }, 1));
    policy = try assign(a, policy, state, declaration, root.id, &.{"coding_task"}, 1);
    try std.testing.expect(!try permits(a, policy, state, child.id, "general_task", 1));
    var rotated = state;
    rotated.epoch += 1;
    try std.testing.expect(!try permits(a, policy, rotated, root.id, "coding_task", 1));
    var changed = state;
    var changed_root = root;
    changed_root.public_key = "replacement-key";
    changed.grants = &.{ changed_root, child };
    try std.testing.expect(!try permits(a, policy, changed, root.id, "coding_task", 1));
    const encoded = try std.json.Stringify.valueAlloc(a, policy, .{});
    try std.testing.expectEqualStrings(policy.workspace, (try decode(a, state.workspace, encoded)).workspace);
}

pub const Selection = struct { capability: ?[]const u8 = null, body: ?[]const u8 = null, capabilities: []const []const u8 = &.{}, total: usize = 0, next_offset: ?usize = null };

fn authorizeClosure(alloc: std.mem.Allocator, policy: Policy, state: authority.State, grant: authority.Grant, declaration: model.Declaration, capability: []const u8, visited: *std.StringHashMapUnmanaged(void), depth: usize, now: i64) anyerror!void {
    if (depth > 64) return error.CapabilityPackageTooLarge;
    if (!try permits(alloc, policy, state, grant.id, capability, now)) return error.CompanyAccessDenied;
    if ((try visited.getOrPut(alloc, capability)).found_existing) return;
    for (declaration.semantic.capabilityHierarchy) |row| {
        if (!std.mem.eql(u8, row.capability, capability)) continue;
        for (row.dependsOn) |dependency| try authorizeClosure(alloc, policy, state, grant, declaration, dependency, visited, depth + 1, now);
    }
}

/// This endpoint exposes declared dependencies, not file inventory. Task reads
/// bind to their model basis; subsequent file reads retain their own evidence.
pub fn inspect(manager: workspace.Manager, state: authority.State, grant: authority.Grant, declaration: model.Declaration, selector: []const u8, realisation: ?[]const u8, offset: usize, limit: usize) !Selection {
    if (limit == 0 or limit > 16384) return error.InvalidEvidenceOffset;
    const policy = try load(manager);
    const now = @import("../shared/io.zig").milliTimestamp();
    if (std.mem.eql(u8, selector, "*")) {
        var visible: std.ArrayList([]const u8) = .empty;
        var total: usize = 0;
        for (model.items(model.spec(declaration.value), "capabilities")) |capability| {
            const id = model.text(capability, "id");
            if (!try permits(manager.alloc, policy, state, grant.id, id, now)) continue;
            if (total >= offset and visible.items.len < @min(limit, 32)) try visible.append(manager.alloc, id);
            total += 1;
        }
        return .{ .capabilities = visible.items, .total = total, .next_offset = if (offset + visible.items.len < total) offset + visible.items.len else null };
    }
    if (!authority.safeIdentity(selector)) return error.InvalidCompanyIdentity;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try authorizeClosure(manager.alloc, policy, state, grant, declaration, selector, &visited, 0, now);
    const plan = @import("capability_package.zig").describe(manager.alloc, declaration, &.{.{ .capability = selector, .realisation = realisation }}) catch |err| switch (err) {
        error.UnknownCapability => return error.CompanyAccessDenied,
        else => return err,
    };
    return .{ .capability = selector, .body = try std.json.Stringify.valueAlloc(manager.alloc, plan, .{}), .total = 1 };
}
