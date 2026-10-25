//! Versioned read dependencies, including empty results and missing files.
//! These observations preserve inputs; they never grant content access.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const fossil_manifest = @import("fossil_manifest.zig");
const authority = @import("company_authority.zig");
const model = @import("definition.zig");
const records = @import("../shared/record_json.zig");

pub fn supported(declaration: model.Declaration) bool {
    var observation = false;
    var submission = false;
    var view = false;
    for (declaration.semantic.entityTypes) |entity| {
        if (std.mem.eql(u8, entity.id, "omos_company_read")) observation = true;
        if (std.mem.eql(u8, entity.id, "omos_company_submission")) submission = true;
        if (std.mem.eql(u8, entity.id, "omos_workspace_view") and model.field(entity.fields, "reads") != null) view = true;
    }
    return observation and submission and view;
}

// File observations and inventory pages retain identities, never aggregate bodies.
pub const max_references: usize = 20000;

pub const Reference = struct { path: []const u8, revision: []const u8 = "", selector: []const u8 };
const File = struct { path: []const u8, observed_hash: ?[]const u8, base_hash: ?[]const u8, flags_observed: bool = false, observed_executable: ?bool = null, base_executable: ?bool = null };
const Kind = enum { file, query, inventory };
pub const Observation = struct {
    version: []const u8 = "omos.company-read/v1",
    workspace: []const u8,
    task: []const u8,
    actor: []const u8,
    grant: []const u8,
    selector: []const u8,
    revision: []const u8,
    base_revision: []const u8,
    paths: []const []const u8,
    kind: Kind,
    entity: ?[]const u8 = null,
    membership_hash: ?[]const u8 = null,
    base_membership_hash: ?[]const u8 = null,
    files: []const File,
};

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

pub fn recordPath(alloc: std.mem.Allocator, value: Observation) ![]const u8 {
    return recordBytesPath(alloc, value.task, try encode(alloc, value));
}

fn recordBytesPath(alloc: std.mem.Allocator, task: []const u8, bytes: []const u8) ![]const u8 {
    return alloc.print("company/reads/{s}/{s}.json", .{ task, try workspace.hash(alloc, bytes) });
}

fn executable(metadata: []const fossil_manifest.File, path: []const u8) !?bool {
    for (metadata) |file| if (std.mem.eql(u8, file.path, path)) {
        if (file.mode == .symlink) return error.WorkspaceSymlinkDenied;
        return file.mode == .executable;
    };
    return null;
}

fn observedFlag(value: std.json.Value) !?bool {
    return switch (value) {
        .bool => value.bool,
        .null => null,
        else => error.InvalidCompanyRead,
    };
}

fn decodeObservation(alloc: std.mem.Allocator, raw: []const u8, reference: Reference) !Observation {
    const value = try records.decode(Observation, alloc, raw, .{});
    // Identity belongs to the original bytes, including historical fields and
    // defaults. Re-encoding a newer host type would change old record hashes.
    if (!std.mem.eql(u8, value.version, "omos.company-read/v1") or !std.mem.eql(u8, value.selector, reference.selector) or !std.mem.eql(u8, reference.path, try recordBytesPath(alloc, value.task, raw))) return error.InvalidCompanyRead;
    return value;
}

fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |entry| if (std.mem.eql(u8, entry, path)) return true;
    return false;
}

fn fileHash(manager: workspace.Manager, inventory: []const []const u8, path: []const u8, revision: []const u8) !?[]const u8 {
    if (!contains(inventory, path)) return null;
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    var scoped = manager;
    scoped.alloc = scratch.allocator();
    return try manager.alloc.dupe(u8, try workspace.hash(scoped.alloc, try scoped.contentAt(path, revision)));
}

