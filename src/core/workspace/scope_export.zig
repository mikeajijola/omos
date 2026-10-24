//! Permission-scoped file snapshots. Content hashes and signed inventory pages
//! prove the archive's declared contents; capability dependency closure remains
//! an explicit, separate requirement.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const authority = @import("company_authority.zig");
const identity = @import("company_identity.zig");
const client = @import("workspace_client.zig");
const workspace = @import("fossil_workspace.zig");
const object_cache = @import("object_cache.zig");

const Config = struct {
    version: []const u8,
    endpoint: []const u8,
    workspace: []const u8,
    actor: []const u8,
    grant: []const u8,
    key_handle: []const u8,
    issuer: []const u8,
    revision: []const u8,
    view: ?[]const u8 = null,
    max_bytes: u64 = 1024 * 1024 * 1024,
    deadline_ms: u32 = 300_000,
};
const Entry = struct { path: []const u8, sha256: []const u8, bytes: usize, executable: ?bool = null };
const Proof = struct { request: []const u8, receipt: std.json.Value };
const Manifest = struct {
    version: []const u8,
    scope: []const u8,
    dependency_closure: []const u8,
    workspace: []const u8,
    revision: []const u8,
    actor: []const u8,
    grant: []const u8,
    issuer: []const u8,
    epoch: u64,
    files: []const Entry,
    inventory_receipts: []const Proof,
};
const Page = struct {
    version: []const u8,
    workspace: []const u8,
    revision: []const u8,
    actor: []const u8,
    grant: []const u8,
    files: []const Entry,
    total: usize,
    next_offset: ?usize,
};
const Segment = struct {
    executable: bool,
    revision: []const u8,
    path: []const u8,
    exists: bool,
    offset: usize,
    bytes: usize,
    sha256: []const u8,
    content: []const u8,
    encoding: []const u8,
    next_offset: ?usize,
};
pub const Snapshot = struct {
    version: []const u8 = "omos.scope-package/v2",
    file_attributes: enum { verified, unavailable } = .verified,
    path: []const u8,
    workspace: []const u8,
    revision: []const u8,
    files: usize,
    bytes: u64,
    scope: []const u8 = "grant_file_snapshot",
    dependency_closure: []const u8 = "not_evaluated",
    shared_cache: ?object_cache.Stats = null,
};

const Session = struct {
    config: Config,
    company: client.Company,
    key: std.crypto.sign.Ed25519.KeyPair,
    control: client.Control,

    fn check(self: Session) !void {
        if (self.control.cancel.load(.seq_cst)) return error.Cancelled;
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, self.control.deadline)) return error.Timeout;
    }

    fn request(self: Session, alloc: std.mem.Allocator, path: ?[]const u8, offset: usize) !struct { request: []const u8, response: std.json.Value, result: std.json.Value } {
        try self.check();
        var nonce: [16]u8 = undefined;
        io.getIo().random(&nonce);
        const payload = try std.json.Stringify.valueAlloc(alloc, authority.Request{
            .version = "omos.company/v2",
            .workspace = self.config.workspace,
            .actor = self.config.actor,
            .grant = self.config.grant,
            .operation = &std.fmt.bytesToHex(&nonce, .lower),
            .expires_ms = io.milliTimestamp() + 120_000,
            .action = .export_scope,
            .revision = self.config.revision,
            .view = self.config.view,
            .path = path,
            .offset = offset,
        }, .{ .emit_null_optional_fields = false });
        const signature = try self.key.sign(payload, null);
        const raw = try std.json.Stringify.valueAlloc(alloc, authority.Envelope{ .payload = payload, .signature = &std.fmt.bytesToHex(signature.toBytes(), .lower) }, .{});
        const response = try client.companyCallControlled(alloc, self.config.endpoint, self.company, raw, self.control);
        const Claims = struct { payload: []const u8 };
        const envelope = try std.json.parseFromValueLeaky(Claims, alloc, response, .{ .ignore_unknown_fields = true });
        const claims = try records.decode(struct { result: std.json.Value }, alloc, envelope.payload, .{ .ignore_unknown_fields = true });
        return .{ .request = raw, .response = response, .result = claims.result };
    }
};

