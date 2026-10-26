//! Signed, scoped company operations over the same Fossil manager. The shared
//! bearer endpoint remains a local-owner API; company callers use actor keys.
const std = @import("std");
const io = @import("../shared/io.zig");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const keys = @import("company_keys.zig");
const model = @import("definition.zig");
const fossil_manifest = @import("fossil_manifest.zig");
const read_dependencies = @import("company_reads.zig");
const uploads = @import("company_upload.zig");
const ownership = @import("company_execution.zig");
const task_scope = @import("company_task_scope.zig");
const runtimes = @import("company_runtime.zig");

pub const progress_stream_limit = 4;
pub const progress_stream_seconds = 30;

const Journal = struct {
    version: []const u8 = "omos.company-operation/v1",
    actor: []const u8,
    grant: []const u8,
    operation: []const u8,
    request_hash: []const u8,
    state: enum { pending, completed, failed, uncertain },
    result: ?[]const u8 = null,
    failure: ?[]const u8 = null,
    view: ?[]const u8 = null,
    request: ?[]const u8 = null,
    receipt: ?[]const u8 = null,
    reconciled_by: ?[]const u8 = null,
};
const View = struct { id: []const u8, actor: []const u8, grant: []const u8, task: []const u8, base: []const u8, pending: ?[]const u8 = null, reads: []const read_dependencies.Reference = &.{}, scope: ?[]const u8 = null, created_at_ms: ?i64 = null };
const Submission = struct {
    version: []const u8 = "omos.company-submission/v1",
    task: []const u8,
    operation: []const u8,
    request_hash: []const u8,
    revision: []const u8,
    contract_hash: []const u8,
    candidate_hash: []const u8,
    reads: []const read_dependencies.Reference,
};
const Admin = struct {
    version: []const u8,
    action: enum { initialize, status, grant, revoke, rotate, inspect_proposal, approve, deny, grant_capabilities, inspect_capabilities, workers, evaluate, runtimes, archive, desired },
    revision: ?[]const u8 = null,
    grant: ?authority.Grant = null,
    id: ?[]const u8 = null,
    view: ?[]const u8 = null,
    candidate_hash: ?[]const u8 = null,
    expires_ms: ?i64 = null,
    capabilities: ?[]const []const u8 = null,
    worker: ?@import("company_worker_jobs.zig").Request = null,
    evaluation: ?@import("company_validation.zig").Request = null,
    runtime: ?@import("company_runtime.zig").Request = null,
    archive: ?@import("company_archive.zig").Request = null,
    desired: ?@import("company_desired.zig").Request = null,
};
fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn parse(alloc: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
}
fn state(manager: workspace.Manager) !authority.State {
    const value = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    if (!std.mem.eql(u8, value.version, "omos.company-authority/v1") or !std.mem.eql(u8, value.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    return value;
}

fn viewBytes(manager: workspace.Manager, view: View) ![]const u8 {
    var value = try parse(manager.alloc, try encode(manager.alloc, view));
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    const accepts_reads = for (declaration.semantic.entityTypes) |entity| {
        if (std.mem.eql(u8, entity.id, "omos_workspace_view")) break model.field(entity.fields, "reads") != null;
    } else false;
    if (!accepts_reads) {
        if (view.reads.len > 0) return error.CompanyDefinitionUpdateRequired;
        _ = value.object.swapRemove("reads");
    }
    if (view.scope == null) _ = value.object.swapRemove("scope");
    const accepts_created = for (declaration.semantic.entityTypes) |entity| {
        if (std.mem.eql(u8, entity.id, "omos_workspace_view")) break model.field(entity.fields, "created_at_ms") != null;
    } else false;
    if (view.created_at_ms == null or !accepts_created) _ = value.object.swapRemove("created_at_ms");
    return encode(manager.alloc, value);
}

/// Administrative changes require local operator access. OmniForm definitions
/// and scoped actor requests can never enroll or enlarge a root authority.
pub fn administer(original: workspace.Manager, raw: []const u8) ![]const u8 {
    var manager = original;
    const request = try records.decode(Admin, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, request.version, "omos.company-admin/v1")) return error.UnsupportedCompanyApi;
    const lease = try manager.companyOperationLease();
    defer lease.release();
    manager.company_operation_held = true;
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    const capability_control = request.action == .grant_capabilities or request.action == .inspect_capabilities;
    const admin_operation = switch (request.action) {
        .grant_capabilities => "omos_grant_capability_scope",
        .inspect_capabilities => "omos_inspect_capability_scopes",
        .workers => if (request.worker != null and request.worker.?.change == .checkpoint) "omos_company_worker_checkpoint" else "omos_company_worker_admin",
        .evaluate => "omos_company_evaluation",
        .runtimes => "omos_company_runtime_admin",
        .archive => "omos_company_archive_admin",
        .desired => "omos_company_desired_admin",
        else => "omos_company_admin",
    };
    if (model.hasOperation(declaration, admin_operation)) {
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, raw), .input);
    } else if (capability_control or request.action == .workers or request.action == .evaluate or request.action == .runtimes or request.action == .archive or request.action == .desired or request.action == .inspect_proposal or request.action == .approve or request.action == .deny) {
        // Older profiles retain their administrative recovery interface. New
        // decisions require the declared operation and protected record type.
        return error.CompanyDefinitionUpdateRequired;
    }
    if (request.worker != null and request.action != .workers) return error.UnsupportedCompanyApi;
    if (request.evaluation != null and request.action != .evaluate) return error.UnsupportedCompanyApi;
    if (request.runtime != null and request.action != .runtimes) return error.UnsupportedCompanyApi;
    if (request.archive != null and request.action != .archive) return error.UnsupportedCompanyApi;
    if (request.desired != null and request.action != .desired) return error.UnsupportedCompanyApi;
    const recovery_lease = if (request.action == .rotate) try keys.recoveryLease(manager) else null;
    defer if (recovery_lease) |held| held.release();
    const revision_id = try manager.companyRevision();
    if (request.action == .status) return encode(manager.alloc, .{ .revision = revision_id, .authority = try state(manager) });
    if (request.action != .initialize and request.action != .rotate) try validateInstance(manager);
    if (request.action == .desired) {
        const output = try @import("company_desired.zig").administer(manager, request.desired orelse return error.InvalidCompanyDesiredState);
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (request.action == .archive) {
        if (request.revision != null or request.worker != null or request.evaluation != null or request.runtime != null) return error.UnsupportedCompanyApi;
        const output = try @import("company_archive.zig").execute(manager, request.archive orelse return error.InvalidCompanyArchive);
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (request.action == .runtimes) {
        if (request.revision != null or request.worker != null or request.evaluation != null) return error.UnsupportedCompanyApi;
        const output = try @import("company_runtime.zig").administer(manager, request.runtime orelse return error.InvalidCompanyRuntime);
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (request.action == .evaluate) {
        if (request.revision != null or request.worker != null) return error.UnsupportedCompanyApi;
        const output = try @import("company_validation.zig").execute(manager, request.evaluation orelse return error.InvalidCompanyValidation);
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (request.action == .workers) {
        if (request.revision != null and !equal(request.revision, revision_id)) return error.WorkspaceRevisionChanged;
        const output = try @import("company_worker_jobs.zig").administer(manager, request.worker orelse return error.InvalidCompanyWorkerJob);
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (request.action == .inspect_capabilities) {
        if (request.revision != null and !equal(request.revision, revision_id)) return error.WorkspaceRevisionChanged;
        const established_revision = revision_id orelse return error.CompanyNotInitialized;
        const output = try encode(manager.alloc, .{ .revision = established_revision, .policy = try @import("company_capabilities.zig").load(manager) });
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (!equal(request.revision, revision_id)) return error.WorkspaceRevisionChanged;
    if (request.action == .grant_capabilities) {
        const scopes = @import("company_capabilities.zig");
        const policy = try scopes.assign(manager.alloc, try scopes.load(manager), try state(manager), declaration, request.id orelse return error.InvalidCompanyIdentity, request.capabilities orelse return error.MissingCapabilities, io.milliTimestamp());
        const revision = try manager.companyWrite(revision_id, &.{.{ .path = scopes.path, .content = try encode(manager.alloc, policy) }});
        const output = try encode(manager.alloc, .{ .revision = revision, .policy = policy });
        try model.validateOperation(manager.alloc, declaration, admin_operation, try parse(manager.alloc, output), .output);
        return output;
    }
    if (request.action == .inspect_proposal or request.action == .approve or request.action == .deny) {
        const approval = @import("company_approval.zig");
        const id = request.view orelse return error.CompanyViewRequired;
        if (!authority.safeIdentity(id)) return error.InvalidCompanyIdentity;
        const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{id})), .{});
        if (view.pending != null) return error.CompanyOperationRecoveryRequired;
        const execution = (try manager.tryTaskExecutionLease(view.task)) orelse return error.WorkspaceExecutionBusy;
        defer execution.release();
        const task = try manager.refreshTaskContext(try manager.loadTask(view.task));
        const current = try state(manager);
        const grant = try authority.liveGrant(current, view.grant, io.milliTimestamp());
        if (!std.mem.eql(u8, grant.actor, view.actor) or task.authority == null or !std.mem.eql(u8, task.authority.?.actor, view.actor) or !std.mem.eql(u8, task.authority.?.grant, view.grant)) return error.CompanyAccessDenied;
        const candidate = try approval.candidate(manager, task, try manager.currentRevision(task), current);
        const candidate_hash = try workspace.hash(manager.alloc, try encode(manager.alloc, candidate));
        if (request.action == .inspect_proposal) return encode(manager.alloc, .{ .revision = revision_id, .candidate = candidate, .candidate_hash = candidate_hash, .approval_required = grant.human_approval });
        const decision = try approval.decide(manager, task, current, request.candidate_hash orelse return error.MissingContent, request.action == .approve, request.expires_ms orelse return error.InvalidCompanyApprovalExpiry);
        const revision = try manager.companyWrite(revision_id, &.{.{ .path = try approval.path(manager.alloc, task.id), .content = try encode(manager.alloc, decision) }});
        // A decision changes authority only. A new verification invocation can
        // reuse retained evidence and never dispatches the actor's actions.
        const job = if (request.action == .approve) try manager.queueReview(task) else null;
        return encode(manager.alloc, .{ .revision = revision, .decision = decision, .job = if (job) |value| value.id else null });
    }
    var current: authority.State = undefined;
    if (request.action == .initialize) {
        if (revision_id != null) return error.CompanyAlreadyInitialized;
        const key = try keys.prepare(manager, 1, false);
        current = .{ .workspace = manager.manifest.id, .issuer = try manager.alloc.dupe(u8, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower)) };
    } else {
        current = try state(manager);
        if (request.action == .grant) {
            const grant = request.grant orelse return error.InvalidCompanyGrant;
            if (grant.parent != null) return error.InvalidCompanyDelegation;
            try authority.validateGrant(current, grant, io.milliTimestamp());
            for (current.grants) |existing| if (std.mem.eql(u8, existing.id, grant.id)) return error.CompanyGrantAlreadyExists;
            const grants = try manager.alloc.alloc(authority.Grant, current.grants.len + 1);
            @memcpy(grants[0..current.grants.len], current.grants);
            grants[current.grants.len] = grant;
            current.grants = grants;
        } else if (request.action == .revoke) {
            const id = request.id orelse return error.InvalidCompanyIdentity;
            const grants = try manager.alloc.dupe(authority.Grant, current.grants);
            const selected = for (grants) |*grant| {
                if (std.mem.eql(u8, grant.id, id)) break grant;
            } else return error.InvalidCompanyIdentity;
            selected.revoked = true;
            current.grants = grants;
        } else if (request.action == .rotate) {
            // Restoring a repository never restores issuer power implicitly.
            // An operator must recover/create the protected key and advance the
            // epoch. All old grants remain recorded but become revoked.
            const epoch = try keys.nextEpoch(manager, current.epoch);
            const key = try keys.prepare(manager, epoch, true);
            current.issuer = try manager.alloc.dupe(u8, &std.fmt.bytesToHex(key.public_key.toBytes(), .lower));
            current.epoch = epoch;
            const grants = try manager.alloc.dupe(authority.Grant, current.grants);
            for (grants) |*grant| grant.revoked = true;
            current.grants = grants;
        }
    }
    const revision = try manager.companyWrite(revision_id, &.{.{ .path = "authority/state.json", .content = try encode(manager.alloc, current) }});
    return encode(manager.alloc, .{ .revision = revision, .authority = current });
}
fn equal(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |left| if (b) |right| std.mem.eql(u8, left, right) else false else b == null;
}
fn operationPath(manager: workspace.Manager, actor: []const u8, operation: []const u8) ![]const u8 {
    return manager.alloc.print("company/operations/{s}.json", .{try workspace.hash(manager.alloc, try encode(manager.alloc, .{ actor, operation }))});
}
fn loadJournal(manager: workspace.Manager, path: []const u8) !?Journal {
    const revision_id = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision_id)) |entry| if (std.mem.eql(u8, entry, path)) return try records.decode(Journal, manager.alloc, try manager.contentAt(path, revision_id), .{});
    return null;
}

