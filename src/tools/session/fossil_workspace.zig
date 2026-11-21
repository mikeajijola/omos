const std = @import("std");
const workspace = @import("../../core/workspace/fossil_workspace.zig");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Input = struct {
    action: enum { status, read, write, artifact, diff, history, verify_manifest, definition, query, record, propose_definition, restore_ui, verify_runtime, distill_capability, promote_capability, dispatch, workers },
    path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    entity: ?[]const u8 = null,
    offset: usize = 0,
    execution: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    capability_id: ?[]const u8 = null,
    realisation: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    paths: ?[]const []const u8 = null,
    apply: bool = false,
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
        .distill_capability => if (parsed.value.apply) {
            parsed.deinit();
            ctx.allocator.destroy(parsed);
            return .{ .failure = try ctx.allocator.dupe(u8, "Dispatch the original contract to a background worker before making changes.") };
        },
        else => {
            parsed.deinit();
            ctx.allocator.destroy(parsed);
            return .{ .failure = try ctx.allocator.dupe(u8, "Dispatch the original contract to a background worker before making changes.") };
        },
    };
    return .{ .input = .{ .ptr = parsed, .deinit_fn = destroy } };
}

pub fn readsOnly(input: dispatch.ToolInput) bool {
    const parsed = input.as(Parsed).value;
    return switch (parsed.action) {
        .write, .artifact, .record, .propose_definition, .restore_ui, .verify_runtime, .promote_capability, .dispatch => false,
        .distill_capability => !parsed.apply,
        else => true,
    };
}

pub fn irreversible(input: dispatch.ToolInput) bool {
    return input.as(Parsed).value.action == .promote_capability;
}

pub fn call(ctx: dispatch.DispatchContext, input: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return .{ .failure = try ctx.allocator.dupe(u8, "Fossil is available only in the native CLI host.") };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    if (input.action == .verify_runtime or input.action == .promote_capability) manager.operation_control = .{ .cancel = ctx.cancel_flag orelse &cancel, .deadline = .fromNow(@import("../../core/shared/io.zig").getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(60000) }) };
    const task = if (ctx.fossil_session_id) |session| try manager.active(session) else null;
    if (input.action == .workers) {
        const entries = try manager.backgroundRecords(input.offset);
        return std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.background-contracts/v1", .workers = entries, .next_offset = if (entries.len == 32) input.offset + entries.len else @as(?usize, null) }, .{});
    }
    if (input.action == .dispatch) {
        if (input.path != null or input.content != null or input.entity != null or input.execution != null or input.revision != null or input.offset != 0 or input.task_id != null or input.capability_id != null or input.realisation != null or input.summary != null or input.paths != null or input.apply) return error.InvalidBackgroundDispatch;
        const run = ctx.background_dispatch_fn orelse return error.BackgroundHostUnavailable;
        return run(ctx.background_dispatch_ctx, alloc, ctx.tool_call_id);
    }
    if (input.action == .distill_capability) {
        if (input.execution != null or input.offset != 0) return error.InvalidCapabilitySelection;
        if (input.apply and task == null) return error.SavedTaskRequired;
        const task_id = input.task_id orelse input.path orelse return error.TaskIdRequired;
        const capability_id = input.capability_id orelse input.entity orelse return error.MissingCapability;
        const result = try @import("../../core/workspace/capability_distill.zig").distill(manager, .{
            .task_id = task_id,
            .capability_id = capability_id,
            .realisation_id = input.realisation orelse input.revision,
            .paths = input.paths,
            .apply = input.apply,
            .summary = input.summary orelse input.content,
        });
        return std.json.Stringify.valueAlloc(alloc, result, .{});
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
        .promote_capability => {
            if (input.execution != null or input.offset != 0) return error.InvalidCapabilitySelection;
            const config_path = input.path orelse return error.MissingPath;
            const capability_id = input.entity orelse return error.MissingCapability;
            var file = try std.Io.Dir.cwd().openFile(@import("../../core/shared/io.zig").getIo(), config_path, .{ .allow_directory = false, .follow_symlinks = false });
            defer file.close(@import("../../core/shared/io.zig").getIo());
            const raw_config = try @import("../../core/shared/io.zig").readFileToEnd(alloc, &file, 1_000_000);
            const result = try @import("../../core/workspace/capability_promotion.zig").promote(manager, raw_config, &.{.{ .capability = capability_id, .realisation = input.revision }}, input.content);
            return std.json.Stringify.valueAlloc(alloc, result, .{});
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

test "fossil_workspace distill_capability enforces read-only classification and coordinator fencing" {
    const alloc = std.testing.allocator;
    const ctx: dispatch.DispatchContext = .{ .allocator = alloc };

    const preview = try decode(ctx, "{\"action\":\"distill_capability\",\"task_id\":\"t1\",\"capability_id\":\"invoice_audit\"}");
    defer preview.input.deinit(alloc);
    try std.testing.expect(readsOnly(preview.input));

    const mutating = try decode(ctx, "{\"action\":\"distill_capability\",\"task_id\":\"t1\",\"capability_id\":\"invoice_audit\",\"apply\":true}");
    defer mutating.input.deinit(alloc);
    try std.testing.expect(!readsOnly(mutating.input));

    const coord_ctx: dispatch.DispatchContext = .{ .allocator = alloc, .coordinator_mode = true };
    const coord_preview = try decode(coord_ctx, "{\"action\":\"distill_capability\",\"task_id\":\"t1\",\"capability_id\":\"invoice_audit\"}");
    defer coord_preview.input.deinit(alloc);
    try std.testing.expect(readsOnly(coord_preview.input));

    const coord_apply = try decode(coord_ctx, "{\"action\":\"distill_capability\",\"task_id\":\"t1\",\"capability_id\":\"invoice_audit\",\"apply\":true}");
    defer alloc.free(coord_apply.failure);
    try std.testing.expect(std.mem.find(u8, coord_apply.failure, "background worker") != null);
}
