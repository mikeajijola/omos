//! Host-owned company policy controlling whether capability promotions require
//! explicit operator approval or follow the submitting actor's grant.
const std = @import("std");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");

pub const path = "authority/promotion_policy.json";

pub const Mode = enum {
    require_human_approval,
    follow_actor_grant,
};

pub const Policy = struct {
    version: []const u8 = "omos.company-promotion-policy/v1",
    workspace: []const u8,
    mode: Mode = .require_human_approval,
};

pub fn decode(alloc: std.mem.Allocator, expected_workspace: []const u8, raw: []const u8) !Policy {
    const policy = try records.decode(Policy, alloc, raw, .{});
    if (!std.mem.eql(u8, policy.version, "omos.company-promotion-policy/v1") or !std.mem.eql(u8, policy.workspace, expected_workspace)) {
        return error.InvalidPromotionPolicy;
    }
    return policy;
}

pub fn load(manager: workspace.Manager) !Policy {
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    return loadAt(manager, revision);
}

pub fn loadAt(manager: workspace.Manager, control_revision: []const u8) !Policy {
    for (try manager.inventory(control_revision)) |name| {
        if (std.mem.eql(u8, name, path)) {
            return decode(manager.alloc, manager.manifest.id, try manager.contentAt(path, control_revision));
        }
    }
    // Fail safe when no explicit policy record exists yet on omos-company.
    return .{ .workspace = manager.manifest.id, .mode = .require_human_approval };
}

pub fn update(workspace_id: []const u8, mode: Mode) !Policy {
    if (!authority.safeIdentity(workspace_id)) return error.InvalidCompanyIdentity;
    return .{ .workspace = workspace_id, .mode = mode };
}

pub fn requiresHumanApproval(policy: Policy, grant: authority.Grant, is_promotion: bool) bool {
    if (grant.human_approval) return true;
    if (!is_promotion) return false;
    return policy.mode == .require_human_approval;
}

test "company promotion policy enforces toggle modes alongside actor grant approval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const auto_grant: authority.Grant = .{
        .id = "auto",
        .actor = "alice",
        .public_key = "0000000000000000000000000000000000000000000000000000000000000000",
        .paths = &.{"skills/"},
        .actions = &.{ .create_view, .checkpoint, .promote_capability },
        .expires_ms = 10000,
        .human_approval = false,
    };
    var manual_grant = auto_grant;
    manual_grant.id = "manual";
    manual_grant.human_approval = true;

    const strict: Policy = .{ .workspace = "company", .mode = .require_human_approval };
    const follow: Policy = .{ .workspace = "company", .mode = .follow_actor_grant };

    // Non-promotion tasks always follow the actor grant.
    try std.testing.expect(!requiresHumanApproval(strict, auto_grant, false));
    try std.testing.expect(requiresHumanApproval(strict, manual_grant, false));
    try std.testing.expect(!requiresHumanApproval(follow, auto_grant, false));
    try std.testing.expect(requiresHumanApproval(follow, manual_grant, false));

    // Promotion tasks obey the company policy toggle.
    try std.testing.expect(requiresHumanApproval(strict, auto_grant, true));
    try std.testing.expect(requiresHumanApproval(strict, manual_grant, true));
    try std.testing.expect(!requiresHumanApproval(follow, auto_grant, true));
    try std.testing.expect(requiresHumanApproval(follow, manual_grant, true));

    const encoded = try std.json.Stringify.valueAlloc(alloc, follow, .{});
    const decoded = try decode(alloc, "company", encoded);
    try std.testing.expectEqual(Mode.follow_actor_grant, decoded.mode);
    try std.testing.expectError(error.InvalidPromotionPolicy, decode(alloc, "other", encoded));
}
