//! Host verification of imported capability inputs and owner runtime handles.
//! A package can describe requirements but cannot supply host probe programs.
const std = @import("std");
const io = @import("../shared/io.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");
const model = @import("definition.zig");
const package = @import("capability_package.zig");
const handles = @import("runtime_handles.zig");
const identity = @import("company_identity.zig");
const authority = @import("company_authority.zig");
const Value = std.json.Value;
const verifier_handle = "capability-runtime-verifier";
const File = struct { path: []const u8, sha256: []const u8, bytes: usize, executable: bool };
const Manifest = struct { version: []const u8, workspace: []const u8, revision: []const u8, issuer: []const u8, files: []const File, capability_plan: []const u8 };
const Import = workspace.CapabilityImport;
const Context = struct { provenance: Import, manifest: Manifest, plan: package.Plan };
const Requirement = struct { resource: []const u8, kind: []const u8, handle: []const u8, constraint: []const u8, verified: bool, probe: ?handles.Probe = null };
const Claims = struct {
    version: []const u8 = "omos.capability-runtime/v1",
    workspace: []const u8,
    task: []const u8,
    manifest: []const u8,
    graph_hash: []const u8,
    bindings_hash: []const u8,
    requirements: []const Requirement,
    verified: bool,
};
const Envelope = struct { host: []const u8, payload: []const u8, signature: []const u8 };

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

fn artifact(manager: workspace.Manager, path: []const u8, revision: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "artifacts/") or path.len != 74) return error.InvalidCapabilityRuntimeProof;
    const bytes = try manager.contentAt(path, revision);
    if (!std.mem.eql(u8, path[10..], try workspace.hash(manager.alloc, bytes))) return error.InvalidArtifactIdentity;
    return bytes;
}

fn context(manager: workspace.Manager, task: workspace.Task, revision: []const u8) !?Context {
    var selected = task.capability_import;
    // The canonical task provides constant-time detection for ordinary turns.
    // Older staged imports are recognised only by their retained obligation.
    const legacy_import = for (task.definition.obligations) |obligation| {
        if (std.mem.eql(u8, obligation.id, "package_runtime")) break true;
    } else false;
    if (selected == null and !legacy_import) return null;
    if (selected == null) {
        var cursor = try manager.historyCursor(task, revision);
        while (cursor.offset < cursor.paths.len) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const batch = (try cursor.next(a)) orelse break;
            for (batch) |raw| {
                const row = try records.decode(struct { kind: []const u8, value: Value }, a, raw, .{ .ignore_unknown_fields = true });
                if (!std.mem.eql(u8, row.kind, "capability_import")) continue;
                const saved = try records.decode(Import, manager.alloc, try encode(manager.alloc, row.value), .{ .ignore_unknown_fields = true });
                if (selected) |previous| if (!std.mem.eql(u8, previous.manifest, saved.manifest) or !std.mem.eql(u8, previous.declaration, saved.declaration)) return error.InvalidCapabilityRuntimeProof;
                selected = saved;
            }
        }
    }
    const provenance = selected orelse return null;
    const manifest = try records.decode(Manifest, manager.alloc, try artifact(manager, provenance.manifest, revision), .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, manifest.version, "omos.scope-package/v3") or !std.mem.eql(u8, provenance.source_workspace, manifest.workspace) or !std.mem.eql(u8, provenance.source_revision, manifest.revision) or !std.mem.eql(u8, provenance.issuer, manifest.issuer)) return error.InvalidCapabilityRuntimeProof;
    const plan = try records.decode(package.Plan, manager.alloc, manifest.capability_plan, .{});
    if (!plan.declaration_complete or plan.problems.len != 0 or manifest.files.len > 10000) return error.IncompleteCapabilityPackage;
    _ = try model.parse(manager.alloc, try artifact(manager, provenance.declaration, revision));
    return .{ .provenance = provenance, .manifest = manifest, .plan = plan };
}

