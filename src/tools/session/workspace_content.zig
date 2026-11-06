const std = @import("std");
const dispatch = @import("../../core/tooling/tool_dispatch.zig");
const capabilities = @import("../../core/workspace/capabilities.zig");
const Parsed = std.json.Parsed(capabilities.Request);

fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const parsed: *Parsed = @ptrCast(@alignCast(ptr));
    parsed.deinit();
    alloc.destroy(parsed);
}

pub fn decode(ctx: dispatch.DispatchContext, args: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    const parsed = try ctx.allocator.create(Parsed);
    var transferred = false;
    defer if (!transferred) ctx.allocator.destroy(parsed);
    parsed.* = std.json.parseFromSlice(capabilities.Request, ctx.allocator, args, .{ .allocate = .alloc_always }) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "Supply a workspace capability action and its typed request.") };
    };
    transferred = true;
    return .{ .input = .{ .ptr = parsed, .deinit_fn = destroy } };
}

pub fn readsOnly(_: dispatch.ToolInput) bool {
    return true;
}
pub fn irreversible(_: dispatch.ToolInput) bool {
    return false;
}

pub fn call(ctx: dispatch.DispatchContext, input: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return .{ .failure = try ctx.allocator.dupe(u8, "Workspace capabilities require a native host.") };
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const request = scopedRequest(ctx, arena.allocator(), input.as(Parsed).value) catch |err| {
        return .{ .failure = try ctx.allocator.print("Workspace contract context unavailable: {s}.", .{@errorName(err)}) };
    };
    const result = capabilities.execute(arena.allocator(), request, false, ctx.cancel_flag) catch |err| {
        return .{ .failure = try ctx.allocator.print("Workspace capability unavailable: {s}. No decision or permission was granted.", .{@errorName(err)}) };
    };
    return .{ .success = try std.json.Stringify.valueAlloc(ctx.allocator, result, .{}) };
}

fn scopedRequest(ctx: dispatch.DispatchContext, alloc: std.mem.Allocator, input: capabilities.Request) !capabilities.Request {
    var request = input;
    if (request.contracts) |*contract| {
        if (contract.task == null and (contract.action == .status or contract.action == .context)) {
            if (ctx.fossil_session_id) |session| {
                if (try @import("../../core/workspace/fossil_workspace.zig").Manager.bound(alloc)) |manager| {
                    if (try manager.active(session)) |task| contract.task = task.id;
                }
            }
        }
    }
    return request;
}
