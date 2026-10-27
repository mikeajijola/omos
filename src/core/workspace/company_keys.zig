//! Issuer power is a protected installation resource, not portable company
//! content. Its atomic descriptor binds a key to one repository and epoch.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const Descriptor = struct {
    version: []const u8 = "omos.company-issuer/v1",
    workspace: []const u8,
    repository: []const u8,
    epoch: u64,
    public_key: []const u8,
    seed_file: []const u8,
    control_revision: ?[]const u8 = null,
    accepted_revision: ?[]const u8 = null,
};

pub fn directory(manager: workspace.Manager) ![]const u8 {
    return std.Io.Dir.path.join(manager.alloc, &.{ io.getenv("HOME") orelse return error.HomeUnavailable, ".fx", "authority", manager.manifest.id });
}

fn open(manager: workspace.Manager) !io.VerifiedDir {
    const path = try directory(manager);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io.getIo(), path, .fromMode(0o700));
    var parent = try io.openDirAbsoluteNoFollow(path, .{ .iterate = true });
    errdefer parent.close(io.getIo());
    try parent.setPermissions(io.getIo(), .fromMode(0o700));
    return .{ .dir = parent };
}

fn descriptor(manager: workspace.Manager, dir: std.Io.Dir) !?Descriptor {
    var file = dir.openFile(io.getIo(), "issuer.json", .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io.getIo());
    const value = try records.decode(Descriptor, manager.alloc, try io.readFileToEnd(manager.alloc, &file, 16384), .{});
    if (!std.mem.eql(u8, value.version, "omos.company-issuer/v1") or !std.mem.eql(u8, value.workspace, manager.manifest.id) or value.public_key.len != 64 or value.epoch == 0) return error.CompanyIssuerRecoveryRequired;
    for (value.public_key) |ch| if (!std.ascii.isHex(ch)) return error.CompanyIssuerRecoveryRequired;
    if (!std.mem.eql(u8, value.seed_file, try manager.alloc.print("issuer-{s}.seed", .{value.public_key}))) return error.CompanyIssuerRecoveryRequired;
    if ((value.control_revision == null) != (value.accepted_revision == null)) return error.CompanyIssuerRecoveryRequired;
    if (value.control_revision) |head| if (!@import("fossil_manifest.zig").validHash(head)) return error.CompanyIssuerRecoveryRequired;
    if (value.accepted_revision) |head| if (!@import("fossil_manifest.zig").validHash(head)) return error.CompanyIssuerRecoveryRequired;
    return value;
}

fn issuerLock(manager: workspace.Manager, dir: std.Io.Dir) !workspace.ExecutionLease {
    if (manager.operation_control) |control| try control.check();
    const file = dir.openFile(io.getIo(), "issuer.lock", .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io.getIo(), "issuer.lock", .{ .exclusive = true, .truncate = false, .permissions = .fromMode(0o600) }) catch |created| switch (created) {
            error.PathAlreadyExists => try dir.openFile(io.getIo(), "issuer.lock", .{ .mode = .read_write, .follow_symlinks = false }),
            else => return created,
        },
        else => return err,
    };
    errdefer file.close(io.getIo());
    var attempts: usize = 0;
    while (!try file.tryLock(io.getIo(), .exclusive)) {
        if (manager.operation_control) |control| try control.check();
        if (attempts >= 3000) return error.WorkspaceBusy;
        attempts += 1;
        if (manager.operation_control != null) try io.getIo().sleep(.fromMilliseconds(10), .awake) else io.sleep(10 * std.time.ns_per_ms);
    }
    return .{ .file = file };
}

