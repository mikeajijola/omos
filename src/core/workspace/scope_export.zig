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
const package = @import("capability_package.zig");

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
    selections: ?[]const authority.CapabilitySelection = null,
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
    capability_plan: ?[]const u8 = null,
    capability_receipts: []const Proof = &.{},
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
    package_hash: ?[]const u8 = null,
    dependency_closure: []const u8 = "not_evaluated",
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

const Reply = struct { request: []const u8, response: std.json.Value, result: std.json.Value };

const Session = struct {
    config: Config,
    company: client.Company,
    key: std.crypto.sign.Ed25519.KeyPair,
    control: client.Control,

    fn check(self: Session) !void {
        if (self.control.cancel.load(.seq_cst)) return error.Cancelled;
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, self.control.deadline)) return error.Timeout;
    }

    fn request(self: Session, alloc: std.mem.Allocator, path: ?[]const u8, offset: usize) !Reply {
        return self.requestAction(alloc, .export_scope, path, offset);
    }

    fn requestAction(self: Session, alloc: std.mem.Allocator, action: authority.Action, path: ?[]const u8, offset: usize) !Reply {
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
            .action = action,
            .revision = self.config.revision,
            .view = self.config.view,
            .path = path,
            .offset = offset,
            .capability = if (path == null and self.config.selections != null) self.config.selections.?[0].capability else null,
            .capability_selections = if (path == null) self.config.selections else null,
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

const MetadataSegment = struct { sha256: []const u8, bytes: usize, offset: usize, content: []const u8, encoding: []const u8, next_offset: ?usize };
const Metadata = struct { version: []const u8, workspace: []const u8, revision: []const u8, definition_revision: []const u8, definition_hash: []const u8, capability: []const u8, package: MetadataSegment };

fn sameSelections(a: ?[]const authority.CapabilitySelection, b: ?[]const authority.CapabilitySelection) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x.capability, y.capability) or !equalView(x.realisation, y.realisation)) return false;
    return true;
}

fn selectedRequest(config: Config, request: authority.Request) bool {
    if (!sameSelections(config.selections, request.capability_selections) or request.realisation != null) return false;
    return if (config.selections) |selections| equalView(request.capability, selections[0].capability) else request.capability == null;
}

fn appendMetadata(alloc: std.mem.Allocator, config: Config, bytes: *std.ArrayList(u8), previous: ?Metadata, page: Metadata) !void {
    const selections = config.selections orelse return error.InvalidScopePackage;
    const segment = page.package;
    if (!std.mem.eql(u8, page.version, "omos.company-capability/v1") or !std.mem.eql(u8, page.workspace, config.workspace) or !std.mem.eql(u8, page.revision, config.revision) or !std.mem.eql(u8, page.capability, selections[0].capability) or !validRevision(page.definition_revision) or !validHash(page.definition_hash) or segment.offset != bytes.items.len or segment.bytes == 0 or segment.bytes > 1024 * 1024 or !validHash(segment.sha256) or !std.mem.eql(u8, segment.encoding, "base64")) return error.InvalidScopePackage;
    if (previous) |prior| if (!std.mem.eql(u8, prior.definition_revision, page.definition_revision) or !std.mem.eql(u8, prior.definition_hash, page.definition_hash) or !std.mem.eql(u8, prior.package.sha256, segment.sha256) or prior.package.bytes != segment.bytes or prior.package.next_offset == null) return error.InvalidScopePackage;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(segment.content);
    if (size == 0 or size > 16384 or size > segment.bytes -| bytes.items.len) return error.InvalidScopePackage;
    const start = bytes.items.len;
    try bytes.resize(alloc, start + size);
    try std.base64.standard.Decoder.decode(bytes.items[start..], segment.content);
    if (bytes.items.len == segment.bytes) {
        if (segment.next_offset != null or !std.mem.eql(u8, segment.sha256, try workspace.hash(alloc, bytes.items))) return error.InvalidScopePackage;
    } else if (segment.next_offset == null or segment.next_offset.? != bytes.items.len) return error.InvalidScopePackage;
}

