//! Long-lived stdio transport for the existing native session runtime.
//! Public delivery journals are operational profile state, not company facts.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("../workspace/fossil_workspace.zig");
const interaction = @import("../workspace/ui_session.zig");
const schedule_worker = @import("../workspace/schedule_worker.zig");
const scheduling = @import("../workspace/scheduling.zig");
const version = "omos.ui-host/v1";
const alloc = std.heap.c_allocator;

pub const Runner = struct {
    context: *anyopaque,
    prompt: *const fn (*anyopaque, []const [:0]const u8, *interaction.Host) anyerror!u8,
    snapshot: *const fn (*anyopaque, std.mem.Allocator, []const [:0]const u8) anyerror![]const u8,
};

const Job = struct {
    server: *Server,
    id: []const u8,
    request_hash: []const u8,
    args: []const [:0]const u8,
    ui: interaction.Host,
    finished: std.atomic.Value(bool) = .init(false),
    exit_code: u8 = 0,
    error_code: ?[]const u8 = null,
    execution_lease: ?workspace.ExecutionLease = null,
    journal: std.Io.File,
    position: u64 = 0,
    cursor: usize = 0,

    fn emit(raw: *anyopaque, data: []const u8) !void {
        const self: *Job = @ptrCast(@alignCast(raw));
        self.server.output_mutex.lockUncancelable(io.getIo());
        defer self.server.output_mutex.unlock(io.getIo());
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
        defer parsed.deinit();
        const model = @import("../workspace/definition.zig");
        if (std.mem.eql(u8, model.text(parsed.value, "type"), "result")) {
            if (model.field(parsed.value, "data")) |result| {
                const code = model.text(result, "error");
                if (code.len > 0) self.error_code = try alloc.dupe(u8, code);
            }
        }
        const line = try std.json.Stringify.valueAlloc(alloc, .{ .version = version, .type = "event", .turn = self.id, .cursor = self.cursor + 1, .data = parsed.value }, .{});
        defer alloc.free(line);
        var buffer: [4096]u8 = undefined;
        var writer = self.journal.writer(io.getIo(), &buffer);
        writer.pos = self.position;
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        try self.journal.sync(io.getIo());
        self.position += line.len + 1;
        self.cursor += 1;
        if (std.mem.eql(u8, @import("../workspace/definition.zig").text(parsed.value, "type"), "session")) {
            const session = @import("../workspace/definition.zig").text(parsed.value, "session_id");
            if (!safeSessionId(session)) return error.InvalidSessionId;
            const digest = try workspace.hash(alloc, session);
            defer alloc.free(digest);
            const index_path = try alloc.print("{s}/session-{s}.json", .{ self.server.journal_dir, digest });
            defer alloc.free(index_path);
            const index_bytes = try std.json.Stringify.valueAlloc(alloc, .{ .turn = self.id }, .{});
            defer alloc.free(index_bytes);
            try io.writeFileAtomic(alloc, index_path, index_bytes);
        }
        try output(line);
    }

    fn run(self: *Job) void {
        defer self.finished.store(true, .release);
        self.perform();
    }

    fn perform(self: *Job) void {
        defer if (self.execution_lease) |lease| {
            lease.release();
            self.execution_lease = null;
        };
        const exit = self.server.runner.prompt(self.server.runner.context, self.args, &self.ui) catch |err| blk: {
            self.error_code = alloc.dupe(u8, @errorName(err)) catch null;
            self.ui.emit(.{ .type = "error", .code = @errorName(err) }) catch {};
            break :blk @as(u8, 1);
        };
        self.exit_code = exit;
        self.ui.emit(.{ .type = "turn_end", .exit_code = exit }) catch {};
    }

    fn destroy(self: *Job) void {
        self.ui.deinit();
        self.journal.close(io.getIo());
        for (self.args) |arg| alloc.free(arg);
        alloc.free(self.args);
        alloc.free(self.id);
        alloc.free(self.request_hash);
        if (self.error_code) |code| alloc.free(code);
        if (self.execution_lease) |lease| lease.release();
        alloc.destroy(self);
    }
};

