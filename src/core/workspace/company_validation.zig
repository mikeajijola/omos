//! Owner-observed checks against an immutable scoped company candidate. Actor
//! tools cannot write these receipts, and a receipt never accepts a task.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const ownership = @import("company_execution.zig");
const scope = @import("company_task_scope.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const io = @import("../shared/io.zig");
const Evidence = @import("../agent/runtime/review_evidence.zig").Evidence;

pub const Check = struct {
    id: []const u8,
    arguments: []const []const u8,
    cwd: []const u8,
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    output_complete: bool,
    source_unchanged: bool,
};
pub const Request = struct {
    version: []const u8,
    action: enum { prepare, candidate, record },
    view: []const u8,
    execution: ownership.Fence,
    revision: []const u8,
    operation: ?[]const u8 = null,
    source_sha256: ?[]const u8 = null,
    configuration_handle: ?[]const u8 = null,
    configuration_sha256: ?[]const u8 = null,
    environment_sha256: ?[]const u8 = null,
    checks: []const Check = &.{},
    offset: usize = 0,
    candidate: ?[]const u8 = null,

    pub fn jsonStringify(self: Request, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Request).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "candidate")) {
                if (self.candidate != null) {
                    try writer.objectField(name);
                    try writer.write(self.candidate);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
const File = struct { path: []const u8, artifact: []const u8, executable: bool };
const Source = struct { sha256: []const u8, files: []const File };
const Context = struct { task: workspace.Task, grant: authority.Grant };

fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

fn managedPath(path: []const u8) bool {
    for ([_][]const u8{ "memory/", "skills/", "documents/", "artifacts/", "ui/" }) |prefix| if (std.mem.startsWith(u8, path, prefix)) return true;
    return std.mem.startsWith(u8, path, "records/") and !std.mem.startsWith(u8, path, "records/omos_");
}

fn source(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, revision: []const u8) !Source {
    const effective = try scope.forTask(manager, task, grant);
    var files: std.ArrayList(File) = .empty;
    for (try manager.fileManifest(revision)) |file| {
        if (!managedPath(file.path) or !authority.permitsPath(effective, file.path)) continue;
        if (file.mode == .symlink or files.items.len == 10000) return error.CompanyValidationSourceTooLarge;
        try files.append(manager.alloc, .{ .path = file.path, .artifact = file.artifact orelse return error.WorkspaceVerificationFailed, .executable = file.mode == .executable });
    }
    return .{ .files = files.items, .sha256 = try workspace.hash(manager.alloc, try json(manager.alloc, .{ .version = "omos.company-source/v1", .workspace = manager.manifest.id, .task = task.id, .paths = effective.paths, .files = files.items })) };
}

fn currentGrant(manager: workspace.Manager, task: workspace.Task) !authority.Grant {
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const state = try records.decode(authority.State, manager.alloc, try manager.companyContent("authority/state.json"), .{});
    const grant = try authority.liveGrant(state, binding.grant, io.milliTimestamp());
    if (!std.mem.eql(u8, grant.actor, binding.actor)) return error.CompanyAccessDenied;
    return grant;
}

pub fn fingerprint(manager: workspace.Manager, task: workspace.Task) ![]const u8 {
    return (try source(manager, task, try currentGrant(manager, task), try manager.currentRevision(task))).sha256;
}

fn context(manager: workspace.Manager, request: Request) !Context {
    if (!authority.safeIdentity(request.view)) return error.InvalidCompanyIdentity;
    const View = struct { id: []const u8, task: []const u8, actor: []const u8, grant: []const u8 };
    const view = try records.decode(View, manager.alloc, try manager.companyContent(try manager.alloc.print("company/views/{s}.json", .{request.view})), .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, view.id, request.view)) return error.CompanyAccessDenied;
    const task = try manager.refreshTaskContext(try manager.loadTask(view.task));
    const grant = try currentGrant(manager, task);
    if (!std.mem.eql(u8, view.actor, grant.actor) or !std.mem.eql(u8, view.grant, grant.id)) return error.CompanyAccessDenied;
    try authority.authorizeExecution(manager, task);
    try manager.validateTaskBasis(task);
    if (task.state == .accepted or task.state == .publication_pending or task.revision_pending) return error.TaskIsReadOnly;
    if (task.review_job) |id| {
        const job = try manager.loadReviewJob(task, id);
        if (job.state == .queued or job.state == .running) return error.TaskReviewInProgress;
    }
    const live = try records.decode(ownership.Record, manager.alloc, try manager.companyContent(try ownership.path(manager.alloc, view.id)), .{});
    try ownership.validate(live, view.id, task.id, grant);
    try ownership.require(live, request.execution, io.milliTimestamp());
    return .{ .task = task, .grant = grant };
}

fn validateChecks(checks: []const Check) !bool {
    if (checks.len == 0 or checks.len > 16) return error.InvalidCompanyValidation;
    var passed = true;
    var total: usize = 0;
    for (checks, 0..) |check, index| {
        if (!authority.safeIdentity(check.id) or check.arguments.len == 0 or check.arguments.len > 64 or check.stdout.len > 8192 or check.stderr.len > 8192 or !authority.validPath(check.cwd, false)) return error.InvalidCompanyValidation;
        for (checks[0..index]) |previous| if (std.mem.eql(u8, previous.id, check.id)) return error.InvalidCompanyValidation;
        for (check.arguments) |argument| {
            if (argument.len > 8192 or std.mem.findScalar(u8, argument, 0) != null) return error.InvalidCompanyValidation;
            total += argument.len;
        }
        total += check.stdout.len + check.stderr.len;
        if (total > 128 * 1024) return error.InvalidCompanyValidation;
        passed = passed and check.exit_code == 0 and check.output_complete and check.source_unchanged;
    }
    return passed;
}

fn handle(task: workspace.Task) []const u8 {
    const basis = task.model_basis orelse return "company-default";
    return basis.execution.validationHandle();
}

/// The caller holds the local owner company lease. Signed actor operations
/// never dispatch this function or supply validation authority.
pub fn execute(manager: workspace.Manager, request: Request) ![]const u8 {
    if (!manager.company_operation_held) return error.CompanyOperationLeaseRequired;
    if (!std.mem.eql(u8, request.version, "omos.company-evaluation/v1")) return error.UnsupportedCompanyApi;
    if (request.action != .candidate and request.candidate != null) return error.InvalidCompanyValidation;
    const selected = try context(manager, request);
    const lease = (try manager.tryTaskExecutionLease(selected.task.id)) orelse return error.WorkspaceExecutionBusy;
    defer lease.release();
    const current = try manager.currentRevision(selected.task);
    const pinned = try source(manager, selected.task, selected.grant, current);
    if (request.action == .prepare) {
        if (request.operation != null or request.source_sha256 != null or request.configuration_handle != null or request.configuration_sha256 != null or request.environment_sha256 != null or request.checks.len != 0 or request.offset > pinned.files.len) return error.InvalidCompanyValidation;
        if (!std.mem.eql(u8, current, request.revision)) return error.WorkspaceRevisionChanged;
        const end = @min(pinned.files.len, request.offset + 32);
        return json(manager.alloc, .{ .version = "omos.company-validation-input/v1", .workspace = manager.manifest.id, .task = selected.task.id, .revision = current, .source_sha256 = pinned.sha256, .configuration_handle = handle(selected.task), .files = pinned.files[request.offset..end], .total = pinned.files.len, .next_offset = if (end < pinned.files.len) @as(?usize, end) else null });
    }
    const operation = request.operation orelse return error.InvalidCompanyValidation;
    if (!authority.safeIdentity(operation) or request.offset != 0) return error.InvalidCompanyValidation;
    const request_hash = try workspace.hash(manager.alloc, try json(manager.alloc, request));
    var history = try manager.historyCursor(selected.task, current);
    while (history.offset < history.paths.len) {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const batch = (try history.next(scratch.allocator())) orelse break;
        for (batch) |raw| {
            const row = try std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), raw, .{});
            const kind = model.text(row, "kind");
            if (!std.mem.eql(u8, kind, "company_candidate") and !std.mem.eql(u8, kind, "company_evaluation")) continue;
            const value = model.field(row, "value") orelse continue;
            if (!std.mem.eql(u8, model.text(value, "operation"), operation)) continue;
            if (!std.mem.eql(u8, model.text(value, "request_sha256"), request_hash)) return error.CompanyOperationConflict;
            if (request.action == .candidate) return json(manager.alloc, .{ .version = "omos.company-candidate-outcome/v1", .task = selected.task.id, .revision = current, .candidate_sha256 = model.text(value, "candidate_sha256"), .authority = "actor_claim", .replayed = true });
            return json(manager.alloc, .{ .version = "omos.company-evaluation-outcome/v1", .task = selected.task.id, .revision = current, .evidence = model.text(value, "evidence"), .passed = model.field(value, "passed") orelse return error.InvalidCompanyValidation, .replayed = true });
        }
    }
    if (!std.mem.eql(u8, current, request.revision)) return error.WorkspaceRevisionChanged;
    if (request.action == .candidate) {
        const candidate = request.candidate orelse return error.InvalidCompanyValidation;
        if (candidate.len == 0 or candidate.len > 32768 or std.mem.trim(u8, candidate, " \t\r\n").len == 0 or request.source_sha256 != null or request.configuration_handle != null or request.configuration_sha256 != null or request.environment_sha256 != null or request.checks.len != 0) return error.InvalidCompanyValidation;
        const candidate_hash = try workspace.hash(manager.alloc, candidate);
        try manager.record(selected.task, "review_candidate", .{ .at_ms = io.milliTimestamp(), .text = candidate, .authority = "actor_claim" });
        try manager.record(selected.task, "company_candidate", .{ .operation = operation, .request_sha256 = request_hash, .candidate_sha256 = candidate_hash, .source = pinned.sha256 });
        const retained = try manager.checkpoint(selected.task);
        return json(manager.alloc, .{ .version = "omos.company-candidate-outcome/v1", .task = selected.task.id, .revision = retained, .candidate_sha256 = candidate_hash, .authority = "actor_claim", .replayed = false });
    }
    if (!std.mem.eql(u8, request.source_sha256 orelse return error.InvalidCompanyValidation, pinned.sha256)) return error.WorkspaceRevisionChanged;
    if (!std.mem.eql(u8, request.configuration_handle orelse return error.InvalidCompanyValidation, handle(selected.task))) return error.CompanyValidationConfigurationChanged;
    _ = try authority.hexBytes(32, request.configuration_sha256 orelse return error.InvalidCompanyValidation);
    _ = try authority.hexBytes(32, request.environment_sha256 orelse return error.InvalidCompanyValidation);
    const passed = try validateChecks(request.checks);
    const receipt = try json(manager.alloc, .{ .version = "omos.company-validation/v1", .task = selected.task.id, .operation = operation, .source = pinned.sha256, .revision = request.revision, .execution = request.execution, .configuration_handle = request.configuration_handle, .configuration_sha256 = request.configuration_sha256, .environment_sha256 = request.environment_sha256, .checks = request.checks, .status = if (passed) "passed" else "failed", .authority = "company_host" });
    const id = try manager.alloc.print("company-validation:{s}", .{try workspace.hash(manager.alloc, receipt)});
    try manager.record(selected.task, "tool_evidence", &[_]Evidence{.{ .id = id, .kind = .verification, .tool = "company_validator", .status = if (passed) .success else .failure, .source = pinned.sha256, .action_id = operation, .content = receipt }});
    if (passed) try manager.record(selected.task, "source_validation", .{ .evidence = id, .source = pinned.sha256 });
    try manager.record(selected.task, "company_evaluation", .{ .operation = operation, .request_sha256 = request_hash, .evidence = id, .passed = passed });
    const retained_revision = try manager.checkpoint(selected.task);
    return json(manager.alloc, .{ .version = "omos.company-evaluation-outcome/v1", .task = selected.task.id, .revision = retained_revision, .evidence = id, .passed = passed, .replayed = false });
}

