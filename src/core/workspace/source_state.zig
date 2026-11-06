//! Hash indexed file paths, kinds, permissions, and contents. No repository program
//! runs. An incomplete scan cannot establish a current validation basis.
const std = @import("std");
const io = @import("../shared/io.zig");
const indexer = @import("../indexer/indexer.zig");

pub fn fingerprint(alloc: std.mem.Allocator, root: []const u8, repository: []const u8) ![]const u8 {
    // Managed workspaces belong to the native CLI. The shared orchestrator is
    // also compiled for SDK hosts, where no native indexer may be instantiated.
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.NativeWorkspaceUnavailable;
    var scan = try indexer.scan(alloc, root, .{ .candidate_cap = 100_000, .max_workers = 2 }, null);
    defer scan.deinit();
    if (scan.tree.incomplete or scan.tree.cap_reached) return error.SourceStateIncomplete;
    for (scan.tree.folders) |folder| if (folder.boundary) return error.SourceScopeIncomplete;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: usize = 0;
    for (scan.tree.entries) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.Io.Dir.path.join(alloc, &.{ root, entry.path });
        defer alloc.free(path);
        if (workspaceState(path, repository)) continue;
        const stat = try std.Io.Dir.cwd().statFile(io.getIo(), path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) {
            var link: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const length = try std.Io.Dir.cwd().readLink(io.getIo(), path, &link);
            hashEntry(&hasher, entry.path, .link, @intCast(stat.permissions.toMode() & 0o7777), link[0..length]);
            continue;
        }
        var file = try std.Io.Dir.cwd().openFile(io.getIo(), path, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(io.getIo());
        const opened = try file.stat(io.getIo());
        if (opened.size > 256 * 1024 * 1024 - total) return error.SourceStateTooLarge;
        var content = std.crypto.hash.sha2.Sha256.init(.{});
        var reader_buffer: [32768]u8 = undefined;
        var chunk: [32768]u8 = undefined;
        var reader = file.reader(io.getIo(), &reader_buffer);
        var bytes: usize = 0;
        while (true) {
            const count = try reader.interface.readSliceShort(&chunk);
            if (count == 0) break;
            if (count > 256 * 1024 * 1024 - total) return error.SourceStateTooLarge;
            total += count;
            bytes += count;
            content.update(chunk[0..count]);
        }
        const after = try file.stat(io.getIo());
        if (bytes != opened.size or after.size != opened.size or !std.meta.eql(opened.mtime, after.mtime) or after.permissions.toMode() != opened.permissions.toMode()) return error.SourceStateChanged;
        var content_hash: [32]u8 = undefined;
        content.final(&content_hash);
        hashDigest(&hasher, entry.path, .file, @intCast(opened.permissions.toMode() & 0o7777), &content_hash);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return alloc.dupe(u8, &std.fmt.bytesToHex(&digest, .lower));
}

// The native store, SQLite sidecars and migration backups are generated host
// state. A parent workspace scan may see them despite a nested Git exclude.
fn workspaceState(path: []const u8, repository: []const u8) bool {
    if (!std.mem.startsWith(u8, path, repository)) return false;
    const suffix = path[repository.len..];
    if (suffix.len == 0) return true;
    for ([_][]const u8{ "-wal", "-shm", "-journal" }) |sidecar| if (std.mem.eql(u8, suffix, sidecar)) return true;
    for ([_][]const u8{ ".pre-omniform-", ".pre-contracts-" }) |prefix| {
        if (!std.mem.startsWith(u8, suffix, prefix) or !std.mem.endsWith(u8, suffix, ".fossil")) continue;
        const timestamp = suffix[prefix.len .. suffix.len - ".fossil".len];
        if (timestamp.len == 0) return false;
        for (timestamp) |byte| if (!std.ascii.isDigit(byte)) return false;
        return true;
    }
    return false;
}

test "source fingerprint excludes only native database state and migration backups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "answer.txt", .data = "source" });
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const repository = try std.Io.Dir.path.join(alloc, &.{ root, "personal.fossil" });
    const before = try fingerprint(alloc, root, repository);
    for ([_][]const u8{ "personal.fossil", "personal.fossil-wal", "personal.fossil-shm", "personal.fossil-journal", "personal.fossil.pre-omniform-123.fossil", "personal.fossil.pre-contracts-456.fossil" }) |name| {
        const file = try tmp.dir.createFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, 512 * 1024 * 1024);
    }
    try std.testing.expectEqualStrings(before, try fingerprint(alloc, root, repository));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "personal.fossil.pre-contracts-source.fossil", .data = "user source" });
    try std.testing.expect(!std.mem.eql(u8, before, try fingerprint(alloc, root, repository)));
}

