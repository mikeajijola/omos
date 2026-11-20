//! CLI-only adapter between the agent turn and the portable workspace.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const types = @import("../shared/types.zig");
const review = @import("../agent/runtime/completion_review.zig");
const record_json = @import("../shared/record_json.zig");

const JournalEvidence = struct {
    record: review.Evidence,
    recorded_at_ms: i64,
    history_path: []const u8,
    within_row_index: usize,

    fn oldestFirst(_: void, left: JournalEvidence, right: JournalEvidence) bool {
        if (left.recorded_at_ms != right.recorded_at_ms) return left.recorded_at_ms < right.recorded_at_ms;
        const paths = std.mem.order(u8, left.history_path, right.history_path);
        if (paths != .eq) return paths == .lt;
        return left.within_row_index < right.within_row_index;
    }
};

fn journalTimestamp(value: std.json.Value) i64 {
    return if (value == .integer) @max(0, value.integer) else 0;
}

pub const AssignedStart = struct {
    task: workspace.Task,
    recycled: bool = false,
};

pub fn startOrRecycleAssignedTask(
    alloc: std.mem.Allocator,
    manager: workspace.Manager,
    session: []const u8,
    project: []const u8,
    goal: []const u8,
    parent: ?workspace.Task,
    capability_override: ?[]const u8,
    skills: []const @import("../skills/skill_contract.zig").Skill,
    exclude_id: []const u8,
) !AssignedStart {
    const selection = @import("realisation_selection.zig");
    const admission = @import("contract_admission.zig");
    const assignment = selection.assignGoalForManager(
        alloc,
        manager,
        goal,
        capability_override,
        parent,
        project,
        skills,
    ) catch null;
    if (parent == null) {
        const recyclable = admission.findRecyclableContractWithAssignment(
            manager,
            exclude_id,
            goal,
            project,
            assignment,
        ) catch null;
        if (recyclable) |recyclable_id| {
            if (manager.resumeTask(session, recyclable_id, project)) |resumed| {
                return .{ .task = resumed, .recycled = true };
            } else |err| switch (err) {
                error.OutOfMemory, error.Cancelled => return err,
                else => {},
            }
        }
    }
    return .{
        .task = try manager.startWithAssignment(session, project, goal, parent, assignment),
        .recycled = false,
    };
}

