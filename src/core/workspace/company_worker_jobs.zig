//! Host-owned invocation records. Company tasks and publication remain canonical;
//! these records bound dispatch, retain pauses, and fence replacement workers.
const std = @import("std");
const authority = @import("company_authority.zig");
const ownership = @import("company_execution.zig");

pub const State = enum { queued, running, waiting, submitted, failed, cancelled, completed, exhausted };
pub const Change = enum { inspect, queue, plan, claim, renew, finish, requeue, cancel, complete, expire, checkpoint };
pub const Outcome = enum { waiting, submitted, failed, completed };
pub const Checkpoint = struct {
    version: []const u8 = "omos.company-worker-checkpoint/v1",
    runtime: []const u8,
    generation: u64,
    image: []const u8,
    source_revision: []const u8,
    model: []const u8,
    phase: enum { prepared, running, stopped, retained },
    export_directory: ?[]const u8 = null,
    continuation: ?Continuation = null,
    pub const Continuation = struct { invocation: u32, archive: []const u8, source: []const u8 };
    pub fn jsonStringify(self: Checkpoint, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Checkpoint).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "continuation")) {
                if (self.continuation) |continued| {
                    try writer.objectField(name);
                    try writer.write(continued);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};

fn sameContinuation(a: ?Checkpoint.Continuation, b: ?Checkpoint.Continuation) bool {
    if (a) |left| return if (b) |right| left.invocation == right.invocation and std.mem.eql(u8, left.archive, right.archive) and std.mem.eql(u8, left.source, right.source) else false;
    return b == null;
}
fn invocation(checkpoint: Checkpoint) u32 {
    return if (checkpoint.continuation) |continued| continued.invocation else 1;
}

fn optionalCheckpointJson(value: anytype, writer: *std.json.Stringify) !void {
    try writer.beginObject();
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "checkpoint")) {
            if (value.checkpoint != null) {
                try writer.objectField(name);
                try writer.write(value.checkpoint);
            }
        } else {
            try writer.objectField(name);
            try writer.write(@field(value, name));
        }
    }
    try writer.endObject();
}
pub const Binding = struct {
    workspace: []const u8,
    view: []const u8,
    task: []const u8,
    actor: []const u8,
    grant: []const u8,
    contract_sha256: []const u8,
    definition_sha256: []const u8,
    policy_sha256: []const u8,
};
pub const Request = struct {
    change: Change,
    operation: ?[]const u8 = null,
    view: ?[]const u8 = null,
    expected_sha256: ?[]const u8 = null,
    execution: ?ownership.Fence = null,
    max_invocations: ?u32 = null,
    max_runtime_ms: ?u32 = null,
    outcome: ?Outcome = null,
    note: ?[]const u8 = null,
    offset: usize = 0,
    limit: usize = 32,
    checkpoint: ?Checkpoint = null,
    pub fn jsonStringify(self: Request, writer: *std.json.Stringify) !void {
        try optionalCheckpointJson(self, writer);
    }
};
pub const Record = struct {
    version: []const u8 = "omos.company-worker-job/v1",
    id: []const u8,
    binding: Binding,
    state: State = .queued,
    invocations: u32 = 0,
    max_invocations: u32 = 3,
    max_runtime_ms: u32 = 240000,
    runtime: ?[]const u8 = null,
    generation: u64 = 0,
    expires_ms: i64 = 0,
    operation: []const u8,
    request_hash: []const u8,
    request: Request,
    updated_ms: i64,
    note: ?[]const u8 = null,
    checkpoint: ?Checkpoint = null,
    pub fn jsonStringify(self: Record, writer: *std.json.Stringify) !void {
        try optionalCheckpointJson(self, writer);
    }
};

