//! Central validation and atomic activation for actor-promoted capability
//! packages. Promoted declarations are strictly additive and land on trunk only
//! after independent review, operator policy enforcement, and atomic publication.
const std = @import("std");
const authority = @import("company_authority.zig");
const model = @import("definition.zig");
const package = @import("capability_package.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");
const Value = std.json.Value;

pub const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: usize,
    executable: bool,
};

pub const Payload = struct {
    version: []const u8 = "omos.capability-promotion/v1",
    source_workspace: ?[]const u8 = null,
    source_revision: ?[]const u8 = null,
    plan: package.Plan,
    files: []const FileEntry = &.{},
};

pub const Validated = struct {
    payload: Payload,
    verified_plan: package.Plan,
    candidate: model.Declaration,
    graph_hash: []const u8,
    capabilities: []const []const u8,
    definition_bytes: []const u8,
    payload_bytes: []const u8,
};

pub const Activation = struct {
    definition: []const u8,
    definition_hash: []const u8,
    graph_hash: []const u8,
    plan_artifact: []const u8,
    capabilities: []const []const u8,
    record_path: []const u8,
    record: []const u8,
};

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
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

fn artifact(manager: workspace.Manager, path: []const u8, revision: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "artifacts/") or path.len != 74) return error.InvalidCapabilityPromotion;
    const bytes = try manager.contentAt(path, revision);
    if (!std.mem.eql(u8, path[10..], try workspace.hash(manager.alloc, bytes))) return error.InvalidArtifactIdentity;
    return bytes;
}

fn selectionsFromPlan(alloc: std.mem.Allocator, plan: package.Plan) !struct { selections: []const package.Selection, capabilities: []const []const u8 } {
    if (plan.capabilities.len == 0 or plan.capabilities.len > 256 or plan.realisations.len != plan.capabilities.len) {
        return error.InvalidCapabilitySelection;
    }
    var selections: std.ArrayList(package.Selection) = .empty;
    var capabilities: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (plan.capabilities) |capability| {
        const cap_id = model.text(capability, "id");
        if (!authority.safeIdentity(cap_id)) return error.InvalidCapabilitySelection;
        if ((try seen.getOrPut(alloc, cap_id)).found_existing) return error.DuplicateCapabilitySelection;
        var matched_realisation: ?[]const u8 = null;
        for (plan.realisations) |realisation| {
            if (!std.mem.eql(u8, model.text(realisation, "capability"), cap_id)) continue;
            if (matched_realisation != null) return error.InvalidCapabilitySelection;
            const real_id = model.text(realisation, "id");
            if (!authority.safeIdentity(real_id)) return error.InvalidCapabilitySelection;
            matched_realisation = real_id;
        }
        const selected = matched_realisation orelse return error.InvalidCapabilitySelection;
        try selections.append(alloc, .{ .capability = cap_id, .realisation = selected });
        try capabilities.append(alloc, cap_id);
    }
    return .{ .selections = selections.items, .capabilities = capabilities.items };
}

fn isAllowedArtifact(path: []const u8, allowed_artifacts: []const []const u8) bool {
    for (allowed_artifacts) |allowed| if (std.mem.eql(u8, path, allowed)) return true;
    return false;
}

fn validateFiles(
    manager: workspace.Manager,
    grant: ?authority.Grant,
    verified_plan: package.Plan,
    files: []const FileEntry,
    source_revision: []const u8,
    target_revision: []const u8,
    allowed_artifacts: []const []const u8,
) !void {
    const alloc = manager.alloc;
    if (files.len > 10000) return error.CapabilityPackageTooLarge;
    var expected: std.StringHashMapUnmanaged(FileEntry) = .empty;
    var lower_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (files) |file| {
        if (!authority.validPath(file.path, false) or !validHash(file.sha256) or file.bytes > 8 * 1024 * 1024) {
            return error.InvalidCapabilityPromotion;
        }
        if (grant) |live| if (!authority.permitsPath(live, file.path)) return error.CompanyAccessDenied;
        if (!package.includes(verified_plan, file.path)) return error.InvalidCapabilityPromotion;
        const lower = try std.ascii.allocLowerString(alloc, file.path);
        if ((try lower_seen.getOrPut(alloc, lower)).found_existing) return error.InvalidCapabilityPromotion;
        try expected.put(alloc, file.path, file);
    }
    for (verified_plan.paths) |selector| {
        if (!authority.validPath(selector.path, std.mem.endsWith(u8, selector.path, "/"))) return error.InvalidResourcePackagePath;
        if (grant) |live| if (!authority.permitsSelector(live, selector.path)) return error.CompanyAccessDenied;
        const matched = for (files) |file| {
            if (std.mem.eql(u8, selector.path, file.path) or (std.mem.endsWith(u8, selector.path, "/") and std.mem.startsWith(u8, file.path, selector.path))) break true;
        } else false;
        if (!matched) return error.IncompleteCapabilityPackage;
    }

    const source_manifest = try manager.fileManifest(source_revision);
    var verified_count: usize = 0;
    for (source_manifest) |entry| {
        if (!package.includes(verified_plan, entry.path)) continue;
        const wanted = expected.get(entry.path) orelse return error.CapabilityImportCollision;
        if (entry.mode == .symlink) return error.WorkspaceSymlinkDenied;
        if ((entry.mode == .executable) != wanted.executable) return error.InvalidCapabilityPromotion;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const bytes = try reader.contentAt(entry.path, source_revision);
        if (bytes.len != wanted.bytes or !std.mem.eql(u8, try workspace.hash(reader.alloc, bytes), wanted.sha256)) {
            return error.InvalidCapabilityPromotion;
        }
        verified_count += 1;
    }
    if (verified_count != expected.count()) return error.IncompleteCapabilityPackage;

    // Promoted files must be strictly additive against target trunk. Identical
    // existing bytes and executable flags may be reused; differences collide.
    const target_manifest = try manager.fileManifest(target_revision);
    for (target_manifest) |existing| {
        const wanted = expected.get(existing.path) orelse continue;
        if (existing.mode == .symlink or (existing.mode == .executable) != wanted.executable) return error.CapabilityImportCollision;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const existing_bytes = try reader.contentAt(existing.path, target_revision);
        if (existing_bytes.len != wanted.bytes or !std.mem.eql(u8, try workspace.hash(reader.alloc, existing_bytes), wanted.sha256)) {
            return error.CapabilityImportCollision;
        }
    }

    // Reject any staged content outside the declared package closure (for
    // example local research, memory, or unrelated documents).
    for (try manager.changedPaths(target_revision, source_revision)) |changed| {
        if (!authority.validPath(changed, false)) continue;
        if (isAllowedArtifact(changed, allowed_artifacts)) continue;
        if (!expected.contains(changed)) return error.InvalidCapabilityPromotion;
    }
}

