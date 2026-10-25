//! Local transport for an isolated worker's fixed Unix-domain broker. This
//! adapter redirects native TCP clients; it is not an isolation boundary.
const std = @import("std");

var wrapped: std.Io.VTable = undefined;
var original_vtable: ?*const std.Io.VTable = null;
var broker_path: [std.Io.net.UnixAddress.max_len]u8 = undefined;
var broker_len: usize = 0;
var valid = false;

/// Install before starting threads. The caller retains the original I/O
/// userdata and all operations except outbound IP connection creation.
pub fn wrap(original: std.Io, path: []const u8) std.Io {
    if (original_vtable == null) {
        original_vtable = original.vtable;
        wrapped = original.vtable.*;
        wrapped.netConnectIp = connect;
        valid = path.len > 0 and path.len <= broker_path.len and path[0] == '/' and std.mem.findScalar(u8, path, 0) == null;
        if (valid) {
            @memcpy(broker_path[0..path.len], path);
            broker_len = path.len;
        }
    } else if (original_vtable.? != original.vtable or !valid or !std.mem.eql(u8, broker_path[0..broker_len], path)) {
        valid = false;
    }
    return .{ .userdata = original.userdata, .vtable = &wrapped };
}

fn connect(userdata: ?*anyopaque, address: *const std.Io.net.IpAddress, options: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
    if (!valid or options.mode != .stream or (options.protocol != null and options.protocol.? != .tcp)) return error.AccessDenied;
    const endpoint: std.Io.net.UnixAddress = .{ .path = broker_path[0..broker_len] };
    const handle = original_vtable.?.netConnectUnix(userdata, &endpoint) catch |err| switch (err) {
        error.PermissionDenied, error.SymLinkLoop, error.FileNotFound, error.NotDir, error.ReadOnlyFileSystem => return error.AccessDenied,
        else => |e| return e,
    };
    return .{ .handle = handle, .address = address.* };
}

test "worker broker transport preserves I/O and redirects only stream connections through the selected Unix socket" {
    const Capture = struct {
        calls: usize = 0,
        fn unix(raw: ?*anyopaque, endpoint: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(std.mem.eql(u8, endpoint.path, "/run/omos-broker.sock"));
            self.calls += 1;
            return 17;
        }
    };
    // The production state is initialized once before threads. Restore it so
    // this isolated unit doesn't configure another test's process transport.
    defer {
        original_vtable = null;
        broker_len = 0;
        valid = false;
    }
    var capture: Capture = .{};
    var table = std.testing.io.vtable.*;
    table.netConnectUnix = Capture.unix;
    const source: std.Io = .{ .userdata = &capture, .vtable = &table };
    const selected = wrap(source, "/run/omos-broker.sock");
    try std.testing.expect(selected.userdata == source.userdata);
    inline for (@typeInfo(std.Io.VTable).@"struct".field_names) |field_name| {
        if (comptime !std.mem.eql(u8, field_name, "netConnectIp")) try std.testing.expectEqual(@field(source.vtable, field_name), @field(selected.vtable, field_name));
    }
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(80) };
    const socket = try selected.vtable.netConnectIp(selected.userdata, &address, .{ .mode = .stream });
    try std.testing.expectEqual(@as(std.Io.net.Socket.Handle, 17), socket.handle);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectError(error.AccessDenied, selected.vtable.netConnectIp(selected.userdata, &address, .{ .mode = .dgram }));
    const changed = wrap(source, "/run/another.sock");
    try std.testing.expectError(error.AccessDenied, changed.vtable.netConnectIp(changed.userdata, &address, .{ .mode = .stream }));
}
