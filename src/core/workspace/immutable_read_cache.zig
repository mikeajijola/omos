//! Request-local reuse of immutable Fossil bytes. Mutable selectors, authority
//! decisions, errors and execution state never enter this cache.
const std = @import("std");
const manifest = @import("fossil_manifest.zig");

const Kind = enum { content, inventory, artifact };
const Entry = struct { kind: Kind, repository: []const u8, revision: []const u8, path: []const u8, bytes: []const u8 };
pub const Cache = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    const limit = 2 * 1024 * 1024;
    const max_entries = 128;

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| {
            self.alloc.free(entry.repository);
            self.alloc.free(entry.revision);
            self.alloc.free(entry.path);
            self.alloc.free(entry.bytes);
        }
        self.entries.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    pub fn get(self: *const Cache, kind: Kind, repository: []const u8, revision: []const u8, path: []const u8) ?[]const u8 {
        if (!manifest.validHash(revision)) return null;
        for (self.entries.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.repository, repository) and std.mem.eql(u8, entry.revision, revision) and std.mem.eql(u8, entry.path, path)) return entry.bytes;
        }
        return null;
    }

    pub fn put(self: *Cache, kind: Kind, repository: []const u8, revision: []const u8, path: []const u8, bytes: []const u8) !void {
        if (!manifest.validHash(revision) or self.entries.items.len >= max_entries or self.get(kind, repository, revision, path) != null) return;
        const size = repository.len + revision.len + path.len + bytes.len;
        if (size > limit - self.bytes) return;
        const owned_repository = try self.alloc.dupe(u8, repository);
        errdefer self.alloc.free(owned_repository);
        const owned_revision = try self.alloc.dupe(u8, revision);
        errdefer self.alloc.free(owned_revision);
        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);
        const owned_bytes = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned_bytes);
        try self.entries.append(self.alloc, .{ .kind = kind, .repository = owned_repository, .revision = owned_revision, .path = owned_path, .bytes = owned_bytes });
        self.bytes += size;
    }
};

test "immutable Fossil read cache separates repositories revisions and operation kinds" {
    var cache: Cache = .{ .alloc = std.testing.allocator };
    defer cache.deinit();
    const first = "0123456789012345678901234567890123456789";
    const next = "1123456789012345678901234567890123456789";
    var source = [_]u8{ 'o', 'l', 'd' };
    try cache.put(.content, "repository", first, "memory/note", &source);
    source[0] = 'x';
    try std.testing.expectEqualStrings("old", cache.get(.content, "repository", first, "memory/note").?);
    try std.testing.expect(cache.get(.content, "other", first, "memory/note") == null);
    try std.testing.expect(cache.get(.content, "repository", next, "memory/note") == null);
    try std.testing.expect(cache.get(.inventory, "repository", first, "memory/note") == null);
    try cache.put(.content, "repository", next, "memory/note", "new");
    try std.testing.expectEqualStrings("new", cache.get(.content, "repository", next, "memory/note").?);
    try cache.put(.content, "repository", first, "memory/note", "replacement");
    try std.testing.expectEqualStrings("old", cache.get(.content, "repository", first, "memory/note").?);
}

test "immutable Fossil read cache rejects mutable selectors and stays within its bounds" {
    var cache: Cache = .{ .alloc = std.testing.allocator };
    defer cache.deinit();
    const revision = "0123456789012345678901234567890123456789";
    for ([_][]const u8{ "trunk", "current", "0123456", "task/actor" }) |selector| {
        try cache.put(.content, "repository", selector, "memory/note", "data");
        try std.testing.expect(cache.get(.content, "repository", selector, "memory/note") == null);
    }
    const too_large = try std.testing.allocator.alloc(u8, Cache.limit + 1);
    defer std.testing.allocator.free(too_large);
    try cache.put(.content, "repository", revision, "memory/large", too_large);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    for (0..Cache.max_entries + 1) |index| {
        var buffer: [32]u8 = undefined;
        try cache.put(.content, "repository", revision, try std.mem.print(&buffer, "memory/{d}", .{index}), "data");
    }
    try std.testing.expectEqual(Cache.max_entries, cache.entries.items.len);
    try std.testing.expect(cache.bytes <= Cache.limit);
}
