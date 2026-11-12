//! Optional managed-task canonical MCP evidence and actor-only projection.
//! A durable companion is the eligibility marker; missing companions preserve
//! existing preview behavior. Captured outputs never authorize tool execution.
const std = @import("std");
const canonical = @import("../tooling/canonical_tool_output.zig");
const projection = @import("../mcp/result_projection.zig");
const workspace = @import("fossil_workspace.zig");
const types = @import("../shared/types.zig");
const review = @import("../agent/runtime/review_evidence.zig");
const Allocator = std.mem.Allocator;
const cache_budget = 1024 * 1024;
const record_budget = 4096;

const CacheEntry = struct { parsed: std.json.Parsed(canonical.Record), encoded_bytes: usize };

pub const State = struct {
    session: []const u8 = "",
    loaded: bool = false,
    disabled: bool = false,
    cached_bytes: usize = 0,
    cache: std.ArrayList(CacheEntry) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *State) void {
        for (self.cache.items) |*item| item.parsed.deinit();
        self.cache.deinit(std.heap.c_allocator);
        var keys = self.seen.keyIterator();
        while (keys.next()) |key| std.heap.c_allocator.free(key.*);
        self.seen.deinit(std.heap.c_allocator);
        self.* = .{};
    }

    fn remember(self: *State, record: canonical.Record) !void {
        if (self.seen.count() >= record_budget and !self.seen.contains(record.id)) {
            self.disabled = true;
            return error.CanonicalEvidenceBudgetExceeded;
        }
        if (!self.seen.contains(record.id)) {
            const key = try std.heap.c_allocator.dupe(u8, record.id);
            errdefer std.heap.c_allocator.free(key);
            try self.seen.put(std.heap.c_allocator, key, {});
        }
        if (!std.mem.eql(u8, record.binding.session, self.session)) return;
        for (self.cache.items) |entry| if (std.mem.eql(u8, entry.parsed.value.id, record.id)) return;
        const encoded = try std.json.Stringify.valueAlloc(std.heap.c_allocator, record, .{});
        defer std.heap.c_allocator.free(encoded);
        // The cache owns the complete binding, including potentially large call
        // arguments. A durable oversized record remains remembered but need not
        // evict useful entries or disable this optional projection for later calls.
        if (encoded.len > cache_budget) return;
        while (self.cache.items.len > 0 and (self.cache.items.len >= 64 or self.cached_bytes + encoded.len > cache_budget)) {
            var removed = self.cache.orderedRemove(0);
            self.cached_bytes -= removed.encoded_bytes;
            removed.parsed.deinit();
        }
        var parsed = try std.json.parseFromSlice(canonical.Record, std.heap.c_allocator, encoded, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try self.cache.append(std.heap.c_allocator, .{ .parsed = parsed, .encoded_bytes = encoded.len });
        self.cached_bytes += encoded.len;
    }

    pub fn load(self: *State, manager: workspace.Manager, task: workspace.Task) !void {
        if (self.loaded or self.disabled) return;
        var lifetime = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer lifetime.deinit();
        var reader = manager;
        reader.alloc = lifetime.allocator();
        const revision = try reader.currentRevision(task);
        var history = try reader.historyCursor(task, revision);
        while (history.offset < history.paths.len) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer scratch.deinit();
            const alloc = scratch.allocator();
            const batch = (try history.next(alloc)) orelse break;
            for (batch) |bytes| {
                const Entry = struct { kind: []const u8, task: []const u8, value: std.json.Value };
                const entry = try std.json.parseFromSliceLeaky(Entry, alloc, bytes, .{ .ignore_unknown_fields = true });
                if (!std.mem.eql(u8, entry.task, task.id)) return error.InvalidWorkspaceJournal;
                if (!std.mem.eql(u8, entry.kind, "canonical_tool_output")) continue;
                const record = try std.json.parseFromValueLeaky(canonical.Record, alloc, entry.value, .{});
                try validateRecord(alloc, task.id, record);
                try self.remember(record);
            }
        }
        self.loaded = true;
    }

    /// Called synchronously after authenticated result storage. Failure is
    /// handled by the runtime as optimization unavailable, never tool failure.
    pub fn capture(self: *State, manager: workspace.Manager, task: workspace.Task, input: canonical.Capture) !void {
        if (self.session.len == 0 or self.disabled) return error.CanonicalEvidenceUnavailable;
        var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const record = try canonical.create(alloc, task.id, self.session, input);
        try self.load(manager, task);
        if (!self.seen.contains(record.id)) {
            var writer = manager;
            writer.alloc = alloc;
            // The immutable content-addressed pending journal is durable even
            // before the next Fossil checkpoint or if that checkpoint fails.
            try writer.recordExact(task, "canonical_tool_output", record);
        }
        try self.remember(record);
    }

    pub fn projectMessages(self: *State, alloc: Allocator, manager: workspace.Manager, task: workspace.Task, source: []const types.ChatMessage, inline_cap: usize) ![]const types.ChatMessage {
        if (self.session.len == 0 or self.disabled) return source;
        var projected: ?[]types.ChatMessage = null;
        var work_bytes: usize = 0;
        for (source, 0..) |message, index| {
            if (message.role != .tool) continue;
            const memory = message.tool_result_memory orelse continue;
            if (!memory.truncated) continue;
            const handle = memory.output_handle orelse continue;
            const call_id = message.tool_call_id orelse continue;
            const status = message.tool_result_status orelse continue;
            if (memory.stored_output_bytes > canonical.max_bytes or work_bytes + memory.stored_output_bytes > cache_budget) continue;
            var producing: ?types.ToolCall = null;
            for (source[0..index]) |previous| for (previous.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, call_id)) producing = call;
            };
            const call = producing orelse continue;
            const preview = memory.preview orelse continue;
            const current_text = message.content orelse continue;
            const ordinary_preview = try @import("../session/result_store.zig").formatStoredResultOutput(alloc, handle, preview, memory.stored_output_bytes);
            // Host image-recovery notices may precede the ordinary preview.
            // Preserve them exactly; unknown changed presentations stay intact.
            if (!std.mem.endsWith(u8, current_text, ordinary_preview)) continue;
            const retained_prefix = current_text[0 .. current_text.len - ordinary_preview.len];
            try self.load(manager, task);
            for (self.cache.items) |entry| {
                const record = entry.parsed.value;
                if (!canonical.matches(record.binding, task.id, self.session, call, status, handle, memory.stored_output_bytes)) continue;
                try validateRecord(alloc, task.id, record);
                work_bytes += record.content.len;
                const text = try projection.project(alloc, record.content, .{ .handle = handle, .bytes = record.binding.bytes, .sha256 = record.binding.sha256, .evidence_id = record.id, .retained_text_prefix = retained_prefix }, inline_cap, .{}) orelse break;
                if (projected == null) projected = try alloc.dupe(types.ChatMessage, source);
                projected.?[index].content = text;
                break;
            }
        }
        return projected orelse source;
    }
};

