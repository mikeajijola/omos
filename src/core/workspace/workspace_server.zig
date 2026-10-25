//! Single-workspace HTTP adapter. Authentication is transport-owned and cannot
//! be granted by an OmniForm declaration. Durable state stays in the manager.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const service = @import("workspace_service.zig");
const bounded = @import("../shared/bounded_operation.zig");

pub fn run(manager: workspace.Manager, port: u16, writable: bool, context: *anyopaque, ready: *const fn (*anyopaque, []const u8) anyerror!void, executor: ?@import("review_worker.zig").Executor, schedule_executor: ?@import("schedule_worker.zig").Executor) !void {
    @import("../agent/runtime/completion_review.zig").configureInvocation("ui-host");
    @import("../shared/debug_trace.zig").configureFromEnv(manager.alloc, std.Io.Dir.path.dirname(manager.repository) orelse ".");
    defer @import("../shared/debug_trace.zig").shutdown();
    workspace.configureHostBinding(.{ .repository = manager.repository, .workspace_id = manager.manifest.id });
    defer workspace.configureHostBinding(null);
    const token = io.getenv("OMOS_WORKSPACE_TOKEN") orelse return error.MissingWorkspaceServiceToken;
    if (token.len < 32 or token.len > 1024 or std.mem.findScalar(u8, token, '\r') != null or std.mem.findScalar(u8, token, '\n') != null) return error.InvalidWorkspaceServiceToken;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try address.listen(io.getIo(), .{ .reuse_address = true });
    defer listener.deinit(io.getIo());
    var maintenance: @import("projection_maintenance.zig").Worker = .{ .manager = manager };
    const maintenance_thread: ?std.Thread = if (writable) try std.Thread.spawn(.{}, @import("projection_maintenance.zig").Worker.loop, .{&maintenance}) else null;
    defer if (maintenance_thread) |thread| {
        maintenance.stopping.store(true, .release);
        thread.join();
    };
    var scheduler: ?@import("review_worker.zig").Scheduler = if (writable and executor != null) .{ .manager = manager, .executor = executor.? } else null;
    var review_threads: [4]?std.Thread = @splat(null);
    defer if (scheduler) |*worker| {
        worker.stopping.store(true, .release);
        for (review_threads) |thread| if (thread) |running| running.join();
    };
    if (scheduler) |*worker| {
        const basis = try manager.modelBasis(try manager.revision("trunk"));
        const count = if (basis) |pinned| pinned.execution.reviewWorkers() else 1;
        for (review_threads[0..count]) |*thread| thread.* = try std.Thread.spawn(.{}, @import("review_worker.zig").Scheduler.loop, .{worker});
    }
    var schedule_worker: ?@import("schedule_worker.zig").Scheduler = if (writable and schedule_executor != null) .{ .manager = manager, .executor = schedule_executor.? } else null;
    const schedule_thread: ?std.Thread = if (schedule_worker) |*worker| try std.Thread.spawn(.{}, @import("schedule_worker.zig").Scheduler.loop, .{worker}) else null;
    defer if (schedule_worker) |*worker| {
        worker.stopping.store(true, .release);
        schedule_thread.?.join();
    };
    try ready(context, try std.json.Stringify.valueAlloc(manager.alloc, .{ .service = "omos.workspace-api/v1", .port = listener.socket.address.getPort(), .workspace = manager.manifest.id, .writable = writable }, .{}));
    var connections: [32]?std.Thread = @splat(null);
    var finished: [32]std.atomic.Value(bool) = @splat(.init(false));
    defer for (&connections) |*connection| if (connection.*) |running| running.join();
    while (true) {
        const stream = try listener.accept(io.getIo());
        const slot = for (&connections, 0..) |*connection, index| {
            if (connection.* == null) break index;
            if (finished[index].load(.acquire)) {
                connection.*.?.join();
                connection.* = null;
                break index;
            }
        } else blk: {
            connections[0].?.join();
            connections[0] = null;
            break :blk @as(usize, 0);
        };
        const connection = std.heap.c_allocator.create(Connection) catch |err| {
            stream.close(io.getIo());
            return err;
        };
        connection.* = .{ .manager = manager, .stream = stream, .token = token, .writable = writable, .finished = &finished[slot] };
        finished[slot].store(false, .release);
        connections[slot] = std.Thread.spawn(.{}, Connection.run, .{connection}) catch |err| {
            stream.close(io.getIo());
            std.heap.c_allocator.destroy(connection);
            return err;
        };
    }
}

