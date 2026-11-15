//! Public conversation projection. Provider replay, credentials, tool payloads
//! and recovery state never enter this interface.
const std = @import("std");
const io = @import("../shared/io.zig");
const store_module = @import("../session/session_store.zig");
const workspace = @import("fossil_workspace.zig");

pub fn retain(manager: workspace.Manager, session: []const u8) !void {
    const snapshot = try project(manager, session, 0, 10001);
    if (snapshot.object.get("next_offset").? != .null) return error.ConversationProjectionTooLarge;
    try manager.retainConversation(session, snapshot);
}

pub fn execute(manager: workspace.Manager, session: ?[]const u8, offset: usize) !std.json.Value {
    return project(manager, session, offset, 32);
}

fn project(manager: workspace.Manager, session: ?[]const u8, offset: usize, limit: usize) !std.json.Value {
    const alloc = manager.alloc;
    const root = try io.realpathAlloc(alloc, ".");
    var store = try store_module.Store.initReadOnly(alloc, root);
    defer store.deinit(alloc);
    if (session) |id| {
        var detail = store.loadReadOnlyDetail(alloc, id, .{}) catch |err| switch (err) {
            error.SessionNotFound, error.FileNotFound => return retained(manager, id, offset, limit),
            else => return err,
        };
        defer detail.deinit(alloc);
        if (detail.summary.workspace_root == null or !std.mem.eql(u8, root, detail.summary.workspace_root.?)) {
            // A portable projection belongs to this Fossil workspace even if
            // a local session with the same ID now belongs to another cwd.
            // Never expose that other directory's unretained local history.
            return retained(manager, id, offset, limit) catch |err| switch (err) {
                error.SessionNotFound => error.ConversationWorkspaceMismatch,
                else => err,
            };
        }
        var turns: std.ArrayList(std.json.Value) = .empty;
        const start = @min(offset, detail.state.history.len);
        const end = @min(start + limit, detail.state.history.len);
        for (detail.state.history[start..end], start..) |turn, index| {
            const entry = switch (turn) {
                .assistant => |item| try @import("capabilities.zig").value(alloc, .{ .index = index, .kind = "exchange", .user = item.user.text, .assistant = item.assistant, .work_id = item.user.work_id }),
                .interrupted => |item| try @import("capabilities.zig").value(alloc, .{ .index = index, .kind = "interrupted", .user = item.user.text, .assistant = item.assistant, .work_id = item.user.work_id }),
                .compacted_summary => |item| try @import("capabilities.zig").value(alloc, .{ .index = index, .kind = "summary", .summary = item.summary }),
            };
            try turns.append(alloc, entry);
        }
        return @import("capabilities.zig").value(alloc, .{ .version = "omos.conversation/v1", .session = id, .revision_ms = detail.summary.updated_at_ms, .title = detail.summary.title, .turns = turns.items, .next_offset = if (end < detail.state.history.len) @as(?usize, end) else null, .authority = "conversation_context" });
    }
    var entries = try store.listForWorkspace(alloc);
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    var items: std.ArrayList(std.json.Value) = .empty;
    var seen: std.StringHashMap(void) = .init(alloc);
    defer seen.deinit();
    for (entries.items) |entry| {
        try seen.put(try alloc.print("runtime/conversations/{s}.json", .{try workspace.hash(alloc, entry.id)}), {});
        try items.append(alloc, try @import("capabilities.zig").value(alloc, .{ .id = entry.id, .title = entry.title, .preview = entry.preview, .created_at_ms = entry.created_at_ms, .updated_at_ms = entry.updated_at_ms, .turns = entry.history_len, .resumable = true }));
    }
    if (try manager.runtimeRevisionIfPresent()) |revision| {
        for (try manager.fileManifest(revision)) |file| {
            if (!std.mem.startsWith(u8, file.path, "runtime/conversations/")) continue;
            if (seen.contains(file.path)) continue;
            const raw = try manager.retrievalArtifact(file.artifact orelse continue);
            const record = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
            const id = @import("definition.zig").text(record, "session");
            if (id.len == 0) continue;
            try items.append(alloc, try @import("capabilities.zig").value(alloc, .{ .id = id, .title = record.object.get("title"), .preview = "Retained conversation", .updated_at_ms = record.object.get("revision_ms"), .resumable = false }));
        }
    }
    std.mem.sort(std.json.Value, items.items, {}, struct {
        fn less(_: void, a: std.json.Value, b: std.json.Value) bool {
            const left = a.object.get("updated_at_ms") orelse .null;
            const right = b.object.get("updated_at_ms") orelse .null;
            if (left == .integer and right == .integer and left.integer != right.integer) return left.integer > right.integer;
            return std.mem.lessThan(u8, @import("definition.zig").text(a, "id"), @import("definition.zig").text(b, "id"));
        }
    }.less);
    const start = @min(offset, items.items.len);
    const end = @min(start + limit, items.items.len);
    return @import("capabilities.zig").value(alloc, .{ .version = "omos.conversations/v1", .items = items.items[start..end], .next_offset = if (end < items.items.len) @as(?usize, end) else null });
}

fn retained(manager: workspace.Manager, id: []const u8, offset: usize, limit: usize) !std.json.Value {
    const alloc = manager.alloc;
    const revision = (try manager.runtimeRevisionIfPresent()) orelse return error.SessionNotFound;
    const path = try alloc.print("runtime/conversations/{s}.json", .{try workspace.hash(alloc, id)});
    const files = try manager.fileManifest(revision);
    const file = for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) break file;
    } else return error.SessionNotFound;
    const projection = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try manager.retrievalArtifact(file.artifact orelse return error.MissingArtifact), .{});
    if (projection != .object or !std.mem.eql(u8, @import("definition.zig").text(projection, "session"), id)) return error.InvalidConversationProjection;
    const turns = projection.object.get("turns") orelse return error.InvalidConversationProjection;
    if (turns != .array) return error.InvalidConversationProjection;
    const all = turns.array.items;
    const start = @min(offset, all.len);
    const end = @min(start + limit, all.len);
    return @import("capabilities.zig").value(alloc, .{ .version = "omos.conversation/v1", .session = id, .title = projection.object.get("title"), .revision_ms = projection.object.get("revision_ms"), .revision = revision, .path = path, .turns = all[start..end], .next_offset = if (end < all.len) @as(?usize, end) else null, .resumable = false, .authority = "retained_conversation_context" });
}