pub const Turn = struct {
    manager: workspace.Manager,
    task: workspace.Task,
    recycled: bool = false,
    recovered_recipe: @import("execution_recovery.zig").SpecialistRecipe = .{},
    execution_guidance: @import("realisation_selection.zig").ExecutionGuidance = .{},
    reviewed_revision: ?[]const u8 = null,
    assessment: []const u8 = "",
    review_snapshot: []const u8 = "",
    recovery_context: []const u8 = "",
    recovered_candidate: ?[]const u8 = null,
    review_only_candidate: ?[]const u8 = null,
    source_basis: ?[]const u8 = null,
    prior_review_pages: []const []const u8 = &.{},
    prior_payloads: []const @import("../agent/runtime/review_evidence.zig").PayloadRef = &.{},
    prior_review_checkpoints: []const []const u8 = &.{},
    review_seen: std.StringHashMapUnmanaged(void) = .empty,
    review_progress_count: usize = 0,
    recorded_evidence: std.StringHashMapUnmanaged(void) = .empty,
    invocation_id: ?[]const u8 = null,
    assessment_record: ?[]const u8 = null,
    filesystem_view: bool = false,
    execution_lease: ?workspace.ExecutionLease = null,
    maintenance: ?@import("projection_maintenance.zig").Handle = null,
    projection_pin: ?@import("../shared/resource_pin.zig").Pin = null,
    canonical_outputs: @import("canonical_tool_outputs.zig").State = .{},

    pub fn begin(alloc: std.mem.Allocator, session: []const u8, parent_session: ?[]const u8, project: []const u8, prompt: []const u8) !?Turn {
        return beginResolved(alloc, session, parent_session, project, prompt, false);
    }

    pub fn beginResolved(alloc: std.mem.Allocator, session: []const u8, parent_session: ?[]const u8, project: []const u8, prompt: []const u8, continuing: bool) !?Turn {
        return beginResolvedWithContext(alloc, session, parent_session, project, prompt, continuing, null, &.{});
    }

    pub fn beginResolvedWithContext(
        alloc: std.mem.Allocator,
        session: []const u8,
        parent_session: ?[]const u8,
        project: []const u8,
        prompt: []const u8,
        continuing: bool,
        capability_override: ?[]const u8,
        skills: []const @import("../skills/skill_contract.zig").Skill,
    ) !?Turn {
        const manager = try workspace.Manager.ensureBound(alloc);
        const parent = if (parent_session) |id| try manager.active(id) else null;
        var recycled = false;
        var task = if (try manager.active(session)) |active| active else blk: {
            const started = try startOrRecycleAssignedTask(alloc, manager, session, project, prompt, parent, capability_override, skills, "");
            recycled = started.recycled;
            break :blk started.task;
        };
        var turn: Turn = .{
            .manager = manager,
            .task = task,
            .recycled = recycled,
            .execution_lease = (try manager.tryTaskExecutionLease(task.id)) orelse return error.WorkspaceExecutionBusy,
        };
        errdefer turn.release();
        task = try manager.refreshTaskContext(task);
        turn.task = task;
        if (task.authority != null) return error.CompanyExecutionIsolationRequired;
        if (!std.mem.eql(u8, project, task.project_root)) return error.TaskProjectMismatch;
        try manager.validateTaskBasis(task);
        var invocation: [16]u8 = undefined;
        @import("../shared/io.zig").getIo().random(&invocation);
        turn.invocation_id = try workspace.hash(alloc, &invocation);
        if (task.state == .publication_pending or (task.state == .accepted and try manager.publicationPending(task))) {
            const steering = !continuing and parent_session == null and !std.ascii.eqlIgnoreCase(std.mem.trim(u8, prompt, " \t\r\n"), "continue") and !std.mem.eql(u8, prompt, task.definition.objective);
            if (steering) {
                if (try manager.publicationCommitted(task)) {
                    _ = try manager.retryPublication(task);
                    try manager.acknowledge(task);
                    const started = try startOrRecycleAssignedTask(alloc, manager, session, project, prompt, parent, capability_override, skills, task.id);
                    task = started.task;
                    turn.recycled = started.recycled;
                    try turn.selectTask(task);
                } else {
                    task = try manager.reopenUnpublished(task);
                }
            } else {
                turn.recovered_candidate = try manager.pendingCandidate(task);
                _ = (try manager.retryPublication(task)) orelse return error.WorkspaceRecoveryRequired;
                turn.task = try manager.loadTask(task.id);
                try turn.refreshRecipe(alloc, &.{}, project, skills);
                return turn;
            }
        }
        if (task.state == .conflict) return error.WorkspaceMergeConflict;
        if (task.state == .accepted) {
            const started = try startOrRecycleAssignedTask(alloc, manager, session, project, prompt, parent, capability_override, skills, task.id);
            task = started.task;
            turn.recycled = started.recycled;
            try turn.selectTask(task);
        }
        turn.task = try manager.setState(task.id, .active);
        if (continuing or std.ascii.eqlIgnoreCase(std.mem.trim(u8, prompt, " \t\r\n"), "continue")) turn.review_only_candidate = try manager.retainedReviewCandidate(turn.task);
        if (!continuing and !turn.recycled and parent_session == null and !std.mem.eql(u8, prompt, task.definition.objective)) {
            turn.task = try manager.amend(task, prompt);
        }
        try turn.refreshRecipe(alloc, &.{}, project, skills);
        if (turn.recycled) {
            try manager.record(turn.task, "contract_recycled", .{
                .realisation_id = turn.recovered_recipe.realisation_id,
                .required_tools = turn.recovered_recipe.required_tools,
                .skill_bindings = turn.recovered_recipe.skill_bindings,
            });
        }
        try manager.record(turn.task, "user_request", .{ .text = prompt, .origin = if (parent_session == null) "user" else "delegation" });
        _ = try manager.checkpoint(turn.task);
        turn.recovery_context = try @import("execution_recovery.zig").context(manager, turn.task);
        turn.projection_pin = try @import("../shared/resource_pin.zig").acquire(try @import("filesystem_projection.zig").retentionPath(manager, turn.task), manager.operation_control);
        {
            var proj_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer proj_scratch.deinit();
            var projection_manager = manager;
            projection_manager.alloc = proj_scratch.allocator();
            try @import("filesystem_projection.zig").prepare(projection_manager, turn.task);
        }
        turn.filesystem_view = true;
        if (turn.task.model_basis) |basis| if (basis.execution.projections != null) {
            turn.maintenance = @import("projection_maintenance.zig").Handle.start(manager) catch null;
        };
        return turn;
    }

    pub fn refreshRecipe(
        self: *Turn,
        alloc: std.mem.Allocator,
        existing_bindings: []const @import("../skills/skill_invocation.zig").ExplicitBinding,
        workspace_root: []const u8,
        skills: []const @import("../skills/skill_contract.zig").Skill,
    ) !void {
        const recovery = @import("execution_recovery.zig");
        self.recovered_recipe = try recovery.recoverRecipe(alloc, self.manager, self.task);
        self.execution_guidance = try recovery.hydrateExecutionGuidance(
            alloc,
            self.manager,
            self.task,
            self.recovered_recipe,
            existing_bindings,
            workspace_root,
            skills,
        );
    }

    fn selectTask(self: *Turn, task: workspace.Task) !void {
        if (!std.mem.eql(u8, task.id, self.task.id)) {
            const lease = (try self.manager.tryTaskExecutionLease(task.id)) orelse return error.WorkspaceExecutionBusy;
            self.release();
            self.execution_lease = lease;
        }
        self.task = task;
    }

    pub fn canonicalSink(self: *Turn, session: []const u8) @import("../tooling/canonical_tool_output.zig").Sink {
        self.canonical_outputs.session = session;
        return .{ .context = self, .capture_fn = captureCanonicalOutput };
    }

    fn captureCanonicalOutput(context: *anyopaque, _: std.mem.Allocator, capture: @import("../tooling/canonical_tool_output.zig").Capture) !void {
        const self: *Turn = @ptrCast(@alignCast(context));
        try self.canonical_outputs.capture(self.manager, self.task, capture);
    }

    pub fn projectCanonicalMessages(self: *Turn, alloc: std.mem.Allocator, messages: []const types.ChatMessage, cap: usize) []const types.ChatMessage {
        return self.canonical_outputs.projectMessages(alloc, self.manager, self.task, messages, cap) catch |err| {
            @import("../shared/debug_trace.zig").logf("workspace", "canonical MCP actor view unavailable err={s}", .{@errorName(err)});
            return messages;
        };
    }

    pub fn release(self: *Turn) void {
        self.canonical_outputs.deinit();
        if (self.maintenance) |maintenance| maintenance.stop();
        self.maintenance = null;
        if (self.projection_pin) |pin| pin.close();
        self.projection_pin = null;
        if (self.execution_lease) |lease| lease.release();
        self.execution_lease = null;
    }

    /// Check execution prerequisites without assembling historical review pages.
    pub fn prepareExecution(self: *Turn, alloc: std.mem.Allocator) !void {
        const coding = if (self.task.model_basis) |basis| if (basis.capability) |id| std.mem.eql(u8, id, "coding_task") else false else false;
        if (coding) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var scratch_manager = self.manager;
            scratch_manager.alloc = scratch.allocator();
            const fp = if (self.task.authority != null)
                try @import("company_validation.zig").fingerprint(scratch_manager, self.task)
            else
                try @import("source_state.zig").fingerprint(scratch.allocator(), self.task.project_root, self.manager.repository);
            self.source_basis = try alloc.dupe(u8, fp);
        }
    }

    // Checkpoints and reviews share these retained-evidence traversal paths.
    pub noinline fn progress(self: *Turn, alloc: std.mem.Allocator, messages: []const types.ChatMessage) !void {
        const latest = try self.manager.loadTask(self.task.id);
        if (latest.definition.version != self.task.definition.version) self.invalidateAssessment();
        self.task = latest;
        if (self.filesystem_view) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var projection_manager = self.manager;
            projection_manager.alloc = scratch.allocator();
            if (try @import("filesystem_projection.zig").checkpoint(projection_manager, self.task)) self.invalidateAssessment();
            try @import("filesystem_projection.zig").prepare(projection_manager, self.task);
        }
        {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const s_alloc = scratch.allocator();
            var scratch_manager = self.manager;
            scratch_manager.alloc = s_alloc;
            const evidence = try review.collectToolEvidence(s_alloc, messages);
            const coding = if (self.task.model_basis) |basis| if (basis.capability) |id| std.mem.eql(u8, id, "coding_task") else false else false;
            const scratch_source = if (coding)
                if (self.task.authority != null)
                    try @import("company_validation.zig").fingerprint(scratch_manager, self.task)
                else
                    try @import("source_state.zig").fingerprint(s_alloc, self.task.project_root, self.manager.repository)
            else
                null;
            for (evidence) |original_record| {
                var record = original_record;
                if (self.invocation_id) |invocation| if (record.assistant_index) |index| if (record.raw_call_id) |id| {
                    record.action_id = try actionIdentity(s_alloc, invocation, index, id);
                    record.id = try s_alloc.print("execution:{s}:{s}", .{ record.action_id.?, record.id });
                };
                record.source = scratch_source;
                if (self.recorded_evidence.contains(record.id)) continue;
                try scratch_manager.record(self.task, "tool_evidence", &[_]review.Evidence{record});
                if (try @import("evidence_receipt.zig").derive(s_alloc, record)) |receipt| try scratch_manager.record(self.task, "command_receipt", receipt);
                if (scratch_source) |current| if (self.source_basis) |previous| {
                    if (record.status == .success and record.tool != null and (std.mem.eql(u8, record.tool.?, "shell") or std.mem.eql(u8, record.tool.?, "shell_input")) and std.mem.eql(u8, current, previous)) {
                        try scratch_manager.record(self.task, "source_validation", .{ .evidence = record.id, .source = current });
                    }
                };
                try self.recorded_evidence.put(alloc, try alloc.dupe(u8, record.id), {});
            }
            self.source_basis = if (scratch_source) |s|
                if (self.source_basis != null and std.mem.eql(u8, self.source_basis.?, s))
                    self.source_basis
                else
                    try alloc.dupe(u8, s)
            else
                null;
        }
        // User corrections are authenticated by the runtime's message origin.
        for (messages) |message| {
            if (message.role == .user and (message.context_origin == .user_turn or message.restored_steering)) {
                if (message.content) |content| {
                    const previous_version = self.task.definition.version;
                    self.task = try self.manager.amend(self.task, content);
                    if (self.task.definition.version != previous_version) self.invalidateAssessment();
                }
            }
        }
        var cp_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer cp_scratch.deinit();
        var cp_manager = self.manager;
        cp_manager.alloc = cp_scratch.allocator();
        _ = try cp_manager.checkpoint(self.task);
    }

    fn invalidateAssessment(self: *Turn) void {
        self.reviewed_revision = null;
        self.assessment = "";
        self.assessment_record = null;
        self.review_snapshot = "";
        self.review_only_candidate = null;
        self.prior_review_pages = &.{};
        self.prior_payloads = &.{};
        self.prior_review_checkpoints = &.{};
        self.review_seen = .empty;
        self.review_progress_count = 0;
    }

    /// The caller owns a turn arena. The bounded operation joins its worker
    /// before returning, including when collection times out or is cancelled.
    pub fn beforeReviewControlled(self: *Turn, alloc: std.mem.Allocator, messages: []const types.ChatMessage, cancel: *std.atomic.Value(bool), deadline: std.Io.Clock.Timestamp) ![]const review.Evidence {
        const Result = struct {
            records: []const review.Evidence,
            pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        };
        const Operation = struct {
            turn: *Turn,
            alloc: std.mem.Allocator,
            messages: []const types.ChatMessage,
            control: @import("../shared/bounded_operation.zig").Control,
            pub fn run(value: @This()) !Result {
                const previous = value.turn.manager.operation_control;
                value.turn.manager.operation_control = value.control;
                defer value.turn.manager.operation_control = previous;
                return .{ .records = try value.turn.beforeReview(value.alloc, value.messages) };
            }
        };
        const result = try @import("../shared/bounded_operation.zig").run(Result, alloc, cancel, deadline, Operation{ .turn = self, .alloc = alloc, .messages = messages, .control = .{ .cancel = cancel, .deadline = deadline } });
        return result.records;
    }

    fn dupePayloadRef(alloc: std.mem.Allocator, reference: @import("../agent/runtime/review_evidence.zig").PayloadRef) !@import("../agent/runtime/review_evidence.zig").PayloadRef {
        return .{
            .id = try alloc.dupe(u8, reference.id),
            .path = try alloc.dupe(u8, reference.path),
            .bytes = reference.bytes,
            .sha256 = try alloc.dupe(u8, reference.sha256),
            .identity_sha256 = if (reference.identity_sha256) |s| try alloc.dupe(u8, s) else null,
        };
    }

    fn appendReviewEvidence(self: *Turn, alloc: std.mem.Allocator, rows: *std.ArrayList(review.Evidence), payloads: *std.ArrayList(@import("../agent/runtime/review_evidence.zig").PayloadRef), record: review.Evidence) !void {
        const detached = try @import("review_spool.zig").detach(alloc, self.manager.root, record);
        try rows.append(alloc, detached.record);
        if (detached.payload) |reference| try payloads.append(self.manager.alloc, try dupePayloadRef(self.manager.alloc, reference));
    }

    fn appendJournalEvidence(self: *Turn, alloc: std.mem.Allocator, rows: *std.ArrayList(JournalEvidence), payloads: *std.ArrayList(@import("../agent/runtime/review_evidence.zig").PayloadRef), record: review.Evidence, at_ms: i64, history_path: []const u8, within_row_index: usize) !void {
        const detached = try @import("review_spool.zig").detach(alloc, self.manager.root, record);
        try rows.append(alloc, .{ .record = detached.record, .recorded_at_ms = at_ms, .history_path = try alloc.dupe(u8, history_path), .within_row_index = within_row_index });
        if (detached.payload) |reference| try payloads.append(self.manager.alloc, try dupePayloadRef(self.manager.alloc, reference));
    }

    pub noinline fn beforeReview(self: *Turn, alloc: std.mem.Allocator, messages: []const types.ChatMessage) ![]const review.Evidence {
        try self.progress(self.manager.alloc, messages);
        if (self.task.revision_pending) return error.TaskContractRevisionPending;
        self.reviewed_revision = try self.manager.checkpoint(self.task);
        var evidence: std.ArrayList(review.Evidence) = .empty;
        var tool_evidence_ids: std.StringHashMapUnmanaged(void) = .empty;
        var payloads: std.ArrayList(@import("../agent/runtime/review_evidence.zig").PayloadRef) = .empty;
        var pages: std.ArrayList([]const u8) = .empty;
        var page_bytes: usize = 0;
        var checkpoints: std.ArrayList([]const u8) = .empty;
        var current_validations: std.ArrayList([]const u8) = .empty;
        for (self.task.company_reads) |reference| {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var reader = self.manager;
            reader.alloc = scratch.allocator();
            const bytes = try reader.contentAt(reference.path, reference.revision);
            try self.appendReviewEvidence(alloc, &evidence, &payloads, .{ .id = try reader.alloc.print("workspace-read:{s}", .{try workspace.hash(reader.alloc, bytes)}), .kind = .verification, .status = .success, .content = bytes });
        }
        if (self.task.authority != null) {
            const prefix = try alloc.print("company/checkpoints/{s}/", .{self.task.id});
            for (try self.manager.inventory(self.reviewed_revision.?)) |path| {
                if (!std.mem.startsWith(u8, path, prefix)) continue;
                const name = std.Io.Dir.path.basename(path);
                if (name.len <= 5 or !std.mem.endsWith(u8, name, ".json")) return error.WorkspaceVerificationFailed;
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                var reader = self.manager;
                reader.alloc = scratch.allocator();
                _ = (try reader.companyCheckpointRevision(self.task, name[0 .. name.len - 5])) orelse return error.WorkspaceVerificationFailed;
                const bytes = try reader.contentAt(path, self.reviewed_revision.?);
                try self.appendReviewEvidence(alloc, &evidence, &payloads, .{ .id = try reader.alloc.print("workspace-checkpoint:{s}", .{try workspace.hash(reader.alloc, bytes)}), .kind = .verification, .status = .success, .content = bytes });
            }
        }
        if (self.task.capability_runtime_receipt != null) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var reader = self.manager;
            reader.alloc = scratch.allocator();
            if (try @import("capability_runtime.zig").reviewReceipt(reader, self.task, self.reviewed_revision.?)) |receipt| try self.appendReviewEvidence(alloc, &evidence, &payloads, .{ .id = try reader.alloc.print("capability-runtime:{s}", .{try workspace.hash(reader.alloc, receipt)}), .kind = .verification, .status = .success, .content = receipt });
        }
        var journal_evidence: std.ArrayList(JournalEvidence) = .empty;
        var history = try self.manager.historyCursor(self.task, self.reviewed_revision.?);
        while (history.offset < history.paths.len) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var reader = self.manager;
            reader.alloc = scratch.allocator();
            const a = reader.alloc;
            const start = history.offset;
            const batch = (try history.next(a)) orelse break;
            for (batch, 0..) |bytes, batch_index| {
                const history_path = history.paths[start + batch_index];
                const Entry = struct { kind: []const u8, task: []const u8, contract_version: u32, recorded_at_ms: std.json.Value = .null, value: std.json.Value };
                const entry = (try std.json.parseFromSlice(Entry, a, bytes, .{ .ignore_unknown_fields = true })).value;
                if (!std.mem.eql(u8, entry.task, self.task.id)) return error.InvalidWorkspaceJournal;
                const at_ms = journalTimestamp(entry.recorded_at_ms);
                if (std.mem.eql(u8, entry.kind, "canonical_tool_output")) {
                    const canonical = @import("../tooling/canonical_tool_output.zig");
                    const record = try std.json.parseFromValueLeaky(canonical.Record, a, entry.value, .{});
                    const companion = try @import("canonical_tool_outputs.zig").evidence(a, self.task.id, record);
                    if (tool_evidence_ids.contains(companion.id)) continue;
                    try self.appendJournalEvidence(alloc, &journal_evidence, &payloads, companion, at_ms, history_path, 0);
                    try tool_evidence_ids.put(alloc, try alloc.dupe(u8, companion.id), {});
                    continue;
                }
                if (self.source_basis) |source| {
                    const model = @import("definition.zig");
                    if (std.mem.eql(u8, entry.kind, "source_validation") and
                        entry.contract_version >= (self.task.source_validation_version orelse 1) and
                        std.mem.eql(u8, model.text(entry.value, "source"), source))
                    {
                        try current_validations.append(alloc, try alloc.dupe(u8, model.text(entry.value, "evidence")));
                    }
                }
                if (entry.contract_version == self.task.definition.version and (std.mem.eql(u8, entry.kind, "review_request") or std.mem.eql(u8, entry.kind, "review_evidence_page") or std.mem.eql(u8, entry.kind, "review_segment_assessment"))) {
                    if (entry.value == .object) if (entry.value.object.get("data")) |data| if (data == .string) try self.trackReview(entry.kind, data.string, false);
                }
                if (std.mem.eql(u8, entry.kind, "command_receipt") or std.mem.eql(u8, entry.kind, "ui_source_validation")) {
                    const content = try std.json.Stringify.valueAlloc(a, entry.value, .{});
                    try self.appendJournalEvidence(alloc, &journal_evidence, &payloads, .{
                        .id = try a.print("command-receipt:{s}", .{try workspace.hash(a, content)}),
                        .kind = .verification,
                        .content = content,
                        .status = if (std.mem.eql(u8, @import("definition.zig").text(entry.value, "outcome"), "failed") or std.mem.eql(u8, @import("definition.zig").text(entry.value, "status"), "failed")) .failure else if (std.mem.eql(u8, entry.kind, "ui_source_validation") and std.mem.eql(u8, @import("definition.zig").text(entry.value, "status"), "passed")) .success else null,
                        .action_id = @import("definition.zig").text(entry.value, "action_id"),
                        .source = @import("definition.zig").text(entry.value, "source"),
                    }, at_ms, history_path, 0);
                }
                if (std.mem.eql(u8, entry.kind, "review_evidence_page") and entry.contract_version == self.task.definition.version) {
                    if (entry.value == .object) if (entry.value.object.get("data")) |data| if (data == .string and data.string.len <= 256 * 1024 - page_bytes) {
                        // Raw replay is a bounded convenience window. Independent
                        // segment decisions below preserve progress beyond it.
                        try pages.append(self.manager.alloc, try self.manager.alloc.dupe(u8, data.string));
                        page_bytes += data.string.len;
                    };
                }
                if (std.mem.eql(u8, entry.kind, "review_segment_assessment") and entry.contract_version == self.task.definition.version) {
                    if (entry.value == .object) if (entry.value.object.get("data")) |data| if (data == .string) try checkpoints.append(self.manager.alloc, try self.manager.alloc.dupe(u8, data.string));
                }
                if (!std.mem.eql(u8, entry.kind, "tool_evidence")) continue;
                const records = (try std.json.parseFromValue([]review.Evidence, a, entry.value, .{})).value;
                for (records, 0..) |record, record_index| {
                    if (tool_evidence_ids.contains(record.id)) continue;
                    try self.appendJournalEvidence(alloc, &journal_evidence, &payloads, record, at_ms, history_path, record_index);
                    try tool_evidence_ids.put(alloc, try alloc.dupe(u8, record.id), {});
                }
            }
        }
        // History paths are content hashes, not chronological order. Keep the
        // persisted evidence unchanged while ordering this request's view by
        // host timestamp. Legacy or malformed timestamps sort at zero; path and
        // row position make ties deterministic. Reverse preload sees newest first.
        std.mem.sort(JournalEvidence, journal_evidence.items, {}, JournalEvidence.oldestFirst);
        for (journal_evidence.items) |item| try evidence.append(alloc, item.record);
        self.prior_review_pages = pages.items;
        self.prior_review_checkpoints = checkpoints.items;
        const inputs = try self.manager.reviewInputs(self.task, self.reviewed_revision.?);
        self.review_snapshot = inputs.snapshot;
        if (self.source_basis) |source| {
            const content = try std.json.Stringify.valueAlloc(alloc, .{ .source_hash = source, .current_validation_evidence = current_validations.items, .note = "For coding_validation, inspect and cite a listed current_validation_evidence ID (or its matching command receipt). These commands succeeded against unchanged current source bytes; independently assess whether their checks cover the request. An empty list means a check must run against the final source before completion. A successful command that changed source is not a current validation. This source-state record alone proves neither coverage nor completion." }, .{});
            try self.appendReviewEvidence(alloc, &evidence, &payloads, .{ .id = try alloc.print("source-state:{s}", .{try workspace.hash(alloc, content)}), .kind = .verification, .content = content });
        }
        try self.appendReviewEvidence(alloc, &evidence, &payloads, try review.workspaceEvidence(alloc, self.review_snapshot));
        for (inputs.files) |file| {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            var reader = self.manager;
            reader.alloc = scratch.allocator();
            const bytes = try reader.contentAt(file.path, self.reviewed_revision.?);
            if (!std.mem.eql(u8, file.hash, try workspace.hash(reader.alloc, bytes))) return error.WorkspaceVerificationFailed;
            const content = if (std.unicode.utf8ValidateSlice(bytes)) bytes else blk: {
                const buffer = try reader.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
                break :blk try std.json.Stringify.valueAlloc(reader.alloc, .{ .encoding = "base64", .bytes = bytes.len, .sha256 = file.hash, .content = std.base64.standard.Encoder.encode(buffer, bytes) }, .{});
            };
            try self.appendReviewEvidence(alloc, &evidence, &payloads, .{ .id = try reader.alloc.print("workspace-file:{s}:{s}", .{ file.hash, file.path }), .kind = .workspace, .content = content, .source = file.path });
        }
        self.prior_payloads = payloads.items;
        return evidence.toOwnedSlice(alloc);
    }

    pub fn journal(self: *Turn) review.Journal {
        return .{ .context = self, .record_fn = recordReview };
    }

    pub fn actionIdentity(alloc: std.mem.Allocator, invocation: []const u8, assistant_index: usize, call: []const u8) ![]const u8 {
        return alloc.print("{s}:{d}:{s}", .{ invocation, assistant_index, try workspace.hash(alloc, call) });
    }

    /// Only distinct delivered byte ranges or independent segment findings
    /// renew an attempt. This query performs no I/O after a deadline expires.
    pub fn reviewProgress(self: *Turn) ![]const u8 {
        return self.manager.alloc.print("{d}", .{self.review_progress_count});
    }

    fn inspectionKey(self: *Turn, scratch: std.mem.Allocator, id: []const u8, payload: []const u8, offset: usize, bytes: usize, segment: []const u8, advance: bool) !void {
        const raw = try std.json.Stringify.valueAlloc(scratch, .{ .id = id, .payload = payload, .offset = offset, .bytes = bytes, .segment = segment }, .{});
        const key = try workspace.hash(self.manager.alloc, raw);
        const slot = try self.review_seen.getOrPut(self.manager.alloc, key);
        if (!slot.found_existing and advance) self.review_progress_count += 1;
    }

    fn trackReview(self: *Turn, kind: []const u8, raw: []const u8, advance: bool) !void {
        const segment = std.mem.eql(u8, kind, "review_segment_assessment");
        const page = std.mem.eql(u8, kind, "review_evidence_page");
        const initial = std.mem.eql(u8, kind, "review_request");
        if (!segment and !page and !initial) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const model = @import("definition.zig");
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
        if (segment) {
            const key = try self.manager.alloc.print("assessment:{s}", .{try workspace.hash(a, raw)});
            const slot = try self.review_seen.getOrPut(self.manager.alloc, key);
            if (!slot.found_existing and advance) self.review_progress_count += 1;
            return;
        }
        const id = model.text(value, "id");
        const hash = model.text(value, "sha256");
        const content = model.text(value, "content");
        if (page and id.len > 0 and hash.len == 64 and content.len > 0) {
            if (model.field(value, "offset")) |offset| if (offset == .integer and offset.integer >= 0) try self.inspectionKey(a, id, hash, @intCast(offset.integer), content.len, try workspace.hash(a, content), advance);
        }
        for (model.items(value, "evidence")) |entry| {
            const complete = model.field(entry, "complete") orelse continue;
            const bytes = model.field(entry, "bytes") orelse continue;
            const entry_id = model.text(entry, "id");
            const entry_hash = model.text(entry, "sha256");
            if (complete != .bool or !complete.bool or bytes != .integer or bytes.integer < 0 or entry_id.len == 0 or entry_hash.len != 64) continue;
            // Inline complete records are delivered too. Initial packet records
            // seed deduplication without granting a retry for generated metadata.
            try self.inspectionKey(a, entry_id, entry_hash, 0, @intCast(bytes.integer), entry_hash, advance and !initial);
        }
    }

    fn recordReview(raw: *anyopaque, kind: []const u8, bytes: []const u8) !void {
        const self: *Turn = @ptrCast(@alignCast(raw));
        const id = try self.manager.recordReceipt(self.task, kind, .{ .at_ms = @import("../shared/io.zig").milliTimestamp(), .data = bytes });
        if (std.mem.eql(u8, kind, "review_assessment")) self.assessment_record = id;
        try self.trackReview(kind, bytes, true);
    }

    pub fn sealReview(self: *Turn) !void {
        // Only the host's audit journal may have advanced during assessment.
        // Fence actual branch edits before adding those audit records.
        const previous = self.reviewed_revision orelse return error.WorkspaceReviewRequired;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = self.manager;
        reader.alloc = scratch.allocator();
        if (!std.mem.eql(u8, previous, try reader.currentRevision(self.task))) return error.WorkspaceRevisionChanged;
        self.reviewed_revision = try self.manager.checkpoint(self.task);
        var snapshot = (try std.json.parseFromSlice(std.json.Value, reader.alloc, self.review_snapshot, .{})).value;
        try snapshot.object.put(reader.alloc, "reviewed_revision", .{ .string = self.reviewed_revision.? });
        const serialized = try std.json.Stringify.valueAlloc(reader.alloc, snapshot, .{});
        self.review_snapshot = try self.manager.alloc.dupe(u8, serialized);
    }

    pub fn sourceAssessmentCurrent(self: *Turn, bytes: []const u8) !bool {
        const basis = self.task.model_basis orelse return true;
        if (basis.capability == null or !std.mem.eql(u8, basis.capability.?, "coding_task")) return true;
        var outer_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer outer_scratch.deinit();
        const alloc = outer_scratch.allocator();
        var reader = self.manager;
        reader.alloc = alloc;
        const current = if (self.task.authority != null) try @import("company_validation.zig").fingerprint(reader, self.task) else try @import("source_state.zig").fingerprint(alloc, self.task.project_root, self.manager.repository);
        const assessment = try record_json.decode(@import("../agent/runtime/work_contract.zig").Assessment, alloc, bytes, .{});
        var validations: std.StringHashMapUnmanaged(void) = .empty;
        var receipts: std.StringHashMapUnmanaged([]const u8) = .empty;
        var history = try reader.historyCursor(self.task, self.reviewed_revision.?);
        while (history.offset < history.paths.len) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const batch = (try history.next(a)) orelse break;
            for (batch) |raw| {
                const row = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
                const model = @import("definition.zig");
                if (self.task.source_validation_version) |minimum| {
                    const version = model.field(row, "contract_version") orelse continue;
                    if (version != .integer or version.integer < minimum) continue;
                }
                const value = model.field(row, "value") orelse continue;
                if (std.mem.eql(u8, model.text(row, "kind"), "source_validation") and std.mem.eql(u8, model.text(value, "source"), current)) {
                    try validations.put(alloc, try alloc.dupe(u8, model.text(value, "evidence")), {});
                } else if (std.mem.eql(u8, model.text(row, "kind"), "command_receipt") and std.mem.eql(u8, model.text(value, "outcome"), "succeeded") and std.mem.eql(u8, model.text(value, "source"), current)) {
                    const content = try std.json.Stringify.valueAlloc(a, value, .{});
                    const reference = try alloc.print("command-receipt:{s}", .{try workspace.hash(a, content)});
                    try receipts.put(alloc, reference, try alloc.dupe(u8, model.text(value, "evidence_id")));
                }
            }
        }
        for (assessment.obligations) |obligation| {
            if (!std.mem.eql(u8, obligation.id, "coding_validation") or obligation.status != .met) continue;
            const supported = for (obligation.evidence) |id| {
                if (validations.contains(id)) break true;
                if (receipts.get(id)) |source| if (validations.contains(source)) break true;
            } else false;
            if (!supported) return false;
        }
        return true;
    }

    pub fn publish(self: *Turn, candidate: []const u8) !void {
        _ = try self.manager.publish(self.task, .{
            .task_id = self.task.id,
            .revision = self.reviewed_revision orelse return error.WorkspaceReviewRequired,
            .contract_version = self.task.definition.version,
            .disposition = "fulfilled",
            .candidate = candidate,
            .assessment = self.assessment,
            .workspace_snapshot = self.review_snapshot,
            .assessment_record = self.assessment_record,
        });
        self.task = try self.manager.loadTask(self.task.id);
    }

    pub fn retain(self: *Turn) !void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var worker = self.manager;
        worker.alloc = scratch.allocator();
        const current = try worker.loadTask(self.task.id);
        if (current.state == .active) self.task = try self.manager.setState(current.id, .paused);
        if (current.state != .accepted and current.state != .publication_pending) {
            if (self.filesystem_view) _ = try @import("filesystem_projection.zig").checkpoint(worker, current);
            _ = try worker.checkpoint(self.task);
        }
    }
};

