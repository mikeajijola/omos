//! Config-gated prototype: ask the Ollaya/Jev decision model which browser
//! tool family should make the first call, instead of relying solely on BM25
//! retrieval plus the browser-first rerank. The decision is advisory: it never
//! grants permission and the existing retrieval path stays as the fallback.
const std = @import("std");
const classification = @import("classification.zig");
const io = @import("../shared/io.zig");

/// What the prototype decided for the first browser call. `unsure` and
/// `fallback` both mean "keep the existing rerank behaviour unchanged".
pub const Selection = enum { run, granular, unsure, fallback };

pub const enabled_flag = "OMOS_DECISION_TOOL_SELECT";
pub const threshold_flag = "OMOS_DECISION_TOOL_SELECT_THRESHOLD";
pub const default_threshold: f64 = 0.65;

/// Browser capabilities described to the decision model. The prototype uses a
/// static list so no catalog plumbing is needed; the real value is the choice.
pub const browser_capabilities = [_][]const u8{
    "run",          "tabs",       "navigate", "snapshot", "act",              "read", "grep",
    "name_session", "screenshot", "pdf",      "upload",   "evaluate_in_page",
};

/// The flag is off by default, so nothing changes unless explicitly enabled.
pub fn enabled() bool {
    const value = io.getenv(enabled_flag) orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn threshold() f64 {
    const raw = io.getenv(threshold_flag) orelse return default_threshold;
    const parsed = std.fmt.parseFloat(f64, raw) catch return default_threshold;
    if (!std.math.isFinite(parsed) or parsed < 0 or parsed > 1) return default_threshold;
    return parsed;
}

/// Pure choice-to-first-call mapping. A low probability or an unknown label is
/// `unsure`, which callers treat as "keep the existing rerank behaviour".
pub fn mapChoice(choice: []const u8, probability: f64, min_probability: f64) Selection {
    if (!std.math.isFinite(probability) or probability < min_probability) return .unsure;
    if (std.mem.eql(u8, choice, "run")) return .run;
    if (std.mem.eql(u8, choice, "granular")) return .granular;
    return .unsure;
}

/// Map one decision record. Uses the probability of the winning label rather
/// than the record confidence alone, so a weak winner is not honoured.
pub fn mapDecision(decision: classification.Decision, min_probability: f64) Selection {
    var probability = decision.confidence;
    for (decision.probabilities) |entry| {
        if (std.mem.eql(u8, entry.label, decision.choice)) {
            probability = entry.probability;
            break;
        }
    }
    return mapChoice(decision.choice, probability, min_probability);
}

/// Choose which first-call guidance to emit. Only a confident `granular`
/// decision changes behaviour; every other selection keeps run-first guidance.
pub fn firstCallGuidance(selection: Selection, run_guidance: []const u8, granular_guidance: []const u8) []const u8 {
    return if (selection == .granular) granular_guidance else run_guidance;
}

fn decideGated(alloc: std.mem.Allocator, prompt: []const u8, capabilities: []const []const u8, gate: bool) Selection {
    if (!gate or !classification.configured()) return .fallback;
    const state = @import("capabilities.zig").value(alloc, .{
        .prompt = prompt,
        .browser_capabilities = capabilities,
    }) catch return .fallback;
    const choices = [_]classification.Choice{
        .{ .label = "run", .description = "Prefer one batched mcp_browseros-neo_run script as the first browser step." },
        .{ .label = "granular", .description = "Allow capability_search and one-off browser tools (tabs, navigate, snapshot, act, read, grep) as the first step." },
        .{ .label = "unsure", .description = "No first browser step clearly fits this request." },
    };
    const result = classification.execute(alloc, .{
        .state = state,
        .questions = &.{.{
            .id = "browser_tool_selection",
            .instructions = "Choose the first browser step for this user request. Choose run when one batched mcp_browseros-neo_run script is the best fit. Choose granular when one-off tools discovered via capability_search are the better fit. Choose unsure when neither clearly fits. This choice is advisory and grants no permission.",
            .choices = &choices,
        }},
    }, null) catch return .fallback;
    if (result.truncated or result.decisions.len != 1) return .fallback;
    return mapDecision(result.decisions[0], threshold());
}

/// Public entry point. Gated on the flag AND a bound browser skill, so an
/// unbound or unconfigured setup keeps the existing behaviour untouched.
pub fn decide(alloc: std.mem.Allocator, prompt: []const u8, capabilities: []const []const u8, browser_skill_bound: bool) Selection {
    return decideGated(alloc, prompt, capabilities, enabled() and browser_skill_bound);
}

test "mapChoice honours confident run and granular, downgrades weak and unknown answers" {
    try std.testing.expectEqual(Selection.run, mapChoice("run", 0.9, 0.65));
    try std.testing.expectEqual(Selection.granular, mapChoice("granular", 0.8, 0.65));
    try std.testing.expectEqual(Selection.unsure, mapChoice("run", 0.5, 0.65));
    try std.testing.expectEqual(Selection.unsure, mapChoice("unsure", 0.99, 0.65));
    try std.testing.expectEqual(Selection.unsure, mapChoice("other", 0.99, 0.65));
    try std.testing.expectEqual(Selection.unsure, mapChoice("run", std.math.nan(f64), 0.65));
}

test "mapDecision uses the winning label probability not just confidence" {
    const weak = [_]classification.Probability{
        .{ .label = "run", .probability = 0.55 },
        .{ .label = "granular", .probability = 0.40 },
        .{ .label = "unsure", .probability = 0.05 },
    };
    const weak_decision: classification.Decision = .{ .question = "browser_tool_selection", .choice = "run", .confidence = 0.9, .probabilities = &weak };
    try std.testing.expectEqual(Selection.unsure, mapDecision(weak_decision, 0.65));

    const strong = [_]classification.Probability{
        .{ .label = "run", .probability = 0.10 },
        .{ .label = "granular", .probability = 0.92 },
        .{ .label = "unsure", .probability = 0.08 },
    };
    const strong_decision: classification.Decision = .{ .question = "browser_tool_selection", .choice = "granular", .confidence = 0.92, .probabilities = &strong };
    try std.testing.expectEqual(Selection.granular, mapDecision(strong_decision, 0.65));
}

test "decision tool select falls back when gated off and maps guidance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = decideGated(arena.allocator(), "Apply via LinkedIn Easy Apply", &browser_capabilities, false);
    try std.testing.expectEqual(Selection.fallback, selection);
    // Fallback and unsure both keep run-first guidance; only granular changes it.
    try std.testing.expectEqualStrings("run", firstCallGuidance(selection, "run", "granular"));
    try std.testing.expectEqualStrings("run", firstCallGuidance(.unsure, "run", "granular"));
    try std.testing.expectEqualStrings("granular", firstCallGuidance(.granular, "run", "granular"));
}
