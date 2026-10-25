//! Disposable filesystem views over versioned workspace content. The baseline
//! records canonical hashes and executable flags; unsaved edits remain in the view until the
//! next successful host checkpoint and must never be treated as cache garbage.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const records = @import("../shared/record_json.zig");

const Entry = struct { path: []const u8, sha256: []const u8, executable: bool = false };
const Pending = struct { revision: []const u8, entries: []const Entry };
const Baseline = struct { version: u32 = 3, workspace: []const u8, task: []const u8, revision: []const u8, entries: []const Entry, pending: ?Pending = null };
const File = struct { path: []const u8, bytes: usize, sha256: []const u8, executable: bool };
const Desired = struct { path: []const u8, sha256: []const u8, executable: bool };
const roots = [_][]const u8{ "memory/", "skills/", "documents/", "artifacts/", "ui/" };
const max_file_bytes = 8 * 1024 * 1024;
const max_view_bytes = 256 * 1024 * 1024;
const max_files = 10000;

fn projectionRecord(manager: workspace.Manager, root: []const u8) ![]const u8 {
    return std.Io.Dir.path.join(manager.alloc, &.{ manager.root, "projections", try manager.alloc.print("{s}.json", .{try workspace.hash(manager.alloc, root)}) });
}

fn present(path: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io_mod.getIo());
    return true;
}

pub fn directory(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    const parent = try std.Io.Dir.path.join(manager.alloc, &.{ task.project_root, ".fx", "workspaces", manager.manifest.id });
    const selected = try std.Io.Dir.path.join(manager.alloc, &.{ parent, try manager.alloc.print("{s}-{s}", .{ task.id, try workspace.hash(manager.alloc, manager.repository) }) });
    // Older runtimes cannot discover the new binding-specific namespace. Keep
    // an existing owned legacy view in place, including its uncommitted drafts.
    if (try present(try projectionRecord(manager, selected))) return selected;
    if (try present(try std.Io.Dir.path.join(manager.alloc, &.{ parent, ".pins", try manager.alloc.print("{s}.lock", .{try workspace.hash(manager.alloc, selected)}) }))) return selected;
    const legacy = try std.Io.Dir.path.join(manager.alloc, &.{ parent, task.id });
    return if (try present(try projectionRecord(manager, legacy))) legacy else selected;
}

