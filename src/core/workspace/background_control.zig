//! Private activation and transport state. These files grant local execution;
//! portable dispatch metadata alone never activates work on a restored host.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const background = @import("background_contract.zig");
const io = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const provider = @import("../config/model_provider.zig");
const record_json = @import("../shared/record_json.zig");

pub const Authority = struct {
    version: []const u8 = "omos.background-activation/v1",
    workspace: []const u8,
    task: []const u8,
    operation: []const u8,
    request_sha256: []const u8,
    permission_mode: types.PermissionMode,
    provider: provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    root_user_context: []const u8,
    root_user_messages: []const []const u8,
    root_user_evidence_complete: bool,
    images: []const types.ImageAttachment = &.{},
    source_session: []const u8,
    project_root: []const u8,
    policy_sha256: []const u8,
    session_permission_sha256: []const u8,
    permission_rules: types.PermissionRuleSet,
    session_rules: []const @import("../permissions/session_permission_state.zig").Rule,
    session_generation: u64,
};

pub const Command = struct {
    version: []const u8 = "omos.background-control/v1",
    operation: []const u8,
    workspace: []const u8,
    task: []const u8,
    generation: u64,
    action: enum { message, steer, cancel, answer, validation },
    text: []const u8 = "",
    request_id: usize = 0,
    approved: ?bool = null,
    answers: ?[]const []const u8 = null,
    receipt: ?std.json.Value = null,
};

pub fn directory(manager: workspace.Manager) ![]const u8 {
    return std.Io.Dir.path.join(manager.alloc, &.{ manager.root, "background" });
}

pub fn path(manager: workspace.Manager, area: []const u8, name: []const u8) ![]const u8 {
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidBackgroundPath;
    if (name.len == 0 or std.mem.find(u8, name, "..") != null) return error.InvalidBackgroundPath;
    const parent = try std.Io.Dir.path.join(manager.alloc, &.{ try directory(manager), area });
    try std.Io.Dir.cwd().createDirPath(io.getIo(), parent);
    return std.Io.Dir.path.join(manager.alloc, &.{ parent, name });
}

pub fn read(manager: workspace.Manager, file_path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io.getIo(), file_path, .{ .follow_symlinks = false });
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.BackgroundAuthorityUnsafe;
    return io.readFileToEnd(manager.alloc, &file, 512 * 1024);
}

fn write(manager: workspace.Manager, file_path: []const u8, bytes: []const u8) !void {
    if (bytes.len > 512 * 1024) return error.BackgroundControlTooLarge;
    // Serialize publishers, then atomically rename a fully synced file. A
    // consumer must never observe a partial authority or control record.
    const lock_path = try manager.alloc.print("{s}.lock", .{file_path});
    var lock = try std.Io.Dir.createFileAbsolute(io.getIo(), lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(io.getIo());
    try lock.lock(io.getIo(), .exclusive);
    defer lock.unlock(io.getIo());
    if (read(manager, file_path)) |_| return error.PathAlreadyExists else |err| if (err != error.FileNotFound) return err;
    const temporary = try manager.alloc.print("{s}.pending", .{file_path});
    var file = try std.Io.Dir.createFileAbsolute(io.getIo(), temporary, .{ .permissions = .fromMode(0o600) });
    defer file.close(io.getIo());
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io.getIo(), &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.sync(io.getIo());
    try std.Io.Dir.renameAbsolute(temporary, file_path, io.getIo());
}

pub fn claimCommand(manager: workspace.Manager, command: Command) !bool {
    write(manager, try path(manager, "claimed", command.operation), "Execution claimed; an absent result requires explicit reconciliation.") catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    return true;
}

pub fn finishCommand(manager: workspace.Manager, command: Command, failure: ?[]const u8) !void {
    try write(manager, try path(manager, "receipts", command.operation), try std.json.Stringify.valueAlloc(manager.alloc, .{ .operation = command.operation, .task = command.task, .generation = command.generation, .applied = failure == null, .failure = failure }, .{}));
    // Completed operations stay inspectable without being reparsed by every
    // active worker on every polling tick.
    const name = try manager.alloc.print("{s}.json", .{command.operation});
    try std.Io.Dir.renameAbsolute(try path(manager, "controls", name), try path(manager, "requests", name), io.getIo());
}

pub fn activate(manager: workspace.Manager, entry: background.Record, authority: Authority) !void {
    try background.validate(entry);
    if (!std.mem.eql(u8, authority.version, "omos.background-activation/v1") or
        !std.mem.eql(u8, entry.workspace, authority.workspace) or
        !std.mem.eql(u8, entry.task, authority.task) or
        !std.mem.eql(u8, entry.operation, authority.operation) or
        !std.mem.eql(u8, entry.request_sha256, authority.request_sha256)) return error.BackgroundAuthorityMismatch;
    const file_path = try path(manager, "authority", try manager.alloc.print("{s}.json", .{entry.operation}));
    var captured = authority;
    if (authority.images.len > 0) {
        const snapshot_dir = try path(manager, "images", entry.operation);
        const images = try manager.alloc.alloc(types.ImageAttachment, authority.images.len);
        for (authority.images, images) |source, *image| {
            image.* = try @import("../images/image_attachments.zig").copyVerifiedImageAttachmentToDir(manager.alloc, source, source.id, snapshot_dir);
        }
        captured.images = images;
    }
    const bytes = try std.json.Stringify.valueAlloc(manager.alloc, captured, .{});
    write(manager, file_path, bytes) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!std.mem.eql(u8, bytes, try read(manager, file_path))) return error.BackgroundAuthorityChanged;
        },
        else => return err,
    };
}

