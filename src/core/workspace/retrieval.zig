//! Revision-pinned content retrieval. The index is a disposable projection of
//! verified Fossil objects; it never supplies authority or application status.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const io = @import("../shared/io.zig");
const manifest = @import("fossil_manifest.zig");

pub const Request = struct {
    action: enum { search, read, query } = .search,
    query: []const u8 = "",
    path: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    runtime_revision: ?[]const u8 = null,
    task: ?[]const u8 = null,
    offset: usize = 0,
    limit: usize = 10,
    entity: ?[]const u8 = null,
    pointer: []const u8 = "",
    filters: []const struct { field: []const u8, equals: []const u8 } = &.{},
    order_by: ?[]const u8 = null,
    descending: bool = true,
};
const Entry = struct { path: []const u8, artifact: []const u8, text: []const u8, complete: bool, reason: ?[]const u8 = null };
const Hit = struct { path: []const u8, artifact: []const u8, revision: []const u8, excerpt: []const u8, byte_offset: usize, score: usize, complete: bool };
const max_content_bytes = 1024 * 1024;

pub fn execute(manager: workspace.Manager, request: Request) !std.json.Value {
    const alloc = manager.alloc;
    if (request.limit == 0 or request.limit > 32 or request.query.len > 1024) return error.InvalidRetrievalRequest;
    const task = if (request.task) |id| try manager.loadTask(id) else null;
    const revision = if (request.revision) |id| try manager.revision(id) else if (task) |selected| try manager.currentRevision(selected) else try manager.revision("trunk");
    if (request.action == .query) {
        if (request.path != null) return queryDocument(manager, request, revision);
        if (request.revision != null and !std.mem.eql(u8, revision, if (task) |selected| try manager.currentRevision(selected) else try manager.revision("trunk"))) return error.WorkspaceRevisionChanged;
        return std.json.parseFromSliceLeaky(std.json.Value, alloc, try manager.queryRecords(task, request.entity, request.offset), .{});
    }
    const files = try manager.fileManifest(revision);
    if (request.action == .read) {
        const path = request.path orelse return error.MissingPath;
        if (!contentPath(path)) return error.RetrievalPathDenied;
        const file = for (files) |file| {
            if (std.mem.eql(u8, file.path, path)) break file;
        } else return error.FileNotFound;
        if (file.mode == .symlink) return error.RetrievalPathDenied;
        const bytes = try manager.retrievalArtifact(file.artifact orelse return error.MissingArtifact);
        const entry: Entry = .{ .path = path, .artifact = file.artifact.?, .text = bytes, .complete = true };
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.findScalar(u8, bytes, 0) != null) return error.BinarySourceRequiresDocumentViewer;
        if (request.offset > entry.text.len) return error.InvalidRetrievalOffset;
        if (utf8Boundary(entry.text, request.offset) != request.offset) return error.InvalidRetrievalOffset;
        const end = utf8Boundary(entry.text, @min(entry.text.len, request.offset +| 16384));
        return value(alloc, .{ .version = "omos.retrieval/v1", .workspace = manager.manifest.id, .revision = revision, .path = path, .artifact = entry.artifact, .text = entry.text[request.offset..end], .byte_offset = request.offset, .next_offset = if (end < entry.text.len) @as(?usize, end) else null, .complete = entry.complete, .reason = entry.reason, .authority = "source_content" });
    }
    if (std.mem.trim(u8, request.query, " \n\t\r").len == 0) return error.MissingSearchQuery;
    const runtime_revision = if (request.task == null) request.runtime_revision orelse try manager.runtimeRevisionIfPresent() else null;
    const Source = struct { file: manifest.File, revision: []const u8 };
    var sources: std.ArrayList(Source) = .empty;
    for (files) |file| try sources.append(alloc, .{ .file = file, .revision = revision });
    if (runtime_revision) |runtime| {
        if (!manifest.validHash(runtime)) return error.InvalidFossilRevision;
        for (try manager.fileManifest(runtime)) |file| if (std.mem.startsWith(u8, file.path, "runtime/conversations/") or std.mem.startsWith(u8, file.path, "runtime/routing/") or std.mem.startsWith(u8, file.path, "runtime/attention/")) try sources.append(alloc, .{ .file = file, .revision = runtime });
    }
    // Prime small content in bounded batches instead of starting a Fossil
    // process for each document. Cache misses for larger objects stay bounded.
    var missing: std.ArrayList([]const u8) = .empty;
    const cache_directory = try alloc.print("{s}/retrieval-v1", .{manager.root});
    try std.Io.Dir.cwd().createDirPath(io.getIo(), cache_directory);
    for (sources.items) |source| {
        const file = source.file;
        if (!contentPath(file.path) or file.mode == .symlink) continue;
        if (request.path == null and std.mem.startsWith(u8, file.path, "history/")) continue;
        if (request.path) |prefix| if (!std.mem.startsWith(u8, file.path, prefix)) continue;
        if (unsupported(file.path) != null) continue;
        if (file.artifact) |artifact| {
            const cache = try alloc.print("{s}/{s}.json", .{ cache_directory, artifact });
            if (std.Io.Dir.openFileAbsolute(io.getIo(), cache, .{ .follow_symlinks = false })) |opened| {
                opened.close(io.getIo());
                continue;
            } else |err| if (err != error.FileNotFound) return err;
            try missing.append(alloc, artifact);
        }
    }
    var batch_start: usize = 0;
    while (batch_start < missing.items.len) {
        const end = @min(batch_start + 32, missing.items.len);
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var batch_manager = manager;
        batch_manager.alloc = scratch.allocator();
        for (try batch_manager.retrievalObjects(missing.items[batch_start..end])) |object| _ = try cacheEntry(batch_manager, object.artifact, "", object.bytes);
        batch_start = end;
    }
    var hits: std.ArrayList(Hit) = .empty;
    var skipped: std.ArrayList(struct { path: []const u8, reason: []const u8 }) = .empty;
    var indexed: usize = 0;
    for (sources.items) |source| {
        const file = source.file;
        if (!contentPath(file.path) or file.mode == .symlink) continue;
        if (request.path == null and std.mem.startsWith(u8, file.path, "history/")) continue;
        if (request.path) |prefix| if (!std.mem.startsWith(u8, file.path, prefix)) continue;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var entry_manager = manager;
        entry_manager.alloc = scratch.allocator();
        const entry = try indexEntry(entry_manager, file);
        indexed += 1;
        if (!entry.complete) try skipped.append(alloc, .{ .path = file.path, .reason = try alloc.dupe(u8, entry.reason orelse "incomplete") });
        const match = score(request.query, file.path, entry.text);
        if (match.score == 0) continue;
        const start = utf8Boundary(entry.text, match.offset -| 160);
        const end = utf8Boundary(entry.text, @min(entry.text.len, start + 480));
        try hits.append(alloc, .{ .path = file.path, .artifact = file.artifact.?, .revision = source.revision, .excerpt = try alloc.dupe(u8, entry.text[start..end]), .byte_offset = start, .score = match.score, .complete = entry.complete });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn less(_: void, a: Hit, b: Hit) bool {
            return if (a.score == b.score) std.mem.lessThan(u8, a.path, b.path) else a.score > b.score;
        }
    }.less);
    const start = @min(request.offset, hits.items.len);
    const end = @min(hits.items.len, start + request.limit);
    return value(alloc, .{ .version = "omos.retrieval/v1", .workspace = manager.manifest.id, .revision = revision, .runtime_revision = runtime_revision, .query = request.query, .hits = hits.items[start..end], .total = hits.items.len, .next_offset = if (end < hits.items.len) @as(?usize, end) else null, .coverage = .{ .indexed_files = indexed, .complete = skipped.items.len == 0, .gaps = skipped.items[0..@min(skipped.items.len, 8)], .gap_count = skipped.items.len, .gaps_omitted = skipped.items.len - @min(skipped.items.len, 8), .scope = "personal knowledge and retained runtime projections; execution history requires an explicit history/ path filter; external company content and unprojected local sessions are not included" }, .authority = "search_preview" });
}

