//! Local capability closure packaging (offline verified tar export) and signed
//! remote promotion to a central Company Control Plane.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const authority = @import("company_authority.zig");
const identity = @import("company_identity.zig");
const client = @import("workspace_client.zig");
const workspace = @import("fossil_workspace.zig");
const model = @import("definition.zig");
const package = @import("capability_package.zig");
const promotion = @import("company_promotion.zig");
const fossil_manifest = @import("fossil_manifest.zig");
const uploads = @import("company_upload.zig");
const Value = std.json.Value;

pub const PromoteConfig = struct {
    version: []const u8,
    endpoint: []const u8,
    workspace: []const u8,
    actor: []const u8,
    grant: []const u8,
    key_handle: []const u8,
    issuer: []const u8,
    scope: ?[]const []const u8 = null,
    deadline_ms: u32 = 300_000,
};

pub const LocalFile = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: usize,
    executable: bool,
    content: []const u8,
};

pub const LocalPackage = struct {
    workspace: []const u8,
    revision: []const u8,
    capability: []const u8,
    graph_hash: []const u8,
    plan: package.Plan,
    files: []const LocalFile,
    total_bytes: u64,
};

pub const LocalManifest = struct {
    version: []const u8 = "omos.local-capability-package/v1",
    scope: []const u8 = "selected_capabilities",
    dependency_closure: []const u8 = "declared_complete",
    workspace: []const u8,
    revision: []const u8,
    capability: []const u8,
    graph_hash: []const u8,
    capability_plan: []const u8,
    files: []const promotion.FileEntry,
};

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

fn validHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

pub fn decodePromoteConfig(alloc: std.mem.Allocator, raw: []const u8) !PromoteConfig {
    const config = try records.decode(PromoteConfig, alloc, raw, .{});
    if (!std.mem.eql(u8, config.version, "omos.capability-promote-request/v1") or
        config.endpoint.len == 0 or
        !authority.safeIdentity(config.workspace) or
        !authority.safeIdentity(config.actor) or
        !authority.safeIdentity(config.grant) or
        !authority.safeIdentity(config.key_handle) or
        config.deadline_ms < 100 or config.deadline_ms > 3_600_000)
    {
        return error.InvalidCapabilityPromoteRequest;
    }
    if (config.scope) |paths| {
        if (paths.len == 0 or paths.len > 32) return error.InvalidCapabilityPromoteRequest;
        for (paths) |p| if (!authority.validPath(p, std.mem.endsWith(u8, p, "/"))) return error.InvalidCapabilityPromoteRequest;
    }
    _ = try authority.hexBytes(32, config.issuer);
    return config;
}

