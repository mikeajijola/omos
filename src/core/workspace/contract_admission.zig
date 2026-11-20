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
/// durable contract. Carries optional specialist metadata when present on the
/// persisted contract; matching a candidate never grants tool permissions.
pub const RecyclableCandidate = struct {
    id: []const u8,
    objective: []const u8,
    scope: []const u8,
    completed: bool = false,
    isolated: bool = false,
    capability_id: ?[]const u8 = null,
    realisation_id: ?[]const u8 = null,
    required_tools: []const []const u8 = &.{},
    skill_bindings: []const []const u8 = &.{},

    pub fn fromTask(task: workspace.Task) RecyclableCandidate {
        return .{
            .id = task.id,
            .objective = task.definition.objective,
            .scope = task.project_root,
            .completed = task.state == .accepted or task.state == .publication_pending or task.state == .conflict,
            .isolated = task.authority != null or task.parent_task_id != null,
            .capability_id = if (task.model_basis) |basis| basis.capability else null,
            .realisation_id = task.definition.realisation_id,
            .required_tools = task.definition.required_tools,
            .skill_bindings = task.definition.skill_bindings,
        };
    }
};

pub const RecycleRequest = struct {
    capability_id: ?[]const u8 = null,
    realisation_id: ?[]const u8 = null,
};

fn trimmedNonEmpty(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn effectiveCapability(capability_id: ?[]const u8, realisation_id: ?[]const u8) ?[]const u8 {
    if (trimmedNonEmpty(realisation_id)) |real| {
        if (std.mem.startsWith(u8, real, "job_application")) return "job_application";
        if (std.mem.startsWith(u8, real, "coding_task")) return "coding_task";
    }
    if (trimmedNonEmpty(capability_id)) |cap| return cap;
    if (trimmedNonEmpty(realisation_id)) |real| {
        if (std.mem.startsWith(u8, real, "general_task")) return "general_task";
    }
    return null;
}

/// Generic host realisations (`general_task_native`, `coding_task_native`) cover
/// arbitrary unrelated requests unless they carry explicit specialist bindings,
/// so they still require `sameRequest`. Dedicated specialist realisations (such
/// as `job_application_browser`) represent a concrete workflow recipe and can
/// be recycled for compatible specialist requests in the same scope.
pub fn isSpecialistRealisation(realisation_id: ?[]const u8, candidate: ?RecyclableCandidate) bool {
    if (candidate) |cand| {
        if (cand.required_tools.len > 0 or cand.skill_bindings.len > 0) return true;
    }
    const id = trimmedNonEmpty(realisation_id) orelse return false;
    return !std.mem.eql(u8, id, "general_task_native") and
        !std.mem.eql(u8, id, "coding_task_native");
}

/// Pure decision: choose an existing active/pending contract in the same scope
/// with compatible specialist realisation or identical request intent, so a new
/// goal resumes it instead of duplicating it. Mismatched specialist realisations
/// are never cross-recycled, and legacy contracts with `realisation_id == null`
/// fall back to `sameRequest`. Returns null when a genuinely new contract is warranted.
pub fn chooseRecyclableContract(
    message: []const u8,
    scope: []const u8,
    exclude_id: []const u8,
    candidates: []const RecyclableCandidate,
    request: RecycleRequest,
) ?[]const u8 {
    if (isConversationalGreeting(message)) return null;
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return null;

    const req_realisation = trimmedNonEmpty(request.realisation_id);
    const req_capability = effectiveCapability(request.capability_id, req_realisation);

    var best_id: ?[]const u8 = null;
    var best_rank: u8 = 0;

    for (candidates) |candidate| {
        if (candidate.completed or candidate.isolated) continue;
        if (std.mem.eql(u8, candidate.id, exclude_id)) continue;
        if (scope.len > 0 and !std.mem.eql(u8, candidate.scope, scope)) continue;

        const cand_realisation = trimmedNonEmpty(candidate.realisation_id);
        const cand_capability = effectiveCapability(candidate.capability_id, cand_realisation);

        // Never cross-recycle mismatched specialist realisations or capabilities.
        if (req_realisation != null and cand_realisation != null and
            !std.mem.eql(u8, req_realisation.?, cand_realisation.?))
        {
            continue;
        }
        if (req_capability != null and cand_capability != null and
            !std.mem.eql(u8, req_capability.?, cand_capability.?))
        {
            continue;
        }

        const exact_request = sameRequest(message, candidate.objective);
        const realisation_matches = req_realisation != null and cand_realisation != null and
            std.mem.eql(u8, req_realisation.?, cand_realisation.?);
        const capability_matches = req_capability != null and cand_capability != null and
            std.mem.eql(u8, req_capability.?, cand_capability.?);

        const rank: u8 = if (realisation_matches and exact_request)
            4
        else if (realisation_matches and isSpecialistRealisation(cand_realisation, candidate))
            3
        else if (req_realisation == null and capability_matches and isSpecialistRealisation(cand_realisation, candidate))
            2
        else if (exact_request and (req_realisation == null or cand_realisation == null or realisation_matches))
            1
        else
            0;

        if (rank > best_rank) {
            best_rank = rank;
            best_id = candidate.id;
            if (rank == 4) break;
        }
    }
    return best_id;
}

/// Scan retained contracts using an already-resolved assignment so callers do
/// not recompute capability selection.
pub fn findRecyclableContractWithAssignment(
    manager: workspace.Manager,
    exclude_id: []const u8,
    message: []const u8,
    scope: []const u8,
    assignment: ?@import("realisation_selection.zig").Assignment,
) !?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var reader = manager;
    reader.alloc = scratch.allocator();
    const candidates = try reader.recyclableCandidates();
    const request: RecycleRequest = if (assignment) |assigned| .{
        .capability_id = assigned.capability,
        .realisation_id = assigned.realisation,
    } else .{};
    const chosen = chooseRecyclableContract(message, scope, exclude_id, candidates, request) orelse return null;
    return try manager.alloc.dupe(u8, chosen);
}

