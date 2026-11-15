//! In-memory three-way line-level text and disjoint JSON object merge.
//! Pure and I/O-free; used by workspace auto-rebase before falling back to
//! explicit conflict resolution.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const MergeResult = union(enum) {
    merged: []u8,
    conflict: []const u8,
};

const max_dp_cells: usize = 1_000_000;

pub fn mergeUtf8(alloc: Allocator, base: []const u8, source: []const u8, target: []const u8) !MergeResult {
    if (std.mem.eql(u8, source, target)) {
        return .{ .merged = try alloc.dupe(u8, source) };
    }
    if (std.mem.eql(u8, source, base)) {
        return .{ .merged = try alloc.dupe(u8, target) };
    }
    if (std.mem.eql(u8, target, base)) {
        return .{ .merged = try alloc.dupe(u8, source) };
    }

    if (!isMergeableUtf8(base) or !isMergeableUtf8(source) or !isMergeableUtf8(target)) {
        return .{ .conflict = "binary_or_invalid_utf8" };
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (try mergeLines(arena, alloc, base, source, target)) |merged_text| {
        return .{ .merged = merged_text };
    }

    if (try mergeJsonObjectsBytes(arena, alloc, base, source, target)) |merged_json| {
        return .{ .merged = merged_json };
    }

    return .{ .conflict = "overlapping_edit" };
}

fn isMergeableUtf8(bytes: []const u8) bool {
    if (std.mem.findScalar(u8, bytes, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(bytes);
}

const SplitLines = struct {
    lines: []const []const u8,
    trailing_nl: bool,
};

fn splitLines(alloc: Allocator, bytes: []const u8) !SplitLines {
    if (bytes.len == 0) return .{ .lines = &.{}, .trailing_nl = false };
    const trailing_nl = bytes[bytes.len - 1] == '\n';
    const trimmed = if (trailing_nl) bytes[0 .. bytes.len - 1] else bytes;
    var list: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, trimmed, '\n');
    while (iter.next()) |line| {
        try list.append(alloc, line);
    }
    return .{
        .lines = try list.toOwnedSlice(alloc),
        .trailing_nl = trailing_nl,
    };
}

const Hunk = struct {
    base_start: usize,
    base_end: usize,
    lines: []const []const u8,
};

fn lineHashes(alloc: Allocator, lines: []const []const u8) ![]u64 {
    const hashes = try alloc.alloc(u64, lines.len);
    for (lines, 0..) |line, i| {
        hashes[i] = std.hash.Wyhash.hash(0, line);
    }
    return hashes;
}

fn extractHunks(alloc: Allocator, base: []const []const u8, side: []const []const u8) !?[]const Hunk {
    var prefix: usize = 0;
    while (prefix < base.len and prefix < side.len and std.mem.eql(u8, base[prefix], side[prefix])) {
        prefix += 1;
    }

    var suffix: usize = 0;
    while (prefix + suffix < base.len and
        prefix + suffix < side.len and
        std.mem.eql(u8, base[base.len - 1 - suffix], side[side.len - 1 - suffix]))
    {
        suffix += 1;
    }

    const b_mid = base[prefix .. base.len - suffix];
    const s_mid = side[prefix .. side.len - suffix];

    var hunks: std.ArrayList(Hunk) = .empty;
    if (b_mid.len == 0 and s_mid.len == 0) {
        return try hunks.toOwnedSlice(alloc);
    }
    if (b_mid.len == 0 or s_mid.len == 0) {
        try hunks.append(alloc, .{
            .base_start = prefix,
            .base_end = base.len - suffix,
            .lines = s_mid,
        });
        return try hunks.toOwnedSlice(alloc);
    }

    if (b_mid.len * s_mid.len > max_dp_cells) return null;

    const b_hashes = try lineHashes(alloc, b_mid);
    const s_hashes = try lineHashes(alloc, s_mid);
    const cols = s_mid.len + 1;
    const dp = try alloc.alloc(u32, (b_mid.len + 1) * cols);
    @memset(dp, 0);

    var i: usize = b_mid.len;
    while (i > 0) {
        i -= 1;
        var j: usize = s_mid.len;
        while (j > 0) {
            j -= 1;
            const idx = i * cols + j;
            if (b_hashes[i] == s_hashes[j] and std.mem.eql(u8, b_mid[i], s_mid[j])) {
                dp[idx] = dp[(i + 1) * cols + (j + 1)] + 1;
            } else {
                const down = dp[(i + 1) * cols + j];
                const right = dp[i * cols + (j + 1)];
                dp[idx] = if (down >= right) down else right;
            }
        }
    }

    var bi: usize = 0;
    var si: usize = 0;
    var cur_b: usize = 0;
    var cur_s: usize = 0;
    while (bi < b_mid.len and si < s_mid.len) {
        if (b_hashes[bi] == s_hashes[si] and std.mem.eql(u8, b_mid[bi], s_mid[si])) {
            if (bi > cur_b or si > cur_s) {
                try hunks.append(alloc, .{
                    .base_start = prefix + cur_b,
                    .base_end = prefix + bi,
                    .lines = s_mid[cur_s..si],
                });
            }
            bi += 1;
            si += 1;
            cur_b = bi;
            cur_s = si;
        } else if (dp[(bi + 1) * cols + si] >= dp[bi * cols + (si + 1)]) {
            bi += 1;
        } else {
            si += 1;
        }
    }
    if (b_mid.len > cur_b or s_mid.len > cur_s) {
        try hunks.append(alloc, .{
            .base_start = prefix + cur_b,
            .base_end = prefix + b_mid.len,
            .lines = s_mid[cur_s..s_mid.len],
        });
    }

    return try hunks.toOwnedSlice(alloc);
}

fn linesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn mergeLines(arena: Allocator, out_alloc: Allocator, base_bytes: []const u8, source_bytes: []const u8, target_bytes: []const u8) !?[]u8 {
    const base_split = try splitLines(arena, base_bytes);
    const source_split = try splitLines(arena, source_bytes);
    const target_split = try splitLines(arena, target_bytes);

    const trailing_nl = if (source_split.trailing_nl == target_split.trailing_nl)
        source_split.trailing_nl
    else if (source_split.trailing_nl == base_split.trailing_nl)
        target_split.trailing_nl
    else if (target_split.trailing_nl == base_split.trailing_nl)
        source_split.trailing_nl
    else
        return null;

    const source_hunks = (try extractHunks(arena, base_split.lines, source_split.lines)) orelse return null;
    const target_hunks = (try extractHunks(arena, base_split.lines, target_split.lines)) orelse return null;

    var out_lines: std.ArrayList([]const u8) = .empty;
    var base_pos: usize = 0;
    var si: usize = 0;
    var ti: usize = 0;

    while (si < source_hunks.len and ti < target_hunks.len) {
        const sh = source_hunks[si];
        const th = target_hunks[ti];

        if (sh.base_start == th.base_start and sh.base_end == th.base_end and linesEqual(sh.lines, th.lines)) {
            try out_lines.appendSlice(arena, base_split.lines[base_pos..sh.base_start]);
            try out_lines.appendSlice(arena, sh.lines);
            base_pos = sh.base_end;
            si += 1;
            ti += 1;
            continue;
        }

        // Check if strictly ordered without overlapping regions (touching only at an endpoint when at least one is non-empty range after/before).
        if (sh.base_end <= th.base_start and !(sh.base_start == sh.base_end and th.base_start == th.base_end and sh.base_start == th.base_start)) {
            try out_lines.appendSlice(arena, base_split.lines[base_pos..sh.base_start]);
            try out_lines.appendSlice(arena, sh.lines);
            base_pos = sh.base_end;
            si += 1;
            continue;
        }

        if (th.base_end <= sh.base_start and !(sh.base_start == sh.base_end and th.base_start == th.base_end and sh.base_start == th.base_start)) {
            try out_lines.appendSlice(arena, base_split.lines[base_pos..th.base_start]);
            try out_lines.appendSlice(arena, th.lines);
            base_pos = th.base_end;
            ti += 1;
            continue;
        }

        return null;
    }

    while (si < source_hunks.len) : (si += 1) {
        const sh = source_hunks[si];
        try out_lines.appendSlice(arena, base_split.lines[base_pos..sh.base_start]);
        try out_lines.appendSlice(arena, sh.lines);
        base_pos = sh.base_end;
    }
    while (ti < target_hunks.len) : (ti += 1) {
        const th = target_hunks[ti];
        try out_lines.appendSlice(arena, base_split.lines[base_pos..th.base_start]);
        try out_lines.appendSlice(arena, th.lines);
        base_pos = th.base_end;
    }
    try out_lines.appendSlice(arena, base_split.lines[base_pos..]);

    if (out_lines.items.len == 0) {
        if (trailing_nl) return try out_alloc.dupe(u8, "\n");
        return try out_alloc.alloc(u8, 0);
    }

    var total_len: usize = out_lines.items.len - 1 + (if (trailing_nl) @as(usize, 1) else 0);
    for (out_lines.items) |line| total_len += line.len;

    const result = try out_alloc.alloc(u8, total_len);
    var pos: usize = 0;
    for (out_lines.items, 0..) |line, idx| {
        if (idx > 0) {
            result[pos] = '\n';
            pos += 1;
        }
        @memcpy(result[pos .. pos + line.len], line);
        pos += line.len;
    }
    if (trailing_nl) {
        result[pos] = '\n';
        pos += 1;
    }
    std.debug.assert(pos == total_len);
    return result;
}

fn mergeJsonObjectsBytes(arena: Allocator, out_alloc: Allocator, base_bytes: []const u8, source_bytes: []const u8, target_bytes: []const u8) !?[]u8 {
    const base_src = if (std.mem.trim(u8, base_bytes, " \t\r\n").len == 0) "{}" else base_bytes;
    const base_val = std.json.parseFromSliceLeaky(std.json.Value, arena, base_src, .{ .allocate = .alloc_always }) catch return null;
    const source_val = std.json.parseFromSliceLeaky(std.json.Value, arena, source_bytes, .{ .allocate = .alloc_always }) catch return null;
    const target_val = std.json.parseFromSliceLeaky(std.json.Value, arena, target_bytes, .{ .allocate = .alloc_always }) catch return null;

    if (base_val != .object or source_val != .object or target_val != .object) return null;
    const merged = (try mergeJsonObjects(arena, base_val.object, source_val.object, target_val.object)) orelse return null;
    const encoded = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = merged }, .{});
    return try out_alloc.dupe(u8, encoded);
}