fn verifyMetadata(alloc: std.mem.Allocator, config: Config, company: client.Company, raw_plan: ?[]const u8, proofs: []const Proof) !?package.Plan {
    if (config.selections == null) {
        if (raw_plan != null or proofs.len != 0) return error.InvalidScopePackage;
        return null;
    }
    if (proofs.len == 0 or proofs.len > 64) return error.InvalidScopePackage;
    var bytes: std.ArrayList(u8) = .empty;
    var previous: ?Metadata = null;
    for (proofs) |proof| {
        try client.verifyCompanyReceipt(alloc, company, proof.request, proof.receipt);
        const envelope = try records.decode(authority.Envelope, alloc, proof.request, .{});
        const request = try records.decode(authority.Request, alloc, envelope.payload, .{});
        if (!std.mem.eql(u8, request.version, "omos.company/v2") or request.action != .discover or request.entity != null or request.path != null or !selectedRequest(config, request) or request.offset != bytes.items.len or !equalView(request.revision, config.revision) or !equalView(request.view, config.view) or !std.mem.eql(u8, request.actor, config.actor) or !std.mem.eql(u8, request.grant, config.grant)) return error.InvalidScopePackage;
        const receipt = try std.json.parseFromValueLeaky(struct { payload: []const u8 }, alloc, proof.receipt, .{ .ignore_unknown_fields = true });
        const claims = try records.decode(struct { result: Metadata }, alloc, receipt.payload, .{ .ignore_unknown_fields = true });
        try appendMetadata(alloc, config, &bytes, previous, claims.result);
        previous = claims.result;
    }
    if (previous.?.package.next_offset != null or !std.mem.eql(u8, bytes.items, raw_plan orelse return error.InvalidScopePackage)) return error.InvalidScopePackage;
    const plan = try records.decode(package.Plan, alloc, bytes.items, .{});
    if (!std.mem.eql(u8, plan.version, "omos.capability-package-plan/v1") or !std.mem.eql(u8, plan.definition_hash, previous.?.definition_hash) or !plan.declaration_complete or plan.problems.len != 0 or plan.files.len != 0 or !std.mem.eql(u8, plan.runtime_verification, "required") or !std.mem.eql(u8, plan.file_verification, "required")) return error.InvalidScopePackage;
    for (plan.paths) |selector| if (!authority.validPath(selector.path, std.mem.endsWith(u8, selector.path, "/"))) return error.InvalidScopePackage;
    return plan;
}

fn verifyRequiredPaths(plan: package.Plan, entries: []const Entry) !void {
    for (entries) |entry| if (!package.includes(plan, entry.path)) return error.InvalidScopePackage;
    for (plan.paths) |selector| {
        const found = for (entries) |entry| {
            if (std.mem.eql(u8, selector.path, entry.path) or (std.mem.endsWith(u8, selector.path, "/") and std.mem.startsWith(u8, entry.path, selector.path))) break true;
        } else false;
        if (!found) return error.IncompleteCapabilityPackage;
    }
}

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
    const selected = std.mem.eql(u8, config.version, "omos.scope-export-request/v2");
    if ((!selected and !std.mem.eql(u8, config.version, "omos.scope-export-request/v1")) or selected != (config.selections != null) or !authority.safeIdentity(config.workspace) or !authority.safeIdentity(config.actor) or !authority.safeIdentity(config.grant) or !validRevision(config.revision) or config.max_bytes == 0 or config.max_bytes > 1024 * 1024 * 1024 * 1024 or config.deadline_ms < 100 or config.deadline_ms > 3_600_000) return error.InvalidScopeExportRequest;
    if (config.selections) |selections| {
        if (selections.len == 0 or selections.len > 256) return error.InvalidCapabilitySelection;
        for (selections, 0..) |selection, index| {
            if (!authority.safeIdentity(selection.capability)) return error.InvalidCapabilitySelection;
            if (selection.realisation) |id| if (!authority.safeIdentity(id)) return error.InvalidCapabilitySelection;
            for (selections[0..index]) |previous| if (std.mem.eql(u8, selection.capability, previous.capability)) return error.DuplicateCapabilitySelection;
        }
    }
    _ = try authority.hexBytes(32, config.issuer);
    return config;
}