fn validHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validRevision(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn decodeConfig(alloc: std.mem.Allocator, raw: []const u8) !Config {
    const config = try records.decode(Config, alloc, raw, .{});
    if (!std.mem.eql(u8, config.version, "omos.scope-export-request/v1") or !authority.safeIdentity(config.workspace) or !authority.safeIdentity(config.actor) or !authority.safeIdentity(config.grant) or !validRevision(config.revision) or config.max_bytes == 0 or config.max_bytes > 1024 * 1024 * 1024 * 1024 or config.deadline_ms < 100 or config.deadline_ms > 3_600_000) return error.InvalidScopeExportRequest;
    _ = try authority.hexBytes(32, config.issuer);
    return config;
}

/// Offline integrity is checked against the caller's separate issuer and
/// scope pins. It makes no claim about the grant's present revocation state.
pub fn verify(alloc: std.mem.Allocator, raw: []const u8, archive: []const u8) !Snapshot {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const config = try decodeConfig(alloc, raw);
    var file = try std.Io.Dir.cwd().openFile(io.getIo(), archive, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.size > config.max_bytes + 10000 * 1024 + 16 * 1024 * 1024 + 2048) return error.ScopeExportByteLimit;
    var buffer: [16384]u8 = undefined;
    var reader = file.readerStreaming(io.getIo(), &buffer);
    var names: [256]u8 = undefined;
    var links: [256]u8 = undefined;
    var iterator = std.tar.Iterator.init(&reader.interface, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var objects: std.StringHashMapUnmanaged(usize) = .empty;
    var manifest_bytes: ?[]u8 = null;
    var object_bytes: u64 = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or manifest_bytes != null) return error.InvalidScopePackage;
        if (std.mem.eql(u8, entry.name, "manifest.json")) {
            if (entry.size > 16 * 1024 * 1024) return error.ScopeExportMetadataLimit;
            const bytes = try alloc.alloc(u8, @intCast(entry.size));
            try reader.interface.readSliceAll(bytes);
            iterator.unread_file_bytes = 0;
            manifest_bytes = bytes;
            continue;
        }
        if (!std.mem.startsWith(u8, entry.name, "objects/") or !validHash(entry.name[8..]) or entry.size > 8 * 1024 * 1024 or objects.count() >= 10000) return error.InvalidScopePackage;
        const object_hash = try alloc.dupe(u8, entry.name[8..]);
        const slot = try objects.getOrPut(alloc, object_hash);
        if (slot.found_existing) return error.InvalidScopePackage;
        slot.value_ptr.* = @intCast(entry.size);
        object_bytes += entry.size;
        if (object_bytes > config.max_bytes) return error.ScopeExportByteLimit;
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var remaining = entry.size;
        var chunk: [16384]u8 = undefined;
        while (remaining > 0) {
            const size: usize = @intCast(@min(remaining, chunk.len));
            try reader.interface.readSliceAll(chunk[0..size]);
            digest.update(chunk[0..size]);
            remaining -= size;
        }
        iterator.unread_file_bytes = 0;
        if (!std.mem.eql(u8, object_hash, &std.fmt.bytesToHex(digest.finalResult(), .lower))) return error.ScopeExportHashMismatch;
    }
    const trailing = try reader.interface.allocRemaining(alloc, .limited(1024));
    if (trailing.len != 512 or !std.mem.allEqual(u8, trailing, 0)) return error.InvalidScopePackage;
    const manifest = try records.decode(Manifest, alloc, manifest_bytes orelse return error.InvalidScopePackage, .{});
    const attributes = std.mem.eql(u8, manifest.version, "omos.scope-package/v2");
    if ((!attributes and !std.mem.eql(u8, manifest.version, "omos.scope-package/v1")) or !std.mem.eql(u8, manifest.scope, "grant_file_snapshot") or !std.mem.eql(u8, manifest.dependency_closure, "not_evaluated") or !std.mem.eql(u8, manifest.workspace, config.workspace) or !std.mem.eql(u8, manifest.revision, config.revision) or !std.mem.eql(u8, manifest.actor, config.actor) or !std.mem.eql(u8, manifest.grant, config.grant) or !std.mem.eql(u8, manifest.issuer, config.issuer) or manifest.epoch == 0 or manifest.files.len > 10000 or manifest.inventory_receipts.len > 313) return error.InvalidScopePackage;
    const company: client.Company = .{ .version = "omos.company/v1", .workspace = config.workspace, .issuer = config.issuer, .epoch = manifest.epoch };
    var covered: usize = 0;
    var complete = false;
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var total_bytes: u64 = 0;
    for (manifest.inventory_receipts) |proof| {
        if (complete) return error.InvalidScopePackage;
        try client.verifyCompanyReceipt(alloc, company, proof.request, proof.receipt);
        const envelope = try records.decode(authority.Envelope, alloc, proof.request, .{});
        const request = try records.decode(authority.Request, alloc, envelope.payload, .{});
        if (!std.mem.eql(u8, request.version, if (attributes) "omos.company/v2" else "omos.company/v1") or request.action != .export_scope or request.path != null or request.revision == null or !std.mem.eql(u8, request.revision.?, config.revision) or request.offset != covered or !std.mem.eql(u8, request.actor, config.actor) or !std.mem.eql(u8, request.grant, config.grant) or !equalView(request.view, config.view)) return error.InvalidScopePackage;
        const receipt = try std.json.parseFromValueLeaky(struct { payload: []const u8 }, alloc, proof.receipt, .{ .ignore_unknown_fields = true });
        const claims = try records.decode(struct { result: Page }, alloc, receipt.payload, .{ .ignore_unknown_fields = true });
        const page = claims.result;
        if (!std.mem.eql(u8, page.version, if (attributes) "omos.scoped-export/v2" else "omos.scoped-export/v1") or !std.mem.eql(u8, page.workspace, config.workspace) or !std.mem.eql(u8, page.revision, config.revision) or !std.mem.eql(u8, page.actor, config.actor) or !std.mem.eql(u8, page.grant, config.grant) or page.total != manifest.files.len or page.files.len > 32 or page.files.len > manifest.files.len -| covered) return error.InvalidScopePackage;
        for (page.files) |entry| {
            const expected = manifest.files[covered];
            if (!std.mem.eql(u8, entry.path, expected.path) or !std.mem.eql(u8, entry.sha256, expected.sha256) or entry.bytes != expected.bytes or (if (attributes) entry.executable == null or entry.executable != expected.executable else entry.executable != null or expected.executable != null) or !authority.validPath(entry.path, false) or !validHash(entry.sha256)) return error.InvalidScopePackage;
            const slot = try paths.getOrPut(alloc, try std.ascii.allocLowerString(alloc, entry.path));
            if (slot.found_existing or (objects.get(entry.sha256) orelse return error.InvalidScopePackage) != entry.bytes) return error.InvalidScopePackage;
            try used.put(alloc, entry.sha256, {});
            total_bytes += entry.bytes;
            if (total_bytes > config.max_bytes) return error.ScopeExportByteLimit;
            covered += 1;
        }
        if (page.next_offset) |next| {
            if (page.files.len == 0 or next != covered or covered >= manifest.files.len) return error.InvalidScopePackage;
        } else {
            if (covered != manifest.files.len) return error.InvalidScopePackage;
            complete = true;
        }
    }
    if (!complete or covered != manifest.files.len or used.count() != objects.count()) return error.InvalidScopePackage;
    return .{ .version = manifest.version, .file_attributes = if (attributes) .verified else .unavailable, .path = archive, .workspace = config.workspace, .revision = config.revision, .files = covered, .bytes = total_bytes };
}

