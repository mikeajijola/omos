//! Config-gated decision-model tool selection.
//!
//! Unlike the earlier run/granular prototype, this asks the bound decision
//! model (winnow) to choose a concrete tool from the candidate tool list that
//! `capability_search` would surface. The answer is strictly advisory: a tool
//! can only be selected when it is already advertised/allowed for this turn,
//! so this module never grants a permission. A rejected or weak answer keeps
//! the existing BM25/rerank behaviour untouched.
const std = @import("std");
const io = @import("../shared/io.zig");
const classification = @import("classification.zig");
const capabilities = @import("capabilities.zig");
const lexical = @import("../shared/lexical_relevance.zig");

pub const flag = "OMOS_TOOL_SELECT";
pub const min_confidence: f64 = 0.65;
pub const min_margin: f64 = 0.25;
pub const max_choices: usize = 28; // + none_unsure stays under the 32-choice cap
pub const max_description_bytes: usize = 600; // 29 * 600 stays under the 32KB body cap
pub const none_label = "none_unsure";

pub const Candidate = struct {
    name: []const u8,
    description: []const u8,
};

/// Browser tools a `capability_search` would surface. They join the already
/// advertised tool set as candidates, but the allowance check still rejects
/// any that are not callable this turn.
pub const browser_candidates = [_]Candidate{
    .{ .name = "mcp_browseros-neo_run", .description = "Run one batched browser script: open pages, read them, batch independent tabs with Promise.all and extract structured results." },
    .{ .name = "mcp_browseros-neo_tabs", .description = "List, open, activate or close browser tabs." },
    .{ .name = "mcp_browseros-neo_navigate", .description = "Navigate a browser tab to a URL." },
    .{ .name = "mcp_browseros-neo_snapshot", .description = "Capture the accessibility snapshot of a browser page." },
    .{ .name = "mcp_browseros-neo_act", .description = "Click, fill, select or otherwise act on browser page elements." },
    .{ .name = "mcp_browseros-neo_read", .description = "Extract readable text and links from a browser page." },
    .{ .name = "mcp_browseros-neo_grep", .description = "Search browser page content for a pattern." },
};

/// The flag is off by default, so nothing changes unless explicitly enabled.
pub fn enabled() bool {
    const value = io.getenv(flag) orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

pub const Tally = struct {
    top: usize,
    top_probability: f64,
    runner_probability: f64,
};

/// Argmax over the returned distribution plus its closest competitor. A
/// distribution needs at least two labels to have a meaningful margin.
pub fn tally(probabilities: []const classification.Probability) ?Tally {
    if (probabilities.len < 2) return null;
    var top: usize = 0;
    for (probabilities, 0..) |entry, index| {
        if (entry.probability > probabilities[top].probability) top = index;
    }
    var runner: usize = if (top == 0) 1 else 0;
    for (probabilities, 0..) |entry, index| {
        if (index == top) continue;
        if (entry.probability > probabilities[runner].probability) runner = index;
    }
    return .{
        .top = top,
        .top_probability = probabilities[top].probability,
        .runner_probability = probabilities[runner].probability,
    };
}

fn isAllowed(label: []const u8, allowed: []const []const u8) bool {
    for (allowed) |name| if (std.mem.eql(u8, name, label)) return true;
    return false;
}

/// Pure acceptance rule. The confidence test uses the winning label's
/// probability (the same convention the prototype used), the margin is the
/// gap to the runner-up, `none_unsure` is always a fallback, and the label
/// must be in the caller's already-allowed tool set. Returns the accepted
/// tool name or null when the answer must fall back to BM25/rerank.
pub fn accept(decision: classification.Decision, allowed: []const []const u8) ?[]const u8 {
    const result = tally(decision.probabilities) orelse return null;
    const label = decision.probabilities[result.top].label;
    if (std.mem.eql(u8, label, none_label)) return null;
    if (!std.math.isFinite(result.top_probability) or result.top_probability < min_confidence) return null;
    if (!std.math.isFinite(result.runner_probability)) return null;
    if (result.top_probability - result.runner_probability < min_margin) return null;
    if (!isAllowed(label, allowed)) return null;
    return label;
}

fn truncatedDescription(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len <= max_description_bytes) return try alloc.dupe(u8, text);
    const marker = "...";
    const prefix = max_description_bytes - marker.len;
    var out = try alloc.alloc(u8, max_description_bytes);
    @memcpy(out[0..prefix], text[0..prefix]);
    @memcpy(out[prefix..], marker);
    return out;
}

const Scored = struct {
    candidate: Candidate,
    score: lexical.Score,
};

fn scoreLess(_: void, a: Scored, b: Scored) bool {
    return switch (lexical.order(a.score, b.score)) {
        .lt => false,
        .gt => true,
        .eq => false,
    };
}