const Kind = enum(u8) { file, link };

fn hashEntry(hasher: *std.crypto.hash.sha2.Sha256, path: []const u8, kind: Kind, permissions: u16, bytes: []const u8) void {
    var content_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &content_hash, .{});
    hashDigest(hasher, path, kind, permissions, &content_hash);
}

fn hashDigest(hasher: *std.crypto.hash.sha2.Sha256, path: []const u8, kind: Kind, permissions: u16, content_hash: *const [32]u8) void {
    hasher.update(path);
    hasher.update(&.{ 0, @backingInt(kind) });
    var mode: [2]u8 = undefined;
    std.mem.writeInt(u16, &mode, permissions, .little);
    hasher.update(&mode);
    // Fixed-width content digests keep link targets from running into the next
    // path. The kind also distinguishes a link from a file with the same bytes.
    hasher.update(content_hash);
}

test "source fingerprint streams large files and preserves the aggregate scan budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "large.bin", .{ .read = true });
    defer file.close(std.testing.io);
    const chunk: [32768]u8 = @splat('a');
    for (0..544) |_| try file.writeStreamingAll(std.testing.io, &chunk);
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const repository = try std.Io.Dir.path.join(alloc, &.{ root, "omos.fossil" });
    const before = try fingerprint(alloc, root, repository);
    try file.writeStreamingAll(std.testing.io, "changed tail");
    const after = try fingerprint(alloc, root, repository);
    try std.testing.expect(!std.mem.eql(u8, before, after));
    try file.setLength(std.testing.io, 256 * 1024 * 1024 + 1);
    try std.testing.expectError(error.SourceStateTooLarge, fingerprint(alloc, root, repository));
}

test "source fingerprints frame link targets, file kinds, and permissions" {
    const Hash = std.crypto.hash.sha2.Sha256;
    var first = Hash.init(.{});
    hashEntry(&first, "a", .link, 0o777, "x");
    hashEntry(&first, "bc", .file, 0o644, "payload");
    var second = Hash.init(.{});
    hashEntry(&second, "a", .link, 0o777, "xb");
    hashEntry(&second, "c", .file, 0o644, "payload");
    // The earlier unframed encoding hashed both as a\0xbc\0<content hash>.
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    first.final(&a);
    second.final(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));

    first = Hash.init(.{});
    second = Hash.init(.{});
    hashEntry(&first, "a", .file, 0o777, "target");
    hashEntry(&second, "a", .link, 0o777, "target");
    first.final(&a);
    second.final(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));

    first = Hash.init(.{});
    second = Hash.init(.{});
    hashEntry(&first, "a", .file, 0o644, "script");
    hashEntry(&second, "a", .file, 0o755, "script");
    first.final(&a);
    second.final(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "source fingerprint observes executable permission changes through the indexer" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "script.sh", .{ .permissions = .fromMode(0o644) });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const repository = try std.Io.Dir.path.join(alloc, &.{ root, "omos.fossil" });
    const before = try fingerprint(alloc, root, repository);
    try file.setPermissions(std.testing.io, .fromMode(0o755));
    const after = try fingerprint(alloc, root, repository);
    try std.testing.expect(!std.mem.eql(u8, before, after));
    try file.setPermissions(std.testing.io, .fromMode(0o4755));
    const special = try fingerprint(alloc, root, repository);
    try std.testing.expect(!std.mem.eql(u8, after, special));
}