fn membershipHash(alloc: std.mem.Allocator, inventory: []const []const u8, paths: []const []const u8, kind: Kind, entity: ?[]const u8) ![]const u8 {
    const permitted: authority.Grant = .{ .id = "read", .actor = "read", .public_key = "", .paths = paths, .actions = &.{}, .expires_ms = 0 };
    var selected: std.ArrayList([]const u8) = .empty;
    for (inventory) |path| {
        if (!authority.permitsPath(permitted, path)) continue;
        if (kind == .query) {
            const row = @import("company_records.zig").identity(path) orelse continue;
            if (entity) |filter| if (!std.mem.eql(u8, row.entity, filter)) continue;
        }
        try selected.append(alloc, path);
    }
    std.mem.sort([]const u8, selected.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    return workspace.hash(alloc, try encode(alloc, selected.items));
}

pub fn observe(manager: workspace.Manager, task: workspace.Task, grant: authority.Grant, request: authority.Request, revision: []const u8, result: std.json.Value) !Observation {
    const kind: Kind = if (request.action == .read or (request.action == .export_scope and request.path != null)) .file else if (request.action == .query) .query else .inventory;
    const attributes = std.mem.eql(u8, request.version, "omos.company/v2");
    const base_metadata: []const fossil_manifest.File = if (attributes) try manager.fileManifest(try manager.revision(task.base_revision)) else &.{};
    const base_files = try manager.inventory(task.base_revision);
    var files: std.ArrayList(File) = .empty;
    if (kind == .file) {
        const path = request.path orelse return error.MissingPath;
        const observed = model.field(result, "sha256") orelse return error.InvalidCompanyRead;
        if (observed != .string and observed != .null) return error.InvalidCompanyRead;
        const flag = model.field(result, "executable");
        try files.append(manager.alloc, .{ .path = path, .observed_hash = if (observed == .string) observed.string else null, .base_hash = try fileHash(manager, base_files, path, task.base_revision), .flags_observed = flag != null, .observed_executable = if (flag) |value| try observedFlag(value) else null, .base_executable = if (flag != null) try executable(base_metadata, path) else null });
    } else {
        for (model.items(result, if (kind == .query) "records" else "files")) |row| {
            const path = model.text(row, if (kind == .query) "source_path" else "path");
            if (!authority.permitsPath(grant, path)) return error.CompanyAccessDenied;
            const observed = model.text(row, "sha256");
            if (observed.len != 64) return error.InvalidCompanyRead;
            const flag = model.field(row, "executable");
            try files.append(manager.alloc, .{ .path = path, .observed_hash = observed, .base_hash = try fileHash(manager, base_files, path, task.base_revision), .flags_observed = flag != null, .observed_executable = if (flag) |value| try observedFlag(value) else null, .base_executable = if (flag != null) try executable(base_metadata, path) else null });
        }
    }
    return .{
        .workspace = manager.manifest.id,
        .task = task.id,
        .actor = grant.actor,
        .grant = grant.id,
        .selector = try workspace.hash(manager.alloc, if (attributes) try encode(manager.alloc, .{ "file_attributes", kind, request.path, request.entity, if (kind == .file) @as(usize, 0) else request.offset, if (kind == .file) @as(usize, 0) else request.limit }) else try encode(manager.alloc, .{ kind, request.path, request.entity, if (kind == .file) @as(usize, 0) else request.offset, if (kind == .file) @as(usize, 0) else request.limit })),
        .revision = revision,
        .base_revision = task.base_revision,
        .paths = grant.paths,
        .kind = kind,
        .entity = request.entity,
        .membership_hash = if (kind == .file) null else try membershipHash(manager.alloc, try manager.inventory(revision), grant.paths, kind, request.entity),
        .base_membership_hash = if (kind == .file) null else try membershipHash(manager.alloc, base_files, grant.paths, kind, request.entity),
        .files = files.items,
    };
}

fn equal(left: ?[]const u8, right: ?[]const u8) bool {
    return if (left) |value| if (right) |other| std.mem.eql(u8, value, other) else false else right == null;
}

fn matchesFile(current: ?[]const u8, flag: ?bool, file: File) bool {
    const matches_observed = equal(current, file.observed_hash) and (!file.flags_observed or flag == file.observed_executable);
    const matches_base = equal(current, file.base_hash) and (!file.flags_observed or flag == file.base_executable);
    return matches_observed or matches_base;
}

pub fn validate(manager: workspace.Manager, task: workspace.Task, references: []const Reference, target: []const u8) !void {
    if (references.len == 0) return;
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    if (references.len > max_references) return error.CompanyReadSetTooLarge;
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const inventory = try manager.inventory(target);
    var target_metadata: ?[]const fossil_manifest.File = null;
    for (references) |reference| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer scratch.deinit();
        var scoped = manager;
        scoped.alloc = scratch.allocator();
        const raw = try scoped.contentAt(reference.path, reference.revision);
        const value = try decodeObservation(scoped.alloc, raw, reference);
        if (!std.mem.eql(u8, value.workspace, manager.manifest.id) or !std.mem.eql(u8, value.task, task.id) or !std.mem.eql(u8, value.actor, binding.actor) or !std.mem.eql(u8, value.grant, binding.grant)) return error.InvalidCompanyRead;
        if (value.kind != .file) {
            const current = try membershipHash(scoped.alloc, inventory, value.paths, value.kind, value.entity);
            if (!equal(current, value.membership_hash) and !equal(current, value.base_membership_hash)) return error.WorkspaceReadDependencyChanged;
        }
        for (value.files) |file| {
            const current = try fileHash(scoped, inventory, file.path, target);
            if (file.flags_observed and target_metadata == null) target_metadata = try manager.fileManifest(try manager.revision(target));
            const flag = if (file.flags_observed) try executable(target_metadata.?, file.path) else null;
            if (!matchesFile(current, flag, file)) return error.WorkspaceReadDependencyChanged;
        }
    }
}

