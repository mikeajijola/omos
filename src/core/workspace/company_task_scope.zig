//! Immutable task-specific file boundaries below a participant's live grant.
//! These records narrow authority; they never create or restore permissions.
const std = @import("std");
const authority = @import("company_authority.zig");
const workspace = @import("fossil_workspace.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");

pub const prefix = "authority/task-scopes/";
pub const Record = struct {
    version: []const u8 = "omos.company-task-scope/v1",
    workspace: []const u8,
    task: []const u8,
    view: []const u8,
    actor: []const u8,
    grant: []const u8,
    paths: []const []const u8,
};

pub fn supported(declaration: model.Declaration) bool {
    var record = false;
    var reference = false;
    for (declaration.semantic.entityTypes) |entity| {
        if (std.mem.eql(u8, entity.id, "omos_company_task_scope")) record = true;
        if (std.mem.eql(u8, entity.id, "omos_workspace_view")) reference = model.field(entity.fields, "scope") != null;
    }
    for (model.items(model.spec(declaration.value), "operations")) |operation| if (std.mem.eql(u8, model.text(operation, "id"), "omos_company_operation")) {
        const input = model.field(operation, "input") orelse return false;
        const properties = model.field(input, "properties") orelse return false;
        return record and reference and model.field(properties, "scope") != null;
    };
    return false;
}

pub fn path(alloc: std.mem.Allocator, task: []const u8) ![]const u8 {
    if (!authority.safeIdentity(task)) return error.InvalidCompanyTaskScope;
    return alloc.print("{s}{s}.json", .{ prefix, task });
}

pub fn validatePaths(grant: authority.Grant, paths: []const []const u8) !void {
    if (paths.len == 0 or paths.len > 32) return error.InvalidCompanyTaskScope;
    for (paths, 0..) |selected, index| {
        if (!authority.permitsSelector(grant, selected)) return error.CompanyAccessDenied;
        for (paths[0..index]) |previous| if (std.mem.eql(u8, previous, selected)) return error.InvalidCompanyTaskScope;
    }
}

pub fn validateStored(alloc: std.mem.Allocator, record: Record, record_path: []const u8) !void {
    if (!std.mem.eql(u8, record.version, "omos.company-task-scope/v1") or record.paths.len == 0 or record.paths.len > 32) return error.InvalidCompanyTaskScope;
    for ([_][]const u8{ record.workspace, record.task, record.view, record.actor, record.grant }) |id| if (!authority.safeIdentity(id)) return error.InvalidCompanyTaskScope;
    if (!std.mem.eql(u8, record_path, try path(alloc, record.task))) return error.InvalidCompanyTaskScope;
    for (record.paths, 0..) |selected, index| {
        if (!authority.validPath(selected, std.mem.endsWith(u8, selected, "/"))) return error.InvalidCompanyTaskScope;
        for (record.paths[0..index]) |previous| if (std.mem.eql(u8, previous, selected)) return error.InvalidCompanyTaskScope;
    }
}

fn apply(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, record: Record) !authority.Grant {
    if (!std.mem.eql(u8, record.workspace, manager.manifest.id) or !std.mem.eql(u8, record.task, task.id) or !std.mem.eql(u8, record.actor, grant.actor) or !std.mem.eql(u8, record.grant, grant.id)) return error.CompanyAccessDenied;
    const binding = task.authority orelse return error.CompanyAccessDenied;
    if (!std.mem.eql(u8, binding.actor, grant.actor) or !std.mem.eql(u8, binding.grant, grant.id)) return error.CompanyAccessDenied;
    try validatePaths(grant, record.paths);
    var scoped = grant;
    scoped.paths = record.paths;
    return scoped;
}

pub fn forView(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, view: []const u8, reference: ?[]const u8) !authority.Grant {
    const selected = reference orelse return grant;
    if (!std.mem.eql(u8, selected, try path(manager.alloc, task.id))) return error.InvalidCompanyTaskScope;
    const record = try records.decode(Record, manager.alloc, try manager.companyContent(selected), .{});
    try validateStored(manager.alloc, record, selected);
    if (!std.mem.eql(u8, record.view, view)) return error.CompanyAccessDenied;
    return apply(manager, task, grant, record);
}

/// Publication and direct native checkpoints cannot depend on a caller's view
/// descriptor. Find the protected task record even when no view was supplied.
pub fn forTask(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant) !authority.Grant {
    const selected = try path(manager.alloc, task.id);
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision)) |entry| if (std.mem.eql(u8, entry, selected)) {
        const record = try records.decode(Record, manager.alloc, try manager.contentAt(selected, revision), .{});
        try validateStored(manager.alloc, record, selected);
        return apply(manager, task, grant, record);
    };
    return grant;
}

test "company task scopes can only narrow live file authority" {
    const grant: authority.Grant = .{ .id = "grant", .actor = "actor", .public_key = "public", .paths = &.{ "documents/team/", "ui/" }, .actions = &.{ .read, .checkpoint }, .expires_ms = 10000 };
    try validatePaths(grant, &.{ "documents/team/report.md", "ui/panels/" });
    try std.testing.expectError(error.CompanyAccessDenied, validatePaths(grant, &.{"documents/"}));
    try std.testing.expectError(error.CompanyAccessDenied, validatePaths(grant, &.{"documents/team/../private"}));
    try std.testing.expectError(error.InvalidCompanyTaskScope, validatePaths(grant, &.{}));
    try std.testing.expectError(error.InvalidCompanyTaskScope, validatePaths(grant, &.{ "ui/", "ui/" }));
}
