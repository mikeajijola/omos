//! Durable file parts on the protected control branch. An upload binds its
//! actor, view, expected file state and exact candidate revision; only an
//! explicit, completely verified finish creates a task checkpoint.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");

pub const chunk_bytes = 128 * 1024;
pub const max_bytes = 8 * 1024 * 1024;
const Part = struct {
    version: []const u8 = "omos.company-upload/v1",
    binding: []const u8,
    offset: usize,
    sha256: []const u8,
    content: []const u8,
};
pub const Result = union(enum) { part: []const u8, complete: []const u8 };

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn path(alloc: std.mem.Allocator, binding: []const u8, offset: usize) ![]const u8 {
    return alloc.print("company/uploads/{s}/{d}.json", .{ binding, offset });
}
fn contains(paths: []const []const u8, selected: []const u8) bool {
    for (paths) |item| if (std.mem.eql(u8, item, selected)) return true;
    return false;
}
fn decode(alloc: std.mem.Allocator, content: []const u8) ![]const u8 {
    const bytes = try alloc.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(content) catch return error.InvalidCompanyUpload);
    std.base64.standard.Decoder.decode(bytes, content) catch return error.InvalidCompanyUpload;
    return bytes;
}

/// Company operation ownership and the current live grant are checked by the
/// service before entering. The signed request and normal operation journal
/// retain retry attribution; no private upload cache is needed for recovery.
pub fn accept(manager: workspace.Manager, request: authority.Request) !Result {
    const upload = request.upload orelse return error.InvalidCompanyUpload;
    if (request.action != .checkpoint or request.remove or request.encoding != .base64 or request.view == null or request.revision == null or request.path == null or upload.bytes == 0 or upload.bytes > max_bytes or upload.sha256.len != 64) return error.InvalidCompanyUpload;
    for (upload.sha256) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidCompanyUpload;
    const basis = (try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired;
    const declaration = try manager.loadDeclaration(basis.revision);
    const declared = for (declaration.semantic.entityTypes) |entity| {
        if (std.mem.eql(u8, entity.id, "omos_company_upload")) break true;
    } else false;
    if (!declared) return error.CompanyDefinitionUpdateRequired;
    const binding = try workspace.hash(manager.alloc, try encode(manager.alloc, .{ request.workspace, request.actor, request.grant, request.view, request.revision, request.path, request.previous_hash, request.previous_executable, request.executable, upload }));
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const inventory = try manager.inventory(control);
    if (request.content) |content| {
        if (request.offset >= upload.bytes or request.offset % chunk_bytes != 0 or content.len > std.base64.standard.Encoder.calcSize(chunk_bytes)) return error.InvalidCompanyUpload;
        const bytes = try decode(manager.alloc, content);
        if (bytes.len != @min(chunk_bytes, upload.bytes - request.offset)) return error.InvalidCompanyUpload;
        const selected = try path(manager.alloc, binding, request.offset);
        const part: Part = .{ .binding = binding, .offset = request.offset, .sha256 = try workspace.hash(manager.alloc, bytes), .content = content };
        const raw = try encode(manager.alloc, part);
        if (contains(inventory, selected)) {
            if (!std.mem.eql(u8, raw, try manager.contentAt(selected, control))) return error.CompanyUploadConflict;
        } else _ = try manager.companyWrite(control, &.{.{ .path = selected, .content = raw }});
        return .{ .part = try encode(manager.alloc, .{ .state = "uploading", .upload = binding, .revision = request.revision.?, .offset = request.offset, .bytes = bytes.len, .sha256 = part.sha256 }) };
    }
    if (request.offset != 0) return error.InvalidCompanyUpload;
    const output = try manager.alloc.alloc(u8, upload.bytes);
    var offset: usize = 0;
    while (offset < output.len) : (offset += @min(chunk_bytes, output.len - offset)) {
        const selected = try path(manager.alloc, binding, offset);
        if (!contains(inventory, selected)) return error.CompanyUploadIncomplete;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var part_manager = manager;
        part_manager.alloc = scratch.allocator();
        const part = try records.decode(Part, scratch.allocator(), try part_manager.contentAt(selected, control), .{});
        if (!std.mem.eql(u8, part.version, "omos.company-upload/v1") or !std.mem.eql(u8, part.binding, binding) or part.offset != offset or part.content.len > std.base64.standard.Encoder.calcSize(@min(chunk_bytes, output.len - offset))) return error.CompanyUploadConflict;
        const bytes = try decode(scratch.allocator(), part.content);
        if (bytes.len != @min(chunk_bytes, output.len - offset) or !std.mem.eql(u8, part.sha256, try workspace.hash(scratch.allocator(), bytes))) return error.CompanyUploadConflict;
        @memcpy(output[offset .. offset + bytes.len], bytes);
    }
    if (!std.mem.eql(u8, upload.sha256, try workspace.hash(manager.alloc, output))) return error.CompanyUploadHashMismatch;
    return .{ .complete = output };
}