fn requireOutcomeView(alloc: std.mem.Allocator, journal: Journal, selected: ?[]const u8) !void {
    const view = selected orelse return;
    if (journal.view) |retained| {
        if (!std.mem.eql(u8, retained, view)) return error.CompanyAccessDenied;
        return;
    }
    const raw = journal.request orelse return error.CompanyAccessDenied;
    const envelope = try records.decode(authority.Envelope, alloc, raw, .{});
    const source = try records.decode(struct { action: authority.Action, view: ?[]const u8 = null }, alloc, envelope.payload, .{ .ignore_unknown_fields = true });
    if (source.view) |retained| {
        if (!std.mem.eql(u8, retained, view)) return error.CompanyAccessDenied;
        return;
    }
    if (source.action == .create_view and journal.state == .completed) {
        const result = try records.decode(struct { view: []const u8 }, alloc, journal.result orelse return error.CompanyAccessDenied, .{ .ignore_unknown_fields = true });
        if (std.mem.eql(u8, result.view, view)) return;
    }
    return error.CompanyAccessDenied;
}
fn saveJournal(manager: workspace.Manager, path: []const u8, journal: Journal) !void {
    var files: std.ArrayList(workspace.Manager.CompanyFile) = .empty;
    try files.append(manager.alloc, .{ .path = path, .content = try encode(manager.alloc, journal) });
    if (journal.view) |id| {
        if (!authority.safeIdentity(id)) return error.InvalidCompanyIdentity;
        const view_path = try manager.alloc.print("company/views/{s}.json", .{id});
        var view = try records.decode(View, manager.alloc, try manager.companyContent(view_path), .{});
        if (view.pending) |pending| if (!std.mem.eql(u8, pending, journal.operation)) return error.CompanyOperationRecoveryRequired;
        view.pending = if (journal.state == .pending or journal.state == .uncertain) journal.operation else null;
        try files.append(manager.alloc, .{ .path = view_path, .content = try viewBytes(manager, view) });
    }
    _ = try manager.companyWrite(try manager.companyRevision(), files.items);
}
fn signed(manager: workspace.Manager, current: authority.State, request: authority.Request, request_hash: []const u8, result: []const u8) ![]const u8 {
    const key = try keys.current(manager, current.epoch, current.issuer);
    const public = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    if (!std.mem.eql(u8, &public, current.issuer)) return error.CompanyIssuerRecoveryRequired;
    const payload = try encode(manager.alloc, .{ .version = "omos.company-receipt/v1", .workspace = current.workspace, .actor = request.actor, .grant = request.grant, .operation = request.operation, .request_hash = request_hash, .action = request.action, .epoch = current.epoch, .result = try parse(manager.alloc, result) });
    const signature = try key.sign(payload, null);
    const signature_hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    return encode(manager.alloc, .{ .payload = payload, .signature = &signature_hex, .issuer = &public });
}

pub fn validateInstance(manager: workspace.Manager) !void {
    if (try manager.companyRevision() == null) return;
    const current = try state(manager);
    _ = try keys.current(manager, current.epoch, current.issuer);
}

fn operationProperties(declaration: model.Declaration) std.json.Value {
    for (model.items(model.spec(declaration.value), "operations")) |operation| {
        if (!std.mem.eql(u8, model.text(operation, "id"), "omos_company_operation")) continue;
        return model.field(model.field(operation, "input") orelse return .null, "properties") orelse .null;
    }
    return .null;
}

fn fileAttributesDeclared(properties: std.json.Value) bool {
    const version = model.field(properties, "version") orelse return false;
    if (std.mem.eql(u8, model.text(version, "const"), "omos.company/v2")) return true;
    for (model.items(version, "enum")) |value| if (value == .string and std.mem.eql(u8, value.string, "omos.company/v2")) return true;
    return false;
}

