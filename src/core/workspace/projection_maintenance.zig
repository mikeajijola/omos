//! Background cleanup of verified disposable views. Durable drafts and process
//! lifetime pins stay outside the eviction budget.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");

pub const Worker = struct {
    manager: workspace.Manager,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn loop(self: *Worker) void {
        const path = std.Io.Dir.path.join(std.heap.c_allocator, &.{ self.manager.root, "projection-maintenance.lock" }) catch return;
        defer std.heap.c_allocator.free(path);
        const pin = (@import("../shared/resource_pin.zig").tryExclusive(path) catch return) orelse return;
        defer pin.close();
        while (!self.stopping.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var manager = self.manager;
            manager.alloc = arena.allocator();
            manager.operation_control = .{ .cancel = &self.stopping, .deadline = .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(15) }) };
            _ = @import("filesystem_projection.zig").collect(manager, .trim) catch |err| {
                if (err != error.Cancelled and err != error.Timeout) @import("../shared/debug_trace.zig").logf("workspace", "projection maintenance retained views: {s}", .{@errorName(err)});
            };
            // Short waits let shutdown cancel collection and join promptly.
            for (0..30) |_| {
                if (self.stopping.load(.acquire)) return;
                io.getIo().sleep(.fromSeconds(1), .awake) catch {};
            }
        }
    }
};

/// The worker borrows repository identity from a live turn. Stop and join it
/// before releasing that turn's arena, including on partial startup failures.
pub const Handle = struct {
    worker: *Worker,
    thread: std.Thread,

    pub fn start(manager: workspace.Manager) !Handle {
        const worker = try std.heap.c_allocator.create(Worker);
        errdefer std.heap.c_allocator.destroy(worker);
        worker.* = .{ .manager = manager };
        return .{ .worker = worker, .thread = try std.Thread.spawn(.{}, Worker.loop, .{worker}) };
    }

    pub fn stop(self: Handle) void {
        self.worker.stopping.store(true, .release);
        self.thread.join();
        std.heap.c_allocator.destroy(self.worker);
    }
};
