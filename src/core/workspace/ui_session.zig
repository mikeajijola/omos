//! Browser-host interaction capabilities. The native CLI continues to own the
//! agent loop, session persistence, permissions, contracts and publication.
const std = @import("std");
const io = @import("../shared/io.zig");
const worker = @import("../agent/worker_runtime.zig");

const ValidationFixture = struct {
    host: *Host = undefined,
    emitted: usize = 0,
    respond: bool = false,

    fn emit(raw: *anyopaque, _: []const u8) !void {
        const self: *ValidationFixture = @ptrCast(@alignCast(raw));
        self.emitted += 1;
        if (self.respond) try self.host.validated(self.host.validation_id, "{\"status\":\"valid\"}");
    }
};

test "workspace UI validation uses its caller deadline and rejects a late receipt" {
    var fixture: ValidationFixture = .{};
    var host: Host = .{ .context = &fixture, .emit_fn = ValidationFixture.emit };
    fixture.host = &host;
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(20) });
    try std.testing.expectError(error.UiValidationPending, host.validateSource(std.testing.allocator, "source", deadline));
    try std.testing.expectEqual(@as(usize, 1), fixture.emitted);
    try std.testing.expectEqual(@as(usize, 0), host.validation_id);
    try std.testing.expectError(error.StaleValidationRequest, host.validated(1, "{}"));
}

test "workspace UI validation retains an exact response and releases its request identity" {
    var fixture: ValidationFixture = .{ .respond = true };
    var host: Host = .{ .context = &fixture, .emit_fn = ValidationFixture.emit };
    fixture.host = &host;
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(5) });
    const response = try host.validateSource(std.testing.allocator, "source", deadline);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"status\":\"valid\"}", response);
    try std.testing.expectEqual(@as(usize, 0), host.validation_id);
    try std.testing.expect(host.validation_response == null);
}

test "workspace UI validation does not dispatch an expired or cancelled request" {
    var fixture: ValidationFixture = .{};
    var host: Host = .{ .context = &fixture, .emit_fn = ValidationFixture.emit };
    fixture.host = &host;
    const expired = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    try std.testing.expectError(error.UiValidationPending, host.validateSource(std.testing.allocator, "source", expired));
    host.cancel.store(true, .release);
    const future = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(1) });
    try std.testing.expectError(error.Cancelled, host.validateSource(std.testing.allocator, "source", future));
    try std.testing.expectEqual(@as(usize, 0), fixture.emitted);
}

