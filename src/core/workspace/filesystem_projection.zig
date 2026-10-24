//! Disposable filesystem views over versioned workspace content. The baseline
//! records canonical hashes and executable flags; unsaved edits remain in the view until the
//! next successful host checkpoint and must never be treated as cache garbage.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const records = @import("../shared/record_json.zig");

const Entry = struct { path: []const u8, sha256: []const u8, executable: bool = false };
const Baseline = struct { version: u32 = 2, workspace: []const u8, task: []const u8, revision: []const u8, entries: []const Entry };
const File = struct { path: []const u8, content: []const u8, sha256: []const u8, executable: bool };
const Desired = struct { path: []const u8, content: ?[]const u8, sha256: []const u8, executable: bool };
const roots = [_][]const u8{ "memory/", "skills/", "documents/", "artifacts/", "ui/" };
const max_file_bytes = 8 * 1024 * 1024;
const max_view_bytes = 256 * 1024 * 1024;
const max_files = 10000;

pub fn directory(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    return std.Io.Dir.path.join(manager.alloc, &.{ task.project_root, ".fx", "workspaces", manager.manifest.id, task.id });
}

fn baselinePath(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    return std.Io.Dir.path.join(manager.alloc, &.{ manager.root, "projections", try manager.alloc.print("{s}.json", .{try workspace.hash(manager.alloc, try directory(manager, task))}) });
}

fn writable(path: []const u8) bool {
    for (roots) |root| if (std.mem.startsWith(u8, path, root)) return true;
    return false;
}

fn lookup(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

fn fileByPath(files: []const File, path: []const u8) ?File {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}

fn equal(a: ?Entry, b: ?Entry) bool {
    if (a) |left| return if (b) |right| left.executable == right.executable and std.mem.eql(u8, left.sha256, right.sha256) else false;
    return b == null;
}

fn state(file: File) Entry {
    return .{ .path = file.path, .sha256 = file.sha256, .executable = file.executable };
}

fn readFile(alloc: std.mem.Allocator, parent: std.Io.Dir, name: []const u8, path: []const u8) !File {
    var file = try parent.openFile(io_mod.getIo(), name, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.WorkspaceProjectionSymlink;
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
    return .{ .path = path, .content = bytes, .sha256 = try workspace.hash(alloc, bytes), .executable = stat.permissions.toMode() & 0o111 != 0 };
}

fn scan(alloc: std.mem.Allocator, parent: std.Io.Dir, prefix: []const u8, files: *std.ArrayList(File), total: *usize) anyerror!void {
    var iterator = parent.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        const path = try alloc.print("{s}{s}", .{ prefix, entry.name });
        const kind = if (entry.kind == .unknown) (try parent.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false })).kind else entry.kind;
        if (kind == .directory) {
            // Execution caches are not portable inputs. Required packages must
            // declare reproducible dependencies or store their actual resources.
            if (std.mem.eql(u8, entry.name, "node_modules") or std.mem.eql(u8, entry.name, "__pycache__") or std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            if (entry.name[0] == '.') return error.WorkspacePathDenied;
            var child = try parent.openDir(io_mod.getIo(), entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io_mod.getIo());
            try scan(alloc, child, try alloc.print("{s}/", .{path}), files, total);
        } else if (kind == .file) {
            if (entry.name[0] == '.') return error.WorkspacePathDenied;
            const file = try readFile(alloc, parent, entry.name, path);
            total.* = try std.math.add(usize, total.*, file.content.len);
            if (total.* > max_view_bytes or files.items.len >= max_files) return error.WorkspaceProjectionTooLarge;
            try files.append(alloc, file);
        } else return error.WorkspaceProjectionSymlink;
    }
}

fn localFiles(manager: workspace.Manager, task: workspace.Task) ![]const File {
    const root = try directory(manager, task);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), root, .fromMode(0o700));
    var dir = try io_mod.openDirAbsoluteNoFollow(root, .{ .iterate = true });
    defer dir.close(io_mod.getIo());
    var files: std.ArrayList(File) = .empty;
    var total: usize = 0;
    for (roots) |prefix| {
        const name = prefix[0 .. prefix.len - 1];
        var child = dir.openDir(io_mod.getIo(), name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer child.close(io_mod.getIo());
        try scan(manager.alloc, child, prefix, &files, &total);
    }
    return files.items;
}