pub fn validateRecord(alloc: Allocator, task: []const u8, record: canonical.Record) !void {
    if (!std.mem.eql(u8, record.binding.task, task)) return error.InvalidCanonicalToolEvidence;
    try canonical.validate(alloc, record.id, record.binding, record.content);
}

pub fn evidence(alloc: Allocator, task: []const u8, record: canonical.Record) !review.Evidence {
    try validateRecord(alloc, task, record);
    return .{
        .id = record.id,
        .kind = .tool,
        .tool = record.binding.tool,
        .arguments = record.binding.arguments,
        .status = record.binding.status,
        .content = record.content,
        .action_id = record.id,
        .raw_call_id = record.binding.call_id,
    };
}

test "canonical MCP actor projection grants no raw reviewer inspection coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const padding = try alloc.alloc(u8, 12000);
    @memset(padding, 'x');
    const value = .{ .padding = padding, .receipt = "verified-tail-receipt" };
    const text = try alloc.print("ok\nreturn: {s}", .{try std.json.Stringify.valueAlloc(alloc, value, .{})});
    const content = try std.json.Stringify.valueAlloc(alloc, .{ .server = "fixture", .tool = "mcp_fixture_run", .result = .{ .content = .{.{ .type = "text", .text = text }}, .structuredContent = .{ .value = value } } }, .{});
    const call: types.ToolCall = .{ .id = "call", .name = "mcp_fixture_run", .arguments_json = "{}" };
    const handle = try @import("../session/result_store.zig").makeHandle(alloc, call.id, call.name, content);
    const record = try canonical.create(alloc, "task", "session", .{ .call = call, .status = .success, .handle = handle, .content = content });
    const projected = (try projection.project(alloc, record.content, .{ .handle = handle, .bytes = record.binding.bytes, .sha256 = record.binding.sha256, .evidence_id = record.id }, 16 * 1024, .{})) orelse return error.TestExpectedProjection;
    try std.testing.expect(projected.len < 16 * 1024);
    const retained = try evidence(alloc, "task", record);
    try std.testing.expectEqualStrings(content, retained.content);
    var view = try review.View.init(alloc, &.{retained});
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected(record.id));
    _ = try view.page(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .action = "read", .id = record.id, .limit = 128 }, .{}));
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected(record.id));
    var offset: usize = 128;
    while (offset < view.payload_sizes[0]) {
        const raw_page = try view.page(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .action = "read", .id = record.id, .offset = offset, .limit = 16384 }, .{}));
        const page = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw_page, .{});
        const next = page.object.get("nextOffset").?;
        if (next == .null) break;
        offset = @intCast(next.integer);
    }
    try view.requireInspected(record.id);
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, evidence(alloc, "another-task", record));
    var corrupt = record;
    corrupt.content = "changed after capture";
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, evidence(alloc, "task", corrupt));
}