const Connection = struct {
    manager: workspace.Manager,
    stream: std.Io.net.Stream,
    token: []const u8,
    writable: bool,
    finished: *std.atomic.Value(bool),

    fn run(self: *Connection) void {
        const finished = self.finished;
        defer finished.store(true, .release);
        defer std.heap.c_allocator.destroy(self);
        defer self.stream.close(io.getIo());
        handle(self.manager, self.stream, self.token, self.writable) catch |err| {
            if (err != error.HttpConnectionClosing) @import("../shared/debug_trace.zig").logf("workspace", "workspace service connection failed error={s}", .{@errorName(err)});
        };
        self.stream.shutdown(io.getIo(), .send) catch {};
        var cancelled = std.atomic.Value(bool).init(false);
        _ = bounded.run(Empty, std.heap.c_allocator, &cancelled, deadline(2), Drain{ .stream = self.stream }) catch {};
    }
};

fn deadline(seconds: i64) std.Io.Clock.Timestamp {
    return .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromSeconds(seconds) });
}

const Empty = struct {
    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};

const Drain = struct {
    stream: std.Io.net.Stream,

    pub fn run(self: @This()) !Empty {
        var buffer: [1024]u8 = undefined;
        var reader = self.stream.reader(io.getIo(), &buffer);
        _ = try reader.interface.discardShort(16384);
        return .{};
    }
};

const Head = struct {
    request: std.http.Server.Request,

    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
};

const ReceiveHead = struct {
    server: *std.http.Server,

    pub fn run(self: @This()) !Head {
        return .{ .request = try self.server.receiveHead() };
    }
};

const Dispatch = struct {
    manager: workspace.Manager,
    request: *std.http.Server.Request,
    stream: std.Io.net.Stream,
    token: []const u8,
    writable: bool,
    keep_alive: *bool,

    pub fn run(self: @This()) !Empty {
        try dispatch(self.manager, self.request, self.stream, self.token, self.writable, self.keep_alive);
        return .{};
    }
};

fn handle(manager: workspace.Manager, stream: std.Io.net.Stream, token: []const u8, writable: bool) !void {
    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io.getIo(), &read_buffer);
    var writer = stream.writer(io.getIo(), &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    for (0..100) |index| {
        // Kernel socket timeouts turn a blocking recv into EAGAIN, which the
        // Zig threaded I/O adapter treats as a programming error. Cancel and
        // drain an owned I/O task instead; no request buffers outlive it.
        var cancelled = std.atomic.Value(bool).init(false);
        var request = (try bounded.run(Head, std.heap.c_allocator, &cancelled, deadline(10), ReceiveHead{ .server = &server })).request;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var request_manager = manager;
        request_manager.alloc = arena.allocator();
        const request_deadline = deadline(60);
        request_manager.operation_control = .{ .cancel = &cancelled, .deadline = request_deadline };
        var keep_alive = request.head.keep_alive and index < 99;
        _ = try bounded.run(Empty, arena.allocator(), &cancelled, request_deadline, Dispatch{ .manager = request_manager, .request = &request, .stream = stream, .token = token, .writable = writable, .keep_alive = &keep_alive });
        if (!keep_alive) return;
    }
}

