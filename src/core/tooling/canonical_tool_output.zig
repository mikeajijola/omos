//! Host-authenticated binding for a retained MCP result. No text grants authority.
const std = @import("std");
const types = @import("../shared/types.zig");
const result_store = @import("../session/result_store.zig");
const session_child_store = @import("../session/session_child_store.zig");

pub const max_bytes: usize = 256 * 1024;
pub const Binding = struct {
    schema: []const u8 = "omos.canonical-mcp-output/v1",
    task: []const u8,
    session: []const u8,
    call_id: []const u8,
    tool: []const u8,
    arguments: []const u8,
    status: types.PersistedToolStatus,
    handle: []const u8,
    bytes: usize,
    sha256: []const u8,
};

/// Borrowed result captured synchronously after genuine MCP dispatch, before
/// another acting tool can run. The sink must copy anything it retains.
pub const Capture = struct {
    call: types.ToolCall,
    status: types.PersistedToolStatus,
    handle: []const u8,
    content: []const u8,
};

pub const Sink = struct {
    context: *anyopaque,
    capture_fn: *const fn (*anyopaque, std.mem.Allocator, Capture) anyerror!void,
};

pub fn digest(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return alloc.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

pub fn identity(alloc: std.mem.Allocator, binding: Binding) ![]const u8 {
    const serialized = try std.json.Stringify.valueAlloc(alloc, binding, .{});
    defer alloc.free(serialized);
    const hash = try digest(alloc, serialized);
    defer alloc.free(hash);
    return alloc.print("canonical-tool-output:{s}", .{hash});
}

/// Validation never resolves a path or trusts an arbitrary output handle.
/// The caller supplies the task/session and exact producing call independently.
pub fn matches(
    binding: Binding,
    task: []const u8,
    session: []const u8,
    call: types.ToolCall,
    status: types.PersistedToolStatus,
    handle: []const u8,
    bytes: usize,
) bool {
    return std.mem.eql(u8, binding.schema, "omos.canonical-mcp-output/v1") and
        std.mem.eql(u8, binding.task, task) and
        std.mem.eql(u8, binding.session, session) and
        std.mem.eql(u8, binding.call_id, call.id) and
        std.mem.eql(u8, binding.tool, call.name) and
        std.mem.eql(u8, binding.arguments, call.arguments_json) and
        binding.status == status and std.mem.eql(u8, binding.handle, handle) and
        binding.bytes == bytes;
}

pub fn validate(alloc: std.mem.Allocator, id: []const u8, binding: Binding, content: []const u8) !void {
    if (!std.mem.eql(u8, binding.schema, "omos.canonical-mcp-output/v1") or
        binding.task.len == 0 or binding.session.len == 0 or binding.call_id.len == 0 or
        binding.tool.len == 0 or binding.bytes != content.len or content.len > max_bytes or
        !result_store.isStoredTextHandle(binding.handle)) return error.InvalidCanonicalToolEvidence;
    const hash = try digest(alloc, content);
    defer alloc.free(hash);
    if (!std.mem.eql(u8, hash, binding.sha256)) return error.InvalidCanonicalToolEvidence;
    const expected_id = try identity(alloc, binding);
    defer alloc.free(expected_id);
    if (!std.mem.eql(u8, expected_id, id)) return error.InvalidCanonicalToolEvidence;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCanonicalToolEvidence,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCanonicalToolEvidence;
    const tool = parsed.value.object.get("tool") orelse return error.InvalidCanonicalToolEvidence;
    const server = parsed.value.object.get("server") orelse return error.InvalidCanonicalToolEvidence;
    const result = parsed.value.object.get("result") orelse return error.InvalidCanonicalToolEvidence;
    if (tool != .string or !std.mem.eql(u8, tool.string, binding.tool) or server != .string or
        server.string.len == 0 or result != .object or result.object.contains("truncated")) return error.InvalidCanonicalToolEvidence;
    const is_error = if (result.object.get("isError")) |flag| if (flag == .bool) flag.bool else return error.InvalidCanonicalToolEvidence else false;
    if (is_error != (binding.status == .failure)) return error.InvalidCanonicalToolEvidence;
}

/// Verify both the content-addressed artifact and its exact producing call.
/// The current session capability, never a path from tool text, selects storage.
pub fn verifyStored(
    alloc: std.mem.Allocator,
    capability: *session_child_store.SessionChildCapability,
    capture: Capture,
) !void {
    if (capture.content.len > max_bytes) return error.ResultSizeUnsupported;
    const expected_handle = try result_store.handleFor(alloc, capability, capture.call.id, capture.call.name, capture.content);
    defer alloc.free(expected_handle);
    if (!std.mem.eql(u8, expected_handle, capture.handle)) return error.InvalidCanonicalToolEvidence;
    const stored = try result_store.readForReplayManaged(alloc, capability, capture.handle, capture.content.len);
    defer alloc.free(stored);
    if (!std.mem.eql(u8, stored, capture.content)) return error.InvalidCanonicalToolEvidence;
}

pub const Record = struct { id: []const u8, binding: Binding, content: []const u8 };

pub fn create(alloc: std.mem.Allocator, task: []const u8, session: []const u8, capture: Capture) !Record {
    const binding: Binding = .{
        .task = task,
        .session = session,
        .call_id = capture.call.id,
        .tool = capture.call.name,
        .arguments = capture.call.arguments_json,
        .status = capture.status,
        .handle = capture.handle,
        .bytes = capture.content.len,
        .sha256 = try digest(alloc, capture.content),
    };
    errdefer alloc.free(binding.sha256);
    const record: Record = .{ .id = try identity(alloc, binding), .binding = binding, .content = capture.content };
    errdefer alloc.free(record.id);
    try validate(alloc, record.id, record.binding, record.content);
    return record;
}

test "canonical MCP binding rejects changed task session call arguments status and body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = "{\"server\":\"fixture\",\"tool\":\"mcp_fixture_run\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"receipt\"}]}}";
    const call: types.ToolCall = .{ .id = "call-1", .name = "mcp_fixture_run", .arguments_json = "{\"id\":1}" };
    const handle = try result_store.makeHandle(alloc, call.id, call.name, content);
    const record = try create(alloc, "task-1", "session-1", .{ .call = call, .status = .success, .handle = handle, .content = content });
    try validate(alloc, record.id, record.binding, record.content);
    try std.testing.expect(matches(record.binding, "task-1", "session-1", call, .success, handle, content.len));
    try std.testing.expect(!matches(record.binding, "other-task", "session-1", call, .success, handle, content.len));
    try std.testing.expect(!matches(record.binding, "task-1", "other-session", call, .success, handle, content.len));
    var changed = call;
    changed.id = "other-call";
    try std.testing.expect(!matches(record.binding, "task-1", "session-1", changed, .success, handle, content.len));
    changed = call;
    changed.arguments_json = "{\"id\":2}";
    try std.testing.expect(!matches(record.binding, "task-1", "session-1", changed, .success, handle, content.len));
    try std.testing.expect(!matches(record.binding, "task-1", "session-1", call, .failure, handle, content.len));
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, validate(alloc, record.id, record.binding, "changed"));
    var forged = record.binding;
    forged.schema = "omos.canonical-mcp-output/v2";
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, validate(alloc, try identity(alloc, forged), forged, content));
    try std.testing.expectEqualStrings(record.id, (try create(alloc, "task-1", "session-1", .{ .call = call, .status = .success, .handle = handle, .content = content })).id);
}