pub fn validate(record: Record) !void {
    if (!std.mem.eql(u8, record.version, "omos.company-worker-job/v1") or record.max_invocations == 0 or record.max_invocations > 32 or record.invocations > record.max_invocations or record.max_runtime_ms < 1000 or record.max_runtime_ms > 240000 or record.updated_ms < 0 or record.expires_ms < 0) return error.InvalidCompanyWorkerJob;
    _ = try authority.hexBytes(32, record.id);
    _ = try authority.hexBytes(32, record.request_hash);
    for ([_][]const u8{ record.binding.workspace, record.binding.contract_sha256, record.binding.definition_sha256, record.binding.policy_sha256 }) |hash| _ = try authority.hexBytes(32, hash);
    for ([_][]const u8{ record.binding.view, record.binding.task, record.binding.actor, record.binding.grant, record.operation }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyWorkerJob;
    if (record.runtime) |runtime| {
        if (!authority.safeIdentity(runtime) or record.generation == 0) return error.InvalidCompanyWorkerJob;
    } else if (record.state == .running or record.expires_ms != 0) return error.InvalidCompanyWorkerJob;
    if (record.state != .running and record.expires_ms != 0) return error.InvalidCompanyWorkerJob;
    if (record.note) |note| if (note.len > 1024 or !std.unicode.utf8ValidateSlice(note)) return error.InvalidCompanyWorkerJob;
    if (record.checkpoint) |saved| {
        if (!std.mem.eql(u8, saved.version, "omos.company-worker-checkpoint/v1") or !authority.safeIdentity(saved.runtime) or saved.generation == 0 or saved.generation > record.generation or saved.model.len == 0 or saved.model.len > 256 or !std.unicode.utf8ValidateSlice(saved.model)) return error.InvalidCompanyWorkerCheckpoint;
        _ = try authority.hexBytes(32, saved.image);
        if (!@import("fossil_manifest.zig").validHash(saved.source_revision)) return error.InvalidCompanyWorkerCheckpoint;
        if (saved.continuation) |continued| {
            if (continued.invocation < 2 or continued.invocation > record.invocations or !@import("fossil_manifest.zig").validHash(continued.source)) return error.InvalidCompanyWorkerCheckpoint;
            _ = try authority.hexBytes(32, continued.archive);
        }
        if (saved.export_directory) |directory| if (!std.mem.startsWith(u8, directory, ".omos-host-archive-") or directory.len > 128 or std.mem.findScalar(u8, directory, '/') != null or std.mem.findScalar(u8, directory, '\\') != null or std.mem.find(u8, directory, "..") != null) return error.InvalidCompanyWorkerCheckpoint;
    }
}

pub fn path(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    _ = try authority.hexBytes(32, id);
    return alloc.print("company/workers/jobs/{s}.json", .{id});
}

fn equalBinding(a: Binding, b: Binding) bool {
    inline for (@typeInfo(Binding).@"struct".field_names) |name| if (!std.mem.eql(u8, @field(a, name), @field(b, name))) return false;
    return true;
}

/// The caller owns the company operation lease and supplies a live execution
/// record. A completed outcome additionally requires host-verified publication.
pub fn transition(previous: ?Record, request: Request, binding: Binding, id: []const u8, request_hash: []const u8, live: ?ownership.Record, now: i64, publication_verified: bool, submission_retained: bool) !Record {
    const operation = request.operation orelse return error.InvalidCompanyIdentity;
    if (!authority.safeIdentity(operation) or request.change == .inspect or request.offset != 0 or request.limit != 32) return error.InvalidCompanyWorkerJob;
    if (request.view) |view| if (!std.mem.eql(u8, view, binding.view)) return error.CompanyAccessDenied;
    if (request.note) |note| if (note.len > 1024 or !std.unicode.utf8ValidateSlice(note)) return error.InvalidCompanyWorkerJob;
    if ((request.change == .checkpoint) != (request.checkpoint != null)) return error.InvalidCompanyWorkerCheckpoint;
    if (previous) |record| {
        try validate(record);
        if (!std.mem.eql(u8, record.id, id) or !equalBinding(record.binding, binding)) return error.StaleCompanyWorkerContract;
        if (std.mem.eql(u8, record.operation, operation)) {
            if (!std.mem.eql(u8, record.request_hash, request_hash)) return error.CompanyOperationConflict;
            return record;
        }
    }
    var next = previous orelse Record{ .id = id, .binding = binding, .operation = operation, .request_hash = request_hash, .request = request, .updated_ms = now };
    if (request.change == .queue) {
        if (previous != null or request.execution != null or request.outcome != null) return error.CompanyWorkerJobAlreadyExists;
        next.max_invocations = request.max_invocations orelse 3;
        next.max_runtime_ms = request.max_runtime_ms orelse 240000;
    } else {
        if (previous == null or request.max_invocations != null or request.max_runtime_ms != null) return error.InvalidCompanyWorkerJob;
        switch (request.change) {
            .claim => {
                if (request.outcome != null or (next.state != .queued and !(next.state == .running and next.expires_ms <= now))) return error.CompanyWorkerNotQueued;
                if (next.invocations >= next.max_invocations) return error.CompanyWorkerInvocationBudget;
                const current = live orelse return error.CompanyExecutionNotClaimed;
                const supplied = request.execution orelse return error.CompanyExecutionFenceRequired;
                try ownership.require(current, supplied, now);
                if (next.state == .running and current.generation <= next.generation) return error.CompanyExecutionFenced;
                if (!std.mem.eql(u8, current.view, binding.view) or !std.mem.eql(u8, current.task, binding.task) or !std.mem.eql(u8, current.actor, binding.actor) or !std.mem.eql(u8, current.grant, binding.grant)) return error.CompanyAccessDenied;
                if (current.expires_ms - now < next.max_runtime_ms + 1000) return error.InvalidCompanyExecutionLease;
                next.state = .running;
                next.invocations += 1;
                next.runtime = current.runtime;
                next.generation = current.generation;
                next.expires_ms = current.expires_ms;
            },
            .renew, .finish, .checkpoint => {
                if (next.state != .running) return error.CompanyWorkerNotRunning;
                const current = live orelse return error.CompanyExecutionNotClaimed;
                const supplied = request.execution orelse return error.CompanyExecutionFenceRequired;
                try ownership.require(current, supplied, now);
                if (next.runtime == null or !std.mem.eql(u8, next.runtime.?, supplied.runtime) or next.generation != supplied.generation) return error.CompanyExecutionFenced;
                if (next.expires_ms <= now) return error.CompanyExecutionExpired;
                if (request.change == .checkpoint) {
                    if (request.outcome != null) return error.InvalidCompanyWorkerCheckpoint;
                    const saved = request.checkpoint.?;
                    if (next.checkpoint) |prior| {
                        if (std.mem.eql(u8, saved.image, prior.image)) {
                            if (!std.mem.eql(u8, saved.runtime, prior.runtime) or saved.generation != prior.generation or !std.mem.eql(u8, saved.model, prior.model) or !std.mem.eql(u8, saved.source_revision, prior.source_revision)) return error.InvalidCompanyWorkerCheckpoint;
                            const continues = prior.phase == .stopped and saved.phase == .running and saved.continuation != null and invocation(saved) == next.invocations and invocation(saved) > invocation(prior) and saved.export_directory == null;
                            if (!continues) {
                                if (@backingInt(saved.phase) < @backingInt(prior.phase) or !sameContinuation(saved.continuation, prior.continuation)) return error.InvalidCompanyWorkerCheckpoint;
                                if (prior.export_directory) |directory| if (saved.export_directory == null or !std.mem.eql(u8, directory, saved.export_directory.?)) return error.InvalidCompanyWorkerCheckpoint;
                            }
                        } else if (prior.phase != .retained or saved.phase != .prepared or saved.generation <= prior.generation or saved.generation != next.generation or !std.mem.eql(u8, saved.runtime, next.runtime.?) or saved.export_directory != null or saved.continuation != null) return error.InvalidCompanyWorkerCheckpoint;
                    } else if (saved.phase != .prepared or saved.generation != next.generation or !std.mem.eql(u8, saved.runtime, next.runtime.?) or saved.continuation != null) return error.InvalidCompanyWorkerCheckpoint;
                    next.checkpoint = saved;
                } else if (request.change == .renew) {
                    if (request.outcome != null or current.expires_ms <= next.expires_ms) return error.InvalidCompanyExecutionLease;
                    next.expires_ms = current.expires_ms;
                } else {
                    const outcome = request.outcome orelse return error.InvalidCompanyWorkerJob;
                    if (outcome == .completed and !publication_verified) return error.WorkspaceVerificationFailed;
                    if (outcome == .submitted and !submission_retained) return error.CompanySubmissionRequired;
                    next.state = switch (outcome) {
                        .waiting => if (next.invocations == next.max_invocations) .exhausted else .waiting,
                        .submitted => .submitted,
                        .failed => .failed,
                        .completed => .completed,
                    };
                    if (outcome == .submitted or outcome == .completed) if (next.checkpoint) |*saved| {
                        saved.phase = .retained;
                    };
                    next.expires_ms = 0;
                }
            },
            .requeue => {
                if (request.execution != null or request.outcome != null or (next.state != .waiting and next.state != .failed and next.state != .exhausted and next.state != .submitted)) return error.CompanyWorkerNotWaiting;
                if (next.invocations >= next.max_invocations) return error.CompanyWorkerInvocationBudget;
                if (live) |current| if (current.runtime != null and current.expires_ms > now) return error.CompanyExecutionBusy;
                next.state = .queued;
                next.expires_ms = 0;
            },
            .expire => {
                if (request.execution != null or request.outcome != null or next.state != .running or next.expires_ms > now) return error.CompanyWorkerNotExpired;
                next.state = if (next.invocations == next.max_invocations) .exhausted else .waiting;
                next.expires_ms = 0;
            },
            .complete => {
                if (!publication_verified or request.execution != null or request.outcome != null) return error.WorkspaceVerificationFailed;
                next.state = .completed;
                next.expires_ms = 0;
                if (next.checkpoint) |*saved| saved.phase = .retained;
            },
            .cancel => {
                if (request.execution != null or request.outcome != null or next.state == .completed or next.state == .cancelled) return error.InvalidCompanyWorkerJob;
                // The caller atomically releases the matching execution fence
                // before returning acknowledgement and stopping the process.
                next.state = .cancelled;
                next.expires_ms = 0;
            },
            else => return error.InvalidCompanyWorkerJob,
        }
    }
    next.operation = operation;
    next.request_hash = request_hash;
    next.request = request;
    next.updated_ms = now;
    if (request.note != null) next.note = request.note;
    try validate(next);
    return next;
}

const workspace = @import("fossil_workspace.zig");
const records = @import("../shared/record_json.zig");
const io = @import("../shared/io.zig");

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

pub fn validateStored(alloc: std.mem.Allocator, record: Record, record_path: []const u8) !void {
    try validate(record);
    const operation = record.request.operation orelse return error.InvalidCompanyWorkerJob;
    const view = record.request.view orelse return error.InvalidCompanyWorkerJob;
    if (record.request.change == .inspect or !std.mem.eql(u8, operation, record.operation) or !std.mem.eql(u8, view, record.binding.view) or !std.mem.eql(u8, record.request_hash, try workspace.hash(alloc, try encode(alloc, record.request)))) return error.InvalidCompanyWorkerJob;
    if (std.mem.eql(u8, record_path, try path(alloc, record.id))) return;
    if (std.mem.eql(u8, record_path, try alloc.print("company/workers/history/{s}/{s}.json", .{ record.id, record.request_hash }))) return;
    if (std.mem.eql(u8, record_path, try alloc.print("company/workers/operations/{s}/{s}.json", .{ record.id, try workspace.hash(alloc, record.operation) }))) return;
    return error.InvalidCompanyWorkerJob;
}

fn optionalContent(manager: workspace.Manager, record_path: []const u8) !?[]const u8 {
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision)) |entry| if (std.mem.eql(u8, entry, record_path)) return try manager.contentAt(entry, revision);
    return null;
}