fn dispatch(manager: workspace.Manager, request: *std.http.Server.Request, stream: std.Io.net.Stream, token: []const u8, writable: bool, keep_alive: *bool) !void {
    @import("../shared/debug_trace.zig").logf("workspace", "workspace service request method={s}", .{@tagName(request.head.method)});
    var headers = request.iterateHeaders();
    var authorization: ?[]const u8 = null;
    var origin = false;
    var progress_stream = false;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            if (authorization != null) {
                keep_alive.* = false;
                return request.respond("{\"error\":\"DuplicateAuthorization\"}", .{ .status = .bad_request, .keep_alive = false });
            }
            authorization = header.value;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) origin = true;
        if (std.ascii.eqlIgnoreCase(header.name, "accept") and std.ascii.eqlIgnoreCase(header.value, "text/event-stream")) progress_stream = true;
    }
    const company = std.mem.eql(u8, request.head.target, "/v1/company");
    if (origin or (!company and !authenticated(authorization, token))) {
        keep_alive.* = false;
        return request.respond("{\"error\":\"Unauthorized\"}", .{ .status = .unauthorized, .keep_alive = false });
    }
    if (progress_stream and (!company or request.head.method != .POST)) return reject(manager, request, keep_alive.*, error.CompanyProgressRequired);
    if (company and request.head.method == .GET) {
        const response = @import("company_service.zig").bootstrap(manager) catch |err| return request.respond(try std.json.Stringify.valueAlloc(manager.alloc, .{ .@"error" = @errorName(err) }, .{}), .{ .status = if (err == error.CompanyNotInitialized) .not_found else .conflict, .keep_alive = keep_alive.* });
        return request.respond(response, .{ .keep_alive = keep_alive.*, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/v1/definition")) {
        const lease = try manager.companyOperationLease();
        defer lease.release();
        @import("company_service.zig").validateInstance(manager) catch |err| return request.respond(try std.json.Stringify.valueAlloc(manager.alloc, .{ .@"error" = @errorName(err) }, .{}), .{ .status = .conflict, .keep_alive = keep_alive.* });
        const snapshot = try manager.definitionSnapshot(null);
        return request.respond(try std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .definition = snapshot, .revision = (try manager.snapshot("")).trunk_revision }, .{}), .{ .keep_alive = keep_alive.*, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }
    const schedules = std.mem.eql(u8, request.head.target, "/v1/schedules");
    if (request.head.method != .POST or (!company and !schedules and !std.mem.eql(u8, request.head.target, "/v1/workspace"))) return request.respond("{\"error\":\"NotFound\"}", .{ .status = .not_found, .keep_alive = keep_alive.* });
    if (request.head.content_length) |length| if (length > 1024 * 1024) {
        keep_alive.* = false;
        return request.respond("{\"error\":\"RequestTooLarge\"}", .{ .status = .payload_too_large, .keep_alive = false });
    };
    const body_reader = try request.readerExpectContinue(&.{});
    const raw = try body_reader.allocRemaining(manager.alloc, .limited(1024 * 1024));
    if (progress_stream) {
        keep_alive.* = false;
        const subscription = @import("company_subscription.zig").prepare(manager, raw, writable, stream) catch |err| {
            if (err == error.Cancelled) return error.HttpConnectionClosing;
            return reject(manager, request, false, err);
        };
        defer subscription.release();
        subscription.respond(request) catch return error.HttpConnectionClosing;
        return;
    }
    const response = (if (company) @import("company_service.zig").execute(manager, raw, writable) else ownerRequest(manager, raw, writable, schedules)) catch |err| {
        return reject(manager, request, keep_alive.*, err);
    };
    try request.respond(response, .{ .keep_alive = keep_alive.*, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    @import("../shared/debug_trace.zig").logf("workspace", "workspace service response sent bytes={d}", .{response.len});
}

fn reject(manager: workspace.Manager, request: *std.http.Server.Request, keep_alive: bool, err: anyerror) !void {
    @import("../shared/debug_trace.zig").logf("workspace", "workspace service rejected error={s}", .{@errorName(err)});
    const status: std.http.Status = switch (err) {
        error.CompanySubscriptionsBusy => .too_many_requests,
        error.CompanyAccessDenied, error.CompanyAccessRevoked, error.CompanySignatureRejected, error.CompanyRequestExpired, error.CompanyDelegationDenied, error.WorkspaceIdentityMismatch, error.ServiceReadOnly, error.HostOwnedEntity, error.WorkspacePathDenied => .forbidden,
        error.CompanyIssuerBoundElsewhere, error.CompanyAuthorityRollbackDetected, error.CompanyIssuerRecoveryRequired, error.CompanyOperationConflict, error.WorkspaceProjectionConflict, error.WorkspaceRevisionChanged, error.StaleWorkspaceDefinition, error.StaleWorkContract => .conflict,
        else => .bad_request,
    };
    return request.respond(try std.json.Stringify.valueAlloc(manager.alloc, .{ .@"error" = @errorName(err) }, .{}), .{ .status = status, .keep_alive = keep_alive });
}

fn ownerRequest(original: workspace.Manager, raw: []const u8, writable: bool, schedules: bool) ![]const u8 {
    var manager = original;
    const lease = try manager.companyOperationLease();
    defer lease.release();
    manager.company_operation_held = true;
    try @import("company_service.zig").validateInstance(manager);
    return if (schedules) service.executeSchedule(manager, raw, writable) else service.execute(manager, raw, writable);
}

fn authenticated(value: ?[]const u8, token: []const u8) bool {
    const actual = value orelse return false;
    if (!std.mem.startsWith(u8, actual, "Bearer ")) return false;
    var expected_hash: [32]u8 = undefined;
    var actual_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &expected_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(actual[7..], &actual_hash, .{});
    return std.crypto.timing_safe.eql([32]u8, expected_hash, actual_hash);
}

test "workspace service authentication requires an exact bearer credential" {
    try std.testing.expect(authenticated("Bearer fixture-token", "fixture-token"));
    try std.testing.expect(!authenticated(null, "fixture-token"));
    try std.testing.expect(!authenticated("Bearer wrong", "fixture-token"));
    try std.testing.expect(!authenticated("Basic fixture-token", "fixture-token"));
}