pub fn retentionPath(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    // Repository copies and profiles can refer to the same physical view. Its
    // lifetime lock belongs beside that view, independently of repository caches.
    var project = try io_mod.openDirAbsoluteNoFollow(task.project_root, .{ .iterate = true });
    defer project.close(io_mod.getIo());
    project.createDir(io_mod.getIo(), ".fx", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var fx = try project.openDir(io_mod.getIo(), ".fx", .{ .iterate = true, .follow_symlinks = false });
    defer fx.close(io_mod.getIo());
    var views = try io_mod.openOrCreateVerifiedPrivateDirFromDir(fx, "workspaces");
    defer views.close();
    var instance = try io_mod.openOrCreateVerifiedPrivateDir(&views, manager.manifest.id);
    defer instance.close();
    var pins = try io_mod.openOrCreateVerifiedPrivateDir(&instance, ".pins");
    defer pins.close();
    const root = try std.Io.Dir.path.join(manager.alloc, &.{ task.project_root, ".fx", "workspaces", manager.manifest.id, ".pins" });
    return std.Io.Dir.path.join(manager.alloc, &.{ root, try manager.alloc.print("{s}.lock", .{try workspace.hash(manager.alloc, try directory(manager, task))}) });
}

pub fn retentionPathForSession(alloc: std.mem.Allocator, session: ?[]const u8) !?[]const u8 {
    if (comptime builtin.target.cpu.arch.isWasm()) return null;
    const id = session orelse return null;
    const manager = (try workspace.Manager.bound(alloc)) orelse return null;
    const task = (try manager.active(id)) orelse return null;
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    return try retentionPath(manager, task);
}

pub fn retentionTaskForSession(alloc: std.mem.Allocator, session: ?[]const u8) !?[]const u8 {
    if (comptime builtin.target.cpu.arch.isWasm()) return null;
    const id = session orelse return null;
    const manager = (try workspace.Manager.bound(alloc)) orelse return null;
    const task = (try manager.active(id)) orelse return null;
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    return task.id;
}

/// A persistent terminal may belong to a root session while running a child
/// task. Validate the explicit task against that authenticated ancestry.
pub fn retentionPathForTask(alloc: std.mem.Allocator, id: []const u8, owner_session: []const u8, project: []const u8) ![]const u8 {
    const manager = (try workspace.Manager.bound(alloc)) orelse return error.NoFossilWorkspace;
    const task = try manager.loadTask(id);
    const owner = try workspace.hash(alloc, owner_session);
    try verifyRetentionOwner(task, owner, project, manager);
    return retentionPath(manager, task);
}

fn verifyRetentionOwner(task: workspace.Task, owner: []const u8, project: []const u8, source: anytype) !void {
    if (!std.mem.eql(u8, task.project_root, project)) return error.TaskProjectMismatch;
    var ancestor = task;
    var owned = false;
    for (0..64) |_| {
        if (ancestor.authority != null) return error.CompanyExecutionIsolationRequired;
        if (std.mem.eql(u8, ancestor.session, owner)) owned = true;
        const parent = ancestor.parent_task_id orelse {
            if (owned) return;
            return error.WorkspaceAccessDenied;
        };
        ancestor = try source.loadTask(parent);
    }
    return error.WorkspaceAccessDenied;
}

fn baselinePath(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    return projectionRecord(manager, try directory(manager, task));
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
    if (stat.size > max_file_bytes) return error.WorkspaceProjectionTooLarge;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var reader_buffer: [8192]u8 = undefined;
    var transfer: [8192]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &reader_buffer);
    var bytes: usize = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&transfer);
        if (count == 0) break;
        bytes = try std.math.add(usize, bytes, count);
        if (bytes > max_file_bytes) return error.WorkspaceProjectionTooLarge;
        digest.update(transfer[0..count]);
    }
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    const hex = std.fmt.bytesToHex(&hash, .lower);
    return .{ .path = path, .bytes = bytes, .sha256 = try alloc.dupe(u8, &hex), .executable = stat.permissions.toMode() & 0o111 != 0 };
}

/// Materialise a changed body only after scanning its metadata. A concurrent
/// edit leaves the baseline unchanged and is inspected again on the next try.
fn changedBytes(alloc: std.mem.Allocator, parent: std.Io.Dir, name: []const u8, expected: File) ![]const u8 {
    var file = try parent.openFile(io_mod.getIo(), name, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size != expected.bytes or (stat.permissions.toMode() & 0o111 != 0) != expected.executable) return error.WorkspaceProjectionConflict;
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
    errdefer alloc.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(&digest, .lower);
    const after = try file.stat(io_mod.getIo());
    if (bytes.len != expected.bytes or after.size != expected.bytes or (after.permissions.toMode() & 0o111 != 0) != expected.executable or !std.mem.eql(u8, expected.sha256, &hex)) return error.WorkspaceProjectionConflict;
    return bytes;
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
            total.* = try std.math.add(usize, total.*, file.bytes);
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
    if ((value.version != 1 and value.version != 2 and value.version != 3) or !std.mem.eql(u8, value.workspace, manager.manifest.id) or !std.mem.eql(u8, value.task, task.id)) return error.WorkspaceProjectionMismatch;
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
    try saveState(manager, task, .{ .workspace = manager.manifest.id, .task = task.id, .revision = revision_id, .entries = entries });
}

fn saveState(manager: workspace.Manager, task: workspace.Task, value: Baseline) !void {
    const path = try baselinePath(manager, task);
    const parent_path = std.Io.Dir.path.dirname(path).?;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), parent_path, .fromMode(0o700));
    var parent = try io_mod.openDirAbsoluteNoFollow(parent_path, .{ .iterate = true });
    defer parent.close(io_mod.getIo());
    const bytes = try std.json.Stringify.valueAlloc(manager.alloc, value, .{});
    if (bytes.len > max_file_bytes) return error.WorkspaceProjectionTooLarge;
    try atomicWrite(manager.alloc, parent, std.Io.Dir.path.basename(path), bytes, false);
}