fn jsonValuesEqual(a: ?std.json.Value, b: ?std.json.Value) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    if (@backingInt(left) != @backingInt(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |v| v == right.bool,
        .integer => |v| v == right.integer,
        .float => |v| v == right.float,
        .number_string => |v| std.mem.eql(u8, v, right.number_string),
        .string => |v| std.mem.eql(u8, v, right.string),
        .array => |arr| blk: {
            if (arr.items.len != right.array.items.len) break :blk false;
            for (arr.items, right.array.items) |l_item, r_item| {
                if (!jsonValuesEqual(l_item, r_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |obj| blk: {
            if (obj.count() != right.object.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn mergeJsonObjects(arena: Allocator, base: std.json.ObjectMap, source: std.json.ObjectMap, target: std.json.ObjectMap) anyerror!?std.json.ObjectMap {
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    var order: std.ArrayList([]const u8) = .empty;

    for ([_]std.json.ObjectMap{ base, source, target }) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            if (!(try keys.getOrPut(arena, entry.key_ptr.*)).found_existing) {
                try order.append(arena, entry.key_ptr.*);
            }
        }
    }

    var merged: std.json.ObjectMap = .empty;
    for (order.items) |key| {
        const b = base.get(key);
        const s = source.get(key);
        const t = target.get(key);

        if (jsonValuesEqual(s, t)) {
            if (s) |val| try merged.put(arena, key, val);
            continue;
        }
        if (jsonValuesEqual(s, b)) {
            if (t) |val| try merged.put(arena, key, val);
            continue;
        }
        if (jsonValuesEqual(t, b)) {
            if (s) |val| try merged.put(arena, key, val);
            continue;
        }
        if (s != null and t != null and s.? == .object and t.? == .object) {
            if (b == null or b.? == .object) {
                const base_sub = if (b) |val| val.object else std.json.ObjectMap.empty;
                if (try mergeJsonObjects(arena, base_sub, s.?.object, t.?.object)) |sub| {
                    try merged.put(arena, key, .{ .object = sub });
                    continue;
                }
            }
        }
        return null;
    }
    return merged;
}

test "three_way_merge: non-overlapping line edits merge cleanly" {
    const alloc = std.testing.allocator;
    const base = "line 1\nline 2\nline 3\nline 4\nline 5\n";
    const source = "line 1 (source)\nline 2\nline 3\nline 4\nline 5\n";
    const target = "line 1\nline 2\nline 3\nline 4\nline 5 (target)\n";

    const res = try mergeUtf8(alloc, base, source, target);
    switch (res) {
        .merged => |bytes| {
            defer alloc.free(bytes);
            try std.testing.expectEqualStrings("line 1 (source)\nline 2\nline 3\nline 4\nline 5 (target)\n", bytes);
        },
        .conflict => return error.TestUnexpectedResult,
    }
}

test "three_way_merge: adjacent line edits and identical edits merge without conflict" {
    const alloc = std.testing.allocator;
    const base = "a\nb\nc\n";
    const source = "A\nb\nc\n";
    const target = "a\nB\nc\n";

    const res = try mergeUtf8(alloc, base, source, target);
    switch (res) {
        .merged => |bytes| {
            defer alloc.free(bytes);
            try std.testing.expectEqualStrings("A\nB\nc\n", bytes);
        },
        .conflict => return error.TestUnexpectedResult,
    }

    const same = try mergeUtf8(alloc, base, source, source);
    switch (same) {
        .merged => |bytes| {
            defer alloc.free(bytes);
            try std.testing.expectEqualStrings(source, bytes);
        },
        .conflict => return error.TestUnexpectedResult,
    }
}

test "three_way_merge: same-line text conflict returns conflict" {
    const alloc = std.testing.allocator;
    const base = "line 1\nshared line\nline 3\n";
    const source = "line 1\nsource edit\nline 3\n";
    const target = "line 1\ntarget edit\nline 3\n";

    const res = try mergeUtf8(alloc, base, source, target);
    try std.testing.expect(res == .conflict);

    const add_add = try mergeUtf8(alloc, "", "original result", "different result");
    try std.testing.expect(add_add == .conflict);
}

test "three_way_merge: disjoint single-line JSON objects merge cleanly while same-key conflicts fail" {
    const alloc = std.testing.allocator;
    const base = "{\"nested\":{\"keep\":true},\"a\":1}";
    const source = "{\"nested\":{\"keep\":true,\"s\":2},\"a\":1,\"b\":\"from-source\"}";
    const target = "{\"nested\":{\"keep\":true,\"t\":3},\"a\":1,\"c\":\"from-target\"}";

    const res = try mergeUtf8(alloc, base, source, target);
    switch (res) {
        .merged => |bytes| {
            defer alloc.free(bytes);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("a").?.integer);
            try std.testing.expectEqualStrings("from-source", parsed.value.object.get("b").?.string);
            try std.testing.expectEqualStrings("from-target", parsed.value.object.get("c").?.string);
            const nested = parsed.value.object.get("nested").?.object;
            try std.testing.expect(nested.get("keep").?.bool);
            try std.testing.expectEqual(@as(i64, 2), nested.get("s").?.integer);
            try std.testing.expectEqual(@as(i64, 3), nested.get("t").?.integer);
        },
        .conflict => return error.TestUnexpectedResult,
    }

    const conflicting = try mergeUtf8(alloc, base, "{\"a\":2}", "{\"a\":3}");
    try std.testing.expect(conflicting == .conflict);
}