fn equalView(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return b != null and std.mem.eql(u8, left, b.?);
    return b == null;
}

fn cached(alloc: std.mem.Allocator, dir: std.Io.Dir, entry: Entry) !?[]u8 {
    var file = dir.openFile(io.getIo(), entry.sha256, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.size != entry.bytes) return null;
    const bytes = try io.readFileToEnd(alloc, &file, 8 * 1024 * 1024);
    if (!std.mem.eql(u8, entry.sha256, try workspace.hash(alloc, bytes))) return null;
    return bytes;
}

fn cacheFailure(err: anyerror) !void {
    switch (err) {
        error.OutOfMemory, error.Cancelled, error.Timeout => return err,
        else => @import("../shared/debug_trace.zig").logf("workspace", "Shared object cache unavailable: {s}", .{@errorName(err)}),
    }
}

fn download(session: Session, alloc: std.mem.Allocator, dir: std.Io.Dir, shared_cache: ?*object_cache.Cache, entry: Entry) ![]u8 {
    if (try cached(alloc, dir, entry)) |bytes| return bytes;
    const reference: object_cache.Reference = .{ .sha256 = entry.sha256, .bytes = entry.bytes };
    if (shared_cache) |cache| if (cache.load(alloc, reference) catch |err| miss: {
        try cacheFailure(err);
        break :miss null;
    }) |bytes| return bytes;
    const bytes = try alloc.alloc(u8, entry.bytes);
    var offset: usize = 0;
    while (true) {
        var page_arena = std.heap.ArenaAllocator.init(alloc);
        defer page_arena.deinit();
        const a = page_arena.allocator();
        const response = try session.request(a, entry.path, offset);
        const segment = try std.json.parseFromValueLeaky(Segment, a, response.result, .{ .ignore_unknown_fields = true });
        if (segment.executable != entry.executable or !segment.exists or !std.mem.eql(u8, segment.revision, session.config.revision) or !std.mem.eql(u8, segment.path, entry.path) or !std.mem.eql(u8, segment.sha256, entry.sha256) or segment.bytes != entry.bytes or segment.offset != offset or !std.mem.eql(u8, segment.encoding, "base64")) return error.InvalidScopeExportSegment;
        const size = try std.base64.standard.Decoder.calcSizeForSlice(segment.content);
        if (size > 16384 or size > bytes.len - offset or (size == 0 and offset != bytes.len)) return error.InvalidScopeExportSegment;
        try std.base64.standard.Decoder.decode(bytes[offset..][0..size], segment.content);
        offset += size;
        if (offset == bytes.len) {
            if (segment.next_offset != null) return error.InvalidScopeExportSegment;
            break;
        }
        if (segment.next_offset == null or segment.next_offset.? != offset) return error.InvalidScopeExportSegment;
    }
    if (!std.mem.eql(u8, entry.sha256, try workspace.hash(alloc, bytes))) return error.ScopeExportHashMismatch;
    if (shared_cache) |cache| cache.save(alloc, reference, bytes) catch |err| try cacheFailure(err);
    // Cache only complete, verified objects. An interrupted download is retried
    // from zero; previously completed objects are reusable after a fresh grant check.
    var nonce: [16]u8 = undefined;
    io.getIo().random(&nonce);
    const pending = try alloc.print("object-{s}.pending", .{std.fmt.bytesToHex(&nonce, .lower)});
    var file = try dir.createFile(io.getIo(), pending, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io.getIo());
    defer dir.deleteFile(io.getIo(), pending) catch {};
    try file.writeStreamingAll(io.getIo(), bytes);
    try file.sync(io.getIo());
    // Replace a corrupt cache entry without following it. The parent is private.
    try dir.rename(pending, dir, entry.sha256, io.getIo());
    return bytes;
}