test "company read membership excludes inaccessible and unrelated records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const initial = try membershipHash(alloc, &.{ "records/note/a.json", "records/note/private.json", "records/other/elsewhere.json" }, &.{"records/note/a.json"}, .query, "note");
    const unaffected = try membershipHash(alloc, &.{ "records/note/a.json", "records/note/private.json", "records/note/another-private.json" }, &.{"records/note/a.json"}, .query, "note");
    try std.testing.expectEqualStrings(initial, unaffected);
    const absent = try membershipHash(alloc, &.{}, &.{"records/note/"}, .query, "note");
    const present = try membershipHash(alloc, &.{"records/note/a.json"}, &.{"records/note/"}, .query, "note");
    try std.testing.expect(!std.mem.eql(u8, absent, present));
    try std.testing.expect(!equal(null, "present"));
    try std.testing.expect(equal(null, null));
}

test "company reads preserve original legacy record identities after attribute extensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const raw = "{\"version\":\"omos.company-read/v1\",\"workspace\":\"company\",\"task\":\"task\",\"actor\":\"alice\",\"grant\":\"grant\",\"selector\":\"selector\",\"revision\":\"revision\",\"base_revision\":\"base\",\"paths\":[\"documents/\"],\"kind\":\"file\",\"files\":[{\"path\":\"documents/a.txt\",\"observed_hash\":\"observed\",\"base_hash\":null}]}";
    const reference: Reference = .{ .path = try recordBytesPath(alloc, "task", raw), .selector = "selector" };
    const value = try decodeObservation(alloc, raw, reference);
    try std.testing.expect(!value.files[0].flags_observed);
    try std.testing.expect(!std.mem.eql(u8, reference.path, try recordPath(alloc, value)));
    try std.testing.expectError(error.InvalidCompanyRead, decodeObservation(alloc, try alloc.print("{s} ", .{raw}), reference));
}

test "company reads compare content and executable flags as one observed state" {
    const file: File = .{ .path = "skills/run.sh", .observed_hash = "new", .base_hash = "old", .flags_observed = true, .observed_executable = false, .base_executable = true };
    try std.testing.expect(matchesFile("new", false, file));
    try std.testing.expect(matchesFile("old", true, file));
    try std.testing.expect(!matchesFile("new", true, file));
    try std.testing.expect(!matchesFile("old", false, file));
    try std.testing.expect(!matchesFile(null, null, file));
    var legacy = file;
    legacy.flags_observed = false;
    try std.testing.expect(matchesFile("new", true, legacy));
}
