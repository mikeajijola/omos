//! Resolve the installation's helper before consulting development PATH. The
//! helper and its integrity manifest belong to the trusted host installation.
const std = @import("std");
const io = @import("../shared/io.zig");

const Cached = struct { path: []const u8, sha256: []const u8, stat: std.Io.File.Stat };
var cache: [8]?Cached = @splat(null);
var next_slot: usize = 0;
var mutex: std.Io.Mutex = .init;
fn sameFile(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and std.meta.eql(a.mtime, b.mtime) and std.meta.eql(a.ctime, b.ctime);
}
fn verified(path: []const u8, expected: []const u8, stat: std.Io.File.Stat) bool {
    mutex.lockUncancelable(io.getIo());
    defer mutex.unlock(io.getIo());
    for (cache) |entry| if (entry) |value| {
        if (std.mem.eql(u8, value.path, path) and std.mem.eql(u8, value.sha256, expected) and sameFile(value.stat, stat)) return true;
    };
    return false;
}
fn remember(path: []const u8, expected: []const u8, stat: std.Io.File.Stat) !void {
    const owned_path = try std.heap.c_allocator.dupe(u8, path);
    errdefer std.heap.c_allocator.free(owned_path);
    const owned_hash = try std.heap.c_allocator.dupe(u8, expected);
    mutex.lockUncancelable(io.getIo());
    defer mutex.unlock(io.getIo());
    if (cache[next_slot]) |old| {
        std.heap.c_allocator.free(old.path);
        std.heap.c_allocator.free(old.sha256);
    }
    cache[next_slot] = .{ .path = owned_path, .sha256 = owned_hash, .stat = stat };
    next_slot = (next_slot + 1) % cache.len;
}

pub fn resolve(alloc: std.mem.Allocator) ![]const u8 {
    if (io.getenv("OMOS_FOSSIL_BIN")) |override| {
        if (!std.Io.Dir.path.isAbsolute(override)) return error.InvalidFossilExecutable;
        return override;
    }
    const home = io.getenv("HOME") orelse return error.HomeUnavailable;
    const directory = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", "libexec" });
    const manifest_path = try std.Io.Dir.path.join(alloc, &.{ directory, "fossil.json" });
    var manifest = std.Io.Dir.cwd().openFile(io.getIo(), manifest_path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return "fossil",
        else => return err,
    };
    defer manifest.close(io.getIo());
    const Descriptor = struct { version: u32, file: []const u8, sha256: []const u8 };
    const descriptor = try @import("../shared/record_json.zig").decode(Descriptor, alloc, try io.readFileToEnd(alloc, &manifest, 1024), .{});
    if (descriptor.version != 1 or descriptor.sha256.len != 64) return error.InvalidFossilExecutable;
    for (descriptor.sha256) |ch| if (!std.ascii.isHex(ch)) return error.InvalidFossilExecutable;
    if (!std.mem.eql(u8, descriptor.file, try alloc.print("fossil-{s}", .{descriptor.sha256}))) return error.InvalidFossilExecutable;
    const path = try std.Io.Dir.path.join(alloc, &.{ directory, descriptor.file });
    var file = try std.Io.Dir.cwd().openFile(io.getIo(), path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    const before = try file.stat(io.getIo());
    if (verified(path, descriptor.sha256, before)) return path;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16384]u8 = undefined;
    var reader = file.reader(io.getIo(), &.{});
    var total: usize = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        total += count;
        if (total > 64 * 1024 * 1024) return error.InvalidFossilExecutable;
        digest.update(buffer[0..count]);
    }
    const actual = std.fmt.bytesToHex(digest.finalResult(), .lower);
    if (!std.mem.eql(u8, descriptor.sha256, &actual)) return error.FossilExecutableChanged;
    if (!sameFile(before, try file.stat(io.getIo()))) return error.FossilExecutableChanged;
    try remember(path, descriptor.sha256, before);
    return path;
}
