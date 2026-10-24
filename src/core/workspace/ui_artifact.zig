//! Typed, revision-bound UI source. Runtime builds are disposable projections.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const records = @import("../shared/record_json.zig");
pub const File = struct { path: []const u8, sha256: []const u8, content: []const u8, encoding: enum { utf8, base64 } = .utf8 };

pub fn bytes(alloc: std.mem.Allocator, file: File) ![]const u8 {
    if (!safePath(file.path)) return error.WorkspacePathDenied;
    const value = switch (file.encoding) {
        .utf8 => file.content,
        .base64 => blk: {
            const out = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(file.content));
            try std.base64.standard.Decoder.decode(out, file.content);
            break :blk out;
        },
    };
    if (value.len > 1024 * 1024 or !std.mem.eql(u8, file.sha256, try workspace.hash(alloc, value))) return error.InvalidUiFileDigest;
    return value;
}

pub fn safePath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "ui/") or path.len > 512 or std.mem.findScalar(u8, path, '\\') != null or std.mem.findScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or std.mem.eql(u8, part, "node_modules")) return false;
    }
    return true;
}

pub fn immutableRevision(revision: []const u8) bool {
    if (revision.len != 40 and revision.len != 64) return false;
    for (revision) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn inspect(manager: workspace.Manager, revision: []const u8) ![]const u8 {
    if (!immutableRevision(revision)) return error.ImmutableRevisionRequired;
    const inventory = try manager.inventory(revision);
    var files: std.ArrayList(struct { path: []const u8, sha256: []const u8, bytes: usize }) = .empty;
    for (inventory) |path| {
        if (!safePath(path)) continue;
        const content = try manager.contentAt(path, revision);
        try files.append(manager.alloc, .{ .path = path, .sha256 = try workspace.hash(manager.alloc, content), .bytes = content.len });
    }
    if (files.items.len == 0) return error.UiNotInstalled;
    const manifest = try manager.contentAt("ui/manifest.json", revision);
    const value = try std.json.parseFromSlice(std.json.Value, manager.alloc, manifest, .{});
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .revision = revision, .manifest = value.value, .files = files.items }, .{});
}

pub fn execute(manager: workspace.Manager, method: []const u8, raw: std.json.Value) ![]const u8 {
    const alloc = manager.alloc;
    const Params = struct { revision: []const u8 = "", task: ?[]const u8 = null, session: ?[]const u8 = null, path: ?[]const u8 = null, offset: usize = 0, files: []const File = &.{}, content: ?[]const u8 = null, rebind_project: bool = false };
    const request = try std.json.parseFromValueLeaky(Params, alloc, raw, .{});
    if (std.mem.eql(u8, method, "ui.import_legacy")) {
        const content = request.content orelse return error.MissingContent;
        const legacy = try std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{});
        if (!std.mem.eql(u8, @import("definition.zig").text(legacy, "version"), "omos.ui-legacy-input/v1")) return error.UnsupportedLegacyUi;
        const digest = try workspace.hash(alloc, content);
        const session = try alloc.print("ui-legacy-{s}", .{digest});
        if (try manager.active(session)) |existing| return std.json.Stringify.valueAlloc(alloc, .{ .task = existing.id, .retained = true, .publication = "unpublished" }, .{});
        const task = try manager.start(session, try @import("../shared/io.zig").realpathAlloc(alloc, "."), "Retain legacy UI appearance history as unpublished migration input", null);
        const artifact = try manager.artifact(task, content);
        try manager.record(task, "legacy_ui_input", .{ .artifact = artifact, .sha256 = digest, .publication = "unpublished", .note = "Imported local appearance history. These are retained inputs, not historical Fossil publications." });
        const paused = try manager.setState(task.id, .paused);
        const revision = try manager.checkpoint(paused);
        return std.json.Stringify.valueAlloc(alloc, .{ .task = task.id, .artifact = artifact, .revision = revision, .retained = true, .publication = "unpublished" }, .{});
    }
    if (std.mem.eql(u8, method, "ui.current")) {
        const saved = try manager.revision("trunk");
        const task = if (request.session) |session| try manager.active(session) else null;
        const selected = if (task) |item| if (item.state == .accepted) null else item else null;
        return std.json.Stringify.valueAlloc(alloc, .{ .saved_revision = saved, .revision = if (selected) |item| try manager.currentRevision(item) else saved, .task = if (selected) |item| item.id else null, .state = if (selected) |item| @tagName(item.state) else "accepted" }, .{});
    }
    if (std.mem.eql(u8, method, "ui.history")) return manager.uiHistory(request.offset);
    if (!immutableRevision(request.revision)) return error.ImmutableRevisionRequired;
    if (std.mem.eql(u8, method, "ui.install")) return manager.installUi(request.revision, request.files);
    if (std.mem.eql(u8, method, "ui.inspect")) return inspect(manager, request.revision);
    if (std.mem.eql(u8, method, "ui.read")) {
        const path = request.path orelse return error.MissingPath;
        if (!safePath(path)) return error.WorkspacePathDenied;
        const content = try manager.contentAt(path, request.revision);
        if (request.offset > content.len) return error.InvalidEvidenceOffset;
        const end = request.offset + @min(content.len - request.offset, 16384);
        const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(end - request.offset));
        return std.json.Stringify.valueAlloc(alloc, .{ .revision = request.revision, .path = path, .sha256 = try workspace.hash(alloc, content), .bytes = content.len, .offset = request.offset, .next_offset = if (end < content.len) @as(?usize, end) else null, .content = std.base64.standard.Encoder.encode(encoded, content[request.offset..end]), .encoding = "base64" }, .{});
    }
    if (std.mem.eql(u8, method, "ui.write")) {
        const task = try manager.loadTask(request.task orelse return error.TaskIdRequired);
        var fenced = manager;
        fenced.expected_revision = request.revision;
        return fenced.writeUi(task, request.files);
    }
    if (std.mem.eql(u8, method, "task.resume")) {
        var fenced = manager;
        fenced.expected_revision = request.revision;
        const selected = try fenced.resumeTaskInProject(request.session orelse return error.SessionIdRequired, request.task orelse return error.TaskIdRequired, try @import("../shared/io.zig").realpathAlloc(alloc, "."), request.rebind_project);
        return std.json.Stringify.valueAlloc(alloc, selected, .{});
    }
    return error.UnsupportedUiMethod;
}

test "UI source rejects traversal, private paths and dependency trees" {
    try std.testing.expect(safePath("ui/src/components/chat.tsx"));
    for ([_][]const u8{ "ui/../auth", "ui/.git/config", "ui//x", "ui/node_modules/a", "memory/ui/x", "ui/a\\b" }) |path| try std.testing.expect(!safePath(path));
}
