const std = @import("std");
const context_limits = @import("../config/context_limits.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const McpTool = @import("catalog_state.zig").McpTool;
const Allocator = std.mem.Allocator;
const encodeScalarAlloc = model_context_encoding.scalarAlloc;

pub const AlwaysLoadedTools = struct {
    tools: []tool_mcp_runtime.SelectedTool,
    /// Owned context notice naming tools the schema budget left unloaded.
    notice: ?[]u8 = null,

    pub fn deinit(self: *AlwaysLoadedTools, alloc: Allocator) void {
        tool_mcp_runtime.freeSelectedTools(alloc, self.tools);
        if (self.notice) |notice| alloc.free(notice);
        self.* = undefined;
    }
};

/// Always-loaded tools share one `mcp_selected_schema_bytes` budget, in the
/// order they are added. Once one doesn't fit, it and every later one are
/// only counted, and stay reachable through capability_search.
pub const AlwaysLoaded = struct {
    selected: std.ArrayList(tool_mcp_runtime.SelectedTool) = .empty,
    remaining: usize,
    omitted: usize = 0,

    pub fn init(limits: context_limits.Values) AlwaysLoaded {
        return .{ .remaining = limits.mcp_selected_schema_bytes.effectiveBytes() };
    }

    pub fn deinit(b: *AlwaysLoaded, alloc: Allocator) void {
        tool_mcp_runtime.freeSelectedTools(alloc, b.selected.items);
        b.* = undefined;
    }

    pub fn add(
        b: *AlwaysLoaded,
        alloc: Allocator,
        tool: McpTool,
        server_instructions: ?[]const u8,
        binding: tool_mcp_runtime.Binding,
        limits: context_limits.Values,
    ) !void {
        if (b.omitted > 0) {
            b.omitted += 1;
            return;
        }
        var projection = try project(alloc, tool, server_instructions, limits);
        const payload = switch (projection) {
            .selected, .rejected => |value| value,
        };
        if (projection == .rejected or payload.model_output.len > b.remaining) {
            b.omitted += 1;
            projection.deinit(alloc);
            return;
        }
        if (payload.notice) |notice| alloc.free(notice);
        errdefer alloc.free(payload.model_output);
        const name = try alloc.dupe(u8, tool.prefixed_name);
        errdefer alloc.free(name);
        try b.selected.append(alloc, .{ .name = name, .schema_json = payload.model_output, .mcp_binding = binding });
        b.remaining -= payload.model_output.len;
    }

    /// Hands the tools over, with a notice when the budget left any out.
    pub fn finish(b: *AlwaysLoaded, alloc: Allocator) !AlwaysLoadedTools {
        const notice = if (b.omitted > 0) try alloc.print(
            "[context] {d} always-loaded MCP tool{s} could not load complete schemas within the context limits and stay discoverable through capability_search",
            .{ b.omitted, if (b.omitted == 1) "" else "s" },
        ) else null;
        errdefer if (notice) |value| alloc.free(value);
        return .{ .tools = try b.selected.toOwnedSlice(alloc), .notice = notice };
    }
};

pub fn project(alloc: Allocator, tool: McpTool, server_instructions: ?[]const u8, limits: context_limits.Values) !tool_mcp_runtime.ToolSchemaResult {
    const instruction_limit = limits.mcp_server_instructions_bytes;
    const observed = if (server_instructions) |value| value.len else 0;
    // A selected tool must carry complete usage instructions. Discovery owns
    // previews; execution either receives the complete schema or a rejection.
    if (observed > instruction_limit.effectiveBytes())
        return reject(alloc, tool.prefixed_name, observed, instruction_limit, "mcp_server_instructions_bytes");
    const encoded_description = try encodeScalarAlloc(alloc, tool.description);
    defer alloc.free(encoded_description);
    const encoded_instructions = if (server_instructions) |text| try encodeScalarAlloc(alloc, text) else null;
    defer if (encoded_instructions) |text| alloc.free(text);
    const description = if (encoded_instructions) |text|
        try alloc.print("{s}\n\nServer instructions: {s}", .{ encoded_description, text })
    else
        try alloc.dupe(u8, encoded_description);
    defer alloc.free(description);
    const schema = try model_tool_schema.dynamicFunctionSchemaJsonAlloc(alloc, tool.prefixed_name, description, tool.input_schema_json);
    const limit = limits.mcp_selected_schema_bytes;
    if (schema.len > limit.effectiveBytes()) {
        defer alloc.free(schema);
        return reject(alloc, tool.prefixed_name, schema.len, limit, "mcp_selected_schema_bytes");
    }
    return .{ .selected = .{ .model_output = schema, .notice = null } };
}

fn reject(alloc: Allocator, name: []const u8, observed: usize, limit: context_limits.Resolved, limit_name: []const u8) !tool_mcp_runtime.ToolSchemaResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"context_limit_rejection\":{{\"name\":\"{s}\",\"tool\":", .{limit_name});
    try model_context_encoding.writeJsonScalar(alloc, &out.writer, name);
    try out.writer.print(",\"action\":\"rejected\",\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":\"{s}\",\"override\":\"--context-limit {s}=BYTES|off\",\"reason\":\"Complete tool instructions must fit before this tool can be selected; no partial executable schema was loaded.\"}}}}", .{ observed, limit.effectiveBytes(), limit.source.label(), limit_name });
    const output = try out.toOwnedSlice();
    errdefer alloc.free(output);
    return .{ .rejected = .{ .model_output = output, .notice = try renderSchemaNotice(alloc, name, "rejected (complete instructions required)", observed, limit, limit_name) } };
}

fn renderSchemaNotice(
    alloc: Allocator,
    tool_name: []const u8,
    action: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    limit_name: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("[context] MCP schema \"");
    try model_context_encoding.writeScalar(&out.writer, tool_name);
    try out.writer.print(
        "\" {s}: observed={d} bytes effective={d} bytes source={s}; override with --context-limit {s}=BYTES|off",
        .{ action, observed_bytes, limit.effectiveBytes(), limit.source.label(), limit_name },
    );
    return try out.toOwnedSlice();
}

test "MCP always-loaded tools report instruction rejections instead of disappearing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var limits: context_limits.Values = .{};
    limits.mcp_server_instructions_bytes = .{ .value = .{ .bytes = 4 }, .source = .user_workspace };
    var loaded = AlwaysLoaded.init(limits);
    const tool: McpTool = .{
        .original_name = "echo",
        .prefixed_name = try alloc.dupe(u8, "mcp_fixture_echo"),
        .description = try alloc.dupe(u8, "Echo"),
        .input_schema_json = try alloc.dupe(u8, "{}"),
        .tags = &.{},
    };
    try loaded.add(alloc, tool, "Complete instructions", undefined, limits);
    var result = try loaded.finish(alloc);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.tools.len);
    try std.testing.expect(result.notice != null);
}
