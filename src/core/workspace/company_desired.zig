//! Company desired state is intent. Only a separately enrolled operator policy
//! can assign an actor, scope and invocation budget to reconcile that intent.
const std = @import("std");
const authority = @import("company_authority.zig");
const scopes = @import("company_task_scope.zig");
const workspace = @import("fossil_workspace.zig");
const records = @import("../shared/record_json.zig");
const io = @import("../shared/io.zig");
const model = @import("definition.zig");

pub const policy_prefix = "authority/reconciliation/";
pub const binding_prefix = "company/desired/tasks/";
pub const state_prefix = "company/desired/state/";
pub const target_prefix = "records/company_desired_capability/";

pub const Target = struct {
    version: []const u8 = "omos.company-desired-capability/v1",
    capability: []const u8,
    objective: []const u8,
    criteria: []const []const u8,
    paths: []const []const u8,
    observations: []const []const u8 = &.{},
    enabled: bool = true,
};
pub const Policy = struct {
    version: []const u8 = "omos.company-reconciliation-policy/v1",
    workspace: []const u8,
    id: []const u8,
    target_path: []const u8,
    actor: []const u8,
    grant: []const u8,
    allowed_paths: []const []const u8,
    execution_capability: []const u8 = "coding_task",
    enabled: bool = true,
    auto_retry: bool = false,
    max_invocations: u32 = 3,
    max_runtime_ms: u32 = 240000,
};
pub const Binding = struct {
    version: []const u8 = "omos.company-desired-binding/v1",
    workspace: []const u8,
    operation: []const u8,
    task: []const u8,
    view: []const u8,
    policy: []const u8,
    policy_sha256: []const u8,
    target_path: []const u8,
    target_sha256: []const u8,
    capability: []const u8,
    execution_capability: []const u8,
};
pub const Phase = enum { preparing, running, met, paused, unavailable, needs_revision };
pub const State = struct {
    version: []const u8 = "omos.company-reconciliation/v1",
    workspace: []const u8,
    policy: []const u8,
    policy_sha256: []const u8,
    target_sha256: []const u8,
    observed_sha256: []const u8,
    base_revision: []const u8,
    operation: []const u8,
    objective: []const u8,
    phase: Phase,
    task: ?[]const u8 = null,
    view: ?[]const u8 = null,
    publication_revision: ?[]const u8 = null,
    publication_observed_sha256: ?[]const u8 = null,
    note: ?[]const u8 = null,
};
pub const Request = struct {
    version: []const u8 = "omos.company-desired/v1",
    change: enum { inspect, register, tick },
    policy: ?Policy = null,
    id: ?[]const u8 = null,
    expected_sha256: ?[]const u8 = null,
    actor: ?[]const u8 = null,
    grant: ?[]const u8 = null,
    offset: usize = 0,
    limit: usize = 1,
};

fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}
fn digest(value: []const u8) !void {
    _ = try authority.hexBytes(32, value);
}
fn paths(values: []const []const u8, empty: bool) !void {
    if ((!empty and values.len == 0) or values.len > 32) return error.InvalidCompanyDesiredState;
    for (values, 0..) |value, index| {
        if (!authority.validPath(value, std.mem.endsWith(u8, value, "/"))) return error.InvalidCompanyDesiredState;
        for (values[0..index]) |previous| if (std.mem.eql(u8, previous, value)) return error.InvalidCompanyDesiredState;
    }
}
fn targetPath(value: []const u8) bool {
    return std.mem.startsWith(u8, value, target_prefix) and @import("company_records.zig").identity(value) != null;
}
pub fn validateTarget(target: Target) !void {
    if (!std.mem.eql(u8, target.version, "omos.company-desired-capability/v1") or !authority.safeIdentity(target.capability) or target.objective.len == 0 or target.objective.len > 8192 or !std.unicode.utf8ValidateSlice(target.objective) or target.criteria.len == 0 or target.criteria.len > 16) return error.InvalidCompanyDesiredState;
    var bytes = target.objective.len;
    for (target.criteria) |criterion| {
        if (criterion.len == 0 or criterion.len > 1024 or !std.unicode.utf8ValidateSlice(criterion)) return error.InvalidCompanyDesiredState;
        bytes += criterion.len;
    }
    if (bytes > 12288) return error.InvalidCompanyDesiredState;
    try paths(target.paths, false);
    try paths(target.observations, true);
}
pub fn validatePolicy(policy: Policy, path: []const u8, alloc: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, policy.version, "omos.company-reconciliation-policy/v1") or !authority.safeIdentity(policy.id) or !authority.safeIdentity(policy.actor) or !authority.safeIdentity(policy.grant) or !authority.safeIdentity(policy.execution_capability) or !targetPath(policy.target_path) or !std.mem.eql(u8, path, try alloc.print("{s}{s}.json", .{ policy_prefix, policy.id })) or policy.max_invocations == 0 or policy.max_invocations > 32 or policy.max_runtime_ms < 1000 or policy.max_runtime_ms > 240000) return error.InvalidCompanyDesiredState;
    try digest(policy.workspace);
    try paths(policy.allowed_paths, false);
}
pub fn authorizeTarget(policy: Policy, target: Target, grant: authority.Grant) !void {
    try validateTarget(target);
    if (!policy.enabled or !target.enabled or !std.mem.eql(u8, policy.actor, grant.actor) or !std.mem.eql(u8, policy.grant, grant.id)) return error.CompanyDesiredStatePaused;
    try scopes.validatePaths(grant, policy.allowed_paths);
    var boundary = grant;
    boundary.paths = policy.allowed_paths;
    try scopes.validatePaths(boundary, target.paths);
    if (target.observations.len > 0) try scopes.validatePaths(boundary, target.observations);
    for ([_]authority.Action{ .create_view, .read, .status, .checkpoint, .submit }) |action| if (!authority.permitsAction(grant, action)) return error.CompanyAccessDenied;
    if (!authority.permitsAction(grant, .execution) and !authority.permitsAction(grant, .execute_task)) return error.CompanyAccessDenied;
}
pub fn validateBinding(binding: Binding, path: []const u8, alloc: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, binding.version, "omos.company-desired-binding/v1") or !targetPath(binding.target_path) or !authority.safeIdentity(binding.operation) or !authority.safeIdentity(binding.task) or !authority.safeIdentity(binding.view) or !authority.safeIdentity(binding.policy) or !authority.safeIdentity(binding.capability) or !authority.safeIdentity(binding.execution_capability) or !std.mem.eql(u8, path, try alloc.print("{s}{s}.json", .{ binding_prefix, binding.operation }))) return error.InvalidCompanyDesiredState;
    for ([_][]const u8{ binding.workspace, binding.policy_sha256, binding.target_sha256 }) |hash| try digest(hash);
}
pub fn validateState(state: State, path: []const u8, alloc: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, state.version, "omos.company-reconciliation/v1") or !authority.safeIdentity(state.policy) or !authority.safeIdentity(state.operation) or !std.mem.eql(u8, path, try alloc.print("{s}{s}.json", .{ state_prefix, state.policy })) or !@import("fossil_manifest.zig").validHash(state.base_revision) or state.objective.len == 0 or state.objective.len > 16384) return error.InvalidCompanyDesiredState;
    for ([_][]const u8{ state.workspace, state.policy_sha256, state.target_sha256, state.observed_sha256 }) |hash| try digest(hash);
    if ((state.task == null) != (state.view == null)) return error.InvalidCompanyDesiredState;
    if (state.task) |task| if (!authority.safeIdentity(task) or !authority.safeIdentity(state.view.?)) return error.InvalidCompanyDesiredState;
    if (state.publication_revision) |revision| if (!@import("fossil_manifest.zig").validHash(revision)) return error.InvalidCompanyDesiredState;
    if (state.publication_observed_sha256) |hash| try digest(hash);
    if (state.phase == .met and (state.task == null or state.publication_revision == null or state.publication_observed_sha256 == null)) return error.InvalidCompanyDesiredState;
    if (state.note) |note| if (note.len > 1024 or !std.unicode.utf8ValidateSlice(note)) return error.InvalidCompanyDesiredState;
}