const View = struct { id: []const u8, actor: []const u8, grant: []const u8, task: []const u8, pending: ?[]const u8 = null, scope: ?[]const u8 = null };
const Context = struct { view: View, task: workspace.Task, grant: authority.Grant, binding: Binding, execution: ?ownership.Record, live: bool };

fn context(manager: workspace.Manager, view_id: []const u8) !Context {
    if (!authority.safeIdentity(view_id)) return error.InvalidCompanyIdentity;
    const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{view_id})), .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, view.id, view_id)) return error.WorkspaceIdentityMismatch;
    const task = try manager.refreshTaskContext(try manager.loadTask(view.task));
    const selected = task.authority orelse return error.CompanyAccessDenied;
    if (!std.mem.eql(u8, selected.actor, view.actor) or !std.mem.eql(u8, selected.grant, view.grant)) return error.CompanyAccessDenied;
    const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const grant = for (state.grants) |candidate| {
        if (std.mem.eql(u8, candidate.id, view.grant) and std.mem.eql(u8, candidate.actor, view.actor)) break candidate;
    } else return error.CompanyAccessDenied;
    const grant_live = if (authority.liveGrant(state, view.grant, io.milliTimestamp())) |_| true else |_| false;
    const desired_live = if (@import("company_desired.zig").require(manager, task)) |_| true else |_| false;
    const live = grant_live and desired_live;
    const basis = task.model_basis orelse return error.WorkspaceMigrationRequired;
    const execution = if (try optionalContent(manager, try ownership.path(manager.alloc, view_id))) |raw| value: {
        const record = try records.decode(ownership.Record, manager.alloc, raw, .{});
        try ownership.validate(record, view_id, task.id, grant);
        break :value record;
    } else null;
    return .{ .view = view, .task = task, .grant = try @import("company_task_scope.zig").forView(manager, task, grant, view.id, view.scope), .live = live, .execution = execution, .binding = .{ .workspace = manager.manifest.id, .view = view_id, .task = task.id, .actor = view.actor, .grant = view.grant, .contract_sha256 = try workspace.hash(manager.alloc, try encode(manager.alloc, .{ .definition = task.definition, .amendments = task.amendments, .request_artifact = task.request_artifact })), .definition_sha256 = basis.definition_hash, .policy_sha256 = basis.execution_hash orelse try workspace.hash(manager.alloc, try encode(manager.alloc, basis.execution)) } };
}