fn verifyFiles(manager: workspace.Manager, revision: []const u8, imported: Context) !void {
    var expected: std.StringHashMapUnmanaged(File) = .empty;
    for (imported.manifest.files) |file| {
        if (!authority.validPath(file.path, false) or !package.includes(imported.plan, file.path) or (try expected.getOrPut(manager.alloc, file.path)).found_existing) return error.InvalidCapabilityRuntimeProof;
        try expected.put(manager.alloc, file.path, file);
    }
    var count: usize = 0;
    for (try manager.fileManifest(revision)) |entry| {
        if (!package.includes(imported.plan, entry.path)) continue;
        const wanted = expected.get(entry.path) orelse return error.CapabilityInputsChanged;
        if (entry.mode == .symlink or (entry.mode == .executable) != wanted.executable) return error.CapabilityInputsChanged;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const bytes = try reader.contentAt(entry.path, revision);
        if (bytes.len != wanted.bytes or !std.mem.eql(u8, try workspace.hash(reader.alloc, bytes), wanted.sha256)) return error.CapabilityInputsChanged;
        count += 1;
    }
    if (count != expected.count()) return error.CapabilityInputsChanged;
}

fn bindingsHash(alloc: std.mem.Allocator, bindings: handles.Bindings) ![]const u8 {
    return workspace.hash(alloc, try encode(alloc, bindings));
}

fn native(handle: []const u8, constraint: []const u8) bool {
    if (!std.mem.eql(u8, constraint, model.profile_id)) return false;
    for ([_][]const u8{ "omos_model", "omos_fossil", "omos_repository", "omos_shell", "fossil_skill" }) |known| if (std.mem.eql(u8, known, handle)) return true;
    return false;
}

fn skillImplementation(manager: workspace.Manager, imported: Context, resource: []const u8, revision: []const u8) !bool {
    const contract = @import("../skills/skill_contract.zig");
    for (imported.manifest.files) |file| {
        if (!std.mem.startsWith(u8, file.path, "skills/") or !std.mem.endsWith(u8, file.path, "/SKILL.md")) continue;
        const selected = for (imported.plan.paths) |path| {
            if (!std.mem.eql(u8, path.resource, resource)) continue;
            if (std.mem.eql(u8, path.path, file.path) or (std.mem.endsWith(u8, path.path, "/") and std.mem.startsWith(u8, file.path, path.path))) break true;
        } else false;
        if (!selected) continue;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const content = try reader.contentAt(file.path, revision);
        if (std.mem.trim(u8, content, " \t\r\n").len == 0) continue;
        const fallback = std.Io.Dir.path.basename(std.Io.Dir.path.dirname(file.path) orelse return false);
        switch (contract.resolveMetadata(contract.parseSkillFile(content), fallback)) {
            .valid => return true,
            .invalid => {},
        }
    }
    return false;
}

fn bindingFor(bindings: handles.Bindings, handle: []const u8) ?handles.Binding {
    for (bindings.handles) |binding| if (std.mem.eql(u8, binding.handle, handle)) return binding;
    return null;
}

fn requireOperation(manager: workspace.Manager, task_id: []const u8) !void {
    const declaration = try manager.loadDeclaration("trunk");
    if (!model.hasOperation(declaration, "omos_verify_capability_runtime")) return error.WorkspaceContractUpgradeRequired;
    try model.validateOperation(manager.alloc, declaration, "omos_verify_capability_runtime", try std.json.parseFromSliceLeaky(Value, manager.alloc, try encode(manager.alloc, .{ .task = task_id }), .{}), .input);
}

pub fn verify(original: workspace.Manager, task_id: []const u8, raw_bindings: ?[]const u8) !Value {
    var manager = original;
    var cancel = std.atomic.Value(bool).init(false);
    if (manager.operation_control == null) manager.operation_control = .{ .cancel = &cancel, .deadline = .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(60000) }) };
    try requireOperation(manager, task_id);
    const task = try manager.refreshTaskContext(try manager.loadTask(task_id));
    if (task.state == .accepted) return verifyAccepted(manager, task, raw_bindings);
    return verifyTask(manager, task, raw_bindings, false);
}

