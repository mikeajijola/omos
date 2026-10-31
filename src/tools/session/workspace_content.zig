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
    const result = capabilities.execute(arena.allocator(), input.as(Parsed).value, false, ctx.cancel_flag) catch |err| {
        return .{ .failure = try ctx.allocator.print("Workspace capability unavailable: {s}. No decision or permission was granted.", .{@errorName(err)}) };
    };
    return .{ .success = try std.json.Stringify.valueAlloc(ctx.allocator, result, .{}) };
}
