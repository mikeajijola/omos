//! Scoped queries over immutable record revisions. Filtering precedes counts,
//! pagination, and record reads; large rows remain revision-pinned references.
const std = @import("std");
const authority = @import("company_authority.zig");
const workspace = @import("fossil_workspace.zig");
const model = @import("definition.zig");

pub fn path(alloc: std.mem.Allocator, entity: []const u8, id: []const u8) ![]const u8 {
    if (!authority.safeIdentity(entity) or !authority.safeIdentity(id)) return error.InvalidCompanyIdentity;
    if (std.mem.startsWith(u8, entity, "omos_")) return error.HostOwnedEntity;
    return alloc.print("records/{s}/{s}.json", .{ entity, id });
}

pub fn validationFailure(err: anyerror) bool {
    return switch (err) {
        error.TaskIsReadOnly, error.TaskReviewInProgress, error.StaleWorkContract, error.InvalidCompanyUpload, error.CompanyUploadIncomplete, error.CompanyUploadHashMismatch, error.CompanyUploadConflict, error.InvalidCompanyFileAttributes, error.InvalidCompanyIdentity, error.HostOwnedEntity, error.UnknownEntityType, error.InvalidEntityRecord, error.MissingEntityField, error.UnknownEntityField, error.InvalidEntityFieldType, error.InvalidCompanyRecordJson, error.CompanyRecordNotPortable, error.UnsupportedCompanyRecordEncoding, error.MissingContent, error.MissingPath, error.WorkspacePathDenied, error.WorkspaceRecordTooLarge, error.InvalidArtifactIdentity, error.InvalidPadding, error.InvalidCharacter => true,
        else => false,
    };
}

pub fn identity(record_path: []const u8) ?struct { entity: []const u8, id: []const u8 } {
    if (!std.mem.startsWith(u8, record_path, "records/") or !std.mem.endsWith(u8, record_path, ".json")) return null;
    var parts = std.mem.splitScalar(u8, record_path, '/');
    _ = parts.next();
    const entity = parts.next() orelse return null;
    const name = parts.next() orelse return null;
    if (parts.next() != null or name.len <= 5 or std.mem.startsWith(u8, entity, "omos_")) return null;
    const id = name[0 .. name.len - 5];
    if (!authority.safeIdentity(entity) or !authority.safeIdentity(id)) return null;
    return .{ .entity = entity, .id = id };
}

pub fn query(manager: workspace.Manager, grant: authority.Grant, request: authority.Request, revision: []const u8) ![]const u8 {
    const alloc = manager.alloc;
    if (request.limit == 0) return error.InvalidEvidenceOffset;
    if (request.entity) |entity| _ = try path(alloc, entity, "query");
    var rows: std.ArrayList(std.json.Value) = .empty;
    var total: usize = 0;
    var page_bytes: usize = 0;
    var page_open = true;
    for (try manager.inventory(revision)) |record_path| {
        if (!authority.permitsPath(grant, record_path)) continue;
        const selected = identity(record_path) orelse continue;
        const entity = selected.entity;
        const id = selected.id;
        if (request.entity) |filter| if (!std.mem.eql(u8, filter, entity)) continue;
        if (page_open and total >= request.offset and rows.items.len < @min(request.limit, 32)) {
            const bytes = try manager.contentAt(record_path, revision);
            const row = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{});
            if (!std.mem.eql(u8, model.text(row, "entity"), entity) or !std.mem.eql(u8, model.text(row, "id"), id)) return error.InvalidEntityRecord;
            const digest = try workspace.hash(alloc, bytes);
            const complete = try std.json.Stringify.valueAlloc(alloc, .{ .entity = entity, .id = id, .data = model.field(row, "data") orelse return error.InvalidEntityRecord, .task = model.text(row, "task"), .source_path = record_path, .revision = revision, .sha256 = digest, .bytes = bytes.len, .complete = true }, .{});
            const encoded = if (complete.len <= 8192) complete else try std.json.Stringify.valueAlloc(alloc, .{ .entity = entity, .id = id, .source_path = record_path, .revision = revision, .sha256 = digest, .bytes = bytes.len, .complete = false }, .{});
            // Reserve room for bounded references after a full page of bodies.
            if (page_bytes + encoded.len <= 64 * 1024) {
                try rows.append(alloc, try std.json.parseFromSliceLeaky(std.json.Value, alloc, encoded, .{}));
                page_bytes += encoded.len;
            } else page_open = false;
        }
        total += 1;
    }
    // Once the byte limit is reached, later rows must not skip over a row that
    // belongs to the next page. Count-only enumeration remains permission-scoped.
    return std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.company-records/v1", .workspace = manager.manifest.id, .revision = revision, .records = rows.items, .total = total, .next_offset = if (request.offset + rows.items.len < total) @as(?usize, request.offset + rows.items.len) else null }, .{});
}

test "company record identities cannot write host records or escape their entity" {
    const alloc = std.testing.allocator;
    const result = try path(alloc, "company_note", "quarterly-report");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("records/company_note/quarterly-report.json", result);
    try std.testing.expectError(error.HostOwnedEntity, path(alloc, "omos_assessment", "forged"));
    try std.testing.expectError(error.InvalidCompanyIdentity, path(alloc, "company_note", "../other"));
    try std.testing.expectError(error.InvalidCompanyIdentity, path(alloc, "company_note/private", "note"));
}