/// Scan retained contracts for one that can be resumed instead of creating a
/// second durable contract for identical or matching specialist work.
pub fn findRecyclableContract(
    manager: workspace.Manager,
    exclude_id: []const u8,
    message: []const u8,
    scope: []const u8,
) !?[]const u8 {
    const selection = @import("realisation_selection.zig");
    const assignment = selection.assignGoalForManager(
        manager.alloc,
        manager,
        message,
        null,
        null,
        scope,
        &.{},
    ) catch null;
    return findRecyclableContractWithAssignment(manager, exclude_id, message, scope, assignment);
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
    try std.testing.expectEqualStrings("task-old", chooseRecyclableContract("  Save a\npreference ", "/repo", "task-current", &candidates, .{}).?);
    // The contract that raised the new goal is never recycled into itself.
    try std.testing.expect(chooseRecyclableContract("save a preference", "/repo", "task-old", &candidates, .{}) == null);
}

test "new goal stays new when the matching contract is completed isolated or out of scope" {
    const base = RecyclableCandidate{ .id = "task-1", .objective = "save a preference", .scope = "/repo" };
    var completed = base;
    completed.completed = true;
    var isolated = base;
    isolated.isolated = true;
    try std.testing.expect(chooseRecyclableContract("save a preference", "/repo", "", &.{completed}, .{}) == null);
    try std.testing.expect(chooseRecyclableContract("save a preference", "/repo", "", &.{isolated}, .{}) == null);
    try std.testing.expect(chooseRecyclableContract("save a preference", "/other", "", &.{base}, .{}) == null);
    try std.testing.expect(chooseRecyclableContract("save a different preference", "/repo", "", &.{base}, .{}) == null);
    try std.testing.expect(chooseRecyclableContract("build a new feature", "/repo", "", &.{base}, .{}) == null);
}