/// Offline integrity is checked against the caller's separate issuer and
/// scope pins. It makes no claim about the grant's present revocation state.
const Inspection = struct { snapshot: Snapshot, manifest: Manifest, raw_manifest: []const u8 };

pub fn verify(alloc: std.mem.Allocator, raw: []const u8, archive: []const u8) !Snapshot {
    return (try inspectArchive(alloc, raw, archive)).snapshot;
}

fn inspectArchive(alloc: std.mem.Allocator, raw: []const u8, archive: []const u8) !Inspection {
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
    const capability_package = std.mem.eql(u8, manifest.version, "omos.scope-package/v3");
    const attributes = capability_package or std.mem.eql(u8, manifest.version, "omos.scope-package/v2");
    if ((!attributes and !std.mem.eql(u8, manifest.version, "omos.scope-package/v1")) or capability_package != (config.selections != null) or !std.mem.eql(u8, manifest.scope, if (capability_package) "selected_capabilities" else "grant_file_snapshot") or !std.mem.eql(u8, manifest.dependency_closure, if (capability_package) "declared_complete" else "not_evaluated") or !std.mem.eql(u8, manifest.workspace, config.workspace) or !std.mem.eql(u8, manifest.revision, config.revision) or !std.mem.eql(u8, manifest.actor, config.actor) or !std.mem.eql(u8, manifest.grant, config.grant) or !std.mem.eql(u8, manifest.issuer, config.issuer) or manifest.epoch == 0 or manifest.files.len > 10000 or manifest.inventory_receipts.len > 313) return error.InvalidScopePackage;
    const company: client.Company = .{ .version = "omos.company/v1", .workspace = config.workspace, .issuer = config.issuer, .epoch = manifest.epoch };
    const plan = try verifyMetadata(alloc, config, company, manifest.capability_plan, manifest.capability_receipts);
    if (plan) |selected| try verifyRequiredPaths(selected, manifest.files);
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
        if (!std.mem.eql(u8, request.version, if (attributes) "omos.company/v2" else "omos.company/v1") or request.action != .export_scope or request.path != null or !selectedRequest(config, request) or request.revision == null or !std.mem.eql(u8, request.revision.?, config.revision) or request.offset != covered or !std.mem.eql(u8, request.actor, config.actor) or !std.mem.eql(u8, request.grant, config.grant) or !equalView(request.view, config.view)) return error.InvalidScopePackage;
        const receipt = try std.json.parseFromValueLeaky(struct { payload: []const u8 }, alloc, proof.receipt, .{ .ignore_unknown_fields = true });
        const claims = try records.decode(struct { result: Page }, alloc, receipt.payload, .{ .ignore_unknown_fields = true });
        const page = claims.result;
        if (!std.mem.eql(u8, page.version, if (attributes) "omos.scoped-export/v2" else "omos.scoped-export/v1") or !std.mem.eql(u8, page.workspace, config.workspace) or !std.mem.eql(u8, page.revision, config.revision) or !std.mem.eql(u8, page.actor, config.actor) or !std.mem.eql(u8, page.grant, config.grant) or page.total != manifest.files.len or page.files.len > 32 or page.files.len > manifest.files.len -| covered) return error.InvalidScopePackage;
        if (plan != null and (!std.mem.eql(u8, page.dependency_closure, "declared_complete") or !equalView(page.package_hash, try workspace.hash(alloc, manifest.capability_plan.?)))) return error.InvalidScopePackage;
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
    return .{ .manifest = manifest, .raw_manifest = manifest_bytes.?, .snapshot = .{ .version = manifest.version, .file_attributes = if (attributes) .verified else .unavailable, .path = archive, .workspace = config.workspace, .revision = config.revision, .files = covered, .bytes = total_bytes, .scope = manifest.scope, .dependency_closure = manifest.dependency_closure } };
}