fn planRecord(manager: workspace.Manager, previous: Record, request: Request, selected: Context, operation: []const u8, request_hash: []const u8) !Record {
    if (previous.state != .queued or request.execution != null or request.outcome != null or request.max_invocations != null or request.max_runtime_ms != null) return error.CompanyWorkerNotQueued;
    var comparable = selected.binding;
    comparable.contract_sha256 = previous.binding.contract_sha256;
    if (!equalBinding(previous.binding, comparable)) return error.StaleCompanyWorkerContract;
    if (selected.execution) |execution| if (execution.runtime != null and execution.expires_ms > io.milliTimestamp()) return error.CompanyExecutionBusy;
    if (!selected.live) return error.CompanyAccessDenied;
    try authority.authorizeExecution(manager, selected.task);
    try manager.validateTaskBasis(selected.task);
    var next = previous;
    const retained = try manager.planningJob(selected.task);
    if (retained) |job| {
        if (job.kind != .planning or !std.mem.eql(u8, job.planning_contract_sha256.?, previous.binding.contract_sha256)) return error.StaleCompanyWorkerContract;
        if (job.state == .planned) {
            if (selected.task.model_basis == null or selected.task.model_basis.?.capability == null or selected.task.review_job != null) return error.InvalidReviewJob;
            next.binding = selected.binding;
            next.note = "The host retained the task plan before actor dispatch.";
        } else if (job.state == .queued or job.state == .running) {
            next.note = "Independent host planning is pending; no actor has started.";
        } else if (previous.request.change == .requeue) {
            _ = try manager.queuePlanning(selected.task, previous.binding.contract_sha256, true);
            next.note = "Independent host planning was explicitly requeued.";
        } else {
            next.state = .waiting;
            next.note = "Host planning needs attention. Inspect the retained planning job and requeue explicitly; actor work has not started.";
        }
    } else {
        _ = try manager.queuePlanning(selected.task, previous.binding.contract_sha256, false);
        next.note = "Independent host planning is queued; no actor has started.";
    }
    next.operation = operation;
    next.request_hash = request_hash;
    next.request = request;
    next.updated_ms = io.milliTimestamp();
    try validate(next);
    return next;
}

fn row(original: workspace.Manager, record: Record, raw: []const u8, details: bool) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var manager = original;
    manager.alloc = scratch.allocator();
    const current = try context(manager, record.binding.view);
    const review = if (current.task.review_job) |review_id| try manager.loadReviewJob(current.task, review_id) else null;
    const basis = (try manager.modelBasis("trunk")) orelse return error.WorkspaceMigrationRequired;
    const supports_planning = @import("company_planning.zig").supported(try manager.loadDeclaration(basis.revision));
    const changed_contract = !std.mem.eql(u8, record.binding.contract_sha256, current.binding.contract_sha256);
    const unplanned = current.task.model_basis == null or current.task.model_basis.?.capability == null;
    const planning = if (review != null and review.?.kind == .planning) review else if (supports_planning and (changed_contract or unplanned)) try manager.planningJob(current.task) else null;
    const planning_required = supports_planning and (unplanned or changed_contract or (planning != null and planning.?.state != .planned));
    const bytes = try encode(manager.alloc, .{ .record = record, .sha256 = try workspace.hash(manager.alloc, raw), .view_revision = try manager.currentRevision(current.task), .task_state = @tagName(current.task.state), .contract = if (details) current.task.definition else null, .request = if (details) try manager.originalRequest(current.task) else null, .amendments = if (details) current.task.amendments else &.{}, .review_job = if (details) review else null, .review_job_id = current.task.review_job, .review_state = if (review) |job| @tagName(job.state) else null, .planning_required = planning_required, .planning_state = if (planning) |job| @tagName(job.state) else null, .planning_job = if (details) planning else null, .basis = if (details) current.task.model_basis else null, .authority_live = current.live, .grant = if (details) current.grant else null, .execution = current.execution, .pending_operation = current.view.pending, .publication = if (current.task.state == .accepted) try manager.publicationSummary(current.task) else null });
    return std.json.parseFromSliceLeaky(std.json.Value, original.alloc, bytes, .{ .allocate = .alloc_always });
}

