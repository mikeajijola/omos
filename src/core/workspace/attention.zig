//! Pending human inputs derived from host events, never inferred from prose.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const background = @import("background_api.zig");
const model = @import("definition.zig");
const io = @import("../shared/io.zig");

pub fn snapshot(manager: workspace.Manager, offset: usize) !std.json.Value {
    const alloc = manager.alloc;
    const page = try background.execute(manager, .{ .offset = offset });
    var items: std.ArrayList(std.json.Value) = .empty;
    var incomplete = false;
    if (offset == 0) try foreground(manager, &items, &incomplete);
    for (page.object.get("workers").?.array.items) |worker| {
        const record = worker.object.get("record").?;
        const state = model.text(record, "state");
        if (!std.mem.eql(u8, state, "running") and !std.mem.eql(u8, state, "waiting")) continue;
        const task = model.text(record, "task");
        const generation: u64 = @intCast(record.object.get("generation").?.integer);
        if (std.mem.eql(u8, state, "waiting")) {
            try items.append(alloc, try @import("capabilities.zig").value(alloc, .{
                .id = try alloc.print("{s}:{d}:waiting", .{ task, generation }),
                .task = task,
                .generation = generation,
                .session = worker.object.get("session") orelse .null,
                .kind = "work_waiting",
                .input = .{ .prompt = model.text(record, "reason") },
                .actionable = false,
            }));
            continue;
        }
        if (worker.object.get("locally_activated")) |active| if (active != .bool or !active.bool) continue;
        const control = @import("background_control.zig");
        const event_path = try alloc.print("{s}/events/background-{s}-{d}.ndjson", .{ try control.directory(manager), task, generation });
        var journal = std.Io.Dir.openFileAbsolute(io.getIo(), event_path, .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer journal.close(io.getIo());
        if (try journal.tryLock(io.getIo(), .exclusive)) {
            journal.unlock(io.getIo());
            continue;
        }
        var cursor: usize = 0;
        var pending: std.AutoHashMap(usize, std.json.Value) = .init(alloc);
        defer pending.deinit();
        var complete = false;
        for (0..128) |_| {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var page_manager = manager;
            page_manager.alloc = scratch.allocator();
            const events = try background.execute(page_manager, .{ .action = .events, .task = task, .generation = generation, .offset = cursor });
            const next: usize = @intCast(events.object.get("next_offset").?.integer);
            if (next == cursor) {
                complete = true;
                break;
            }
            cursor = next;
            for (events.object.get("events").?.array.items) |event| try project(alloc, &pending, event);
        }
        // Never present a possibly resolved old approval as actionable when
        // the journal scan is incomplete.
        if (!complete) {
            incomplete = true;
            continue;
        }
        var iterator = pending.iterator();
        while (iterator.next()) |entry| try items.append(alloc, try @import("capabilities.zig").value(alloc, .{
            .id = try alloc.print("{s}:{d}:{d}", .{ task, generation, entry.key_ptr.* }),
            .task = task,
            .generation = generation,
            .request_id = entry.key_ptr.*,
            .session = worker.object.get("session") orelse .null,
            .kind = model.text(entry.value_ptr.*, "kind"),
            .input = entry.value_ptr.*,
            .actionable = true,
        }));
    }
    if (offset == 0) for (try manager.tasks()) |task| {
        const prompt: []const u8 = switch (task.state) {
            .blocked => "This task is blocked. Review its retained evidence and remaining requirements.",
            .conflict => "Publication has a conflict that needs review.",
            .publication_pending => "Publication is pending. Inspect the task before retrying recovery.",
            else => continue,
        };
        var already_present = false;
        for (items.items) |item| {
            if (std.mem.eql(u8, model.text(item, "task"), task.id)) {
                already_present = true;
                break;
            }
        }
        if (already_present) continue;
        try items.append(alloc, try @import("capabilities.zig").value(alloc, .{
            .id = try alloc.print("{s}:task-state", .{task.id}),
            .task = task.id,
            .session = task.session,
            .state = @tagName(task.state),
            .kind = "work_waiting",
            .input = .{ .prompt = prompt },
            .actionable = false,
        }));
    };
    std.mem.sort(std.json.Value, items.items, {}, struct {
        fn less(_: void, a: std.json.Value, b: std.json.Value) bool {
            return std.mem.lessThan(u8, model.text(a, "id"), model.text(b, "id"));
        }
    }.less);
    return @import("capabilities.zig").value(alloc, .{ .version = "omos.attention/v1", .items = items.items, .next_offset = page.object.get("next_offset") orelse .null, .complete = !incomplete, .scope = "live host inputs and retained waiting work" });
}

fn foreground(manager: workspace.Manager, items: *std.ArrayList(std.json.Value), incomplete: *bool) !void {
    const alloc = manager.alloc;
    const home = io.getenv("HOME") orelse return;
    const directory = try alloc.print("{s}/.fx/ui-host/{s}", .{ home, try workspace.hash(alloc, try io.realpathAlloc(alloc, ".")) });
    var dir = io.openDirAbsoluteNoFollow(directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io.getIo());
    var iterator = dir.iterate();
    while (try iterator.next(io.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ndjson")) continue;
        var file = try dir.openFile(io.getIo(), entry.name, .{ .mode = .read_write, .follow_symlinks = false });
        defer file.close(io.getIo());
        // Only a currently executing host holds this lock. A crash releases
        // it, preventing abandoned journal entries becoming stale approvals.
        if (try file.tryLock(io.getIo(), .exclusive)) {
            file.unlock(io.getIo());
            continue;
        }
        const raw = io.readFileToEnd(alloc, &file, 8 * 1024 * 1024) catch {
            incomplete.* = true;
            continue;
        };
        var pending: std.AutoHashMap(usize, std.json.Value) = .init(alloc);
        defer pending.deinit();
        var session: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const event = std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{}) catch {
                incomplete.* = true;
                pending.clearRetainingCapacity();
                break;
            };
            const data = model.field(event, "data") orelse event;
            if (std.mem.eql(u8, model.text(data, "type"), "session")) session = model.text(data, "session_id");
            try project(alloc, &pending, event);
        }
        var inputs = pending.iterator();
        const turn = entry.name[0 .. entry.name.len - ".ndjson".len];
        while (inputs.next()) |input| try items.append(alloc, try @import("capabilities.zig").value(alloc, .{
            .id = try alloc.print("{s}:{d}", .{ turn, input.key_ptr.* }),
            .turn = turn,
            .session = session,
            .request_id = input.key_ptr.*,
            .kind = model.text(input.value_ptr.*, "kind"),
            .input = input.value_ptr.*,
            .actionable = true,
        }));
    }
}

