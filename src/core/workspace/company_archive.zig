//! Host-retained public worker repositories. Byte integrity does not give an
//! actor's private assessments or receipts company acceptance authority.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const ownership = @import("company_execution.zig");
const scope = @import("company_task_scope.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const manifest = @import("fossil_manifest.zig");
const io = @import("../shared/io.zig");

pub const prefix = "company/archives/";
pub const chunk_bytes = 128 * 1024;
pub const object_prefix = prefix ++ "objects/";
pub const Object = struct { version: []const u8 = "omos.company-archive-object/v1", sha256: []const u8, bytes: usize, content: []const u8 };
const max_bytes: u64 = 9007199254740991; // Largest exact integer in the wire format.
pub const Source = struct { workspace: []const u8, task: []const u8, revision: []const u8, sha256: []const u8, bytes: usize };
pub const Request = struct { action: enum { inspect, chunk } = .chunk, version: []const u8, view: []const u8, execution: ownership.Fence, source: Source, offset: usize, content: []const u8 };
pub const Record = struct {
    version: []const u8 = "omos.company-actor-archive/v1",
    workspace: []const u8,
    task: []const u8,
    view: []const u8,
    actor: []const u8,
    grant: []const u8,
    paths: []const []const u8,
    id: []const u8,
    source: Source,
    offset: usize,
    content: []const u8,
    chunk_sha256: []const u8,
    complete: bool = false,
    hash_state: [8]u32 = @splat(0),
    authority: []const u8 = "actor_public_history_only",
    retirement: ?[]const u8 = null,
    pub fn jsonStringify(self: Record, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Record).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "retirement")) {
                if (self.retirement) |reference| {
                    try writer.objectField(name);
                    try writer.write(reference);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn validateSource(source: Source) !void {
    for ([_][]const u8{ source.workspace, source.task, source.sha256 }) |id| _ = try authority.hexBytes(32, id);
    if (!manifest.validHash(source.revision) or source.bytes < 512 or source.bytes > max_bytes) return error.InvalidCompanyArchive;
}
fn identifier(alloc: std.mem.Allocator, source: Source) ![]const u8 {
    return workspace.hash(alloc, try json(alloc, source));
}
fn chunkPath(alloc: std.mem.Allocator, task: []const u8, id: []const u8, offset: usize) ![]const u8 {
    return alloc.print("{s}{s}/{s}/{d}.json", .{ prefix, task, id, offset });
}
fn receiptPath(alloc: std.mem.Allocator, task: []const u8, id: []const u8) ![]const u8 {
    return alloc.print("{s}{s}/{s}/receipt.json", .{ prefix, task, id });
}
fn headPath(alloc: std.mem.Allocator, task: []const u8, id: []const u8) ![]const u8 {
    return alloc.print("{s}{s}/{s}/head.json", .{ prefix, task, id });
}
fn objectPath(alloc: std.mem.Allocator, sha256: []const u8) ![]const u8 {
    return alloc.print("{s}{s}.json", .{ object_prefix, sha256 });
}
pub fn validateObject(alloc: std.mem.Allocator, object: Object, filename: []const u8) ![]const u8 {
    _ = try authority.hexBytes(32, object.sha256);
    if (!std.mem.eql(u8, object.version, "omos.company-archive-object/v1") or object.bytes == 0 or object.bytes > chunk_bytes or object.content.len > std.base64.standard.Encoder.calcSize(chunk_bytes) or !std.mem.eql(u8, filename, try objectPath(alloc, object.sha256))) return error.InvalidCompanyArchive;
    const bytes = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(object.content));
    try std.base64.standard.Decoder.decode(bytes, object.content);
    if (bytes.len != object.bytes or !std.mem.eql(u8, try workspace.hash(alloc, bytes), object.sha256)) return error.CompanyArchiveHashMismatch;
    return bytes;
}
fn objectBytes(manager: workspace.Manager, sha256: []const u8, revision: []const u8) ![]const u8 {
    const filename = try objectPath(manager.alloc, sha256);
    return validateObject(manager.alloc, try records.decode(Object, manager.alloc, try manager.contentAt(filename, revision), .{}), filename);
}
fn decode(alloc: std.mem.Allocator, source: Source, offset: usize, content: []const u8) ![]const u8 {
    try validateSource(source);
    if (offset >= source.bytes or offset % chunk_bytes != 0 or content.len > std.base64.standard.Encoder.calcSize(chunk_bytes)) return error.InvalidCompanyArchive;
    const bytes = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(content));
    try std.base64.standard.Decoder.decode(bytes, content);
    if (bytes.len != @min(chunk_bytes, source.bytes - offset)) return error.InvalidCompanyArchive;
    if (offset == 0 and !std.mem.startsWith(u8, bytes, "SQLite format 3\x00")) return error.InvalidCompanyArchive;
    return bytes;
}
pub fn validateStored(alloc: std.mem.Allocator, record: Record, filename: []const u8) !void {
    try validateSource(record.source);
    if (record.retirement) |reference| _ = try authority.hexBytes(32, reference);
    for ([_][]const u8{ record.workspace, record.task, record.id }) |id| _ = try authority.hexBytes(32, id);
    for ([_][]const u8{ record.view, record.actor, record.grant }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyArchive;
    if (!std.mem.eql(u8, record.version, "omos.company-actor-archive/v1") or !std.mem.eql(u8, record.authority, "actor_public_history_only") or !std.mem.eql(u8, record.id, try identifier(alloc, record.source)) or record.paths.len == 0 or record.paths.len > 32) return error.InvalidCompanyArchive;
    for (record.paths) |path| if (!authority.validPath(path, std.mem.endsWith(u8, path, "/"))) return error.InvalidCompanyArchive;
    if (std.mem.eql(u8, filename, try headPath(alloc, record.task, record.id))) {
        if (record.complete or record.content.len != 0 or record.chunk_sha256.len != 0 or record.offset == 0 or record.offset > record.source.bytes or (record.offset < record.source.bytes and record.offset % chunk_bytes != 0)) return error.InvalidCompanyArchive;
    } else if (record.complete) {
        if (record.offset != 0 or record.content.len != 0 or record.chunk_sha256.len != 0 or !std.mem.eql(u8, filename, try receiptPath(alloc, record.task, record.id))) return error.InvalidCompanyArchive;
    } else {
        _ = try authority.hexBytes(32, record.chunk_sha256);
        if (record.content.len != 0 or record.offset >= record.source.bytes or record.offset % chunk_bytes != 0 or !std.mem.eql(u8, filename, try chunkPath(alloc, record.task, record.id, record.offset))) return error.InvalidCompanyArchive;
    }
}
fn load(manager: workspace.Manager, path: []const u8) !?Record {
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision)) |entry| if (std.mem.eql(u8, entry, path)) {
        const record = try records.decode(Record, manager.alloc, try manager.contentAt(path, revision), .{});
        try validateStored(manager.alloc, record, path);
        return record;
    };
    return null;
}
fn permits(grant: authority.Grant, record: Record) !void {
    if (!std.mem.eql(u8, grant.actor, record.actor) or !std.mem.eql(u8, grant.id, record.grant)) return error.CompanyAccessDenied;
    for (record.paths) |path| if (!authority.permitsSelector(grant, path)) return error.CompanyAccessDenied;
}

