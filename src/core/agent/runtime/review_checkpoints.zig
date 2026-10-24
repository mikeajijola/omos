//! Independent segment assessments survive review budgets. The host binds each
//! decision to inspected bytes; neither a preview nor a saved cursor is proof.
const std = @import("std");
const sort_utils = @import("../../shared/sort_utils.zig");
const evidence = @import("review_evidence.zig");
const contract = @import("work_contract.zig");
const record_json = @import("../../shared/record_json.zig");

pub const Finding = struct {
    id: []const u8,
    verdict: enum { supports, contradicts, irrelevant },
    note: []const u8,
};
pub const Submission = struct {
    id: []const u8,
    offset: usize,
    bytes: usize,
    obligations: []const Finding,
};
const Receipt = struct {
    contract_id: []const u8,
    version: u32,
    segment: Submission,
    sha256: []const u8,
    segment_sha256: []const u8,
};
const Counts = struct {
    id: []const u8,
    supports: usize = 0,
    contradicts: usize = 0,
    irrelevant: usize = 0,
    supporting_finding: ?[]const u8 = null,
    contradicting_finding: ?[]const u8 = null,
};
const Record = struct {
    id: []const u8,
    sha256: []const u8,
    bytes: usize,
    assessed_bytes: usize = 0,
    segments: usize = 0,
    obligations: []Counts,
};