fn readKey(manager: workspace.Manager, dir: std.Io.Dir, value: Descriptor) !Ed25519.KeyPair {
    var file = try dir.openFile(io.getIo(), value.seed_file, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    if ((try file.stat(io.getIo())).permissions.toMode() & 0o777 != 0o600) return error.CompanyIssuerPermissionsUnsafe;
    const bytes = try io.readFileToEnd(manager.alloc, &file, 33);
    if (bytes.len != 32) return error.CompanyIssuerRecoveryRequired;
    const key = try Ed25519.KeyPair.generateDeterministic(bytes[0..32].*);
    const public = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    if (!std.mem.eql(u8, &public, value.public_key)) return error.CompanyIssuerRecoveryRequired;
    return key;
}

pub fn current(original: workspace.Manager, epoch: u64, public_key: []const u8) !Ed25519.KeyPair {
    var manager = original;
    // Snapshot reads must still validate signing authority against live heads.
    manager.company_read_revision = null;
    manager.company_revision_cache = null;
    var dir = try open(manager);
    defer dir.close();
    const lease = try issuerLock(manager, dir.dir);
    defer lease.release();
    var value = (try descriptor(manager, dir.dir)) orelse return error.CompanyIssuerRecoveryRequired;
    if (!std.mem.eql(u8, value.repository, manager.repository)) return error.CompanyIssuerBoundElsewhere;
    if (value.epoch > epoch) return error.CompanyAuthorityRollbackDetected;
    if (value.epoch != epoch or !std.mem.eql(u8, value.public_key, public_key)) return error.CompanyIssuerRecoveryRequired;
    const key = try readKey(manager, dir.dir, value);
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const accepted = try manager.revision("trunk");
    if (value.control_revision) |previous| if (!try manager.revisionDescendsFrom(control, previous)) return error.CompanyAuthorityRollbackDetected;
    if (value.accepted_revision) |previous| if (!try manager.revisionDescendsFrom(accepted, previous)) return error.CompanyAuthorityRollbackDetected;
    if (value.control_revision == null or !std.mem.eql(u8, value.control_revision.?, control) or !std.mem.eql(u8, value.accepted_revision.?, accepted)) {
        value.control_revision = control;
        value.accepted_revision = accepted;
        try io.durableReplaceVerified(manager.alloc, &dir, "issuer.json", try std.json.Stringify.valueAlloc(manager.alloc, value, .{}));
    }
    return key;
}

/// Advance protected observed heads after a committed company effect and
/// before acknowledging it. A crash between these writes catches up only
/// along retained ancestry; restoring an older repository requires recovery.
pub fn observe(original: workspace.Manager) !void {
    var manager = original;
    manager.company_read_revision = null;
    manager.company_revision_cache = null;
    const authority = try records.decode(@import("company_authority.zig").State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    _ = try current(manager, authority.epoch, authority.issuer);
}

pub fn nextEpoch(manager: workspace.Manager, canonical: u64) !u64 {
    var dir = try open(manager);
    defer dir.close();
    const previous = try descriptor(manager, dir.dir);
    return std.math.add(u64, @max(canonical, if (previous) |value| value.epoch else 0), 1);
}

/// The protected descriptor names the last active source. An operator cannot
/// replace it with a stale local copy while checkpoints or review advance it.
pub fn recoveryLease(manager: workspace.Manager) !?workspace.ExecutionLease {
    var dir = try open(manager);
    defer dir.close();
    const previous = (try descriptor(manager, dir.dir)) orelse return null;
    if (std.mem.eql(u8, previous.repository, manager.repository)) return null;
    const source = workspace.Manager.open(manager.alloc, previous.repository) catch return error.CompanyRecoverySourceUnavailable;
    if (!std.mem.eql(u8, source.manifest.id, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    const lease = try source.snapshotLease();
    errdefer lease.release();
    if (!std.mem.eql(u8, try source.repositoryFingerprint(), try manager.repositoryFingerprint())) return error.CompanyRecoverySourceAdvanced;
    return lease;
}

/// Callers hold the global company operation lease through the subsequent
/// canonical authority update. Interrupted descriptor publication can retry.
pub fn prepare(manager: workspace.Manager, epoch: u64, replace: bool) !Ed25519.KeyPair {
    var dir = try open(manager);
    defer dir.close();
    const lease = try issuerLock(manager, dir.dir);
    defer lease.release();
    if (try descriptor(manager, dir.dir)) |previous| {
        if (previous.epoch == epoch and std.mem.eql(u8, previous.repository, manager.repository)) return readKey(manager, dir.dir, previous);
        if (!replace) return error.CompanyIssuerBoundElsewhere;
        if (previous.epoch >= epoch) return error.CompanyAuthorityRollbackDetected;
    }
    const key = Ed25519.KeyPair.generate(io.getIo());
    const public = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    const filename = try manager.alloc.print("issuer-{s}.seed", .{public});
    var nonce: [16]u8 = undefined;
    io.getIo().random(&nonce);
    const temporary = try manager.alloc.print("issuer.pending-{s}", .{std.fmt.bytesToHex(&nonce, .lower)});
    var file = try dir.dir.createFile(io.getIo(), temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io.getIo());
    defer dir.dir.deleteFile(io.getIo(), temporary) catch {};
    try file.writeStreamingAll(io.getIo(), &key.secret_key.seed());
    try file.sync(io.getIo());
    try std.Io.Dir.hardLink(dir.dir, temporary, dir.dir, filename, io.getIo(), .{});
    const handle: std.Io.File = .{ .handle = dir.dir.handle, .flags = .{ .nonblocking = false } };
    try handle.sync(io.getIo());
    try fault("issuer-key-prepared");
    const value: Descriptor = .{ .workspace = manager.manifest.id, .repository = manager.repository, .epoch = epoch, .public_key = &public, .seed_file = filename };
    try io.durableReplaceVerified(manager.alloc, &dir, "issuer.json", try std.json.Stringify.valueAlloc(manager.alloc, value, .{}));
    try fault("issuer-binding-published");
    return key;
}

fn fault(stage: []const u8) !void {
    if (io.getenv("FX_E2E_FOSSIL_FAULT")) |selected| if (std.mem.eql(u8, selected, stage)) return error.WorkspaceInjectedFailure;
}