test "managed review evidence uses timestamps rather than hashed history path order" {
    const record: review.Evidence = .{ .id = "same-record-shape", .kind = .tool, .status = .success, .content = "retained bytes" };
    var rows = [_]JournalEvidence{
        .{ .record = record, .recorded_at_ms = 30, .history_path = "history/task/aaa.json", .within_row_index = 0 },
        .{ .record = record, .recorded_at_ms = 10, .history_path = "history/task/zzz.json", .within_row_index = 0 },
        .{ .record = record, .recorded_at_ms = 20, .history_path = "history/task/bbb.json", .within_row_index = 1 },
        .{ .record = record, .recorded_at_ms = 20, .history_path = "history/task/bbb.json", .within_row_index = 0 },
        .{ .record = record, .recorded_at_ms = 20, .history_path = "history/task/aaa.json", .within_row_index = 0 },
        .{ .record = record, .recorded_at_ms = journalTimestamp(.null), .history_path = "history/task/legacy.json", .within_row_index = 0 },
    };
    std.mem.sort(JournalEvidence, &rows, {}, JournalEvidence.oldestFirst);
    try std.testing.expectEqual(@as(i64, 0), rows[0].recorded_at_ms);
    try std.testing.expectEqual(@as(i64, 10), rows[1].recorded_at_ms);
    try std.testing.expectEqualStrings("history/task/aaa.json", rows[2].history_path);
    try std.testing.expectEqual(@as(usize, 0), rows[3].within_row_index);
    try std.testing.expectEqual(@as(usize, 1), rows[4].within_row_index);
    try std.testing.expectEqual(@as(i64, 30), rows[5].recorded_at_ms);
    for (rows) |row| try std.testing.expectEqualDeep(record, row.record);
    try std.testing.expectEqual(@as(i64, 0), journalTimestamp(.{ .string = "30" }));
    try std.testing.expectEqual(@as(i64, 0), journalTimestamp(.{ .integer = -1 }));
}