test "canonical MCP capture verifies exact current-session storage and rejects missing or corrupt bodies" {
    const alloc = std.testing.allocator;
    var memory = session_child_store.MemoryBlobsForTesting.init(alloc);
    defer memory.deinit();
    var foreign_memory = session_child_store.MemoryBlobsForTesting.init(alloc);
    defer foreign_memory.deinit();
    var capability = try session_child_store.SessionChildCapability.initBlobs(alloc, memory.blobs(), "", .writable);
    defer capability.deinit();
    var foreign = try session_child_store.SessionChildCapability.initBlobs(alloc, foreign_memory.blobs(), "", .writable);
    defer foreign.deinit();
    const content = "{\"server\":\"fixture\",\"tool\":\"mcp_fixture_run\",\"result\":{\"content\":[]}}";
    const call: types.ToolCall = .{ .id = "native-call", .name = "mcp_fixture_run", .arguments_json = "{}" };
    const handle = try result_store.storeLargeResultManaged(alloc, &capability, call.id, call.name, content);
    defer alloc.free(handle);
    const captured: Capture = .{ .call = call, .status = .success, .handle = handle, .content = content };
    try verifyStored(alloc, &capability, captured);
    try std.testing.expectError(error.ResultHandleNotFound, verifyStored(alloc, &foreign, captured));
    var wrong = captured;
    wrong.content = "changed";
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, verifyStored(alloc, &capability, wrong));
    var bodies = memory.bodies.valueIterator();
    const body = bodies.next().?.*;
    body[0] = '[';
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, verifyStored(alloc, &capability, captured));
}

test "canonical MCP failed output cannot be promoted to successful evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body = "{\"server\":\"fixture\",\"tool\":\"mcp_fixture_run\",\"result\":{\"isError\":true,\"content\":[]}}";
    const call: types.ToolCall = .{ .id = "failed-call", .name = "mcp_fixture_run", .arguments_json = "{}" };
    const handle = try result_store.makeHandle(alloc, call.id, call.name, body);
    try std.testing.expectError(error.InvalidCanonicalToolEvidence, create(alloc, "task", "session", .{ .call = call, .status = .success, .handle = handle, .content = body }));
    const failed = try create(alloc, "task", "session", .{ .call = call, .status = .failure, .handle = handle, .content = body });
    try std.testing.expectEqual(types.PersistedToolStatus.failure, failed.binding.status);
}
