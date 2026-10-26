//! Versioned service operations shared by local and HTTP hosts. The transport
//! selects the workspace; request bodies can never select a repository path.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const model = @import("definition.zig");
const records = @import("../shared/record_json.zig");

/// Scheduling is an additive transport, independent of a task's pinned
/// OmniForm declaration. It grants no authority to execute actor tools.
pub fn executeSchedule(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 16384) return error.ServiceRequestTooLarge;
    const Envelope = struct {
        version: []const u8,
        workspace: []const u8,
        action: @FieldType(@import("scheduling.zig").Request, "action") = .list,
        task: ?[]const u8 = null,
        id: ?[]const u8 = null,
        at: ?[]const u8 = null,
        from: ?[]const u8 = null,
        to: ?[]const u8 = null,
        revision: ?[]const u8 = null,
    };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.schedule/v1")) return error.UnsupportedScheduleApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    const mutation = envelope.action == .add or envelope.action == .move or envelope.action == .cancel;
    if (mutation and !writable) return error.ServiceReadOnly;
    if (mutation and envelope.revision == null) return error.WorkspaceRevisionRequired;
    return std.json.Stringify.valueAlloc(manager.alloc, try manager.scheduleSnapshot(.{
        .action = envelope.action,
        .task = envelope.task,
        .id = envelope.id,
        .at = envelope.at,
        .from = envelope.from,
        .to = envelope.to,
        .revision = envelope.revision,
    }), .{});
}

/// Owner transport for native worker control. Scoped actors cannot enter this
/// route, and the canonical admin operation still validates every transition.
pub fn executeWorkers(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 65536) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_worker_jobs.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-worker-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (envelope.request.change != .inspect and !writable) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const request = parsed.object.get("request") orelse return error.InvalidCompanyWorkerJob;
    const response = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "workers", .worker = request }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, response) }, .{});
}

pub fn executeControls(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 65536) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_control.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-input-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (envelope.request.action != .inspect and !writable) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const output = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "controls", .controls = parsed.object.get("request").? }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, output) }, .{});
}

pub fn executeActivity(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 256 * 1024) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_activity.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-activity-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (envelope.request.action != .inspect and !writable) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const output = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "activity", .activity = parsed.object.get("request").? }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, output) }, .{});
}

pub fn executeDesired(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 65536) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_desired.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-desired-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (envelope.request.change != .inspect and !writable) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const output = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "desired", .desired = parsed.object.get("request").? }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, output) }, .{});
}

pub fn executeEvaluation(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 256 * 1024) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_validation.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-evaluation-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (envelope.request.action != .prepare and !writable) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const response = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "evaluate", .evaluation = parsed.object.get("request").? }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, response) }, .{});
}

pub fn executeArchives(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 256 * 1024) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_archive.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-archive-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (!writable and envelope.request.action != .inspect) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const output = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "archive", .archive = parsed.object.get("request").? }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, output) }, .{});
}

pub fn executeRuntimes(manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    if (raw.len > 65536) return error.ServiceRequestTooLarge;
    const Envelope = struct { version: []const u8, workspace: []const u8, request: @import("company_runtime.zig").Request };
    const envelope = try records.decode(Envelope, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, envelope.version, "omos.company-runtime-api/v1")) return error.UnsupportedCompanyApi;
    if (!std.mem.eql(u8, envelope.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    if (envelope.request.change != .inspect and !writable) return error.ServiceReadOnly;
    const parsed = try parse(manager.alloc, raw);
    const output = try @import("company_service.zig").administer(manager, try std.json.Stringify.valueAlloc(manager.alloc, .{ .version = "omos.company-admin/v1", .action = "runtimes", .runtime = parsed.object.get("request").? }, .{}));
    return std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .data = try parse(manager.alloc, output) }, .{});
}

pub const Request = struct {
    version: []const u8,
    workspace: []const u8,
    definition_hash: []const u8,
    revision: []const u8 = "",
    action: enum { head, candidate, definition, query, read, inventory, record, propose, audit, queue_review, job },
    task: ?[]const u8 = null,
    entity: ?[]const u8 = null,
    content: ?[]const u8 = null,
    path: ?[]const u8 = null,
    offset: usize = 0,
    job: ?[]const u8 = null,
    limit: usize = 16384,
};