/// Owner mutations hold the company lease; inspections pin immutable heads.
/// A live generation authorizes retention without changing task source.
pub fn execute(original: workspace.Manager, request: Request) ![]const u8 {
    var manager = original;
    if (!manager.company_operation_held and !(request.action == .inspect and manager.company_read_revision != null)) return error.CompanyOperationLeaseRequired;
    const retired = std.mem.eql(u8, request.version, "omos.company-retired-archive-write/v1");
    if ((!retired and !std.mem.eql(u8, request.version, "omos.company-actor-archive-write/v1")) or !authority.safeIdentity(request.view)) return error.InvalidCompanyArchive;
    try validateSource(request.source);
    if (request.action == .inspect and (request.offset != 0 or request.content.len != 0)) return error.InvalidCompanyArchive;
    const View = struct { id: []const u8, actor: []const u8, grant: []const u8, task: []const u8 };
    const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{request.view})), .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, view.id, request.view)) return error.CompanyAccessDenied;
    const snapshot = if (manager.company_read_revision != null) try manager.taskStatusSnapshot(view.task) else null;
    const task = if (snapshot) |selected| selected.task else try manager.refreshTaskContext(try manager.loadTask(view.task));
    if (snapshot) |selected| manager.task_read_revision = .{ .branch = task.branch, .revision = selected.revision };
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const live = if (retired) original: {
        for (state.grants) |candidate| if (std.mem.eql(u8, candidate.id, binding.grant) and std.mem.eql(u8, candidate.actor, binding.actor)) break :original candidate;
        return error.CompanyAccessDenied;
    } else try authority.liveGrant(state, binding.grant, io.milliTimestamp());
    const grant = try scope.forTask(manager, task, live);
    if (!std.mem.eql(u8, binding.actor, grant.actor) or !std.mem.eql(u8, view.actor, grant.actor) or !std.mem.eql(u8, view.grant, grant.id)) return error.CompanyAccessDenied;
    var retirement_reference: ?[]const u8 = null;
    if (retired) {
        const stopped = (try @import("company_worker_jobs.zig").retirement(manager, task.id)) orelse return error.CompanyWorkerNotRetired;
        const saved = stopped.checkpoint orelse return error.InvalidCompanyWorkerCheckpoint;
        if (!std.mem.eql(u8, stopped.binding.view, view.id) or !std.mem.eql(u8, stopped.binding.actor, grant.actor) or !std.mem.eql(u8, stopped.binding.grant, grant.id) or !std.mem.eql(u8, saved.runtime, request.execution.runtime) or saved.generation != request.execution.generation) return error.CompanyAccessDenied;
        retirement_reference = try workspace.hash(manager.alloc, try manager.companyContent(try @import("company_worker_jobs.zig").retirementPath(manager.alloc, task.id)));
    } else {
        try authority.authorizeExecution(manager, task);
        const execution = try records.decode(ownership.Record, manager.alloc, try manager.companyContent(try ownership.path(manager.alloc, request.view)), .{});
        try ownership.validate(execution, request.view, task.id, grant);
        try ownership.require(execution, request.execution, io.milliTimestamp());
    }
    const lease: ?workspace.ExecutionLease = if (request.action == .inspect) null else (try manager.tryTaskExecutionLease(task.id)) orelse return error.WorkspaceExecutionBusy;
    defer if (lease) |held| held.release();
    const id = try identifier(manager.alloc, request.source);
    const completed = try receiptPath(manager.alloc, task.id, id);
    const progress_path = try headPath(manager.alloc, task.id, id);
    const progress = try load(manager, progress_path);
    const receipt = try load(manager, completed);
    if (progress) |pinned| try permits(grant, pinned);
    if (receipt) |pinned| try permits(grant, pinned);
    const retained_offset = if (progress) |head| head.offset else 0;
    if (request.action == .inspect) return json(manager.alloc, .{ .version = "omos.company-actor-archive-outcome/v1", .workspace = manager.manifest.id, .task = task.id, .view = request.view, .revision = (try manager.companyRevision()).?, .archive_id = id, .sha256 = request.source.sha256, .bytes = request.source.bytes, .offset = 0, .next_offset = if (receipt != null) @as(?usize, null) else retained_offset, .resume_offset = retained_offset, .complete = receipt != null });
    const bytes = try decode(manager.alloc, request.source, request.offset, request.content);
    const filename = try chunkPath(manager.alloc, task.id, id, request.offset);
    const previous = if (request.offset > 0) (try load(manager, try chunkPath(manager.alloc, task.id, id, request.offset - chunk_bytes))) orelse return error.CompanyArchiveIncomplete else null;
    if (previous) |part| try permits(grant, part);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    if (previous) |part| {
        digest.s = part.hash_state;
        digest.total_len = @intCast(request.offset);
    }
    digest.update(bytes);
    const paths = if (progress) |head| head.paths else grant.paths;
    const record: Record = .{ .workspace = manager.manifest.id, .task = task.id, .view = request.view, .actor = grant.actor, .grant = grant.id, .paths = paths, .id = id, .source = request.source, .offset = request.offset, .content = "", .chunk_sha256 = try workspace.hash(manager.alloc, bytes), .hash_state = digest.s, .retirement = if (progress) |head| head.retirement else if (receipt) |saved| saved.retirement else retirement_reference };
    var files: std.ArrayList(workspace.Manager.CompanyFile) = .empty;
    if (try load(manager, filename)) |existing| {
        if (!std.mem.eql(u8, try json(manager.alloc, existing), try json(manager.alloc, record))) return error.CompanyArchiveConflict;
    } else {
        if (request.offset != retained_offset) return error.CompanyArchiveIncomplete;
        try files.append(manager.alloc, .{ .path = filename, .content = try json(manager.alloc, record) });
    }
    const end = request.offset + bytes.len;
    const last = end == request.source.bytes;
    if (last) {
        var result: [32]u8 = undefined;
        digest.final(&result);
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(&result, .lower), request.source.sha256)) return error.CompanyArchiveHashMismatch;
        if (receipt == null) {
            var accepted = record;
            accepted.offset = 0;
            accepted.content = "";
            accepted.chunk_sha256 = "";
            accepted.complete = true;
            if (retirement_reference) |reference| accepted.retirement = reference;
            try files.append(manager.alloc, .{ .path = completed, .content = try json(manager.alloc, accepted) });
        }
    }
    if (end > retained_offset) {
        var head = record;
        head.offset = end;
        head.content = "";
        head.chunk_sha256 = "";
        try files.append(manager.alloc, .{ .path = progress_path, .content = try json(manager.alloc, head) });
    }
    const object = Object{ .sha256 = record.chunk_sha256, .bytes = bytes.len, .content = request.content };
    const object_file = try objectPath(manager.alloc, object.sha256);
    const current = (try manager.companyRevision()).?;
    const known = for (try manager.inventory(current)) |entry| {
        if (std.mem.eql(u8, entry, object_file)) break true;
    } else false;
    if (known) {
        if (!std.mem.eql(u8, bytes, try objectBytes(manager, object.sha256, current))) return error.CompanyArchiveConflict;
    } else try files.append(manager.alloc, .{ .path = object_file, .content = try json(manager.alloc, object) });
    const revision = if (files.items.len > 0) try manager.companyWrite(try manager.companyRevision(), files.items) else (try manager.companyRevision()).?;
    return json(manager.alloc, .{ .version = "omos.company-actor-archive-outcome/v1", .workspace = manager.manifest.id, .task = task.id, .view = request.view, .revision = revision, .archive_id = id, .sha256 = request.source.sha256, .bytes = request.source.bytes, .offset = request.offset, .next_offset = if (last) @as(?usize, null) else end, .resume_offset = @max(retained_offset, end), .complete = last });
}