pub fn validate(
    manager: workspace.Manager,
    grant: authority.Grant,
    central_declaration: model.Declaration,
    view_revision: []const u8,
    base_revision: []const u8,
    request_artifact: ?[]const u8,
    raw_payload: []const u8,
) !Validated {
    const alloc = manager.alloc;
    const payload = try records.decode(Payload, alloc, raw_payload, .{});
    if (!std.mem.eql(u8, payload.version, "omos.capability-promotion/v1")) return error.InvalidCapabilityPromotion;
    if (payload.source_workspace) |ws| if (!authority.safeIdentity(ws)) return error.InvalidCapabilityPromotion;
    if (payload.source_revision) |rev| if (!validRevision(rev)) return error.InvalidCapabilityPromotion;
    if (!std.mem.eql(u8, payload.plan.version, "omos.capability-package-plan/v1")) return error.InvalidCapabilityPromotion;
    if (!payload.plan.declaration_complete or payload.plan.problems.len != 0) return error.IncompleteCapabilityPackage;

    for (payload.plan.paths) |selector| {
        if (!authority.validPath(selector.path, std.mem.endsWith(u8, selector.path, "/"))) return error.InvalidResourcePackagePath;
        if (!authority.permitsSelector(grant, selector.path)) return error.CompanyAccessDenied;
    }

    const parsed = try selectionsFromPlan(alloc, payload.plan);
    const candidate = try package.importDefinition(alloc, central_declaration, payload.plan);
    const verified_plan = try package.describe(alloc, candidate, parsed.selections);
    if (!verified_plan.declaration_complete or verified_plan.problems.len != 0) return error.IncompleteCapabilityPackage;
    const expected_graph = try package.graphHash(alloc, payload.plan);
    const verified_graph = try package.graphHash(alloc, verified_plan);
    if (!std.mem.eql(u8, expected_graph, verified_graph)) return error.InvalidCapabilityPromotion;

    var allowed: [1][]const u8 = undefined;
    var allowed_len: usize = 0;
    if (request_artifact) |req| {
        allowed[allowed_len] = req;
        allowed_len += 1;
    }
    try validateFiles(manager, grant, verified_plan, payload.files, view_revision, base_revision, allowed[0..allowed_len]);

    return .{
        .payload = payload,
        .verified_plan = verified_plan,
        .candidate = candidate,
        .graph_hash = verified_graph,
        .capabilities = parsed.capabilities,
        .definition_bytes = try model.canonical(alloc, candidate.value),
        .payload_bytes = try encode(alloc, payload),
    };
}

pub fn loadPlanAt(manager: workspace.Manager, task: workspace.Task, revision: []const u8) !?Payload {
    const promo = task.capability_promotion orelse return null;
    const raw = try artifact(manager, promo.plan, revision);
    const payload = try records.decode(Payload, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, payload.version, "omos.capability-promotion/v1")) return error.InvalidCapabilityPromotion;
    return payload;
}