/// Called only by the local operator API with the company operation lease.
/// Definitions and actor-visible record writes cannot enter this path.
pub fn administer(manager: workspace.Manager, request: Request) ![]const u8 {
    if (!manager.company_operation_held) return error.CompanyOperationLeaseRequired;
    if (request.limit == 0 or request.limit > 32 or request.offset > 1000000) return error.InvalidCompanyWorkerJob;
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (request.change == .inspect) {
        if (request.operation != null or request.expected_sha256 != null or request.execution != null or request.max_invocations != null or request.max_runtime_ms != null or request.outcome != null or request.note != null or request.checkpoint != null) return error.InvalidCompanyWorkerJob;
        var jobs: std.ArrayList(std.json.Value) = .empty;
        var count: usize = 0;
        for (try manager.inventory(revision)) |entry| {
            if (!std.mem.startsWith(u8, entry, "company/workers/jobs/")) continue;
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var reader = manager;
            reader.alloc = scratch.allocator();
            const raw = try reader.contentAt(entry, revision);
            const record = try records.decode(Record, scratch.allocator(), raw, .{});
            try validateStored(scratch.allocator(), record, entry);
            if (request.view) |view_id| if (!std.mem.eql(u8, record.binding.view, view_id)) continue;
            if (count >= request.offset and jobs.items.len < request.limit) try jobs.append(manager.alloc, try row(manager, try records.decode(Record, manager.alloc, raw, .{}), raw, request.view != null));
            count += 1;
        }
        return encode(manager.alloc, .{ .revision = revision, .jobs = jobs.items, .next_offset = if (request.offset + jobs.items.len < count) @as(?usize, request.offset + jobs.items.len) else null, .total = count });
    }
    const view_id = request.view orelse return error.CompanyViewRequired;
    const selected = try context(manager, view_id);
    const task_lease = (try manager.tryTaskExecutionLease(selected.task.id)) orelse return error.WorkspaceExecutionBusy;
    defer task_lease.release();
    const id = try workspace.hash(manager.alloc, view_id);
    const record_path = try path(manager.alloc, id);
    const operation = request.operation orelse return error.InvalidCompanyIdentity;
    if (!authority.safeIdentity(operation)) return error.InvalidCompanyIdentity;
    const request_hash = try workspace.hash(manager.alloc, try encode(manager.alloc, request));
    const operation_path = try manager.alloc.print("company/workers/operations/{s}/{s}.json", .{ id, try workspace.hash(manager.alloc, operation) });
    if (try optionalContent(manager, operation_path)) |retained| {
        const committed = try records.decode(Record, manager.alloc, retained, .{});
        try validateStored(manager.alloc, committed, operation_path);
        if (!std.mem.eql(u8, committed.request_hash, request_hash)) return error.CompanyOperationConflict;
        return encode(manager.alloc, .{ .revision = revision, .jobs = .{try row(manager, committed, retained, true)}, .next_offset = @as(?usize, null), .replayed = true });
    }
    const previous_raw = try optionalContent(manager, record_path);
    const previous = if (previous_raw) |raw| try records.decode(Record, manager.alloc, raw, .{}) else null;
    if (previous) |record| try validateStored(manager.alloc, record, record_path);
    if (previous_raw) |raw| {
        if (request.expected_sha256 == null or !std.mem.eql(u8, request.expected_sha256.?, try workspace.hash(manager.alloc, raw))) return error.CompanyWorkerJobChanged;
    } else if (request.expected_sha256 != null) return error.CompanyWorkerJobChanged;
    if (request.change == .checkpoint) {
        try authority.authorizeExecution(manager, selected.task);
        try manager.validateTaskBasis(selected.task);
        if (!selected.live) return error.CompanyAccessDenied;
        const saved = request.checkpoint orelse return error.InvalidCompanyWorkerCheckpoint;
        const expected_image = try workspace.hash(manager.alloc, try encode(manager.alloc, .{ selected.binding.workspace, selected.binding.view, saved.runtime, saved.generation }));
        if (!std.mem.eql(u8, saved.image, expected_image)) return error.InvalidCompanyWorkerCheckpoint;
        if (saved.continuation) |continued| {
            _ = try authority.hexBytes(32, continued.archive);
            const archive_path = try manager.alloc.print("company/archives/{s}/{s}/receipt.json", .{ selected.task.id, continued.archive });
            const archived = try records.decode(@import("company_archive.zig").Record, manager.alloc, try manager.companyContent(archive_path), .{});
            try @import("company_archive.zig").validateStored(manager.alloc, archived, archive_path);
            if (!archived.complete or !std.mem.eql(u8, archived.task, selected.task.id) or !std.mem.eql(u8, archived.view, view_id) or !std.mem.eql(u8, archived.actor, selected.grant.actor) or !std.mem.eql(u8, archived.grant, selected.grant.id) or !std.mem.eql(u8, archived.source.revision, continued.source)) return error.CompanyArchiveRequired;
        }
    }
    if (request.change == .queue or request.change == .claim or request.change == .renew or request.change == .requeue) {
        try authority.authorizeExecution(manager, selected.task);
        try manager.validateTaskBasis(selected.task);
        if (!selected.live or !authority.permitsAction(selected.grant, .submit) or !authority.permitsAction(selected.grant, .status)) return error.CompanyAccessDenied;
        if (selected.task.state == .accepted or selected.task.state == .publication_pending) return error.TaskIsReadOnly;
        if (selected.task.review_job) |job_id| {
            const job = try manager.loadReviewJob(selected.task, job_id);
            if (job.state == .queued or job.state == .running) return error.TaskIsReadOnly;
        }
    }
    var live = selected.execution;
    var normalized = request;
    var files: std.ArrayList(workspace.Manager.CompanyFile) = .empty;
    const now = io.milliTimestamp();
    if (request.change == .claim or request.change == .renew) {
        const fence = request.execution orelse return error.CompanyExecutionFenceRequired;
        const runtime_ms = if (previous) |record| record.max_runtime_ms else return error.CompanyWorkerNotQueued;
        live = try ownership.change(live, if (request.change == .claim) .claim else .renew, fence, runtime_ms + 60000, now, selected.grant, view_id, selected.task.id, operation, request_hash);
        normalized.execution = .{ .runtime = live.?.runtime.?, .generation = live.?.generation };
    }
    var publication_verified = false;
    if (selected.task.state == .accepted) {
        // Acceptance is established by the verified canonical receipt. A local
        // answer-delivery journal may remain until its consumer acknowledges it.
        _ = try manager.publicationSummary(selected.task);
        publication_verified = true;
    }
    var transition_binding = selected.binding;
    if (request.change == .requeue or request.change == .cancel) if (previous) |retained| {
        if (!equalBinding(retained.binding, selected.binding)) {
            var comparable = selected.binding;
            comparable.contract_sha256 = retained.binding.contract_sha256;
            const planning = (try manager.planningJob(selected.task)) orelse return error.StaleCompanyWorkerContract;
            if (!equalBinding(retained.binding, comparable) or !std.mem.eql(u8, planning.planning_contract_sha256.?, retained.binding.contract_sha256)) return error.StaleCompanyWorkerContract;
            // Keep the old pin through an interrupted plan. Only planRecord
            // can adopt the strengthened contract after verified completion.
            transition_binding = retained.binding;
        }
    };
    var record = if (request.change == .plan)
        try planRecord(manager, previous orelse return error.CompanyWorkerNotQueued, request, selected, operation, request_hash)
    else
        try transition(previous, normalized, transition_binding, id, request_hash, live, now, publication_verified, selected.task.review_job != null);
    record.request = request;
    if (request.change == .finish or request.change == .cancel or request.change == .complete or request.change == .expire) {
        if (live) |current| if (record.runtime != null and current.runtime != null and record.generation == current.generation and std.mem.eql(u8, record.runtime.?, current.runtime.?)) {
            var released = current;
            released.runtime = null;
            released.expires_ms = 0;
            released.operation = operation;
            released.request_hash = request_hash;
            live = released;
        };
    }
    if (live) |current| {
        const raw = try encode(manager.alloc, current);
        const changed = if (selected.execution) |prior| !std.mem.eql(u8, raw, try encode(manager.alloc, prior)) else true;
        if (changed) {
            try files.append(manager.alloc, .{ .path = try ownership.path(manager.alloc, view_id), .content = raw });
            try files.append(manager.alloc, .{ .path = try manager.alloc.print("company/execution/{s}/{s}.json", .{ view_id, request_hash }), .content = raw });
        }
    }
    const raw = try encode(manager.alloc, record);
    try files.append(manager.alloc, .{ .path = record_path, .content = raw });
    try files.append(manager.alloc, .{ .path = operation_path, .content = raw });
    try files.append(manager.alloc, .{ .path = try manager.alloc.print("company/workers/history/{s}/{s}.json", .{ id, request_hash }), .content = raw });
    const committed = try manager.companyWrite(revision, files.items);
    return encode(manager.alloc, .{ .revision = committed, .jobs = .{try row(manager, record, raw, true)}, .next_offset = @as(?usize, null), .replayed = false });
}

