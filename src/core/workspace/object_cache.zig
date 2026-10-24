//! Disposable immutable company objects. Callers must obtain a fresh authorised
//! inventory before lookup; cache possession never supplies retrieval authority.
const std = @import("std");
const io = @import("../shared/io.zig");
const Control = @import("../shared/bounded_operation.zig").Control;

pub const Limits = struct { bytes: u64 = 256 * 1024 * 1024, entries: usize = 4096 };
pub const Scope = struct { workspace: []const u8, issuer: []const u8, epoch: u64 };
pub const Reference = struct { sha256: []const u8, bytes: usize };
pub const Stats = struct { hits: usize = 0, misses: usize = 0, stored_bytes: u64 = 0, evicted_bytes: u64 = 0, evictions: usize = 0 };
const maximum_object_bytes = 8 * 1024 * 1024;

fn digest(bytes: []const u8) [64]u8 {
    var value: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return std.fmt.bytesToHex(&value, .lower);
}

fn validHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}

pub const Cache = struct {
    dir: std.Io.Dir,
    scope: [64]u8,
    control: Control,
    limits: Limits,
    stats: Stats = .{},

    pub fn open(scope: Scope, control: Control) !Cache {
        try control.check();
        var home = try io.openDirAbsoluteNoFollow(io.getenv("HOME") orelse return error.HomeUnavailable, .{ .iterate = true });
        defer home.close(io.getIo());
        var profile = try io.openOrCreateVerifiedPrivateDirFromDir(home, ".fx");
        defer profile.close();
        var caches = try io.openOrCreateVerifiedPrivateDir(&profile, "cache");
        defer caches.close();
        var objects = try io.openOrCreateVerifiedPrivateDir(&caches, "company-objects");
        errdefer objects.close();
        return init(objects.dir, scope, control, .{});
    }

    fn openAt(path: []const u8, scope: Scope, control: Control, limits: Limits) !Cache {
        if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
        try control.check();
        _ = try std.Io.Dir.cwd().createDirPathStatus(io.getIo(), path, .fromMode(0o700));
        var dir = try io.openDirAbsoluteNoFollow(path, .{ .iterate = true });
        errdefer dir.close(io.getIo());
        return init(dir, scope, control, limits);
    }

    fn init(dir: std.Io.Dir, scope: Scope, control: Control, limits: Limits) !Cache {
        if (!@import("company_authority.zig").safeIdentity(scope.workspace) or !validHash(scope.issuer) or scope.epoch == 0 or limits.bytes == 0 or limits.entries == 0 or limits.entries > 4096) return error.InvalidObjectCache;
        try dir.setPermissions(io.getIo(), .fromMode(0o700));
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("omos.object-cache/v1\x00");
        hasher.update(scope.workspace);
        hasher.update(&.{0});
        hasher.update(scope.issuer);
        var epoch: [8]u8 = undefined;
        std.mem.writeInt(u64, &epoch, scope.epoch, .little);
        hasher.update(&epoch);
        var value: [32]u8 = undefined;
        hasher.final(&value);
        return .{ .dir = dir, .scope = std.fmt.bytesToHex(&value, .lower), .control = control, .limits = limits };
    }

    pub fn close(self: Cache) void {
        self.dir.close(io.getIo());
    }

    fn filename(self: Cache, reference: Reference) ![129]u8 {
        if (!validHash(reference.sha256) or reference.bytes > maximum_object_bytes) return error.InvalidCacheReference;
        var result: [129]u8 = undefined;
        @memcpy(result[0..64], &self.scope);
        result[64] = '-';
        @memcpy(result[65..], reference.sha256);
        return result;
    }

    pub fn load(self: *Cache, alloc: std.mem.Allocator, reference: Reference) !?[]u8 {
        try self.control.check();
        const name = try self.filename(reference);
        var file = self.dir.openFile(io.getIo(), &name, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                self.stats.misses += 1;
                return null;
            },
            else => return err,
        };
        defer file.close(io.getIo());
        const stat = try file.stat(io.getIo());
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600 or stat.size != reference.bytes) {
            self.stats.misses += 1;
            return null;
        }
        const bytes = try io.readFileToEnd(alloc, &file, maximum_object_bytes);
        errdefer alloc.free(bytes);
        try self.control.check();
        if (!std.mem.eql(u8, reference.sha256, &digest(bytes))) {
            alloc.free(bytes);
            self.stats.misses += 1;
            return null;
        }
        // Approximate LRU uses object metadata only. Removing an open cached
        // object cannot affect the verified bytes already owned by its reader.
        try file.setTimestamps(io.getIo(), .{ .modify_timestamp = .now });
        self.stats.hits += 1;
        return bytes;
    }

    fn lock(self: Cache) !std.Io.File {
        const file = self.dir.createFile(io.getIo(), "writer.lock", .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => try self.dir.openFile(io.getIo(), "writer.lock", .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false }),
            else => return err,
        };
        errdefer file.close(io.getIo());
        const stat = try file.stat(io.getIo());
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) return error.InvalidObjectCache;
        while (!try file.tryLock(io.getIo(), .exclusive)) {
            try self.control.check();
            try io.getIo().sleep(.fromMilliseconds(10), .awake);
        }
        try self.control.check();
        return file;
    }

    const Stored = struct { name: [129]u8, bytes: u64, used: std.Io.Timestamp };

    pub fn save(self: *Cache, alloc: std.mem.Allocator, reference: Reference, bytes: []const u8) !void {
        try self.control.check();
        const name = try self.filename(reference);
        if (bytes.len != reference.bytes or !std.mem.eql(u8, reference.sha256, &digest(bytes))) return error.InvalidCacheReference;
        if (bytes.len > self.limits.bytes) return;
        const writer = try self.lock();
        defer writer.close(io.getIo());
        defer writer.unlock(io.getIo());
        var stored: std.ArrayList(Stored) = .empty;
        defer stored.deinit(alloc);
        var total: u64 = 0;
        var scanned: usize = 0;
        var iterator = self.dir.iterate();
        while (try iterator.next(io.getIo())) |entry| {
            try self.control.check();
            scanned += 1;
            if (scanned > 4098) return error.ObjectCacheInventoryLimit;
            if (std.mem.eql(u8, entry.name, "writer.lock")) continue;
            const pending = std.mem.startsWith(u8, entry.name, ".pending-") and entry.name.len == 41 and for (entry.name[9..]) |ch| {
                if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) break false;
            } else true;
            if (pending) {
                try self.dir.deleteFile(io.getIo(), entry.name);
                continue;
            }
            if (entry.name.len != 129 or entry.name[64] != '-' or !validHash(entry.name[0..64]) or !validHash(entry.name[65..])) return error.InvalidObjectCache;
            if (stored.items.len >= 4096) return error.ObjectCacheInventoryLimit;
            const stat = try self.dir.statFile(io.getIo(), entry.name, .{ .follow_symlinks = false });
            if (stat.kind != .file or stat.nlink != 1 or stat.size > maximum_object_bytes) return error.InvalidObjectCache;
            total = try std.math.add(u64, total, stat.size);
            try stored.append(alloc, .{ .name = entry.name[0..129].*, .bytes = stat.size, .used = stat.mtime });
        }
        std.mem.sort(Stored, stored.items, {}, struct {
            fn less(_: void, a: Stored, b: Stored) bool {
                return std.Io.Timestamp.compare(a.used, .lt, b.used);
            }
        }.less);
        var removed: usize = 0;
        while (total + bytes.len > self.limits.bytes or stored.items.len - removed >= self.limits.entries) : (removed += 1) {
            try self.control.check();
            if (removed >= stored.items.len) return error.InvalidObjectCache;
            const object = stored.items[removed];
            self.dir.deleteFile(io.getIo(), &object.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            total -= object.bytes;
            self.stats.evictions += 1;
            self.stats.evicted_bytes += object.bytes;
        }
        var nonce: [16]u8 = undefined;
        io.getIo().random(&nonce);
        const pending = try alloc.print(".pending-{s}", .{std.fmt.bytesToHex(&nonce, .lower)});
        var file = try self.dir.createFile(io.getIo(), pending, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io.getIo());
        defer self.dir.deleteFile(io.getIo(), pending) catch {};
        try file.writeStreamingAll(io.getIo(), bytes);
        try file.sync(io.getIo());
        try self.control.check();
        try self.dir.rename(pending, self.dir, &name, io.getIo());
        const parent: std.Io.File = .{ .handle = self.dir.handle, .flags = .{ .nonblocking = false } };
        try parent.sync(io.getIo());
        self.stats.stored_bytes += bytes.len;
    }
};