pub fn write(alloc: std.mem.Allocator, raw: []const u8, destination: []const u8) !Snapshot {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const config = try decodeConfig(alloc, raw);
    if (destination.len == 0) return error.MissingPath;
    if (std.Io.Dir.cwd().statFile(io.getIo(), destination, .{ .follow_symlinks = false })) |_| return error.WorkspaceAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var cancel = std.atomic.Value(bool).init(false);
    const control: client.Control = .{ .cancel = &cancel, .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromMilliseconds(config.deadline_ms)) } };
    var key = try identity.load(alloc, config.key_handle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));
    const company = try client.companyBootstrapControlled(alloc, config.endpoint, control);
    if (!std.mem.eql(u8, company.workspace, config.workspace) or !std.mem.eql(u8, company.issuer, config.issuer)) return error.WorkspaceIdentityMismatch;
    const features = company.features orelse return error.CompanyDefinitionUpdateRequired;
    if (!std.mem.eql(u8, features.file_attributes orelse return error.CompanyDefinitionUpdateRequired, "omos.company/v2")) return error.CompanyDefinitionUpdateRequired;
    const session: Session = .{ .config = config, .company = company, .key = key, .control = control };
    var entries: std.ArrayList(Entry) = .empty;
    var receipts: std.ArrayList(std.json.Value) = .empty;
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    var total_bytes: u64 = 0;
    var metadata_bytes: usize = 0;
    var offset: usize = 0;
    var total: ?usize = null;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const response = try session.request(a, null, offset);
        const page = try std.json.parseFromValueLeaky(Page, a, response.result, .{ .ignore_unknown_fields = true });
        if (!std.mem.eql(u8, page.version, "omos.scoped-export/v2") or !std.mem.eql(u8, page.workspace, config.workspace) or !std.mem.eql(u8, page.revision, config.revision) or !std.mem.eql(u8, page.actor, config.actor) or !std.mem.eql(u8, page.grant, config.grant) or page.files.len > 32 or page.total > 10000 or page.files.len > page.total -| offset or (total != null and total.? != page.total)) return error.InvalidScopeExportInventory;
        total = page.total;
        const proof = try std.json.Stringify.valueAlloc(a, .{ .request = response.request, .receipt = response.response }, .{});
        metadata_bytes += proof.len;
        if (metadata_bytes > 8 * 1024 * 1024) return error.ScopeExportMetadataLimit;
        try receipts.append(alloc, try std.json.parseFromSliceLeaky(std.json.Value, alloc, proof, .{ .allocate = .alloc_always }));
        for (page.files) |entry| {
            if (entry.executable == null or !authority.validPath(entry.path, false) or !validHash(entry.sha256) or entry.bytes > 8 * 1024 * 1024) return error.InvalidScopeExportInventory;
            const lower = try std.ascii.allocLowerString(alloc, entry.path);
            const slot = try paths.getOrPut(alloc, lower);
            if (slot.found_existing) return error.InvalidScopeExportInventory;
            total_bytes += entry.bytes;
            if (total_bytes > config.max_bytes) return error.ScopeExportByteLimit;
            try entries.append(alloc, .{ .path = try alloc.dupe(u8, entry.path), .sha256 = try alloc.dupe(u8, entry.sha256), .bytes = entry.bytes, .executable = entry.executable });
        }
        offset += page.files.len;
        if (offset == page.total) {
            if (page.next_offset != null) return error.InvalidScopeExportInventory;
            break;
        }
        if (page.files.len == 0 or page.next_offset == null or page.next_offset.? != offset) return error.InvalidScopeExportInventory;
    }
    // The cache identity includes the exact request configuration. It is never
    // used to skip live inventory authorisation on a subsequent invocation.
    const staging = try alloc.print("{s}.partial-{s}", .{ destination, try workspace.hash(alloc, raw) });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io.getIo(), staging, .fromMode(0o700));
    var dir = try io.openDirAbsoluteNoFollow(try std.Io.Dir.path.resolve(alloc, &.{ try io.realpathAlloc(alloc, "."), staging }), .{ .iterate = true });
    defer dir.close(io.getIo());
    try dir.setPermissions(io.getIo(), .fromMode(0o700));
    // The complete signed inventory above authorises each lookup. Company and
    // issuer epoch partition immutable objects; a cache hit cannot skip the
    // final live grant check before publishing this export.
    var shared_cache = object_cache.Cache.open(.{ .workspace = company.workspace, .issuer = company.issuer, .epoch = company.epoch }, control) catch |err| absent: {
        try cacheFailure(err);
        break :absent null;
    };
    defer if (shared_cache) |cache| cache.close();
    var nonce: [16]u8 = undefined;
    io.getIo().random(&nonce);
    const archive_path = try alloc.print("archive-{s}.pending", .{std.fmt.bytesToHex(&nonce, .lower)});
    var file = try dir.createFile(io.getIo(), archive_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io.getIo());
    defer dir.deleteFile(io.getIo(), archive_path) catch {};
    var buffer: [16384]u8 = undefined;
    var writer = file.writerStreaming(io.getIo(), &buffer);
    var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
    var objects: std.StringHashMapUnmanaged(void) = .empty;
    for (entries.items) |entry| {
        try session.check();
        const slot = try objects.getOrPut(alloc, entry.sha256);
        if (slot.found_existing) continue;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const bytes = try download(session, arena.allocator(), dir, if (shared_cache) |*cache| cache else null, entry);
        try tar.writeFileBytes(try arena.allocator().print("objects/{s}", .{entry.sha256}), bytes, .{ .mode = 0o600 });
    }
    try session.check();
    // A final authorised request also checks revocation when every object was
    // served from the local cache and packaging performed no further reads.
    var final_arena = std.heap.ArenaAllocator.init(alloc);
    defer final_arena.deinit();
    _ = try session.request(final_arena.allocator(), null, 0);
    const manifest = try std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.scope-package/v2", .scope = "grant_file_snapshot", .dependency_closure = "not_evaluated", .workspace = config.workspace, .revision = config.revision, .actor = config.actor, .grant = config.grant, .issuer = company.issuer, .epoch = company.epoch, .files = entries.items, .inventory_receipts = receipts.items }, .{});
    if (manifest.len > 16 * 1024 * 1024) return error.ScopeExportMetadataLimit;
    try tar.writeFileBytes("manifest.json", manifest, .{ .mode = 0o600 });
    try tar.finishPedantically();
    try writer.interface.flush();
    try file.sync(io.getIo());
    _ = try verify(alloc, raw, try std.Io.Dir.path.join(alloc, &.{ staging, archive_path }));
    const snapshot: Snapshot = .{ .path = destination, .workspace = config.workspace, .revision = config.revision, .files = entries.items.len, .bytes = total_bytes, .shared_cache = if (shared_cache) |cache| cache.stats else null };
    const model = @import("definition.zig");
    const output = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, snapshot, .{}), .{});
    try model.validateOperation(alloc, try model.parse(alloc, model.seed), "omos_export_scope", output, .output);
    try session.check();
    try std.Io.Dir.hardLink(dir, archive_path, std.Io.Dir.cwd(), destination, io.getIo(), .{});
    var parent = try std.Io.Dir.cwd().openDir(io.getIo(), std.Io.Dir.path.dirname(destination) orelse ".", .{ .iterate = true });
    defer parent.close(io.getIo());
    const parent_file: std.Io.File = .{ .handle = parent.handle, .flags = .{ .nonblocking = false } };
    try parent_file.sync(io.getIo());
    return snapshot;
}