/// Compare all hashes before modifying the view. Interrupted materialisation
/// can be repeated; local changes are never overwritten by a different revision.
pub fn prepare(manager: workspace.Manager, task: workspace.Task) !void {
    const lease = try manager.projectionLease(task);
    defer lease.release();
    try materialise(manager, task, .{});
}

const Selection = struct {
    all: bool = false,
    path: ?[]const u8 = null,
    skill_index: bool = false,

    fn includes(self: Selection, path: []const u8) bool {
        if (self.all) return true;
        if (self.skill_index and std.mem.startsWith(u8, path, "skills/") and std.mem.endsWith(u8, path, "/SKILL.md")) return true;
        const prefix = self.path orelse return false;
        return prefix.len == 0 or std.mem.eql(u8, prefix, path) or (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
    }
};

fn materialise(manager: workspace.Manager, task: workspace.Task, selection: Selection) !void {
    if (manager.operation_control) |control| try control.check();
    var previous = try baseline(manager, task);
    const view = io_mod.openDirAbsoluteNoFollow(try directory(manager, task), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (view) |opened| opened.close(io_mod.getIo()) else previous = null;
    const revision_id = try manager.currentRevision(task);
    if (previous) |saved| if (saved.version == 3 and saved.pending == null and std.mem.eql(u8, saved.revision, revision_id) and !selection.all and selection.path == null and !selection.skill_index) return;
    const local = try localFiles(manager, task);
    const old = try priorEntries(manager.alloc, previous, local);
    const changed = if (previous) |saved| try manager.changedPaths(saved.revision, revision_id) else &.{};
    var desired: std.ArrayList(Desired) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var total: usize = 0;
    for (try manager.fileManifest(revision_id)) |metadata| {
        if (manager.operation_control) |control| try control.check();
        const path = metadata.path;
        if (!writable(path)) continue;
        const prior = lookup(old, path);
        const current_file = fileByPath(local, path);
        if (prior == null and current_file == null and !selection.includes(path)) continue;
        if (metadata.mode == .symlink) return error.WorkspaceProjectionSymlink;
        const executable = metadata.mode == .executable;
        const altered = previous == null or prior == null or for (changed) |entry| {
            if (std.mem.eql(u8, entry, path)) break true;
        } else false;
        const need_bytes = altered or (current_file == null and prior == null);
        var page_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer page_arena.deinit();
        var page_manager = manager;
        page_manager.alloc = page_arena.allocator();
        const bytes: ?[]const u8 = if (need_bytes) try page_manager.contentAt(path, revision_id) else null;
        if (bytes) |value| if (value.len > max_file_bytes) return error.WorkspaceProjectionTooLarge;
        total = try std.math.add(usize, total, if (bytes) |value| value.len else if (current_file) |value| value.bytes else 0);
        if (total > max_view_bytes or entries.items.len >= max_files) return error.WorkspaceProjectionTooLarge;
        const digest = if (bytes) |value| try workspace.hash(manager.alloc, value) else prior.?.sha256;
        const expected: Entry = .{ .path = path, .sha256 = digest, .executable = executable };
        const current = fileByPath(local, path);
        const observed = if (current) |file| state(file) else null;
        if (!equal(observed, prior) and !equal(observed, expected) and !equal(prior, expected)) return error.WorkspaceProjectionConflict;
        try desired.append(manager.alloc, .{ .path = path, .sha256 = digest, .executable = executable });
        try entries.append(manager.alloc, expected);
    }
    for (old) |entry| {
        if (lookup(entries.items, entry.path) != null) continue;
        if (fileByPath(local, entry.path)) |file| if (!equal(state(file), entry)) return error.WorkspaceProjectionConflict;
    }
    // Retain expected hashes before the first write. Recovery adopts only
    // present files; an unwritten pending file can never become a deletion.
    try saveState(manager, task, .{ .workspace = manager.manifest.id, .task = task.id, .revision = if (previous) |saved| saved.revision else revision_id, .entries = old, .pending = .{ .revision = revision_id, .entries = entries.items } });
    const root = try directory(manager, task);
    for (desired.items) |file| {
        if (manager.operation_control) |control| try control.check();
        const current = fileByPath(local, file.path);
        const observed = if (current) |value| state(value) else null;
        const expected: Entry = .{ .path = file.path, .sha256 = file.sha256, .executable = file.executable };
        if (!equal(observed, lookup(old, file.path)) or equal(observed, expected)) continue;
        var parent = try parentDirectory(manager.alloc, root, file.path);
        defer parent.close(io_mod.getIo());
        var page_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer page_arena.deinit();
        var page_manager = manager;
        page_manager.alloc = page_arena.allocator();
        const body = try page_manager.contentAt(file.path, revision_id);
        if (!std.mem.eql(u8, try workspace.hash(page_manager.alloc, body), file.sha256)) return error.WorkspaceProjectionConflict;
        try atomicWrite(manager.alloc, parent, std.Io.Dir.path.basename(file.path), body, file.executable);
        if (comptime !@import("build_options").libfx) if (io_mod.getenv("FX_E2E_FOSSIL_FAULT")) |point| {
            if (std.mem.eql(u8, point, "projection_after_file")) return error.WorkspaceInjectedFailure;
        };
    }
    for (old) |entry| {
        if (lookup(entries.items, entry.path) != null or fileByPath(local, entry.path) == null) continue;
        var parent = try parentDirectory(manager.alloc, root, entry.path);
        defer parent.close(io_mod.getIo());
        try parent.deleteFile(io_mod.getIo(), std.Io.Dir.path.basename(entry.path));
    }
    try saveBaseline(manager, task, revision_id, entries.items);
}

fn priorEntries(alloc: std.mem.Allocator, previous: ?Baseline, local: []const File) ![]const Entry {
    const saved = previous orelse return &.{};
    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(alloc, saved.entries);
    if (saved.pending) |pending| for (pending.entries) |entry| {
        const observed = fileByPath(local, entry.path) orelse continue;
        const index = for (entries.items, 0..) |prior, index| {
            if (std.mem.eql(u8, prior.path, entry.path)) break index;
        } else null;
        if (index) |i| {
            if (!equal(state(observed), entries.items[i])) entries.items[i] = entry;
        } else try entries.append(alloc, entry);
    };
    return entries.items;
}

/// No baseline advancement occurs before the complete batch is committed. A
/// crash after the commit can retry by matching the canonical desired hashes.
pub fn checkpoint(manager: workspace.Manager, task: workspace.Task) !bool {
    const lease = try manager.projectionLease(task);
    defer lease.release();
    var saved = (try baseline(manager, task)) orelse return error.WorkspaceProjectionMissing;
    if (saved.pending != null) {
        try materialise(manager, task, .{});
        saved = (try baseline(manager, task)) orelse return error.WorkspaceProjectionMissing;
    }
    const local = try localFiles(manager, task);
    var changes: std.ArrayList(workspace.Manager.ContentChange) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    for (local) |file| {
        const prior = lookup(saved.entries, file.path);
        try entries.append(manager.alloc, state(file));
        if (equal(prior, state(file))) continue;
        var parent = try parentDirectory(manager.alloc, try directory(manager, task), file.path);
        defer parent.close(io_mod.getIo());
        try changes.append(manager.alloc, .{ .path = file.path, .content = try changedBytes(manager.alloc, parent, std.Io.Dir.path.basename(file.path), file), .previous_hash = if (prior) |value| value.sha256 else null, .previous_executable = if (prior) |value| value.executable else null, .executable = file.executable });
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
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    const lease = try manager.projectionLease(task);
    defer lease.release();
    try materialise(manager, task, .{ .skill_index = true });
    return try std.Io.Dir.path.join(alloc, &.{ try directory(manager, task), "skills" });
}

/// Hydrate only a requested managed path before ordinary permission preflight.
/// An opaque process can open arbitrary files, so shell execution explicitly
/// hydrates its complete personal view instead of exposing missing placeholders.
/// This changes caches, never canonical content or the tool's permission policy.
pub fn prepareForTool(alloc: std.mem.Allocator, session: ?[]const u8, project: []const u8, name: []const u8, raw: []const u8, cancel_flag: ?*std.atomic.Value(bool)) !void {
    if (comptime builtin.target.cpu.arch.isWasm()) return;
    const id = session orelse return;
    const process_access = std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "run_command");
    const skill = std.mem.eql(u8, name, "skill") or std.mem.eql(u8, name, "install_skill");
    const file = std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file") or std.mem.eql(u8, name, "glob_files") or std.mem.eql(u8, name, "grep_files");
    if (!process_access and !skill and !file) return;
    const arguments = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer arguments.deinit();
    if (arguments.value != .object) return;
    var manager = (try workspace.Manager.bound(alloc)) orelse return;
    var cancelled = std.atomic.Value(bool).init(false);
    manager.operation_control = .{ .cancel = cancel_flag orelse &cancelled, .deadline = .fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(30) }) };
    const task = (try manager.active(id)) orelse return;
    if (task.authority != null) return error.CompanyExecutionIsolationRequired;
    if (!std.mem.eql(u8, project, task.project_root)) return error.TaskProjectMismatch;
    const root = try directory(manager, task);
    var selection: Selection = .{ .all = process_access };
    if (skill) {
        // Discovery reads only SKILL.md. Loading or installing a package makes
        // its executable resources available to the unchanged skill runtime.
        selection.path = "skills";
        if (arguments.value.object.get("name")) |package_name| if (package_name == .string and @import("company_authority.zig").safeIdentity(package_name.string)) {
            selection.path = try alloc.print("skills/{s}", .{package_name.string});
        };
        if (arguments.value.object.get("location")) |location| if (location == .string) {
            const path = try relativeManagedPath(alloc, project, root, location.string);
            if (path) |value| selection.path = std.Io.Dir.path.dirname(value) orelse value;
        };
    } else if (file) {
        const path = arguments.value.object.get("path");
        if (path != null and path.? != .string) return;
        var requested = if (path) |value| value.string else ".";
        if (std.mem.eql(u8, name, "glob_files")) {
            if (arguments.value.object.get("pattern")) |pattern| if (pattern == .string) {
                requested = try std.Io.Dir.path.resolve(alloc, &.{ project, requested, globDirectory(pattern.string) });
            };
        } else if (path == null) return;
        selection.path = (try relativeManagedPath(alloc, project, root, requested)) orelse return;
    }
    const lease = try manager.projectionLease(task);
    defer lease.release();
    try materialise(manager, task, selection);
}

