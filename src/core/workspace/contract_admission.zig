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
pub fn isConversationalGreeting(message: []const u8) bool {
    const trimmed = std.mem.trim(u8, message, " \t\r\n!?.");
    for ([_][]const u8{
        "hi",
        "hello",
        "hey",
        "hi there",
        "hello there",
        "hey there",
        "good morning",
        "good afternoon",
        "good evening",
        "how are you",
        "thanks",
        "thank you",
    }) |greeting| {
        if (std.ascii.eqlIgnoreCase(trimmed, greeting)) return true;
    }
    return false;
}

fn sameRequest(a: []const u8, b: []const u8) bool {
    if (isConversationalGreeting(a)) return false;
    var left = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var right = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (left.next()) |word| if (!std.ascii.eqlIgnoreCase(word, right.next() orelse return false)) return false;
    return right.next() == null;
}

/// A retained contract considered for recycling rather than minting a duplicate
/// durable contract.
pub const RecyclableCandidate = struct {
    id: []const u8,
    objective: []const u8,
    scope: []const u8,
    completed: bool = false,
    isolated: bool = false,
};

/// Pure decision: choose an existing active/pending contract in the same scope
/// with the same intent, so a new goal resumes it instead of duplicating it.
/// Returns null when a genuinely new contract is warranted.
pub fn chooseRecyclableContract(
    message: []const u8,
    scope: []const u8,
    exclude_id: []const u8,
    candidates: []const RecyclableCandidate,
) ?[]const u8 {
    for (candidates) |candidate| {
        if (candidate.completed or candidate.isolated) continue;
        if (std.mem.eql(u8, candidate.id, exclude_id)) continue;
        if (scope.len > 0 and !std.mem.eql(u8, candidate.scope, scope)) continue;
        if (!sameRequest(message, candidate.objective)) continue;
        return candidate.id;
    }
    return null;
}

/// Scan retained contracts for one that can be resumed instead of creating a
/// second durable contract for identical work.
pub fn findRecyclableContract(
    manager: workspace.Manager,
    exclude_id: []const u8,
    message: []const u8,
    scope: []const u8,
) !?[]const u8 {
    var candidates: std.ArrayList(RecyclableCandidate) = .empty;
    defer candidates.deinit(manager.alloc);
    for (try manager.tasks()) |task| {
        try candidates.append(manager.alloc, .{
            .id = task.id,
            .objective = task.definition.objective,
            .scope = task.project_root,
            .completed = task.state == .accepted,
            .isolated = task.authority != null or task.parent_task_id != null,
        });
    }
    return chooseRecyclableContract(message, scope, exclude_id, candidates.items);
}

pub fn resolve(manager: workspace.Manager, session: []const u8, message: []const u8, history: []const types.ChatMessage, cancel: *std.atomic.Value(bool)) !Admission {
    const active = try manager.active(session);
    const raw = try manager.communication(try focusKey(manager, session));
    const focus = if (raw) |bytes| try std.json.parseFromSliceLeaky(Focus, manager.alloc, bytes, .{}) else Focus{ .task = null };
    if (isConversationalGreeting(message)) {
        if (focus.pending) try saveFocus(manager, session, null, false);
        return .{};
    }
    var selected: ?workspace.Task = null;
    var duplicate = false;
    var matches: usize = 0;
    var choices: std.ArrayList(u8) = .empty;
    // Explicit IDs and exact repeated objectives do not require inference.
    // Multiple matches are genuinely ambiguous, even if one is more recent.
    for (try manager.tasks()) |task| {
        if (task.authority != null or task.parent_task_id != null) continue;
        const exact = sameRequest(message, task.definition.objective);
        if (!exact and std.mem.find(u8, message, task.id) == null) continue;
        selected = task;
        duplicate = exact;
        matches += 1;
        if (matches <= 8) try choices.appendSlice(manager.alloc, try manager.alloc.print("\n{s} ({s})", .{ task.id, @tagName(task.state) }));
    }
    if (duplicate and classification.configured()) {
        const routed = @import("request_routing.zig").decide(manager.alloc, message, history, cancel) catch null;
        if (routed) |decision| {
            if (decision.route == .conversation or decision.route == .retrieval) {
                selected = null;
                duplicate = false;
                matches = 0;
                choices.clearRetainingCapacity();
                if (focus.pending) try saveFocus(manager, session, null, false);
                return .{};
            }
        }
    }
    if (matches > 1) {
        try saveFocus(manager, session, null, true);
        return .{ .response = try manager.alloc.print("Several retained contracts match that request:{s}\nSpecify a contract ID to continue. Use /task new to start separate work.{s}", .{ choices.items, if (matches > 8) " More matches are available in the contract list." else "" }) };
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
            if (matches > 1) {
                if (classification.configured()) {
                    if (@import("request_routing.zig").decide(manager.alloc, message, history, cancel) catch null) |decision| {
                        if (decision.route == .conversation or decision.route == .retrieval) {
                            if (focus.pending) try saveFocus(manager, session, null, false);
                            return .{};
                        }
                    }
                }
                return .{ .response = "The previous answer mentioned several contracts. Specify which contract you want to continue." };
            }
            break;
        }
    }
    if (selected == null and focus.pending) {
        if (classification.configured()) {
            if (@import("request_routing.zig").decide(manager.alloc, message, history, cancel) catch null) |decision| {
                if (decision.route == .conversation or decision.route == .retrieval) {
                    try saveFocus(manager, session, null, false);
                    return .{};
                }
            }
        }
        return .{ .response = "Several contracts were in scope. Specify a contract ID, or use /task new to start separate work." };
    }
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
            // A request that asks for "separate work" must not mint a duplicate
            // durable contract when an active/pending contract for the same
            // scope and intent already exists. Recycle it instead of creating
            // a second long-lived contract for identical work.
            if (try findRecyclableContract(manager, task.id, message, task.project_root)) |recyclable| {
                try saveFocus(manager, session, recyclable, false);
                return .{ .task = recyclable, .continuing = true };
            }
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

test "new goal resumes an active contract with the same scope and intent" {
    const candidates = [_]RecyclableCandidate{
        .{ .id = "task-old", .objective = "save a preference", .scope = "/repo" },
    };
    try std.testing.expectEqualStrings("task-old", chooseRecyclableContract("  Save a\npreference ", "/repo", "task-current", &candidates).?);
    // The contract that raised the new goal is never recycled into itself.
    try std.testing.expect(chooseRecyclableContract("save a preference", "/repo", "task-old", &candidates) == null);
}

test "new goal stays new when the matching contract is completed isolated or out of scope" {
    const base = RecyclableCandidate{ .id = "task-1", .objective = "save a preference", .scope = "/repo" };
    var completed = base;
    completed.completed = true;
    var isolated = base;
    isolated.isolated = true;
    try std.testing.expect(chooseRecyclableContract("save a preference", "/repo", "", &.{completed}) == null);
    try std.testing.expect(chooseRecyclableContract("save a preference", "/repo", "", &.{isolated}) == null);
    try std.testing.expect(chooseRecyclableContract("save a preference", "/other", "", &.{base}) == null);
    try std.testing.expect(chooseRecyclableContract("save a different preference", "/repo", "", &.{base}) == null);
    try std.testing.expect(chooseRecyclableContract("build a new feature", "/repo", "", &.{base}) == null);
}