/// Collect ONLY the selected capability closure and its declared file paths from
/// the bound local Fossil's trunk, excluding all unrelated memory, research, and
/// conversations.
pub fn collectLocal(manager: workspace.Manager, selections: []const package.Selection) !LocalPackage {
    const alloc = manager.alloc;
    const revision = try manager.revision("trunk");
    const declaration = try manager.loadDeclaration(revision);
    const plan = try package.describe(alloc, declaration, selections);
    if (!plan.declaration_complete or plan.problems.len != 0) return error.IncompleteCapabilityPackage;
    const graph_hash = try package.graphHash(alloc, plan);
    const manifest = try manager.fileManifest(revision);

    var files: std.ArrayList(LocalFile) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var total_bytes: u64 = 0;

    for (plan.paths) |requested| {
        var found = false;
        for (manifest) |entry| {
            if (!std.mem.eql(u8, requested.path, entry.path) and !(std.mem.endsWith(u8, requested.path, "/") and std.mem.startsWith(u8, entry.path, requested.path))) continue;
            found = true;
            if (entry.mode == .symlink) return error.WorkspaceSymlinkDenied;
            if ((try seen.getOrPut(alloc, entry.path)).found_existing) continue;
            if (files.items.len >= 10000) return error.CapabilityPackageTooLarge;
            const bytes = try manager.contentAt(entry.path, revision);
            if (bytes.len > 8 * 1024 * 1024) return error.CapabilityPackageTooLarge;
            try fossil_manifest.verifyObject(entry.artifact orelse return error.WorkspaceVerificationFailed, bytes);
            const digest = try workspace.hash(alloc, bytes);
            total_bytes += bytes.len;
            try files.append(alloc, .{
                .path = entry.path,
                .sha256 = digest,
                .bytes = bytes.len,
                .executable = entry.mode == .executable,
                .content = bytes,
            });
        }
        if (!found) return error.IncompleteCapabilityPackage;
    }

    std.mem.sort(LocalFile, files.items, {}, struct {
        fn less(_: void, left: LocalFile, right: LocalFile) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);

    return .{
        .workspace = manager.manifest.id,
        .revision = revision,
        .capability = selections[0].capability,
        .graph_hash = graph_hash,
        .plan = plan,
        .files = files.items,
        .total_bytes = total_bytes,
    };
}

pub fn verifyLocalArchive(alloc: std.mem.Allocator, archive: []const u8) !LocalManifest {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    var file = try std.Io.Dir.cwd().openFile(io.getIo(), archive, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    var buffer: [16384]u8 = undefined;
    var reader = file.readerStreaming(io.getIo(), &buffer);
    var names: [256]u8 = undefined;
    var links: [256]u8 = undefined;
    var iterator = std.tar.Iterator.init(&reader.interface, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var objects: std.StringHashMapUnmanaged(usize) = .empty;
    var manifest_bytes: ?[]u8 = null;

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
        if (!std.mem.startsWith(u8, entry.name, "objects/") or !validHash(entry.name[8..]) or entry.size > 8 * 1024 * 1024 or objects.count() >= 10000) {
            return error.InvalidScopePackage;
        }
        const object_hash = try alloc.dupe(u8, entry.name[8..]);
        const slot = try objects.getOrPut(alloc, object_hash);
        if (slot.found_existing) return error.InvalidScopePackage;
        slot.value_ptr.* = @intCast(entry.size);
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

    const manifest = try records.decode(LocalManifest, alloc, manifest_bytes orelse return error.InvalidScopePackage, .{});
    if (!std.mem.eql(u8, manifest.version, "omos.local-capability-package/v1") or
        !std.mem.eql(u8, manifest.scope, "selected_capabilities") or
        !std.mem.eql(u8, manifest.dependency_closure, "declared_complete"))
    {
        return error.InvalidScopePackage;
    }
    const plan = try records.decode(package.Plan, alloc, manifest.capability_plan, .{});
    if (!plan.declaration_complete or plan.problems.len != 0) return error.IncompleteCapabilityPackage;
    if (!std.mem.eql(u8, manifest.graph_hash, try package.graphHash(alloc, plan))) return error.InvalidScopePackage;

    var used: std.StringHashMapUnmanaged(void) = .empty;
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    for (manifest.files) |entry| {
        if (!authority.validPath(entry.path, false) or !validHash(entry.sha256) or !package.includes(plan, entry.path)) return error.InvalidScopePackage;
        const lower = try std.ascii.allocLowerString(alloc, entry.path);
        if ((try paths.getOrPut(alloc, lower)).found_existing) return error.InvalidScopePackage;
        if ((objects.get(entry.sha256) orelse return error.InvalidScopePackage) != entry.bytes) return error.InvalidScopePackage;
        try used.put(alloc, entry.sha256, {});
    }
    for (plan.paths) |selector| {
        const matched = for (manifest.files) |entry| {
            if (std.mem.eql(u8, selector.path, entry.path) or (std.mem.endsWith(u8, selector.path, "/") and std.mem.startsWith(u8, entry.path, selector.path))) break true;
        } else false;
        if (!matched) return error.IncompleteCapabilityPackage;
    }
    if (used.count() != objects.count()) return error.InvalidScopePackage;
    return manifest;
}

/// Export ONLY the selected capability closure from the bound local Fossil into
/// a verified offline tar archive. Refuses to overwrite existing files.
pub fn exportArchive(manager: workspace.Manager, selections: []const package.Selection, destination: []const u8) !Value {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const alloc = manager.alloc;
    if (destination.len == 0) return error.MissingPath;
    if (std.Io.Dir.cwd().statFile(io.getIo(), destination, .{ .follow_symlinks = false })) |_| return error.WorkspaceAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const collected = try collectLocal(manager, selections);
    const parent_path = std.Io.Dir.path.dirname(destination) orelse ".";
    var parent = try std.Io.Dir.cwd().openDir(io.getIo(), parent_path, .{ .iterate = true });
    defer parent.close(io.getIo());

    var nonce: [16]u8 = undefined;
    io.getIo().random(&nonce);
    const pending_name = try alloc.print(".omos-capability-export-{s}.pending", .{std.fmt.bytesToHex(&nonce, .lower)});
    const pending_full = try std.Io.Dir.path.join(alloc, &.{ parent_path, pending_name });
    var file = try parent.createFile(io.getIo(), pending_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io.getIo());
    defer parent.deleteFile(io.getIo(), pending_name) catch {};

    var buffer: [16384]u8 = undefined;
    var writer = file.writerStreaming(io.getIo(), &buffer);
    var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };

    var written_objects: std.StringHashMapUnmanaged(void) = .empty;
    var entries: std.ArrayList(promotion.FileEntry) = .empty;
    for (collected.files) |item| {
        try entries.append(alloc, .{
            .path = item.path,
            .sha256 = item.sha256,
            .bytes = item.bytes,
            .executable = item.executable,
        });
        if ((try written_objects.getOrPut(alloc, item.sha256)).found_existing) continue;
        try tar.writeFileBytes(try alloc.print("objects/{s}", .{item.sha256}), item.content, .{ .mode = 0o600 });
    }

    const plan_json = try encode(alloc, collected.plan);
    const manifest: LocalManifest = .{
        .workspace = collected.workspace,
        .revision = collected.revision,
        .capability = collected.capability,
        .graph_hash = collected.graph_hash,
        .capability_plan = plan_json,
        .files = entries.items,
    };
    const manifest_bytes = try encode(alloc, manifest);
    if (manifest_bytes.len > 16 * 1024 * 1024) return error.ScopeExportMetadataLimit;
    try tar.writeFileBytes("manifest.json", manifest_bytes, .{ .mode = 0o600 });
    try tar.finishPedantically();
    try writer.interface.flush();
    try file.sync(io.getIo());

    _ = try verifyLocalArchive(alloc, pending_full);
    try std.Io.Dir.hardLink(parent, pending_name, std.Io.Dir.cwd(), destination, io.getIo(), .{});
    const parent_file: std.Io.File = .{ .handle = parent.handle, .flags = .{ .nonblocking = false } };
    try parent_file.sync(io.getIo());

    return std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .version = "omos.local-capability-package/v1",
        .workspace = collected.workspace,
        .revision = collected.revision,
        .path = destination,
        .capability = collected.capability,
        .graph_hash = collected.graph_hash,
        .files = collected.files.len,
        .bytes = collected.total_bytes,
        .scope = "selected_capabilities",
        .dependency_closure = "declared_complete",
    }), .{});
}

