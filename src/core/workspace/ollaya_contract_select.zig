//! Config-gated capability selection: ask the winnow decision model to pick the
//! contract capability/realisation instead of the deterministic keyword rules in
//! realisation_selection.classifyDeliverable. job_application is a first-class
//! declared capability in omos.json; retrieval and no_contract are extra options
//! that intentionally fall back to the deterministic path.
//!
//! Enable with OMOS_CONTRACT_SELECT=ollaya. The legacy
//! OMOS_OLLAYA_CONTRACT_SELECT=1 flag remains accepted as an alias. The
//! typed-decision endpoint is configured as for any other classifier call, e.g.
//!   OMOS_CLASSIFIER_URL=http://10.80.0.10:11435/v1/systemone
//! The decision model is pinned here to winnow:e4b regardless of global config.
const std = @import("std");
const classification = @import("classification.zig");
const request_plan = @import("request_plan.zig");
const definition = @import("definition.zig");
const io = @import("../shared/io.zig");

pub const flag = "OMOS_CONTRACT_SELECT";
pub const flag_value = "ollaya";
pub const legacy_flag = "OMOS_OLLAYA_CONTRACT_SELECT";
pub const model_name = "winnow:e4b";
pub const question_id = "capability";
pub const instructions = "Which capability best fits this request?";
pub const confidence_threshold: f64 = 0.5;

/// Extra candidate options that are not declared capabilities. They are offered
/// to the model but deliberately not mapped to a request_plan capability, so
/// choosing one exercises the fallback path.
const candidate_options = [_]classification.Choice{
    .{ .label = "retrieval", .description = "Retrieve or look up information, answer questions about stored records or data." },
    .{ .label = "no_contract", .description = "A trivial conversational question that needs no durable capability or contract." },
};

pub const Trace = struct {
    attempted: bool = false,
    choice: []const u8 = "",
    confidence: f64 = 0,
    mapped: ?request_plan.Capability = null,
    fallback: bool = false,
};

pub fn gateEnabled(value: ?[]const u8, legacy: ?[]const u8) bool {
    if (value) |v| return std.mem.eql(u8, v, flag_value);
    if (legacy) |v| return std.mem.eql(u8, v, "1");
    return false;
}

pub fn enabled() bool {
    return gateEnabled(io.getenv(flag), io.getenv(legacy_flag));
}

/// Map an offered choice to a request_plan capability. Only capabilities and
/// realisations declared in omos.json are valid; everything else falls back.
/// job_application and its realisation are first-class choices.
pub fn mapChoice(choice: []const u8) ?request_plan.Capability {
    if (std.mem.eql(u8, choice, "general_task") or std.mem.eql(u8, choice, "general_task_native")) return .general_task;
    if (std.mem.eql(u8, choice, "coding_task") or std.mem.eql(u8, choice, "coding_task_native")) return .coding_task;
    if (std.mem.eql(u8, choice, "job_application") or std.mem.eql(u8, choice, "job_application_browser")) return .job_application;
    return null;
}

/// Confidence/validity gate applied to the model's top decision. Null means the
/// caller must fall back to the deterministic classifier.
pub fn acceptedCapability(decision: classification.Decision) ?request_plan.Capability {
    if (decision.confidence < confidence_threshold) return null;
    return mapChoice(decision.choice);
}

/// Build one typed choice question whose options are the capabilities and
/// realisations declared in omos.json plus the experiment candidates. Criteria
/// are each realisation's name and its capability's description.
pub fn buildQuestion(alloc: std.mem.Allocator, declaration: definition.Declaration) !classification.Question {
    var choices: std.ArrayList(classification.Choice) = .empty;
    errdefer choices.deinit(alloc);

    const spec = definition.spec(declaration.value);
    const capabilities = definition.items(spec, "capabilities");
    for (capabilities) |capability| {
        const id = definition.text(capability, "id");
        const name = definition.text(capability, "name");
        const description = definition.text(capability, "description");
        const criteria = try alloc.print("{s}: {s}", .{ name, description });
        try choices.append(alloc, .{ .label = id, .description = criteria });
    }
    const realisations = definition.items(spec, "realisations");
    for (realisations) |realisation| {
        const id = definition.text(realisation, "id");
        const name = definition.text(realisation, "name");
        const capability_id = definition.text(realisation, "capability");
        var description: []const u8 = "";
        for (capabilities) |capability| {
            if (std.mem.eql(u8, definition.text(capability, "id"), capability_id)) {
                description = definition.text(capability, "description");
                break;
            }
        }
        const criteria = try alloc.print("{s}: {s}", .{ name, description });
        try choices.append(alloc, .{ .label = id, .description = criteria });
    }
    for (candidate_options) |candidate| try choices.append(alloc, candidate);

    return .{
        .id = question_id,
        .instructions = instructions,
        .choices = try choices.toOwnedSlice(alloc),
        .required = true,
    };
}

