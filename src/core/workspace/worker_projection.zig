//! Sparse, disposable files for a host-pinned company view. The broker owns
//! identity, authority and the immutable source revision; no key enters here.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");
const model = @import("definition.zig");
const authority = @import("company_authority.zig");

pub const Source = struct { version: []const u8, workspace: []const u8, view: []const u8, revision: []const u8, generation: u64 };
pub const File = struct { path: []const u8, sha256: []const u8, bytes: usize, executable: bool };
pub const Ledger = struct { version: []const u8 = "omos.worker-projection/v1", task: []const u8, source: Source, files: []const File = &.{} };
const max_files = 10000;
const max_file_bytes = 8 * 1024 * 1024;
const max_bytes = 64 * 1024 * 1024;

fn hash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn managed(path: []const u8) bool {
    if (!authority.validPath(path, false)) return false;
    for ([_][]const u8{ "memory/", "skills/", "documents/", "artifacts/", "ui/" }) |root| if (std.mem.startsWith(u8, path, root)) return true;
    return false;
}

pub fn ledgerPath(alloc: std.mem.Allocator, task: []const u8) ![]const u8 {
    if (!hash(task)) return error.InvalidWorkerProjection;
    return alloc.print("records/omos_worker_projection/{s}.json", .{task});
}

fn validateSource(source: Source) !void {
    if (!std.mem.eql(u8, source.version, "omos.worker-source/v1") or !hash(source.workspace) or !hash(source.view) or !hash(source.revision) or source.generation == 0) return error.InvalidWorkerProjection;
}

pub fn validateLedger(ledger: Ledger) !void {
    try validateSource(ledger.source);
    if (!std.mem.eql(u8, ledger.version, "omos.worker-projection/v1") or !hash(ledger.task) or ledger.files.len > max_files) return error.InvalidWorkerProjection;
    var total: usize = 0;
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    for (ledger.files) |file| {
        if (!managed(file.path) or !hash(file.sha256) or file.bytes > max_file_bytes or file.bytes > max_bytes - total) return error.InvalidWorkerProjection;
        const result = try seen.getOrPut(file.path);
        if (result.found_existing) return error.InvalidWorkerProjection;
        total += file.bytes;
    }
}

fn sameSource(left: Source, right: Source) bool {
    return left.generation == right.generation and std.mem.eql(u8, left.workspace, right.workspace) and std.mem.eql(u8, left.view, right.view) and std.mem.eql(u8, left.revision, right.revision);
}

fn fetch(manager: workspace.Manager, source: Source, request: anytype) !std.json.Value {
    if (manager.operation_control) |control| try control.check();
    const response = try @import("workspace_client.zig").workerProjection(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, request, .{}), manager.operation_control);
    if (!std.mem.eql(u8, model.text(response, "workspace"), source.workspace) or !std.mem.eql(u8, model.text(response, "view"), source.view) or !std.mem.eql(u8, model.text(response, "revision"), source.revision)) return error.WorkerProjectionChanged;
    const generation = model.field(response, "generation") orelse return error.InvalidWorkerProjection;
    if (generation != .integer or generation.integer < 1 or generation.integer != source.generation) return error.WorkerProjectionChanged;
    const data = model.field(response, "data") orelse return error.InvalidWorkerProjection;
    if (!std.mem.eql(u8, model.text(data, "revision"), source.revision) or !std.mem.eql(u8, model.text(data, "read_tracking"), "recorded")) return error.WorkerProjectionChanged;
    return data;
}

fn loadSource(manager: workspace.Manager) !?Source {
    if (io.getenv("OMOS_WORKER_BROKER") == null) return null;
    const path = io.getenv("OMOS_WORKER_PROJECTION") orelse return null;
    // The launcher fixes this path in a read-only, root-owned runtime mount.
    if (!std.mem.eql(u8, path, "/runtime/worker-source.json")) return error.InvalidWorkerProjection;
    var file = std.Io.Dir.cwd().openFile(io.getIo(), path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io.getIo());
    const source = try records.decode(Source, manager.alloc, try io.readFileToEnd(manager.alloc, &file, 8192), .{});
    try validateSource(source);
    return source;
}

fn body(original: workspace.Manager, source: Source, file: File) ![]const u8 {
    const content = try original.alloc.alloc(u8, file.bytes);
    var offset: usize = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var manager = original;
        manager.alloc = arena.allocator();
        const value = try fetch(manager, source, .{ .action = "read", .path = file.path, .offset = offset });
        const Page = struct { path: []const u8, exists: bool, offset: usize, content: []const u8, encoding: []const u8, bytes: usize, sha256: []const u8, executable: bool, next_offset: ?usize };
        const page = try std.json.parseFromValueLeaky(Page, manager.alloc, value, .{ .ignore_unknown_fields = true });
        if (!page.exists or !std.mem.eql(u8, page.path, file.path) or page.offset != offset or page.bytes != file.bytes or !std.mem.eql(u8, page.sha256, file.sha256) or page.executable != file.executable or !std.mem.eql(u8, page.encoding, "base64")) return error.WorkerProjectionChanged;
        const bytes = try std.base64.standard.Decoder.calcSizeForSlice(page.content);
        if (bytes > 16384 or bytes > content.len - offset or (bytes == 0 and offset != content.len)) return error.InvalidWorkerProjection;
        try std.base64.standard.Decoder.decode(content[offset..][0..bytes], page.content);
        offset += bytes;
        if (page.next_offset) |next| {
            if (next != offset or offset >= content.len) return error.InvalidWorkerProjection;
        } else {
            if (offset != content.len or !std.mem.eql(u8, try workspace.hash(original.alloc, content), file.sha256)) return error.WorkerProjectionChanged;
            return content;
        }
    }
}