/// The tool host calls this only for its currently leased managed task. It can
/// adopt an accepted package's references but cannot change private bindings.
pub fn verifyCurrent(manager: workspace.Manager, previous: workspace.Task, source_task: ?[]const u8) !Value {
    try requireOperation(manager, previous.id);
    var task = previous;
    if (task.authority != null) return error.CompanyCapabilityImportDenied;
    if (source_task) |id| {
        const source = try manager.loadTask(id);
        if (source.state != .accepted) return error.CapabilitySourceNotAccepted;
        const imported = (try context(manager, source, try manager.currentRevision(source))) orelse return error.CapabilityPackageRequired;
        const missing = task.capability_import == null;
        task = try manager.bindCapabilityImport(task, imported.provenance);
        if (missing) {
            try manager.record(task, "capability_reverification", .{ .source_task = source.id, .manifest = imported.provenance.manifest });
            _ = try manager.checkpoint(task);
        }
    } else if (task.capability_import == null) return error.CapabilityPackageRequired;
    return verifyTask(manager, task, null, true);
}

fn verifyTask(manager: workspace.Manager, previous: workspace.Task, raw_bindings: ?[]const u8, owned: bool) !Value {
    var task = try manager.refreshTaskContext(previous);
    if (task.authority != null) return error.CompanyCapabilityImportDenied;
    if (task.state == .accepted or task.state == .publication_pending) return error.TaskIsReadOnly;
    const lease: ?workspace.ExecutionLease = if (owned) null else (try manager.tryTaskExecutionLease(task.id)) orelse return error.TaskAlreadyRunning;
    defer if (lease) |held| held.release();
    var revision = try manager.currentRevision(task);
    const imported = (try context(manager, task, revision)) orelse return error.CapabilityPackageRequired;
    if (task.capability_import == null) {
        task = try manager.bindCapabilityImport(task, imported.provenance);
        revision = try manager.currentRevision(task);
    }
    try verifyFiles(manager, revision, imported);
    const bindings = if (raw_bindings) |raw| try handles.parse(manager.alloc, raw) else handles.load(manager.alloc) catch |err| switch (err) {
        error.FileNotFound => handles.Bindings{},
        else => return err,
    };
    var probes: std.StringHashMapUnmanaged(handles.Probe) = .empty;
    var requirements: std.ArrayList(Requirement) = .empty;
    var complete = true;
    for (imported.plan.external_dependencies) |entry| {
        const dependency = entry.dependency;
        var requirement: Requirement = .{ .resource = entry.resource, .kind = @tagName(dependency.kind), .handle = dependency.handle, .constraint = dependency.constraint, .verified = false };
        switch (dependency.kind) {
            .host_implementation => requirement.verified = native(dependency.handle, dependency.constraint) and (!std.mem.eql(u8, dependency.handle, "fossil_skill") or try skillImplementation(manager, imported, entry.resource, revision)),
            .runtime => if (bindingFor(bindings, dependency.handle)) |binding| {
                const observed = probes.get(binding.handle) orelse probe: {
                    const value = try handles.probeControlled(manager.alloc, binding, manager.operation_control);
                    try probes.put(manager.alloc, binding.handle, value);
                    break :probe value;
                };
                requirement.probe = observed;
                requirement.verified = try handles.satisfies(binding.kind, observed.version, dependency.constraint);
            },
            .configuration, .service => {},
        }
        complete = complete and requirement.verified;
        try requirements.append(manager.alloc, requirement);
    }
    // An operator supplies bindings explicitly. They remain in the private
    // profile; receipts retain only handle names, hashes and observations.
    if (raw_bindings) |raw| try handles.save(manager.alloc, raw);
    _ = try identity.create(manager.alloc, verifier_handle);
    var key = try identity.load(manager.alloc, verifier_handle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));
    const claims: Claims = .{ .workspace = manager.manifest.id, .task = task.id, .manifest = imported.provenance.manifest, .graph_hash = try package.graphHash(manager.alloc, imported.plan), .bindings_hash = try bindingsHash(manager.alloc, bindings), .requirements = requirements.items, .verified = complete };
    const payload = try encode(manager.alloc, claims);
    const signature = try key.sign(payload, null);
    const proof: Envelope = .{ .host = try manager.alloc.dupe(u8, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower)), .payload = payload, .signature = try manager.alloc.dupe(u8, &std.fmt.bytesToHex(signature.toBytes(), .lower)) };
    if (!std.mem.eql(u8, revision, try manager.currentRevision(task))) return error.WorkspaceRevisionChanged;
    const receipt = try manager.artifact(task, try encode(manager.alloc, proof));
    if (task.capability_runtime_receipt == null or !std.mem.eql(u8, task.capability_runtime_receipt.?, receipt)) {
        try manager.record(task, "capability_runtime", .{ .receipt = receipt, .graph_hash = claims.graph_hash, .verified = complete });
        _ = try manager.checkpoint(task);
        task = try manager.bindCapabilityRuntime(task, receipt);
    }
    return std.json.parseFromSliceLeaky(Value, manager.alloc, try encode(manager.alloc, .{ .version = "omos.capability-runtime-result/v1", .workspace = manager.manifest.id, .task = task.id, .revision = try manager.currentRevision(task), .verified = complete, .receipt = receipt, .requirements = requirements.items }), .{});
}