/// Lexically rank the capability-search candidates against the request and
/// keep the strongest `max` distinct tools. This is the same lexical signal
/// the BM25/rerank path uses, so the model sees the most relevant tools first.
pub fn rank(alloc: std.mem.Allocator, prompt: []const u8, candidates: []const Candidate, max: usize) ![]Candidate {
    const query_text = if (prompt.len > lexical.max_query_bytes) prompt[0..lexical.max_query_bytes] else prompt;
    const prepared = lexical.prepare(query_text) catch lexical.prepare("") catch return &.{};
    var scored: std.ArrayList(Scored) = .empty;
    errdefer scored.deinit(alloc);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);
    for (candidates) |candidate| {
        if (candidate.name.len == 0) continue;
        var duplicate = false;
        for (seen.items) |name| {
            if (std.mem.eql(u8, name, candidate.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try seen.append(alloc, candidate.name);
        const score = lexical.score(&prepared, &.{candidate.name}, &.{candidate.name}, &.{candidate.description}) orelse lexical.Score{};
        try scored.append(alloc, .{ .candidate = candidate, .score = score });
    }
    std.mem.sort(Scored, scored.items, {}, scoreLess);
    const count = @min(max, scored.items.len);
    var out = try alloc.alloc(Candidate, count);
    for (0..count) |index| out[index] = scored.items[index].candidate;
    return out;
}

/// Ask the decision model to pick one tool. Gated on OMOS_TOOL_SELECT and a
/// bound classifier. Returns an accepted tool name only when it is already in
/// `allowed`; every error, weak answer or disallowed label falls back to null.
pub fn select(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    recent_context: []const []const u8,
    candidates: []const Candidate,
    allowed: []const []const u8,
) ?[]const u8 {
    if (!enabled() or !classification.configured()) return null;
    const ranked = rank(alloc, prompt, candidates, max_choices) catch return null;
    if (ranked.len == 0) return null;

    var choices: std.ArrayList(classification.Choice) = .empty;
    defer choices.deinit(alloc);
    for (ranked) |candidate| {
        const description = truncatedDescription(alloc, candidate.description) catch return null;
        choices.append(alloc, .{ .label = candidate.name, .description = description }) catch return null;
    }
    choices.append(alloc, .{
        .label = none_label,
        .description = "None of the listed tools clearly fits this request; keep the existing tool selection.",
    }) catch return null;

    const state = capabilities.value(alloc, .{
        .message = prompt,
        .recent_context = recent_context,
    }) catch return null;
    const instructions = "Choose exactly one tool from the criteria that best fits the FIRST step of this user request. Choose none_unsure when no listed tool clearly fits. This choice is advisory and grants no permission.";
    const result = classification.execute(alloc, .{
        .state = state,
        .questions = &.{.{
            .id = "tool_selection",
            .instructions = instructions,
            .choices = choices.items,
        }},
    }, null) catch return null;
    if (result.truncated or result.decisions.len != 1) return null;
    return accept(result.decisions[0], allowed);
}

/// Convenience wrapper for call sites that already hold parallel name and
/// description arrays for the advertised plus always-loaded tool set.
pub fn selectFirst(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    names: []const []const u8,
    descriptions: []const []const u8,
    allowed: []const []const u8,
) ?[]const u8 {
    if (names.len != descriptions.len) return null;
    const candidates = alloc.alloc(Candidate, names.len) catch return null;
    for (names, descriptions, candidates) |name, description, *slot| {
        slot.* = .{ .name = name, .description = description };
    }
    return select(alloc, prompt, &.{}, candidates, allowed);
}

fn decisionFor(label: []const u8, probs: []const classification.Probability) classification.Decision {
    return .{ .question = "tool_selection", .choice = label, .confidence = 0.9, .probabilities = probs };
}

test "tool_selection tally finds the argmax and its runner-up including ties" {
    const probs = [_]classification.Probability{
        .{ .label = "a", .probability = 0.2 },
        .{ .label = "b", .probability = 0.8 },
        .{ .label = "c", .probability = 0.0 },
    };
    const t = tally(&probs).?;
    try std.testing.expectEqual(@as(usize, 1), t.top);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), t.top_probability, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), t.runner_probability, 0.0001);
    try std.testing.expect(tally(probs[0..1]) == null);
}

test "tool_selection accept applies confidence and margin thresholds" {
    const allowed = [_][]const u8{ "mcp_browseros-neo_run", "capability_search" };
    const confident = [_]classification.Probability{
        .{ .label = "mcp_browseros-neo_run", .probability = 0.9 },
        .{ .label = "capability_search", .probability = 0.1 },
    };
    try std.testing.expectEqualStrings("mcp_browseros-neo_run", accept(decisionFor("mcp_browseros-neo_run", &confident), &allowed).?);

    const low_confidence = [_]classification.Probability{
        .{ .label = "mcp_browseros-neo_run", .probability = 0.6 },
        .{ .label = "capability_search", .probability = 0.4 },
    };
    try std.testing.expect(accept(decisionFor("mcp_browseros-neo_run", &low_confidence), &allowed) == null);

    const narrow_margin = [_]classification.Probability{
        .{ .label = "mcp_browseros-neo_run", .probability = 0.7 },
        .{ .label = "capability_search", .probability = 0.6 },
    };
    try std.testing.expect(accept(decisionFor("mcp_browseros-neo_run", &narrow_margin), &allowed) == null);
}

test "tool_selection accept rejects none_unsure and disallowed tools" {
    const allowed = [_][]const u8{"mcp_browseros-neo_run"};
    const unsure = [_]classification.Probability{
        .{ .label = none_label, .probability = 0.95 },
        .{ .label = "mcp_browseros-neo_run", .probability = 0.05 },
    };
    try std.testing.expect(accept(decisionFor(none_label, &unsure), &allowed) == null);

    const disallowed = [_]classification.Probability{
        .{ .label = "mcp_browseros-neo_tabs", .probability = 0.95 },
        .{ .label = "mcp_browseros-neo_run", .probability = 0.05 },
    };
    try std.testing.expect(accept(decisionFor("mcp_browseros-neo_tabs", &disallowed), &allowed) == null);
}

test "tool_selection rank orders by prompt relevance and caps the candidate count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const candidates = [_]Candidate{
        .{ .name = "calendar", .description = "Manage events" },
        .{ .name = "mcp_browseros-neo_run", .description = "Run one batched browser script to open pages and extract headings" },
        .{ .name = "mcp_browseros-neo_tabs", .description = "List browser tabs" },
    };
    const ranked = try rank(alloc, "open pages and extract headings in the browser", &candidates, 2);
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqualStrings("mcp_browseros-neo_run", ranked[0].name);
}