/// Retain a verified package on an isolated task branch. No package program is
/// executed, and no declaration or content is accepted by this staging step.
pub fn importArchive(manager: workspace.Manager, raw: []const u8, archive: []const u8) !std.json.Value {
    const alloc = manager.alloc;
    const config = try decodeConfig(alloc, raw);
    if (config.selections == null) return error.CapabilityPackageRequired;
    const inspected = try inspectArchive(alloc, raw, archive);
    if (inspected.snapshot.bytes > 256 * 1024 * 1024 or inspected.raw_manifest.len > 8 * 1024 * 1024) return error.CapabilityImportByteLimit;
    const manifest = inspected.manifest;
    const plan = try records.decode(package.Plan, alloc, manifest.capability_plan.?, .{});
    const session = try alloc.print("capability-import-{s}", .{try workspace.hash(alloc, inspected.raw_manifest)});
    const session_lease = (try manager.trySessionExecutionLease(session)) orelse return error.TaskAlreadyRunning;
    defer session_lease.release();
    const previous = try manager.active(session);
    const base = if (previous) |task| task.base_revision else try manager.revision("trunk");
    const declaration = try manager.loadDeclaration(base);
    const model = @import("definition.zig");
    if (!model.hasOperation(declaration, "omos_import_capabilities")) return error.WorkspaceContractUpgradeRequired;
    const candidate = try package.importDefinition(alloc, declaration, plan);
    const definition_bytes = try model.canonical(alloc, candidate.value);
    const definition_path = try alloc.print("artifacts/{s}", .{try workspace.hash(alloc, definition_bytes)});
    const manifest_path = try alloc.print("artifacts/{s}", .{try workspace.hash(alloc, inspected.raw_manifest)});
    // Re-read only after the complete archive was verified. Check every object
    // and the exact signed manifest again before changing any destination state.
    var file = try std.Io.Dir.cwd().openFile(io.getIo(), archive, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io.getIo());
    var buffer: [16384]u8 = undefined;
    var reader = file.readerStreaming(io.getIo(), &buffer);
    var names: [256]u8 = undefined;
    var links: [256]u8 = undefined;
    var iterator = std.tar.Iterator.init(&reader.interface, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var objects: std.StringHashMapUnmanaged([]const u8) = .empty;
    var seen_manifest = false;
    var retained_bytes: u64 = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or seen_manifest) return error.InvalidScopePackage;
        if (std.mem.eql(u8, entry.name, "manifest.json")) {
            if (entry.size != inspected.raw_manifest.len) return error.InvalidScopePackage;
            const bytes = try alloc.alloc(u8, @intCast(entry.size));
            try reader.interface.readSliceAll(bytes);
            iterator.unread_file_bytes = 0;
            if (!std.mem.eql(u8, bytes, inspected.raw_manifest)) return error.InvalidScopePackage;
            seen_manifest = true;
            continue;
        }
        if (!std.mem.startsWith(u8, entry.name, "objects/") or !validHash(entry.name[8..]) or entry.size > 8 * 1024 * 1024) return error.InvalidScopePackage;
        const expected = for (manifest.files) |item| {
            if (std.mem.eql(u8, item.sha256, entry.name[8..])) break item;
        } else return error.InvalidScopePackage;
        if (entry.size != expected.bytes or objects.contains(expected.sha256)) return error.InvalidScopePackage;
        retained_bytes += entry.size;
        if (retained_bytes > 256 * 1024 * 1024) return error.CapabilityImportByteLimit;
        const bytes = try alloc.alloc(u8, @intCast(entry.size));
        try reader.interface.readSliceAll(bytes);
        iterator.unread_file_bytes = 0;
        if (!std.mem.eql(u8, expected.sha256, try workspace.hash(alloc, bytes))) return error.ScopeExportHashMismatch;
        try objects.put(alloc, expected.sha256, bytes);
    }
    const trailing = try reader.interface.allocRemaining(alloc, .limited(1024));
    if (!seen_manifest or trailing.len != 512 or !std.mem.allEqual(u8, trailing, 0)) return error.InvalidScopePackage;
    const inventory = try manager.fileManifest(base);
    for (manifest.files) |entry| {
        _ = objects.get(entry.sha256) orelse return error.InvalidScopePackage;
        // Imported definitions and all files must be additive. Identical
        // existing bytes may be reused; differing bytes or flags are conflicts.
        for (inventory) |existing| {
            if (!std.mem.eql(u8, entry.path, existing.path)) continue;
            if (existing.mode == .symlink or (existing.mode == .executable) != entry.executable.? or !std.mem.eql(u8, try workspace.hash(alloc, try manager.contentAt(entry.path, base)), entry.sha256)) return error.CapabilityImportCollision;
        }
    }
    var task = previous orelse try manager.start(session, try io.realpathAlloc(alloc, "."), "Import the selected capability package. Preserve signed provenance, verify all files and runtime dependencies, validate the additive company definition, and publish only after independent contract verification.", null);
    if (!std.mem.eql(u8, task.base_revision, base)) return error.WorkspaceRevisionChanged;
    const task_lease = (try manager.tryTaskExecutionLease(task.id)) orelse return error.TaskAlreadyRunning;
    defer task_lease.release();
    // Do not replay a completed import, including one subsequently published by
    // normal review. Existing changed tasks still pass the same collision fence.
    task = try manager.bindCapabilityImport(task, .{ .manifest = manifest_path, .declaration = definition_path, .source_workspace = config.workspace, .source_revision = config.revision, .issuer = config.issuer });
    const existing_paths = try manager.inventory(try manager.currentRevision(task));
    const retained = for (existing_paths) |path| {
        if (std.mem.eql(u8, path, manifest_path)) break true;
    } else false;
    if (!retained) {
        if (task.model_basis == null) return error.WorkspaceMigrationRequired;
        if (task.model_basis.?.capability == null) task = try manager.setPlan(task, "general_task", "Retain a signed capability package and verify its destination dependencies before activation.", &.{
            .{ .id = "package_files", .description = "Verify every selected file hash, mode, and signed source manifest." },
            .{ .id = "package_runtime", .description = "Verify explicit external runtime and configuration handles on the destination host." },
            .{ .id = "package_definition", .description = "Validate and activate the additive declaration only after dependency verification." },
        }, &.{});
        for ([_][]const u8{ "package_files", "package_runtime", "package_definition" }) |id| {
            const retained_obligation = for (task.definition.obligations) |obligation| {
                if (std.mem.eql(u8, obligation.id, id)) break true;
            } else false;
            if (!retained_obligation) return error.StaleWorkContract;
        }
        var changes: std.ArrayList(workspace.Manager.ContentChange) = .empty;
        for (manifest.files) |entry| try changes.append(alloc, .{ .path = entry.path, .content = objects.get(entry.sha256).?, .previous_hash = null, .executable = entry.executable });
        try changes.append(alloc, .{ .path = definition_path, .content = definition_bytes, .previous_hash = null });
        _ = try manager.checkpointContent(task, changes.items);
        try importFault("capability-import-files");
        try manager.record(task, "capability_import", .{ .source_workspace = config.workspace, .source_revision = config.revision, .issuer = config.issuer, .epoch = manifest.epoch, .manifest = manifest_path, .declaration = definition_path, .definition_hash = candidate.hash, .runtime_verification = "required" });
        task = try manager.setState(task.id, .paused);
        _ = try manager.checkpoint(task);
        try importFault("capability-import-retained");
        // This last durable marker proves the source record and paused task
        // were retained. A crash before it can safely repeat desired writes.
        try manager.writeContent(task, manifest_path, inspected.raw_manifest);
    } else {
        const revision = try manager.currentRevision(task);
        const metadata = try manager.fileManifest(revision);
        for (manifest.files) |entry| {
            const present = for (metadata) |item| {
                if (std.mem.eql(u8, item.path, entry.path)) break item;
            } else return error.CapabilityImportCollision;
            if (present.mode == .symlink or (present.mode == .executable) != entry.executable.? or !std.mem.eql(u8, try workspace.hash(alloc, try manager.contentAt(entry.path, revision)), entry.sha256)) return error.CapabilityImportCollision;
        }
    }
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.capability-import/v1", .workspace = manager.manifest.id, .source_workspace = config.workspace, .source_revision = config.revision, .task = task.id, .revision = try manager.currentRevision(task), .state = @tagName(task.state), .publication = if (task.state == .accepted) "accepted" else "pending", .runtime_verification = "required", .declaration = definition_path, .manifest = manifest_path, .files = manifest.files.len }, .{}), .{});
}