fn verifyAccepted(manager: workspace.Manager, original: workspace.Task, raw_bindings: ?[]const u8) !Value {
    if (original.authority != null) return error.CompanyCapabilityImportDenied;
    const imported = (try context(manager, original, try manager.currentRevision(original))) orelse return error.CapabilityPackageRequired;
    try verifyFiles(manager, try manager.revision("trunk"), imported);
    const bindings = if (raw_bindings) |raw| try handles.parse(manager.alloc, raw) else handles.load(manager.alloc) catch |err| switch (err) {
        error.FileNotFound => handles.Bindings{},
        else => return err,
    };
    _ = try identity.create(manager.alloc, verifier_handle);
    var key = try identity.load(manager.alloc, verifier_handle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));
    var stamps: std.ArrayList([]const u8) = .empty;
    for (bindings.handles) |binding| try stamps.append(manager.alloc, try handles.fingerprint(manager.alloc, binding));
    const session = try manager.alloc.print("capability-reverify-{s}", .{try workspace.hash(manager.alloc, try encode(manager.alloc, .{ original.id, imported.provenance.manifest, key.public_key.toBytes(), try bindingsHash(manager.alloc, bindings), stamps.items }))});
    const session_lease = (try manager.trySessionExecutionLease(session)) orelse return error.TaskAlreadyRunning;
    defer session_lease.release();
    var task = (try manager.active(session)) orelse try manager.start(session, try io.realpathAlloc(manager.alloc, "."), "Verify the accepted capability package on this host. Preserve the original accepted task, verify its retained inputs and configured runtime handles, and publish new implementation evidence only after independent review.", null);
    if (task.state == .accepted) {
        if (raw_bindings) |raw| try handles.save(manager.alloc, raw);
        const receipt = task.capability_runtime_receipt orelse return error.CapabilityRuntimeVerificationRequired;
        const proof = try verifyEnvelope(manager.alloc, try artifact(manager, receipt, try manager.currentRevision(task)));
        const current = (try context(manager, task, try manager.currentRevision(task))) orelse return error.InvalidCapabilityRuntimeProof;
        try live(manager, current, proof.claims, proof.envelope.host, try manager.currentRevision(task));
        return std.json.parseFromSliceLeaky(Value, manager.alloc, try encode(manager.alloc, .{ .version = "omos.capability-runtime-result/v1", .workspace = manager.manifest.id, .task = task.id, .revision = try manager.currentRevision(task), .verified = true, .receipt = receipt, .requirements = proof.claims.requirements }), .{});
    }
    if (task.capability_import == null) {
        task = try manager.bindCapabilityImport(task, imported.provenance);
        task = try manager.setPlan(task, "general_task", "Verify retained capability inputs and this host's runtime bindings without changing the accepted source task.", &.{
            .{ .id = "package_files", .description = "Verify every retained package input hash and mode against its immutable source manifest." },
            .{ .id = "package_runtime", .description = "Verify destination runtime and configuration handles; missing implementations remain unavailable." },
        }, &.{});
        try manager.record(task, "capability_reverification", .{ .source_task = original.id, .manifest = imported.provenance.manifest });
        _ = try manager.checkpoint(task);
    }
    const result = try verifyTask(manager, task, raw_bindings, false);
    task = try manager.setState(task.id, .paused);
    _ = try manager.checkpoint(task);
    var output = result;
    try output.object.put(manager.alloc, "revision", .{ .string = try manager.currentRevision(task) });
    return output;
}