fn executionDeclared(declaration: model.Declaration) bool {
    if (!model.hasOperation(declaration, "omos_company_execution")) return false;
    for (declaration.semantic.entityTypes) |entity| if (std.mem.eql(u8, entity.id, "omos_company_execution")) return true;
    return false;
}

fn executionRecord(manager: workspace.Manager, view: View, grant: authority.Grant) !?ownership.Record {
    const path = try ownership.path(manager.alloc, view.id);
    for (try manager.inventory((try manager.companyRevision()) orelse return error.CompanyNotInitialized)) |entry| {
        if (!std.mem.eql(u8, entry, path)) continue;
        const record = try records.decode(ownership.Record, manager.alloc, try manager.companyContent(path), .{});
        try ownership.validate(record, view.id, view.task, grant);
        return record;
    }
    return null;
}

fn requireExecution(manager: workspace.Manager, view: View, grant: authority.Grant, fence: ?ownership.Fence) !void {
    try ownership.require(try executionRecord(manager, view, grant), fence, io.milliTimestamp());
}

fn frozenTask(manager: workspace.Manager, task: workspace.Task) !bool {
    if (task.state == .accepted or task.state == .publication_pending) return true;
    if (task.review_job) |id| {
        const job = try manager.loadReviewJob(task, id);
        return job.state == .queued or job.state == .running;
    }
    return false;
}

pub fn bootstrap(manager: workspace.Manager) ![]const u8 {
    const lease = try manager.companyOperationLease();
    defer lease.release();
    const current = try state(manager);
    _ = try keys.current(manager, current.epoch, current.issuer);
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    const properties = operationProperties(declaration);
    const upload_entity = for (declaration.semantic.entityTypes) |entity| {
        if (std.mem.eql(u8, entity.id, "omos_company_upload")) break true;
    } else false;
    return encode(manager.alloc, .{ .version = "omos.company/v1", .workspace = current.workspace, .issuer = current.issuer, .epoch = current.epoch, .revision = try manager.revision("trunk"), .features = .{ .scope = "path", .merge = "record_or_file", .typed_records = "custom_entities", .scoped_export = "manifest", .file_attributes = if (fileAttributesDeclared(properties)) @as(?[]const u8, "omos.company/v2") else null, .chunked_upload = upload_entity and model.field(properties, "upload") != null, .max_upload_chunk_bytes = uploads.chunk_bytes, .checkpoint_attributes = model.field(properties, "executable") != null and model.field(properties, "previous_executable") != null, .read_dependencies = read_dependencies.supported(declaration), .operator_approvals = model.hasOperation(declaration, "omos_company_admin"), .schema_discovery = model.hasOperation(declaration, "omos_company_schema"), .capability_discovery = model.hasOperation(declaration, "omos_company_capability") and model.field(properties, "capability") != null, .capability_packages = model.field(properties, "capability_selections") != null and model.hasOperation(declaration, "omos_company_capability"), .capability_delegation = model.hasOperation(declaration, "omos_grant_capability_scope") and model.field(properties, "delegated_capabilities") != null, .progress_history = model.field(properties, "progress_cursor") != null, .progress_stream = if (model.field(properties, "progress_cursor") != null and model.hasOperation(declaration, "omos_company_subscription")) @as(?[]const u8, "omos.company-progress/v1") else null, .max_progress_streams = progress_stream_limit, .max_progress_seconds = progress_stream_seconds, .task_scopes = task_scope.supported(declaration), .execution_ownership = executionDeclared(declaration), .scoped_inventory = model.hasOperation(declaration, "omos_company_inventory"), .inventory_export = model.hasOperation(declaration, "omos_company_inventory_export"), .owned_views = model.hasOperation(declaration, "omos_company_views"), .conversation = model.hasOperation(declaration, "omos_company_conversation"), .worker_checkpoints = model.hasOperation(declaration, "omos_company_worker_checkpoint"), .desired_state = model.hasOperation(declaration, "omos_company_desired_admin") and model.hasOperation(declaration, "omos_company_desired_read"), .actor_archives = model.hasOperation(declaration, "omos_company_archive_admin") and model.hasOperation(declaration, "omos_company_archive_read"), .validation_feedback = model.hasOperation(declaration, "omos_company_validation_feedback"), .completion_planning = model.hasOperation(declaration, "omos_company_completion_plan") and @import("company_planning.zig").supported(declaration), .hosted_execution = model.hasOperation(declaration, "omos_company_hosted_execution") and try runtimes.available(manager, null, null), .max_request_bytes = 1024 * 1024, .max_read_bytes = 16384, .max_object_bytes = 8 * 1024 * 1024 } });
}

pub fn execute(original: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    return executeInner(original, raw, writable, false, null);
}

/// Transport-owned continuation of an authenticated status subscription. The
/// cursor carries no authority; every page revalidates the original request.
pub fn progress(original: workspace.Manager, raw: []const u8, writable: bool, cursor: ?[]const u8) ![]const u8 {
    return executeInner(original, raw, writable, true, cursor);
}

