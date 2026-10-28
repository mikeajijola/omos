const std = @import("std");
const workspace = @import("../../core/workspace/fossil_workspace.zig");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Input = struct {
    action: enum { status, read, write, artifact, diff, history, verify_manifest, definition, query, record, propose_definition, restore_ui, verify_runtime, dispatch, workers },
    path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    entity: ?[]const u8 = null,
    offset: usize = 0,
    execution: ?[]const u8 = null,
    revision: ?[]const u8 = null,
};
const Parsed = std.json.Parsed(Input);

fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const parsed: *Parsed = @ptrCast(@alignCast(ptr));
    parsed.deinit();
    alloc.destroy(parsed);
}

pub fn decode(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = try ctx.allocator.create(Parsed);
    errdefer ctx.allocator.destroy(parsed);
    parsed.* = std.json.parseFromSlice(Input, ctx.allocator, args, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        const failure = try ctx.allocator.dupe(u8, "Invalid fossil_workspace arguments");
        ctx.allocator.destroy(parsed);
        return .{ .failure = failure };
    };
    if (ctx.coordinator_mode) switch (parsed.value.action) {
        .status, .read, .diff, .history, .definition, .query, .dispatch, .workers => {},
        else => {
            parsed.deinit();
            ctx.allocator.destroy(parsed);
            return .{ .failure = try ctx.allocator.dupe(u8, "Dispatch the original contract to a background worker before making changes.") };
        },
    };
    return .{ .input = .{ .ptr = parsed, .deinit_fn = destroy } };
}

pub fn readsOnly(input: dispatch.ToolInput) bool {
    return switch (input.as(Parsed).value.action) {
        .write, .artifact, .record, .propose_definition, .restore_ui, .verify_runtime, .dispatch => false,
        else => true,
    };
}

pub fn irreversible(_: dispatch.ToolInput) bool {
    return false;
}

pub fn call(ctx: dispatch.DispatchContext, input: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return .{ .failure = try ctx.allocator.dupe(u8, "Fossil is available only in the native CLI host.") };
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const result = execute(arena.allocator(), ctx, input.as(Parsed).value) catch |err| {
        return .{ .failure = try ctx.allocator.print("Fossil workspace: {s}. The task remains unaccepted.", .{@errorName(err)}) };
    };
    return .{ .success = try ctx.allocator.dupe(u8, result) };
}

fn execute(alloc: std.mem.Allocator, ctx: dispatch.DispatchContext, input: Input) ![]const u8 {
    if (!ctx.fossil_workspace_available) return error.UnmanagedHost;
    var manager = (try workspace.Manager.bound(alloc)) orelse return error.NoFossilWorkspace;
    var cancel = std.atomic.Value(bool).init(false);
    if (input.action == .verify_runtime) manager.operation_control = .{ .cancel = ctx.cancel_flag orelse &cancel, .deadline = .fromNow(@import("../../core/shared/io.zig").getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(60000) }) };
    const task = if (ctx.fossil_session_id) |session| try manager.active(session) else null;
    if (input.action == .workers) {
        const entries = try manager.backgroundRecords(input.offset);
        return std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.background-contracts/v1", .workers = entries, .next_offset = if (entries.len == 32) input.offset + entries.len else @as(?usize, null) }, .{});
    }
    if (input.action == .dispatch) {
        if (input.path != null or input.content != null or input.entity != null or input.execution != null or input.revision != null or input.offset != 0) return error.InvalidBackgroundDispatch;
        const run = ctx.background_dispatch_fn orelse return error.BackgroundHostUnavailable;
        return run(ctx.background_dispatch_ctx, alloc, ctx.tool_call_id);
    }
    if (input.action == .status) {
        var snapshot = try manager.snapshot("");
        if (task) |active| snapshot.files = try manager.inventory(active.branch);
        return std.json.Stringify.valueAlloc(alloc, snapshot, .{});
    }
    if (input.action == .history) return manager.history();
    if (input.action == .definition) return std.json.Stringify.valueAlloc(alloc, try manager.definitionSnapshot(task), .{});
    if (input.action == .query) return manager.queryRecords(task, input.entity, input.offset);
    if (input.action == .read) {
        const path = input.path orelse return error.MissingPath;
        return if (task) |active| manager.readContent(active, path) else manager.trunkContent(path);
    }
    const active = task orelse return error.SavedTaskRequired;
    switch (input.action) {
        .verify_runtime => {
            if (input.content != null or input.execution != null or input.revision != null or input.entity != null or input.offset != 0) return error.InvalidCapabilitySelection;
            return std.json.Stringify.valueAlloc(alloc, try @import("../../core/workspace/capability_runtime.zig").verifyCurrent(manager, active, input.path), .{});
        },
        .restore_ui => return manager.restoreUi(active, input.revision orelse return error.MissingRevision),
        .propose_definition => return manager.proposeDefinition(active, input.content orelse return error.MissingContent, input.execution),
        .record => return manager.writeRecord(active, input.entity orelse return error.MissingEntityType, input.content orelse return error.MissingContent),
        .verify_manifest => return manager.verifyManifest(active, input.path orelse return error.MissingPath),
        .diff => return manager.diff(active),
        .write => {
            try manager.writeContent(active, input.path orelse return error.MissingPath, input.content orelse return error.MissingContent);
            return "Workspace content checkpointed on the task branch.";
        },
        .artifact => return manager.artifact(active, input.content orelse return error.MissingContent),
        else => unreachable,
    }
}