fn verifyEnvelope(alloc: std.mem.Allocator, raw: []const u8) !struct { envelope: Envelope, claims: Claims } {
    const envelope = try records.decode(Envelope, alloc, raw, .{});
    const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try authority.hexBytes(32, envelope.host));
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(try authority.hexBytes(64, envelope.signature));
    signature.verifyStrict(envelope.payload, public) catch return error.InvalidCapabilityRuntimeProof;
    const claims = try records.decode(Claims, alloc, envelope.payload, .{});
    if (!std.mem.eql(u8, claims.version, "omos.capability-runtime/v1") or claims.requirements.len > 4096) return error.InvalidCapabilityRuntimeProof;
    return .{ .envelope = envelope, .claims = claims };
}

fn live(manager: workspace.Manager, imported: Context, claims: Claims, proof_host: []const u8, revision: []const u8) !void {
    if (!claims.verified or !std.mem.eql(u8, claims.workspace, manager.manifest.id) or !std.mem.eql(u8, claims.manifest, imported.provenance.manifest) or !std.mem.eql(u8, claims.graph_hash, try package.graphHash(manager.alloc, imported.plan)) or claims.requirements.len != imported.plan.external_dependencies.len) return error.CapabilityRuntimeVerificationRequired;
    var key = try identity.load(manager.alloc, verifier_handle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));
    if (!std.mem.eql(u8, proof_host, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower))) return error.CapabilityRuntimeHostChanged;
    const bindings = handles.load(manager.alloc) catch |err| switch (err) {
        error.FileNotFound => handles.Bindings{},
        else => return err,
    };
    if (!std.mem.eql(u8, claims.bindings_hash, try bindingsHash(manager.alloc, bindings))) return error.CapabilityRuntimeBindingsChanged;
    for (claims.requirements, imported.plan.external_dependencies) |requirement, entry| {
        const dependency = entry.dependency;
        if (!requirement.verified or !std.mem.eql(u8, requirement.resource, entry.resource) or !std.mem.eql(u8, requirement.kind, @tagName(dependency.kind)) or !std.mem.eql(u8, requirement.handle, dependency.handle) or !std.mem.eql(u8, requirement.constraint, dependency.constraint)) return error.InvalidCapabilityRuntimeProof;
        switch (dependency.kind) {
            .host_implementation => if (!native(dependency.handle, dependency.constraint) or requirement.probe != null or (std.mem.eql(u8, dependency.handle, "fossil_skill") and !try skillImplementation(manager, imported, entry.resource, revision))) return error.CapabilityRuntimeVerificationRequired,
            .runtime => {
                const binding = bindingFor(bindings, dependency.handle) orelse return error.CapabilityRuntimeBindingsChanged;
                const observation = requirement.probe orelse return error.InvalidCapabilityRuntimeProof;
                if (!std.mem.eql(u8, observation.handle, binding.handle) or observation.kind != binding.kind or !std.mem.eql(u8, observation.fingerprint, try handles.fingerprint(manager.alloc, binding)) or !try handles.satisfies(binding.kind, observation.version, dependency.constraint)) return error.CapabilityRuntimeBindingsChanged;
            },
            .configuration, .service => return error.CapabilityRuntimeVerificationRequired,
        }
    }
}

pub const Activation = struct { definition: []const u8, record_path: []const u8, record: []const u8, graph_hash: []const u8, receipt: []const u8 };

/// Publication calls this again at its controlled writer boundary. No probes
/// run during publication; stale files or environment observations reject it.
pub fn activation(manager: workspace.Manager, task: workspace.Task, source: []const u8, target: []const u8) !?Activation {
    const imported = (try context(manager, task, source)) orelse return null;
    try verifyFiles(manager, source, imported);
    const receipt = task.capability_runtime_receipt orelse return error.CapabilityRuntimeVerificationRequired;
    const proof = try verifyEnvelope(manager.alloc, try artifact(manager, receipt, source));
    if (!std.mem.eql(u8, proof.claims.task, task.id)) return error.InvalidCapabilityRuntimeProof;
    try live(manager, imported, proof.claims, proof.envelope.host, source);
    const accepted = .{ .path = receipt, .host = proof.envelope.host, .graph_hash = proof.claims.graph_hash };
    const definition = try package.importDefinition(manager.alloc, try manager.loadDeclaration(target), imported.plan);
    const id = try workspace.hash(manager.alloc, try encode(manager.alloc, .{ accepted.graph_hash, accepted.host }));
    const data = .{ .version = "omos.capability-implementation/v1", .workspace = manager.manifest.id, .task = task.id, .graph_hash = accepted.graph_hash, .host = accepted.host, .receipt = accepted.path };
    try model.validateRecord(definition.semantic, "omos_capability_implementation", try std.json.parseFromSliceLeaky(Value, manager.alloc, try encode(manager.alloc, data), .{}), true);
    return .{ .definition = try model.canonical(manager.alloc, definition.value), .graph_hash = data.graph_hash, .receipt = data.receipt, .record_path = try manager.alloc.print("records/omos_capability_implementation/{s}.json", .{id}), .record = try encode(manager.alloc, .{ .entity = "omos_capability_implementation", .id = id, .task = task.id, .data = data }) };
}