test "company object cache isolates trust scopes and rebuilds after loss" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try io.dirRealpathAlloc(a, temporary.dir, ".");
    var cancel = std.atomic.Value(bool).init(false);
    const control: Control = .{ .cancel = &cancel, .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(10)) } };
    const workspace_id: [64]u8 = @splat('a');
    const issuer: [64]u8 = @splat('b');
    const scope: Scope = .{ .workspace = &workspace_id, .issuer = &issuer, .epoch = 1 };
    var cache = try Cache.openAt(path, scope, control, .{ .bytes = 32, .entries = 2 });
    defer cache.close();
    const value = "Verified content";
    const hash = digest(value);
    const reference: Reference = .{ .sha256 = &hash, .bytes = value.len };
    try cache.save(a, reference, value);
    try std.testing.expectEqualStrings(value, (try cache.load(a, reference)).?);
    const another: [64]u8 = @splat('c');
    for ([_]Scope{
        .{ .workspace = scope.workspace, .issuer = scope.issuer, .epoch = 2 },
        .{ .workspace = &another, .issuer = scope.issuer, .epoch = 1 },
        .{ .workspace = scope.workspace, .issuer = &another, .epoch = 1 },
    }) |other_scope| {
        var other = try Cache.openAt(path, other_scope, control, .{ .bytes = 32, .entries = 2 });
        defer other.close();
        try std.testing.expect((try other.load(a, reference)) == null);
    }
    const name = try cache.filename(reference);
    try cache.dir.deleteFile(io.getIo(), &name);
    try std.testing.expect((try cache.load(a, reference)) == null);
    try cache.save(a, reference, value);
    try std.testing.expectEqualStrings(value, (try cache.load(a, reference)).?);
}