/// Re-verify the promoted package against the live target trunk under the
/// publication writer fence and build the atomic activation payload.
pub fn activation(manager: workspace.Manager, task: workspace.Task, source: []const u8, target: []const u8) !?Activation {
    const promo = task.capability_promotion orelse return null;
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const alloc = manager.alloc;

    const raw_payload = try artifact(manager, promo.plan, source);
    _ = try artifact(manager, promo.declaration, source);
    const payload = try records.decode(Payload, alloc, raw_payload, .{});
    if (!std.mem.eql(u8, payload.version, "omos.capability-promotion/v1")) return error.InvalidCapabilityPromotion;
    if (!std.mem.eql(u8, payload.plan.version, "omos.capability-package-plan/v1")) return error.InvalidCapabilityPromotion;
    if (!payload.plan.declaration_complete or payload.plan.problems.len != 0) return error.IncompleteCapabilityPackage;

    const target_declaration = try manager.loadDeclaration(target);
    const parsed = try selectionsFromPlan(alloc, payload.plan);
    const candidate = try package.importDefinition(alloc, target_declaration, payload.plan);
    const verified_plan = try package.describe(alloc, candidate, parsed.selections);
    if (!verified_plan.declaration_complete or verified_plan.problems.len != 0) return error.IncompleteCapabilityPackage;

    const graph_hash = try package.graphHash(alloc, verified_plan);
    if (!std.mem.eql(u8, graph_hash, promo.graph_hash) or !std.mem.eql(u8, graph_hash, try package.graphHash(alloc, payload.plan))) {
        return error.InvalidCapabilityPromotion;
    }

    var allowed: [3][]const u8 = undefined;
    var allowed_len: usize = 0;
    allowed[allowed_len] = promo.plan;
    allowed_len += 1;
    allowed[allowed_len] = promo.declaration;
    allowed_len += 1;
    if (task.request_artifact) |req| {
        allowed[allowed_len] = req;
        allowed_len += 1;
    }
    try validateFiles(manager, null, verified_plan, payload.files, source, target, allowed[0..allowed_len]);

    const id = try workspace.hash(alloc, try encode(alloc, .{ graph_hash, binding.actor, binding.grant, task.id }));
    const data = .{
        .version = "omos.capability-promotion-record/v1",
        .workspace = manager.manifest.id,
        .task = task.id,
        .actor = binding.actor,
        .grant = binding.grant,
        .graph_hash = graph_hash,
        .plan = promo.plan,
        .capabilities = parsed.capabilities,
        .source_workspace = payload.source_workspace,
        .source_revision = payload.source_revision,
    };
    try model.validateRecord(candidate.semantic, "omos_capability_promotion", try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, data), .{}), true);

    return .{
        .definition = try model.canonical(alloc, candidate.value),
        .definition_hash = candidate.hash,
        .graph_hash = graph_hash,
        .plan_artifact = promo.plan,
        .capabilities = parsed.capabilities,
        .record_path = try alloc.print("records/omos_capability_promotion/{s}.json", .{id}),
        .record = try encode(alloc, .{ .entity = "omos_capability_promotion", .id = id, .task = task.id, .data = data }),
    };
}

pub fn verifyPublication(manager: workspace.Manager, task: workspace.Task, source: []const u8, plan_artifact: []const u8, graph_hash: []const u8) !void {
    const promo = task.capability_promotion orelse return error.InvalidCapabilityPromotion;
    if (!std.mem.eql(u8, promo.plan, plan_artifact) or !std.mem.eql(u8, promo.graph_hash, graph_hash)) {
        return error.InvalidCapabilityPromotion;
    }
    const raw = try artifact(manager, plan_artifact, source);
    const payload = try records.decode(Payload, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, payload.version, "omos.capability-promotion/v1")) return error.InvalidCapabilityPromotion;
    if (!std.mem.eql(u8, try package.graphHash(manager.alloc, payload.plan), graph_hash)) return error.InvalidCapabilityPromotion;
}

