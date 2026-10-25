//! Kernel lifetime pins for disposable resources. Closing a parent's descriptor
//! must not unlock a lease still held by an inherited child descriptor.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const bounded = @import("bounded_operation.zig");

pub const Pin = struct {
    file: std.Io.File,

    pub fn close(self: Pin) void {
        // flock ownership follows the open file description across fork/exec.
        // Explicit unlock here would release every child's protection too.
        self.file.close(io.getIo());
    }
};

fn tryLock(path: []const u8, kind: std.Io.File.Lock) !?Pin {
    if (comptime builtin.target.cpu.arch.isWasm() or builtin.target.os.tag == .windows) return error.UnsupportedPlatform;
    if (!std.Io.Dir.path.isAbsolute(path)) return error.InvalidResourcePin;
    var parent = try io.openDirAbsoluteNoFollow(std.Io.Dir.path.dirname(path) orelse return error.InvalidResourcePin, .{});
    defer parent.close(io.getIo());
    const name = std.Io.Dir.path.basename(path);
    const file = parent.openFile(io.getIo(), name, .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => parent.createFile(io.getIo(), name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => try parent.openFile(io.getIo(), name, .{ .mode = .read_write, .follow_symlinks = false }),
            else => return create_err,
        },
        else => return err,
    };
    errdefer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.size != 0 or stat.permissions.toMode() & 0o077 != 0) return error.InvalidResourcePin;
    if (!try file.tryLock(io.getIo(), kind)) {
        file.close(io.getIo());
        return null;
    }
    // Keep stdio/progress slots free. The process-tree witness also reserves
    // 64/65 in a Darwin child, independently of the retained resource.
    if (file.handle < 4 or (builtin.target.os.tag == .macos and (file.handle == 64 or file.handle == 65))) {
        const duplicate = std.posix.system.fcntl(file.handle, std.posix.F.DUPFD_CLOEXEC, @as(usize, if (builtin.target.os.tag == .macos) 66 else 4));
        if (std.posix.errno(duplicate) != .SUCCESS) return error.ResourcePinDescriptorUnavailable;
        file.close(io.getIo());
        return .{ .file = .{ .handle = @intCast(duplicate), .flags = .{ .nonblocking = false } } };
    }
    return .{ .file = file };
}

pub fn acquire(path: []const u8, control: ?bounded.Control) !Pin {
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(30) });
    while (true) {
        if (control) |value| try value.check();
        if (try tryLock(path, .shared)) |pin| return pin;
        if (!std.Io.Clock.Timestamp.compare(.now(io.getIo(), .awake), .lt, deadline)) return error.WorkspaceBusy;
        try io.getIo().sleep(.fromMilliseconds(10), .awake);
    }
}

/// Cleanup uses a separate open file description and never waits on a live user.
pub fn tryExclusive(path: []const u8) !?Pin {
    return tryLock(path, .exclusive);
}

test "resource pin excludes cleanup until all shared owners close" {
    if (comptime builtin.target.cpu.arch.isWasm() or builtin.target.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try io.dirRealpathAlloc(std.testing.allocator, temporary.dir, ".");
    defer std.testing.allocator.free(root);
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "resource.lock" });
    defer std.testing.allocator.free(path);
    const first = try acquire(path, null);
    const second = try acquire(path, null);
    try std.testing.expect((try tryExclusive(path)) == null);
    first.close();
    try std.testing.expect((try tryExclusive(path)) == null);
    second.close();
    const exclusive = (try tryExclusive(path)) orelse return error.TestExpectedExclusiveLease;
    exclusive.close();
}

test "resource pin survives parent closure while an inherited child is running" {
    if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const alloc = std.testing.allocator;
    const root = try io.dirRealpathAlloc(alloc, temporary.dir, ".");
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "child.lock" });
    defer alloc.free(path);
    var pin: ?Pin = try acquire(path, null);
    defer if (pin) |owned| owned.close();
    const inherited = [_]std.Io.File{pin.?.file};
    var child = try std.process.spawn(io.getIo(), .{ .argv = &.{ "/bin/sh", "-c", "printf ready; read line" }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe, .inherit_files = &inherited });
    defer if (child.id != null) child.kill(io.getIo());
    var ready: [5]u8 = undefined;
    var offset: usize = 0;
    while (offset < ready.len) {
        const count = try child.stdout.?.readStreaming(io.getIo(), &.{ready[offset..]});
        if (count == 0) return error.TestChildExitedBeforeReady;
        offset += count;
    }
    try std.testing.expectEqualStrings("ready", &ready);
    pin.?.close();
    pin = null;
    try std.testing.expect((try tryExclusive(path)) == null);
    try child.stdin.?.writeStreamingAll(io.getIo(), "stop\n");
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io.getIo()));
    const exclusive = (try tryExclusive(path)) orelse return error.TestExpectedExclusiveLease;
    exclusive.close();
}