test "canonical MCP cache accounts for large arguments and skips oversized records without disabling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var state: State = .{ .session = "session" };
    defer state.deinit();
    const content = "{\"server\":\"fixture\",\"tool\":\"mcp_fixture_run\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}";
    const padding = try alloc.alloc(u8, 600 * 1024);
    @memset(padding, 'x');
    const arguments = try std.json.Stringify.valueAlloc(alloc, .{ .input = padding }, .{});
    const oversized_padding = try alloc.alloc(u8, cache_budget);
    @memset(oversized_padding, 'y');
    const oversized_arguments = try std.json.Stringify.valueAlloc(alloc, .{ .input = oversized_padding }, .{});
    const calls = [_]types.ToolCall{
        .{ .id = "first", .name = "mcp_fixture_run", .arguments_json = arguments },
        .{ .id = "second", .name = "mcp_fixture_run", .arguments_json = arguments },
        .{ .id = "oversized", .name = "mcp_fixture_run", .arguments_json = oversized_arguments },
        .{ .id = "small", .name = "mcp_fixture_run", .arguments_json = "{}" },
    };
    var records: [calls.len]canonical.Record = undefined;
    for (calls, 0..) |call, index| {
        const handle = try @import("../session/result_store.zig").makeHandle(alloc, call.id, call.name, content);
        records[index] = try canonical.create(alloc, "task", "session", .{ .call = call, .status = .success, .handle = handle, .content = content });
    }
    try state.remember(records[0]);
    try std.testing.expect(state.cached_bytes > arguments.len);
    try state.remember(records[1]);
    try std.testing.expectEqual(@as(usize, 1), state.cache.items.len);
    try std.testing.expectEqualStrings(records[1].id, state.cache.items[0].parsed.value.id);
    try std.testing.expect(state.cached_bytes <= cache_budget);
    const before_oversized = state.cached_bytes;
    try state.remember(records[2]);
    try std.testing.expect(state.seen.contains(records[2].id));
    try std.testing.expect(!state.disabled);
    try std.testing.expectEqual(before_oversized, state.cached_bytes);
    try std.testing.expectEqual(@as(usize, 1), state.cache.items.len);
    try state.remember(records[3]);
    try std.testing.expectEqual(@as(usize, 2), state.cache.items.len);
    try std.testing.expectEqualStrings(records[3].id, state.cache.items[1].parsed.value.id);
    var charged: usize = 0;
    for (state.cache.items) |entry| {
        const encoded = try std.json.Stringify.valueAlloc(alloc, entry.parsed.value, .{});
        try std.testing.expectEqual(encoded.len, entry.encoded_bytes);
        charged += encoded.len;
    }
    try std.testing.expectEqual(charged, state.cached_bytes);
    try std.testing.expect(state.cached_bytes <= cache_budget);
}
