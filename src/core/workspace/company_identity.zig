//! Actor signing keys belong to the local credential profile. Creating one
//! does not enroll its holder or grant authority in a company workspace.
const std = @import("std");
const io = @import("../shared/io.zig");
const authority = @import("company_authority.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const Snapshot = struct {
    version: []const u8 = "omos.company-key/v1",
    key_handle: []const u8,
    public_key: []const u8,
    created: bool,
};

fn directory(alloc: std.mem.Allocator, create_directory: bool) !io.VerifiedDir {
    const path = try std.Io.Dir.path.join(alloc, &.{ io.getenv("HOME") orelse return error.HomeUnavailable, ".fx", "company-keys" });
    if (create_directory) _ = try std.Io.Dir.cwd().createDirPathStatus(io.getIo(), path, .fromMode(0o700));
    var dir = try io.openDirAbsoluteNoFollow(path, .{ .iterate = true });
    errdefer dir.close(io.getIo());
    try dir.setPermissions(io.getIo(), .fromMode(0o700));
    return .{ .dir = dir };
}

fn filename(alloc: std.mem.Allocator, handle: []const u8) ![]const u8 {
    if (!authority.safeIdentity(handle)) return error.InvalidCompanyKeyHandle;
    return alloc.print("{s}.seed", .{handle});
}

fn read(alloc: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !Ed25519.KeyPair {
    var file = try dir.openFile(io.getIo(), path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o777 != 0o600) return error.CompanyKeyPermissionsUnsafe;
    const bytes = try io.readFileToEnd(alloc, &file, 33);
    defer std.crypto.secureZero(u8, bytes);
    if (bytes.len != 32) return error.InvalidCompanyKey;
    return Ed25519.KeyPair.generateDeterministic(bytes[0..32].*);
}

pub fn load(alloc: std.mem.Allocator, handle: []const u8) !Ed25519.KeyPair {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const path = try filename(alloc, handle);
    var dir = try directory(alloc, false);
    defer dir.close();
    return read(alloc, dir.dir, path);
}

pub fn create(alloc: std.mem.Allocator, handle: []const u8) !Snapshot {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const path = try filename(alloc, handle);
    var dir = try directory(alloc, true);
    defer dir.close();
    const existing = read(alloc, dir.dir, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |key| return .{ .key_handle = handle, .public_key = try alloc.dupe(u8, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower)), .created = false };
    const key = Ed25519.KeyPair.generate(io.getIo());
    var nonce: [16]u8 = undefined;
    io.getIo().random(&nonce);
    const temporary = try alloc.print("key.pending-{s}", .{std.fmt.bytesToHex(&nonce, .lower)});
    var file = try dir.dir.createFile(io.getIo(), temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io.getIo());
    defer dir.dir.deleteFile(io.getIo(), temporary) catch {};
    try file.writeStreamingAll(io.getIo(), &key.secret_key.seed());
    try file.sync(io.getIo());
    std.Io.Dir.hardLink(dir.dir, temporary, dir.dir, path, io.getIo(), .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const winner = try read(alloc, dir.dir, path);
            return .{ .key_handle = handle, .public_key = try alloc.dupe(u8, &std.fmt.bytesToHex(winner.public_key.toBytes(), .lower)), .created = false };
        },
        else => return err,
    };
    const parent: std.Io.File = .{ .handle = dir.dir.handle, .flags = .{ .nonblocking = false } };
    try parent.sync(io.getIo());
    return .{ .key_handle = handle, .public_key = try alloc.dupe(u8, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower)), .created = true };
}