const Context = struct { policy: Policy, policy_sha256: []const u8, target: Target, target_sha256: []const u8, grant: authority.Grant };
fn optional(manager: workspace.Manager, path: []const u8) !?[]const u8 {
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision)) |entry| if (std.mem.eql(u8, path, entry)) return try manager.contentAt(path, revision);
    return null;
}
fn context(manager: workspace.Manager, policy: Policy) !Context {
    const raw = try manager.companyContent(try manager.alloc.print("{s}{s}.json", .{ policy_prefix, policy.id }));
    const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const grant = try authority.liveGrant(state, policy.grant, io.milliTimestamp());
    const bytes = try manager.contentAt(policy.target_path, "trunk");
    const Record = struct { entity: []const u8, id: []const u8, data: std.json.Value };
    const target_record = try records.decode(Record, manager.alloc, bytes, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, target_record.entity, "company_desired_capability") or !std.mem.eql(u8, policy.target_path, try @import("company_records.zig").path(manager.alloc, target_record.entity, target_record.id))) return error.InvalidCompanyDesiredState;
    const target = try records.decode(Target, manager.alloc, try json(manager.alloc, target_record.data), .{});
    try authorizeTarget(policy, target, grant);
    return .{ .policy = policy, .policy_sha256 = try workspace.hash(manager.alloc, raw), .target = target, .target_sha256 = try workspace.hash(manager.alloc, bytes), .grant = grant };
}

/// Called before effects and again within publication. Desired documents cannot
/// grant authority; removing or changing the pinned intent invalidates old work.
pub fn require(manager: workspace.Manager, task: workspace.Task) !void {
    if (task.authority == null) return;
    const path = task.authority.?.desired orelse return;
    if (!std.mem.startsWith(u8, path, binding_prefix)) return error.InvalidCompanyDesiredState;
    const raw = try manager.companyContent(path);
    const binding = try records.decode(Binding, manager.alloc, raw, .{});
    try validateBinding(binding, path, manager.alloc);
    const episode_path = try statePath(manager.alloc, binding.policy);
    const episode = try records.decode(State, manager.alloc, try manager.companyContent(episode_path), .{});
    try validateState(episode, episode_path, manager.alloc);
    if (!std.mem.eql(u8, episode.operation, binding.operation) or episode.task == null or !std.mem.eql(u8, episode.task.?, task.id)) return error.CompanyDesiredStateSuperseded;
    const policy_path = try manager.alloc.print("{s}{s}.json", .{ policy_prefix, binding.policy });
    const policy = try records.decode(Policy, manager.alloc, try manager.companyContent(policy_path), .{});
    try validatePolicy(policy, policy_path, manager.alloc);
    const selected = try context(manager, policy);
    if (!std.mem.eql(u8, binding.workspace, manager.manifest.id) or !std.mem.eql(u8, binding.task, task.id) or !std.mem.eql(u8, policy.actor, task.authority.?.actor) or !std.mem.eql(u8, policy.grant, task.authority.?.grant) or !std.mem.eql(u8, selected.policy_sha256, binding.policy_sha256) or !std.mem.eql(u8, selected.target_sha256, binding.target_sha256) or !std.mem.eql(u8, binding.capability, selected.target.capability)) return error.CompanyDesiredStateChanged;
    if (task.model_basis) |basis| if (basis.capability) |capability| if (!std.mem.eql(u8, capability, binding.execution_capability)) return error.CompanyDesiredExecutionCapabilityMismatch;
    // Pending proposals cannot absorb newly accepted inputs without another
    // episode. Accepted tasks are compared with their publication snapshot.
    if (task.state != .accepted and !std.mem.eql(u8, episode.observed_sha256, try observed(manager, selected.target, try manager.revision("trunk")))) return error.CompanyDesiredObservationChanged;
}