/// Canonical reads fetch the same pinned company inputs as filesystem tools.
/// Personal reads and protected host records require no worker projection.
pub fn hydrateRead(manager: workspace.Manager, task: workspace.Task, path: []const u8) !void {
    if (!managed(path) or io.getenv("OMOS_WORKER_BROKER") == null or io.getenv("OMOS_WORKER_PROJECTION") == null) return;
    const lease = try manager.projectionLease(task);
    defer lease.release();
    try hydrate(manager, task, .{ .path = path });
}

/// The caller holds the projection lease. Each file and its provenance commit
/// together, so an interrupted fetch resumes without resurrecting later deletes.
pub fn hydrate(original: workspace.Manager, task: workspace.Task, selection: @import("filesystem_projection.zig").Selection) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var manager = original;
    manager.alloc = arena.allocator();
    const source = (try loadSource(manager)) orelse return;
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    var ledger: Ledger = .{ .task = task.id, .source = source };
    const path = try ledgerPath(manager.alloc, task.id);
    const revision = try manager.currentRevision(task);
    const canonical = try manager.inventory(revision);
    for (canonical) |existing| if (std.mem.eql(u8, existing, path)) {
        ledger = try records.decode(Ledger, manager.alloc, try manager.contentAt(path, revision), .{});
        try validateLedger(ledger);
        if (!std.mem.eql(u8, ledger.task, task.id) or !sameSource(ledger.source, source)) return error.WorkerProjectionChanged;
        break;
    };
    var files: std.ArrayList(File) = .empty;
    try files.appendSlice(manager.alloc, ledger.files);
    var known = std.StringHashMap(void).init(manager.alloc);
    defer known.deinit();
    var total: usize = 0;
    for (files.items) |file| {
        try known.put(file.path, {});
        total += file.bytes;
    }
    if (!selection.all and !selection.skill_index) if (selection.path) |selected| if (known.contains(selected)) return;
    var seen = std.StringHashMap(void).init(manager.alloc);
    defer seen.deinit();
    var offset: usize = 0;
    var expected_total: ?usize = null;
    while (true) {
        var page_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer page_arena.deinit();
        var reader = manager;
        reader.alloc = page_arena.allocator();
        const value = try fetch(reader, source, .{ .action = "inventory", .offset = offset });
        const Page = struct { files: []const File, total: usize, next_offset: ?usize };
        const page = try std.json.parseFromValueLeaky(Page, reader.alloc, value, .{ .ignore_unknown_fields = true });
        if (page.files.len > 32 or page.total > max_files or (expected_total != null and expected_total.? != page.total)) return error.WorkerProjectionBudgetExceeded;
        expected_total = page.total;
        for (page.files) |file| {
            if (!hash(file.sha256) or file.bytes > max_file_bytes) return error.InvalidWorkerProjection;
            const unique = try seen.getOrPut(try manager.alloc.dupe(u8, file.path));
            if (unique.found_existing) return error.InvalidWorkerProjection;
            if (!managed(file.path) or !selection.includes(file.path) or known.contains(file.path)) continue;
            // Explicit Fossil writes can precede a normal file tool. Preserve
            // those private changes instead of replacing them with base input.
            const local = for (canonical) |existing| {
                if (std.mem.eql(u8, existing, file.path)) break true;
            } else false;
            if (local) continue;
            if (files.items.len >= max_files or file.bytes > max_bytes - total) return error.WorkerProjectionBudgetExceeded;
            var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer file_arena.deinit();
            var writer = manager;
            writer.alloc = file_arena.allocator();
            const bytes = try body(writer, source, file);
            const retained: File = .{ .path = try manager.alloc.dupe(u8, file.path), .sha256 = try manager.alloc.dupe(u8, file.sha256), .bytes = file.bytes, .executable = file.executable };
            try files.append(manager.alloc, retained);
            ledger.files = files.items;
            _ = try writer.hydrateWorkerContent(task, .{ .path = file.path, .content = bytes, .previous_hash = null, .executable = file.executable }, try std.json.Stringify.valueAlloc(writer.alloc, ledger, .{}));
            total += file.bytes;
            try known.put(retained.path, {});
        }
        offset += page.files.len;
        if (page.next_offset) |next| {
            if (next != offset or page.files.len == 0 or next >= page.total) return error.InvalidWorkerProjection;
        } else {
            if (offset != page.total) return error.InvalidWorkerProjection;
            return;
        }
    }
}

test "worker projection provenance rejects unsafe, duplicate and over-budget files" {
    const ids: [5][64]u8 = .{ @splat('a'), @splat('b'), @splat('c'), @splat('d'), @splat('e') };
    const source: Source = .{ .version = "omos.worker-source/v1", .workspace = &ids[0], .view = &ids[1], .revision = &ids[2], .generation = 1 };
    const file: File = .{ .path = "documents/team/a.txt", .sha256 = &ids[3], .bytes = 12, .executable = false };
    try validateLedger(.{ .task = &ids[4], .source = source, .files = &.{file} });
    try std.testing.expectError(error.InvalidWorkerProjection, validateLedger(.{ .task = &ids[4], .source = source, .files = &.{ file, file } }));
    var invalid = file;
    invalid.path = "documents/../credentials";
    try std.testing.expectError(error.InvalidWorkerProjection, validateLedger(.{ .task = &ids[4], .source = source, .files = &.{invalid} }));
    invalid = file;
    invalid.bytes = max_file_bytes + 1;
    try std.testing.expectError(error.InvalidWorkerProjection, validateLedger(.{ .task = &ids[4], .source = source, .files = &.{invalid} }));
}