const Server = struct {
    runner: Runner,
    state_mutex: std.Io.Mutex = .init,
    output_mutex: std.Io.Mutex = .init,
    job: ?*Job = null,
    thread: ?std.Thread = null,
    journal_dir: []const u8,
    repository: []const u8,
    workspace_id: []const u8,

    fn respond(self: *Server, id: []const u8, result: std.json.Value, err: ?[]const u8) !void {
        self.output_mutex.lockUncancelable(io.getIo());
        defer self.output_mutex.unlock(io.getIo());
        const bytes = try std.json.Stringify.valueAlloc(alloc, .{ .version = version, .type = "response", .id = id, .result = result, .err = err }, .{});
        defer alloc.free(bytes);
        try output(bytes);
    }

    fn reap(self: *Server) void {
        if (self.job) |job| if (job.finished.load(.acquire)) {
            if (self.thread) |thread| thread.join();
            job.destroy();
            self.job = null;
            self.thread = null;
        };
    }

    fn dispatch(self: *Server, arena: std.mem.Allocator, raw: []const u8) !void {
        self.state_mutex.lockUncancelable(io.getIo());
        defer self.state_mutex.unlock(io.getIo());
        const Request = struct { version: []const u8, id: []const u8, method: []const u8, params: std.json.Value = .null };
        const request = try records.decode(Request, arena, raw, .{});
        if (!std.mem.eql(u8, request.version, version) or !safeId(request.id)) return error.InvalidUiRequest;
        self.reap();
        const result = self.execute(arena, request.id, request.method, request.params) catch |err| {
            try self.respond(request.id, .null, @errorName(err));
            return;
        };
        try self.respond(request.id, result, null);
    }

    fn execute(self: *Server, arena: std.mem.Allocator, id: []const u8, method: []const u8, params: std.json.Value) !std.json.Value {
        // A profile binding change never retargets a running UI host.
        // Cancellation and public replay remain available for retained work.
        if (!std.mem.eql(u8, method, "cancel") and !std.mem.eql(u8, method, "events") and !std.mem.eql(u8, method, "session.events")) {
            const bound = (workspace.Manager.bound(arena) catch |err| {
                if (self.job) |active| active.ui.stop();
                return err;
            }) orelse {
                if (self.job) |active| active.ui.stop();
                return error.WorkspaceBindingChanged;
            };
            if (!std.mem.eql(u8, bound.repository, self.repository) or !std.mem.eql(u8, bound.manifest.id, self.workspace_id)) {
                if (self.job) |active| active.ui.stop();
                return error.WorkspaceBindingChanged;
            }
        }
        if (std.mem.eql(u8, method, "initialize")) return value(arena, .{ .version = version, .project = try io.realpathAlloc(arena, "."), .workspace = self.workspace_id, .active_turn = if (self.job) |job| job.id else null });
        if (std.mem.eql(u8, method, "prompt")) return self.start(arena, id, params, null);
        if (std.mem.eql(u8, method, "events")) return self.events(arena, params);
        if (std.mem.eql(u8, method, "session.events")) {
            const query = try std.json.parseFromValueLeaky(struct { session: []const u8, offset: u64 = 0 }, arena, params, .{});
            if (!safeSessionId(query.session)) return error.InvalidSessionId;
            const index_path = try arena.print("{s}/session-{s}.json", .{ self.journal_dir, try workspace.hash(arena, query.session) });
            var index_file = try std.Io.Dir.openFileAbsolute(io.getIo(), index_path, .{ .follow_symlinks = false });
            defer index_file.close(io.getIo());
            const index_bytes = try io.readFileToEnd(arena, &index_file, 4096);
            const index = try records.decode(struct { turn: []const u8 }, arena, index_bytes, .{});
            return self.events(arena, try value(arena, .{ .turn = index.turn, .offset = query.offset }));
        }
        if (std.mem.eql(u8, method, "cancel") or std.mem.eql(u8, method, "steer") or std.mem.eql(u8, method, "input") or std.mem.eql(u8, method, "validation")) {
            const Control = struct { turn: []const u8, text: []const u8 = "", request_id: usize = 0, approved: ?bool = null, answers: ?[]const []const u8 = null, receipt: ?std.json.Value = null };
            const control = try std.json.parseFromValueLeaky(Control, arena, params, .{});
            const job = self.job orelse return error.NoActiveTurn;
            if (!std.mem.eql(u8, control.turn, job.id)) return error.StaleTurn;
            if (std.mem.eql(u8, method, "cancel")) job.ui.stop() else if (std.mem.eql(u8, method, "steer")) try job.ui.steer(control.text) else if (std.mem.eql(u8, method, "validation")) try job.ui.validated(control.request_id, try std.json.Stringify.valueAlloc(arena, control.receipt orelse return error.MissingReceipt, .{})) else try job.ui.answer(control.request_id, control.approved, control.answers);
            return value(arena, .{ .accepted = true });
        }
        if (std.mem.eql(u8, method, "snapshot")) {
            const Query = struct { action: []const u8, id: ?[]const u8 = null, entity: ?[]const u8 = null, offset: usize = 0 };
            const query = try std.json.parseFromValueLeaky(Query, arena, params, .{});
            const args = try snapshotArgs(arena, query.action, query.id, query.entity, query.offset);
            return parse(arena, try self.runner.snapshot(self.runner.context, arena, args));
        }
        const manager = (try workspace.Manager.bound(arena)) orelse return error.NoFossilWorkspace;
        if (std.mem.eql(u8, method, "schedule")) {
            const request = try std.json.parseFromValueLeaky(scheduling.Request, arena, params, .{});
            if (request.action == .add or request.action == .move or request.action == .cancel) {
                if (request.revision == null) return error.WorkspaceRevisionRequired;
            }
            return value(arena, try manager.scheduleSnapshot(request));
        }
        if (std.mem.eql(u8, method, "profile.read")) return parse(arena, try manager.profilePhoto(false, null));
        if (std.mem.eql(u8, method, "profile.update")) {
            const photo = try records.decode(struct { content: ?[]const u8 }, arena, try std.json.Stringify.valueAlloc(arena, params, .{}), .{});
            return parse(arena, try manager.profilePhoto(true, photo.content));
        }
        if (std.mem.eql(u8, method, "workspace")) return parse(arena, try @import("../workspace/workspace_service.zig").execute(manager, try std.json.Stringify.valueAlloc(arena, params, .{}), false));
        if (std.mem.startsWith(u8, method, "ui.") or std.mem.eql(u8, method, "task.resume")) return parse(arena, try @import("../workspace/ui_artifact.zig").execute(manager, method, params));
        return error.UnsupportedUiMethod;
    }

    fn start(self: *Server, arena: std.mem.Allocator, id: []const u8, params: std.json.Value, scheduled: ?schedule_worker.Invocation) !std.json.Value {
        const Prompt = struct { text: []const u8 = "", session: ?[]const u8 = null, model: ?[]const u8 = null, effort: ?[]const u8 = null, continue_recovery: bool = false, images: []const []const u8 = &.{} };
        const request = try std.json.parseFromValueLeaky(Prompt, arena, params, .{});
        if (request.text.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(request.text) or std.mem.findScalar(u8, request.text, 0) != null) return error.InvalidPrompt;
        const request_hash = try workspace.hash(arena, try std.json.Stringify.valueAlloc(arena, request, .{}));
        if (self.job) |active| {
            if (!std.mem.eql(u8, active.id, id)) return error.TurnInProgress;
            if (!std.mem.eql(u8, active.request_hash, request_hash)) return error.TurnIdConflict;
            return value(arena, .{ .turn = id, .already_accepted = true });
        }
        var args: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (args.items) |arg| alloc.free(arg);
            args.deinit(alloc);
        }
        for ([_][]const u8{ "--json", "--prompt-permissions" }) |arg| try args.append(alloc, try alloc.dupeSentinel(u8, arg, 0));
        if (request.session) |session| {
            if (!safeSessionId(session)) return error.InvalidSessionId;
            try args.append(alloc, try alloc.dupeSentinel(u8, "--resume-id", 0));
            try args.append(alloc, try alloc.dupeSentinel(u8, session, 0));
        }
        if (request.model) |model| {
            try args.append(alloc, try alloc.dupeSentinel(u8, "--model", 0));
            try args.append(alloc, try alloc.dupeSentinel(u8, model, 0));
        }
        if (request.effort) |effort| {
            try args.append(alloc, try alloc.dupeSentinel(u8, "--effort", 0));
            try args.append(alloc, try alloc.dupeSentinel(u8, effort, 0));
        }
        if (request.images.len > 5) return error.TooManyImages;
        for (request.images) |image| {
            // The local authenticated host resolves upload handles, never model text.
            if (!std.Io.Dir.path.isAbsolute(image)) return error.InvalidImagePath;
            try args.append(alloc, try alloc.dupeSentinel(u8, "--image", 0));
            try args.append(alloc, try alloc.dupeSentinel(u8, image, 0));
        }
        if (request.continue_recovery) try args.append(alloc, try alloc.dupeSentinel(u8, "--continue-recovery", 0)) else {
            try args.append(alloc, try alloc.dupeSentinel(u8, "--", 0));
            try args.append(alloc, try alloc.dupeSentinel(u8, request.text, 0));
        }
        const path = try arena.print("{s}/{s}.ndjson", .{ self.journal_dir, id });
        const journal = std.Io.Dir.createFileAbsolute(io.getIo(), path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var previous = try std.Io.Dir.openFileAbsolute(io.getIo(), path, .{ .follow_symlinks = false });
                defer previous.close(io.getIo());
                var buffer: [4096]u8 = undefined;
                var reader = previous.reader(io.getIo(), &buffer);
                const first = try reader.interface.takeDelimiter('\n') orelse return error.TurnAcceptanceUncertain;
                const entry = try parse(arena, first);
                const data = @import("../workspace/definition.zig").field(entry, "data") orelse return error.TurnAcceptanceUncertain;
                if (!std.mem.eql(u8, @import("../workspace/definition.zig").text(data, "request_hash"), request_hash)) return error.TurnIdConflict;
                return value(arena, .{ .turn = id, .already_accepted = true });
            },
            else => return err,
        };
        errdefer {
            journal.close(io.getIo());
            std.Io.Dir.deleteFileAbsolute(io.getIo(), path) catch {};
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_hash = try alloc.dupe(u8, request_hash);
        errdefer alloc.free(owned_hash);
        const owned_args = try args.toOwnedSlice(alloc);
        errdefer {
            for (owned_args) |arg| alloc.free(arg);
            alloc.free(owned_args);
        }
        const acknowledgement = try value(arena, .{ .turn = id, .already_accepted = false });
        const execution_lease: ?workspace.ExecutionLease = if (scheduled == null) blk: {
            const manager = (try workspace.Manager.bound(arena)) orelse return error.NoFossilWorkspace;
            break :blk (try manager.trySessionExecutionLease(request.session orelse id)) orelse return error.WorkspaceExecutionBusy;
        } else null;
        errdefer if (execution_lease) |lease| lease.release();
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        job.* = .{ .server = self, .id = owned_id, .request_hash = owned_hash, .args = owned_args, .ui = .{ .context = job, .emit_fn = Job.emit, .execution_lease_held = execution_lease != null }, .journal = journal, .execution_lease = execution_lease };
        if (scheduled) |invocation| {
            job.ui.project_root = invocation.task.project_root;
            job.ui.execution_lease_held = true;
        }
        try job.ui.emit(.{ .type = "turn_start", .request_hash = request_hash });
        self.job = job;
        if (scheduled == null) self.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            self.job = null;
            return err;
        };
        return acknowledgement;
    }

    fn available(raw: *anyopaque) bool {
        const self: *Server = @ptrCast(@alignCast(raw));
        self.state_mutex.lockUncancelable(io.getIo());
        defer self.state_mutex.unlock(io.getIo());
        self.reap();
        return self.job == null;
    }

    fn scheduledTask(raw: *anyopaque, manager: workspace.Manager, schedule: scheduling.Schedule, cancel: *std.atomic.Value(bool)) !void {
        const self: *Server = @ptrCast(@alignCast(raw));
        const job = blk: {
            self.state_mutex.lockUncancelable(io.getIo());
            defer self.state_mutex.unlock(io.getIo());
            self.reap();
            if (self.job != null) return error.WorkspaceExecutionBusy;
            const invocation = try schedule_worker.prepare(manager, schedule);
            const id = try manager.alloc.print("schedule-{s}-{d}", .{ schedule.id, schedule.generation });
            if (!safeId(id)) return error.InvalidTurnId;
            const accepted = try self.start(manager.alloc, id, try value(manager.alloc, .{ .text = "continue", .session = invocation.session }), invocation);
            if (@import("../workspace/definition.zig").field(accepted, "already_accepted")) |retained| {
                if (retained == .bool and retained.bool) return error.ScheduledTurnAcceptanceUncertain;
            }
            const started = self.job orelse return error.ScheduledTurnAcceptanceUncertain;
            started.ui.emit(.{ .type = "scheduled_task", .schedule = schedule.id, .task = schedule.task, .turn = id }) catch |err| {
                started.finished.store(true, .release);
                return err;
            };
            break :blk started;
        };
        var cancellation: schedule_worker.Cancellation = .{ .ui = &job.ui, .source = cancel };
        const monitor = std.Thread.spawn(.{}, schedule_worker.Cancellation.loop, .{&cancellation}) catch |err| {
            job.finished.store(true, .release);
            return err;
        };
        // The worker owns this invocation; controls and replay use the same job
        // that ordinary prompts expose through the host.
        job.perform();
        cancellation.finished.store(true, .release);
        monitor.join();
        const exit_code = job.exit_code;
        const failure = schedule_worker.errorFromCode(job.error_code);
        job.finished.store(true, .release);
        if (cancel.load(.acquire)) return error.Cancelled;
        if (exit_code != 0) return failure;
    }

    fn events(self: *Server, arena: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        const Query = struct { turn: []const u8, offset: u64 = 0 };
        const query = try std.json.parseFromValueLeaky(Query, arena, params, .{});
        if (!safeId(query.turn)) return error.InvalidTurnId;
        const path = try arena.print("{s}/{s}.ndjson", .{ self.journal_dir, query.turn });
        var file = try std.Io.Dir.openFileAbsolute(io.getIo(), path, .{ .follow_symlinks = false });
        defer file.close(io.getIo());
        const size = (try file.stat(io.getIo())).size;
        if (query.offset > size) return error.InvalidEventCursor;
        const buffer = try arena.alloc(u8, 2 * 1024 * 1024);
        var reader = file.reader(io.getIo(), buffer);
        try reader.seekTo(query.offset);
        var events_list: std.ArrayList(std.json.Value) = .empty;
        var next = query.offset;
        for (0..32) |_| {
            const line = try reader.interface.takeDelimiter('\n') orelse break;
            if (line.len == 0) continue;
            // A concurrently appended partial tail is retried from the same cursor.
            const event = parse(arena, line) catch break;
            try events_list.append(arena, event);
            next += line.len + 1;
        }
        return value(arena, .{ .events = events_list.items, .next_offset = next, .active = if (self.job) |job| std.mem.eql(u8, job.id, query.turn) and !job.finished.load(.acquire) else false });
    }
};