const RemoteSession = struct {
    config: PromoteConfig,
    company: client.Company,
    key: std.crypto.sign.Ed25519.KeyPair,
    control: client.Control,

    fn check(self: RemoteSession) !void {
        if (self.control.cancel.load(.seq_cst)) return error.Cancelled;
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, self.control.deadline)) return error.Timeout;
    }

    fn call(self: RemoteSession, alloc: std.mem.Allocator, request_value: authority.Request) !Value {
        try self.check();
        const payload = try std.json.Stringify.valueAlloc(alloc, request_value, .{ .emit_null_optional_fields = false });
        const signature = try self.key.sign(payload, null);
        const raw = try std.json.Stringify.valueAlloc(alloc, authority.Envelope{
            .payload = payload,
            .signature = &std.fmt.bytesToHex(signature.toBytes(), .lower),
        }, .{});
        const response = try client.companyCallControlled(alloc, self.config.endpoint, self.company, raw, self.control);
        const Envelope = struct { payload: []const u8 };
        const envelope = try std.json.parseFromValueLeaky(Envelope, alloc, response, .{ .ignore_unknown_fields = true });
        const claims = try records.decode(struct { result: Value }, alloc, envelope.payload, .{ .ignore_unknown_fields = true });
        return claims.result;
    }

    fn nextOperation(alloc: std.mem.Allocator) ![]const u8 {
        var nonce: [16]u8 = undefined;
        io.getIo().random(&nonce);
        return alloc.dupe(u8, &std.fmt.bytesToHex(&nonce, .lower));
    }
};