test "company object cache bounds retained payloads and verifies every cache hit" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cancel = std.atomic.Value(bool).init(false);
    const control: Control = .{ .cancel = &cancel, .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(10)) } };
    const workspace_id: [64]u8 = @splat('a');
    const issuer: [64]u8 = @splat('b');
    var cache = try Cache.openAt(try io.dirRealpathAlloc(a, temporary.dir, "."), .{ .workspace = &workspace_id, .issuer = &issuer, .epoch = 1 }, control, .{ .bytes = 16, .entries = 2 });
    defer cache.close();
    const first_hash = digest("one-blob");
    const second_hash = digest("two-blob");
    const third_hash = digest("tri-blob");
    const first: Reference = .{ .sha256 = &first_hash, .bytes = 8 };
    const second: Reference = .{ .sha256 = &second_hash, .bytes = 8 };
    const third: Reference = .{ .sha256 = &third_hash, .bytes = 8 };
    try cache.save(a, first, "one-blob");
    try cache.save(a, second, "two-blob");
    for ([_]Reference{ first, second }, 1..) |reference, index| {
        const name = try cache.filename(reference);
        var file = try cache.dir.openFile(io.getIo(), &name, .{ .mode = .read_write });
        defer file.close(io.getIo());
        try file.setTimestamps(io.getIo(), .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(index) } } });
    }
    try std.testing.expectEqualStrings("one-blob", (try cache.load(a, first)).?);
    try cache.save(a, third, "tri-blob");
    try std.testing.expect((try cache.load(a, second)) == null);
    try std.testing.expectEqualStrings("one-blob", (try cache.load(a, first)).?);
    try std.testing.expectEqualStrings("tri-blob", (try cache.load(a, third)).?);
    try std.testing.expectEqual(@as(usize, 1), cache.stats.evictions);
    try std.testing.expectEqual(@as(u64, 8), cache.stats.evicted_bytes);
    try std.testing.expectError(error.InvalidCacheReference, cache.save(a, first, "bad-blob"));
    const name = try cache.filename(first);
    var poisoned = try cache.dir.createFile(io.getIo(), &name, .{});
    try poisoned.writeStreamingAll(io.getIo(), "bad-blob");
    poisoned.close(io.getIo());
    try std.testing.expect((try cache.load(a, first)) == null);
    try cache.save(a, first, "one-blob");
    try std.testing.expectEqualStrings("one-blob", (try cache.load(a, first)).?);
    cancel.store(true, .seq_cst);
    try std.testing.expectError(error.Cancelled, cache.load(a, first));
    try std.testing.expectError(error.Cancelled, cache.save(a, first, "one-blob"));
}

test "company object cache lock waits share the operation deadline" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cancel = std.atomic.Value(bool).init(false);
    const control: Control = .{ .cancel = &cancel, .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(10)) } };
    const workspace_id: [64]u8 = @splat('a');
    const issuer: [64]u8 = @splat('b');
    var cache = try Cache.openAt(try io.dirRealpathAlloc(a, temporary.dir, "."), .{ .workspace = &workspace_id, .issuer = &issuer, .epoch = 1 }, control, .{});
    defer cache.close();
    const held = try cache.lock();
    defer held.close(io.getIo());
    defer held.unlock(io.getIo());
    cache.control.deadline.raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromMilliseconds(25));
    const hash = digest("value");
    try std.testing.expectError(error.Timeout, cache.save(a, .{ .sha256 = &hash, .bytes = 5 }, "value"));
}

test "company object cache never follows object symlinks" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cancel = std.atomic.Value(bool).init(false);
    const control: Control = .{ .cancel = &cancel, .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(10)) } };
    const workspace_id: [64]u8 = @splat('a');
    const issuer: [64]u8 = @splat('b');
    var cache = try Cache.openAt(try io.dirRealpathAlloc(a, temporary.dir, "."), .{ .workspace = &workspace_id, .issuer = &issuer, .epoch = 1 }, control, .{});
    defer cache.close();
    const hash = digest("content");
    const reference: Reference = .{ .sha256 = &hash, .bytes = 7 };
    var target = try temporary.dir.createFile(io.getIo(), "foreign.txt", .{ .read = true, .permissions = .fromMode(0o600) });
    defer target.close(io.getIo());
    try target.writeStreamingAll(io.getIo(), "content");
    try target.setTimestamps(io.getIo(), .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1 } } });
    const before = try target.stat(io.getIo());
    const name = try cache.filename(reference);
    try cache.dir.symLink(io.getIo(), "foreign.txt", &name, .{});
    try std.testing.expectError(error.SymLinkLoop, cache.load(a, reference));
    try std.testing.expectEqual(before.mtime, (try target.stat(io.getIo())).mtime);
    try std.testing.expectEqual(@as(usize, 0), cache.stats.hits);
}