fn importFault(stage: []const u8) !void {
    if (comptime @import("build_options").libfx) return;
    if (io.getenv("FX_E2E_FOSSIL_FAULT")) |point| if (std.mem.eql(u8, stage, point)) return error.WorkspaceInjectedFailure;
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
    if (config.selections != null and !features.capability_packages) return error.CompanyDefinitionUpdateRequired;
    var capability_receipts: std.ArrayList(Proof) = .empty;
    var metadata: std.ArrayList(u8) = .empty;
    var prior_metadata: ?Metadata = null;
    if (config.selections != null) while (true) {
        const response = try session.requestAction(alloc, .discover, null, metadata.items.len);
        const page = try std.json.parseFromValueLeaky(Metadata, alloc, response.result, .{ .ignore_unknown_fields = true });
        try appendMetadata(alloc, config, &metadata, prior_metadata, page);
        try capability_receipts.append(alloc, .{ .request = response.request, .receipt = response.response });
        prior_metadata = page;
        if (page.package.next_offset == null) break;
    };
    const raw_plan: ?[]const u8 = if (config.selections != null) metadata.items else null;
    const plan = try verifyMetadata(alloc, config, company, raw_plan, capability_receipts.items);

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
        if (plan != null and (!std.mem.eql(u8, page.dependency_closure, "declared_complete") or !equalView(page.package_hash, try workspace.hash(alloc, raw_plan.?)))) return error.InvalidScopeExportInventory;
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
    if (plan) |selected| try verifyRequiredPaths(selected, entries.items);
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
    const manifest = try std.json.Stringify.valueAlloc(alloc, .{ .version = if (plan != null) "omos.scope-package/v3" else "omos.scope-package/v2", .scope = if (plan != null) "selected_capabilities" else "grant_file_snapshot", .dependency_closure = if (plan != null) "declared_complete" else "not_evaluated", .capability_plan = raw_plan, .capability_receipts = capability_receipts.items, .workspace = config.workspace, .revision = config.revision, .actor = config.actor, .grant = config.grant, .issuer = company.issuer, .epoch = company.epoch, .files = entries.items, .inventory_receipts = receipts.items }, .{});
    if (manifest.len > 16 * 1024 * 1024) return error.ScopeExportMetadataLimit;
    try tar.writeFileBytes("manifest.json", manifest, .{ .mode = 0o600 });
    try tar.finishPedantically();
    try writer.interface.flush();
    try file.sync(io.getIo());
    _ = try verify(alloc, raw, try std.Io.Dir.path.join(alloc, &.{ staging, archive_path }));
    const snapshot: Snapshot = .{ .version = if (plan != null) "omos.scope-package/v3" else "omos.scope-package/v2", .scope = if (plan != null) "selected_capabilities" else "grant_file_snapshot", .dependency_closure = if (plan != null) "declared_complete" else "not_evaluated", .path = destination, .workspace = config.workspace, .revision = config.revision, .files = entries.items.len, .bytes = total_bytes, .shared_cache = if (shared_cache) |cache| cache.stats else null };
    const model = @import("definition.zig");
    const output = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, snapshot, .{}), .{});
    try model.validateOperation(alloc, try model.parse(alloc, model.seed), if (plan != null) "omos_export_capabilities" else "omos_export_scope", output, .output);
    try session.check();
    try std.Io.Dir.hardLink(dir, archive_path, std.Io.Dir.cwd(), destination, io.getIo(), .{});
    var parent = try std.Io.Dir.cwd().openDir(io.getIo(), std.Io.Dir.path.dirname(destination) orelse ".", .{ .iterate = true });
    defer parent.close(io.getIo());
    const parent_file: std.Io.File = .{ .handle = parent.handle, .flags = .{ .nonblocking = false } };
    try parent_file.sync(io.getIo());
    return snapshot;
}