test "company worker jobs retain pauses and require verified server outcomes" {
    const digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const binding: Binding = .{ .workspace = digest, .view = "view", .task = "task", .actor = "actor", .grant = "grant", .contract_sha256 = digest, .definition_sha256 = digest, .policy_sha256 = digest };
    const live: ownership.Record = .{ .view = "view", .task = "task", .actor = "actor", .grant = "grant", .runtime = "first", .generation = 1, .expires_ms = 50000, .operation = "lease", .request_hash = digest };
    const fence: ownership.Fence = .{ .runtime = "first", .generation = 1 };
    var job = try transition(null, .{ .change = .queue, .operation = "queue", .max_invocations = 2, .max_runtime_ms = 1000 }, binding, digest, digest, null, 100, false, false);
    try std.testing.expectEqual(State.queued, job.state);
    try std.testing.expectEqual(@as(u32, 0), job.invocations);
    job = try transition(job, .{ .change = .claim, .operation = "claim", .execution = fence }, binding, digest, digest, live, 101, false, false);
    try std.testing.expectEqual(State.running, job.state);
    try std.testing.expectEqual(@as(u32, 1), job.invocations);
    const finish: Request = .{ .change = .finish, .operation = "finish", .execution = fence, .outcome = .completed };
    try std.testing.expectError(error.WorkspaceVerificationFailed, transition(job, finish, binding, digest, digest, live, 102, false, false));
    try std.testing.expectError(error.CompanySubmissionRequired, transition(job, .{ .change = .finish, .operation = "submit", .execution = fence, .outcome = .submitted }, binding, digest, digest, live, 102, false, false));
    const completed = try transition(job, finish, binding, digest, digest, live, 102, true, true);
    try std.testing.expectEqual(State.completed, completed.state);
    job = try transition(job, .{ .change = .finish, .operation = "pause", .execution = fence, .outcome = .waiting }, binding, digest, digest, live, 102, false, false);
    try std.testing.expectEqual(State.waiting, job.state);
    try std.testing.expectError(error.CompanyExecutionBusy, transition(job, .{ .change = .requeue, .operation = "retry" }, binding, digest, digest, live, 103, false, false));
    var released = live;
    released.runtime = null;
    released.expires_ms = 0;
    var submitted = try transition(try transition(null, .{ .change = .queue, .operation = "submit-queue", .max_runtime_ms = 1000 }, binding, digest, digest, null, 100, false, false), .{ .change = .claim, .operation = "submit-claim", .execution = fence }, binding, digest, digest, live, 101, false, false);
    submitted = try transition(submitted, .{ .change = .finish, .operation = "submitted", .execution = fence, .outcome = .submitted }, binding, digest, digest, live, 102, false, true);
    try std.testing.expectEqual(State.submitted, submitted.state);
    try std.testing.expectEqual(State.queued, (try transition(submitted, .{ .change = .requeue, .operation = "revise" }, binding, digest, digest, released, 104, false, false)).state);
    job = try transition(job, .{ .change = .requeue, .operation = "retry" }, binding, digest, digest, released, 104, false, false);
    var successor = live;
    successor.runtime = "second";
    successor.generation = 2;
    const second: ownership.Fence = .{ .runtime = "second", .generation = 2 };
    job = try transition(job, .{ .change = .claim, .operation = "claim-second", .execution = second }, binding, digest, digest, successor, 105, false, false);
    try std.testing.expectError(error.CompanyExecutionFenced, transition(job, .{ .change = .finish, .operation = "stale", .execution = fence, .outcome = .waiting }, binding, digest, digest, successor, 106, false, false));
    job = try transition(job, .{ .change = .finish, .operation = "pause-second", .execution = second, .outcome = .waiting }, binding, digest, digest, successor, 106, false, false);
    try std.testing.expectEqual(State.exhausted, job.state);
    try std.testing.expectEqual(@as(u32, 2), job.invocations);
    var lost = job;
    lost.state = .running;
    lost.expires_ms = 200;
    try std.testing.expectError(error.CompanyWorkerNotExpired, transition(lost, .{ .change = .expire, .operation = "too-early" }, binding, digest, digest, null, 199, false, false));
    try std.testing.expectEqual(State.exhausted, (try transition(lost, .{ .change = .expire, .operation = "expired" }, binding, digest, digest, null, 201, false, false)).state);
    try std.testing.expectError(error.CompanyWorkerInvocationBudget, transition(job, .{ .change = .requeue, .operation = "over-budget" }, binding, digest, digest, released, 107, false, false));
}