fn globDirectory(pattern: []const u8) []const u8 {
    var end = pattern.len;
    for (pattern, 0..) |byte, index| if (byte == '*' or byte == '?' or byte == '[' or byte == '{') {
        end = index;
        break;
    };
    const slash = std.mem.findScalarLast(u8, pattern[0..end], '/') orelse return ".";
    return pattern[0..@max(slash, 1)];
}

fn relativeManagedPath(alloc: std.mem.Allocator, project: []const u8, root: []const u8, input: []const u8) !?[]const u8 {
    const resolved = try std.Io.Dir.path.resolve(alloc, &.{ project, input });
    if (std.mem.eql(u8, root, resolved)) return "";
    if (!std.mem.startsWith(u8, resolved, root) or resolved.len <= root.len or resolved[root.len] != '/') return null;
    const path = resolved[root.len + 1 ..];
    for (roots) |prefix| if (std.mem.eql(u8, path, prefix[0 .. prefix.len - 1]) or std.mem.startsWith(u8, path, prefix)) return path;
    return null;
}

test "sparse projection selection respects path components and skill indexes" {
    try std.testing.expectEqualStrings("/Users/example/view/documents", globDirectory("/Users/example/view/documents/**/*.md"));
    try std.testing.expectEqualStrings("documents", globDirectory("documents/one.txt"));
    try std.testing.expectEqualStrings(".", globDirectory("*.md"));
    try std.testing.expect((Selection{ .path = "documents/one" }).includes("documents/one"));
    try std.testing.expect((Selection{ .path = "documents/one" }).includes("documents/one/a.txt"));
    try std.testing.expect(!(Selection{ .path = "documents/one" }).includes("documents/one-other/a.txt"));
    try std.testing.expect((Selection{ .skill_index = true }).includes("skills/career/SKILL.md"));
    try std.testing.expect(!(Selection{ .skill_index = true }).includes("skills/career/data.json"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const root = "/Users/example/project/.fx/workspaces/workspace/task";
    try std.testing.expectEqualStrings("documents/a.txt", (try relativeManagedPath(alloc, "/Users/example/project", root, ".fx/workspaces/workspace/task/documents/a.txt")).?);
    try std.testing.expect((try relativeManagedPath(alloc, "/Users/example/project", root, ".fx/workspaces/workspace/task-other/documents/a.txt")) == null);
    try std.testing.expect((try relativeManagedPath(alloc, "/Users/example/project", root, ".fx/workspaces/workspace/task/documents/../../outside.txt")) == null);
}

test "sparse projection recovers fetched pending entries without inventing deletions or losing edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const saved = Baseline{ .workspace = "workspace", .task = "task", .revision = "before", .entries = &.{.{ .path = "documents/old", .sha256 = "old" }}, .pending = .{ .revision = "after", .entries = &.{
        .{ .path = "documents/old", .sha256 = "new" },
        .{ .path = "documents/fetched", .sha256 = "canonical" },
        .{ .path = "documents/unfetched", .sha256 = "canonical" },
    } } };
    const local = [_]File{
        .{ .path = "documents/old", .sha256 = "old", .bytes = 3, .executable = false },
        .{ .path = "documents/fetched", .sha256 = "unsaved-edit", .bytes = 12, .executable = false },
    };
    const recovered = try priorEntries(alloc, saved, &local);
    try std.testing.expectEqual(@as(usize, 2), recovered.len);
    try std.testing.expectEqualStrings("old", lookup(recovered, "documents/old").?.sha256);
    try std.testing.expectEqualStrings("canonical", lookup(recovered, "documents/fetched").?.sha256);
    try std.testing.expect(lookup(recovered, "documents/unfetched") == null);
    // An already known file that was deleted stays known, unlike an unfetched
    // pending file; checkpointing can retain that deliberate local deletion.
    const deleted = try priorEntries(alloc, saved, &.{});
    try std.testing.expectEqual(@as(usize, 1), deleted.len);
    try std.testing.expect(lookup(deleted, "documents/old") != null);
}

