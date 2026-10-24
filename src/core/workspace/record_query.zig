//! Bounded query projections. Counting and skipping rows never retains bodies;
//! selected large records remain references to their immutable originals.
const std = @import("std");
const model = @import("definition.zig");
const projection = @import("record_projection.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Page = struct {
    alloc: Allocator,
    offset: usize,
    revision: []const u8,
    records: std.ArrayList(Value) = .empty,
    relationships: std.ArrayList(projection.Edge) = .empty,
    total: usize = 0,
    relationship_total: usize = 0,
    bytes: usize = 0,
    sealed: bool = false,

    pub fn add(self: *Page, manager: anytype, row: Value) !void {
        const index = self.total;
        self.total += 1;
        if (index < self.offset or self.sealed or self.records.items.len == 32) return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var reader = manager;
        reader.alloc = a;
        const encoded = try std.json.Stringify.valueAlloc(a, row, .{});
        const bounded = if (encoded.len <= 8192) encoded else blk: {
            const entity = model.text(row, "entity");
            const id = model.text(row, "id");
            const explicit_path = model.text(row, "source_path");
            const path = if (explicit_path.len > 0) explicit_path else if (std.mem.eql(u8, entity, "omos_task")) try a.print("tasks/{s}.json", .{id}) else model.declaration_path;
            const own_revision = model.text(row, "revision");
            const revision = if (own_revision.len > 0) own_revision else self.revision;
            const original = try reader.contentAt(path, revision);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(original, &digest, .{});
            break :blk try std.json.Stringify.valueAlloc(a, .{
                .entity = entity,
                .id = id,
                .complete = false,
                .source_path = path,
                .revision = revision,
                .bytes = original.len,
                .sha256 = std.fmt.bytesToHex(&digest, .lower),
                .projection_bytes = encoded.len,
                .note = "Read the original record in bounded pages; this reference cannot establish unseen content.",
            }, .{});
        };
        if (self.records.items.len > 0 and self.bytes + bounded.len > 64 * 1024) {
            self.sealed = true;
            return;
        }
        self.bytes += bounded.len;
        try self.records.append(self.alloc, try std.json.parseFromSliceLeaky(Value, self.alloc, bounded, .{ .allocate = .alloc_always }));
    }

    pub fn edge(self: *Page, value: projection.Edge) !void {
        const index = self.relationship_total;
        self.relationship_total += 1;
        if (index < self.offset or self.relationships.items.len == 32) return;
        var owned = value;
        owned.relationship = try self.alloc.dupe(u8, value.relationship);
        owned.from = try self.alloc.dupe(u8, value.from);
        owned.to = try self.alloc.dupe(u8, value.to);
        owned.task = try self.alloc.dupe(u8, value.task);
        owned.obligation = if (value.obligation) |id| try self.alloc.dupe(u8, id) else null;
        try self.relationships.append(self.alloc, owned);
    }

    pub fn result(self: Page) ![]const u8 {
        const end = @min(self.offset, self.total) + self.records.items.len;
        const edge_end = @min(self.offset, self.relationship_total) + self.relationships.items.len;
        return std.json.Stringify.valueAlloc(self.alloc, .{
            .revision = self.revision,
            .records = self.records.items,
            .relationships = self.relationships.items,
            .relationship_total = self.relationship_total,
            .next_relationship_offset = if (edge_end < self.relationship_total) @as(?usize, edge_end) else null,
            .next_offset = if (end < self.total) @as(?usize, end) else null,
            .total = self.total,
        }, .{});
    }
};

test "workspace query skips large unselected bodies and owns selected relationship strings" {
    var bytes: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    const a = fixed.allocator();
    var page: Page = .{ .alloc = a, .offset = 1000, .revision = "revision" };
    const Unused = struct {
        alloc: Allocator,
        pub fn contentAt(_: @This(), _: []const u8, _: []const u8) ![]const u8 {
            return error.UnexpectedOriginalRead;
        }
    };
    const large = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    for (0..1000) |_| try page.add(Unused{ .alloc = a }, .{ .string = large });
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
    const row = try std.json.parseFromSliceLeaky(Value, a, "{\"entity\":\"omos_event\",\"id\":\"selected\"}", .{});
    try page.add(Unused{ .alloc = a }, row);
    var from = [_]u8{ 'i', 'd' };
    for (0..1001) |_| try page.edge(.{ .relationship = "provenance", .from = &from, .to = "target", .task = "task", .authority = .host_observed });
    from[0] = 'X';
    try std.testing.expectEqualStrings("id", page.relationships.items[0].from);
    try std.testing.expectEqual(@as(usize, 1001), page.total);
    try std.testing.expectEqual(@as(usize, 1), page.records.items.len);
    _ = try page.result();
    try std.testing.expect(fixed.end_index < bytes.len);
}
