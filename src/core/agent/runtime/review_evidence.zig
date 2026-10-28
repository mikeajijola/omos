//! Bounded views of retained evidence. A preview is never proof of unseen bytes.
const std = @import("std");
const sort_utils = @import("../../shared/sort_utils.zig");
const types = @import("../../shared/types.zig");
const record_json = @import("../../shared/record_json.zig");
const io = @import("../../shared/io.zig");

/// A rebuildable host cache entry, never a canonical evidence record or a
/// model-supplied reference. Its bytes are checked before every retrieval.
pub const PayloadRef = struct { id: []const u8, path: []const u8, bytes: usize, sha256: []const u8, identity_sha256: ?[]const u8 = null };

/// Preserve the existing progress identity's canonical arguments/content/tool
/// object while hashing the large serialized prefix without another copy.
pub fn progressIdentity(alloc: std.mem.Allocator, payload: []const u8, tool: ?[]const u8) ![64]u8 {
    if (payload.len == 0 or payload[payload.len - 1] != '}') return error.InvalidContractEvidence;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(payload[0 .. payload.len - 1]);
    hash.update(",\"tool\":");
    hash.update(try std.json.Stringify.valueAlloc(alloc, tool, .{}));
    hash.update("}");
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

pub const Evidence = struct {
    id: []const u8,
    kind: enum { tool, candidate, workspace, context, verification } = .tool,
    tool: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    status: ?types.PersistedToolStatus = null,
    content: []const u8,
    action_id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    obligations: []const []const u8 = &.{},
    raw_call_id: ?[]const u8 = null,
    assistant_index: ?usize = null,
};

pub const IndexEntry = struct {
    id: []const u8,
    kind: @FieldType(Evidence, "kind"),
    tool: ?[]const u8,
    arguments: ?[]const u8,
    status: ?types.PersistedToolStatus,
    bytes: usize,
    sha256: []const u8,
    content: []const u8,
    complete: bool,
    action_id: ?[]const u8,
    source: ?[]const u8,
    obligations: []const []const u8,
    raw_call_id: ?[]const u8,
};

pub const View = struct {
    records: []const Evidence,
    inspected: []usize,
    payloads: []const []const u8,
    payload_refs: []const ?PayloadRef,
    payload_sizes: []const usize,
    payload_digests: []const []const u8,
    raw_ranges: std.ArrayList(struct { ordinal: usize, start: usize, end: usize }) = .empty,
    max_read_bytes: usize = 16384,

    pub fn rawInspected(self: View, ordinal: usize, offset: usize, bytes: usize) bool {
        var cursor = offset;
        while (cursor < offset + bytes) {
            var next = cursor;
            for (self.raw_ranges.items) |range| {
                if (range.ordinal == ordinal and range.start <= cursor) next = @max(next, range.end);
            }
            if (next == cursor) return false;
            cursor = next;
        }
        return true;
    }

    pub fn init(alloc: std.mem.Allocator, records: []const Evidence) !View {
        return initWithBacking(alloc, records, &.{});
    }

    pub fn initWithBacking(alloc: std.mem.Allocator, records: []const Evidence, backing: []const PayloadRef) !View {
        const inspected = try alloc.alloc(usize, records.len);
        @memset(inspected, 0);
        const payloads = try alloc.alloc([]const u8, records.len);
        const refs = try alloc.alloc(?PayloadRef, records.len);
        const sizes = try alloc.alloc(usize, records.len);
        const digests = try alloc.alloc([]const u8, records.len);
        var by_id: std.StringHashMapUnmanaged(PayloadRef) = .empty;
        for (backing) |reference| {
            if (reference.bytes <= 2048 or reference.bytes > 64 * 1024 * 1024 or reference.sha256.len != 64 or !std.mem.eql(u8, std.Io.Dir.path.basename(reference.path), reference.sha256)) return error.InvalidContractEvidence;
            for (reference.sha256) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidContractEvidence;
            if (reference.identity_sha256) |identity| {
                if (identity.len != 64) return error.InvalidContractEvidence;
                for (identity) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidContractEvidence;
            }
            const entry = try by_id.getOrPut(alloc, reference.id);
            if (entry.found_existing) return error.InvalidContractEvidence;
            entry.value_ptr.* = reference;
        }
        var matched: usize = 0;
        for (records, payloads, refs, sizes, digests) |record, *payload, *reference, *size, *digest| {
            reference.* = by_id.get(record.id);
            if (reference.*) |value| {
                matched += 1;
                payload.* = "";
                size.* = value.bytes;
                digest.* = value.sha256;
            } else {
                payload.* = try std.json.Stringify.valueAlloc(alloc, .{ .arguments = record.arguments, .content = record.content }, .{});
                size.* = payload.*.len;
                digest.* = try payloadHash(alloc, payload.*);
            }
        }
        if (matched != backing.len) return error.InvalidContractEvidence;
        return .{ .records = records, .inspected = inspected, .payloads = payloads, .payload_refs = refs, .payload_sizes = sizes, .payload_digests = digests };
    }

    pub fn payloadSize(self: View, ordinal: usize) usize {
        return self.payload_sizes[ordinal];
    }

    pub fn payloadDigest(self: View, ordinal: usize) []const u8 {
        return self.payload_digests[ordinal];
    }

    /// Callers use an independent scratch allocator and release one payload
    /// before loading another. The model still receives bounded byte ranges.
    pub fn loadPayload(self: View, alloc: std.mem.Allocator, ordinal: usize) ![]const u8 {
        const reference = self.payload_refs[ordinal] orelse return self.payloads[ordinal];
        if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
        var dir = try io.openDirAbsoluteNoFollow(std.Io.Dir.path.dirname(reference.path) orelse return error.InvalidContractEvidence, .{});
        defer dir.close(io.getIo());
        var file = try dir.openFile(io.getIo(), std.Io.Dir.path.basename(reference.path), .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(io.getIo());
        const stat = try file.stat(io.getIo());
        if (stat.kind != .file or stat.size != reference.bytes) return error.InvalidContractEvidence;
        const bytes = try io.readFileToEnd(alloc, &file, 64 * 1024 * 1024);
        if (!std.mem.eql(u8, reference.sha256, try payloadHash(alloc, bytes))) return error.InvalidContractEvidence;
        return bytes;
    }

    pub fn prefix(bytes: []const u8, limit: usize) []const u8 {
        var end = @min(bytes.len, limit);
        while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
        return bytes[0..end];
    }

    pub fn index(self: *View, alloc: std.mem.Allocator, offset: usize, limit: usize) ![]const IndexEntry {
        const start = @min(offset, self.records.len);
        const end = start + @min(@min(limit, 128), self.records.len - start);
        const result = try alloc.alloc(IndexEntry, end - start);
        for (self.records[start..end], result, start..) |record, *entry, ordinal| {
            const size = self.payloadSize(ordinal);
            const complete = size <= 2048;
            const content = if (complete) record.content else prefix(record.content, 256);
            if (complete) {
                self.inspected[ordinal] = size;
                try self.raw_ranges.append(alloc, .{ .ordinal = ordinal, .start = 0, .end = size });
            }
            entry.* = .{
                .id = record.id,
                .kind = record.kind,
                .tool = record.tool,
                .arguments = if (record.arguments) |args| if (complete) args else prefix(args, 512) else null,
                .status = record.status,
                .bytes = size,
                .sha256 = self.payloadDigest(ordinal),
                .content = content,
                .complete = complete,
                .action_id = record.action_id,
                .source = record.source,
                .obligations = record.obligations,
                .raw_call_id = record.raw_call_id,
            };
        }
        return result;
    }

    pub fn page(self: *View, alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const Command = struct { action: enum { list, read }, id: ?[]const u8 = null, offset: usize = 0, limit: usize = 16384 };
        const command = try record_json.decode(Command, alloc, raw, .{});
        if (command.limit == 0) return error.InvalidEvidenceOffset;
        if (command.action == .list) {
            const entries = try self.index(alloc, command.offset, @min(command.limit, 32));
            return std.json.Stringify.valueAlloc(alloc, .{
                .evidence = entries,
                .total = self.records.len,
                .nextOffset = if (command.offset < self.records.len and entries.len < self.records.len - command.offset) command.offset + entries.len else @as(?usize, null),
            }, .{});
        }
        const id = command.id orelse return error.InvalidContractEvidence;
        for (self.records, 0..) |record, ordinal| {
            if (!std.mem.eql(u8, record.id, id)) continue;
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const payload = try self.loadPayload(scratch.allocator(), ordinal);
            if (command.offset > payload.len or (command.offset < payload.len and (payload[command.offset] & 0xc0) == 0x80)) return error.InvalidEvidenceOffset;
            const chunk = prefix(payload[command.offset..], @min(command.limit, self.max_read_bytes));
            if (chunk.len == 0 and command.offset < payload.len) return error.InvalidEvidenceOffset;
            try self.raw_ranges.append(alloc, .{ .ordinal = ordinal, .start = command.offset, .end = command.offset + chunk.len });
            if (command.offset <= self.inspected[ordinal]) self.inspected[ordinal] = @max(self.inspected[ordinal], command.offset + chunk.len);
            return std.json.Stringify.valueAlloc(alloc, .{
                .id = id,
                .offset = command.offset,
                .content = chunk,
                .bytes = payload.len,
                .sha256 = self.payloadDigest(ordinal),
                .nextOffset = if (command.offset + chunk.len < payload.len) command.offset + chunk.len else @as(?usize, null),
                .fullyInspected = self.inspected[ordinal] == payload.len,
            }, .{});
        }
        return error.InvalidContractEvidence;
    }

    /// Exact relationship filters precede lexical discovery. Results retain their
    /// original identities; snippets never establish inspection of omitted bytes.
    pub fn retrieve(self: *View, alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const Command = struct {
            action: enum { query, search, related, coverage },
            id: ?[]const u8 = null,
            query: ?[]const u8 = null,
            kind: ?@FieldType(Evidence, "kind") = null,
            tool: ?[]const u8 = null,
            status: ?types.PersistedToolStatus = null,
            action_id: ?[]const u8 = null,
            source: ?[]const u8 = null,
            obligation: ?[]const u8 = null,
            offset: usize = 0,
            limit: usize = 16,
        };
        const command = try record_json.decode(Command, alloc, raw, .{});
        if (command.limit == 0) return error.InvalidEvidenceOffset;
        const limit = @min(command.limit, 32);
        if (command.action == .coverage) {
            const id = command.id orelse return error.InvalidContractEvidence;
            for (self.records, 0..) |record, ordinal| {
                if (!std.mem.eql(u8, record.id, id)) continue;
                const Gap = struct { offset: usize, bytes: usize };
                var gaps: std.ArrayList(Gap) = .empty;
                var cursor: usize = 0;
                while (cursor < self.payloadSize(ordinal)) {
                    var end = cursor;
                    var next = self.payloadSize(ordinal);
                    for (self.raw_ranges.items) |range| {
                        if (range.ordinal != ordinal) continue;
                        if (range.start <= cursor) end = @max(end, range.end) else next = @min(next, range.start);
                    }
                    end = @max(end, self.inspected[ordinal]);
                    if (end > cursor) {
                        cursor = end;
                        continue;
                    }
                    try gaps.append(alloc, .{ .offset = cursor, .bytes = next - cursor });
                    cursor = next;
                }
                return std.json.Stringify.valueAlloc(alloc, .{ .id = id, .sha256 = self.payloadDigest(ordinal), .bytes = self.payloadSize(ordinal), .missing = gaps.items }, .{});
            }
            return error.InvalidContractEvidence;
        }
        if (command.query) |query| if (query.len == 0 or query.len > 512) return error.InvalidEvidenceQuery;
        if (command.action == .search and command.query == null) return error.InvalidEvidenceQuery;
        var related_action: ?[]const u8 = null;
        if (command.action == .related) {
            const id = command.id orelse return error.InvalidContractEvidence;
            const record = for (self.records) |record| {
                if (std.mem.eql(u8, record.id, id)) break record;
            } else return error.InvalidContractEvidence;
            related_action = record.action_id orelse return error.MissingEvidenceRelationship;
        }
        var rows: std.ArrayList(IndexEntry) = .empty;
        var total: usize = 0;
        for (self.records, 0..) |record, ordinal| {
            if (command.kind) |kind| if (record.kind != kind) continue;
            if (command.status) |status| if (record.status != status) continue;
            if (!optionalMatch(command.tool, record.tool) or !optionalMatch(command.source, record.source) or !optionalMatch(command.action_id, record.action_id) or !optionalMatch(related_action, record.action_id)) continue;
            if (command.obligation) |id| {
                const matched = for (record.obligations) |obligation| {
                    if (std.mem.eql(u8, id, obligation)) break true;
                } else false;
                if (!matched) continue;
            }
            if (command.query) |query| {
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const value = try record_json.decode(struct { arguments: ?[]const u8, content: []const u8 }, scratch.allocator(), try self.loadPayload(scratch.allocator(), ordinal), .{});
                if (std.ascii.findIgnoreCase(value.content, query) == null and
                    std.ascii.findIgnoreCase(value.arguments orelse "", query) == null and
                    std.ascii.findIgnoreCase(record.tool orelse "", query) == null) continue;
            }
            if (total >= command.offset and rows.items.len < limit) try rows.appendSlice(alloc, try self.index(alloc, ordinal, 1));
            total += 1;
        }
        return std.json.Stringify.valueAlloc(alloc, .{ .evidence = rows.items, .total = total, .complete = true, .scope = "pinned_review_manifest", .nextOffset = if (command.offset +| rows.items.len < total) @as(?usize, command.offset + rows.items.len) else null }, .{});
    }

    /// Replay only pages whose complete payload hash still matches. The full
    /// regenerated bytes are included in the next assessor packet.
    pub fn restorePages(self: *View, alloc: std.mem.Allocator, saved: []const []const u8) ![]const std.json.Value {
        const Saved = struct { id: []const u8, offset: usize, bytes: usize, sha256: []const u8, content: []const u8 };
        var pages: std.ArrayList(Saved) = .empty;
        for (saved) |raw| {
            // List replies are journaled too, but contain no record bytes.
            const page_value = record_json.decode(Saved, alloc, raw, .{ .ignore_unknown_fields = true }) catch continue;
            try pages.append(alloc, page_value);
        }
        sort_utils.sort(Saved, pages.items, {}, struct {
            fn less(_: void, a: Saved, b: Saved) bool {
                const order = std.mem.order(u8, a.id, b.id);
                return order == .lt or (order == .eq and a.offset < b.offset);
            }
        }.less);
        var restored: std.ArrayList(std.json.Value) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var total: usize = 0;
        for (pages.items) |page_value| {
            if (page_value.content.len == 0) continue;
            const key = try alloc.print("{s}:{d}:{d}:{s}", .{ page_value.id, page_value.offset, page_value.content.len, page_value.sha256 });
            if (seen.contains(key)) continue;
            try seen.put(alloc, key, {});
            for (self.records, 0..) |record, i| {
                if (!std.mem.eql(u8, record.id, page_value.id)) continue;
                if (self.payloadSize(i) != page_value.bytes or !std.mem.eql(u8, self.payloadDigest(i), page_value.sha256)) break;
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const payload = try self.loadPayload(scratch.allocator(), i);
                if (page_value.offset > payload.len or page_value.content.len > payload.len - page_value.offset or !std.mem.eql(u8, payload[page_value.offset..][0..page_value.content.len], page_value.content)) break;
                if (page_value.offset + page_value.content.len <= self.inspected[i]) break;
                // Large records advance through independent segment decisions,
                // rather than accumulating all earlier raw pages in one packet.
                const previous_inspected = self.inspected[i];
                const regenerated = try self.page(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .action = "read", .id = page_value.id, .offset = page_value.offset, .limit = page_value.content.len }, .{}));
                if (total + regenerated.len > 160 * 1024) {
                    // This page was not delivered in the next packet.
                    self.raw_ranges.items.len -= 1;
                    self.inspected[i] = previous_inspected;
                    break;
                }
                total += regenerated.len;
                try restored.append(alloc, (try std.json.parseFromSlice(std.json.Value, alloc, regenerated, .{})).value);
                break;
            }
        }
        return restored.items;
    }

    pub fn requireInspected(self: View, id: []const u8) !void {
        for (self.records, 0..) |record, i| {
            if (!std.mem.eql(u8, record.id, id)) continue;
            if (self.inspected[i] != self.payloadSize(i)) return error.UninspectedContractEvidence;
            return;
        }
        return error.InvalidContractEvidence;
    }
};