pub fn verifyPublication(manager: workspace.Manager, task: workspace.Task, source: []const u8, receipt: []const u8, graph_hash: []const u8) !void {
    if (task.capability_runtime_receipt == null or !std.mem.eql(u8, task.capability_runtime_receipt.?, receipt)) return error.InvalidCapabilityRuntimeProof;
    const proof = try verifyEnvelope(manager.alloc, try artifact(manager, receipt, source));
    if (!proof.claims.verified or !std.mem.eql(u8, proof.claims.workspace, manager.manifest.id) or !std.mem.eql(u8, proof.claims.task, task.id) or !std.mem.eql(u8, proof.claims.graph_hash, graph_hash)) return error.InvalidCapabilityRuntimeProof;
}

pub fn available(manager: workspace.Manager, declaration: model.Declaration, capability: []const u8, revision: []const u8) !bool {
    const plan = package.describe(manager.alloc, declaration, &.{.{ .capability = capability }}) catch |err| switch (err) {
        error.RealisationSelectionRequired, error.UnknownCapability => return false,
        else => return err,
    };
    if (!plan.declaration_complete) return false;
    var key = identity.load(manager.alloc, verifier_handle) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));
    const host = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    const graph_hash = try package.graphHash(manager.alloc, plan);
    const id = try workspace.hash(manager.alloc, try encode(manager.alloc, .{ graph_hash, @as([]const u8, &host) }));
    const path = try manager.alloc.print("records/omos_capability_implementation/{s}.json", .{id});
    const raw = manager.contentAt(path, revision) catch |err| switch (err) {
        error.FossilCommandFailed => return false,
        else => return err,
    };
    const Row = struct { entity: []const u8, id: []const u8, task: []const u8, data: struct { version: []const u8, workspace: []const u8, task: []const u8, graph_hash: []const u8, host: []const u8, receipt: []const u8 } };
    const row = try records.decode(Row, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, row.entity, "omos_capability_implementation") or !std.mem.eql(u8, row.id, id) or !std.mem.eql(u8, row.task, row.data.task) or !std.mem.eql(u8, row.data.version, "omos.capability-implementation/v1") or !std.mem.eql(u8, row.data.workspace, manager.manifest.id) or !std.mem.eql(u8, row.data.graph_hash, graph_hash) or !std.mem.eql(u8, row.data.host, &host)) return error.InvalidCapabilityRuntimeProof;
    const proof = try verifyEnvelope(manager.alloc, try artifact(manager, row.data.receipt, revision));
    if (!std.mem.eql(u8, proof.claims.task, row.task) or !std.mem.eql(u8, proof.claims.graph_hash, graph_hash) or !std.mem.eql(u8, proof.envelope.host, row.data.host)) return error.InvalidCapabilityRuntimeProof;
    const imported_task = try manager.loadTask(row.task);
    const imported = (try context(manager, imported_task, revision)) orelse return error.InvalidCapabilityRuntimeProof;
    verifyFiles(manager, revision, imported) catch |err| switch (err) {
        error.CapabilityInputsChanged => return false,
        else => return err,
    };
    live(manager, imported, proof.claims, proof.envelope.host, revision) catch |err| switch (err) {
        error.CapabilityRuntimeVerificationRequired, error.CapabilityRuntimeHostChanged, error.CapabilityRuntimeBindingsChanged, error.RuntimeExecutableUnsafe, error.RuntimeExecutableChanged, error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn verifyReceiptIdentity(manager: workspace.Manager, task: workspace.Task, receipt: []const u8) !void {
    const imported = (try context(manager, task, try manager.currentRevision(task))) orelse return error.CapabilityPackageRequired;
    const proof = try verifyEnvelope(manager.alloc, try artifact(manager, receipt, try manager.currentRevision(task)));
    var key = try identity.load(manager.alloc, verifier_handle);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key));
    if (!std.mem.eql(u8, proof.claims.workspace, manager.manifest.id) or !std.mem.eql(u8, proof.claims.task, task.id) or !std.mem.eql(u8, proof.claims.manifest, imported.provenance.manifest) or !std.mem.eql(u8, proof.claims.graph_hash, try package.graphHash(manager.alloc, imported.plan)) or !std.mem.eql(u8, proof.envelope.host, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower))) return error.InvalidCapabilityRuntimeProof;
}