test "managed chronological evidence preloads newest complete result within unchanged budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try alloc.alloc(u8, 1024);
    @memset(content, 'x');
    var rows = [_]JournalEvidence{
        .{ .record = .{ .id = "newest", .kind = .tool, .status = .success, .content = content }, .recorded_at_ms = 30, .history_path = "history/task/aaa.json", .within_row_index = 0 },
        .{ .record = .{ .id = "oldest", .kind = .tool, .status = .success, .content = content }, .recorded_at_ms = 10, .history_path = "history/task/zzz.json", .within_row_index = 0 },
    };
    std.mem.sort(JournalEvidence, &rows, {}, JournalEvidence.oldestFirst);
    const ordered = [_]review.Evidence{ rows[0].record, rows[1].record };
    var view = try @import("../agent/runtime/review_evidence.zig").View.init(alloc, &ordered);
    _ = try view.initialInspections(alloc, 1800);
    try view.requireInspected("newest");
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected("oldest"));
}

test "managed_task recycles matching specialist contract and hydrates recipe alongside recovery_context on reuse and resume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io_mod = @import("../shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    const repo_path = try std.Io.Dir.path.join(alloc, &.{ root, "repo.fossil" });
    const project_dir = try std.Io.Dir.path.join(alloc, &.{ root, "project" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), project_dir, .fromMode(0o700));

    const EnvFallback = struct {
        var empty: std.process.Environ.Map = .init(std.heap.page_allocator);
    };
    var environ = std.process.Environ.Map.init(alloc);
    try environ.put("HOME", root);
    io_mod.setEnvironMap(&environ);
    defer io_mod.setEnvironMap(&EnvFallback.empty);

    _ = try workspace.Manager.init(alloc, repo_path);

    const skill_contract = @import("../skills/skill_contract.zig");
    const skills = [_]skill_contract.Skill{
        .{
            .name = "browseros-neo",
            .description = "Dedicated agent browser",
            .path = "/Users/example/project/skills/browseros-neo",
            .source = .workspace_shared,
        },
    };

    // 1. Start first job_application turn, record tool evidence, and pause it.
    var first_turn = (try Turn.beginResolvedWithContext(
        alloc,
        "session-job-1",
        null,
        project_dir,
        "Apply to outside IR35 UK contract roles via LinkedIn Easy Apply",
        false,
        null,
        &skills,
    )).?;
    const original_task_id = try alloc.dupe(u8, first_turn.task.id);
    try std.testing.expect(!first_turn.recycled);
    try std.testing.expectEqualStrings("job_application_browser", first_turn.recovered_recipe.realisation_id.?);
    try std.testing.expectEqual(@as(usize, 4), first_turn.recovered_recipe.required_tools.len);
    try std.testing.expectEqualStrings("shell", first_turn.recovered_recipe.required_tools[0]);
    try std.testing.expectEqualStrings("read_file", first_turn.recovered_recipe.required_tools[1]);
    try std.testing.expectEqualStrings("write_file", first_turn.recovered_recipe.required_tools[2]);
    try std.testing.expectEqualStrings("mcp_browseros-neo_run", first_turn.recovered_recipe.required_tools[3]);
    try std.testing.expectEqual(@as(usize, 1), first_turn.recovered_recipe.skill_bindings.len);
    try std.testing.expectEqualStrings("browseros-neo", first_turn.recovered_recipe.skill_bindings[0]);
    try std.testing.expectEqual(@as(usize, 1), first_turn.execution_guidance.resolved_skills.len);
    try std.testing.expect(std.mem.find(u8, first_turn.execution_guidance.text, "realisation=\"job_application_browser\"") != null);

    try first_turn.manager.record(first_turn.task, "tool_evidence", &[_]review.Evidence{
        .{
            .id = "ev-1",
            .action_id = "act-1",
            .kind = .tool,
            .tool = "mcp_browseros-neo_run",
            .status = .success,
            .arguments = "{\"script\":\"return 1\"}",
            .content = "Submitted first batch receipt-001",
        },
    });
    try first_turn.retain();
    first_turn.release();

    // 2. Resume existing session with "continue": both recovery_context AND specialist recipe hydrate!
    var resumed_turn = (try Turn.beginResolvedWithContext(
        alloc,
        "session-job-1",
        null,
        project_dir,
        "continue",
        true,
        null,
        &skills,
    )).?;
    try std.testing.expectEqualStrings(original_task_id, resumed_turn.task.id);
    try std.testing.expect(std.mem.find(u8, resumed_turn.recovery_context, "Retained execution summary") != null);
    try std.testing.expect(std.mem.find(u8, resumed_turn.recovery_context, "receipt-001") != null);
    try std.testing.expectEqualStrings("job_application_browser", resumed_turn.recovered_recipe.realisation_id.?);
    try std.testing.expectEqual(@as(usize, 4), resumed_turn.recovered_recipe.required_tools.len);
    try std.testing.expectEqualStrings("mcp_browseros-neo_run", resumed_turn.recovered_recipe.required_tools[3]);
    try std.testing.expectEqualStrings("browseros-neo", resumed_turn.recovered_recipe.skill_bindings[0]);
    try std.testing.expectEqual(@as(usize, 1), resumed_turn.execution_guidance.resolved_skills.len);
    try std.testing.expect(std.mem.find(u8, resumed_turn.execution_guidance.text, "mcp_browseros-neo_run") != null);
    try resumed_turn.retain();
    resumed_turn.release();

    // 3. Second matching job_application request in a new session recycles the specialist contract!
    var recycled_turn = (try Turn.beginResolvedWithContext(
        alloc,
        "session-job-2",
        null,
        project_dir,
        "Submit job applications for outside IR35 roles on LinkedIn and save receipts",
        false,
        null,
        &skills,
    )).?;
    try std.testing.expect(recycled_turn.recycled);
    try std.testing.expectEqualStrings(original_task_id, recycled_turn.task.id);
    try std.testing.expect(std.mem.find(u8, recycled_turn.recovery_context, "Retained execution summary") != null);
    try std.testing.expectEqualStrings("job_application_browser", recycled_turn.recovered_recipe.realisation_id.?);
    try std.testing.expectEqual(@as(usize, 4), recycled_turn.recovered_recipe.required_tools.len);
    try std.testing.expectEqualStrings("shell", recycled_turn.recovered_recipe.required_tools[0]);
    try std.testing.expectEqualStrings("mcp_browseros-neo_run", recycled_turn.recovered_recipe.required_tools[3]);
    try std.testing.expectEqualStrings("browseros-neo", recycled_turn.recovered_recipe.skill_bindings[0]);
    try std.testing.expectEqual(@as(usize, 1), recycled_turn.execution_guidance.resolved_skills.len);
    try recycled_turn.retain();
    recycled_turn.release();

    // 4. Mismatched coding_task request in the same project is NEVER cross-recycled.
    var coding_turn = (try Turn.beginResolvedWithContext(
        alloc,
        "session-coding-1",
        null,
        project_dir,
        "Refactor src/main.zig and run zig build test",
        false,
        null,
        &skills,
    )).?;
    defer {
        coding_turn.retain() catch {};
        coding_turn.release();
    }
    try std.testing.expect(!coding_turn.recycled);
    try std.testing.expect(!std.mem.eql(u8, original_task_id, coding_turn.task.id));
    try std.testing.expectEqualStrings("coding_task_native", coding_turn.recovered_recipe.realisation_id.?);
    try std.testing.expectEqual(@as(usize, 0), coding_turn.recovered_recipe.required_tools.len);
}

