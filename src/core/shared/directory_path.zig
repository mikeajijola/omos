//! Descriptor-bound directory paths when procfs is unavailable. Walk parents
//! without changing process cwd, then reopen every component without symlinks.
const std = @import("std");
const builtin = @import("builtin");
const Identity = struct { inode: u64, major: u32, minor: u32 };

fn identity(dir: std.Io.Dir) !Identity {
    if (comptime builtin.os.tag != .linux) return error.HandlePathUnavailable;
    var metadata: std.os.linux.Statx = undefined;
    while (true) switch (std.os.linux.errno(std.os.linux.statx(dir.handle, "", std.os.linux.AT.EMPTY_PATH, .BASIC_STATS, &metadata))) {
        .SUCCESS => return .{ .inode = metadata.ino, .major = metadata.dev_major, .minor = metadata.dev_minor },
        .INTR => continue,
        else => return error.HandlePathUnavailable,
    };
}

fn same(left: Identity, right: Identity) bool {
    return std.meta.eql(left, right);
}

pub fn resolve(alloc: std.mem.Allocator, io: std.Io, source: std.Io.Dir) ![]u8 {
    if (comptime builtin.os.tag != .linux) return error.HandlePathUnavailable;
    const origin = try identity(source);
    var current = try source.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer current.close(io);
    var root = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    defer root.close(io);
    const root_identity = try identity(root);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var bytes: usize = 1;
    for (0..256) |_| {
        const current_identity = try identity(current);
        var parent = try current.openDir(io, "..", .{ .iterate = true, .follow_symlinks = false });
        var adopted = false;
        defer if (!adopted) parent.close(io);
        if (same(current_identity, try identity(parent))) {
            if (!same(current_identity, root_identity)) return error.HandlePathUnavailable;
            var verified = try root.openDir(io, ".", .{ .follow_symlinks = false });
            defer verified.close(io);
            var path: std.ArrayList(u8) = .empty;
            errdefer path.deinit(alloc);
            try path.append(alloc, '/');
            var index = names.items.len;
            while (index > 0) {
                index -= 1;
                const next = try verified.openDir(io, names.items[index], .{ .follow_symlinks = false });
                verified.close(io);
                verified = next;
                if (path.items.len > 1) try path.append(alloc, '/');
                try path.appendSlice(alloc, names.items[index]);
            }
            if (!same(origin, try identity(verified)) or !same(origin, try identity(source))) return error.HandlePathUnavailable;
            return path.toOwnedSlice(alloc);
        }
        var iterator = parent.iterate();
        var found: ?[]const u8 = null;
        errdefer if (found) |name| alloc.free(name);
        var inspected: usize = 0;
        while (try iterator.next(io)) |entry| {
            inspected += 1;
            if (inspected > 65536) return error.HandlePathUnavailable;
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const metadata = parent.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            if (metadata.kind != .directory or metadata.inode != current_identity.inode) continue;
            var candidate = parent.openDir(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            defer candidate.close(io);
            if (!same(current_identity, try identity(candidate))) continue;
            if (found != null) return error.HandlePathUnavailable;
            found = try alloc.dupe(u8, entry.name);
        }
        const name = found orelse return error.HandlePathUnavailable;
        bytes += name.len + 1;
        if (bytes > std.Io.Dir.max_path_bytes) return error.HandlePathUnavailable;
        try names.append(alloc, name);
        found = null;
        current.close(io);
        current = parent;
        adopted = true;
    }
    return error.HandlePathUnavailable;
}

test "directory paths without procfs follow retained directory identities through rename and reject deletion" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    try tmp.dir.createDirPath(io, "original/nested");
    var nested = try tmp.dir.openDir(io, "original/nested", .{ .iterate = true });
    defer nested.close(io);
    const original = try resolve(alloc, io, nested);
    defer alloc.free(original);
    try std.testing.expect(std.mem.endsWith(u8, original, "/original/nested"));
    try std.Io.Dir.rename(tmp.dir, "original", tmp.dir, "moved", io);
    const renamed = try resolve(alloc, io, nested);
    defer alloc.free(renamed);
    try std.testing.expect(std.mem.endsWith(u8, renamed, "/moved/nested"));
    try tmp.dir.deleteDir(io, "moved/nested");
    try std.testing.expectError(error.HandlePathUnavailable, resolve(alloc, io, nested));
}