/// A signed caller must already own the selected view. Archived private
/// receipts are data to inspect and never company publication receipts.
pub fn read(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, view: []const u8, request: authority.Request) ![]const u8 {
    if (request.limit == 0 or request.limit > 16384 or request.offset > max_bytes) return error.InvalidEvidenceOffset;
    const current = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const revision = request.revision orelse current;
    if (!manifest.validHash(revision) or !try manager.revisionDescendsFrom(current, revision)) return error.CompanyAccessDenied;
    if (request.record_id) |id| {
        _ = try authority.hexBytes(32, id);
        const receipt_file = try receiptPath(manager.alloc, task.id, id);
        const receipt = try records.decode(Record, manager.alloc, try manager.contentAt(receipt_file, revision), .{});
        try validateStored(manager.alloc, receipt, receipt_file);
        try permits(grant, receipt);
        if (!std.mem.eql(u8, receipt.workspace, manager.manifest.id) or !receipt.complete or !std.mem.eql(u8, receipt.view, view) or request.offset > receipt.source.bytes or request.limit == 0 or request.limit > 16384) return error.InvalidCompanyArchive;
        const offset = (request.offset / chunk_bytes) * chunk_bytes;
        const chunk_file = try chunkPath(manager.alloc, task.id, id, if (offset == receipt.source.bytes) offset - chunk_bytes else offset);
        const chunk = try records.decode(Record, manager.alloc, try manager.contentAt(chunk_file, revision), .{});
        try validateStored(manager.alloc, chunk, chunk_file);
        try permits(grant, chunk);
        const bytes = try objectBytes(manager, chunk.chunk_sha256, revision);
        if (bytes.len != @min(chunk_bytes, receipt.source.bytes - chunk.offset)) return error.InvalidCompanyArchive;
        const start = request.offset - chunk.offset;
        const end = start + @min(request.limit, bytes.len - start);
        const encoded = try manager.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(end - start));
        return json(manager.alloc, .{ .version = "omos.company-actor-archive-page/v1", .archive_id = id, .revision = revision, .task = task.id, .source = receipt.source, .authority = receipt.authority, .offset = request.offset, .content = std.base64.standard.Encoder.encode(encoded, bytes[start..end]), .encoding = "base64", .next_offset = if (chunk.offset + end < receipt.source.bytes) @as(?usize, chunk.offset + end) else null });
    }
    const root = try manager.alloc.print("{s}{s}/", .{ prefix, task.id });
    var rows: std.ArrayList(std.json.Value) = .empty;
    var count: usize = 0;
    for (try manager.inventory(revision)) |filename| {
        if (!std.mem.startsWith(u8, filename, root) or !std.mem.endsWith(u8, filename, "/receipt.json")) continue;
        if (count >= request.offset and rows.items.len < @min(request.limit, 32)) {
            const receipt = try records.decode(Record, manager.alloc, try manager.contentAt(filename, revision), .{});
            try validateStored(manager.alloc, receipt, filename);
            try permits(grant, receipt);
            if (!std.mem.eql(u8, receipt.workspace, manager.manifest.id) or !receipt.complete or !std.mem.eql(u8, receipt.view, view)) return error.InvalidCompanyArchive;
            try rows.append(manager.alloc, try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try json(manager.alloc, .{ .id = receipt.id, .source = receipt.source, .authority = receipt.authority }), .{}));
        }
        count += 1;
    }
    return json(manager.alloc, .{ .version = "omos.company-actor-archives/v1", .revision = revision, .task = task.id, .archives = rows.items, .total = count, .next_offset = if (request.offset + rows.items.len < count) @as(?usize, request.offset + rows.items.len) else null });
}

