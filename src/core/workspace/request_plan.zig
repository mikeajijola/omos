//! Select a host contract template without decomposing the authenticated request.
//! This selection neither grants tool access nor establishes task completion.
const std = @import("std");
const classification = @import("classification.zig");

pub const Capability = enum { general_task, coding_task };

pub const question: classification.Question = .{
    .id = "capability",
    .required = false,
    .instructions = "Classify the requested deliverable, not the tools that might implement it. coding_task means changing software implementation or behavior, delivering reusable executable software, or changing runtime configuration. general_task means operational work, using applications or websites, retrieving information, analysing records, or producing documents and structured data. Temporary scripts and saving JSON or CSV for operational work do not make it coding. Choose unresolved for an ambiguous deliverable. This selection does not grant permissions or prove completion.",
    .choices = &.{
        .{ .label = "general_task", .description = "Operational, browser, information, document or data work without a software deliverable." },
        .{ .label = "coding_task", .description = "Implement or change software behavior, executable software or runtime configuration." },
        .{ .label = "unresolved", .description = "The requested deliverable or its context is ambiguous." },
    },
};

pub fn select(result: classification.Result) ?Capability {
    if (result.truncated) return null;
    for (result.decisions) |decision| {
        if (!std.mem.eql(u8, decision.question, question.id)) continue;
        const capability = std.meta.stringToEnum(Capability, decision.choice) orelse return null;
        var chosen: f64 = 0;
        var alternative: f64 = 0;
        for (decision.probabilities) |score| {
            if (std.mem.eql(u8, score.label, decision.choice)) chosen = score.probability else alternative = @max(alternative, score.probability);
        }
        return if (decision.confidence >= 0.85 and chosen >= 0.85 and chosen - alternative >= 0.5) capability else null;
    }
    return null;
}

pub const Facts = struct {
    has_plan: bool,
    revision_pending: bool,
    amendments: usize,
    scoped: bool,
    request_matches: bool,
};

pub fn eligible(facts: Facts) bool {
    return !facts.has_plan and !facts.revision_pending and facts.amendments == 0 and !facts.scoped and facts.request_matches;
}

test "request contract template requires a complete confident offered capability" {
    const scores = [_]classification.Probability{ .{ .label = "general_task", .probability = 0.97 }, .{ .label = "coding_task", .probability = 0.02 }, .{ .label = "unresolved", .probability = 0.01 } };
    var decision: classification.Decision = .{ .question = "capability", .choice = "general_task", .confidence = 0.97, .probabilities = &scores };
    var result: classification.Result = .{ .model = "fixture", .elapsed_ms = 1, .decisions = (&decision)[0..1] };
    try std.testing.expectEqual(Capability.general_task, select(result).?);
    result.truncated = true;
    try std.testing.expect(select(result) == null);
    result.truncated = false;
    decision.confidence = 0.6;
    try std.testing.expect(select(result) == null);
    decision.confidence = 0.99;
    decision.choice = "invented";
    try std.testing.expect(select(result) == null);
    decision.choice = "coding_task";
    try std.testing.expect(select(result) == null);
    decision.probabilities = &.{ .{ .label = "coding_task", .probability = 0.97 }, .{ .label = "general_task", .probability = 0.02 }, .{ .label = "unresolved", .probability = 0.01 } };
    try std.testing.expectEqual(Capability.coding_task, select(result).?);
    result.decisions = &.{};
    try std.testing.expect(select(result) == null);
}

test "request contract template cannot replace retained scoped or amended work" {
    const fresh: Facts = .{ .has_plan = false, .revision_pending = false, .amendments = 0, .scoped = false, .request_matches = true };
    try std.testing.expect(eligible(fresh));
    inline for (.{ "has_plan", "revision_pending", "scoped" }) |name| {
        var changed = fresh;
        @field(changed, name) = true;
        try std.testing.expect(!eligible(changed));
    }
    var changed = fresh;
    changed.amendments = 1;
    try std.testing.expect(!eligible(changed));
    changed = fresh;
    changed.request_matches = false;
    try std.testing.expect(!eligible(changed));
}