fn executeInner(original: workspace.Manager, raw: []const u8, writable: bool, progress_only: bool, cursor: ?[]const u8) ![]const u8 {
    var manager = original;
    if (raw.len > 1024 * 1024) return error.ServiceRequestTooLarge;
    const incoming = try records.decode(authority.Envelope, manager.alloc, raw, .{});
    // This hint only installs a deadline. Authentication and declaration
    // validation below remain mandatory before inspecting workspace state.
    const hint = try records.decode(struct { action: ?[]const u8 = null, progress_cursor: ?[]const u8 = null }, manager.alloc, incoming.payload, .{ .ignore_unknown_fields = true });
    if (progress_only and (hint.progress_cursor == null or hint.action == null or !std.mem.eql(u8, hint.action.?, "status"))) return error.CompanyProgressRequired;
    var cancelled = std.atomic.Value(bool).init(false);
    if (hint.progress_cursor != null) {
        const deadline: std.Io.Clock.Timestamp = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(30)) };
        if (manager.operation_control) |*control| {
            if (std.Io.Clock.Timestamp.compare(deadline, .lt, control.deadline)) control.deadline = deadline;
        } else manager.operation_control = .{ .cancel = &cancelled, .deadline = deadline };
    }
    const lease = try manager.companyOperationLease();
    defer lease.release();
    manager.company_operation_held = true;
    const current = try state(manager);
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    try model.validateOperation(manager.alloc, declaration, "omos_company_request", try parse(manager.alloc, raw), .input);
    if (progress_only) {
        if (!model.hasOperation(declaration, "omos_company_subscription")) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, "omos_company_subscription", try parse(manager.alloc, raw), .input);
    }
    var request = try authority.authenticate(manager.alloc, current, raw, io.milliTimestamp());
    if (request.scope != null and request.action != .create_view) return error.UnsupportedCompanyApi;
    if (request.scope != null and !task_scope.supported(declaration)) return error.CompanyDefinitionUpdateRequired;
    if (request.action == .create_view and request.view != null) return error.UnsupportedCompanyApi;
    try model.validateOperation(manager.alloc, declaration, "omos_company_operation", try parse(manager.alloc, incoming.payload), .input);
    const grant = try authority.liveGrant(current, request.grant, io.milliTimestamp());
    if (request.action == .execution) {
        if (!executionDeclared(declaration)) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, "omos_company_execution", try parse(manager.alloc, incoming.payload), .input);
        if (request.view == null or request.execution == null or request.execution_change == null) return error.InvalidCompanyExecution;
    } else if (request.execution_change != null or request.execution_lease_ms != null) return error.InvalidCompanyExecution;
    if (request.action == .execute_task) {
        if (!model.hasOperation(declaration, "omos_company_hosted_execution")) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, "omos_company_hosted_execution", try parse(manager.alloc, incoming.payload), .input);
    }
    if (request.action == .status and request.record_id != null and request.entity == null) {
        if (!model.hasOperation(declaration, "omos_company_validation_feedback")) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, "omos_company_validation_feedback", try parse(manager.alloc, incoming.payload), .input);
    }
    if (request.action == .status and request.entity != null) {
        const operation = if (std.mem.eql(u8, request.entity.?, "omos_company_reconciliation")) "omos_company_desired_read" else if (std.mem.eql(u8, request.entity.?, "omos_company_conversation")) "omos_company_conversation" else if (std.mem.eql(u8, request.entity.?, "omos_company_archive")) "omos_company_archive_read" else "omos_company_views";
        if (!model.hasOperation(declaration, operation)) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, operation, try parse(manager.alloc, incoming.payload), .input);
    }
    const directory_export = request.action == .export_scope and request.path != null and std.mem.endsWith(u8, request.path.?, "/");
    if ((request.action == .discover and request.path != null) or directory_export) {
        const operation = if (directory_export) "omos_company_inventory_export" else "omos_company_inventory";
        if (!model.hasOperation(declaration, operation)) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, operation, try parse(manager.alloc, incoming.payload), .input);
    }
    if (request.execution != null and request.view == null and request.action != .reconcile) return error.CompanyViewRequired;
    const schema_discovery = request.action == .discover and request.entity != null;
    const capability_discovery = request.action == .discover and request.capability != null;
    const capability_export = request.action == .export_scope and request.capability != null;
    const capability_request = capability_discovery or capability_export;
    if ((request.capability != null and (!capability_request or request.entity != null or request.path != null)) or (request.realisation != null and (!capability_request or std.mem.eql(u8, request.capability.?, "*")))) return error.InvalidCapabilitySelection;
    if (request.capability_selections != null and (!capability_request or std.mem.eql(u8, request.capability.?, "*"))) return error.InvalidCapabilitySelection;
    if (capability_export and (!std.mem.eql(u8, request.version, "omos.company/v2") or std.mem.eql(u8, request.capability.?, "*"))) return error.InvalidCapabilitySelection;
    if (capability_request) {
        if (!model.hasOperation(declaration, "omos_company_capability")) return error.CompanyDefinitionUpdateRequired;
        if (capability_discovery) try model.validateOperation(manager.alloc, declaration, "omos_company_capability", try parse(manager.alloc, incoming.payload), .input);
    }
    if (schema_discovery) {
        if (!model.hasOperation(declaration, "omos_company_schema")) return error.CompanyDefinitionUpdateRequired;
        try model.validateOperation(manager.alloc, declaration, "omos_company_schema", try parse(manager.alloc, incoming.payload), .input);
    }
    if (request.delegated_capabilities != null and request.action != .delegate) return error.InvalidCapabilitySelection;
    if (request.upload != null and request.action != .checkpoint) return error.InvalidCompanyUpload;
    if (request.progress_cursor != null and (request.action != .status or request.outcome != null or request.offset != 0 or request.revision != null)) return error.InvalidCompanyProgressCursor;
    if (progress_only) if (cursor) |position| {
        request.progress_cursor = position;
    };
    const mutation = authority.isMutation(request.action);
    if (mutation and !writable) return error.ServiceReadOnly;
    if (mutation and request.action != .reconcile and request.action != .execution) if (request.view) |id| {
        const selected = try loadView(manager, grant, id);
        if (selected.view.pending) |pending| if (!std.mem.eql(u8, pending, request.operation)) return error.CompanyOperationRecoveryRequired;
    };
    // Never perform an effect without the key needed to acknowledge it.
    _ = try keys.current(manager, current.epoch, current.issuer);
    const path = try operationPath(manager, request.actor, request.operation);
    const request_hash = try workspace.hash(manager.alloc, incoming.payload);
    const retained = try loadJournal(manager, path);
    if (retained) |previous| {
        if (!std.mem.eql(u8, previous.request_hash, request_hash) or !std.mem.eql(u8, previous.grant, grant.id)) return error.CompanyOperationConflict;
        if (previous.state == .completed) return signed(manager, current, request, request_hash, previous.result.?);
        if (previous.state == .failed) return error.CompanyOperationFailed;
        // Only internal idempotent operations below can replay. No external
        // command or provider effect is dispatched by this API.
    }
    if (request.view) |id| if (request.action != .status and request.action != .execution and request.action != .reconcile) {
        const selected = try loadView(manager, grant, id);
        const observes = request.action == .read or request.action == .query or request.action == .discover;
        const edits = request.action == .checkpoint or request.action == .record or request.action == .submit;
        if (edits or (observes and !try frozenTask(manager, selected.task))) {
            try requireExecution(manager, selected.view, grant, request.execution);
            try @import("company_desired.zig").require(manager, selected.task);
        }
    };
    var journal: Journal = .{ .actor = request.actor, .grant = request.grant, .operation = request.operation, .request_hash = request_hash, .state = .pending, .view = if (request.action == .reconcile or request.action == .execution) null else request.view, .request = if (retained) |previous| previous.request orelse raw else raw };
    if (mutation and retained == null) try saveJournal(manager, path, journal);
    const result = perform(manager, current, grant, request, request_hash, writable) catch |err| {
        if (mutation) {
            journal.state = if (err == error.InvalidCompanyTaskScope or err == error.WorkspaceRevisionChanged or err == error.WorkspaceReadDependencyChanged or err == error.CompanyDefinitionUpdateRequired or err == error.CompanyAccessDenied or (request.action == .execute_task and (err == error.CompanyImplementationUnavailable or err == error.CompanyWorkerInvocationBudget or err == error.CompanyWorkerCancelled or err == error.TaskIsReadOnly)) or (request.action == .execution and ownership.rejected(err)) or (request.action == .delegate and (err == error.CompanyDelegationDenied or err == error.CompanyGrantAlreadyExists or err == error.UnknownCapability or err == error.DuplicateCapabilitySelection)) or err == error.WorkspaceProjectionConflict or ((request.action == .record or request.action == .checkpoint) and @import("company_records.zig").validationFailure(err))) .failed else .uncertain;
            journal.failure = @errorName(err);
            journal.receipt = try signed(manager, current, request, request_hash, try encode(manager.alloc, .{ .operation = request.operation, .state = @tagName(journal.state), .failure = journal.failure }));
            try saveJournal(manager, path, journal);
        }
        return err;
    };
    if (schema_discovery) try model.validateOperation(manager.alloc, declaration, "omos_company_schema", try parse(manager.alloc, result), .output);
    if (capability_discovery) try model.validateOperation(manager.alloc, declaration, "omos_company_capability", try parse(manager.alloc, result), .output);
    if (request.action == .execution) try model.validateOperation(manager.alloc, declaration, "omos_company_execution", try parse(manager.alloc, result), .output);
    const response = try signed(manager, current, request, request_hash, result);
    if (mutation) {
        journal.state = .completed;
        journal.result = result;
        journal.receipt = response;
        try saveJournal(manager, path, journal);
    }
    try model.validateOperation(manager.alloc, declaration, "omos_company_request", try parse(manager.alloc, response), .output);
    if (progress_only) try model.validateOperation(manager.alloc, declaration, "omos_company_subscription", try parse(manager.alloc, response), .output);
    return response;
}

fn loadView(manager: workspace.Manager, grant: authority.Grant, id: []const u8) !struct { view: View, task: workspace.Task } {
    if (!authority.safeIdentity(id)) return error.InvalidCompanyIdentity;
    const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{id})), .{});
    if (!std.mem.eql(u8, view.id, id)) return error.WorkspaceIdentityMismatch;
    if (!std.mem.eql(u8, view.actor, grant.actor) or !std.mem.eql(u8, view.grant, grant.id)) return error.CompanyAccessDenied;
    return .{ .view = view, .task = try manager.refreshTaskContext(try manager.loadTask(view.task)) };
}

fn requestPage(manager: workspace.Manager, bytes: []const u8, offset: usize, limit: usize) !std.json.Value {
    if (limit == 0 or limit > 16384 or offset > bytes.len) return error.InvalidEvidenceOffset;
    const end = offset + @min(limit, bytes.len - offset);
    const segment = bytes[offset..end];
    const encoded = try manager.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(segment.len));
    return parse(manager.alloc, try encode(manager.alloc, .{ .sha256 = try workspace.hash(manager.alloc, bytes), .bytes = bytes.len, .offset = offset, .content = std.base64.standard.Encoder.encode(encoded, segment), .encoding = "base64", .next_offset = if (end < bytes.len) @as(?usize, end) else null }));
}