fn optionalMatch(filter: ?[]const u8, value: ?[]const u8) bool {
    return if (filter) |expected| if (value) |actual| std.mem.eql(u8, expected, actual) else false else true;
}

test "completion review caps oversized record pages without losing records or inspecting previews" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try alloc.alloc(u8, 3000);
    @memset(content, 'x');
    @memcpy(content[0..6], "needle");
    var evidence: [65]Evidence = undefined;
    for (&evidence, 0..) |*record, index| record.* = .{
        .id = try std.fmt.allocPrint(alloc, "record-{d}", .{index}),
        .tool = "shell",
        .action_id = "shared-action",
        .content = content,
    };
    for ([_][]const u8{ "query", "search", "related" }) |action| {
        var view = try View.init(alloc, &evidence);
        var offset: usize = 0;
        while (true) {
            const request = try std.json.Stringify.valueAlloc(alloc, .{
                .action = action,
                .query = if (std.mem.eql(u8, action, "related")) @as(?[]const u8, null) else "needle",
                .id = if (std.mem.eql(u8, action, "related")) @as(?[]const u8, evidence[0].id) else null,
                .offset = offset,
                .limit = 50,
            }, .{});
            const page_value = (try std.json.parseFromSlice(std.json.Value, alloc, try view.retrieve(alloc, request), .{})).value;
            const rows = page_value.object.get("evidence").?.array.items;
            try std.testing.expectEqual(@min(@as(usize, 32), evidence.len - offset), rows.len);
            try std.testing.expectEqual(@as(i64, evidence.len), page_value.object.get("total").?.integer);
            for (rows, offset..) |row, index| {
                try std.testing.expectEqualStrings(evidence[index].id, row.object.get("id").?.string);
                try std.testing.expect(!row.object.get("complete").?.bool);
                try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected(evidence[index].id));
            }
            offset += rows.len;
            const next = page_value.object.get("nextOffset").?;
            if (next == .null) {
                try std.testing.expectEqual(evidence.len, offset);
                break;
            }
            try std.testing.expectEqual(@as(i64, @intCast(offset)), next.integer);
        }
        try std.testing.expectError(error.InvalidEvidenceOffset, view.retrieve(alloc, "{\"action\":\"query\",\"limit\":0}"));
        try std.testing.expectError(error.InvalidContractEvidence, view.page(alloc, "{\"action\":\"read\",\"id\":\"invented\"}"));
    }
}