pub const Ledger = struct {
    definition: contract.Definition,
    records: []Record,

    pub fn init(alloc: std.mem.Allocator, definition: contract.Definition, view: evidence.View) !Ledger {
        const records = try alloc.alloc(Record, view.records.len);
        for (view.records, records, 0..) |record, *out, i| {
            const counts = try alloc.alloc(Counts, definition.obligations.len);
            for (definition.obligations, counts) |obligation, *count| count.* = .{ .id = obligation.id };
            out.* = .{ .id = record.id, .sha256 = view.payloadDigest(i), .bytes = view.payloadSize(i), .obligations = counts };
        }
        return .{ .definition = definition, .records = records };
    }

    fn ordinal(self: Ledger, id: []const u8) !usize {
        for (self.records, 0..) |record, i| if (std.mem.eql(u8, record.id, id)) return i;
        return error.InvalidContractEvidence;
    }

    fn validate(self: Ledger, segment: Submission, payload: []const u8, prefix: usize) !void {
        if (segment.offset != prefix or segment.bytes == 0 or segment.offset > payload.len or segment.bytes > payload.len - segment.offset) return error.InvalidEvidenceOffset;
        const end = segment.offset + segment.bytes;
        if ((segment.offset < payload.len and (payload[segment.offset] & 0xc0) == 0x80) or (end < payload.len and (payload[end] & 0xc0) == 0x80)) return error.InvalidEvidenceOffset;
        if (segment.obligations.len != self.definition.obligations.len) return error.InvalidContractAssessment;
        for (self.definition.obligations) |obligation| {
            var found: usize = 0;
            for (segment.obligations) |finding| if (std.mem.eql(u8, finding.id, obligation.id)) {
                if (finding.note.len == 0 or finding.note.len > 256) return error.InvalidContractAssessment;
                found += 1;
            };
            if (found != 1) return error.InvalidContractAssessment;
        }
    }

    fn apply(self: *Ledger, i: usize, segment: Submission) void {
        const record = &self.records[i];
        record.assessed_bytes += segment.bytes;
        record.segments += 1;
        for (record.obligations) |*counts| for (segment.obligations) |finding| {
            if (!std.mem.eql(u8, counts.id, finding.id)) continue;
            switch (finding.verdict) {
                .supports => {
                    counts.supports += 1;
                    counts.supporting_finding = finding.note;
                },
                .contradicts => {
                    counts.contradicts += 1;
                    counts.contradicting_finding = finding.note;
                },
                .irrelevant => counts.irrelevant += 1,
            }
        };
    }

    pub fn submit(self: *Ledger, alloc: std.mem.Allocator, view: evidence.View, raw: []const u8) ![]const u8 {
        const segment = try record_json.decode(Submission, alloc, raw, .{});
        const i = try self.ordinal(segment.id);
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const payload = try view.loadPayload(scratch.allocator(), i);
        try self.validate(segment, payload, self.records[i].assessed_bytes);
        // Only raw bytes delivered in this attempt may establish a new decision.
        if (!view.rawInspected(i, segment.offset, segment.bytes)) return error.UninspectedContractEvidence;
        const receipt: Receipt = .{
            .contract_id = self.definition.id,
            .version = self.definition.version,
            .segment = segment,
            .sha256 = self.records[i].sha256,
            .segment_sha256 = try digest(alloc, payload[segment.offset..][0..segment.bytes]),
        };
        self.apply(i, segment);
        return std.json.Stringify.valueAlloc(alloc, receipt, .{});
    }

    pub fn restore(self: *Ledger, alloc: std.mem.Allocator, view: *evidence.View, saved: []const []const u8) !void {
        var receipts: std.ArrayList(Receipt) = .empty;
        for (saved) |raw| {
            const receipt = record_json.decode(Receipt, alloc, raw, .{}) catch continue;
            try receipts.append(alloc, receipt);
        }
        sort_utils.sort(Receipt, receipts.items, {}, struct {
            fn less(_: void, a: Receipt, b: Receipt) bool {
                const order = std.mem.order(u8, a.segment.id, b.segment.id);
                return order == .lt or (order == .eq and a.segment.offset < b.segment.offset);
            }
        }.less);
        for (receipts.items) |receipt| {
            if (!std.mem.eql(u8, receipt.contract_id, self.definition.id) or receipt.version != self.definition.version) continue;
            const i = self.ordinal(receipt.segment.id) catch continue;
            if (!std.mem.eql(u8, receipt.sha256, self.records[i].sha256)) continue;
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const payload = try view.loadPayload(scratch.allocator(), i);
            self.validate(receipt.segment, payload, self.records[i].assessed_bytes) catch continue;
            if (!std.mem.eql(u8, receipt.segment_sha256, try digest(alloc, payload[receipt.segment.offset..][0..receipt.segment.bytes]))) continue;
            self.apply(i, receipt.segment);
            view.inspected[i] = @max(view.inspected[i], self.records[i].assessed_bytes);
        }
    }

    pub fn index(self: Ledger, alloc: std.mem.Allocator, offset: usize, limit: usize) ![]const Record {
        var result: std.ArrayList(Record) = .empty;
        const start = @min(offset, self.records.len);
        const end = start + @min(limit, self.records.len - start);
        var bytes: usize = 0;
        for (self.records[start..end]) |record| if (record.segments > 0) {
            const size = (try std.json.Stringify.valueAlloc(alloc, record, .{})).len;
            if (bytes + size > 128 * 1024) break;
            bytes += size;
            try result.append(alloc, record);
        };
        return result.toOwnedSlice(alloc);
    }

    pub fn page(self: Ledger, alloc: std.mem.Allocator, view: *evidence.View, raw: []const u8) ![]const u8 {
        const Command = struct { action: []const u8, id: ?[]const u8 = null, offset: usize = 0, limit: usize = 32 };
        const command = try record_json.decode(Command, alloc, raw, .{});
        if (std.mem.eql(u8, command.action, "assessments")) {
            const i = try self.ordinal(command.id orelse return error.InvalidContractEvidence);
            return std.json.Stringify.valueAlloc(alloc, .{ .previousAssessments = try self.index(alloc, i, 1) }, .{});
        }
        var result = (try std.json.parseFromSlice(std.json.Value, alloc, try view.page(alloc, raw), .{})).value;
        const start = if (command.id) |id| try self.ordinal(id) else command.offset;
        // Preserve the typed read/list reply and attach only assessments for its
        // visible manifest range. Other decisions remain discoverable by ID.
        const value = (try std.json.parseFromSlice(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, try self.index(alloc, start, if (command.id != null) 1 else @min(command.limit, 32)), .{}), .{})).value;
        try result.object.put(alloc, "previousAssessments", value);
        return std.json.Stringify.valueAlloc(alloc, result, .{});
    }

    pub fn verify(self: Ledger, view: evidence.View, obligation: []const u8, id: []const u8) !void {
        const i = try self.ordinal(id);
        const record = self.records[i];
        if (record.segments == 0 or view.rawInspected(i, 0, view.payloadSize(i))) return;
        for (record.obligations) |counts| if (std.mem.eql(u8, counts.id, obligation)) {
            if (counts.supports == 0 or counts.contradicts > 0) return error.InvalidContractEvidence;
            return;
        };
        return error.InvalidContractAssessment;
    }
};