test "company validation requires complete unchanged checks and rejects duplicate or excessive results" {
    const check: Check = .{ .id = "syntax", .arguments = &.{ "/runtime/bin/python3", "-m", "py_compile", "main.py" }, .cwd = "documents/team", .exit_code = 0, .stdout = "", .stderr = "", .output_complete = true, .source_unchanged = true };
    try std.testing.expect(try validateChecks(&.{check}));
    var changed = check;
    changed.source_unchanged = false;
    try std.testing.expect(!try validateChecks(&.{changed}));
    changed = check;
    changed.output_complete = false;
    try std.testing.expect(!try validateChecks(&.{changed}));
    changed = check;
    changed.exit_code = 1;
    try std.testing.expect(!try validateChecks(&.{changed}));
    try std.testing.expectError(error.InvalidCompanyValidation, validateChecks(&.{}));
    try std.testing.expectError(error.InvalidCompanyValidation, validateChecks(&.{ check, check }));
}

test "company validation preserves previously retained request hashes when adding candidate checkpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const c: [64]u8 = @splat('c');
    const d: [64]u8 = @splat('d');
    const e: [64]u8 = @splat('e');
    const request: Request = .{ .version = "omos.company-evaluation/v1", .action = .record, .view = &a, .execution = .{ .runtime = "worker", .generation = 3 }, .revision = &b, .operation = "retained-check", .source_sha256 = &c, .configuration_handle = "company-default", .configuration_sha256 = &d, .environment_sha256 = &e, .checks = &.{.{ .id = "syntax", .arguments = &.{"/bin/true"}, .cwd = "ui", .exit_code = 0, .stdout = "", .stderr = "", .output_complete = true, .source_unchanged = true }} };
    const bytes = try json(arena.allocator(), request);
    // Golden digest of the original v1 wire format, before candidate support.
    try std.testing.expectEqualStrings("bcae201de9b76b7dc1aae670f190af07813e4e22b99dff8297f4810bc1add4e7", try workspace.hash(arena.allocator(), bytes));
}