fn stageFile(session: RemoteSession, alloc: std.mem.Allocator, view_id: []const u8, view_revision: []const u8, file: LocalFile, supports_chunked: bool) ![]const u8 {
    if (file.bytes > uploads.chunk_bytes) {
        if (!supports_chunked) return error.CompanyDefinitionUpdateRequired;
        var offset: usize = 0;
        while (offset < file.bytes) {
            var chunk_arena = std.heap.ArenaAllocator.init(alloc);
            defer chunk_arena.deinit();
            const a = chunk_arena.allocator();
            const end = offset + @min(uploads.chunk_bytes, file.bytes - offset);
            const slice = file.content[offset..end];
            const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(slice.len));
            _ = try session.call(a, .{
                .version = "omos.company/v1",
                .workspace = session.config.workspace,
                .actor = session.config.actor,
                .grant = session.config.grant,
                .operation = try RemoteSession.nextOperation(a),
                .expires_ms = io.milliTimestamp() + 120_000,
                .action = .checkpoint,
                .view = view_id,
                .revision = view_revision,
                .path = file.path,
                .offset = offset,
                .content = std.base64.standard.Encoder.encode(encoded, slice),
                .encoding = .base64,
                .executable = file.executable,
                .upload = .{ .sha256 = file.sha256, .bytes = file.bytes },
            });
            offset = end;
        }
        const finished = try session.call(alloc, .{
            .version = "omos.company/v1",
            .workspace = session.config.workspace,
            .actor = session.config.actor,
            .grant = session.config.grant,
            .operation = try RemoteSession.nextOperation(alloc),
            .expires_ms = io.milliTimestamp() + 120_000,
            .action = .checkpoint,
            .view = view_id,
            .revision = view_revision,
            .path = file.path,
            .offset = 0,
            .encoding = .base64,
            .executable = file.executable,
            .upload = .{ .sha256 = file.sha256, .bytes = file.bytes },
        });
        return model.text(finished, "revision");
    }
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(file.content.len));
    const result = try session.call(alloc, .{
        .version = "omos.company/v1",
        .workspace = session.config.workspace,
        .actor = session.config.actor,
        .grant = session.config.grant,
        .operation = try RemoteSession.nextOperation(alloc),
        .expires_ms = io.milliTimestamp() + 120_000,
        .action = .checkpoint,
        .view = view_id,
        .revision = view_revision,
        .path = file.path,
        .content = std.base64.standard.Encoder.encode(encoded, file.content),
        .encoding = .base64,
        .executable = file.executable,
    });
    return model.text(result, "revision");
}