pub fn activation(manager: workspace.Manager, entry: background.Record) !?Authority {
    const bytes = read(manager, try path(manager, "authority", try manager.alloc.print("{s}.json", .{entry.operation}))) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const authority = try record_json.decode(Authority, manager.alloc, bytes, .{});
    if (!std.mem.eql(u8, authority.version, "omos.background-activation/v1") or
        !std.mem.eql(u8, entry.workspace, authority.workspace) or
        !std.mem.eql(u8, entry.task, authority.task) or
        !std.mem.eql(u8, entry.operation, authority.operation) or
        !std.mem.eql(u8, entry.request_sha256, authority.request_sha256)) return error.BackgroundAuthorityMismatch;
    return authority;
}

pub fn enqueue(manager: workspace.Manager, command: Command) !void {
    if (!std.mem.eql(u8, command.version, "omos.background-control/v1") or
        !std.mem.eql(u8, command.workspace, manager.manifest.id) or command.operation.len != 64 or
        command.task.len != 64 or command.text.len > 65536 or !std.unicode.utf8ValidateSlice(command.text)) return error.InvalidBackgroundControl;
    const file_path = try path(manager, "controls", try manager.alloc.print("{s}.json", .{command.operation}));
    const bytes = try std.json.Stringify.valueAlloc(manager.alloc, command, .{});
    if (read(manager, file_path)) |existing| {
        if (!std.mem.eql(u8, existing, bytes)) return error.BackgroundOperationConflict;
        return;
    } else |err| if (err != error.FileNotFound) return err;
    const archived = try path(manager, "requests", try manager.alloc.print("{s}.json", .{command.operation}));
    if (read(manager, archived)) |existing| {
        if (!std.mem.eql(u8, existing, bytes)) return error.BackgroundOperationConflict;
        return;
    } else |err| if (err != error.FileNotFound) return err;
    const entry = (try manager.backgroundRecord(command.task)) orelse return error.BackgroundDispatchRequired;
    if (entry.state != .running or entry.generation != command.generation) return error.StaleBackgroundOwner;
    write(manager, file_path, bytes) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!std.mem.eql(u8, bytes, try read(manager, file_path))) return error.BackgroundOperationConflict;
        },
        else => return err,
    };
}

pub fn loadCommand(manager: workspace.Manager, file_path: []const u8) !Command {
    return record_json.decode(Command, manager.alloc, try read(manager, file_path), .{});
}