test "company_promotion: local export, additive fence, approval toggle modes, and full A-to-central-to-B round-trip" {
    const io = @import("../shared/io.zig");
    const service = @import("company_service.zig");
    const local_promo = @import("capability_promotion.zig");
    const policy_mod = @import("company_promotion_policy.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const local_repo = try std.Io.Dir.path.join(alloc, &.{ root, "local-a.fossil" });
    const central_repo = try std.Io.Dir.path.join(alloc, &.{ root, "central.fossil" });
    const project_dir = try std.Io.Dir.path.join(alloc, &.{ root, "project" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project_dir);

    var environ = std.process.Environ.Map.init(alloc);
    try environ.put("HOME", root);
    if (io.getenv("PATH")) |p| try environ.put("PATH", p);
    const EnvFallback = struct {
        const empty = std.process.Environ.Map.init(std.heap.page_allocator);
    };
    const prev_environ = io.environMap();
    io.setEnvironMap(&environ);
    defer if (prev_environ) |prev| io.setEnvironMap(prev) else io.setEnvironMap(&EnvFallback.empty);

    var local_queue: workspace.WriterQueue = .{};
    defer local_queue.deinit();
    var local_mgr = try workspace.Manager.init(alloc, local_repo);
    local_mgr.writer_queue = &local_queue;

    // Actor A builds a new capability + portable skill + executable helper + unrelated private research locally.
    const seed_task = try local_mgr.start("build-cap", project_dir, "Build invoice_audit capability locally", null);
    const skill_md = "---\nname: invoice-audit\ndescription: Audit vendor invoices.\n---\n# Invoice Audit\n";
    const helper_sh = "#!/bin/sh\necho audit\n";
    _ = try local_mgr.checkpointContent(seed_task, &.{
        .{ .path = "skills/invoice-audit/SKILL.md", .content = skill_md, .previous_hash = null, .executable = false },
        .{ .path = "skills/invoice-audit/run.sh", .content = helper_sh, .previous_hash = null, .executable = true },
        .{ .path = "memory/private-research.md", .content = "secret local scratchpad", .previous_hash = null, .executable = false },
        .{ .path = "documents/unrelated-notes.md", .content = "do not promote", .previous_hash = null, .executable = false },
    });
    const seed_assessment = try encode(alloc, .{
        .contractId = seed_task.id,
        .version = seed_task.definition.version,
        .obligations = &.{.{ .id = "request_complete", .status = "met", .evidence = &.{"skills/invoice-audit/SKILL.md"}, .note = "Created local skill files" }},
    });
    _ = try local_mgr.publish(seed_task, .{
        .task_id = seed_task.id,
        .revision = try local_mgr.revision(seed_task.branch),
        .contract_version = seed_task.definition.version,
        .disposition = "fulfilled",
        .candidate = "Created local invoice_audit skill and helper",
        .assessment = seed_assessment,
    });

    // Additively propose the invoice_audit capability, realisation, and portable skill resource on local trunk.
    const base_decl = try local_mgr.loadDeclaration("trunk");
    var local_decl_val = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, base_decl.value), .{});
    const spec_obj = local_decl_val.object.getPtr("spec").?;
    try spec_obj.object.getPtr("resources").?.object.getPtr("skills").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"invoice_audit_skill","name":"Invoice Audit Skill","offers":["invoice_rules"],"spec":{"implementation":"fossil_skill","portability":{"version":"omos.resource-portability/v1","paths":["skills/invoice-audit/"]}}}
    , .{}));
    try spec_obj.object.getPtr("capabilities").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"invoice_audit","name":"Invoice Audit","description":"Audit vendor invoices.","requires":[{"id":"reasoning","primitiveFamily":"inference"},{"id":"invoice_rules","primitiveFamily":"skills"}],"realisations":["invoice_audit_v1"]}
    , .{}));
    try spec_obj.object.getPtr("realisations").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"invoice_audit_v1","name":"Invoice Audit v1","capability":"invoice_audit","participants":[{"resource":"configured_model","supplies":["reasoning"]},{"resource":"invoice_audit_skill","supplies":["invoice_rules"]}]}
    , .{}));
    _ = try local_mgr.proposeDefinition(null, try model.canonical(alloc, local_decl_val), null);

    // 1. Local package export packs ONLY the selected capability closure and excludes private memory/documents.
    const archive_path = try std.Io.Dir.path.join(alloc, &.{ root, "invoice-audit.tar" });
    const export_result = try local_promo.exportArchive(local_mgr, &.{.{ .capability = "invoice_audit" }}, archive_path);
    try std.testing.expectEqualStrings("omos.local-capability-package/v1", model.text(export_result, "version"));
    try std.testing.expectEqual(@as(i64, 2), model.field(export_result, "files").?.integer);
    const verified_local = try local_promo.verifyLocalArchive(alloc, archive_path);
    try std.testing.expectEqual(@as(usize, 2), verified_local.files.len);
    for (verified_local.files) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.path, "skills/invoice-audit/"));
        if (std.mem.eql(u8, entry.path, "skills/invoice-audit/run.sh")) try std.testing.expect(entry.executable);
        if (std.mem.eql(u8, entry.path, "skills/invoice-audit/SKILL.md")) try std.testing.expect(!entry.executable);
    }

    // Initialize Central Company Fossil.
    var central_queue: workspace.WriterQueue = .{};
    defer central_queue.deinit();
    var central_mgr = try workspace.Manager.init(alloc, central_repo);
    central_mgr.writer_queue = &central_queue;

    const init_res = try service.administer(central_mgr, try encode(alloc, .{ .version = "omos.company-admin/v1", .action = "initialize" }));
    var admin_rev = model.text(try std.json.parseFromSliceLeaky(Value, alloc, init_res, .{}), "revision");

    // Verify default promotion policy is require_human_approval.
    const default_policy_raw = try service.administer(central_mgr, try encode(alloc, .{ .version = "omos.company-admin/v1", .action = "inspect_promotion_policy" }));
    const default_policy = try std.json.parseFromSliceLeaky(Value, alloc, default_policy_raw, .{});
    try std.testing.expectEqualStrings("require_human_approval", model.text(model.field(default_policy, "policy").?, "mode"));

    // Create Actor A (auto grant, human_approval=false, WITH promote_capability),
    // Actor A_manual (human_approval=true, WITH promote_capability),
    // Actor A_no_promo (WITHOUT promote_capability, only submit),
    // and Actor B (consumer with discover + export_scope).
    const kp_a = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    const pub_a = try alloc.dupe(u8, &std.fmt.bytesToHex(kp_a.public_key.toBytes(), .lower));
    const kp_b = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    const pub_b = try alloc.dupe(u8, &std.fmt.bytesToHex(kp_b.public_key.toBytes(), .lower));
    const expires = io.milliTimestamp() + 3_600_000;

    for ([_]authority.Grant{
        .{ .id = "grant_a_auto", .actor = "actor_a", .public_key = pub_a, .paths = &.{"skills/"}, .actions = &.{ .create_view, .checkpoint, .status, .promote_capability }, .expires_ms = expires, .human_approval = false },
        .{ .id = "grant_a_manual", .actor = "actor_a", .public_key = pub_a, .paths = &.{"skills/"}, .actions = &.{ .create_view, .checkpoint, .status, .promote_capability }, .expires_ms = expires, .human_approval = true },
        .{ .id = "grant_a_submit_only", .actor = "actor_a", .public_key = pub_a, .paths = &.{"skills/"}, .actions = &.{ .create_view, .checkpoint, .status, .submit }, .expires_ms = expires, .human_approval = false },
        .{ .id = "grant_b", .actor = "actor_b", .public_key = pub_b, .paths = &.{"skills/"}, .actions = &.{ .discover, .export_scope, .read, .status }, .expires_ms = expires, .human_approval = false },
    }) |g| {
        const res = try service.administer(central_mgr, try encode(alloc, .{ .version = "omos.company-admin/v1", .action = "grant", .revision = admin_rev, .grant = g }));
        admin_rev = model.text(try std.json.parseFromSliceLeaky(Value, alloc, res, .{}), "revision");
    }

    const callCompany = struct {
        fn send(m: workspace.Manager, a: std.mem.Allocator, signer: std.crypto.sign.Ed25519.KeyPair, req: anytype) !Value {
            const payload = try encode(a, req);
            const sig = try signer.sign(payload, null);
            const sig_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);
            const env = try encode(a, .{ .payload = payload, .signature = &sig_hex });
            const resp = try service.execute(m, env, true);
            const envelope = try std.json.parseFromSliceLeaky(Value, a, resp, .{});
            const receipt = try std.json.parseFromSliceLeaky(Value, a, model.text(envelope, "payload"), .{});
            return model.field(receipt, "result").?;
        }
    }.send;

    const collected = try local_promo.collectLocal(local_mgr, &.{.{ .capability = "invoice_audit" }});
    var file_entries: std.ArrayList(FileEntry) = .empty;
    for (collected.files) |f| try file_entries.append(alloc, .{ .path = f.path, .sha256 = f.sha256, .bytes = f.bytes, .executable = f.executable });
    const promo_payload = try encode(alloc, Payload{
        .source_workspace = collected.workspace,
        .source_revision = collected.revision,
        .plan = collected.plan,
        .files = file_entries.items,
    });

    const req_expires = io.milliTimestamp() + 120_000;

    // 2a. Actor without promote_capability permission is denied.
    const denied_view = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_submit_only",
        .operation = "op-no-promo-view",
        .expires_ms = req_expires,
        .action = "create_view",
        .revision = try central_mgr.revision("trunk"),
        .objective = "Attempt unauthorized promotion",
    });
    try std.testing.expectError(error.CompanyAccessDenied, callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_submit_only",
        .operation = "op-no-promo-submit",
        .expires_ms = req_expires,
        .action = "promote_capability",
        .view = model.text(denied_view, "view"),
        .revision = model.text(denied_view, "revision"),
        .candidate = "Unauthorized promotion",
        .capability_plan = promo_payload,
    }));

    // 2b. Reject colliding capability redefinition (attempting to alter existing general_task resource).
    const native_plan = try package.describe(alloc, try central_mgr.loadDeclaration("trunk"), &.{.{ .capability = "general_task" }});
    var colliding_plan = native_plan;
    const dup_resources = try alloc.dupe(@TypeOf(native_plan.resources[0]), native_plan.resources);
    var mutated = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, dup_resources[0].definition), .{});
    try mutated.object.put(alloc, "name", .{ .string = "Mutated Native Resource" });
    dup_resources[0].definition = mutated;
    colliding_plan.resources = dup_resources;
    const colliding_payload = try encode(alloc, Payload{ .plan = colliding_plan, .files = &.{} });
    const col_view = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-collide-view",
        .expires_ms = req_expires,
        .action = "create_view",
        .revision = try central_mgr.revision("trunk"),
        .objective = "Attempt colliding capability promotion",
    });
    try std.testing.expectError(error.CapabilityImportCollision, callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-collide-submit",
        .expires_ms = req_expires,
        .action = "promote_capability",
        .view = model.text(col_view, "view"),
        .revision = model.text(col_view, "revision"),
        .candidate = "Colliding promotion",
        .capability_plan = colliding_payload,
    }));

    const currentAdminRev = struct {
        fn get(m: workspace.Manager, a: std.mem.Allocator) ![]const u8 {
            const raw = try service.administer(m, try encode(a, .{ .version = "omos.company-admin/v1", .action = "status" }));
            return model.text(try std.json.parseFromSliceLeaky(Value, a, raw, .{}), "revision");
        }
    }.get;

    // 2c. Reject unrelated staged files outside plan.paths on a promotion view.
    const dirty_view = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-dirty-view",
        .expires_ms = req_expires,
        .action = "create_view",
        .revision = try central_mgr.revision("trunk"),
        .objective = "Attempt promotion with unrelated file",
    });
    const dirty_id = model.text(dirty_view, "view");
    var dirty_rev = model.text(dirty_view, "revision");
    for (collected.files, 0..) |f, idx| {
        const enc = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(f.content.len));
        const ck = try callCompany(central_mgr, alloc, kp_a, .{
            .version = "omos.company/v1",
            .workspace = central_mgr.manifest.id,
            .actor = "actor_a",
            .grant = "grant_a_auto",
            .operation = try alloc.print("op-dirty-ckpt-{d}", .{idx}),
            .expires_ms = req_expires,
            .action = "checkpoint",
            .view = dirty_id,
            .revision = dirty_rev,
            .path = f.path,
            .content = std.base64.standard.Encoder.encode(enc, f.content),
            .encoding = "base64",
            .executable = f.executable,
        });
        dirty_rev = model.text(ck, "revision");
    }
    const stray_ckpt = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-dirty-stray",
        .expires_ms = req_expires,
        .action = "checkpoint",
        .view = dirty_id,
        .revision = dirty_rev,
        .path = "skills/unrelated/scratch.md",
        .content = "stray notes",
        .encoding = "utf8",
    });
    try std.testing.expectError(error.InvalidCapabilityPromotion, callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-dirty-submit",
        .expires_ms = req_expires,
        .action = "promote_capability",
        .view = dirty_id,
        .revision = model.text(stray_ckpt, "revision"),
        .candidate = "Promotion with stray file",
        .capability_plan = promo_payload,
    }));

    // 3. Toggle mode = require_human_approval: even with grant.human_approval == false, auto-publish is BLOCKED until operator approves!
    const v1 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-promo-view-1",
        .expires_ms = req_expires,
        .action = "create_view",
        .revision = try central_mgr.revision("trunk"),
        .objective = "Promote invoice_audit capability",
    });
    const v1_id = model.text(v1, "view");
    var v1_rev = model.text(v1, "revision");
    for (collected.files, 0..) |f, idx| {
        const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(f.content.len));
        const ckpt = try callCompany(central_mgr, alloc, kp_a, .{
            .version = "omos.company/v1",
            .workspace = central_mgr.manifest.id,
            .actor = "actor_a",
            .grant = "grant_a_auto",
            .operation = try alloc.print("op-promo-ckpt-{d}", .{idx}),
            .expires_ms = req_expires,
            .action = "checkpoint",
            .view = v1_id,
            .revision = v1_rev,
            .path = f.path,
            .content = std.base64.standard.Encoder.encode(encoded, f.content),
            .encoding = "base64",
            .executable = f.executable,
        });
        v1_rev = model.text(ckpt, "revision");
    }

    const promo1 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-promo-submit-1",
        .expires_ms = req_expires,
        .action = "promote_capability",
        .view = v1_id,
        .revision = v1_rev,
        .candidate = "Promoted invoice_audit capability with verified skill files.",
        .capability_plan = promo_payload,
    });
    try std.testing.expectEqualStrings("approval_required", model.text(promo1, "state"));
    try std.testing.expect(model.field(promo1, "approval_required").?.bool);
    try std.testing.expectEqualStrings("require_human_approval", model.text(promo1, "promotion_policy"));

    // Independent review cannot publish before operator approval!
    const inspected1_raw = try service.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "inspect_proposal",
        .revision = try currentAdminRev(central_mgr, alloc),
        .view = v1_id,
    }));
    const inspected1 = try std.json.parseFromSliceLeaky(Value, alloc, inspected1_raw, .{});
    try std.testing.expect(model.field(inspected1, "approval_required").?.bool);
    const task1_id = model.text(model.field(inspected1, "candidate").?, "task");
    const task1 = try central_mgr.loadTask(task1_id);
    _ = try central_mgr.claimReview("test-reviewer");
    const task1_fresh = try central_mgr.loadTask(task1.id);
    const job1_fresh = try central_mgr.loadReviewJob(task1_fresh, task1_fresh.review_job.?);
    var review_mgr1 = central_mgr;
    review_mgr1.review_fence = .{ .task = task1_fresh.id, .job = job1_fresh.id, .generation = job1_fresh.generation, .owner = job1_fresh.owner };
    const assess1 = try encode(alloc, .{
        .contractId = task1_fresh.id,
        .version = task1_fresh.definition.version,
        .obligations = &.{.{ .id = "request_complete", .status = "met", .evidence = &.{"skills/invoice-audit/SKILL.md"}, .note = "Verified promotion files" }},
    });
    try std.testing.expectError(error.CompanyApprovalRequired, review_mgr1.publish(task1_fresh, .{
        .task_id = task1_fresh.id,
        .revision = try review_mgr1.revision(task1_fresh.branch),
        .contract_version = task1_fresh.definition.version,
        .disposition = "fulfilled",
        .candidate = "Promoted invoice_audit capability with verified skill files.",
        .assessment = assess1,
    }));
    try review_mgr1.finishReviewJob(job1_fresh, .blocked, "CompanyApprovalRequired");

    // Operator approves exact proposal hash, then review publishes atomically onto central trunk!
    const approved1_raw = try service.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "approve",
        .revision = try currentAdminRev(central_mgr, alloc),
        .view = v1_id,
        .candidate_hash = model.text(inspected1, "candidate_hash"),
        .expires_ms = io.milliTimestamp() + 600_000,
    }));
    _ = approved1_raw;
    const task1_approved = try central_mgr.loadTask(task1.id);
    _ = try central_mgr.claimReview("test-reviewer-2");
    const job1_approved = try central_mgr.loadReviewJob(task1_approved, task1_approved.review_job.?);
    var pub_mgr1 = central_mgr;
    pub_mgr1.review_fence = .{ .task = task1_approved.id, .job = job1_approved.id, .generation = job1_approved.generation, .owner = job1_approved.owner };
    _ = try pub_mgr1.publish(task1_approved, .{
        .task_id = task1_approved.id,
        .revision = try pub_mgr1.revision(task1_approved.branch),
        .contract_version = task1_approved.definition.version,
        .disposition = "fulfilled",
        .candidate = "Promoted invoice_audit capability with verified skill files.",
        .assessment = assess1,
    });

    // Verify central trunk now contains invoice_audit capability + files!
    const central_decl_after = try central_mgr.loadDeclaration("trunk");
    const central_plan = try package.describe(alloc, central_decl_after, &.{.{ .capability = "invoice_audit" }});
    try std.testing.expect(central_plan.declaration_complete);
    try std.testing.expectEqualStrings(skill_md, try central_mgr.trunkContent("skills/invoice-audit/SKILL.md"));

    // 4. Full round-trip: Operator grants Actor B access to invoice_audit -> Actor B discovers & exports it!
    _ = try service.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "grant_capabilities",
        .revision = try currentAdminRev(central_mgr, alloc),
        .id = "grant_b",
        .capabilities = &.{"invoice_audit"},
    }));

    const b_list = try callCompany(central_mgr, alloc, kp_b, .{
        .version = "omos.company/v2",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_b",
        .grant = "grant_b",
        .operation = "op-b-discover-list",
        .expires_ms = req_expires,
        .action = "discover",
        .capability = "*",
    });
    try std.testing.expectEqual(@as(i64, 1), model.field(b_list, "total").?.integer);
    try std.testing.expectEqualStrings("invoice_audit", model.items(b_list, "capabilities")[0].string);

    const b_export = try callCompany(central_mgr, alloc, kp_b, .{
        .version = "omos.company/v2",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_b",
        .grant = "grant_b",
        .operation = "op-b-export-cap",
        .expires_ms = req_expires,
        .action = "export_scope",
        .revision = try central_mgr.revision("trunk"),
        .capability = "invoice_audit",
        .capability_selections = &.{.{ .capability = "invoice_audit" }},
    });
    try std.testing.expectEqualStrings("declared_complete", model.text(b_export, "dependency_closure"));
    try std.testing.expectEqual(@as(i64, 2), model.field(b_export, "total").?.integer);

    // 5. Switch policy toggle to follow_actor_grant:
    //    - Actor A (human_approval == false) promotes a second capability -> auto-publishes after review WITHOUT operator approval!
    //    - Actor A_manual (human_approval == true) promotes a third capability -> STILL requires operator approval!
    _ = try service.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "set_promotion_policy",
        .revision = try currentAdminRev(central_mgr, alloc),
        .mode = "follow_actor_grant",
    }));
    try std.testing.expectEqual(policy_mod.Mode.follow_actor_grant, (try policy_mod.load(central_mgr)).mode);

    // Build second capability (expense_audit) locally for follow_actor_grant auto-publish test.
    var decl2_val = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, central_decl_after.value), .{});
    const spec2 = decl2_val.object.getPtr("spec").?;
    try spec2.object.getPtr("resources").?.object.getPtr("skills").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"expense_audit_skill","name":"Expense Audit Skill","offers":["expense_rules"],"spec":{"implementation":"fossil_skill","portability":{"version":"omos.resource-portability/v1","paths":["skills/expense-audit/"]}}}
    , .{}));
    try spec2.object.getPtr("capabilities").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"expense_audit","name":"Expense Audit","description":"Audit expenses.","requires":[{"id":"reasoning","primitiveFamily":"inference"},{"id":"expense_rules","primitiveFamily":"skills"}],"realisations":["expense_audit_v1"]}
    , .{}));
    try spec2.object.getPtr("realisations").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"expense_audit_v1","name":"Expense Audit v1","capability":"expense_audit","participants":[{"resource":"configured_model","supplies":["reasoning"]},{"resource":"expense_audit_skill","supplies":["expense_rules"]}]}
    , .{}));
    const plan2 = try package.describe(alloc, try model.parse(alloc, try model.canonical(alloc, decl2_val)), &.{.{ .capability = "expense_audit" }});
    const expense_skill = "---\nname: expense-audit\ndescription: Audit expenses.\n---\n";
    const payload2 = try encode(alloc, Payload{
        .plan = plan2,
        .files = &.{.{ .path = "skills/expense-audit/SKILL.md", .sha256 = try workspace.hash(alloc, expense_skill), .bytes = expense_skill.len, .executable = false }},
    });

    const v2 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-promo-view-2",
        .expires_ms = req_expires,
        .action = "create_view",
        .revision = try central_mgr.revision("trunk"),
        .objective = "Promote expense_audit under follow_actor_grant",
    });
    const v2_id = model.text(v2, "view");
    const enc2 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(expense_skill.len));
    const ckpt2 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-promo-ckpt-2",
        .expires_ms = req_expires,
        .action = "checkpoint",
        .view = v2_id,
        .revision = model.text(v2, "revision"),
        .path = "skills/expense-audit/SKILL.md",
        .content = std.base64.standard.Encoder.encode(enc2, expense_skill),
        .encoding = "base64",
        .executable = false,
    });
    const promo2 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_auto",
        .operation = "op-promo-submit-2",
        .expires_ms = req_expires,
        .action = "promote_capability",
        .view = v2_id,
        .revision = model.text(ckpt2, "revision"),
        .candidate = "Promoted expense_audit without operator gate.",
        .capability_plan = payload2,
    });
    try std.testing.expectEqualStrings("verification_pending", model.text(promo2, "state"));
    try std.testing.expect(!model.field(promo2, "approval_required").?.bool);
    try std.testing.expectEqualStrings("follow_actor_grant", model.text(promo2, "promotion_policy"));

    // Review publishes expense_audit directly WITHOUT operator approval!
    const insp2 = try std.json.parseFromSliceLeaky(Value, alloc, try service.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "inspect_proposal",
        .revision = try currentAdminRev(central_mgr, alloc),
        .view = v2_id,
    })), .{});
    try std.testing.expect(!model.field(insp2, "approval_required").?.bool);
    const task2 = try central_mgr.loadTask(model.text(model.field(insp2, "candidate").?, "task"));
    _ = try central_mgr.claimReview("test-reviewer-3");
    const job2 = try central_mgr.loadReviewJob(task2, task2.review_job.?);
    var pub_mgr2 = central_mgr;
    pub_mgr2.review_fence = .{ .task = task2.id, .job = job2.id, .generation = job2.generation, .owner = job2.owner };
    const assess2 = try encode(alloc, .{
        .contractId = task2.id,
        .version = task2.definition.version,
        .obligations = &.{.{ .id = "request_complete", .status = "met", .evidence = &.{"skills/expense-audit/SKILL.md"}, .note = "Verified" }},
    });
    _ = try pub_mgr2.publish(task2, .{
        .task_id = task2.id,
        .revision = try pub_mgr2.revision(task2.branch),
        .contract_version = task2.definition.version,
        .disposition = "fulfilled",
        .candidate = "Promoted expense_audit without operator gate.",
        .assessment = assess2,
    });
    try central_mgr.verify();
    try std.testing.expect((try package.describe(alloc, try central_mgr.loadDeclaration("trunk"), &.{.{ .capability = "expense_audit" }})).declaration_complete);

    // Under follow_actor_grant, a grant with human_approval=true STILL requires operator approval!
    var decl3_val = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, (try central_mgr.loadDeclaration("trunk")).value), .{});
    const spec3 = decl3_val.object.getPtr("spec").?;
    try spec3.object.getPtr("resources").?.object.getPtr("skills").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"tax_audit_skill","name":"Tax Audit Skill","offers":["tax_rules"],"spec":{"implementation":"fossil_skill","portability":{"version":"omos.resource-portability/v1","paths":["skills/tax-audit/"]}}}
    , .{}));
    try spec3.object.getPtr("capabilities").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"tax_audit","name":"Tax Audit","description":"Audit taxes.","requires":[{"id":"reasoning","primitiveFamily":"inference"},{"id":"tax_rules","primitiveFamily":"skills"}],"realisations":["tax_audit_v1"]}
    , .{}));
    try spec3.object.getPtr("realisations").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc,
        \\{"id":"tax_audit_v1","name":"Tax Audit v1","capability":"tax_audit","participants":[{"resource":"configured_model","supplies":["reasoning"]},{"resource":"tax_audit_skill","supplies":["tax_rules"]}]}
    , .{}));
    const plan3 = try package.describe(alloc, try model.parse(alloc, try model.canonical(alloc, decl3_val)), &.{.{ .capability = "tax_audit" }});
    const tax_skill = "---\nname: tax-audit\ndescription: Audit taxes.\n---\n";
    const payload3 = try encode(alloc, Payload{
        .plan = plan3,
        .files = &.{.{ .path = "skills/tax-audit/SKILL.md", .sha256 = try workspace.hash(alloc, tax_skill), .bytes = tax_skill.len, .executable = false }},
    });
    const v3 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_manual",
        .operation = "op-promo-view-3",
        .expires_ms = req_expires,
        .action = "create_view",
        .revision = try central_mgr.revision("trunk"),
        .objective = "Promote tax_audit with human_approval grant",
    });
    const v3_id = model.text(v3, "view");
    const enc3 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(tax_skill.len));
    const ckpt3 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_manual",
        .operation = "op-promo-ckpt-3",
        .expires_ms = req_expires,
        .action = "checkpoint",
        .view = v3_id,
        .revision = model.text(v3, "revision"),
        .path = "skills/tax-audit/SKILL.md",
        .content = std.base64.standard.Encoder.encode(enc3, tax_skill),
        .encoding = "base64",
        .executable = false,
    });
    const promo3 = try callCompany(central_mgr, alloc, kp_a, .{
        .version = "omos.company/v1",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_manual",
        .operation = "op-promo-submit-3",
        .expires_ms = req_expires,
        .action = "promote_capability",
        .view = v3_id,
        .revision = model.text(ckpt3, "revision"),
        .candidate = "Promoted tax_audit under manual grant.",
        .capability_plan = payload3,
    });
    try std.testing.expectEqualStrings("approval_required", model.text(promo3, "state"));
    try std.testing.expect(model.field(promo3, "approval_required").?.bool);
    const insp3 = try std.json.parseFromSliceLeaky(Value, alloc, try service.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "inspect_proposal",
        .revision = try currentAdminRev(central_mgr, alloc),
        .view = v3_id,
    })), .{});
    const task3 = try central_mgr.loadTask(model.text(model.field(insp3, "candidate").?, "task"));
    _ = try central_mgr.claimReview("test-reviewer-4");
    const job3 = try central_mgr.loadReviewJob(task3, task3.review_job.?);
    var pub_mgr3 = central_mgr;
    pub_mgr3.review_fence = .{ .task = task3.id, .job = job3.id, .generation = job3.generation, .owner = job3.owner };
    const assess3 = try encode(alloc, .{
        .contractId = task3.id,
        .version = task3.definition.version,
        .obligations = &.{.{ .id = "request_complete", .status = "met", .evidence = &.{"skills/tax-audit/SKILL.md"}, .note = "Verified" }},
    });
    try std.testing.expectError(error.CompanyApprovalRequired, pub_mgr3.publish(task3, .{
        .task_id = task3.id,
        .revision = try pub_mgr3.revision(task3.branch),
        .contract_version = task3.definition.version,
        .disposition = "fulfilled",
        .candidate = "Promoted tax_audit under manual grant.",
        .assessment = assess3,
    }));
}