test "completion review targeted retrieval preserves action relationships and inspection gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const large = try alloc.alloc(u8, 20000);
    @memset(large, 'x');
    @memcpy(large[15000..15006], "failed");
    var view = try View.init(alloc, &.{
        .{ .id = "a", .tool = "shell", .status = .failure, .action_id = "call-1", .source = "source-1", .content = large },
        .{ .id = "b", .tool = "read_file", .status = .success, .action_id = "call-2", .content = "Other result" },
    });
    const result = (try std.json.parseFromSlice(std.json.Value, alloc, try view.retrieve(alloc, "{\"action\":\"search\",\"query\":\"FAILED\",\"tool\":\"shell\"}"), .{})).value;
    try std.testing.expectEqual(@as(i64, 1), result.object.get("total").?.integer);
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected("a"));
    _ = try view.page(alloc, "{\"action\":\"read\",\"id\":\"a\",\"offset\":0,\"limit\":1000}");
    _ = try view.page(alloc, "{\"action\":\"read\",\"id\":\"a\",\"offset\":2000,\"limit\":1000}");
    const coverage = (try std.json.parseFromSlice(std.json.Value, alloc, try view.retrieve(alloc, "{\"action\":\"coverage\",\"id\":\"a\"}"), .{})).value;
    const missing = coverage.object.get("missing").?.array.items;
    try std.testing.expectEqual(@as(i64, 1000), missing[0].object.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 1000), missing[0].object.get("bytes").?.integer);
    const related = (try std.json.parseFromSlice(std.json.Value, alloc, try view.retrieve(alloc, "{\"action\":\"related\",\"id\":\"a\"}"), .{})).value;
    try std.testing.expectEqual(@as(i64, 1), related.object.get("total").?.integer);
    try std.testing.expectError(error.InvalidContractEvidence, view.retrieve(alloc, "{\"action\":\"related\",\"id\":\"invented\"}"));
}