/// Ask the decision model once and apply the gate. Returns null when disabled,
/// on any transport/parse error, or when the top choice is invalid or below the
/// confidence threshold; the caller then uses the deterministic classifier.
pub fn select(alloc: std.mem.Allocator, prompt: []const u8, cancel: ?*std.atomic.Value(bool), trace: ?*Trace) !?request_plan.Capability {
    if (!enabled()) return null;
    if (trace) |t| t.attempted = true;

    const declaration = try definition.parse(alloc, definition.seed);
    const question = try buildQuestion(alloc, declaration);
    const request: classification.Request = .{ .state = .{ .string = prompt }, .questions = (&question)[0..1] };
    const result = classification.executeWithModel(alloc, request, cancel, model_name) catch return null;
    if (result.truncated) {
        if (trace) |t| t.fallback = true;
        return null;
    }
    var decision: ?classification.Decision = null;
    for (result.decisions) |d| {
        if (std.mem.eql(u8, d.question, question_id)) {
            decision = d;
            break;
        }
    }
    const top = decision orelse {
        if (trace) |t| t.fallback = true;
        return null;
    };
    const capability = acceptedCapability(top);
    if (trace) |t| {
        t.choice = top.choice;
        t.confidence = top.confidence;
        t.mapped = capability;
        t.fallback = capability == null;
    }
    std.debug.print("[ollaya-contract-select] choice={s} confidence={d:.4} mapped={s}\n", .{
        top.choice,
        top.confidence,
        if (capability) |cap| @tagName(cap) else "fallback",
    });
    return capability;
}

test "ollaya gate accepts new value and legacy alias" {
    try std.testing.expect(!gateEnabled(null, null));
    try std.testing.expect(gateEnabled("ollaya", null));
    try std.testing.expect(!gateEnabled("1", null));
    try std.testing.expect(gateEnabled(null, "1"));
    try std.testing.expect(!gateEnabled(null, "ollaya"));
    try std.testing.expect(!gateEnabled("other", "1"));
}

test "ollaya mapChoice maps declared capabilities and realisations" {
    try std.testing.expectEqual(request_plan.Capability.general_task, mapChoice("general_task").?);
    try std.testing.expectEqual(request_plan.Capability.general_task, mapChoice("general_task_native").?);
    try std.testing.expectEqual(request_plan.Capability.coding_task, mapChoice("coding_task").?);
    try std.testing.expectEqual(request_plan.Capability.coding_task, mapChoice("coding_task_native").?);
    try std.testing.expectEqual(request_plan.Capability.job_application, mapChoice("job_application").?);
    try std.testing.expectEqual(request_plan.Capability.job_application, mapChoice("job_application_browser").?);
    inline for (.{ "retrieval", "no_contract", "invented", "" }) |label| {
        try std.testing.expect(mapChoice(label) == null);
    }
}

test "ollaya acceptedCapability applies confidence threshold and falls back" {
    try std.testing.expectEqual(
        request_plan.Capability.general_task,
        acceptedCapability(.{ .question = question_id, .choice = "general_task", .confidence = 0.9451, .probabilities = &.{} }).?,
    );
    // First-class job capability maps above the threshold.
    try std.testing.expectEqual(
        request_plan.Capability.job_application,
        acceptedCapability(.{ .question = question_id, .choice = "job_application", .confidence = 0.9451, .probabilities = &.{} }).?,
    );
    // Low confidence falls back even for a valid choice.
    try std.testing.expect(acceptedCapability(.{ .question = question_id, .choice = "coding_task", .confidence = 0.49, .probabilities = &.{} }) == null);
    // High confidence but invalid candidate falls back.
    try std.testing.expect(acceptedCapability(.{ .question = question_id, .choice = "retrieval", .confidence = 0.9451, .probabilities = &.{} }) == null);
    // Realisation label maps back to its capability.
    try std.testing.expectEqual(
        request_plan.Capability.coding_task,
        acceptedCapability(.{ .question = question_id, .choice = "coding_task_native", .confidence = 0.9471, .probabilities = &.{} }).?,
    );
    try std.testing.expectEqual(
        request_plan.Capability.job_application,
        acceptedCapability(.{ .question = question_id, .choice = "job_application_browser", .confidence = 0.9471, .probabilities = &.{} }).?,
    );
}

test "ollaya buildQuestion offers omos.json capabilities, realisations and candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const declaration = try definition.parse(alloc, definition.seed);
    const q = try buildQuestion(alloc, declaration);
    try std.testing.expectEqualStrings("Which capability best fits this request?", q.instructions);
    try std.testing.expect(q.choices.len >= 7);
    var names = std.StringHashMap(void).init(alloc);
    defer names.deinit();
    for (q.choices) |choice| {
        try names.put(choice.label, {});
        try std.testing.expect(choice.description.len > 0);
    }
    inline for (.{ "general_task", "coding_task", "general_task_native", "coding_task_native", "job_application", "retrieval", "no_contract" }) |label| {
        try std.testing.expect(names.contains(label));
    }
}
