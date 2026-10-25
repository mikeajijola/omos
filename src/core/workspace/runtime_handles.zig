//! Local owner runtime bindings. Company definitions name handles, never host
//! executables or probe arguments. Package content cannot change these bindings.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const authority = @import("company_authority.zig");
const workspace = @import("fossil_workspace.zig");
const Control = @import("../shared/bounded_operation.zig").Control;

pub const Kind = enum { node, python };
pub const Binding = struct { handle: []const u8, kind: Kind, executable: []const u8 };
pub const Bindings = struct { version: []const u8 = "omos.runtime-handles/v1", handles: []const Binding = &.{} };
pub const Probe = struct { handle: []const u8, kind: Kind, version: []const u8, executable_sha256: []const u8, fingerprint: []const u8 };

pub fn parse(alloc: std.mem.Allocator, raw: []const u8) !Bindings {
    if (raw.len > 256 * 1024) return error.InvalidRuntimeBindings;
    const bindings = try records.decode(Bindings, alloc, raw, .{});
    if (!std.mem.eql(u8, bindings.version, "omos.runtime-handles/v1") or bindings.handles.len > 64) return error.InvalidRuntimeBindings;
    for (bindings.handles, 0..) |binding, index| {
        if (!authority.safeIdentity(binding.handle) or !std.Io.Dir.path.isAbsolute(binding.executable) or binding.executable.len > 4096 or std.mem.findScalar(u8, binding.executable, 0) != null) return error.InvalidRuntimeBinding;
        for (bindings.handles[0..index]) |previous| if (std.mem.eql(u8, previous.handle, binding.handle)) return error.DuplicateRuntimeHandle;
    }
    return bindings;
}

fn directory(alloc: std.mem.Allocator) !io.VerifiedDir {
    const path = try std.Io.Dir.path.join(alloc, &.{ io.getenv("HOME") orelse return error.HomeUnavailable, ".fx", "runtimes" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io.getIo(), path, .fromMode(0o700));
    var dir = try io.openDirAbsoluteNoFollow(path, .{ .iterate = true });
    errdefer dir.close(io.getIo());
    try dir.setPermissions(io.getIo(), .fromMode(0o700));
    return .{ .dir = dir };
}

pub fn load(alloc: std.mem.Allocator) !Bindings {
    var dir = try directory(alloc);
    defer dir.close();
    var file = try dir.dir.openFile(io.getIo(), "handles.json", .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o777 != 0o600) return error.RuntimeBindingPermissionsUnsafe;
    return parse(alloc, try io.readFileToEnd(alloc, &file, 256 * 1024));
}

pub fn save(alloc: std.mem.Allocator, raw: []const u8) !void {
    const bindings = try parse(alloc, raw);
    var dir = try directory(alloc);
    defer dir.close();
    try io.durableReplaceVerified(alloc, &dir, "handles.json", try std.json.Stringify.valueAlloc(alloc, bindings, .{}));
}

fn sameFile(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.permissions.toMode() == b.permissions.toMode() and std.meta.eql(a.mtime, b.mtime) and std.meta.eql(a.ctime, b.ctime);
}

fn identify(alloc: std.mem.Allocator, binding: Binding, stat: std.Io.File.Stat) ![]const u8 {
    if (stat.kind != .file or stat.size == 0 or stat.size > 256 * 1024 * 1024 or stat.permissions.toMode() & 0o022 != 0 or stat.permissions.toMode() & 0o111 == 0) return error.RuntimeExecutableUnsafe;
    return workspace.hash(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .binding = binding, .inode = stat.inode, .bytes = stat.size, .mode = stat.permissions.toMode(), .mtime_ns = stat.mtime.nanoseconds, .ctime_ns = stat.ctime.nanoseconds }, .{}));
}

pub fn fingerprint(alloc: std.mem.Allocator, binding: Binding) ![]const u8 {
    var file = try io.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), binding.executable, .no_follow);
    defer file.close(io.getIo());
    return identify(alloc, binding, try file.stat(io.getIo()));
}

pub fn probe(alloc: std.mem.Allocator, binding: Binding) !Probe {
    return probeControlled(alloc, binding, null);
}

fn check(control: ?Control) !void {
    if (control) |active| {
        if (active.cancel.load(.seq_cst)) return error.Cancelled;
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, active.deadline)) return error.Timeout;
    }
}