test "company desired state stays within separately delegated policy authority" {
    const grant: authority.Grant = .{ .id = "grant", .actor = "actor", .public_key = "key", .paths = &.{ "documents/", "ui/" }, .actions = &.{ .create_view, .read, .status, .checkpoint, .submit, .execute_task }, .expires_ms = 10000 };
    const policy: Policy = .{ .workspace = "0000000000000000000000000000000000000000000000000000000000000000", .id = "policy", .actor = "actor", .grant = "grant", .target_path = "records/company_desired_capability/report.json", .allowed_paths = &.{"documents/team/"} };
    const target: Target = .{ .capability = "reporting", .objective = "Keep the report current", .criteria = &.{"The report matches accepted company records."}, .paths = &.{"documents/team/report.md"} };
    try authorizeTarget(policy, target, grant);
    var changed = target;
    changed.paths = &.{"ui/"};
    try std.testing.expectError(error.CompanyAccessDenied, authorizeTarget(policy, changed, grant));
    changed = target;
    changed.observations = &.{"documents/private/"};
    try std.testing.expectError(error.CompanyAccessDenied, authorizeTarget(policy, changed, grant));
    changed = target;
    changed.enabled = false;
    try std.testing.expectError(error.CompanyDesiredStatePaused, authorizeTarget(policy, changed, grant));
    var disabled = policy;
    disabled.enabled = false;
    try std.testing.expectError(error.CompanyDesiredStatePaused, authorizeTarget(disabled, target, grant));
}