/// Pack a local capability closure from the bound Fossil, sign requests with the
/// actor's local key handle, stage only the declared package files on a central
/// view, and submit the capability promotion for review and policy enforcement.
pub fn promote(manager: workspace.Manager, raw_config: []const u8, selections: []const package.Selection, summary_override: ?[]const u8) !Value {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const alloc = manager.alloc;
    const config = try decodePromoteConfig(alloc, raw_config);
    const collected = try collectLocal(manager, selections);

    const summary = if (summary_override) |text| blk: {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 16384) return error.InvalidCompanyObjective;
        break :blk trimmed;
    } else try alloc.print("Promote capability {s} ({s}) from local workspace {s}", .{
        collected.capability,
        collected.graph_hash[0..@min(@as(usize, 12), collected.graph_hash.len)],
        collected.workspace,
    });

    var cancel = std.atomic.Value(bool).init(false);
    const control: client.Control = if (manager.operation_control) |existing| existing else .{
        .cancel = &cancel,
        .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromMilliseconds(config.deadline_ms)) },
    };

    var key = try identity.load(alloc, config.key_handle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));

    const company = try client.companyBootstrapControlled(alloc, config.endpoint, control);
    if (!std.mem.eql(u8, company.workspace, config.workspace) or !std.mem.eql(u8, company.issuer, config.issuer)) {
        return error.WorkspaceIdentityMismatch;
    }
    const features = company.features orelse return error.CompanyDefinitionUpdateRequired;
    if (!features.capability_promotion) return error.CompanyDefinitionUpdateRequired;
    const central_base = company.revision orelse return error.InvalidCompanyInstance;

    const session: RemoteSession = .{
        .config = config,
        .company = company,
        .key = key,
        .control = control,
    };

    const created = try session.call(alloc, .{
        .version = "omos.company/v1",
        .workspace = config.workspace,
        .actor = config.actor,
        .grant = config.grant,
        .operation = try RemoteSession.nextOperation(alloc),
        .expires_ms = io.milliTimestamp() + 120_000,
        .action = .create_view,
        .revision = central_base,
        .objective = summary,
        .scope = config.scope,
    });
    const view_id = model.text(created, "view");
    var view_revision = model.text(created, "revision");
    if (view_id.len == 0 or view_revision.len == 0) return error.InvalidCompanyInstance;

    var file_entries: std.ArrayList(promotion.FileEntry) = .empty;
    for (collected.files) |item| {
        view_revision = try stageFile(session, alloc, view_id, view_revision, item, features.chunked_upload);
        try file_entries.append(alloc, .{
            .path = item.path,
            .sha256 = item.sha256,
            .bytes = item.bytes,
            .executable = item.executable,
        });
    }

    const promotion_payload: promotion.Payload = .{
        .source_workspace = collected.workspace,
        .source_revision = collected.revision,
        .plan = collected.plan,
        .files = file_entries.items,
    };
    const encoded_payload = try encode(alloc, promotion_payload);

    const submitted = try session.call(alloc, .{
        .version = "omos.company/v1",
        .workspace = config.workspace,
        .actor = config.actor,
        .grant = config.grant,
        .operation = try RemoteSession.nextOperation(alloc),
        .expires_ms = io.milliTimestamp() + 120_000,
        .action = .promote_capability,
        .view = view_id,
        .revision = view_revision,
        .candidate = summary,
        .capability_plan = encoded_payload,
    });

    const approval_required = if (model.field(submitted, "approval_required")) |flag| (flag == .bool and flag.bool) else true;
    const policy_mode = model.text(submitted, "promotion_policy");

    return std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .version = "omos.capability-promotion-result/v1",
        .workspace = config.workspace,
        .source_workspace = collected.workspace,
        .source_revision = collected.revision,
        .capability = collected.capability,
        .graph_hash = collected.graph_hash,
        .view = view_id,
        .job = model.text(submitted, "job"),
        .state = model.text(submitted, "state"),
        .approval_required = approval_required,
        .promotion_policy = if (policy_mode.len > 0) policy_mode else "require_human_approval",
        .revision = model.text(submitted, "revision"),
        .files = collected.files.len,
        .bytes = collected.total_bytes,
    }), .{});
}