test "filesystem projection scans bodies with bounded metadata allocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var payload: [65537]u8 = @splat('x');
    payload[payload.len - 1] = 'z';
    var file = try temporary.dir.createFile(std.testing.io, "input.txt", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, &payload);
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const observed = try readFile(fixed.allocator(), temporary.dir, "input.txt", "documents/input.txt");
    try std.testing.expectEqual(payload.len, observed.bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&payload, &digest, .{});
    const hex = std.fmt.bytesToHex(&digest, .lower);
    try std.testing.expectEqualStrings(&hex, observed.sha256);
    const body = try changedBytes(std.testing.allocator, temporary.dir, "input.txt", observed);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualSlices(u8, &payload, body);
    payload[0] = 'y';
    var replacement = try temporary.dir.createFile(std.testing.io, "input.txt", .{});
    defer replacement.close(std.testing.io);
    try replacement.writeStreamingAll(std.testing.io, &payload);
    try std.testing.expectError(error.WorkspaceProjectionConflict, changedBytes(std.testing.allocator, temporary.dir, "input.txt", observed));
}

test "resource pin ownership allows descendants and rejects unrelated or company task scopes" {
    const Source = struct {
        task: workspace.Task,
        fn loadTask(self: @This(), id: []const u8) !workspace.Task {
            if (!std.mem.eql(u8, self.task.id, id)) return error.WorkspaceAccessDenied;
            return self.task;
        }
    };
    var parent = workspace.Task{ .id = "parent", .workspace_id = "workspace", .session = "root-owner", .branch = "task/parent", .base_revision = "base", .project_root = "/Users/example/project", .definition = .{ .id = "contract", .version = 1, .objective = "Retain the view", .obligations = &.{} } };
    var child = parent;
    child.id = "child";
    child.session = "child-owner";
    child.parent_task_id = parent.id;
    try verifyRetentionOwner(child, "root-owner", parent.project_root, Source{ .task = parent });
    try std.testing.expectError(error.WorkspaceAccessDenied, verifyRetentionOwner(child, "unrelated-owner", parent.project_root, Source{ .task = parent }));
    try std.testing.expectError(error.TaskProjectMismatch, verifyRetentionOwner(child, "root-owner", "/Users/example/other-project", Source{ .task = parent }));
    parent.authority = .{ .actor = "company-actor", .grant = "company-grant" };
    try std.testing.expectError(error.CompanyExecutionIsolationRequired, verifyRetentionOwner(child, "root-owner", parent.project_root, Source{ .task = parent }));
    try std.testing.expectError(error.CompanyExecutionIsolationRequired, verifyRetentionOwner(child, "child-owner", child.project_root, Source{ .task = parent }));
    parent.authority = null;
    // The independently authenticated terminal grant fixes the selected task's
    // project. A parent contract can delegate work in another project.
    parent.project_root = "/Users/example/parent-project";
    try verifyRetentionOwner(child, "root-owner", child.project_root, Source{ .task = parent });
    parent.project_root = child.project_root;
    parent.parent_task_id = parent.id;
    parent.session = "cycle";
    try std.testing.expectError(error.WorkspaceAccessDenied, verifyRetentionOwner(child, "root-owner", parent.project_root, Source{ .task = parent }));
}