test "company actor archives bound bytes and never confer company acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id: [64]u8 = @splat('a');
    var bytes: [512]u8 = @splat(0);
    @memcpy(bytes[0..16], "SQLite format 3\x00");
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    const content = std.base64.standard.Encoder.encode(encoded, &bytes);
    const source: Source = .{ .workspace = &id, .task = &id, .revision = &id, .sha256 = try workspace.hash(alloc, &bytes), .bytes = bytes.len };
    try std.testing.expectEqualSlices(u8, &bytes, try decode(alloc, source, 0, content));
    try std.testing.expectError(error.InvalidCompanyArchive, decode(alloc, source, 1, content));
    try std.testing.expectError(error.InvalidCompanyArchive, decode(alloc, source, bytes.len, content));
    try std.testing.expectError(error.InvalidCompanyArchive, decode(alloc, source, 0, "bm90LWEtd29ya2VyLWV4cG9ydA=="));
    var oversized = source;
    oversized.bytes = max_bytes + 1;
    try std.testing.expectError(error.InvalidCompanyArchive, validateSource(oversized));
    var row: Record = .{ .workspace = &id, .task = &id, .view = "view", .actor = "actor", .grant = "grant", .paths = &.{"documents/team/"}, .id = try identifier(alloc, source), .source = source, .offset = 0, .content = "", .chunk_sha256 = source.sha256 };
    const filename = try chunkPath(alloc, row.task, row.id, 0);
    const historical = try json(alloc, row);
    try std.testing.expect(std.mem.find(u8, historical, "retirement") == null);
    const restored = try records.decode(Record, alloc, historical, .{});
    try std.testing.expectEqualStrings(historical, try json(alloc, restored));
    row.retirement = &id;
    const retained = try records.decode(Record, alloc, try json(alloc, row), .{});
    try std.testing.expectEqualStrings(&id, retained.retirement.?);
    row.retirement = null;
    try validateStored(alloc, row, filename);
    row.authority = "company_host";
    try std.testing.expectError(error.InvalidCompanyArchive, validateStored(alloc, row, filename));
    row.authority = "actor_public_history_only";
    const object = Object{ .sha256 = source.sha256, .bytes = bytes.len, .content = content };
    try std.testing.expectEqualSlices(u8, &bytes, try validateObject(alloc, object, try objectPath(alloc, source.sha256)));
    var damaged = object;
    damaged.sha256 = &id;
    try std.testing.expectError(error.CompanyArchiveHashMismatch, validateObject(alloc, damaged, try objectPath(alloc, &id)));
    row.complete = true;
    try std.testing.expectError(error.InvalidCompanyArchive, validateStored(alloc, row, filename));
}
