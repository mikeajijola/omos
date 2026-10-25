//! Scoped record contracts from the pinned OmniForm declaration. These describe
//! expected data; they confer no authority and establish no execution success.
const std = @import("std");
const authority = @import("company_authority.zig");
const model = @import("definition.zig");

pub const Selection = struct {
    entity: ?[]const u8 = null,
    body: ?[]const u8 = null,
    entities: []const []const u8 = &.{},
    total: usize = 0,
    next_offset: ?usize = null,
};

fn visible(alloc: std.mem.Allocator, grant: authority.Grant, entity: []const u8) !bool {
    if (!authority.safeIdentity(entity) or std.mem.startsWith(u8, entity, "omos_")) return false;
    const prefix = try alloc.print("records/{s}/", .{entity});
    for (grant.paths) |scope| {
        if (std.mem.startsWith(u8, prefix, scope) or std.mem.startsWith(u8, scope, prefix)) return true;
    }
    return false;
}

pub fn inspect(alloc: std.mem.Allocator, declaration: model.Declaration, grant: authority.Grant, selector: []const u8, offset: usize, limit: usize) !Selection {
    if (limit == 0) return error.InvalidEvidenceOffset;
    const semantic = model.field(model.spec(declaration.value), "semantic") orelse return error.InvalidWorkspaceDefinition;
    const entities = model.items(semantic, "entityTypes");
    if (!std.mem.eql(u8, selector, "*")) {
        if (!authority.safeIdentity(selector)) return error.InvalidCompanyIdentity;
        // Scope is checked before lookup so absent and hidden types are alike.
        if (!try visible(alloc, grant, selector)) return error.CompanyAccessDenied;
        for (entities) |entity| if (std.mem.eql(u8, model.text(entity, "id"), selector)) {
            return .{ .entity = selector, .body = try model.canonical(alloc, entity), .total = 1 };
        };
        return error.UnknownEntityType;
    }
    var selected: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    for (entities) |entity| {
        const id = model.text(entity, "id");
        if (!try visible(alloc, grant, id)) continue;
        if (total >= offset and selected.items.len < @min(limit, 32)) try selected.append(alloc, id);
        total += 1;
    }
    return .{ .entities = selected.items, .total = total, .next_offset = if (offset + selected.items.len < total) offset + selected.items.len else null };
}

test "company schema visibility includes scoped record types without revealing other types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var grant: authority.Grant = .{ .id = "reader", .actor = "reader", .public_key = "", .paths = &.{"records/team_note/one.json"}, .actions = &.{.discover}, .expires_ms = 1 };
    try std.testing.expect(try visible(alloc, grant, "team_note"));
    try std.testing.expect(!try visible(alloc, grant, "team_note_private"));
    try std.testing.expect(!try visible(alloc, grant, "private_note"));
    grant.paths = &.{"records/"};
    try std.testing.expect(try visible(alloc, grant, "team_note"));
    try std.testing.expect(!try visible(alloc, grant, "omos_assessment"));
    grant.paths = &.{"documents/"};
    try std.testing.expect(!try visible(alloc, grant, "team_note"));
}

test "company schema operation enforces discovery shape and bounded projection output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const declaration = try model.parse(alloc, model.seed);
    const input = (try std.json.parseFromSlice(std.json.Value, alloc, "{\"action\":\"discover\",\"entity\":\"*\"}", .{})).value;
    try model.validateOperation(alloc, declaration, "omos_company_schema", input, .input);
    const missing = (try std.json.parseFromSlice(std.json.Value, alloc, "{\"action\":\"discover\"}", .{})).value;
    try std.testing.expectError(error.InvalidOperationRecord, model.validateOperation(alloc, declaration, "omos_company_schema", missing, .input));
    var output = (try std.json.parseFromSlice(std.json.Value, alloc, "{\"version\":\"omos.company-schema/v1\",\"workspace\":\"company\",\"revision\":\"revision\",\"definition_revision\":\"definition\",\"definition_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"semantic_version\":\"omniseedos.semantic/v1\",\"scope_filtered\":true,\"read_tracking\":\"model_basis\",\"entity\":null,\"schema\":null,\"entities\":[\"team_note\"],\"total\":1,\"next_offset\":null}", .{})).value;
    try model.validateOperation(alloc, declaration, "omos_company_schema", output, .output);
    try output.object.put(alloc, "scope_filtered", .{ .bool = false });
    try std.testing.expectError(error.InvalidOperationRecord, model.validateOperation(alloc, declaration, "omos_company_schema", output, .output));
    try output.object.put(alloc, "scope_filtered", .{ .bool = true });
    for (0..32) |_| try output.object.getPtr("entities").?.array.append(.{ .string = "team_note" });
    try std.testing.expectError(error.InvalidOperationRecord, model.validateOperation(alloc, declaration, "omos_company_schema", output, .output));
}