fn retainRead(manager: workspace.Manager, grant: authority.Grant, request: authority.Request, selected: ?View, revision: []const u8, raw: []const u8, writable: bool) ![]const u8 {
    // Export transfers are inspection, not inputs to a future proposal.
    if (request.action == .export_scope) return raw;
    var view = selected orelse return raw;
    const task = try manager.loadTask(view.task);
    var result = try parse(manager.alloc, raw);
    if (result != .object) return error.InvalidCompanyRead;
    const frozen = try frozenTask(manager, task);
    if (frozen) {
        try result.object.put(manager.alloc, "read_tracking", .{ .string = "frozen_inspection" });
        return encode(manager.alloc, result);
    }
    if (!writable) return error.CompanyReadTrackingRequired;
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    if (!read_dependencies.supported(declaration)) return error.CompanyDefinitionUpdateRequired;
    const observation = try read_dependencies.observe(manager, task, grant, request, revision, result);
    var reference: read_dependencies.Reference = .{ .path = try read_dependencies.recordPath(manager.alloc, observation), .selector = observation.selector };
    var active: std.ArrayList(read_dependencies.Reference) = .empty;
    for (view.reads) |previous| if (!std.mem.eql(u8, previous.selector, reference.selector)) try active.append(manager.alloc, previous);
    try active.append(manager.alloc, reference);
    if (active.items.len > read_dependencies.max_references) return error.CompanyReadSetTooLarge;
    view.reads = active.items;
    const control = try manager.companyWrite(try manager.companyRevision(), &.{
        .{ .path = reference.path, .content = try encode(manager.alloc, observation) },
        .{ .path = try manager.alloc.print("company/views/{s}.json", .{view.id}), .content = try viewBytes(manager, view) },
    });
    reference.revision = control;
    try result.object.put(manager.alloc, "read_tracking", .{ .string = "recorded" });
    try result.object.put(manager.alloc, "observation", try parse(manager.alloc, try encode(manager.alloc, reference)));
    return encode(manager.alloc, result);
}

fn prepareSubmission(manager: workspace.Manager, view: View, task: workspace.Task, request: authority.Request, request_hash: []const u8, candidate: []const u8) !Submission {
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    if (!read_dependencies.supported(declaration)) return error.CompanyDefinitionUpdateRequired;
    const path = try manager.alloc.print("company/submissions/{s}/{s}.json", .{ task.id, request_hash });
    const control = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const contract_hash = try workspace.hash(manager.alloc, try encode(manager.alloc, .{ task.definition, task.model_basis }));
    const candidate_hash = try workspace.hash(manager.alloc, candidate);
    for (try manager.inventory(control)) |entry| if (std.mem.eql(u8, entry, path)) {
        const previous = try records.decode(Submission, manager.alloc, try manager.contentAt(path, control), .{});
        if (!std.mem.eql(u8, previous.version, "omos.company-submission/v1") or !std.mem.eql(u8, previous.task, task.id) or !std.mem.eql(u8, previous.operation, request.operation) or !std.mem.eql(u8, previous.request_hash, request_hash) or !equal(request.revision, previous.revision) or !std.mem.eql(u8, previous.contract_hash, contract_hash) or !std.mem.eql(u8, previous.candidate_hash, candidate_hash) or !try manager.revisionDescendsFrom(try manager.currentRevision(task), previous.revision)) return error.CompanyOperationConflict;
        return previous;
    };
    const revision = request.revision orelse return error.WorkspaceRevisionChanged;
    if (!std.mem.eql(u8, revision, try manager.currentRevision(task))) return error.WorkspaceRevisionChanged;
    const frozen = try manager.alloc.dupe(read_dependencies.Reference, view.reads);
    for (frozen) |*reference| reference.revision = control;
    try read_dependencies.validate(manager, task, frozen, try manager.revision(task.parent));
    const submission: Submission = .{ .task = task.id, .operation = request.operation, .request_hash = request_hash, .revision = revision, .contract_hash = contract_hash, .candidate_hash = candidate_hash, .reads = frozen };
    _ = try manager.companyWrite(control, &.{.{ .path = path, .content = try encode(manager.alloc, submission) }});
    return submission;
}