fn queryDocument(manager: workspace.Manager, request: Request, revision: []const u8) !std.json.Value {
    const alloc = manager.alloc;
    const path = request.path.?;
    if (!contentPath(path) or request.filters.len > 16 or request.pointer.len > 512) return error.InvalidRetrievalRequest;
    const files = try manager.fileManifest(revision);
    const file = for (files) |entry| {
        if (std.mem.eql(u8, entry.path, path)) break entry;
    } else return error.FileNotFound;
    if (file.mode == .symlink) return error.RetrievalPathDenied;
    const bytes = try manager.retrievalArtifact(file.artifact orelse return error.MissingArtifact);
    if (std.mem.startsWith(u8, bytes, "SQLite format 3\x00")) return @import("retrieval_database.zig").query(manager, request, revision, file.artifact.?, bytes);
    if (bytes.len > 8 * 1024 * 1024) return error.QueryDocumentTooLarge;
    const document = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{});
    const selected = try pointer(document, request.pointer);
    if (selected != .array) return error.QueryRequiresArray;
    const Row = struct { index: usize, record: std.json.Value, sort_value: []const u8, sort_number: ?f64 };
    var rows: std.ArrayList(Row) = .empty;
    for (selected.array.items, 0..) |record, index| {
        var include = true;
        for (request.filters) |filter| {
            const actual = pointer(record, filter.field) catch {
                include = false;
                break;
            };
            if (!std.mem.eql(u8, try scalar(alloc, actual), filter.equals)) {
                include = false;
                break;
            }
        }
        if (!include) continue;
        const sort_field: std.json.Value = if (request.order_by) |field| pointer(record, field) catch .null else .null;
        const sort_value = try scalar(alloc, sort_field);
        const sort_number: ?f64 = switch (sort_field) {
            .integer => @floatFromInt(sort_field.integer),
            .float => sort_field.float,
            else => null,
        };
        try rows.append(alloc, .{ .index = index, .record = record, .sort_value = sort_value, .sort_number = sort_number });
    }
    if (request.order_by != null) std.mem.sort(Row, rows.items, request.descending, struct {
        fn less(descending: bool, a: Row, b: Row) bool {
            if (a.sort_value.len == 0 or b.sort_value.len == 0) return a.sort_value.len > b.sort_value.len;
            if ((a.sort_number == null) != (b.sort_number == null)) return a.sort_number != null;
            if (a.sort_number) |number| {
                if (number == b.sort_number.?) return a.index < b.index;
                return if (descending) number > b.sort_number.? else number < b.sort_number.?;
            }
            if (std.mem.eql(u8, a.sort_value, b.sort_value)) return a.index < b.index;
            return if (descending) std.mem.lessThan(u8, b.sort_value, a.sort_value) else std.mem.lessThan(u8, a.sort_value, b.sort_value);
        }
    }.less);
    const start = @min(request.offset, rows.items.len);
    const end = @min(start + request.limit, rows.items.len);
    return value(alloc, .{ .version = "omos.retrieval/v1", .revision = revision, .path = path, .artifact = file.artifact, .pointer = request.pointer, .records = rows.items[start..end], .total = rows.items.len, .next_offset = if (end < rows.items.len) @as(?usize, end) else null, .ordering = "numbers first numerically; strings lexically (use normalised ISO timestamps); missing values last", .authority = "source_records" });
}