fn digest(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return alloc.dupe(u8, &std.fmt.bytesToHex(&hash, .lower));
}

test "completion review checkpoints advance across a record larger than every packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try alloc.alloc(u8, 1024 * 1024);
    @memset(content, 'x');
    const records = [_]evidence.Evidence{.{ .id = "large-receipt", .content = content, .status = .success }};
    const definition: contract.Definition = .{ .id = "task", .version = 1, .objective = "Verify receipt", .obligations = &.{.{ .id = "complete", .description = "Verify complete receipt" }} };
    var receipts: std.ArrayList([]const u8) = .empty;
    var prefix: usize = 0;
    for (0..100) |_| {
        var view = try evidence.View.init(alloc, &records);
        var ledger = try Ledger.init(alloc, definition, view);
        try ledger.restore(alloc, &view, receipts.items);
        try std.testing.expectEqual(prefix, ledger.records[0].assessed_bytes);
        if (prefix == view.payloads[0].len) {
            try view.requireInspected("large-receipt");
            try ledger.verify(view, "complete", "large-receipt");
            return;
        }
        const start = prefix;
        // Seven retrievals and one independent decision fit one attempt.
        for (0..7) |_| {
            const raw = try view.page(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .action = "read", .id = "large-receipt", .offset = prefix }, .{}));
            const page = (try std.json.parseFromSlice(std.json.Value, alloc, raw, .{})).value;
            prefix += page.object.get("content").?.string.len;
            if (prefix == view.payloads[0].len) break;
        }
        const raw = try std.json.Stringify.valueAlloc(alloc, Submission{ .id = "large-receipt", .offset = start, .bytes = prefix - start, .obligations = &.{.{ .id = "complete", .verdict = .supports, .note = "Verified this receipt segment against the requested fixture." }} }, .{});
        try receipts.append(alloc, try ledger.submit(alloc, view, raw));
        try std.testing.expectError(error.InvalidEvidenceOffset, ledger.submit(alloc, view, raw));
        try std.testing.expect((try std.json.Stringify.valueAlloc(alloc, try ledger.index(alloc, 0, 128), .{})).len < 4096);
    }
    return error.TestUnexpectedResult;
}

test "completion review checkpoints reject unseen bytes and invalidate changed evidence or contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const definition: contract.Definition = .{ .id = "task", .version = 1, .objective = "Verify", .obligations = &.{.{ .id = "complete", .description = "Verify" }} };
    const records = [_]evidence.Evidence{.{ .id = "receipt", .content = "original", .status = .success }};
    var view = try evidence.View.init(alloc, &records);
    var ledger = try Ledger.init(alloc, definition, view);
    const submission: Submission = .{ .id = "receipt", .offset = 0, .bytes = view.payloads[0].len, .obligations = &.{.{ .id = "complete", .verdict = .contradicts, .note = "The receipt reports failure." }} };
    const raw = try std.json.Stringify.valueAlloc(alloc, submission, .{});
    try std.testing.expectError(error.UninspectedContractEvidence, ledger.submit(alloc, view, raw));
    _ = try view.page(alloc, "{\"action\":\"read\",\"id\":\"receipt\"}");
    const receipt = try ledger.submit(alloc, view, raw);
    var resumed = try evidence.View.init(alloc, &records);
    var restored = try Ledger.init(alloc, definition, resumed);
    try restored.restore(alloc, &resumed, &.{ receipt, receipt });
    try resumed.requireInspected("receipt");
    try std.testing.expectEqual(@as(usize, 1), restored.records[0].segments);
    try std.testing.expectError(error.InvalidContractEvidence, restored.verify(resumed, "complete", "receipt"));
    var changed = try evidence.View.init(alloc, &.{.{ .id = "receipt", .content = "modified" }});
    var stale = try Ledger.init(alloc, definition, changed);
    try stale.restore(alloc, &changed, &.{receipt});
    try std.testing.expectEqual(@as(usize, 0), stale.records[0].segments);
    var next = definition;
    next.version += 1;
    var stale_contract = try Ledger.init(alloc, next, resumed);
    try stale_contract.restore(alloc, &resumed, &.{receipt});
    try std.testing.expectEqual(@as(usize, 0), stale_contract.records[0].segments);
}