pub fn probeControlled(alloc: std.mem.Allocator, binding: Binding, control: ?Control) !Probe {
    try check(control);
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    var file = try io.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), binding.executable, .no_follow);
    defer file.close(io.getIo());
    const before = try file.stat(io.getIo());
    const stamp = try identify(alloc, binding, before);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16384]u8 = undefined;
    var reader = file.readerStreaming(io.getIo(), &buffer);
    var total: u64 = 0;
    var chunk: [16384]u8 = undefined;
    while (true) {
        try check(control);
        const size = try reader.interface.readSliceShort(&chunk);
        if (size == 0) break;
        total += size;
        if (total > 256 * 1024 * 1024) return error.RuntimeExecutableUnsafe;
        digest.update(chunk[0..size]);
    }
    if (total != before.size or !sameFile(before, try file.stat(io.getIo()))) return error.RuntimeExecutableChanged;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("LC_ALL", "C");
    try environment.put("LANG", "C");
    try check(control);
    var deadline: std.Io.Clock.Timestamp = .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(5000) });
    if (control) |active| if (std.Io.Clock.Timestamp.compare(active.deadline, .lt, deadline)) {
        deadline = active.deadline;
    };
    const result = try std.process.run(alloc, io.getIo(), .{
        .argv = switch (binding.kind) {
            .node => &.{ binding.executable, "--version" },
            .python => &.{ binding.executable, "-I", "--version" },
        },
        .environ_map = &environment,
        .cwd = .{ .path = std.Io.Dir.path.dirname(binding.executable) orelse return error.InvalidRuntimeBinding },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = deadline },
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.RuntimeProbeFailed,
        else => return error.RuntimeProbeFailed,
    }
    try check(control);
    if (result.stderr.len != 0) return error.RuntimeProbeUnexpectedStderr;
    if (!sameFile(before, try file.stat(io.getIo())) or !std.mem.eql(u8, stamp, try fingerprint(alloc, binding))) return error.RuntimeExecutableChanged;
    const version = std.mem.trim(u8, result.stdout, " \r\n\t");
    _ = try versionNumbers(binding.kind, version);
    return .{ .handle = binding.handle, .kind = binding.kind, .version = try alloc.dupe(u8, version), .executable_sha256 = try alloc.dupe(u8, &std.fmt.bytesToHex(digest.finalResult(), .lower)), .fingerprint = stamp };
}

fn numbers(raw: []const u8) ![3]u32 {
    var parts = std.mem.splitScalar(u8, raw, '.');
    var result: [3]u32 = @splat(0);
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == 3 or part.len == 0 or part.len > 9) return error.UnsupportedRuntimeConstraint;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return error.UnsupportedRuntimeConstraint;
        result[count] = std.fmt.parseInt(u32, part, 10) catch return error.UnsupportedRuntimeConstraint;
        count += 1;
    }
    if (count == 0) return error.UnsupportedRuntimeConstraint;
    return result;
}

fn versionNumbers(kind: Kind, output: []const u8) ![3]u32 {
    const prefix = switch (kind) {
        .node => "v",
        .python => "Python ",
    };
    if (!std.mem.startsWith(u8, output, prefix)) return error.RuntimeVersionMismatch;
    return numbers(output[prefix.len..]);
}

pub fn satisfies(kind: Kind, version: []const u8, constraint: []const u8) !bool {
    const actual = try versionNumbers(kind, version);
    const lower_bound = std.mem.startsWith(u8, constraint, ">=");
    const wanted = try numbers(if (lower_bound) constraint[2..] else if (std.mem.startsWith(u8, constraint, "=")) constraint[1..] else constraint);
    for (actual, wanted) |a, b| {
        if (a != b) return lower_bound and a > b;
    }
    return true;
}

test "runtime handles enforce explicit absolute owner bindings and supported version constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try satisfies(.node, "v22.22.1", ">=22"));
    try std.testing.expect(!try satisfies(.node, "v20.19.0", ">=22"));
    try std.testing.expect(try satisfies(.python, "Python 3.14.0", ">=3.12"));
    try std.testing.expect(!try satisfies(.node, "v22.22.1", "=22.22.0"));
    try std.testing.expectError(error.UnsupportedRuntimeConstraint, satisfies(.node, "v22.22.1", "^22"));
    try std.testing.expectError(error.RuntimeVersionMismatch, satisfies(.node, "Python 3.14.0", ">=22"));
    const valid = "{\"handles\":[{\"handle\":\"node\",\"kind\":\"node\",\"executable\":\"/usr/bin/node\"}]}";
    try std.testing.expectEqual(@as(usize, 1), (try parse(a, valid)).handles.len);
    try std.testing.expectError(error.InvalidRuntimeBinding, parse(a, "{\"handles\":[{\"handle\":\"node\",\"kind\":\"node\",\"executable\":\"node\"}]}"));
    try std.testing.expectError(error.DuplicateRuntimeHandle, parse(a, "{\"handles\":[{\"handle\":\"node\",\"kind\":\"node\",\"executable\":\"/usr/bin/node\"},{\"handle\":\"node\",\"kind\":\"node\",\"executable\":\"/usr/bin/node\"}]}"));
}

test "runtime probes use fixed arguments, record exact executable identity and detect replacement" {
    if (@import("builtin").os.tag == .windows or @import("builtin").target.cpu.arch.isWasm()) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = --version ] || exit 4\n[ -z \"$NODE_OPTIONS\" ] || exit 5\nprintf 'v22.22.1\\n'\n";
    var file = try tmp.dir.createFile(io.getIo(), "runtime", .{ .permissions = .fromMode(0o700) });
    try file.writeStreamingAll(io.getIo(), source);
    file.close(io.getIo());
    const path = try io.dirRealpathAlloc(a, tmp.dir, "runtime");
    const binding: Binding = .{ .handle = "node", .kind = .node, .executable = path };
    const result = try probe(a, binding);
    try std.testing.expectEqualStrings("v22.22.1", result.version);
    try std.testing.expectEqualStrings(try workspace.hash(a, source), result.executable_sha256);
    try std.testing.expectEqualStrings(result.fingerprint, try fingerprint(a, binding));
    var replacement = try tmp.dir.createFile(io.getIo(), "runtime", .{ .permissions = .fromMode(0o700) });
    try replacement.writeStreamingAll(io.getIo(), "#!/bin/sh\nprintf 'v20.0.0\\n'\n");
    replacement.close(io.getIo());
    try std.testing.expect(!std.mem.eql(u8, result.fingerprint, try fingerprint(a, binding)));
    try std.testing.expect(!try satisfies(.node, (try probe(a, binding)).version, ">=22"));
}