fn baseline(manager: workspace.Manager, task: workspace.Task) !?Baseline {
    const path = try baselinePath(manager, task);
    const bytes = blk: {
        var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        break :blk try io_mod.readFileToEnd(manager.alloc, &file, max_file_bytes);
    };
    const value = try records.decode(Baseline, manager.alloc, bytes, .{});
    if ((value.version != 1 and value.version != 2) or !std.mem.eql(u8, value.workspace, manager.manifest.id) or !std.mem.eql(u8, value.task, task.id)) return error.WorkspaceProjectionMismatch;
    return value;
}

fn parentDirectory(alloc: std.mem.Allocator, root: []const u8, path: []const u8) !std.Io.Dir {
    var parent = try io_mod.openDirAbsoluteNoFollow(root, .{ .iterate = true });
    errdefer parent.close(io_mod.getIo());
    var parts = std.mem.splitScalar(u8, std.Io.Dir.path.dirname(path) orelse return parent, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or std.mem.findScalar(u8, part, '\\') != null) return error.WorkspacePathDenied;
        _ = try parent.createDirPathStatus(io_mod.getIo(), part, .fromMode(0o700));
        const next = try parent.openDir(io_mod.getIo(), part, .{ .iterate = true, .follow_symlinks = false });
        parent.close(io_mod.getIo());
        parent = next;
    }
    _ = alloc;
    return parent;
}

fn atomicWrite(alloc: std.mem.Allocator, parent: std.Io.Dir, name: []const u8, bytes: []const u8, executable: bool) !void {
    var nonce: [16]u8 = undefined;
    io_mod.getIo().random(&nonce);
    const temporary = try alloc.print("{s}.pending-{s}", .{ name, std.fmt.bytesToHex(&nonce, .lower) });
    var file = try parent.createFile(io_mod.getIo(), temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io_mod.getIo());
    errdefer parent.deleteFile(io_mod.getIo(), temporary) catch {};
    try file.writeStreamingAll(io_mod.getIo(), bytes);
    try file.setPermissions(io_mod.getIo(), .fromMode(if (executable) @as(u32, 0o700) else 0o600));
    try file.sync(io_mod.getIo());
    try std.Io.Dir.rename(parent, temporary, parent, name, io_mod.getIo());
    const handle: std.Io.File = .{ .handle = parent.handle, .flags = .{ .nonblocking = false } };
    try handle.sync(io_mod.getIo());
}

fn saveBaseline(manager: workspace.Manager, task: workspace.Task, revision_id: []const u8, entries: []const Entry) !void {
    const path = try baselinePath(manager, task);
    const parent_path = std.Io.Dir.path.dirname(path).?;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), parent_path, .fromMode(0o700));
    var parent = try io_mod.openDirAbsoluteNoFollow(parent_path, .{ .iterate = true });
    defer parent.close(io_mod.getIo());
    try atomicWrite(manager.alloc, parent, std.Io.Dir.path.basename(path), try std.json.Stringify.valueAlloc(manager.alloc, Baseline{ .workspace = manager.manifest.id, .task = task.id, .revision = revision_id, .entries = entries }, .{}), false);
}