test "managed_task and fossil tools release per-call scratch memory across repeated steps" {
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const setup_alloc = setup_arena.allocator();

    const io_mod = @import("../shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(setup_alloc, tmp.dir, ".");
    const repo_path = try std.Io.Dir.path.join(setup_alloc, &.{ root, "repo.fossil" });
    const project_dir = try std.Io.Dir.path.join(setup_alloc, &.{ root, "project" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io_mod.getIo(), project_dir, .fromMode(0o700));

    const EnvFallback = struct {
        var empty: std.process.Environ.Map = .init(std.heap.page_allocator);
    };
    var environ = std.process.Environ.Map.init(setup_alloc);
    try environ.put("HOME", root);
    if (io_mod.getenv("PATH")) |p| try environ.put("PATH", p);
    io_mod.setEnvironMap(&environ);
    defer io_mod.setEnvironMap(&EnvFallback.empty);

    const seed_manager = try workspace.Manager.init(setup_alloc, repo_path);
    try seed_manager.use();

    // Seed a large memory file and advance trunk across several delta commits so
    // manifest and file reads exercise delta reconstruction without leaking into
    // the caller's turn arena.
    {
        var seed_turn = (try Turn.beginResolvedWithContext(
            setup_alloc,
            "seed-session",
            null,
            project_dir,
            "Seed workspace memory",
            false,
            null,
            &.{},
        )).?;
        defer seed_turn.release();
        const large_note = try setup_alloc.alloc(u8, 2048);
        @memset(large_note, 'm');
        try seed_turn.manager.writeContent(seed_turn.task, "memory/guide.md", large_note);
        _ = try seed_turn.beforeReview(setup_alloc, &.{});
        const seed_assessment = try std.json.Stringify.valueAlloc(setup_alloc, .{
            .version = @as(u32, 1),
            .contractId = seed_turn.task.id,
            .obligations = &[_]struct { id: []const u8, status: []const u8, note: []const u8, evidence: []const []const u8 }{.{
                .id = "request_complete",
                .status = "met",
                .note = "Seeded",
                .evidence = &.{"seed"},
            }},
        }, .{});
        try seed_turn.journal().record("review_assessment", seed_assessment);
        try seed_turn.sealReview();
        seed_turn.assessment = seed_assessment;
        try seed_turn.publish("Seeded workspace memory");
        try seed_turn.manager.acknowledge(seed_turn.task);
    }

    var turn_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer turn_arena.deinit();
    const arena = turn_arena.allocator();

    var turn = (try Turn.beginResolvedWithContext(
        arena,
        "bounded-turn-session",
        null,
        project_dir,
        "Inspect workspace capabilities across repeated steps",
        false,
        null,
        &.{},
    )).?;
    defer {
        turn.retain() catch {};
        turn.release();
    }

    const fw_tool = @import("../../tools/session/fossil_workspace.zig");
    const wc_tool = @import("../../tools/session/workspace_content.zig");
    const tool_dispatch = @import("../tooling/tool_dispatch.zig");

    var messages: std.ArrayList(types.ChatMessage) = .empty;
    const fw_calls = [_][]const u8{
        "{\"action\":\"status\"}",
        "{\"action\":\"query\",\"entity\":\"omos_capability\"}",
        "{\"action\":\"history\"}",
        "{\"action\":\"definition\"}",
        "{\"action\":\"read\",\"path\":\"memory/guide.md\"}",
    };
    const wc_calls = [_][]const u8{
        "{\"action\":\"catalog\"}",
        "{\"action\":\"conversations\"}",
        "{\"action\":\"contracts\",\"contracts\":{\"action\":\"list\"}}",
        "{\"action\":\"attention\"}",
        "{\"action\":\"background\",\"background\":{\"action\":\"list\"}}",
    };

    const cap_after_begin = turn_arena.queryCapacity();
    for (0..15) |step| {
        const ctx: tool_dispatch.DispatchContext = .{
            .allocator = arena,
            .fossil_workspace_available = true,
            .fossil_session_id = "bounded-turn-session",
            .workspace_root = project_dir,
            .tool_call_id = try arena.print("fw-{d}", .{step}),
        };

        const fw_args = fw_calls[step % fw_calls.len];
        const fw_dec = try fw_tool.decode(ctx, fw_args);
        switch (fw_dec) {
            .input => |inp| {
                defer inp.deinit(ctx.allocator);
                const res = try fw_tool.call(ctx, inp);
                const body = switch (res) {
                    .success => |s| s,
                    .failure => |f| f,
                    .rich => |r| r.text,
                };
                try messages.append(arena, .{
                    .role = .assistant,
                    .tool_calls = try arena.dupe(types.ToolCall, &.{.{ .id = ctx.tool_call_id, .name = "fossil_workspace", .arguments_json = fw_args }}),
                });
                try messages.append(arena, .{
                    .role = .tool,
                    .tool_call_id = ctx.tool_call_id,
                    .tool_name = "fossil_workspace",
                    .content = body[0..@min(body.len, 512)],
                    .tool_result_status = .success,
                });
            },
            .failure => return error.TestUnexpectedResult,
        }

        const wc_args = wc_calls[step % wc_calls.len];
        const wc_dec = try wc_tool.decode(ctx, wc_args);
        switch (wc_dec) {
            .input => |inp| {
                defer inp.deinit(ctx.allocator);
                const res = try wc_tool.call(ctx, inp);
                const body = switch (res) {
                    .success => |s| s,
                    .failure => |f| f,
                    .rich => |r| r.text,
                };
                const wc_id = try arena.print("wc-{d}", .{step});
                try messages.append(arena, .{
                    .role = .assistant,
                    .tool_calls = try arena.dupe(types.ToolCall, &.{.{ .id = wc_id, .name = "workspace_content", .arguments_json = wc_args }}),
                });
                try messages.append(arena, .{
                    .role = .tool,
                    .tool_call_id = wc_id,
                    .tool_name = "workspace_content",
                    .content = body[0..@min(body.len, 512)],
                    .tool_result_status = .success,
                });
            },
            .failure => return error.TestUnexpectedResult,
        }

        try turn.progress(arena, messages.items);
        var overlay_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer overlay_arena.deinit();
        var overlay_manager = turn.manager;
        overlay_manager.alloc = overlay_arena.allocator();
        _ = try overlay_manager.context(turn.task);
    }

    var review_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer review_arena.deinit();
    _ = try turn.beforeReview(review_arena.allocator(), messages.items);

    const assessment_json = try std.json.Stringify.valueAlloc(arena, .{
        .version = @as(u32, 1),
        .contractId = turn.task.id,
        .obligations = &[_]struct { id: []const u8, status: []const u8, note: []const u8, evidence: []const []const u8 }{.{
            .id = "request_complete",
            .status = "met",
            .note = "Verified",
            .evidence = &.{"verified"},
        }},
    }, .{});
    try turn.journal().record("review_assessment", assessment_json);
    try turn.sealReview();
    turn.assessment = assessment_json;
    try turn.publish("Completed bounded workspace inspection");

    const final_cap = turn_arena.queryCapacity();
    // 15 steps of tool results + small retained IDs must stay well under 2 MiB in the turn arena.
    try std.testing.expect(cap_after_begin < 512 * 1024);
    try std.testing.expect(final_cap < 2 * 1024 * 1024);
}