fn statePath(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    if (!authority.safeIdentity(id)) return error.InvalidCompanyDesiredState;
    return alloc.print("{s}{s}.json", .{ state_prefix, id });
}
fn save(manager: workspace.Manager, state: State) !void {
    const path = try statePath(manager.alloc, state.policy);
    try validateState(state, path, manager.alloc);
    const bytes = try json(manager.alloc, state);
    if (try optional(manager, path)) |before| if (std.mem.eql(u8, before, bytes)) return;
    _ = try manager.companyWrite(try manager.companyRevision(), &.{.{ .path = path, .content = bytes }});
}
fn selectedPath(target: Target, path: []const u8) bool {
    for ([_][]const []const u8{ target.paths, target.observations }) |selectors| for (selectors) |selector| {
        if (if (std.mem.endsWith(u8, selector, "/")) std.mem.startsWith(u8, path, selector) else std.mem.eql(u8, path, selector)) return true;
    };
    return false;
}
fn observed(manager: workspace.Manager, target: Target, revision: []const u8) ![]const u8 {
    var digest_state = std.crypto.hash.sha2.Sha256.init(.{});
    digest_state.update("omos.company-observed-scope/v1\n");
    for (try manager.fileManifest(revision)) |entry| {
        if (!selectedPath(target, entry.path)) continue;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        digest_state.update(try json(scratch.allocator(), entry));
        digest_state.update("\n");
    }
    var result: [32]u8 = undefined;
    digest_state.final(&result);
    return manager.alloc.dupe(u8, &std.fmt.bytesToHex(&result, .lower));
}
fn declared(declaration: model.Declaration, id: []const u8) bool {
    for (model.items(model.spec(declaration.value), "capabilities")) |capability| if (std.mem.eql(u8, model.text(capability, "id"), id)) return true;
    return false;
}
fn prepare(manager: workspace.Manager, selected: Context, observed_hash: []const u8, revision: []const u8) !State {
    const operation = try workspace.hash(manager.alloc, try json(manager.alloc, .{ "company-desired", selected.policy.id, selected.policy_sha256, selected.target_sha256, observed_hash, revision }));
    const objective = try manager.alloc.print("{s}\nSuccess criteria:\n{s}\nReconcile these criteria against accepted company state. Inspect existing records and evidence first. Preserve completed effects and already satisfied criteria; a new task is not a request to repeat earlier actions.\nCompany capability: {s}\nExecution capability: {s}\nReconciliation policy: {s}\nPinned target: {s}\nTarget SHA-256: {s}\n", .{ selected.target.objective, try json(manager.alloc, selected.target.criteria), selected.target.capability, selected.policy.execution_capability, selected.policy.id, selected.policy.target_path, selected.target_sha256 });
    if (objective.len > 16384) return error.InvalidCompanyDesiredState;
    return .{ .workspace = manager.manifest.id, .policy = selected.policy.id, .policy_sha256 = selected.policy_sha256, .target_sha256 = selected.target_sha256, .observed_sha256 = observed_hash, .base_revision = revision, .operation = operation, .objective = objective, .phase = .preparing };
}
fn createView(manager: workspace.Manager, selected: Context, state: State) !State {
    const view_id = try workspace.hash(manager.alloc, try json(manager.alloc, .{ "company-desired", selected.policy.id, state.operation }));
    const session = try manager.alloc.print("company-{s}", .{view_id});
    const project = try std.Io.Dir.path.join(manager.alloc, &.{ manager.root, "company-workers", view_id });
    const binding_path = try manager.alloc.print("{s}{s}.json", .{ binding_prefix, state.operation });
    const actor: authority.Binding = .{ .actor = selected.policy.actor, .grant = selected.policy.grant, .desired = binding_path };
    var starter = manager;
    starter.expected_revision = state.base_revision;
    const task = if (try manager.active(session)) |previous| try manager.bindCompanyTask(previous, actor) else try starter.startCompany(session, project, state.objective, actor);
    const scope_path = try scopes.path(manager.alloc, task.id);
    const binding: Binding = .{ .workspace = manager.manifest.id, .operation = state.operation, .task = task.id, .view = view_id, .policy = selected.policy.id, .policy_sha256 = selected.policy_sha256, .target_path = selected.policy.target_path, .target_sha256 = selected.target_sha256, .capability = selected.target.capability, .execution_capability = selected.policy.execution_capability };
    var next = state;
    next.task = task.id;
    next.view = view_id;
    next.phase = .running;
    try validateState(next, try statePath(manager.alloc, state.policy), manager.alloc);
    _ = try manager.companyWrite(try manager.companyRevision(), &.{
        .{ .path = try manager.alloc.print("company/views/{s}.json", .{view_id}), .content = try json(manager.alloc, .{ .id = view_id, .actor = actor.actor, .grant = actor.grant, .task = task.id, .base = task.base_revision, .pending = @as(?[]const u8, null), .reads = @as([]const @import("company_reads.zig").Reference, &.{}), .scope = scope_path, .created_at_ms = task.created_at_ms }) },
        .{ .path = scope_path, .content = try json(manager.alloc, scopes.Record{ .workspace = manager.manifest.id, .task = task.id, .view = view_id, .actor = actor.actor, .grant = actor.grant, .paths = selected.target.paths }) },
        .{ .path = binding_path, .content = try json(manager.alloc, binding) },
        .{ .path = try statePath(manager.alloc, state.policy), .content = try json(manager.alloc, next) },
    });
    return next;
}
fn queue(manager: workspace.Manager, selected: Context, state: State) !Phase {
    const jobs = @import("company_worker_jobs.zig");
    const inspected = try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try jobs.administer(manager, .{ .change = .inspect, .view = state.view.? }), .{});
    const rows = model.items(inspected, "jobs");
    if (rows.len == 0) {
        _ = try jobs.administer(manager, .{ .change = .queue, .operation = try workspace.hash(manager.alloc, try json(manager.alloc, .{ "desired-queue", state.operation })), .view = state.view, .max_invocations = selected.policy.max_invocations, .max_runtime_ms = selected.policy.max_runtime_ms });
    } else if (rows.len == 1) {
        const record = model.field(rows[0], "record") orelse return error.InvalidCompanyWorkerJob;
        const phase = model.text(record, "state");
        const review_phase = model.text(rows[0], "review_state");
        const review_failed = std.mem.eql(u8, phase, "submitted") and (std.mem.eql(u8, review_phase, "changes_required") or std.mem.eql(u8, review_phase, "blocked") or std.mem.eql(u8, review_phase, "failed"));
        if (std.mem.eql(u8, phase, "waiting") or std.mem.eql(u8, phase, "failed") or review_failed) {
            const encoded = try records.decode(jobs.Record, manager.alloc, try json(manager.alloc, record), .{});
            if (!selected.policy.auto_retry or encoded.invocations >= encoded.max_invocations) return .needs_revision;
            _ = try jobs.administer(manager, .{ .change = .requeue, .operation = try workspace.hash(manager.alloc, try json(manager.alloc, .{ "desired-requeue", state.operation, encoded.invocations })), .view = state.view, .expected_sha256 = model.text(rows[0], "sha256") });
        }
        if (std.mem.eql(u8, phase, "exhausted") or std.mem.eql(u8, phase, "cancelled")) return .needs_revision;
    } else if (rows.len > 1) return error.InvalidCompanyWorkerJob;
    return if (try @import("company_runtime.zig").available(manager, selected.grant, null)) .running else .unavailable;
}
fn tick(manager: workspace.Manager, policy: Policy) !State {
    const selected = try context(manager, policy);
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired).revision);
    if (!scopes.supported(declaration) or !model.hasOperation(declaration, "omos_company_worker_admin")) return error.CompanyDefinitionUpdateRequired;
    if (!declared(declaration, selected.target.capability) or !declared(declaration, policy.execution_capability)) return error.UnknownCapability;
    const revision = try manager.revision("trunk");
    const scope_hash = try observed(manager, selected.target, revision);
    const path = try statePath(manager.alloc, policy.id);
    const previous = if (try optional(manager, path)) |bytes| try records.decode(State, manager.alloc, bytes, .{}) else null;
    var next = if (previous) |before| value: {
        try validateState(before, path, manager.alloc);
        if (!std.mem.eql(u8, before.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
        if (!std.mem.eql(u8, before.target_sha256, selected.target_sha256) or !std.mem.eql(u8, before.policy_sha256, selected.policy_sha256)) break :value try prepare(manager, selected, scope_hash, revision);
        if (before.task) |id| {
            const task = try manager.refreshTaskContext(try manager.loadTask(id));
            if (task.state == .accepted) {
                const receipt = try manager.publicationSummary(task);
                var completed = before;
                completed.publication_revision = model.text(receipt, "revision");
                completed.publication_observed_sha256 = try observed(manager, selected.target, completed.publication_revision.?);
                if (!std.mem.eql(u8, scope_hash, completed.publication_observed_sha256.?)) break :value try prepare(manager, selected, scope_hash, revision);
                completed.phase = .met;
                completed.note = "The current selected state matches the independently accepted company outcome.";
                try save(manager, completed);
                return completed;
            }
            if (!std.mem.eql(u8, scope_hash, before.observed_sha256)) break :value try prepare(manager, selected, scope_hash, revision);
            try require(manager, task);
            var ongoing = before;
            ongoing.phase = try queue(manager, selected, ongoing);
            try save(manager, ongoing);
            return ongoing;
        }
        break :value if (std.mem.eql(u8, scope_hash, before.observed_sha256)) before else try prepare(manager, selected, scope_hash, revision);
    } else try prepare(manager, selected, scope_hash, revision);
    try save(manager, next); // Durable intent precedes task creation and dispatch.
    next = try createView(manager, selected, next);
    next.phase = try queue(manager, selected, next);
    try save(manager, next);
    return next;
}

/// The owner route holds the company lease. Every policy is separate from the
/// editable desired record, so an intent cannot enroll or enlarge an actor.
pub fn administer(manager: workspace.Manager, request: Request) ![]const u8 {
    if (!manager.company_operation_held) return error.CompanyOperationLeaseRequired;
    if (!std.mem.eql(u8, request.version, "omos.company-desired/v1") or request.limit == 0 or request.limit > 32 or request.offset > 1000000) return error.InvalidCompanyDesiredState;
    const current = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (request.change == .register) {
        const policy = request.policy orelse return error.InvalidCompanyDesiredState;
        if (request.id != null or request.actor != null or request.grant != null or request.offset != 0) return error.InvalidCompanyDesiredState;
        const path = try manager.alloc.print("{s}{s}.json", .{ policy_prefix, policy.id });
        try validatePolicy(policy, path, manager.alloc);
        if (!std.mem.eql(u8, policy.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
        const before = try optional(manager, path);
        if (before) |bytes| {
            if (request.expected_sha256 == null or !std.mem.eql(u8, request.expected_sha256.?, try workspace.hash(manager.alloc, bytes))) return error.CompanyDesiredPolicyChanged;
        } else if (request.expected_sha256 != null) return error.CompanyDesiredPolicyChanged;
        if (policy.enabled) {
            // Persisting first would let invalid policy records survive a failed
            // target lookup. Validate authority without granting it from intent.
            const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
            const grant = try authority.liveGrant(state, policy.grant, io.milliTimestamp());
            if (!std.mem.eql(u8, grant.actor, policy.actor)) return error.CompanyAccessDenied;
            try scopes.validatePaths(grant, policy.allowed_paths);
        }
        const bytes = try json(manager.alloc, policy);
        if (before == null or !std.mem.eql(u8, before.?, bytes)) _ = try manager.companyWrite(current, &.{.{ .path = path, .content = bytes }});
        return json(manager.alloc, .{ .revision = try manager.companyRevision(), .id = policy.id, .sha256 = try workspace.hash(manager.alloc, bytes) });
    }
    if (request.policy != null or request.expected_sha256 != null) return error.InvalidCompanyDesiredState;
    var rows: std.ArrayList(std.json.Value) = .empty;
    const headers = try policyHeaders(manager, current, request.actor, request.grant, request.id, request.offset, request.limit + 1);
    for (headers[0..@min(headers.len, request.limit)]) |header| {
        const policy = try records.decode(Policy, manager.alloc, try manager.contentAt(header.filename, current), .{});
        try validatePolicy(policy, header.filename, manager.alloc);
        if (!std.mem.eql(u8, header.id, policy.id)) return error.InvalidCompanyDesiredState;
        const encoded = if (request.change == .tick) result: {
            if (tick(manager, policy)) |outcome| break :result try json(manager.alloc, .{ .policy = policy.id, .state = outcome, .failure = @as(?[]const u8, null) }) else |err| break :result try json(manager.alloc, .{ .policy = policy.id, .state = @as(?State, null), .failure = @errorName(err) });
        } else try json(manager.alloc, .{ .policy = policy, .sha256 = try workspace.hash(manager.alloc, try json(manager.alloc, policy)), .state = if (try optional(manager, try statePath(manager.alloc, policy.id))) |bytes| try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, bytes, .{}) else null });
        try rows.append(manager.alloc, try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, encoded, .{}));
    }
    return json(manager.alloc, .{ .revision = try manager.companyRevision(), .policies = rows.items, .next_offset = if (headers.len > request.limit) @as(?usize, request.offset + rows.items.len) else null });
}

pub fn validateControl(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8, workspace_id: []const u8) !void {
    const identity = if (std.mem.startsWith(u8, path, policy_prefix)) value: {
        const policy = try records.decode(Policy, alloc, bytes, .{});
        try validatePolicy(policy, path, alloc);
        break :value policy.workspace;
    } else if (std.mem.startsWith(u8, path, binding_prefix)) value: {
        const binding = try records.decode(Binding, alloc, bytes, .{});
        try validateBinding(binding, path, alloc);
        break :value binding.workspace;
    } else if (std.mem.startsWith(u8, path, state_prefix)) value: {
        const state = try records.decode(State, alloc, bytes, .{});
        try validateState(state, path, alloc);
        break :value state.workspace;
    } else return error.InvalidCompanyDesiredState;
    if (!std.mem.eql(u8, identity, workspace_id)) return error.WorkspaceIdentityMismatch;
}

pub fn validateCandidate(manager: workspace.Manager, task: workspace.Task) !void {
    const actor = task.authority orelse return;
    const path = actor.desired orelse return;
    const binding = try records.decode(Binding, manager.alloc, try manager.companyContent(path), .{});
    try validateBinding(binding, path, manager.alloc);
    for (try manager.changedPaths(task.base_revision, try manager.currentRevision(task))) |changed| if (std.mem.eql(u8, changed, binding.target_path)) return error.CompanyDesiredStateSelfMutation;
}

const Header = struct { filename: []const u8, id: []const u8 };
fn policyHeaders(manager: workspace.Manager, revision: []const u8, actor: ?[]const u8, grant: ?[]const u8, id: ?[]const u8, offset: usize, limit: usize) ![]const Header {
    const raw = try manager.companyPolicyHeaders(revision, actor, grant, id, offset, limit);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return &.{};
    const rows = try records.decode([]const struct { entry: []const u8 }, manager.alloc, raw, .{});
    if (rows.len > limit) return error.InvalidCompanyDesiredState;
    const headers = try manager.alloc.alloc(Header, rows.len);
    for (rows, headers) |row, *header| {
        header.* = try records.decode(Header, manager.alloc, row.entry, .{});
        if (!authority.safeIdentity(header.id) or !std.mem.eql(u8, header.filename, try manager.alloc.print("{s}{s}.json", .{ policy_prefix, header.id }))) return error.InvalidCompanyDesiredState;
    }
    return headers;
}

/// Signed metadata for the currently assigned actor and grant. Revision pins
/// select membership; current enrollment and permissions still gate every row.
pub fn page(manager: workspace.Manager, grant: authority.Grant, request: authority.Request, task: ?workspace.Task) ![]const u8 {
    if (!manager.company_operation_held or request.limit == 0 or request.limit > 32 or request.offset > 1000000) return error.InvalidCompanyDesiredState;
    const current = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    const revision = request.revision orelse current;
    if (!@import("fossil_manifest.zig").validHash(revision) or !try manager.revisionDescendsFrom(current, revision)) return error.CompanyAccessDenied;
    const policy_id: ?[]const u8 = if (task) |selected| value: {
        const actor = selected.authority orelse return error.CompanyAccessDenied;
        const binding_path = actor.desired orelse return error.CompanyAccessDenied;
        const binding = try records.decode(Binding, manager.alloc, try manager.companyContent(binding_path), .{});
        try validateBinding(binding, binding_path, manager.alloc);
        if (!std.mem.eql(u8, binding.task, selected.id)) return error.CompanyAccessDenied;
        break :value binding.policy;
    } else null;
    const limit = @min(request.limit, 4);
    const headers = try policyHeaders(manager, revision, grant.actor, grant.id, policy_id, request.offset, limit + 1);
    var rows: std.ArrayList(std.json.Value) = .empty;
    for (headers[0..@min(headers.len, limit)]) |header| {
        const policy = try records.decode(Policy, manager.alloc, try manager.companyContent(header.filename), .{});
        try validatePolicy(policy, header.filename, manager.alloc);
        if (!std.mem.eql(u8, policy.actor, grant.actor) or !std.mem.eql(u8, policy.grant, grant.id)) return error.CompanyAccessDenied;
        const state_path = try statePath(manager.alloc, policy.id);
        const retained = if (try optional(manager, state_path)) |bytes| try records.decode(State, manager.alloc, bytes, .{}) else null;
        var phase: Phase = if (retained) |value| value.phase else .unavailable;
        var failure: ?[]const u8 = null;
        const selected: ?Context = context(manager, policy) catch |err| value: {
            phase = .paused;
            failure = @errorName(err);
            break :value null;
        };
        if (retained) |value| {
            try validateState(value, state_path, manager.alloc);
            if (!std.mem.eql(u8, value.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
            if (task) |bound| if (value.task == null or !std.mem.eql(u8, value.task.?, bound.id)) return error.CompanyDesiredStateSuperseded;
            if (selected) |live| {
                if (!std.mem.eql(u8, value.target_sha256, live.target_sha256) or !std.mem.eql(u8, value.policy_sha256, live.policy_sha256)) phase = .needs_revision;
                if (phase == .met) {
                    const accepted = try manager.refreshTaskContext(try manager.loadTask(value.task.?));
                    const receipt = try manager.publicationSummary(accepted);
                    if (!std.mem.eql(u8, model.text(receipt, "revision"), value.publication_revision.?) or !std.mem.eql(u8, try observed(manager, live.target, try manager.revision("trunk")), value.publication_observed_sha256.?)) phase = .needs_revision;
                }
            }
        }
        const encoded = try json(manager.alloc, .{ .policy = policy.id, .state = @tagName(phase), .task = if (retained) |value| value.task else null, .view = if (retained) |value| value.view else null, .target_sha256 = if (retained) |value| value.target_sha256 else null, .publication_revision = if (retained) |value| value.publication_revision else null, .failure = failure });
        try rows.append(manager.alloc, try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, encoded, .{}));
    }
    return json(manager.alloc, .{ .version = "omos.company-desired-status/v1", .workspace = manager.manifest.id, .index_revision = revision, .policies = rows.items, .next_offset = if (headers.len > limit) @as(?usize, request.offset + rows.items.len) else null });
}