test "resource pin follows the physical view across profile caches" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const project = try io_mod.dirRealpathAlloc(alloc, temporary.dir, ".");
    var manager = workspace.Manager{ .alloc = alloc, .repository = "/Users/example/original.fossil", .root = "/Users/example/cache/original", .manifest = .{ .id = "workspace", .format = 2 } };
    const task = workspace.Task{ .id = "task", .workspace_id = "workspace", .session = "owner", .branch = "task/task", .base_revision = "base", .project_root = project, .definition = .{ .id = "contract", .version = 1, .objective = "Retain the view", .obligations = &.{} } };
    const first = try retentionPath(manager, task);
    manager.root = "/Users/example/cache/copied";
    const second = try retentionPath(manager, task);
    try std.testing.expectEqualStrings(first, second);
    const pin = try @import("../shared/resource_pin.zig").acquire(first, null);
    try std.testing.expect((try @import("../shared/resource_pin.zig").tryExclusive(second)) == null);
    pin.close();
    const exclusive = (try @import("../shared/resource_pin.zig").tryExclusive(second)) orelse return error.TestExpectedExclusiveLease;
    exclusive.close();
}

test "filesystem projection isolates copied bindings and retains owned legacy drafts" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const project = try io_mod.dirRealpathAlloc(alloc, temporary.dir, ".");
    var manager = workspace.Manager{ .alloc = alloc, .repository = "/Users/example/original.fossil", .root = try std.Io.Dir.path.join(alloc, &.{ project, "cache" }), .manifest = .{ .id = "workspace", .format = 2 } };
    const task = workspace.Task{ .id = "task", .workspace_id = "workspace", .session = "owner", .branch = "task/task", .base_revision = "base", .project_root = project, .definition = .{ .id = "contract", .version = 1, .objective = "Retain drafts", .obligations = &.{} } };
    const first = try directory(manager, task);
    manager.repository = "/Users/example/copied.fossil";
    try std.testing.expect(!std.mem.eql(u8, first, try directory(manager, task)));
    const legacy = try std.Io.Dir.path.join(alloc, &.{ project, ".fx", "workspaces", "workspace", "task" });
    const marker = try projectionRecord(manager, legacy);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), std.Io.Dir.path.dirname(marker).?, .fromMode(0o700));
    var record = try std.Io.Dir.cwd().createFile(io_mod.getIo(), marker, .{});
    record.close(io_mod.getIo());
    try std.testing.expectEqualStrings(legacy, try directory(manager, task));
    try std.testing.expect(!std.mem.eql(u8, legacy, first));
}