test "company worker recovery requires a newer execution generation" {
    const digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const other = "1111111111111111111111111111111111111111111111111111111111111111";
    const binding: Binding = .{ .workspace = digest, .view = "view", .task = "task", .actor = "actor", .grant = "grant", .contract_sha256 = digest, .definition_sha256 = digest, .policy_sha256 = digest };
    var live: ownership.Record = .{ .view = "view", .task = "task", .actor = "actor", .grant = "grant", .runtime = "first", .generation = 1, .expires_ms = 10000, .operation = "lease", .request_hash = digest };
    var job = try transition(null, .{ .change = .queue, .operation = "queue", .max_runtime_ms = 1000 }, binding, digest, digest, null, 100, false, false);
    job = try transition(job, .{ .change = .claim, .operation = "claim", .execution = .{ .runtime = "first", .generation = 1 } }, binding, digest, digest, live, 101, false, false);
    const request: Request = .{ .change = .claim, .operation = "recover", .execution = .{ .runtime = "first", .generation = 1 } };
    live.expires_ms = 20000;
    try std.testing.expectError(error.CompanyExecutionFenced, transition(job, request, binding, digest, digest, live, 10001, false, false));
    live.runtime = "replacement";
    live.generation = 2;
    job = try transition(job, .{ .change = .claim, .operation = "recover", .execution = .{ .runtime = "replacement", .generation = 2 } }, binding, digest, digest, live, 10001, false, false);
    try std.testing.expectEqual(@as(u32, 2), job.invocations);
    try std.testing.expectEqualStrings("replacement", job.runtime.?);
    try std.testing.expectError(error.CompanyOperationConflict, transition(job, .{ .change = .claim, .operation = "recover" }, binding, digest, other, live, 10002, false, false));
    var changed = binding;
    changed.contract_sha256 = other;
    try std.testing.expectError(error.StaleCompanyWorkerContract, transition(job, .{ .change = .cancel, .operation = "cancel" }, changed, digest, digest, live, 10002, false, false));
    try std.testing.expectError(error.CompanyAccessDenied, transition(job, .{ .change = .cancel, .operation = "cancel", .view = "other" }, binding, digest, digest, live, 10002, false, false));
}

