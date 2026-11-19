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

fn startAssignedTask(
    alloc: std.mem.Allocator,
    manager: workspace.Manager,
    session: []const u8,
    project: []const u8,
    goal: []const u8,
    parent: ?workspace.Task,
    capability_override: ?[]const u8,
    skills: []const @import("../skills/skill_contract.zig").Skill,
) !workspace.Task {
    const selection = @import("realisation_selection.zig");
    const assignment = selection.assignGoalForManager(
        alloc,
        manager,
        goal,
        capability_override,
        parent,
        project,
        skills,
    ) catch null;
    return manager.startWithAssignment(session, project, goal, parent, assignment);
}

pub const Turn = struct {
    manager: workspace.Manager,
    task: workspace.Task,
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

    fn startWithoutAssignment(
        manager: workspace.Manager,
        session: []const u8,
        project: []const u8,
        goal: []const u8,
        parent: ?workspace.Task,
    ) !workspace.Task {
        return manager.start(session, project, goal, parent);
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
        var task = if (try manager.active(session)) |active| active else try startAssignedTask(alloc, manager, session, project, prompt, parent, capability_override, skills);
        var turn: Turn = .{ .manager = manager, .task = task, .execution_lease = (try manager.tryTaskExecutionLease(task.id)) orelse return error.WorkspaceExecutionBusy };
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
                    task = try manager.start(session, project, prompt, parent);
                    try turn.selectTask(task);
                } else {
                    task = try manager.reopenUnpublished(task);
                }
            } else {
                turn.recovered_candidate = try manager.pendingCandidate(task);
                _ = (try manager.retryPublication(task)) orelse return error.WorkspaceRecoveryRequired;
                turn.task = try manager.loadTask(task.id);
                return turn;
            }
        }
        if (task.state == .conflict) return error.WorkspaceMergeConflict;
        if (task.state == .accepted) {
            task = try manager.start(session, project, prompt, parent);
            try turn.selectTask(task);
        }
        turn.task = try manager.setState(task.id, .active);
        if (continuing or std.ascii.eqlIgnoreCase(std.mem.trim(u8, prompt, " \t\r\n"), "continue")) turn.review_only_candidate = try manager.retainedReviewCandidate(turn.task);
        if (!continuing and parent_session == null and !std.mem.eql(u8, prompt, task.definition.objective)) {
            turn.task = try manager.amend(task, prompt);
        }
        try manager.record(turn.task, "user_request", .{ .text = prompt, .origin = if (parent_session == null) "user" else "delegation" });
        _ = try manager.checkpoint(turn.task);
        turn.recovery_context = try @import("execution_recovery.zig").context(manager, turn.task);
        turn.projection_pin = try @import("../shared/resource_pin.zig").acquire(try @import("filesystem_projection.zig").retentionPath(manager, turn.task), manager.operation_control);
        try @import("filesystem_projection.zig").prepare(manager, turn.task);
        turn.filesystem_view = true;
        if (turn.task.model_basis) |basis| if (basis.execution.projections != null) {
            turn.maintenance = @import("projection_maintenance.zig").Handle.start(manager) catch null;
        };
        return turn;
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
        if (coding) self.source_basis = if (self.task.authority != null)
            try @import("company_validation.zig").fingerprint(self.manager, self.task)
        else
            try @import("source_state.zig").fingerprint(alloc, self.task.project_root, self.manager.repository);
    }

    // Checkpoints and reviews share these retained-evidence traversal paths.
    pub noinline fn progress(self: *Turn, alloc: std.mem.Allocator, messages: []const types.ChatMessage) !void {
        const latest = try self.manager.loadTask(self.task.id);
        if (latest.definition.version != self.task.definition.version) self.invalidateAssessment();
        self.task = latest;
        if (self.filesystem_view) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer scratch.deinit();
            var projection_manager = self.manager;
            projection_manager.alloc = scratch.allocator();
            if (try @import("filesystem_projection.zig").checkpoint(projection_manager, self.task)) self.invalidateAssessment();
            try @import("filesystem_projection.zig").prepare(projection_manager, self.task);
        }
        const evidence = try review.collectToolEvidence(alloc, messages);
        const coding = if (self.task.model_basis) |basis| if (basis.capability) |id| std.mem.eql(u8, id, "coding_task") else false else false;
        const source = if (coding) if (self.task.authority != null) try @import("company_validation.zig").fingerprint(self.manager, self.task) else try @import("source_state.zig").fingerprint(alloc, self.task.project_root, self.manager.repository) else null;
        for (evidence) |original_record| {
            var record = original_record;
            if (self.invocation_id) |invocation| if (record.assistant_index) |index| if (record.raw_call_id) |id| {
                record.action_id = try actionIdentity(alloc, invocation, index, id);
                record.id = try alloc.print("execution:{s}:{s}", .{ record.action_id.?, record.id });
            };
            record.source = source;
            if (self.recorded_evidence.contains(record.id)) continue;
            try self.manager.record(self.task, "tool_evidence", &[_]review.Evidence{record});
            if (try @import("evidence_receipt.zig").derive(alloc, record)) |receipt| try self.manager.record(self.task, "command_receipt", receipt);
            if (source) |current| if (self.source_basis) |previous| {
                if (record.status == .success and record.tool != null and (std.mem.eql(u8, record.tool.?, "shell") or std.mem.eql(u8, record.tool.?, "shell_input")) and std.mem.eql(u8, current, previous)) {
                    try self.manager.record(self.task, "source_validation", .{ .evidence = record.id, .source = current });
                }
            };
            try self.recorded_evidence.put(alloc, record.id, {});
        }
        self.source_basis = source;
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
        _ = try self.manager.checkpoint(self.task);
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

    fn appendReviewEvidence(self: *Turn, alloc: std.mem.Allocator, rows: *std.ArrayList(review.Evidence), payloads: *std.ArrayList(@import("../agent/runtime/review_evidence.zig").PayloadRef), record: review.Evidence) !void {
        const detached = try @import("review_spool.zig").detach(alloc, self.manager.root, record);
        try rows.append(alloc, detached.record);
        if (detached.payload) |reference| try payloads.append(alloc, reference);
    }

    fn appendJournalEvidence(self: *Turn, alloc: std.mem.Allocator, rows: *std.ArrayList(JournalEvidence), payloads: *std.ArrayList(@import("../agent/runtime/review_evidence.zig").PayloadRef), record: review.Evidence, at_ms: i64, history_path: []const u8, within_row_index: usize) !void {
        const detached = try @import("review_spool.zig").detach(alloc, self.manager.root, record);
        try rows.append(alloc, .{ .record = detached.record, .recorded_at_ms = at_ms, .history_path = try alloc.dupe(u8, history_path), .within_row_index = within_row_index });
        if (detached.payload) |reference| try payloads.append(alloc, reference);
    }

    pub noinline fn beforeReview(self: *Turn, alloc: std.mem.Allocator, messages: []const types.ChatMessage) ![]const review.Evidence {
        try self.progress(alloc, messages);
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
                        try pages.append(alloc, try alloc.dupe(u8, data.string));
                        page_bytes += data.string.len;
                    };
                }
                if (std.mem.eql(u8, entry.kind, "review_segment_assessment") and entry.contract_version == self.task.definition.version) {
                    if (entry.value == .object) if (entry.value.object.get("data")) |data| if (data == .string) try checkpoints.append(alloc, try alloc.dupe(u8, data.string));
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
        if (!std.mem.eql(u8, previous, try self.manager.currentRevision(self.task))) return error.WorkspaceRevisionChanged;
        self.reviewed_revision = try self.manager.checkpoint(self.task);
        var snapshot = (try std.json.parseFromSlice(std.json.Value, self.manager.alloc, self.review_snapshot, .{})).value;
        try snapshot.object.put(self.manager.alloc, "reviewed_revision", .{ .string = self.reviewed_revision.? });
        self.review_snapshot = try std.json.Stringify.valueAlloc(self.manager.alloc, snapshot, .{});
    }

    pub fn sourceAssessmentCurrent(self: *Turn, bytes: []const u8) !bool {
        const basis = self.task.model_basis orelse return true;
        if (basis.capability == null or !std.mem.eql(u8, basis.capability.?, "coding_task")) return true;
        const alloc = self.manager.alloc;
        const current = if (self.task.authority != null) try @import("company_validation.zig").fingerprint(self.manager, self.task) else try @import("source_state.zig").fingerprint(alloc, self.task.project_root, self.manager.repository);
        const assessment = try record_json.decode(@import("../agent/runtime/work_contract.zig").Assessment, alloc, bytes, .{});
        var validations: std.StringHashMapUnmanaged(void) = .empty;
        var receipts: std.StringHashMapUnmanaged([]const u8) = .empty;
        var history = try self.manager.historyCursor(self.task, self.reviewed_revision.?);
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
        const current = try self.manager.loadTask(self.task.id);
        if (current.state == .active) self.task = try self.manager.setState(current.id, .paused);
        if (current.state != .accepted and current.state != .publication_pending) {
            if (self.filesystem_view) _ = try @import("filesystem_projection.zig").checkpoint(self.manager, current);
            _ = try self.manager.checkpoint(self.task);
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