/// A short-lived launcher creates the long-lived host, then exits. Its caller
/// reaps the launcher; the worker is independent of foreground turn lifetime.
pub fn ensureHost(manager: workspace.Manager) !void {
    const lock_path = try path(manager, "", "host.lock");
    var lock = try std.Io.Dir.createFileAbsolute(io.getIo(), lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(io.getIo());
    if (!try lock.tryLock(io.getIo(), .exclusive)) return;
    lock.unlock(io.getIo());
    const executable = try std.process.executablePathAlloc(io.getIo(), manager.alloc);
    const result = try std.process.run(manager.alloc, io.getIo(), .{ .argv = &.{ executable, "ui-host", "--background-start" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    defer manager.alloc.free(result.stdout);
    defer manager.alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.BackgroundHostUnavailable;
}

pub fn launchHost(manager: workspace.Manager) !void {
    const lock_path = try path(manager, "", "host.lock");
    var lock = try std.Io.Dir.createFileAbsolute(io.getIo(), lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(io.getIo());
    if (!try lock.tryLock(io.getIo(), .exclusive)) return;
    lock.unlock(io.getIo());
    const executable = try std.process.executablePathAlloc(io.getIo(), manager.alloc);
    _ = try std.process.spawn(io.getIo(), .{ .argv = &.{ executable, "ui-host", "--background-serve" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    const until = io.milliTimestamp() + 5000;
    while (io.milliTimestamp() < until) {
        if (!try lock.tryLock(io.getIo(), .exclusive)) return;
        lock.unlock(io.getIo());
        io.sleep(20 * std.time.ns_per_ms);
    }
    return error.BackgroundHostUnavailable;
}

/// Captures permission and integration configuration, excluding theme, model
/// selection and unrelated interaction preferences. Only the digest is retained.
pub fn policyDigest(manager: workspace.Manager, project: []const u8) ![]const u8 {
    const home = io.getenv("HOME") orelse return error.HomeUnavailable;
    const paths = @import("../shared/profile_paths.zig");
    var selected: std.ArrayList(std.json.Value) = .empty;
    for ([_][]const u8{ try paths.settingsPath(manager.alloc, home), try paths.mcpConfigPath(manager.alloc, home), try std.Io.Dir.path.join(manager.alloc, &.{ project, ".fx.json" }), try std.Io.Dir.path.join(manager.alloc, &.{ project, ".mcp.json" }) }) |file_path| {
        var file = std.Io.Dir.openFileAbsolute(io.getIo(), file_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io.getIo());
        const data = try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try io.readFileToEnd(manager.alloc, &file, 8 * 1024 * 1024), .{});
        if (std.mem.endsWith(u8, file_path, "mcp.json")) try selected.append(manager.alloc, data) else try selectPolicy(manager.alloc, data, &selected);
    }
    return workspace.hash(manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, selected.items, .{}));
}

fn selectPolicy(arena: std.mem.Allocator, node: std.json.Value, selected: *std.ArrayList(std.json.Value)) !void {
    if (node != .object) return;
    var iterator = node.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.find(u8, key, "permission") != null or std.mem.find(u8, key, "trust") != null or std.mem.find(u8, key, "sandbox") != null or std.mem.eql(u8, key, "providers") or std.mem.eql(u8, key, "allowlist")) {
            try selected.append(arena, .{ .string = key });
            try selected.append(arena, entry.value_ptr.*);
        } else try selectPolicy(arena, entry.value_ptr.*, selected);
    }
}

pub fn verifyLiveAuthority(manager: workspace.Manager, authority: Authority) !void {
    if (!std.mem.eql(u8, authority.policy_sha256, try policyDigest(manager, authority.project_root))) return error.BackgroundPermissionPolicyChanged;
    const adapter = @import("../session/session_adapter.zig");
    var store = try adapter.Store.openFromEnv(manager.alloc);
    defer store.deinit(manager.alloc);
    var state = try adapter.readPermissions(&store, manager.alloc, authority.source_session);
    defer state.deinit(manager.alloc);
    const encoded = try @import("../session/session_codec.zig").encodePermissionState(manager.alloc, state);
    if (!std.mem.eql(u8, authority.session_permission_sha256, try workspace.hash(manager.alloc, encoded))) return error.BackgroundSourcePermissionsChanged;
}
