//! Exact-value factoring for an actor-only MCP result view. Canonical bytes are
//! never rewritten. A caller must authenticate the retained companion first.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Limits = struct {
    input_bytes: usize = 256 * 1024,
    depth: usize = 32,
    candidates: usize = 16,
    targets: usize = 256,
    comparison_nodes: usize = 100_000,
    replacements: usize = 16,
};
pub const Source = struct {
    handle: []const u8,
    bytes: usize,
    sha256: []const u8,
    evidence_id: []const u8,
    retained_text_prefix: []const u8 = "",
};
const Target = struct { path: []const u8, value: Value };
const Part = union(enum) { literal: []const u8, jsonPointer: []const u8 };
const Work = struct { limits: Limits, comparisons: usize = 0, spans: usize = 0, replacements: usize = 0 };

/// Null is the conservative unchanged fallback. This function does not read
/// files, grant permissions, record inspection, or persist evidence.
pub fn project(alloc: Allocator, canonical: []const u8, source: Source, inline_cap: usize, limits: Limits) !?[]u8 {
    if (canonical.len != source.bytes or canonical.len > limits.input_bytes or inline_cap == 0) return null;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    return projectInner(alloc, scratch.allocator(), canonical, source, @min(inline_cap, 16 * 1024), limits) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn projectInner(alloc: Allocator, arena: Allocator, canonical: []const u8, source: Source, cap: usize, limits: Limits) !?[]u8 {
    try checkDepth(canonical, limits.depth);
    var parsed = try std.json.parseFromSlice(Value, arena, canonical, .{ .parse_numbers = false });
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.getPtr("result") orelse return null;
    if (result.* != .object or result.object.contains("truncated")) return null;
    const structured = result.object.get("structuredContent") orelse return null;
    if (structured != .object and structured != .array) return null;
    const content = result.object.getPtr("content") orelse return null;
    if (content.* != .array) return null;
    var targets: std.ArrayList(Target) = .empty;
    try collectTargets(arena, structured, "/result/structuredContent", 0, limits, &targets);
    var work: Work = .{ .limits = limits };
    for (content.array.items) |*item| {
        if (item.* != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const field = item.object.getPtr("text") orelse continue;
        if (field.* != .string) return null;
        const text = field.string;
        var parts: std.ArrayList(Part) = .empty;
        var cursor: usize = 0;
        var retained_start: usize = 0;
        var changed = false;
        while (cursor < text.len) {
            const relative = std.mem.findAny(u8, text[cursor..], "{[") orelse break;
            const start = cursor + relative;
            work.spans += 1;
            if (work.spans > limits.candidates) return error.ProjectionBudgetExceeded;
            const end = try spanEnd(text, start, limits.depth);
            const candidate = try std.json.parseFromSliceLeaky(Value, arena, text[start..end], .{ .parse_numbers = false });
            var match: ?[]const u8 = null;
            for (targets.items) |target| {
                if (try equalValue(candidate, target.value, &work, 0)) {
                    if (match != null) return error.AmbiguousProjection;
                    match = target.path;
                }
            }
            if (match) |path| {
                if (end - start >= 256) {
                    work.replacements += 1;
                    if (work.replacements > limits.replacements) return error.ProjectionBudgetExceeded;
                    try parts.append(arena, .{ .literal = text[retained_start..start] });
                    try parts.append(arena, .{ .jsonPointer = path });
                    retained_start = end;
                    changed = true;
                }
            }
            cursor = end;
        }
        if (changed) {
            try parts.append(arena, .{ .literal = text[retained_start..] });
            const replacement = try std.json.Stringify.valueAlloc(arena, .{ .factoredText = parts.items }, .{});
            field.* = try std.json.parseFromSliceLeaky(Value, arena, replacement, .{ .parse_numbers = false });
        }
    }
    if (work.replacements == 0) return null;
    const rendered = try std.json.Stringify.valueAlloc(arena, .{
        .kind = "omos.mcp-model-view/v1",
        .verbatim = false,
        .canonical = .{ .handle = source.handle, .bytes = source.bytes, .sha256 = source.sha256, .evidence_id = source.evidence_id },
        .retained_text_prefix = source.retained_text_prefix,
        .pointer_base = "envelope",
        .envelope = parsed.value,
    }, .{});
    if (rendered.len >= canonical.len or rendered.len > cap) return null;
    return try alloc.dupe(u8, rendered);
}

fn pointerChild(alloc: Allocator, path: []const u8, key: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, path);
    try out.append(alloc, '/');
    for (key) |c| switch (c) {
        '~' => try out.appendSlice(alloc, "~0"),
        '/' => try out.appendSlice(alloc, "~1"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

fn collectTargets(alloc: Allocator, value: Value, path: []const u8, depth: usize, limits: Limits, targets: *std.ArrayList(Target)) (Allocator.Error || error{ProjectionBudgetExceeded})!void {
    if (depth > limits.depth) return error.ProjectionBudgetExceeded;
    if (value != .object and value != .array) return;
    if (targets.items.len >= limits.targets) return error.ProjectionBudgetExceeded;
    try targets.append(alloc, .{ .path = path, .value = value });
    switch (value) {
        .object => |object| {
            var entries = object.iterator();
            while (entries.next()) |entry| try collectTargets(alloc, entry.value_ptr.*, try pointerChild(alloc, path, entry.key_ptr.*), depth + 1, limits, targets);
        },
        .array => |array| for (array.items, 0..) |item, index| try collectTargets(alloc, item, try alloc.print("{s}/{d}", .{ path, index }), depth + 1, limits, targets),
        else => unreachable,
    }
}

fn equalValue(left: Value, right: Value, work: *Work, depth: usize) error{ProjectionBudgetExceeded}!bool {
    work.comparisons += 1;
    if (work.comparisons > work.limits.comparison_nodes or depth > work.limits.depth) return error.ProjectionBudgetExceeded;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |v| v == right.bool,
        .string => |v| std.mem.eql(u8, v, right.string),
        .number_string => |v| std.mem.eql(u8, v, right.number_string),
        // Both trees are parsed with parse_numbers=false; rejecting other numeric
        // representations avoids accidental coercion or floating-point loss.
        .integer, .float => false,
        .array => |array| blk: {
            if (array.items.len != right.array.items.len) break :blk false;
            for (array.items, right.array.items) |a, b| if (!try equalValue(a, b, work, depth + 1)) break :blk false;
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var entries = object.iterator();
            while (entries.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!try equalValue(entry.value_ptr.*, other, work, depth + 1)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn spanEnd(text: []const u8, start: usize, max_depth: usize) !usize {
    var expected: [64]u8 = undefined;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    var cursor = start;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') {
            quoted = true;
            continue;
        }
        if (c == '{' or c == '[') {
            if (depth >= @min(max_depth, expected.len)) return error.ProjectionBudgetExceeded;
            expected[depth] = if (c == '{') '}' else ']';
            depth += 1;
        } else if (c == '}' or c == ']') {
            if (depth == 0 or expected[depth - 1] != c) return error.InvalidProjectionJson;
            depth -= 1;
            if (depth == 0) return cursor + 1;
        }
    }
    return error.InvalidProjectionJson;
}

fn checkDepth(bytes: []const u8, max_depth: usize) !void {
    const start = std.mem.findAny(u8, bytes, "{[") orelse return error.InvalidProjectionJson;
    _ = try spanEnd(bytes, start, max_depth);
}

fn sampleEnvelope(alloc: Allocator, padding: usize, duplicate_target: bool, candidate_number: []const u8, structured_number: []const u8) ![]u8 {
    const repeated = try alloc.alloc(u8, padding);
    defer alloc.free(repeated);
    @memset(repeated, 'x');
    const candidate = try alloc.print("{{\"n\":{s},\"body\":\"{s}\"}}", .{ candidate_number, repeated });
    defer alloc.free(candidate);
    const structured_json = try alloc.print("{{\"n\":{s},\"body\":\"{s}\"}}", .{ structured_number, repeated });
    defer alloc.free(structured_json);
    var parsed = try std.json.parseFromSlice(Value, alloc, structured_json, .{ .parse_numbers = false });
    defer parsed.deinit();
    const text = try alloc.print("Warning: retain this exact Unicode α.\nok\nreturn: {s}\nFinal warning: preserve me too.", .{candidate});
    defer alloc.free(text);
    const structured = if (duplicate_target)
        try std.json.Stringify.valueAlloc(alloc, .{ .left = parsed.value, .right = parsed.value }, .{})
    else
        try std.json.Stringify.valueAlloc(alloc, .{ .value = parsed.value }, .{});
    defer alloc.free(structured);
    var structured_value = try std.json.parseFromSlice(Value, alloc, structured, .{ .parse_numbers = false });
    defer structured_value.deinit();
    return std.json.Stringify.valueAlloc(alloc, .{
        .server = "fixture",
        .tool = "mcp_fixture_run",
        .result = .{
            .content = .{
                .{ .type = "text", .text = text, .annotations = .{ .priority = 0.5 } },
                .{ .type = "text", .text = "A separate unique tip." },
                .{ .type = "image", .data = "media remains unchanged", .mimeType = "image/png" },
            },
            .structuredContent = structured_value.value,
            .isError = true,
            ._meta = .{ .request = "preserve metadata" },
        },
    }, .{});
}

fn sampleSource(alloc: Allocator, raw: []const u8) !Source {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
    const hex = try alloc.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
    return .{ .handle = "result-fixture-call-content.txt", .bytes = raw.len, .sha256 = hex, .evidence_id = "canonical-tool-output:fixture-binding" };
}

test "MCP actor projection factors wrapped exact JSON below inline threshold without losing distinct content" {
    const alloc = std.testing.allocator;
    const raw = try sampleEnvelope(alloc, 13_000, false, "1", "1");
    defer alloc.free(raw);
    var source = try sampleSource(alloc, raw);
    defer alloc.free(source.sha256);
    source.retained_text_prefix = "Saved images: image-fixture. Use read_tool_result to recover the image.\n";
    const projected = (try project(alloc, raw, source, 16 * 1024, .{})) orelse return error.TestExpectedProjection;
    defer alloc.free(projected);
    try std.testing.expect(raw.len > 16 * 1024);
    try std.testing.expect(projected.len < 16 * 1024);
    var parsed = try std.json.parseFromSlice(Value, alloc, projected, .{ .parse_numbers = false });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("verbatim").?.bool);
    try std.testing.expectEqualStrings(source.retained_text_prefix, parsed.value.object.get("retained_text_prefix").?.string);
    const result = parsed.value.object.get("envelope").?.object.get("result").?;
    try std.testing.expect(result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array.items;
    const parts = content[0].object.get("text").?.object.get("factoredText").?.array.items;
    try std.testing.expectEqualStrings("Warning: retain this exact Unicode α.\nok\nreturn: ", parts[0].object.get("literal").?.string);
    try std.testing.expectEqualStrings("/result/structuredContent/value", parts[1].object.get("jsonPointer").?.string);
    try std.testing.expectEqualStrings("\nFinal warning: preserve me too.", parts[2].object.get("literal").?.string);
    try std.testing.expectEqualStrings("A separate unique tip.", content[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("media remains unchanged", content[2].object.get("data").?.string);
    try std.testing.expectEqualStrings("0.5", content[0].object.get("annotations").?.object.get("priority").?.number_string);
    try std.testing.expectEqualStrings("preserve metadata", result.object.get("_meta").?.object.get("request").?.string);
    try std.testing.expect(try project(alloc, projected, .{ .handle = source.handle, .bytes = projected.len, .sha256 = source.sha256, .evidence_id = source.evidence_id }, 16 * 1024, .{}) == null);
}

test "MCP projection rejects unequal JSON types numeric lexemes and ambiguous identical targets" {
    const alloc = std.testing.allocator;
    const pairs = [_][2][]const u8{ .{ "1", "\"1\"" }, .{ "1", "1.0" }, .{ "-0", "0" }, .{ "true", "1" }, .{ "null", "false" } };
    for (pairs) |pair| {
        const raw = try sampleEnvelope(alloc, 512, false, pair[0], pair[1]);
        defer alloc.free(raw);
        const source = try sampleSource(alloc, raw);
        defer alloc.free(source.sha256);
        try std.testing.expect(try project(alloc, raw, source, 16 * 1024, .{}) == null);
    }
    const raw = try sampleEnvelope(alloc, 512, true, "1", "1");
    defer alloc.free(raw);
    const source = try sampleSource(alloc, raw);
    defer alloc.free(source.sha256);
    try std.testing.expect(try project(alloc, raw, source, 16 * 1024, .{}) == null);
}

test "MCP projection resource limits preserve unchanged fallback" {
    const alloc = std.testing.allocator;
    const raw = try sampleEnvelope(alloc, 512, false, "1", "1");
    defer alloc.free(raw);
    const source = try sampleSource(alloc, raw);
    defer alloc.free(source.sha256);
    const limits = [_]Limits{ .{ .input_bytes = 32 }, .{ .depth = 1 }, .{ .candidates = 0 }, .{ .targets = 0 }, .{ .comparison_nodes = 0 }, .{ .replacements = 0 } };
    for (limits) |limit| try std.testing.expect(try project(alloc, raw, source, 16 * 1024, limit) == null);
    try std.testing.expect(try project(alloc, raw, source, 100, .{}) == null);
    var wrong_size = source;
    wrong_size.bytes += 1;
    try std.testing.expect(try project(alloc, raw, wrong_size, 16 * 1024, .{}) == null);
}

test "JSON candidate scanner respects escaped quotes and rejects mismatched or incomplete nesting" {
    try std.testing.expectEqual(@as(usize, 17), try spanEnd("{\"text\":\"} [ \\\"\"} trailing", 0, 32));
    try std.testing.expectError(error.InvalidProjectionJson, spanEnd("{]", 0, 32));
    try std.testing.expectError(error.InvalidProjectionJson, spanEnd("{\"text\":\"unterminated", 0, 32));
    try std.testing.expectError(error.ProjectionBudgetExceeded, spanEnd("[[[]]]", 0, 2));
}
