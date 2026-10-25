//! Bounded, resumable company progress streams. Receipts retain the original
//! request hash; continuation positions are issuer-signed, scoped cursors.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const service = @import("company_service.zig");
const model = @import("definition.zig");
const records = @import("../shared/record_json.zig");
const control_mod = @import("../shared/bounded_operation.zig");

const byte_budget = 1024 * 1024;
const event_budget = 32;
var active = std.atomic.Value(usize).init(0);

fn position(alloc: std.mem.Allocator, response: []const u8) ![]const u8 {
    const envelope = try records.decode(struct { payload: []const u8 }, alloc, response, .{ .ignore_unknown_fields = true });
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, alloc, envelope.payload, .{});
    const result = model.field(payload, "result") orelse return error.InvalidCompanyProgressCursor;
    const progress = model.field(result, "progress") orelse return error.CompanyProgressRequired;
    const next = model.field(progress, "next_cursor") orelse .null;
    const cursor = if (next == .string) next else model.field(progress, "resume_cursor") orelse return error.InvalidCompanyProgressCursor;
    if (cursor != .string or cursor.string.len == 0 or cursor.string.len > 4096 or std.mem.findAny(u8, cursor.string, "\r\n\x00") != null) return error.InvalidCompanyProgressCursor;
    return cursor.string;
}

const Subscription = struct {
    manager: workspace.Manager,
    raw: []const u8,
    writable: bool,
    initial: []const u8 = "",
    cursor: [4096]u8 = undefined,
    cursor_len: usize = 0,
    control: control_mod.Control = undefined,
    cancelled: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
    parent_cancel: ?*std.atomic.Value(bool) = null,
    watcher: ?std.Thread = null,

    pub fn release(self: *Subscription) void {
        self.stop();
        _ = active.fetchSub(1, .acq_rel);
    }

    fn stop(self: *Subscription) void {
        self.stopped.store(true, .release);
        if (self.watcher) |watcher| watcher.join();
        self.watcher = null;
    }

    fn watch(self: *Subscription, stream: std.Io.net.Stream) void {
        while (!self.stopped.load(.acquire)) {
            if (self.parent_cancel) |parent| if (parent.load(.seq_cst)) break;
            self.control.check() catch break;
            var descriptors = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = 0, .revents = 0 }};
            const count = std.posix.poll(&descriptors, 0) catch break;
            if (count != 0 and descriptors[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) break;
            io.sleep(100 * std.time.ns_per_ms);
        }
        if (!self.stopped.load(.acquire)) {
            self.cancelled.store(true, .seq_cst);
            stream.shutdown(io.getIo(), .both) catch {};
        }
    }

    fn flush(body: *std.http.BodyWriter) !void {
        try body.writer.flush();
        try body.flush();
    }

    fn emit(self: *Subscription, body: *std.http.BodyWriter, response: []const u8, cursor: []const u8, used: *usize) !bool {
        const length = response.len + cursor.len + 32;
        if (length > byte_budget - 1024 - used.*) return false;
        try body.writer.print("id: {s}\nevent: workspace\ndata: {s}\n\n", .{ cursor, response });
        try flush(body);
        if (cursor.ptr != self.cursor[0..].ptr) @memcpy(self.cursor[0..cursor.len], cursor);
        self.cursor_len = cursor.len;
        used.* += length;
        return true;
    }

    pub fn respond(self: *Subscription, request: *std.http.Server.Request) !void {
        var buffer: [4096]u8 = undefined;
        var body = try request.respondStreaming(&buffer, .{ .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
        } });
        var used: usize = 0;
        _ = try self.emit(&body, self.initial, self.cursor[0..self.cursor_len], &used);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.initial, &digest, .{});
        var events: usize = 1;
        while (events < event_budget) {
            self.control.check() catch break;
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var manager = self.manager;
            manager.alloc = arena.allocator();
            const response = service.progress(manager, self.raw, self.writable, self.cursor[0..self.cursor_len]) catch |err| {
                if (err == error.Timeout or err == error.Cancelled) break;
                try body.writer.print("event: error\ndata: {{\"error\":\"{s}\"}}\n\n", .{@errorName(err)});
                try flush(&body);
                break;
            };
            const next = try position(manager.alloc, response);
            var next_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(response, &next_digest, .{});
            if (!std.mem.eql(u8, &digest, &next_digest)) {
                if (!try self.emit(&body, response, next, &used)) break;
                digest = next_digest;
                events += 1;
            } else {
                if (used + 32 > byte_budget - 1024) break;
                try body.writer.writeAll(": keep-alive\n\n");
                try flush(&body);
                used += 14;
            }
            io.sleep(std.time.ns_per_s);
        }
        try body.writer.writeAll("event: end\ndata: {\"reason\":\"reconnect\"}\n\n");
        try body.end();
    }
};

pub fn prepare(original: workspace.Manager, raw: []const u8, writable: bool, stream: std.Io.net.Stream) !*Subscription {
    if (active.fetchAdd(1, .acq_rel) >= service.progress_stream_limit) {
        _ = active.fetchSub(1, .acq_rel);
        return error.CompanySubscriptionsBusy;
    }
    errdefer {
        _ = active.fetchSub(1, .acq_rel);
    }
    const subscription = try original.alloc.create(Subscription);
    subscription.* = .{ .manager = original, .raw = raw, .writable = writable };
    errdefer subscription.stop();
    var deadline: std.Io.Clock.Timestamp = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(service.progress_stream_seconds)) };
    if (original.operation_control) |parent| {
        try parent.check();
        if (std.Io.Clock.Timestamp.compare(parent.deadline, .lt, deadline)) deadline = parent.deadline;
        subscription.parent_cancel = parent.cancel;
    }
    subscription.control = .{ .cancel = &subscription.cancelled, .deadline = deadline };
    subscription.manager.operation_control = subscription.control;
    subscription.watcher = try std.Thread.spawn(.{}, Subscription.watch, .{ subscription, stream });
    subscription.initial = try service.progress(subscription.manager, raw, writable, null);
    const cursor = try position(original.alloc, subscription.initial);
    if (subscription.initial.len + cursor.len + 32 > byte_budget - 1024) return error.ServiceResponseTooLarge;
    @memcpy(subscription.cursor[0..cursor.len], cursor);
    subscription.cursor_len = cursor.len;
    return subscription;
}