fn snapshotArgs(arena: std.mem.Allocator, action: []const u8, id: ?[]const u8, entity: ?[]const u8, offset: usize) ![]const [:0]const u8 {
    var result: std.ArrayList([:0]const u8) = .empty;
    const simple = [_][]const u8{ "status", "models", "permissions", "doctor", "credits" };
    var accepted = false;
    for (simple) |name| if (std.mem.eql(u8, name, action)) {
        try result.append(arena, try arena.dupeSentinel(u8, name, 0));
        accepted = true;
        break;
    };
    if (std.mem.eql(u8, action, "sessions")) {
        try result.appendSlice(arena, &.{ "sessions", "--all" });
        accepted = true;
    }
    if (std.mem.eql(u8, action, "session")) {
        const selected = id orelse return error.SessionIdRequired;
        if (!safeSessionId(selected)) return error.InvalidSessionId;
        try result.appendSlice(arena, &.{ "session", "--id", try arena.dupeSentinel(u8, selected, 0) });
        accepted = true;
    }
    if (std.mem.eql(u8, action, "workspace")) {
        try result.appendSlice(arena, &.{ "workspace", "list" });
        accepted = true;
    }
    if (std.mem.eql(u8, action, "mcp")) {
        try result.appendSlice(arena, &.{ "mcp", "list" });
        accepted = true;
    }
    if (std.mem.eql(u8, action, "usage")) {
        try result.appendSlice(arena, &.{ "usage", "--period", "month" });
        accepted = true;
    }
    if (std.mem.startsWith(u8, action, "fossil.")) {
        const verb = action[7..];
        for ([_][]const u8{ "status", "tasks", "history", "verify", "audit", "query", "diff" }) |name| if (std.mem.eql(u8, verb, name)) {
            try result.appendSlice(arena, &.{ "fossil", try arena.dupeSentinel(u8, name, 0) });
            accepted = true;
            if (std.mem.eql(u8, verb, "query")) {
                try result.append(arena, try arena.dupeSentinel(u8, entity orelse "omos_task", 0));
                try result.appendSlice(arena, &.{ "--offset", try arena.dupeSentinel(u8, try arena.print("{d}", .{offset}), 0) });
            }
            if (std.mem.eql(u8, verb, "diff")) try result.append(arena, try arena.dupeSentinel(u8, id orelse return error.TaskIdRequired, 0));
            break;
        };
        if (std.mem.eql(u8, verb, "definition")) {
            try result.appendSlice(arena, &.{ "fossil", "definition", "show" });
            accepted = true;
        }
    }
    if (!accepted) return error.UnsupportedSnapshot;
    try result.append(arena, "--json");
    return result.toOwnedSlice(arena);
}