/// This compact host receipt is emitted only after deterministic verification.
/// The complete signed observations remain retrievable through its artifact.
pub fn reviewReceipt(manager: workspace.Manager, task: workspace.Task, revision: []const u8) !?[]const u8 {
    const receipt = task.capability_runtime_receipt orelse return null;
    const imported = (try context(manager, task, revision)) orelse return error.InvalidCapabilityRuntimeProof;
    const proof = try verifyEnvelope(manager.alloc, try artifact(manager, receipt, revision));
    if (!std.mem.eql(u8, proof.claims.task, task.id)) return error.InvalidCapabilityRuntimeProof;
    live(manager, imported, proof.claims, proof.envelope.host, revision) catch |err| switch (err) {
        error.CapabilityRuntimeVerificationRequired, error.CapabilityRuntimeHostChanged, error.CapabilityRuntimeBindingsChanged, error.RuntimeExecutableUnsafe, error.RuntimeExecutableChanged, error.FileNotFound => return null,
        else => return err,
    };
    verifyFiles(manager, revision, imported) catch |err| switch (err) {
        error.CapabilityInputsChanged => return null,
        else => return err,
    };
    return try encode(manager.alloc, .{ .version = "omos.capability-runtime-receipt/v1", .workspace = manager.manifest.id, .task = task.id, .graph_hash = proof.claims.graph_hash, .receipt = receipt, .verified_files = imported.manifest.files.len, .verified_requirements = proof.claims.requirements.len, .scope = "Declared inputs and configured runtime constraints only. Package behavior and external effects require separate evidence." });
}

test "capability runtime receipts reject modified observations, signatures, and versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(19));
    const claims: Claims = .{ .workspace = "workspace", .task = "task", .manifest = "artifacts/manifest", .graph_hash = "graph", .bindings_hash = "bindings", .requirements = &.{}, .verified = true };
    const payload = try encode(a, claims);
    const signature = try key.sign(payload, null);
    var proof = Envelope{ .host = try a.dupe(u8, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower)), .payload = payload, .signature = try a.dupe(u8, &std.fmt.bytesToHex(signature.toBytes(), .lower)) };
    try std.testing.expect((try verifyEnvelope(a, try encode(a, proof))).claims.verified);
    proof.payload = try encode(a, .{ .version = claims.version, .workspace = claims.workspace, .task = claims.task, .manifest = claims.manifest, .graph_hash = claims.graph_hash, .bindings_hash = claims.bindings_hash, .requirements = claims.requirements, .verified = false });
    try std.testing.expectError(error.InvalidCapabilityRuntimeProof, verifyEnvelope(a, try encode(a, proof)));
    proof.payload = payload;
    proof.signature = try a.dupe(u8, &@as([128]u8, @splat('0')));
    try std.testing.expectError(error.InvalidCapabilityRuntimeProof, verifyEnvelope(a, try encode(a, proof)));
    var changed = claims;
    changed.version = "omos.capability-runtime/unknown";
    proof.payload = try encode(a, changed);
    const new_signature = try key.sign(proof.payload, null);
    proof.signature = try a.dupe(u8, &std.fmt.bytesToHex(new_signature.toBytes(), .lower));
    try std.testing.expectError(error.InvalidCapabilityRuntimeProof, verifyEnvelope(a, try encode(a, proof)));
}