/// Compare all hashes before modifying the view. Interrupted materialisation
/// can be repeated; local changes are never overwritten by a different revision.
pub fn prepare(manager: workspace.Manager, task: workspace.Task) !void {
    var previous = try baseline(manager, task);
    const view = io_mod.openDirAbsoluteNoFollow(try directory(manager, task), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (view) |opened| opened.close(io_mod.getIo()) else previous = null;
    const revision_id = try manager.currentRevision(task);
    if (previous) |saved| if (saved.version == 2 and std.mem.eql(u8, saved.revision, revision_id)) return;
    const local = try localFiles(manager, task);
    const old = if (previous) |value| value.entries else &.{};
    const changed = if (previous) |saved| try manager.changedPaths(saved.revision, revision_id) else &.{};
    var desired: std.ArrayList(Desired) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var total: usize = 0;
    for (try manager.fileManifest(revision_id)) |metadata| {
        const path = metadata.path;
        if (!writable(path)) continue;
        if (metadata.mode == .symlink) return error.WorkspaceProjectionSymlink;
        const executable = metadata.mode == .executable;
        const prior = lookup(old, path);
        const altered = previous == null or prior == null or for (changed) |entry| {
            if (std.mem.eql(u8, entry, path)) break true;
        } else false;
        const current_file = fileByPath(local, path);
        const need_bytes = altered or (current_file == null and prior == null);
        const bytes: ?[]const u8 = if (need_bytes) try manager.contentAt(path, revision_id) else null;
        total = try std.math.add(usize, total, if (bytes) |value| value.len else if (current_file) |value| value.content.len else 0);
        if (total > max_view_bytes or entries.items.len >= max_files) return error.WorkspaceProjectionTooLarge;
        const digest = if (bytes) |value| try workspace.hash(manager.alloc, value) else prior.?.sha256;
        const expected: Entry = .{ .path = path, .sha256 = digest, .executable = executable };
        const current = fileByPath(local, path);
        const observed = if (current) |file| state(file) else null;
        if (!equal(observed, prior) and !equal(observed, expected) and !equal(prior, expected)) return error.WorkspaceProjectionConflict;
        try desired.append(manager.alloc, .{ .path = path, .content = bytes, .sha256 = digest, .executable = executable });
        try entries.append(manager.alloc, expected);
    }
    for (old) |entry| {
        if (lookup(entries.items, entry.path) != null) continue;
        if (fileByPath(local, entry.path)) |file| if (!equal(state(file), entry)) return error.WorkspaceProjectionConflict;
    }
    const root = try directory(manager, task);
    for (desired.items) |file| {
        const current = fileByPath(local, file.path);
        const observed = if (current) |value| state(value) else null;
        const expected: Entry = .{ .path = file.path, .sha256 = file.sha256, .executable = file.executable };
        if (!equal(observed, lookup(old, file.path)) or equal(observed, expected)) continue;
        var parent = try parentDirectory(manager.alloc, root, file.path);
        defer parent.close(io_mod.getIo());
        try atomicWrite(manager.alloc, parent, std.Io.Dir.path.basename(file.path), file.content orelse try manager.contentAt(file.path, revision_id), file.executable);
    }
    for (old) |entry| {
        if (lookup(entries.items, entry.path) != null or fileByPath(local, entry.path) == null) continue;
        var parent = try parentDirectory(manager.alloc, root, entry.path);
        defer parent.close(io_mod.getIo());
        try parent.deleteFile(io_mod.getIo(), std.Io.Dir.path.basename(entry.path));
    }
    try saveBaseline(manager, task, revision_id, entries.items);
}

/// No baseline advancement occurs before the complete batch is committed. A
/// crash after the commit can retry by matching the canonical desired hashes.
pub fn checkpoint(manager: workspace.Manager, task: workspace.Task) !bool {
    const saved = (try baseline(manager, task)) orelse return error.WorkspaceProjectionMissing;
    const local = try localFiles(manager, task);
    var changes: std.ArrayList(workspace.Manager.ContentChange) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    for (local) |file| {
        const prior = lookup(saved.entries, file.path);
        try entries.append(manager.alloc, state(file));
        if (equal(prior, state(file))) continue;
        try changes.append(manager.alloc, .{ .path = file.path, .content = file.content, .previous_hash = if (prior) |value| value.sha256 else null, .previous_executable = if (prior) |value| value.executable else null, .executable = file.executable });
    }
    for (saved.entries) |entry| if (fileByPath(local, entry.path) == null) {
        try changes.append(manager.alloc, .{ .path = entry.path, .content = null, .previous_hash = entry.sha256, .previous_executable = entry.executable });
    };
    if (changes.items.len == 0) return false;
    const revision_id = try manager.checkpointContent(task, changes.items);
    try saveBaseline(manager, task, revision_id, entries.items);
    return true;
}

/// Only managed saved turns redirect skill installation. Unmanaged SDK callers
/// retain their existing configured filesystem behavior.
pub fn skillsDirectory(alloc: std.mem.Allocator, session: ?[]const u8) !?[]const u8 {
    if (comptime builtin.target.cpu.arch.isWasm()) return null;
    const id = session orelse return null;
    const manager = (try workspace.Manager.bound(alloc)) orelse return null;
    const task = (try manager.active(id)) orelse return null;
    return try std.Io.Dir.path.join(alloc, &.{ try directory(manager, task), "skills" });
}