fn perform(original: workspace.Manager, current: authority.State, original_grant: authority.Grant, request: authority.Request, operation_hash: []const u8, writable: bool) anyerror![]const u8 {
    var manager = original;
    const alloc = manager.alloc;
    const selected = if (request.view) |id| try loadView(manager, original_grant, id) else null;
    const grant = if (selected) |view| try task_scope.forView(manager, view.task, original_grant, view.view.id, view.view.scope) else original_grant;
    const revision_id = if (selected) |view| try manager.currentRevision(view.task) else try manager.revision("trunk");
    if (request.action == .reconcile) {
        const id = request.outcome orelse return error.CompanyOutcomeRequired;
        if (!authority.safeIdentity(id) or std.mem.eql(u8, id, request.operation)) return error.InvalidCompanyIdentity;
        const path = try operationPath(manager, grant.actor, id);
        var journal = (try loadJournal(manager, path)) orelse return error.CompanyOutcomeNotFound;
        if (!std.mem.eql(u8, journal.grant, grant.id)) return error.CompanyAccessDenied;
        try requireOutcomeView(alloc, journal, request.view);
        if (journal.state == .failed) return error.CompanyOperationFailed;
        const original_request = try authority.authenticateRetained(alloc, current, journal.request orelse return error.CompanyRequestNotRetained, request, io.milliTimestamp());
        const envelope = try records.decode(authority.Envelope, alloc, journal.request.?, .{});
        if (!std.mem.eql(u8, journal.request_hash, try workspace.hash(alloc, envelope.payload))) return error.CompanyOperationConflict;
        if (journal.state != .completed) {
            if (journal.view) |view_id| {
                const view = try loadView(manager, grant, view_id);
                if (view.view.pending) |pending| if (!std.mem.eql(u8, pending, id)) return error.CompanyOperationRecoveryRequired;
                // The new owner explicitly authorizes reconciliation of the
                // retained internal operation. This API runs no actor tools.
                try requireExecution(manager, view.view, grant, request.execution);
            }
            const result = perform(manager, current, grant, original_request, journal.request_hash, writable) catch |err| {
                journal.state = if (err == error.WorkspaceReadDependencyChanged) .failed else .uncertain;
                journal.failure = @errorName(err);
                journal.reconciled_by = request.operation;
                journal.receipt = try signed(manager, current, original_request, journal.request_hash, try encode(alloc, .{ .operation = id, .state = @tagName(journal.state), .failure = journal.failure }));
                try saveJournal(manager, path, journal);
                return err;
            };
            journal.state = .completed;
            journal.result = result;
            journal.failure = null;
            journal.reconciled_by = request.operation;
            journal.receipt = try signed(manager, current, original_request, journal.request_hash, result);
            try saveJournal(manager, path, journal);
        }
        return encode(alloc, .{ .operation = id, .request_hash = journal.request_hash, .state = @tagName(journal.state), .result = if (journal.result) |value| try parse(alloc, value) else null });
    }
    if (request.action == .create_view) {
        if (request.scope) |paths| try task_scope.validatePaths(grant, paths);
        const objective = request.objective orelse return error.MissingCompanyObjective;
        if (objective.len == 0 or objective.len > 16384) return error.InvalidCompanyObjective;
        const id = try workspace.hash(alloc, try encode(alloc, .{ request.actor, request.operation }));
        const view_path = try alloc.print("company/views/{s}.json", .{id});
        for (try manager.inventory((try manager.companyRevision()) orelse return error.CompanyNotInitialized)) |entry| if (std.mem.eql(u8, entry, view_path)) {
            // Lost creation acknowledgements never reset read observations,
            // execution recovery, the original base, or an accepted task.
            const retained = try loadView(manager, grant, id);
            const reference = retained.view.scope;
            if (request.scope != null and reference == null) return error.CompanyOperationConflict;
            const effective = try task_scope.forView(manager, retained.task, grant, id, reference);
            if (request.scope) |paths| if (!std.mem.eql(u8, try encode(alloc, paths), try encode(alloc, effective.paths))) return error.CompanyOperationConflict;
            return encode(alloc, .{ .view = id, .revision = try manager.currentRevision(retained.task), .base = retained.view.base, .contract = retained.task.definition, .basis = retained.task.model_basis, .paths = effective.paths });
        };
        const session = try alloc.print("company-{s}", .{id});
        const project = try std.Io.Dir.path.join(alloc, &.{ manager.root, "company-workers", id });
        const previous = try manager.active(session);
        if (previous == null and (request.revision == null or !std.mem.eql(u8, request.revision.?, revision_id))) return error.WorkspaceRevisionChanged;
        const binding: authority.Binding = .{ .actor = grant.actor, .grant = grant.id };
        var starter = manager;
        starter.expected_revision = request.revision;
        const task = if (previous) |value| try manager.bindCompanyTask(value, binding) else try starter.startCompany(session, project, objective, binding);
        const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
        const pinned_paths = request.scope orelse grant.paths;
        const scope_path = if (request.scope != null or task_scope.supported(declaration)) try task_scope.path(alloc, task.id) else null;
        const view: View = .{ .id = id, .actor = grant.actor, .grant = grant.id, .task = task.id, .base = task.base_revision, .scope = scope_path, .created_at_ms = task.created_at_ms };
        var files: std.ArrayList(workspace.Manager.CompanyFile) = .empty;
        try files.append(alloc, .{ .path = view_path, .content = try viewBytes(manager, view) });
        if (scope_path) |selected_path| {
            try task_scope.validatePaths(grant, pinned_paths);
            try files.append(alloc, .{ .path = selected_path, .content = try encode(alloc, task_scope.Record{ .workspace = manager.manifest.id, .task = task.id, .view = id, .actor = grant.actor, .grant = grant.id, .paths = pinned_paths }) });
        }
        _ = try manager.companyWrite(try manager.companyRevision(), files.items);
        return encode(alloc, .{ .view = id, .revision = try manager.currentRevision(task), .base = task.base_revision, .contract = task.definition, .basis = task.model_basis, .paths = request.scope orelse grant.paths });
    }
    if (request.action == .delegate) {
        const delegated = request.delegated_grant orelse return error.InvalidCompanyGrant;
        if (delegated.parent == null or !std.mem.eql(u8, delegated.parent.?, grant.id)) return error.CompanyDelegationDenied;
        try authority.validateGrant(current, delegated, io.milliTimestamp());
        for (delegated.paths) |path| if (!authority.permitsSelector(grant, path)) return error.CompanyDelegationDenied;
        for (current.grants) |existing| if (std.mem.eql(u8, existing.id, delegated.id)) {
            if (!std.mem.eql(u8, try encode(alloc, existing), try encode(alloc, delegated))) return error.CompanyGrantAlreadyExists;
            if (request.delegated_capabilities) |capabilities| {
                const scopes = @import("company_capabilities.zig");
                if (!try scopes.matchesAssignment(alloc, try scopes.load(manager), current, delegated.id, capabilities, io.milliTimestamp())) return error.CompanyGrantAlreadyExists;
            }
            return encode(alloc, .{ .grant = delegated.id, .state = "delegated" });
        };
        var next = current;
        const grants = try alloc.alloc(authority.Grant, current.grants.len + 1);
        @memcpy(grants[0..current.grants.len], current.grants);
        grants[current.grants.len] = delegated;
        next.grants = grants;
        var files: std.ArrayList(workspace.Manager.CompanyFile) = .empty;
        try files.append(alloc, .{ .path = "authority/state.json", .content = try encode(alloc, next) });
        if (request.delegated_capabilities) |capabilities| {
            if (request.revision == null or !std.mem.eql(u8, request.revision.?, revision_id)) return error.WorkspaceRevisionChanged;
            const scopes = @import("company_capabilities.zig");
            const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
            if (!model.hasOperation(declaration, "omos_grant_capability_scope")) return error.CompanyDefinitionUpdateRequired;
            const policy = try scopes.assign(alloc, try scopes.load(manager), next, declaration, delegated.id, capabilities, io.milliTimestamp());
            try files.append(alloc, .{ .path = scopes.path, .content = try encode(alloc, policy) });
        }
        _ = try manager.companyWrite(try manager.companyRevision(), files.items);
        return encode(alloc, .{ .grant = delegated.id, .state = "delegated" });
    }
    if (request.action == .status) {
        if (request.entity) |entity| {
            if (std.mem.eql(u8, entity, "omos_company_reconciliation")) return @import("company_desired.zig").page(manager, grant, request, if (selected) |view| view.task else null);
            if (std.mem.eql(u8, entity, "omos_workspace_view")) return @import("company_views.zig").page(manager, grant, request);
            const view = selected orelse return error.CompanyViewRequired;
            if (std.mem.eql(u8, entity, "omos_company_archive")) return @import("company_archive.zig").read(manager, view.task, grant, view.view.id, request);
            const pinned = (try manager.companyReadRevision(view.task, request.revision orelse revision_id)) orelse return error.CompanyAccessDenied;
            const task = try manager.taskAtRevision(view.task.id, pinned);
            const original_request = if (task.request_artifact) |path| try manager.contentAt(path, pinned) else task.definition.objective;
            const body = try encode(alloc, .{ .version = "omos.company-conversation/v1", .task = task.id, .revision = pinned, .original_request = original_request, .amendments = task.amendments, .candidate = try manager.candidateAnswerAt(task, pinned), .candidate_authority = "actor_claim" });
            return encode(alloc, .{ .version = "omos.company-conversation-page/v1", .view = view.view.id, .revision = pinned, .conversation = try requestPage(manager, body, request.offset, request.limit) });
        }
        if (request.record_id) |id| {
            const view = selected orelse return error.CompanyViewRequired;
            const pinned = (try manager.companyReadRevision(view.task, request.revision orelse revision_id)) orelse return error.CompanyAccessDenied;
            return @import("company_validation.zig").feedback(manager, view.task, id, pinned, request.offset, request.limit);
        }
        if (request.outcome) |id| {
            if (!authority.safeIdentity(id)) return error.InvalidCompanyIdentity;
            const journal = (try loadJournal(manager, try operationPath(manager, grant.actor, id))) orelse return error.CompanyOutcomeNotFound;
            if (!std.mem.eql(u8, journal.grant, grant.id)) return error.CompanyAccessDenied;
            try requireOutcomeView(alloc, journal, request.view);
            return encode(alloc, .{ .operation = id, .request_hash = journal.request_hash, .state = @tagName(journal.state), .failure = journal.failure, .reconciled_by = journal.reconciled_by, .request = if (journal.request) |value| try requestPage(manager, value, request.offset, request.limit) else null, .receipt = if (journal.receipt) |value| try parse(alloc, value) else null, .result = if (journal.result) |value| try parse(alloc, value) else null });
        }
        if (selected == null) return encode(alloc, .{ .workspace = manager.manifest.id, .actor = grant.actor, .grant = grant.id, .actions = grant.actions, .paths = grant.paths, .expires_ms = grant.expires_ms });
        const view = selected.?;
        const job = if (view.task.review_job) |id| try manager.loadReviewJob(view.task, id) else null;
        var result = try parse(alloc, try encode(alloc, .{ .view = view.view.id, .revision = revision_id, .state = @tagName(view.task.state), .base = view.task.base_revision, .contract = view.task.definition, .basis = view.task.model_basis, .paths = grant.paths, .job = job, .execution = try executionRecord(manager, view.view, grant), .publication = if (view.task.state == .accepted) try manager.publicationSummary(view.task) else null }));
        try result.object.put(alloc, "hosted_execution", try parse(alloc, try runtimes.taskStatus(manager, grant, view.task, view.view.id)));
        if (request.progress_cursor) |cursor| try result.object.put(alloc, "progress", try @import("company_progress.zig").page(manager, current, grant, view.task, view.view.id, view.view.base, revision_id, cursor, request.limit));
        return encode(alloc, result);
    }
    if (request.action == .execute_task) {
        const view = selected orelse return error.CompanyViewRequired;
        return runtimes.requestTask(manager, grant, view.task, view.view.id, request.operation, request.revision);
    }
    if (request.action == .execution) {
        const view = selected orelse return error.CompanyViewRequired;
        const path = try ownership.path(alloc, view.view.id);
        const history_path = try alloc.print("company/execution/{s}/{s}.json", .{ view.view.id, operation_hash });
        for (try manager.inventory((try manager.companyRevision()) orelse return error.CompanyNotInitialized)) |entry| if (std.mem.eql(u8, entry, history_path)) {
            const retained = try records.decode(ownership.Record, alloc, try manager.companyContent(history_path), .{});
            try ownership.validate(retained, view.view.id, view.task.id, grant);
            if (!std.mem.eql(u8, retained.operation, request.operation) or !std.mem.eql(u8, retained.request_hash, operation_hash)) return error.CompanyOperationConflict;
            return encode(alloc, retained);
        };
        if (try frozenTask(manager, view.task)) return error.TaskIsReadOnly;
        if (request.revision == null or !std.mem.eql(u8, request.revision.?, revision_id)) return error.WorkspaceRevisionChanged;
        const next = try ownership.change(try executionRecord(manager, view.view, grant), request.execution_change orelse return error.InvalidCompanyExecution, request.execution orelse return error.InvalidCompanyExecution, request.execution_lease_ms, io.milliTimestamp(), grant, view.view.id, view.task.id, request.operation, operation_hash);
        const raw = try encode(alloc, next);
        _ = try manager.companyWrite(try manager.companyRevision(), &.{ .{ .path = path, .content = raw }, .{ .path = history_path, .content = raw } });
        return raw;
    }
    if (request.action == .record) {
        const view = selected orelse return error.CompanyViewRequired;
        if (try manager.companyCheckpointRevision(view.task, operation_hash)) |committed| return encode(alloc, .{ .view = view.view.id, .revision = committed, .state = "checkpointed" });
        if (request.revision == null or !std.mem.eql(u8, request.revision.?, revision_id)) return error.WorkspaceRevisionChanged;
        const entity = request.entity orelse return error.UnknownEntityType;
        const id = request.record_id orelse return error.InvalidCompanyIdentity;
        const path = try @import("company_records.zig").path(alloc, entity, id);
        if (!authority.permitsPath(grant, path)) return error.CompanyAccessDenied;
        if (request.encoding != .utf8) return error.UnsupportedCompanyRecordEncoding;
        manager.expected_revision = request.revision;
        const revision = try manager.writeCompanyRecord(view.task, entity, id, if (request.remove) null else request.content orelse return error.MissingContent, request.previous_hash, operation_hash);
        return encode(alloc, .{ .view = view.view.id, .revision = revision, .state = "checkpointed", .entity = entity, .record_id = id, .path = path });
    }
    if (request.action == .checkpoint) {
        const view = selected orelse return error.CompanyViewRequired;
        if (try manager.companyCheckpointRevision(view.task, operation_hash)) |committed| return encode(alloc, .{ .view = view.view.id, .revision = committed, .state = "checkpointed" });
        if (request.revision == null or !std.mem.eql(u8, request.revision.?, revision_id)) return error.WorkspaceRevisionChanged;
        const path = request.path orelse return error.MissingPath;
        if ((request.remove and request.executable != null) or (request.previous_executable != null and request.previous_hash == null) or (request.executable != null and request.previous_hash != null and request.previous_executable == null)) return error.InvalidCompanyFileAttributes;
        if (!authority.permitsPath(grant, path)) return error.CompanyAccessDenied;
        if (view.task.state == .accepted or view.task.state == .publication_pending or view.task.state == .conflict) return error.TaskIsReadOnly;
        if (view.task.review_job) |id| {
            const job = try manager.loadReviewJob(view.task, id);
            if (job.state == .queued or job.state == .running) return error.TaskReviewInProgress;
        }
        const bytes: ?[]const u8 = if (request.upload != null) switch (try uploads.accept(manager, request)) {
            .part => |response| return response,
            .complete => |content| content,
        } else if (request.remove) null else if (request.encoding == .utf8) request.content orelse return error.MissingContent else blk: {
            const encoded = request.content orelse return error.MissingContent;
            const result = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
            try std.base64.standard.Decoder.decode(result, encoded);
            break :blk result;
        };
        manager.expected_revision = request.revision;
        const revision = try manager.checkpointCompanyContent(view.task, &.{.{ .path = path, .content = bytes, .previous_hash = request.previous_hash, .executable = request.executable, .previous_executable = request.previous_executable }}, operation_hash);
        return encode(alloc, .{ .view = view.view.id, .revision = revision, .state = "checkpointed" });
    }
    if (request.action == .submit) {
        const view = selected orelse return error.CompanyViewRequired;
        const execution = (try manager.tryTaskExecutionLease(view.task.id)) orelse return error.WorkspaceExecutionBusy;
        defer execution.release();
        const candidate = request.candidate orelse return error.MissingContent;
        if (candidate.len == 0 or candidate.len > 32768) return error.InvalidCompanyCandidate;
        var retained_proposal = false;
        var cursor = try manager.historyCursor(view.task, revision_id);
        find_proposal: while (cursor.offset < cursor.paths.len) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const batch = (try cursor.next(a)) orelse break;
            for (batch) |raw| {
                const row = try parse(a, raw);
                if (!std.mem.eql(u8, model.text(row, "kind"), "company_proposal")) continue;
                const value = model.field(row, "value") orelse continue;
                if (std.mem.eql(u8, model.text(value, "operation"), request.operation)) {
                    retained_proposal = true;
                    break :find_proposal;
                }
            }
        }
        if (retained_proposal) {
            const job = if (view.task.review_job) |id| try manager.loadReviewJob(view.task, id) else try manager.queueReview(view.task);
            if (!std.mem.eql(u8, job.candidate_hash, try workspace.hash(alloc, candidate))) return error.CompanyOperationConflict;
            return encode(alloc, .{ .view = view.view.id, .candidate_revision = request.revision, .job = job.id, .state = if (job.state == .published) "published" else if (grant.human_approval) "approval_required" else "verification_pending", .revision = try manager.currentRevision(view.task), .publication = if (job.state == .published) try manager.publicationSummary(view.task) else null });
        }
        const submission = try prepareSubmission(manager, view.view, view.task, request, operation_hash, candidate);
        const frozen = try manager.freezeCompanyReads(view.task, submission.reads);
        const integrated = try manager.refresh(frozen);
        const integration_revision = try manager.currentRevision(integrated);
        try manager.record(integrated, "company_proposal", .{ .actor = grant.actor, .grant = grant.id, .candidate_revision = revision_id, .integration_revision = integration_revision, .operation = request.operation });
        try manager.record(integrated, "review_candidate", .{ .text = candidate, .at_ms = io.milliTimestamp() });
        try manager.record(integrated, "review_failure", .{ .code = "IndependentCompanyReviewRequired", .at_ms = io.milliTimestamp() + 1 });
        _ = try manager.checkpoint(integrated);
        const job = try manager.queueReview(integrated);
        return encode(alloc, .{ .view = view.view.id, .candidate_revision = revision_id, .job = job.id, .state = if (grant.human_approval) "approval_required" else "verification_pending", .revision = try manager.currentRevision(view.task) });
    }
    if (request.action == .discover or request.action == .read or request.action == .export_scope or request.action == .query) {
        const attributes = std.mem.eql(u8, request.version, "omos.company/v2");
        const requested_revision = request.revision orelse revision_id;
        // Check ancestry before looking up caller-supplied identities so the
        // response cannot reveal whether another private draft exists.
        const pinned = (try manager.companyReadRevision(if (selected) |view| view.task else null, requested_revision)) orelse return error.CompanyAccessDenied;
        const manifest = try records.decode(workspace.Manifest, alloc, try manager.contentAt("workspace.json", pinned), .{});
        if (!std.mem.eql(u8, manifest.id, current.workspace)) return error.WorkspaceIdentityMismatch;
        if (request.action == .discover) if (request.capability) |selector| {
            const basis = (if (selected) |view| view.task.model_basis else try manager.modelBasis(pinned)) orelse return error.WorkspaceMigrationRequired;
            const definition = try manager.loadDeclaration(basis.revision);
            if (!std.mem.eql(u8, basis.definition_hash, definition.hash)) return error.StaleWorkspaceDefinition;
            const result = try @import("company_capabilities.zig").inspect(manager, current, original_grant, definition, selector, request.realisation, request.capability_selections, request.offset, request.limit);
            return encode(alloc, .{ .version = "omos.company-capability/v1", .workspace = current.workspace, .revision = pinned, .definition_revision = basis.revision, .definition_hash = definition.hash, .semantic_version = definition.semantic.version, .scope_filtered = true, .read_tracking = if (selected != null) "model_basis" else "not_recorded", .capability = result.capability, .package = if (result.body) |body| try requestPage(manager, body, request.offset, request.limit) else null, .capabilities = result.capabilities, .total = result.total, .next_offset = result.next_offset });
        };
        if (request.action == .discover) if (request.entity) |selector| {
            const basis = (if (selected) |view| view.task.model_basis else try manager.modelBasis(pinned)) orelse return error.WorkspaceMigrationRequired;
            const declaration = try manager.loadDeclaration(basis.revision);
            if (!std.mem.eql(u8, basis.definition_hash, declaration.hash)) return error.StaleWorkspaceDefinition;
            const result = try @import("company_schema.zig").inspect(alloc, declaration, grant, selector, request.offset, request.limit);
            return encode(alloc, .{ .version = "omos.company-schema/v1", .workspace = current.workspace, .revision = pinned, .definition_revision = basis.revision, .definition_hash = declaration.hash, .semantic_version = declaration.semantic.version, .scope_filtered = true, .read_tracking = if (selected != null) "model_basis" else "not_recorded", .entity = result.entity, .schema = if (result.body) |body| try requestPage(manager, body, request.offset, request.limit) else null, .entities = result.entities, .total = result.total, .next_offset = result.next_offset });
        };
        const package = @import("capability_package.zig");
        const export_plan: ?package.Plan = if (request.action == .export_scope and request.capability != null) selected_plan: {
            const basis = (if (selected) |view| view.task.model_basis else try manager.modelBasis(pinned)) orelse return error.WorkspaceMigrationRequired;
            const definition = try manager.loadDeclaration(basis.revision);
            if (!std.mem.eql(u8, basis.definition_hash, definition.hash)) return error.StaleWorkspaceDefinition;
            const plan = try @import("company_capabilities.zig").packagePlan(manager, current, original_grant, definition, request.capability.?, request.realisation, request.capability_selections);
            if (!plan.declaration_complete) return error.IncompleteCapabilityPackage;
            const inventory = try manager.inventory(pinned);
            for (plan.paths) |selector| {
                // Directory scopes must cover the whole selector. Filtering an
                // incomplete directory would falsely establish portability.
                if (!authority.permitsSelector(grant, selector.path)) return error.CompanyAccessDenied;
                const found = for (inventory) |path| {
                    if (std.mem.eql(u8, path, selector.path) or (std.mem.endsWith(u8, selector.path, "/") and std.mem.startsWith(u8, path, selector.path))) break true;
                } else false;
                if (!found) return error.IncompleteCapabilityPackage;
            }
            break :selected_plan plan;
        } else null;
        const directory_export = request.action == .export_scope and request.path != null and std.mem.endsWith(u8, request.path.?, "/");
        const selector = if (request.action == .discover or directory_export) request.path else null;
        if (selector) |path| if (!authority.permitsSelector(grant, path)) return error.CompanyAccessDenied;
        var flags = std.StringHashMap(fossil_manifest.File).init(alloc);
        defer flags.deinit();
        if (attributes) for (try manager.fileManifest(pinned)) |file| {
            if (!authority.permitsPath(grant, file.path)) continue;
            if (selector) |path| if (!std.mem.eql(u8, file.path, path) and !(std.mem.endsWith(u8, path, "/") and std.mem.startsWith(u8, file.path, path))) continue;
            if (file.mode == .symlink) return error.WorkspaceSymlinkDenied;
            try flags.put(file.path, file);
        };
        if (request.action == .query) return retainRead(manager, grant, request, if (selected) |view| view.view else null, pinned, try @import("company_records.zig").query(manager, grant, request, pinned), writable);
        if (request.action == .read or (request.action == .export_scope and request.path != null and !directory_export)) {
            const path = request.path orelse return error.MissingPath;
            if (!authority.permitsPath(grant, path)) return error.CompanyAccessDenied;
            const present = for (try manager.inventory(pinned)) |entry| {
                if (std.mem.eql(u8, entry, path)) break true;
            } else false;
            if (!present) {
                if (request.offset != 0) return error.InvalidEvidenceOffset;
                var result = try parse(alloc, try encode(alloc, .{ .revision = pinned, .path = path, .exists = false, .content = "", .encoding = "base64", .bytes = 0, .sha256 = @as(?[]const u8, null), .next_offset = @as(?usize, null) }));
                if (attributes) try result.object.put(alloc, "executable", .null);
                return retainRead(manager, grant, request, if (selected) |view| view.view else null, pinned, try encode(alloc, result), writable);
            }
            const bytes = try manager.contentAt(path, pinned);
            if (attributes) try fossil_manifest.verifyObject((flags.get(path) orelse return error.WorkspaceVerificationFailed).artifact.?, bytes);
            if (request.limit == 0 or request.limit > 16384 or request.offset > bytes.len) return error.InvalidEvidenceOffset;
            const end = request.offset + @min(request.limit, bytes.len - request.offset);
            const segment = bytes[request.offset..end];
            const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(segment.len));
            var result = try parse(alloc, try encode(alloc, .{ .revision = pinned, .path = path, .exists = true, .offset = request.offset, .content = std.base64.standard.Encoder.encode(encoded, segment), .encoding = "base64", .bytes = bytes.len, .sha256 = try workspace.hash(alloc, bytes), .next_offset = if (end < bytes.len) @as(?usize, end) else null }));
            if (attributes) try result.object.put(alloc, "executable", .{ .bool = (flags.get(path) orelse return error.WorkspaceVerificationFailed).mode == .executable });
            return retainRead(manager, grant, request, if (selected) |view| view.view else null, pinned, try encode(alloc, result), writable);
        }
        var files: std.ArrayList(std.json.Value) = .empty;
        var count: usize = 0;
        // Row count alone can hide 32 maximum-sized object reads. Stop after
        // crossing the byte budget; one bounded object can cross the boundary.
        var inspected_bytes: usize = 0;
        const inspection_budget = 4 * 1024 * 1024;
        for (try manager.inventory(pinned)) |path| {
            if (!authority.permitsPath(grant, path)) continue;
            if (selector) |selected_path| if (!std.mem.eql(u8, path, selected_path) and !(std.mem.endsWith(u8, selected_path, "/") and std.mem.startsWith(u8, path, selected_path))) continue;
            if (export_plan) |plan| if (!package.includes(plan, path)) continue;
            if (count >= request.offset and files.items.len < 32 and inspected_bytes < inspection_budget) {
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                var reader = manager;
                reader.alloc = scratch.allocator();
                const bytes = try reader.contentAt(path, pinned);
                inspected_bytes += bytes.len;
                if (attributes) try fossil_manifest.verifyObject((flags.get(path) orelse return error.WorkspaceVerificationFailed).artifact.?, bytes);
                var result = try parse(alloc, try encode(alloc, .{ .path = path, .sha256 = try workspace.hash(scratch.allocator(), bytes), .bytes = bytes.len }));
                if (attributes) try result.object.put(alloc, "executable", .{ .bool = (flags.get(path) orelse return error.WorkspaceVerificationFailed).mode == .executable });
                try files.append(alloc, result);
            }
            count += 1;
        }
        return retainRead(manager, grant, request, if (selected) |view| view.view else null, pinned, try encode(alloc, .{ .version = if (request.action == .export_scope) (if (attributes) "omos.scoped-export/v2" else "omos.scoped-export/v1") else (if (attributes) "omos.scoped-inventory/v2" else "omos.scoped-inventory/v1"), .workspace = current.workspace, .revision = pinned, .actor = grant.actor, .grant = grant.id, .files = files.items, .next_offset = if (request.offset + files.items.len < count) @as(?usize, request.offset + files.items.len) else null, .total = count, .content_endpoint = "/v1/company", .dependency_closure = if (export_plan != null) "declared_complete" else "not_evaluated", .package_hash = if (export_plan) |plan| try workspace.hash(alloc, try encode(alloc, plan)) else @as(?[]const u8, null), .authority = "content_only" }), writable);
    }
    return error.UnsupportedCompanyApi;
}

