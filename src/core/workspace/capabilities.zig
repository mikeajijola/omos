//! One local capability contract for CLI, UI, MCP and agent loops.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const classification = @import("classification.zig");
const retrieval = @import("retrieval.zig");
const background = @import("background_api.zig");

pub const Request = struct {
    version: []const u8 = "omos.capabilities/v1",
    action: enum { catalog, classify, search, read, query, attention, conversations, conversation, background },
    classification: ?classification.Request = null,
    retrieval: ?retrieval.Request = null,
    background: ?background.Request = null,
    session: ?[]const u8 = null,
    offset: usize = 0,
};

pub fn execute(alloc: std.mem.Allocator, request: Request, trusted_operator: bool, cancel: ?*std.atomic.Value(bool)) !std.json.Value {
    if (!std.mem.eql(u8, request.version, "omos.capabilities/v1")) return error.UnsupportedCapabilitiesVersion;
    if (request.action == .conversation and request.session == null) return error.SessionIdRequired;
    if (request.action == .catalog) return value(alloc, .{ .version = "omos.capabilities/v1", .operations = &[_][]const u8{ "classify", "search", "read", "query", "attention", "conversations", "conversation", "background" }, .classification_configured = classification.configured(), .classification_advisory = true });
    if (request.action == .classify) return value(alloc, try classification.execute(alloc, request.classification orelse return error.MissingClassificationRequest, cancel));
    var manager = (try workspace.Manager.bound(alloc)) orelse return error.NoFossilWorkspace;
    var stopped = std.atomic.Value(bool).init(false);
    manager.operation_control = .{ .cancel = cancel orelse &stopped, .deadline = .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(30) }) };
    return switch (request.action) {
        .catalog, .classify => unreachable,
        .search, .read, .query => blk: {
            var input = request.retrieval orelse return error.MissingRetrievalRequest;
            input.action = switch (request.action) {
                .search => .search,
                .read => .read,
                else => .query,
            };
            break :blk try retrieval.execute(manager, input);
        },
        .background => blk: {
            const input = request.background orelse return error.MissingBackgroundRequest;
            if (!trusted_operator) switch (input.action) {
                .host, .list, .show, .events, .receipt => {},
                else => return error.OperatorAuthorityRequired,
            };
            break :blk try background.execute(manager, input);
        },
        .attention => try @import("attention.zig").snapshot(manager, request.offset),
        .conversations, .conversation => try @import("conversations.zig").execute(manager, request.session, request.offset),
    };
}

pub fn value(alloc: std.mem.Allocator, data: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, data, .{}), .{});
}