fn scalar(alloc: std.mem.Allocator, input: std.json.Value) ![]const u8 {
    return switch (input) {
        .string => input.string,
        .null => "",
        .integer, .float, .bool => std.json.Stringify.valueAlloc(alloc, input, .{}),
        else => error.QueryRequiresScalarField,
    };
}

fn pointer(root: std.json.Value, path: []const u8) !std.json.Value {
    if (path.len == 0) return root;
    var current = root;
    var fields = std.mem.splitScalar(u8, if (path[0] == '/') path[1..] else path, '/');
    while (fields.next()) |field| {
        if (current == .object) current = current.object.get(field) orelse return error.QueryFieldMissing else if (current == .array) {
            const index = std.fmt.parseInt(usize, field, 10) catch return error.QueryFieldMissing;
            if (index >= current.array.items.len) return error.QueryFieldMissing;
            current = current.array.items[index];
        } else return error.QueryFieldMissing;
    }
    return current;
}

fn contentPath(path: []const u8) bool {
    for ([_][]const u8{ "documents/", "memory/", "skills/", "artifacts/", "records/", "history/", "runtime/conversations/", "runtime/routing/", "runtime/attention/" }) |prefix| if (std.mem.startsWith(u8, path, prefix)) return true;
    return false;
}

fn indexEntry(manager: workspace.Manager, file: manifest.File) !Entry {
    const artifact = file.artifact orelse return error.MissingArtifact;
    if (!manifest.validHash(artifact)) return error.InvalidFossilRevision;
    const alloc = manager.alloc;
    if (unsupported(file.path)) |reason| return .{ .path = file.path, .artifact = artifact, .text = "", .complete = false, .reason = reason };
    const directory = try alloc.print("{s}/retrieval-v1", .{manager.root});
    try std.Io.Dir.cwd().createDirPath(io.getIo(), directory);
    const path = try alloc.print("{s}/{s}.json", .{ directory, artifact });
    if (std.Io.Dir.openFileAbsolute(io.getIo(), path, .{ .follow_symlinks = false })) |opened| {
        var cached = opened;
        defer cached.close(io.getIo());
        const raw = io.readFileToEnd(alloc, &cached, max_content_bytes * 8) catch "";
        if (std.json.parseFromSliceLeaky(Entry, alloc, raw, .{ .allocate = .alloc_always })) |entry| {
            if (std.mem.eql(u8, entry.artifact, artifact)) return .{ .path = file.path, .artifact = artifact, .text = entry.text, .complete = entry.complete, .reason = entry.reason };
        } else |_| {}
    } else |err| if (err != error.FileNotFound) return err;
    const bytes = try manager.retrievalArtifact(artifact);
    return cacheEntry(manager, artifact, file.path, bytes);
}