fn payloadHash(alloc: std.mem.Allocator, payload: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    return alloc.dupe(u8, &std.fmt.bytesToHex(&digest, .lower));
}

test "completion review pages require contiguous inspection and preserve UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try alloc.alloc(u8, 40000);
    @memset(content, 'x');
    var view = try View.init(alloc, &.{.{ .id = "tool:large", .content = content }});
    _ = try view.index(alloc, 0, 128);
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected("tool:large"));
    _ = try view.page(alloc, "{\"action\":\"read\",\"id\":\"tool:large\",\"offset\":30000}");
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected("tool:large"));
    var offset: usize = 0;
    while (offset < content.len) : (offset += 16384) {
        _ = try view.page(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .action = "read", .id = "tool:large", .offset = offset }, .{}));
    }
    try view.requireInspected("tool:large");
    try std.testing.expectEqualStrings("", View.prefix("£", 1));
}

test "completion review restores record pages without interpreting manifest lists as records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try alloc.alloc(u8, 8192);
    @memset(content, 'x');
    var original = try View.init(alloc, &.{.{ .id = "receipt", .content = content }});
    const list = try original.page(alloc, "{\"action\":\"list\"}");
    const read = try original.page(alloc, "{\"action\":\"read\",\"id\":\"receipt\"}");
    var resumed = try View.init(alloc, original.records);
    const pages = try resumed.restorePages(alloc, &.{ list, read });
    try std.testing.expectEqual(@as(usize, 1), pages.len);
    try resumed.requireInspected("receipt");
    var changed = try View.init(alloc, &.{.{ .id = "receipt", .content = "changed" }});
    try std.testing.expectEqual(@as(usize, 0), (try changed.restorePages(alloc, &.{read})).len);
    try std.testing.expectError(error.UninspectedContractEvidence, changed.requireInspected("receipt"));
    try std.testing.expectError(error.InvalidEvidenceOffset, original.page(alloc, "{\"action\":\"read\",\"id\":\"receipt\",\"limit\":0}"));
}
