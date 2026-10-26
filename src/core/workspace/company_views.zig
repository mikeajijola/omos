//! Scoped task discovery projects canonical company views. Fossil's own
//! read-only manifest query supplies bounded headers, never a second task DB.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const io = @import("../shared/io.zig");
const manifest = @import("fossil_manifest.zig");

pub const Header = struct {
    filename: []const u8,
    id: []const u8,
    actor: []const u8,
    grant: []const u8,
    task: []const u8,
    base: []const u8,
    scope: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
};

pub fn page(original: workspace.Manager, grant: authority.Grant, request: authority.Request) ![]const u8 {
    if (!original.company_operation_held) return error.CompanyOperationLeaseRequired;
    if (request.offset > 1000000 or request.limit == 0) return error.InvalidEvidenceOffset;
    var manager = original;
    var cancelled = std.atomic.Value(bool).init(false);
    if (manager.operation_control == null) manager.operation_control = .{ .cancel = &cancelled, .deadline = .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(30) }) };
    const current = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const revision = request.revision orelse current;
    if (!manifest.validHash(revision) or !try manager.revisionDescendsFrom(current, revision)) return error.CompanyAccessDenied;
    const limit = @min(request.limit, 32);
    const raw = try manager.companyViewHeaders(grant, revision, request.offset, limit + 1);
    const selected = if (std.mem.trim(u8, raw, " \t\r\n").len == 0) &.{} else try records.decode([]const struct { entry: []const u8 }, manager.alloc, raw, .{});
    if (selected.len > limit + 1) return error.InvalidCompanyViewIndex;
    var rows: std.ArrayList(std.json.Value) = .empty;
    for (selected[0..@min(selected.len, limit)]) |entry| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const header = try records.decode(Header, reader.alloc, entry.entry, .{});
        for ([_][]const u8{ header.id, header.task }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyViewIndex;
        if (!std.mem.eql(u8, header.actor, grant.actor) or !std.mem.eql(u8, header.grant, grant.id) or !std.mem.eql(u8, header.filename, try reader.alloc.print("company/views/{s}.json", .{header.id}))) return error.CompanyAccessDenied;
        const task = try reader.refreshTaskContext(try reader.loadTask(header.task));
        const binding = task.authority orelse return error.CompanyAccessDenied;
        if (!std.mem.eql(u8, binding.actor, grant.actor) or !std.mem.eql(u8, binding.grant, grant.id)) return error.CompanyAccessDenied;
        _ = try @import("company_task_scope.zig").forView(reader, task, grant, header.id, header.scope);
        if (header.created_at_ms) |at| if (at != task.created_at_ms) return error.InvalidCompanyViewIndex;
        const job = if (task.review_job) |id| try reader.loadReviewJob(task, id) else null;
        const published = if (task.state == .accepted) value: {
            _ = try reader.publicationSummary(task);
            break :value true;
        } else false;
        var end = @min(task.definition.objective.len, 512);
        while (end > 0 and !std.unicode.utf8ValidateSlice(task.definition.objective[0..end])) end -= 1;
        const encoded = try std.json.Stringify.valueAlloc(reader.alloc, .{ .view = header.id, .task = task.id, .revision = try reader.currentRevision(task), .state = @tagName(task.state), .objective = task.definition.objective[0..end], .contract_version = task.definition.version, .created_at_ms = task.created_at_ms, .capability = if (task.model_basis) |basis| basis.capability else null, .review_state = if (job) |review| @tagName(review.state) else null, .published = published }, .{});
        try rows.append(manager.alloc, try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, encoded, .{ .allocate = .alloc_always }));
    }
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-views/v1", .index_revision = revision, .views = rows.items, .next_offset = if (selected.len > limit) @as(?usize, request.offset + limit) else null }, .{});
}