fn cacheEntry(manager: workspace.Manager, artifact: []const u8, file_path: []const u8, bytes: []const u8) !Entry {
    const alloc = manager.alloc;
    const path = try alloc.print("{s}/retrieval-v1/{s}.json", .{ manager.root, artifact });
    const binary = std.mem.findScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes);
    const pdf = std.mem.startsWith(u8, bytes, "%PDF-");
    const complete = !binary and !pdf and bytes.len <= max_content_bytes;
    const entry: Entry = .{ .path = file_path, .artifact = artifact, .text = if (binary or pdf) "" else bytes[0..utf8Boundary(bytes, @min(bytes.len, max_content_bytes))], .complete = complete, .reason = if (pdf) "pdf_text_not_extracted" else if (binary) "binary_content" else if (!complete) "content_size_limit" else null };
    try io.writeFileAtomic(alloc, path, try std.json.Stringify.valueAlloc(alloc, entry, .{}));
    return entry;
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    return null;
}

const Match = struct { score: usize, offset: usize };
fn score(query: []const u8, path: []const u8, body: []const u8) Match {
    var result: Match = .{ .score = 0, .offset = 0 };
    var tokens = std.mem.tokenizeAny(u8, query, " \n\r\t,?!\"'");
    while (tokens.next()) |token| {
        if (token.len < 2) continue;
        if (findIgnoreCase(path, token) != null) result.score += 3;
        if (findIgnoreCase(body, token)) |offset| {
            if (result.offset == 0) result.offset = offset;
            result.score += 1;
        }
    }
    return result;
}

fn value(alloc: std.mem.Allocator, data: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, data, .{}), .{});
}

test "retrieval ranks content and excludes implementation and authority paths" {
    try std.testing.expect(contentPath("documents/applications.json"));
    try std.testing.expect(!contentPath("ui/app.tsx"));
    try std.testing.expect(!contentPath("authority/grants.json"));
    try std.testing.expectEqual(@as(usize, 4), score("architect", "documents/Architect.md", "Applied for ARCHITECT").score);
    try std.testing.expectEqual(@as(usize, 0), score("architect", "documents/other.md", "unrelated").score);
}

fn utf8Boundary(bytes: []const u8, offset: usize) usize {
    var end = @min(offset, bytes.len);
    while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

test "retrieval slices preserve multibyte characters" {
    const text = "a€𐍈z";
    try std.testing.expectEqual(@as(usize, 1), utf8Boundary(text, 2));
    try std.testing.expectEqual(@as(usize, 4), utf8Boundary(text, 7));
    try std.testing.expectEqual(text.len, utf8Boundary(text, text.len));
}

fn unsupported(path: []const u8) ?[]const u8 {
    const ext = std.Io.Dir.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "pdf_text_not_extracted";
    if (std.ascii.eqlIgnoreCase(ext, ".sqlite") or std.ascii.eqlIgnoreCase(ext, ".db")) return "use_structured_database_query";
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ttf", ".woff", ".woff2", ".zip", ".gz" }) |binary| if (std.ascii.eqlIgnoreCase(ext, binary)) return "binary_content";
    return null;
}