pub fn run(runner: Runner) !void {
    @import("../agent/runtime/completion_review.zig").configureInvocation("ui-host");
    var setup = std.heap.ArenaAllocator.init(alloc);
    defer setup.deinit();
    const binding = try workspace.Manager.ensureBound(setup.allocator());
    workspace.configureHostBinding(.{ .repository = binding.repository, .workspace_id = binding.manifest.id });
    defer workspace.configureHostBinding(null);
    var maintenance: @import("../workspace/projection_maintenance.zig").Worker = .{ .manager = binding };
    const maintenance_thread = try std.Thread.spawn(.{}, @import("../workspace/projection_maintenance.zig").Worker.loop, .{&maintenance});
    defer {
        maintenance.stopping.store(true, .release);
        maintenance_thread.join();
    }
    const home = io.getenv("HOME") orelse return error.HomeUnavailable;
    const directory = try alloc.print("{s}/.fx/ui-host/{s}", .{ home, try workspace.hash(alloc, try io.realpathAlloc(alloc, ".")) });
    defer alloc.free(directory);
    try std.Io.Dir.cwd().createDirPath(io.getIo(), directory);
    var server: Server = .{ .runner = runner, .journal_dir = directory, .repository = binding.repository, .workspace_id = binding.manifest.id };
    var scheduler: schedule_worker.Scheduler = .{ .manager = binding, .executor = .{ .context = &server, .run = Server.scheduledTask, .available = Server.available } };
    const scheduler_thread = try std.Thread.spawn(.{}, schedule_worker.Scheduler.loop, .{&scheduler});
    defer {
        scheduler.stopping.store(true, .release);
        server.state_mutex.lockUncancelable(io.getIo());
        if (server.job) |job| job.ui.stop();
        server.state_mutex.unlock(io.getIo());
        scheduler_thread.join();
        if (server.job) |job| {
            if (server.thread) |thread| thread.join();
            job.destroy();
        }
    }
    const buffer = try alloc.alloc(u8, 12 * 1024 * 1024);
    defer alloc.free(buffer);
    var reader = std.Io.File.stdin().reader(io.getIo(), buffer);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        server.dispatch(arena.allocator(), line) catch |err| try server.respond("invalid", .null, @errorName(err));
    }
}

fn output(line: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io.getIo(), &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
fn safeSessionId(id: []const u8) bool {
    @import("../session/session_store.zig").validateSessionId(id) catch return false;
    return true;
}

fn safeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    return true;
}
fn parse(arena: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
}
fn value(arena: std.mem.Allocator, data: anytype) !std.json.Value {
    return parse(arena, try std.json.Stringify.valueAlloc(arena, data, .{}));
}

test "UI host snapshot vocabulary cannot execute arbitrary commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedSnapshot, snapshotArgs(arena.allocator(), "shell", null, null, 0));
    try std.testing.expectError(error.UnsupportedSnapshot, snapshotArgs(arena.allocator(), "fossil.recover", null, null, 0));
    try std.testing.expect(!safeId("../session"));
    try std.testing.expect(!safeSessionId("../session"));
    try std.testing.expect(safeSessionId("native_id.with-dash"));
    try std.testing.expect(safeId("browser-turn-123"));
}