pub fn project(alloc: std.mem.Allocator, pending: *std.AutoHashMap(usize, std.json.Value), event: std.json.Value) !void {
    const data = model.field(event, "data") orelse event;
    const kind = model.text(data, "type");
    if (std.mem.eql(u8, kind, "background_outcome") or std.mem.eql(u8, kind, "turn_end")) {
        pending.clearRetainingCapacity();
        return;
    }
    const id = model.field(data, "request_id") orelse return;
    if (id != .integer or id.integer < 0) return;
    const key: usize = @intCast(id.integer);
    if (std.mem.eql(u8, kind, "input_required")) try pending.put(key, try @import("capabilities.zig").value(alloc, data));
    if (std.mem.eql(u8, kind, "input_resolved")) _ = pending.remove(key);
}

test "attention includes only unresolved host inputs and clears terminal turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var pending: std.AutoHashMap(usize, std.json.Value) = .init(alloc);
    defer pending.deinit();
    for ([_][]const u8{ "{\"type\":\"input_required\",\"request_id\":1}", "{\"type\":\"input_required\",\"request_id\":2}", "{\"type\":\"input_resolved\",\"request_id\":1}" }) |raw| try project(alloc, &pending, try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}));
    try std.testing.expectEqual(@as(usize, 1), pending.count());
    try std.testing.expect(pending.contains(2));
    try project(alloc, &pending, try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"type\":\"turn_end\"}", .{}));
    try std.testing.expectEqual(@as(usize, 0), pending.count());
}
