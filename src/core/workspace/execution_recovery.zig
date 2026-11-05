//! A projection of retained action evidence, never permission to replay effects.
const std = @import("std");
const model = @import("definition.zig");
const workspace = @import("fossil_workspace.zig");

const Outcome = enum { unresolved, succeeded, failed };
const Action = struct { id: []const u8, tool: []const u8 = "", outcome: Outcome = .unresolved };
const Ledger = struct {
    actions: std.StringHashMapUnmanaged(Action) = .empty,

    fn observe(self: *Ledger, alloc: std.mem.Allocator, kind: []const u8, value: std.json.Value) !void {
        if (std.mem.eql(u8, kind, "action_intent")) {
            for (model.items(value, "calls")) |call| {
                const id = model.text(call, "execution_id");
                if (id.len == 0) continue;
                const slot = try self.actions.getOrPut(alloc, try alloc.dupe(u8, id));
                if (!slot.found_existing) slot.value_ptr.* = .{ .id = slot.key_ptr.*, .tool = try alloc.dupe(u8, model.text(call, "name")) };
            }
        } else if (std.mem.eql(u8, kind, "tool_evidence") and value == .array) {
            for (value.array.items) |record| {
                const id = model.text(record, "action_id");
                if (id.len == 0) continue;
                const status = model.text(record, "status");
                const outcome: Outcome = if (std.mem.eql(u8, status, "success")) .succeeded else if (std.mem.eql(u8, status, "failure")) .failed else .unresolved;
                const slot = try self.actions.getOrPut(alloc, try alloc.dupe(u8, id));
                if (!slot.found_existing) slot.value_ptr.* = .{ .id = slot.key_ptr.*, .tool = try alloc.dupe(u8, model.text(record, "tool")), .outcome = outcome } else {
                    // Conflicting observations require inspection, not guessing.
                    if (slot.value_ptr.outcome != .unresolved and slot.value_ptr.outcome != outcome) return error.ConflictingExecutionEvidence;
                    slot.value_ptr.outcome = outcome;
                }
            }
        }
    }
};

pub fn context(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    var reader = manager;
    reader.alloc = alloc;
    var ledger: Ledger = .{};
    var history = try reader.historyCursor(task, try reader.currentRevision(task));
    while (history.offset < history.paths.len) {
        var batch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer batch_arena.deinit();
        const batch = (try history.next(batch_arena.allocator())) orelse break;
        for (batch) |bytes| {
            const row = try std.json.parseFromSliceLeaky(std.json.Value, batch_arena.allocator(), bytes, .{});
            if (!std.mem.eql(u8, model.text(row, "task"), task.id)) return error.InvalidWorkspaceJournal;
            try ledger.observe(alloc, model.text(row, "kind"), model.field(row, "value") orelse continue);
        }
    }
    if (ledger.actions.count() == 0) return "";
    var succeeded: usize = 0;
    var failed: usize = 0;
    var unresolved: usize = 0;
    var pending: std.ArrayList(Action) = .empty;
    var completed: std.ArrayList(Action) = .empty;
    var failures: std.ArrayList(Action) = .empty;
    var it = ledger.actions.valueIterator();
    while (it.next()) |action| switch (action.outcome) {
        .succeeded => {
            succeeded += 1;
            if (completed.items.len < 16) try completed.append(alloc, action.*);
        },
        .failed => {
            failed += 1;
            if (failures.items.len < 16) try failures.append(alloc, action.*);
        },
        .unresolved => {
            unresolved += 1;
            if (pending.items.len < 16) try pending.append(alloc, action.*);
        },
    };
    return manager.alloc.print("Retained execution summary (host observations, not contract completion): {s}\nReuse retained successful results when still applicable. Failed tool calls can still have external effects. Inspect unresolved or failed external actions before retrying; this summary does not authorize replay. Retrieve full action evidence from task history when needed. Counts describe tool executions, not completed user outcomes.", .{try std.json.Stringify.valueAlloc(alloc, .{ .task = task.id, .successful_tool_results = succeeded, .failed_tool_results = failed, .unresolved_intents = unresolved, .successful = completed.items, .failed = failures.items, .omitted_successful = succeeded - completed.items.len, .omitted_failed = failed - failures.items.len, .unresolved = pending.items, .omitted_unresolved = unresolved - pending.items.len }, .{})});
}

test "execution recovery joins results before intents and never infers missing success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ledger: Ledger = .{};
    try ledger.observe(a, "tool_evidence", try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"action_id\":\"one\",\"tool\":\"submit\",\"status\":\"success\"}]", .{}));
    try ledger.observe(a, "action_intent", try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"calls\":[{\"execution_id\":\"one\",\"name\":\"submit\"},{\"execution_id\":\"two\",\"name\":\"submit\"}]}", .{}));
    try std.testing.expectEqual(Outcome.succeeded, ledger.actions.get("one").?.outcome);
    try std.testing.expectEqual(Outcome.unresolved, ledger.actions.get("two").?.outcome);
    try std.testing.expectEqual(@as(usize, 2), ledger.actions.count());
}