pub const Host = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    cancel: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    bound_worker: ?*worker.WorkerRuntime = null,
    steering: std.ArrayList([]u8) = .empty,
    approval_id: usize = 0,
    approval_answer: ?bool = null,
    question_id: usize = 0,
    next_input: usize = 1,
    validation_id: usize = 0,
    validation_response: ?[]u8 = null,
    session_id: []const u8 = "",
    project_root: ?[]const u8 = null,
    execution_lease_held: bool = false,
    background_authority: ?*const @import("background_control.zig").Authority = null,
    coordinator_mode: bool = false,
    session_binding_ctx: ?*anyopaque = null,
    session_binding_fn: ?*const fn (*anyopaque, []const u8) anyerror!void = null,

    pub fn emit(self: *Host, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{});
        defer std.heap.c_allocator.free(bytes);
        try self.emit_fn(self.context, bytes);
    }

    pub fn attach(self: *Host, runtime: ?*worker.WorkerRuntime) void {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        self.bound_worker = runtime;
    }

    pub fn beginSession(self: *Host, id: []const u8) !void {
        if (self.session_binding_fn) |bind| try bind(self.session_binding_ctx.?, id);
        self.mutex.lockUncancelable(io.getIo());
        self.session_id = id;
        self.mutex.unlock(io.getIo());
        try self.emit(.{ .type = "session", .session_id = id });
    }

    pub fn stop(self: *Host) void {
        self.cancel.store(true, .release);
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        if (self.bound_worker) |runtime| _ = runtime.cancelPendingQuestionBatch();
    }

    pub fn steer(self: *Host, text: []const u8) !void {
        if (text.len == 0 or text.len > 65536 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidSteering;
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        if (self.steering.items.len >= 16) return error.SteeringQueueFull;
        try self.steering.append(std.heap.c_allocator, try std.heap.c_allocator.dupe(u8, text));
    }

    pub fn takeSteering(self: *Host, alloc: std.mem.Allocator) !worker.SteeringBoundaryResult {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        if (self.steering.items.len == 0) return .none;
        const values = try alloc.alloc([]u8, self.steering.items.len);
        var count: usize = 0;
        errdefer {
            for (values[0..count]) |value| alloc.free(value);
            alloc.free(values);
        }
        for (self.steering.items, 0..) |value, i| {
            values[i] = try alloc.dupe(u8, value);
            count += 1;
        }
        for (self.steering.items) |value| std.heap.c_allocator.free(value);
        self.steering.clearRetainingCapacity();
        return .{ .continue_turn = values };
    }

    pub fn approve(self: *Host, label: []const u8) !bool {
        self.mutex.lockUncancelable(io.getIo());
        const id = self.next_input;
        self.next_input += 1;
        self.approval_id = id;
        self.approval_answer = null;
        self.mutex.unlock(io.getIo());
        defer {
            self.mutex.lockUncancelable(io.getIo());
            self.approval_id = 0;
            self.approval_answer = null;
            self.mutex.unlock(io.getIo());
        }
        try self.emit(.{ .type = "input_required", .kind = "approval", .request_id = id, .prompt = label });
        while (!self.cancel.load(.acquire)) {
            self.mutex.lockUncancelable(io.getIo());
            const decision = self.approval_answer;
            self.mutex.unlock(io.getIo());
            if (decision) |value| return value;
            io.sleep(10 * std.time.ns_per_ms);
        }
        return false;
    }

    pub fn answer(self: *Host, id: usize, approved: ?bool, answers: ?[]const []const u8) !void {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        if (id != 0 and id == self.approval_id and approved != null and self.approval_answer == null) {
            self.approval_answer = approved;
            return;
        }
        if (id != 0 and id == self.question_id and answers != null) {
            const runtime = self.bound_worker orelse return error.NoActiveInput;
            const pending = try runtime.snapshotPendingQuestionBatch(std.heap.c_allocator) orelse return error.NoActiveInput;
            defer pending.deinit(std.heap.c_allocator);
            if (pending.entries.len != answers.?.len) return error.InvalidQuestionAnswers;
            try runtime.submitQuestionBatchAnswer(std.heap.c_allocator, answers);
            self.question_id = 0;
            return;
        }
        return error.StaleInputRequest;
    }

    pub fn validateSource(self: *Host, arena: std.mem.Allocator, revision: []const u8, deadline: std.Io.Clock.Timestamp) ![]const u8 {
        if (self.cancel.load(.acquire)) return error.Cancelled;
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline)) return error.UiValidationPending;
        self.mutex.lockUncancelable(io.getIo());
        const id = self.next_input;
        self.next_input += 1;
        self.validation_id = id;
        self.validation_response = null;
        self.mutex.unlock(io.getIo());
        defer {
            self.mutex.lockUncancelable(io.getIo());
            if (self.validation_response) |bytes| std.heap.c_allocator.free(bytes);
            self.validation_response = null;
            self.validation_id = 0;
            self.mutex.unlock(io.getIo());
        }
        try self.emit(.{ .type = "validate_ui", .request_id = id, .revision = revision });
        while (!self.cancel.load(.acquire) and std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline)) {
            self.mutex.lockUncancelable(io.getIo());
            if (self.validation_response) |bytes| {
                defer self.mutex.unlock(io.getIo());
                return arena.dupe(u8, bytes);
            }
            self.mutex.unlock(io.getIo());
            io.sleep(10 * std.time.ns_per_ms);
        }
        if (self.cancel.load(.acquire)) return error.Cancelled;
        return error.UiValidationPending;
    }

    pub fn validated(self: *Host, id: usize, response: []const u8) !void {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        if (id == 0 or id != self.validation_id or self.validation_response != null or response.len > 512 * 1024) return error.StaleValidationRequest;
        self.validation_response = try std.heap.c_allocator.dupe(u8, response);
    }

    pub fn monitor(self: *Host, stopping: *const std.atomic.Value(bool)) void {
        while (!stopping.load(.acquire)) {
            self.pollQuestion() catch {};
            io.sleep(20 * std.time.ns_per_ms);
        }
    }

    fn pollQuestion(self: *Host) !void {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        const runtime = self.bound_worker orelse return;
        const pending = try runtime.snapshotPendingQuestionBatch(std.heap.c_allocator) orelse {
            self.question_id = 0;
            return;
        };
        defer pending.deinit(std.heap.c_allocator);
        if (self.question_id != 0) return;
        self.question_id = self.next_input;
        self.next_input += 1;
        try self.emit(.{ .type = "input_required", .kind = "question", .request_id = self.question_id, .questions = pending.entries });
    }

    pub fn deinit(self: *Host) void {
        for (self.steering.items) |value| std.heap.c_allocator.free(value);
        self.steering.deinit(std.heap.c_allocator);
    }
};