pub fn execute(original_manager: workspace.Manager, raw: []const u8, writable: bool) ![]const u8 {
    var manager = original_manager;
    if (raw.len > 1024 * 1024) return error.ServiceRequestTooLarge;
    const alloc = manager.alloc;
    const request = try records.decode(Request, alloc, raw, .{});
    if (!std.mem.eql(u8, request.version, "omos.workspace-api/v1")) return error.UnsupportedWorkspaceApi;
    if (!std.mem.eql(u8, request.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    const task: ?workspace.Task = if (request.task) |id| try manager.loadTask(id) else null;
    if (request.action == .candidate and task == null) return error.TaskIdRequired;
    if (task) |selected| if (!std.mem.eql(u8, selected.workspace_id, request.workspace)) return error.WorkspaceIdentityMismatch;
    const revision = if (task) |selected| try manager.currentRevision(selected) else try manager.revision("trunk");
    if (request.action != .head and request.action != .job and request.action != .read and request.action != .inventory and !std.mem.eql(u8, request.revision, revision)) return error.WorkspaceRevisionChanged;
    if (request.action == .read or request.action == .inventory) {
        const manifest = try records.decode(workspace.Manifest, alloc, try manager.contentAt("workspace.json", request.revision), .{});
        if (!std.mem.eql(u8, manifest.id, request.workspace)) return error.WorkspaceIdentityMismatch;
    }
    const transport_basis = (try manager.modelBasis(try manager.revision("trunk"))) orelse return error.WorkspaceMigrationRequired;
    const basis = (if (request.action == .head) transport_basis else if (task) |selected| selected.model_basis else transport_basis) orelse transport_basis;
    if (!std.mem.eql(u8, request.definition_hash, basis.definition_hash)) return error.StaleWorkspaceDefinition;
    // Workspace API contracts govern transport. A task keeps its own older
    // declaration and policy for record writes and independent assessment.
    const declaration = try manager.loadDeclaration(transport_basis.revision);
    const operation = switch (request.action) {
        .head => "omos_workspace_head",
        .candidate => "omos_workspace_candidate",
        .inventory => "omos_workspace_inventory",
        else => "omos_workspace_request",
    };
    try model.validateOperation(alloc, declaration, operation, (try std.json.parseFromSlice(std.json.Value, alloc, raw, .{})).value, .input);
    manager.expected_revision = request.revision;
    const data: std.json.Value = switch (request.action) {
        .head => try parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .revision = revision, .task = if (task) |selected| @as(?[]const u8, selected.id) else null, .definition_hash = if (task) |selected| (selected.model_basis orelse return error.WorkspaceMigrationRequired).definition_hash else transport_basis.definition_hash }, .{})),
        .candidate => blk: {
            const selected = task orelse return error.TaskIdRequired;
            const text = try manager.candidateAnswerAt(selected, revision);
            if (text) |value| if (value.len > 32768) return error.ReviewCandidateTooLarge;
            break :blk try parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .task = selected.id, .candidate = text, .authority = "actor_claim" }, .{}));
        },
        .definition => try manager.definitionSnapshot(task),
        .query => try parse(alloc, try manager.queryRecords(task, request.entity, request.offset)),
        .audit => try parse(alloc, try manager.auditContracts()),
        .queue_review => blk: {
            if (!writable) return error.ServiceReadOnly;
            const job = try manager.queueReview(task orelse return error.TaskIdRequired);
            break :blk try parse(alloc, try std.json.Stringify.valueAlloc(alloc, job, .{}));
        },
        .job => blk: {
            const job = try manager.loadReviewJob(task orelse return error.TaskIdRequired, request.job orelse return error.InvalidReviewJob);
            break :blk try parse(alloc, try std.json.Stringify.valueAlloc(alloc, job, .{}));
        },
        .inventory => blk: {
            if (!@import("fossil_manifest.zig").validHash(request.revision)) return error.InvalidFossilRevision;
            const pinned = try manager.revision(request.revision);
            if (request.path) |selector| {
                const candidate = if (std.mem.endsWith(u8, selector, "/")) try alloc.print("{s}_", .{selector}) else selector;
                if (!safeContentPath(candidate)) return error.WorkspacePathDenied;
            }
            var files: std.ArrayList(std.json.Value) = .empty;
            var count: usize = 0;
            for (try manager.fileManifest(pinned)) |file| {
                if (!safeContentPath(file.path)) continue;
                if (request.path) |selector| {
                    const matches = if (std.mem.endsWith(u8, selector, "/")) std.mem.startsWith(u8, file.path, selector) else std.mem.eql(u8, file.path, selector);
                    if (!matches) continue;
                }
                if (file.mode == .symlink) return error.WorkspaceSymlinkDenied;
                if (count >= request.offset and files.items.len < 32) try files.append(alloc, try parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .path = file.path, .artifact = file.artifact orelse return error.InvalidFossilManifest, .executable = file.mode == .executable }, .{})));
                count += 1;
            }
            break :blk try parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .revision = pinned, .files = files.items, .total = count, .next_offset = if (request.offset + files.items.len < count) @as(?usize, request.offset + files.items.len) else null }, .{}));
        },
        .read => blk: {
            const path = request.path orelse return error.MissingPath;
            if (!safeContentPath(path)) return error.WorkspacePathDenied;
            const content = try manager.contentAt(path, request.revision);
            if (request.limit == 0 or request.limit > 16384 or request.offset > content.len) return error.InvalidEvidenceOffset;
            const text_content = std.unicode.utf8ValidateSlice(content);
            if (text_content and request.offset < content.len and (content[request.offset] & 0xc0) == 0x80) return error.InvalidEvidenceOffset;
            var end = request.offset + @min(request.limit, content.len - request.offset);
            if (text_content) while (end > request.offset and !std.unicode.utf8ValidateSlice(content[request.offset..end])) {
                end -= 1;
            };
            if (end == request.offset and end < content.len) return error.InvalidEvidenceOffset;
            const segment = content[request.offset..end];
            const encoded = if (text_content) segment else encode_segment: {
                const result = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(segment.len));
                break :encode_segment std.base64.standard.Encoder.encode(result, segment);
            };
            break :blk try parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .path = path, .content = encoded, .encoding = if (text_content) "utf8" else "base64", .offset = request.offset, .bytes = content.len, .next_offset = if (end < content.len) @as(?usize, end) else null, .sha256 = try workspace.hash(alloc, content) }, .{}));
        },
        .record => blk: {
            if (!writable) return error.ServiceReadOnly;
            const selected = task orelse return error.TaskIdRequired;
            const id = try manager.writeRecord(selected, request.entity orelse return error.UnknownEntityType, request.content orelse return error.MissingContent);
            break :blk try parse(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .id = id }, .{}));
        },
        .propose => blk: {
            if (!writable) return error.ServiceReadOnly;
            break :blk try parse(alloc, try manager.proposeDefinition(task, request.content orelse return error.MissingContent, null));
        },
    };
    const result_revision = if (task) |selected| try manager.currentRevision(selected) else try manager.revision("trunk");
    const mutation = request.action == .record or request.action == .propose or request.action == .queue_review;
    if (!mutation and request.action != .read and request.action != .inventory and !std.mem.eql(u8, result_revision, revision)) return error.WorkspaceRevisionChanged;
    const response = try std.json.Stringify.valueAlloc(alloc, .{ .workspace = manager.manifest.id, .definition_hash = basis.definition_hash, .revision = if (request.action == .read or request.action == .inventory) request.revision else result_revision, .data = data }, .{});
    try model.validateOperation(alloc, declaration, operation, try parse(alloc, response), .output);
    return response;
}

fn parse(alloc: std.mem.Allocator, raw: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, alloc, raw, .{})).value;
}

fn safeContentPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.findScalar(u8, path, '\\') != null or std.mem.findScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for ([_][]const u8{ "history/", "records/", "memory/", "documents/", "artifacts/", "skills/", "ui/", "tasks/", "omniform/", "execution/", "proposals/", "acceptances/", "jobs/" }) |root| if (std.mem.startsWith(u8, path, root)) return true;
    return false;
}

test "workspace service restricts content paths to portable public record roots" {
    try std.testing.expect(safeContentPath("history/task/record.json"));
    try std.testing.expect(safeContentPath("memory/report.md"));
    try std.testing.expect(safeContentPath("ui/theme.json"));
    for ([_][]const u8{ "/etc/passwd", "history/../credentials", "memory//x", "sessions/private", "history\\private" }) |path| try std.testing.expect(!safeContentPath(path));
}