test "chooseRecyclableContract recycles matching specialist realisation rejects mismatches and falls back for legacy null realisation" {
    const legacy_candidate = RecyclableCandidate{
        .id = "task-legacy",
        .objective = "Apply to outside IR35 roles on LinkedIn",
        .scope = "/Users/example/project",
        .realisation_id = null,
    };
    const specialist_candidate = RecyclableCandidate{
        .id = "task-job-specialist",
        .objective = "Apply to outside IR35 roles on LinkedIn",
        .scope = "/Users/example/project",
        .capability_id = "job_application",
        .realisation_id = "job_application_browser",
        .required_tools = &.{ "shell", "read_file", "write_file", "mcp_browseros-neo_run" },
        .skill_bindings = &.{"browseros-neo"},
    };
    const coding_candidate = RecyclableCandidate{
        .id = "task-coding",
        .objective = "Apply to outside IR35 roles on LinkedIn",
        .scope = "/Users/example/project",
        .capability_id = "coding_task",
        .realisation_id = "coding_task_native",
    };

    // 1. Matching realisation_id recycles the specialist candidate (and prefers it over legacy).
    const mixed = [_]RecyclableCandidate{ legacy_candidate, coding_candidate, specialist_candidate };
    try std.testing.expectEqualStrings(
        "task-job-specialist",
        chooseRecyclableContract(
            "Apply to outside IR35 roles on LinkedIn",
            "/Users/example/project",
            "task-other",
            &mixed,
            .{ .capability_id = "job_application", .realisation_id = "job_application_browser" },
        ).?,
    );

    // Compatible second job_application request in the same scope recycles the active specialist contract.
    try std.testing.expectEqualStrings(
        "task-job-specialist",
        chooseRecyclableContract(
            "Submit job applications for UK contract roles via LinkedIn Easy Apply",
            "/Users/example/project",
            "task-other",
            &.{specialist_candidate},
            .{ .capability_id = "job_application", .realisation_id = "job_application_browser" },
        ).?,
    );

    // 2. Mismatched realisation_id is never cross-recycled, even if the objective text matches.
    try std.testing.expect(
        chooseRecyclableContract(
            "Apply to outside IR35 roles on LinkedIn",
            "/Users/example/project",
            "task-other",
            &.{specialist_candidate},
            .{ .capability_id = "coding_task", .realisation_id = "coding_task_native" },
        ) == null,
    );
    try std.testing.expect(
        chooseRecyclableContract(
            "Apply to outside IR35 roles on LinkedIn",
            "/Users/example/project",
            "task-other",
            &.{coding_candidate},
            .{ .capability_id = "job_application", .realisation_id = "job_application_browser" },
        ) == null,
    );

    // Unrelated generic coding/general tasks with different objectives never cross-recycle.
    const generic_coding = RecyclableCandidate{
        .id = "task-coding-a",
        .objective = "Refactor src/a.zig",
        .scope = "/Users/example/project",
        .capability_id = "coding_task",
        .realisation_id = "coding_task_native",
    };
    try std.testing.expect(
        chooseRecyclableContract(
            "Refactor src/b.zig",
            "/Users/example/project",
            "task-other",
            &.{generic_coding},
            .{ .capability_id = "coding_task", .realisation_id = "coding_task_native" },
        ) == null,
    );

    // 3. Legacy candidate with null realisation_id falls back cleanly to sameRequest.
    try std.testing.expectEqualStrings(
        "task-legacy",
        chooseRecyclableContract(
            "  apply to outside IR35 roles\non LinkedIn ",
            "/Users/example/project",
            "task-other",
            &.{legacy_candidate},
            .{ .capability_id = "job_application", .realisation_id = "job_application_browser" },
        ).?,
    );
    try std.testing.expect(
        chooseRecyclableContract(
            "Submit a different application campaign",
            "/Users/example/project",
            "task-other",
            &.{legacy_candidate},
            .{ .capability_id = "job_application", .realisation_id = "job_application_browser" },
        ) == null,
    );

    // 4. Specialist candidate whose planner basis recorded general_task still recycles via specialist realisation_id.
    var fallback_basis_candidate = specialist_candidate;
    fallback_basis_candidate.id = "task-specialist-fallback-basis";
    fallback_basis_candidate.capability_id = "general_task";
    try std.testing.expectEqualStrings(
        "task-specialist-fallback-basis",
        chooseRecyclableContract(
            "Submit a second batch of UK contract applications via LinkedIn Easy Apply",
            "/Users/example/project",
            "task-other",
            &.{fallback_basis_candidate},
            .{ .capability_id = "job_application", .realisation_id = "job_application_browser" },
        ).?,
    );
}