test "company worker checkpoint phases retain unfinished images across owners" {
    const digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const other = "1111111111111111111111111111111111111111111111111111111111111111";
    const binding: Binding = .{ .workspace = digest, .view = "view", .task = "task", .actor = "actor", .grant = "grant", .contract_sha256 = digest, .definition_sha256 = digest, .policy_sha256 = digest };
    var live: ownership.Record = .{ .view = "view", .task = "task", .actor = "actor", .grant = "grant", .runtime = "first", .generation = 1, .expires_ms = 50000, .operation = "lease", .request_hash = digest };
    const first: ownership.Fence = .{ .runtime = "first", .generation = 1 };
    var job = try transition(null, .{ .change = .queue, .operation = "queue", .max_runtime_ms = 1000 }, binding, digest, digest, null, 100, false, false);
    job = try transition(job, .{ .change = .claim, .operation = "claim", .execution = first }, binding, digest, digest, live, 101, false, false);
    var checkpoint: Checkpoint = .{ .runtime = "first", .generation = 1, .image = digest, .source_revision = digest, .model = "model", .phase = .prepared };
    job = try transition(job, .{ .change = .checkpoint, .operation = "prepared", .execution = first, .checkpoint = checkpoint }, binding, digest, digest, live, 102, false, false);
    checkpoint.phase = .stopped;
    checkpoint.export_directory = ".omos-host-archive-fixture";
    job = try transition(job, .{ .change = .checkpoint, .operation = "stopped", .execution = first, .checkpoint = checkpoint }, binding, digest, digest, live, 103, false, false);
    job = try transition(job, .{ .change = .finish, .operation = "pause", .execution = first, .outcome = .failed }, binding, digest, digest, live, 104, false, false);
    live.runtime = null;
    live.expires_ms = 0;
    job = try transition(job, .{ .change = .requeue, .operation = "requeue" }, binding, digest, digest, live, 105, false, false);
    live.runtime = "second";
    live.generation = 2;
    live.expires_ms = 50000;
    const second: ownership.Fence = .{ .runtime = "second", .generation = 2 };
    job = try transition(job, .{ .change = .claim, .operation = "second", .execution = second }, binding, digest, digest, live, 106, false, false);
    try std.testing.expectEqual(@as(u64, 1), job.checkpoint.?.generation);
    var replacement: Checkpoint = .{ .runtime = "second", .generation = 2, .image = other, .source_revision = other, .model = "model", .phase = .prepared };
    try std.testing.expectError(error.InvalidCompanyWorkerCheckpoint, transition(job, .{ .change = .checkpoint, .operation = "replace-unfinished", .execution = second, .checkpoint = replacement }, binding, digest, digest, live, 107, false, false));
    checkpoint.phase = .running;
    try std.testing.expectError(error.InvalidCompanyWorkerCheckpoint, transition(job, .{ .change = .checkpoint, .operation = "rewind", .execution = second, .checkpoint = checkpoint }, binding, digest, digest, live, 107, false, false));
    var continued = checkpoint;
    continued.continuation = .{ .invocation = 2, .archive = digest, .source = digest };
    continued.export_directory = null;
    const resumed = try transition(job, .{ .change = .checkpoint, .operation = "continue-native-session", .execution = second, .checkpoint = continued }, binding, digest, digest, live, 107, false, false);
    try std.testing.expectEqual(@as(u32, 2), resumed.checkpoint.?.continuation.?.invocation);
    try std.testing.expectEqualStrings(job.checkpoint.?.image, resumed.checkpoint.?.image);
    continued.phase = .stopped;
    const stopped_again = try transition(resumed, .{ .change = .checkpoint, .operation = "stop-continuation", .execution = second, .checkpoint = continued }, binding, digest, digest, live, 107, false, false);
    continued.phase = .running;
    try std.testing.expectError(error.InvalidCompanyWorkerCheckpoint, transition(stopped_again, .{ .change = .checkpoint, .operation = "repeat-invocation", .execution = second, .checkpoint = continued }, binding, digest, digest, live, 107, false, false));
    checkpoint.phase = .retained;
    job = try transition(job, .{ .change = .checkpoint, .operation = "retained", .execution = second, .checkpoint = checkpoint }, binding, digest, digest, live, 108, false, false);
    checkpoint.phase = .prepared;
    try std.testing.expectError(error.InvalidCompanyWorkerCheckpoint, transition(job, .{ .change = .checkpoint, .operation = "replay-image", .execution = second, .checkpoint = checkpoint }, binding, digest, digest, live, 109, false, false));
    replacement.export_directory = "../private";
    try std.testing.expectError(error.InvalidCompanyWorkerCheckpoint, transition(job, .{ .change = .checkpoint, .operation = "unsafe-directory", .execution = second, .checkpoint = replacement }, binding, digest, digest, live, 109, false, false));
    replacement.export_directory = null;
    job = try transition(job, .{ .change = .checkpoint, .operation = "replace-collected", .execution = second, .checkpoint = replacement }, binding, digest, digest, live, 109, false, false);
    try std.testing.expectEqualStrings(other, job.checkpoint.?.image);
    try std.testing.expectError(error.CompanyExecutionFenced, transition(job, .{ .change = .checkpoint, .operation = "stale", .execution = first, .checkpoint = replacement }, binding, digest, digest, live, 110, false, false));
    const completed = try transition(job, .{ .change = .complete, .operation = "publication-recovered" }, binding, digest, digest, live, 111, true, true);
    try std.testing.expectEqual(State.completed, completed.state);
    try std.testing.expectEqual(@TypeOf(completed.checkpoint.?.phase).retained, completed.checkpoint.?.phase);
}

test "company worker checkpoint extension preserves legacy request hashes" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, Request{ .change = .inspect });
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{\"change\":\"inspect\",\"operation\":null,\"view\":null,\"expected_sha256\":null,\"execution\":null,\"max_invocations\":null,\"max_runtime_ms\":null,\"outcome\":null,\"note\":null,\"offset\":0,\"limit\":32}", bytes);
}
