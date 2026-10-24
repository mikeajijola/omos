//! Cancellation and deadlines for an owned I/O operation. Cancellation drains
//! the losing task before caller-owned memory or handles can be released.
const std = @import("std");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

pub const Control = struct {
    deadline: std.Io.Clock.Timestamp,
    cancel: *std.atomic.Value(bool),

    pub fn check(self: Control) !void {
        if (self.cancel.load(.seq_cst)) return error.Cancelled;
        std.debug.assert(self.deadline.clock == .awake);
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, self.deadline)) return error.Timeout;
    }
};

pub fn run(
    comptime Result: type,
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !Result {
    if (cancel_flag.load(.seq_cst)) {
        debug_trace.logf("stream", "bounded termination cause=cancellation phase=admission", .{});
        return error.Cancelled;
    }
    std.debug.assert(deadline.clock == .awake);

    const zio = io_mod.getIo();
    const now = std.Io.Clock.Timestamp.now(zio, .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
        debug_trace.logf("stream", "bounded termination cause=deadline phase=admission", .{});
        return error.Timeout;
    }

    const Event = union(enum) {
        request: anyerror!Result,
        watch: anyerror!Watch.Outcome,
    };
    const Operation = @TypeOf(operation);
    const Runner = struct {
        fn run(value: Operation) anyerror!Result {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event), watch: *Watch) void {
            watch.stopped.set(select.io);
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .watch => {},
            };
        }
    };

    var watch: Watch = .{};
    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(zio, &select_buffer);
    select.concurrent(.watch, Watch.run, .{ &watch, cancel_flag, deadline }) catch |err| {
        return err;
    };
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        watch.finish(&select);
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select, &watch);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            watch.finish(&select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=request_result", .{});
                var owned_result = request_result catch return error.Cancelled;
                owned_result.deinit(alloc);
                return error.Cancelled;
            }
            if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(zio, .awake), .lt, deadline)) {
                var late_result = request_result catch return error.Timeout;
                late_result.deinit(alloc);
                return error.Timeout;
            }
            return request_result;
        },
        .watch => |watch_result| {
            Cleanup.drain(alloc, &select, &watch);
            const outcome = try watch_result;
            if (outcome == .cancelled) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=control", .{});
                return error.Cancelled;
            }
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=deadline_cleanup", .{});
                return error.Cancelled;
            }
            debug_trace.logf("stream", "bounded termination cause=deadline phase=control", .{});
            return error.Timeout;
        },
    }
}

/// Watches one bounded request for cancellation and its deadline. The request
/// owner stops it with `finish` instead of cancelling it: in Zig 0.17 a cancel
/// can interrupt whatever task the watch's worker thread runs next, and an
/// interrupted connect then fails with ISCONN.
pub const Watch = struct {
    stopped: std.Io.Event = .unset,

    pub const Outcome = enum { stopped, cancelled, deadline };

    pub fn run(
        watch: *Watch,
        cancel_flag: *std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
    ) anyerror!Outcome {
        const zio = io_mod.getIo();
        while (true) {
            if (cancel_flag.load(.seq_cst)) return .cancelled;
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(zio, .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) return .deadline;
            }
            watch.stopped.waitTimeout(zio, .{ .duration = .{
                .raw = .fromMilliseconds(5),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => continue,
                else => |e| return e,
            };
            return .stopped;
        }
    }

    /// Stops the watch and waits for its event, then releases the select.
    /// Call only when the watch event is the one still outstanding.
    pub fn finish(watch: *Watch, select: anytype) void {
        watch.stopped.set(select.io);
        const event = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
            // Only Select.cancel closes the queue, so nothing is outstanding.
            error.Closed => return,
        };
        std.debug.assert(event == .watch);
        std.debug.assert(select.cancel() == null);
    }
};

test "bounded operation drains a cancelled worker and disposes its late owned result" {
    var cancelled = std.atomic.Value(bool).init(false);
    var active = std.atomic.Value(bool).init(false);
    var disposed = std.atomic.Value(bool).init(false);
    const Result = struct {
        disposed: *std.atomic.Value(bool),
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.disposed.store(true, .seq_cst);
        }
    };
    const Operation = struct {
        cancelled: *std.atomic.Value(bool),
        active: *std.atomic.Value(bool),
        disposed: *std.atomic.Value(bool),
        pub fn run(self: @This()) !Result {
            self.active.store(true, .seq_cst);
            defer self.active.store(false, .seq_cst);
            self.cancelled.store(true, .seq_cst);
            io_mod.getIo().sleep(.fromSeconds(30), .awake) catch {};
            // An operation may finish producing a value during cancellation.
            return .{ .disposed = self.disposed };
        }
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(60) });
    try std.testing.expectError(error.Cancelled, run(Result, std.testing.allocator, &cancelled, deadline, Operation{ .cancelled = &cancelled, .active = &active, .disposed = &disposed }));
    try std.testing.expect(!active.load(.seq_cst));
    try std.testing.expect(disposed.load(.seq_cst));
}

test "bounded operation rejects cancelled and expired admission before running work" {
    var cancelled = std.atomic.Value(bool).init(true);
    var ran = std.atomic.Value(bool).init(false);
    const Result = struct {
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };
    const Operation = struct {
        ran: *std.atomic.Value(bool),
        pub fn run(self: @This()) !Result {
            self.ran.store(true, .seq_cst);
            return .{};
        }
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(60) });
    try std.testing.expectError(error.Cancelled, run(Result, std.testing.allocator, &cancelled, deadline, Operation{ .ran = &ran }));
    cancelled.store(false, .seq_cst);
    try std.testing.expectError(error.Timeout, run(Result, std.testing.allocator, &cancelled, .now(io_mod.getIo(), .awake), Operation{ .ran = &ran }));
    try std.testing.expect(!ran.load(.seq_cst));
}
