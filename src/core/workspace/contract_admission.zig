//! Resolve conversational references before creating execution state. Selection
//! is durable workspace data; classifiers interpret intent, never prove outcomes.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const channels = @import("contract_channels.zig");
const classification = @import("classification.zig");
const model = @import("definition.zig");
const types = @import("../shared/types.zig");

pub const Admission = struct {
    response: ?[]const u8 = null,
    task: ?[]const u8 = null,
    continuing: bool = false,
    new_goal: ?[]const u8 = null,
    independent: bool = false,
    unresolved_task: ?[]const u8 = null,
    lookup_task: ?[]const u8 = null,
};
const Focus = struct { kind: []const u8 = "contract_selection", task: ?[]const u8, pending: bool = false };
const Intent = channels.Intent;

fn focusKey(manager: workspace.Manager, session: []const u8) ![]const u8 {
    return manager.alloc.print("selection-{s}", .{try workspace.hash(manager.alloc, session)});
}
fn saveFocus(manager: workspace.Manager, session: []const u8, task: ?[]const u8, pending: bool) !void {
    const id = try focusKey(manager, session);
    const raw = try manager.communication(id);
    const bytes = try std.json.Stringify.valueAlloc(manager.alloc, Focus{ .task = task, .pending = pending }, .{});
    if (raw) |previous| if (std.mem.eql(u8, previous, bytes)) return;
    try manager.saveCommunications(&.{.{ .key = id, .expected = if (raw) |previous| try workspace.hash(manager.alloc, previous) else null, .content = bytes }});
}
fn sameRequest(a: []const u8, b: []const u8) bool {
    var left = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var right = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (left.next()) |word| if (!std.ascii.eqlIgnoreCase(word, right.next() orelse return false)) return false;
    return right.next() == null;
}

pub fn resolve(manager: workspace.Manager, session: []const u8, message: []const u8, history: []const types.ChatMessage, cancel: *std.atomic.Value(bool)) !Admission {
    const active = try manager.active(session);
    const raw = try manager.communication(try focusKey(manager, session));
    const focus = if (raw) |bytes| try std.json.parseFromSliceLeaky(Focus, manager.alloc, bytes, .{}) else Focus{ .task = null };
    var selected: ?workspace.Task = null;
    var duplicate = false;
    var matches: usize = 0;
    // Explicit IDs and exact repeated objectives do not require inference.
    // Multiple matches are genuinely ambiguous, even if one is more recent.
    for (try manager.tasks()) |task| {
        if (task.authority != null or task.parent_task_id != null) continue;
        const exact = sameRequest(message, task.definition.objective);
        if (!exact and std.mem.find(u8, message, task.id) == null) continue;
        selected = task;
        duplicate = exact;
        matches += 1;
    }
    if (matches > 1) {
        try saveFocus(manager, session, null, true);
        return .{ .response = "Several retained contracts match that request. Specify the contract ID to continue, or explicitly request a separate new task." };
    }
    if (selected == null) {
        if (focus.task) |id| selected = try manager.loadTask(id) else selected = active;
    }
    // An assistant's reference is context only. The current user's intent must
    // still explicitly request resume/amend before any state change is made.
    if (selected == null and history.len > 0) {
        var index = history.len;
        while (index > 0) {
            index -= 1;
            if (history[index].role != .assistant) continue;
            const text = history[index].content orelse break;
            for (try manager.tasks()) |task| {
                if (task.authority != null or task.parent_task_id != null or std.mem.find(u8, text, task.id) == null) continue;
                selected = task;
                matches += 1;
            }
            if (matches > 1) return .{ .response = "The previous answer mentioned several contracts. Specify which contract you want to continue." };
            break;
        }
    }
    if (selected == null and focus.pending) return .{ .response = "Several contracts were in scope. Specify a contract ID, or use /task new to start separate work." };
    const task = selected orelse return .{};
    if (task.authority != null or task.parent_task_id != null) return .{};
    if (duplicate) {
        try saveFocus(manager, session, task.id, true);
        const state = try channels.status(manager, task);
        return .{ .response = try manager.alloc.print("This request already has contract {s}.\n{s}\nYou can continue this contract, ask for its status, change its requirements, or explicitly start separate work.", .{ task.id, model.text(state, "text") }) };
    }
    const continuing = std.ascii.eqlIgnoreCase(std.mem.trim(u8, message, " \t\r\n"), "continue");
    const choice: Intent = if (continuing) .@"resume" else if (classification.configured()) try channels.interpretIntent(manager, task, message, cancel) else return .{};
    if (choice == .clarify) return .{ .unresolved_task = task.id };
    return apply(manager, session, message, task.id, choice);
}

pub fn apply(manager: workspace.Manager, session: []const u8, message: []const u8, id: []const u8, choice: Intent) !Admission {
    const task = try manager.loadTask(id);
    if (task.authority != null or task.parent_task_id != null) return error.CompanyExecutionIsolationRequired;
    switch (choice) {
        .unrelated => {
            try saveFocus(manager, session, null, false);
            return .{ .independent = true };
        },
        .clarify => {
            // Do not turn an uncertain reference into a new execution contract.
            try saveFocus(manager, session, task.id, true);
            return .{ .response = try manager.alloc.print("For contract {s}, do you want its status, to continue it, to change its requirements, or to start separate work?", .{task.id}) };
        },
        .status => {
            try saveFocus(manager, session, task.id, false);
            return .{ .lookup_task = task.id };
        },
        .new => {
            try saveFocus(manager, session, null, false);
            return .{ .new_goal = try manager.alloc.print("Create a separate contract. Previous objective for reference: {s}\nCurrent user instruction: {s}", .{ task.definition.objective, message }) };
        },
        .@"resume", .amend => {},
    }
    try saveFocus(manager, session, task.id, false);
    if (task.state == .accepted and !try manager.publicationPending(task)) return .{ .response = try manager.alloc.print("Contract {s} is already completed. Ask for its results or explicitly request a separate task.", .{task.id}) };
    if (try manager.backgroundRecord(task.id)) |worker| {
        if (choice == .@"resume" and (worker.state == .queued or worker.state == .starting or worker.state == .running)) return .{ .response = try manager.alloc.print("Contract {s} is already {s}; no duplicate worker was started. This state does not establish completed outcomes.", .{ task.id, @tagName(worker.state) }) };
        const request: @import("background_api.zig").Request = .{
            .action = if (choice == .@"resume") .@"resume" else .steer,
            .task = task.id,
            .generation = worker.generation,
            .operation = try workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, .{ session, task.id, worker.generation, choice, message }, .{})),
            .text = if (choice == .amend) message else "",
        };
        _ = @import("background_api.zig").execute(manager, request) catch |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            return .{ .response = try manager.alloc.print("Contract {s} was retained, but the requested transition could not be applied ({s}). No replacement contract was created.", .{ task.id, @errorName(err) }) };
        };
        return .{ .response = try manager.alloc.print("{s} existing contract {s}. Its completed work and evidence are retained; no replacement contract was created.", .{ if (choice == .@"resume") "Resumed" else "Sent your update to", task.id }) };
    }
    return .{ .task = task.id, .continuing = choice == .@"resume" };
}

test "contract request matching ignores whitespace but not changed requirements" {
    try std.testing.expect(sameRequest("  Save a\npreference ", "save a preference"));
    try std.testing.expect(!sameRequest("save a different preference", "save a preference"));
    try std.testing.expect(!sameRequest("save a preference and continue", "save a preference"));
}