test "company outcome inspection retains the selected view boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var journal: Journal = .{ .actor = "actor", .grant = "grant", .operation = "operation", .request_hash = "hash", .state = .completed, .view = "first" };
    try requireOutcomeView(alloc, journal, null);
    try requireOutcomeView(alloc, journal, "first");
    try std.testing.expectError(error.CompanyAccessDenied, requireOutcomeView(alloc, journal, "other"));
    journal.view = null;
    journal.request = try encode(alloc, authority.Envelope{ .payload = "{\"action\":\"execution\",\"view\":\"first\"}", .signature = "signature" });
    try requireOutcomeView(alloc, journal, "first");
    try std.testing.expectError(error.CompanyAccessDenied, requireOutcomeView(alloc, journal, "other"));
    journal.request = try encode(alloc, authority.Envelope{ .payload = "{\"action\":\"create_view\"}", .signature = "signature" });
    journal.result = "{\"view\":\"first\",\"revision\":\"revision\"}";
    try requireOutcomeView(alloc, journal, "first");
    try std.testing.expectError(error.CompanyAccessDenied, requireOutcomeView(alloc, journal, "other"));
    journal.state = .pending;
    try std.testing.expectError(error.CompanyAccessDenied, requireOutcomeView(alloc, journal, "first"));
    journal.request = null;
    try std.testing.expectError(error.CompanyAccessDenied, requireOutcomeView(alloc, journal, "first"));
}
