//! Request-local reuse of immutable Fossil bytes. Mutable selectors, errors,
//! authority decisions and live ownership decisions never enter this cache.
const std = @import("std");
const manifest = @import("fossil_manifest.zig");

const Kind = enum { content, inventory, artifact };
const Entry = struct { kind: Kind, repository: []const u8, revision: []const u8, path: []const u8, bytes: []const u8 };

/// Server-owned immutable bytes, shared only while the server is running.
/// Copies leave the lock; eviction cannot invalidate a request's allocation.
pub const Shared = struct {
    cache: Cache,
    mutex: std.Io.Mutex = .init,

    pub fn deinit(self: *Shared) void {
        self.cache.deinit();
    }

    pub fn get(self: *Shared, io: std.Io, alloc: std.mem.Allocator, kind: Kind, repository: []const u8, revision: []const u8, path: []const u8) !?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const bytes = self.cache.get(kind, repository, revision, path) orelse return null;
        return try alloc.dupe(u8, bytes);
    }

    pub fn put(self: *Shared, io: std.Io, kind: Kind, repository: []const u8, revision: []const u8, path: []const u8, bytes: []const u8) !void {
        if (!manifest.validHash(revision)) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.cache.get(kind, repository, revision, path) != null) return;
        const size = repository.len + revision.len + path.len + bytes.len;
        if (size > Cache.limit) return;
        // Discard only disposable bytes. An active request owns its own copy;
        // no authority decision or mutable branch selector is retained here.
        if (self.cache.entries.items.len >= Cache.max_entries or size > Cache.limit - self.cache.bytes) self.cache.deinit();
        try self.cache.put(kind, repository, revision, path, bytes);
    }
};

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

test "shared immutable cache retains owned copies across eviction and separates scopes" {
    var shared: Shared = .{ .cache = .{ .alloc = std.testing.allocator } };
    defer shared.deinit();
    const revision = "0123456789012345678901234567890123456789";
    try shared.put(std.testing.io, .content, "repository", revision, "memory/note", "original");
    const owned = (try shared.get(std.testing.io, std.testing.allocator, .content, "repository", revision, "memory/note")).?;
    defer std.testing.allocator.free(owned);
    try std.testing.expect(try shared.get(std.testing.io, std.testing.allocator, .content, "other", revision, "memory/note") == null);
    try std.testing.expect(try shared.get(std.testing.io, std.testing.allocator, .artifact, "repository", revision, "memory/note") == null);
    for (0..Cache.max_entries) |index| {
        var buffer: [32]u8 = undefined;
        try shared.put(std.testing.io, .content, "repository", revision, try std.mem.print(&buffer, "memory/{d}", .{index}), "next");
    }
    try std.testing.expect(try shared.get(std.testing.io, std.testing.allocator, .content, "repository", revision, "memory/note") == null);
    try std.testing.expectEqualStrings("original", owned);
    try std.testing.expect(shared.cache.entries.items.len <= Cache.max_entries);
    try std.testing.expect(shared.cache.bytes <= Cache.limit);
    try shared.put(std.testing.io, .content, "repository", "trunk", "memory/note", "moving");
    try std.testing.expect(try shared.get(std.testing.io, std.testing.allocator, .content, "repository", "trunk", "memory/note") == null);
    const oversized = try std.testing.allocator.alloc(u8, Cache.limit + 1);
    defer std.testing.allocator.free(oversized);
    try shared.put(std.testing.io, .content, "repository", revision, "memory/oversized", oversized);
    try std.testing.expect(try shared.get(std.testing.io, std.testing.allocator, .content, "repository", revision, "memory/oversized") == null);
}

test "shared immutable cache serializes concurrent readers and writers" {
    var shared: Shared = .{ .cache = .{ .alloc = std.testing.allocator } };
    defer shared.deinit();
    const Runner = struct {
        shared: *Shared,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            const revision = "0123456789012345678901234567890123456789";
            for (0..128) |index| {
                var buffer: [32]u8 = undefined;
                const path = std.mem.print(&buffer, "memory/{d}", .{index % 32}) catch unreachable;
                self.shared.put(std.testing.io, .content, "repository", revision, path, "immutable") catch {
                    self.failed.store(true, .release);
                    return;
                };
                const found = self.shared.get(std.testing.io, std.testing.allocator, .content, "repository", revision, path) catch {
                    self.failed.store(true, .release);
                    return;
                };
                if (found) |bytes| {
                    defer std.testing.allocator.free(bytes);
                    if (!std.mem.eql(u8, bytes, "immutable")) self.failed.store(true, .release);
                } else self.failed.store(true, .release);
            }
        }
    };
    var runner: Runner = .{ .shared = &shared };
    var threads: [4]std.Thread = undefined;
    {
        var started: usize = 0;
        errdefer for (threads[0..started]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Runner.run, .{&runner});
            started += 1;
        }
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!runner.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 32), shared.cache.entries.items.len);
}

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
