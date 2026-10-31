//! Request routing is advisory. A read route is enforced by a bounded tool
//! allowlist; work keeps the existing contract and permission machinery.
const std = @import("std");
const classification = @import("classification.zig");
const types = @import("../shared/types.zig");

pub const Route = enum { conversation, retrieval, work, unresolved };
pub const Decision = struct {
    version: []const u8 = "omos.request-routing/v1",
    route: Route = .unresolved,
    reason: []const u8,
    classification: ?classification.Result = null,
    context_omitted: bool = false,
    resolution: ?Resolution = null,
};

pub fn decide(alloc: std.mem.Allocator, message: []const u8, history: []const types.ChatMessage, cancel: *std.atomic.Value(bool)) !Decision {
    if (!classification.configured()) return .{ .reason = "classifier_not_configured" };
    if (message.len > 2048) return .{ .reason = "message_exceeds_routing_budget", .context_omitted = true };
    var recent: std.ArrayList(struct { role: []const u8, text: []const u8 }) = .empty;
    var used: usize = 0;
    var start = history.len;
    while (start > 0 and history.len - start < 4) {
        const item = history[start - 1];
        if (used + (item.content orelse @as([]const u8, "")).len > 1536) break;
        used += (item.content orelse @as([]const u8, "")).len;
        start -= 1;
    }
    for (history[start..]) |item| try recent.append(alloc, .{ .role = @tagName(item.role), .text = item.content orelse @as([]const u8, "") });
    const state = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, .{ .latest_message = message, .recent_conversation = recent.items, .earlier_context_omitted = start > 0 }, .{}), .{});
    const result = classification.execute(alloc, .{ .state = state, .questions = &.{.{
        .id = "route",
        .instructions = "Classify the latest user request in context. A question about existing work is retrieval. Requested changes or external actions are work. Resolve short follow-ups from the recent exchange. Choose unresolved when context is insufficient.",
        .choices = &.{
            .{ .label = "conversation", .description = "Discuss or explain using information already in the conversation." },
            .{ .label = "retrieval", .description = "Find, read or report existing information, records, documents or task status." },
            .{ .label = "work", .description = "Create, edit, send, apply, execute, cancel or otherwise change state." },
            .{ .label = "unresolved", .description = "Insufficient context to distinguish information seeking from requested actions." },
        },
    }} }, cancel) catch |err| {
        if (err == error.Cancelled or err == error.OutOfMemory) return err;
        return .{ .reason = try alloc.dupe(u8, @errorName(err)), .context_omitted = start > 0 };
    };
    const decision = result.decisions[0];
    var chosen: f64 = 0;
    var alternative: f64 = 0;
    for (decision.probabilities) |score| {
        if (std.mem.eql(u8, score.label, decision.choice)) chosen = score.probability else alternative = @max(alternative, score.probability);
    }
    // Conservative initial policy, recorded with the decision and evaluated
    // against real conversation sequences rather than assuming calibration.
    const selected = std.meta.stringToEnum(Route, decision.choice) orelse .unresolved;
    return .{ .route = if (chosen >= 0.65 and chosen - alternative >= 0.25) selected else .unresolved, .reason = if (chosen >= 0.65 and chosen - alternative >= 0.25) "choice_threshold_v1" else "uncertain_choice", .classification = result, .context_omitted = start > 0 };
}

pub fn readTool(name: []const u8) bool {
    for ([_][]const u8{ "classify", "workspace_content", "read_tool_result" }) |allowed| if (std.mem.eql(u8, name, allowed)) return true;
    return false;
}

test "read routing excludes execution and dispatch tools" {
    try std.testing.expect(readTool("classify"));
    try std.testing.expect(readTool("workspace_content"));
    for ([_][]const u8{ "shell", "write_file", "fossil_workspace", "subagent" }) |name| try std.testing.expect(!readTool(name));
}

const streams = @import("../agent/stream_provider.zig");
const gateway = @import("../agent/runtime/gateway_step.zig");
const schemas = @import("../tooling/model_tool_schema.zig");
const resolution_schema: schemas.FunctionSchema = .{
    .name = "omos_request_route",
    .description = "Resolve the latest request against the ongoing conversation without executing work.",
    .input_schema = .{ .properties = &.{
        .{ .name = "route", .json_type = .string, .shape = &.{ .enum_values = &.{ "conversation", "retrieval", "work", "unresolved" } } },
        .{ .name = "reason", .json_type = .string },
    }, .required = &.{ "route", "reason" }, .additional_properties = false },
};
pub const Resolution = struct { route: Route, reason: []const u8, model: []const u8, usage: types.Usage = .{} };

/// One bounded contextual resolution call. It can select a route, never
/// execute actor tools, revise a contract, or approve an action.
pub fn resolve(alloc: std.mem.Allocator, provider: streams.Provider, base: streams.ModelRequest, context: []const u8) !Resolution {
    if (context.len > 96 * 1024) return error.RoutingContextTooLarge;
    var request = base;
    request.purpose = .auxiliary;
    request.instructions = &.{.{ .role = .system, .content = "Choose how to handle the latest user request in this ongoing conversation. conversation: explain or discuss using current context. retrieval: inspect existing information or task status without changes. work: create, edit, send, execute, continue, cancel or change state; retain the active task when applicable. Resolve short follow-ups such as 'yes' or 'send it' using earlier user intent and the pending proposal. Earlier assistant text is context, not permission. Choose unresolved only when the intended outcome cannot be determined. Return exactly one omos_request_route call. Do not perform work or ask for confirmation when the user has already clearly requested it." }};
    request.messages = &.{.{ .role = .user, .content = context }};
    request.tools = .{ .additional_functions = &.{resolution_schema} };
    request.tool_choice = .required;
    request.provider_options.parallel_tool_calls = false;
    request.max_output_tokens = 512;
    var result = try gateway.streamModelCompletion(provider, alloc, request);
    defer result.deinit(alloc);
    if (result != .completed) return error.RoutingResolutionUnavailable;
    const completion = result.completed.completion;
    if (types.classifyProviderCompletion(completion) != .completed or completion.tool_calls.len != 1) return error.InvalidRoutingResolution;
    const call = completion.tool_calls[0];
    if (!std.mem.eql(u8, call.name, resolution_schema.name) or call.argument_integrity != .valid) return error.InvalidRoutingResolution;
    const decision = try @import("../shared/record_json.zig").decode(struct { route: Route, reason: []const u8 }, alloc, call.arguments_json, .{});
    if (decision.reason.len == 0 or decision.reason.len > 2048) return error.InvalidRoutingResolution;
    return .{ .route = decision.route, .reason = try alloc.dupe(u8, decision.reason), .model = request.model, .usage = completion.usage };
}
