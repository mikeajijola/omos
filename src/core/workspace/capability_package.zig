//! Explicit dependency closure for selected OmniForm realisations. A complete
//! declaration is distinct from verified runtime availability or permission.
const std = @import("std");
const model = @import("definition.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");
const Value = std.json.Value;

pub const Selection = authority.CapabilitySelection;
const Dependency = struct { kind: enum { runtime, configuration, service, host_implementation }, handle: []const u8, constraint: []const u8 };
const Portability = struct { version: []const u8, paths: []const []const u8 = &.{}, dependencies: []const Dependency = &.{} };
const Resource = struct { family: []const u8, definition: Value };
const Path = struct { resource: []const u8, path: []const u8 };
const External = struct { resource: []const u8, dependency: Dependency };
const Problem = struct { subject: []const u8, reason: []const u8 };
const DependencyEdge = struct { capability: []const u8, dependsOn: []const []const u8 };
const File = struct { path: []const u8, artifact: []const u8, executable: bool };

pub const Plan = struct {
    version: []const u8 = "omos.capability-package-plan/v1",
    definition_hash: []const u8,
    declaration_complete: bool,
    file_verification: []const u8 = "required",
    runtime_verification: []const u8 = "required",
    capabilities: []const Value,
    realisations: []const Value,
    resources: []const Resource,
    paths: []const Path,
    external_dependencies: []const External,
    problems: []const Problem,
    files: []const File = &.{},
    hierarchy: []const DependencyEdge = &.{},
};

pub fn includes(plan: Plan, path: []const u8) bool {
    for (plan.paths) |selector| if (std.mem.eql(u8, selector.path, path) or (std.mem.endsWith(u8, selector.path, "/") and std.mem.startsWith(u8, path, selector.path))) return true;
    return false;
}

fn mergeRows(alloc: std.mem.Allocator, target: *Value, additions: []const Value) !void {
    for (additions) |addition| {
        if (named(target.array.items, model.text(addition, "id"))) |previous| {
            if (!std.mem.eql(u8, try model.canonical(alloc, previous), try model.canonical(alloc, addition))) return error.CapabilityImportCollision;
        } else try target.array.append(addition);
    }
}

fn selectedCapabilities(alloc: std.mem.Allocator, plan: Plan) ![]const Value {
    var capabilities: std.ArrayList(Value) = .empty;
    for (plan.capabilities) |capability| {
        var selected = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, capability), .{});
        var realisations: std.ArrayList(Value) = .empty;
        for (plan.realisations) |realisation| if (std.mem.eql(u8, model.text(realisation, "capability"), model.text(capability, "id"))) try realisations.append(alloc, .{ .string = model.text(realisation, "id") });
        if (realisations.items.len != 1) return error.InvalidCapabilitySelection;
        try selected.object.put(alloc, "realisations", .{ .array = .init(alloc) });
        try selected.object.getPtr("realisations").?.array.appendSlice(realisations.items);
        try capabilities.append(alloc, selected);
    }
    return capabilities.items;
}

pub fn graphHash(alloc: std.mem.Allocator, plan: Plan) ![]const u8 {
    return workspace.hash(alloc, try model.canonical(alloc, try std.json.parseFromSliceLeaky(Value, alloc, try std.json.Stringify.valueAlloc(alloc, .{
        .version = "omos.capability-graph/v1",
        .capabilities = try selectedCapabilities(alloc, plan),
        .realisations = plan.realisations,
        .resources = plan.resources,
        .paths = plan.paths,
        .external_dependencies = plan.external_dependencies,
        .hierarchy = plan.hierarchy,
    }, .{}), .{})));
}

/// Build an additive candidate only. Caller retains this as an artifact until
/// runtime verification and normal host publication establish activation.
pub fn importDefinition(alloc: std.mem.Allocator, current: model.Declaration, plan: Plan) !model.Declaration {
    var value = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, current.value), .{});
    const root = value.object.getPtr("spec").?;
    const capabilities = try selectedCapabilities(alloc, plan);
    try mergeRows(alloc, root.object.getPtr("capabilities").?, capabilities);
    try mergeRows(alloc, root.object.getPtr("realisations").?, plan.realisations);
    const resources = root.object.getPtr("resources").?;
    for (plan.resources) |resource| {
        const family = resources.object.getPtr(resource.family) orelse return error.UnsupportedResourceFamily;
        try mergeRows(alloc, family, &.{resource.definition});
    }
    if (plan.hierarchy.len > 0) {
        const semantic = root.object.getPtr("semantic").?;
        if (semantic.object.getPtr("capabilityHierarchy") == null) try semantic.object.put(alloc, "capabilityHierarchy", .{ .array = .init(alloc) });
        const hierarchy = semantic.object.getPtr("capabilityHierarchy").?;
        for (plan.hierarchy) |edge| {
            const previous = for (hierarchy.array.items) |row| {
                if (std.mem.eql(u8, model.text(row, "capability"), edge.capability)) break row;
            } else null;
            if (previous) |row| {
                if (!std.mem.eql(u8, try std.json.Stringify.valueAlloc(alloc, model.items(row, "dependsOn"), .{}), try std.json.Stringify.valueAlloc(alloc, edge.dependsOn, .{}))) return error.CapabilityImportCollision;
            } else try hierarchy.array.append(try std.json.parseFromSliceLeaky(Value, alloc, try std.json.Stringify.valueAlloc(alloc, edge, .{}), .{}));
        }
    }
    const candidate = try model.parse(alloc, try model.canonical(alloc, value));
    if (!try model.compatible(alloc, current, candidate)) return error.CapabilityImportCollision;
    return candidate;
}

fn named(rows: []const Value, id: []const u8) ?Value {
    for (rows) |row| if (std.mem.eql(u8, model.text(row, "id"), id)) return row;
    return null;
}

fn findResource(root: Value, id: []const u8) ?Resource {
    const families = model.field(root, "resources") orelse return null;
    var iterator = families.object.iterator();
    while (iterator.next()) |family| if (named(family.value_ptr.array.items, id)) |definition| return .{ .family = family.key_ptr.*, .definition = definition };
    return null;
}

const Builder = struct {
    alloc: std.mem.Allocator,
    declaration: model.Declaration,
    selections: []const Selection,
    capabilities: std.ArrayList(Value) = .empty,
    realisations: std.ArrayList(Value) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    paths: std.ArrayList(Path) = .empty,
    external: std.ArrayList(External) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    visiting: std.StringHashMapUnmanaged(void) = .empty,

    fn problem(self: *Builder, subject: []const u8, reason: []const u8) !void {
        try self.problems.append(self.alloc, .{ .subject = subject, .reason = reason });
    }

    fn resource(self: *Builder, id: []const u8) !void {
        for (self.resources.items) |row| if (std.mem.eql(u8, model.text(row.definition, "id"), id)) return;
        const families = model.field(model.spec(self.declaration.value), "resources") orelse return error.UnknownResource;
        var iterator = families.object.iterator();
        while (iterator.next()) |family| {
            const definition = named(family.value_ptr.array.items, id) orelse continue;
            if (self.resources.items.len >= 1024) return error.CapabilityPackageTooLarge;
            try self.resources.append(self.alloc, .{ .family = family.key_ptr.*, .definition = definition });
            const spec = model.field(definition, "spec") orelse .null;
            const implementation = model.text(spec, "implementation");
            if (self.external.items.len >= 4096) return error.CapabilityPackageTooLarge;
            if (implementation.len == 0) try self.problem(id, "implementation_not_declared") else {
                try self.external.append(self.alloc, .{ .resource = id, .dependency = .{ .kind = .host_implementation, .handle = implementation, .constraint = model.profile_id } });
            }
            if (model.field(spec, "portability")) |raw| {
                const portability = try records.decode(Portability, self.alloc, try std.json.Stringify.valueAlloc(self.alloc, raw, .{}), .{});
                if (!std.mem.eql(u8, portability.version, "omos.resource-portability/v1") or portability.paths.len > 128 or portability.dependencies.len > 64) return error.UnsupportedResourcePortability;
                if (self.paths.items.len + portability.paths.len > 10000 or self.external.items.len + portability.dependencies.len > 4096) return error.CapabilityPackageTooLarge;
                for (portability.paths) |path| {
                    if (!authority.validPath(path, std.mem.endsWith(u8, path, "/"))) return error.InvalidResourcePackagePath;
                    try self.paths.append(self.alloc, .{ .resource = id, .path = path });
                }
                for (portability.dependencies) |dependency| {
                    if (!authority.safeIdentity(dependency.handle) or dependency.constraint.len == 0 or dependency.constraint.len > 256 or !std.unicode.utf8ValidateSlice(dependency.constraint)) return error.InvalidResourceDependency;
                    try self.external.append(self.alloc, .{ .resource = id, .dependency = dependency });
                }
                if (std.mem.eql(u8, implementation, "fossil_skill") and portability.paths.len == 0) try self.problem(id, "skill_package_paths_missing");
            } else if (std.mem.eql(u8, implementation, "fossil_skill")) try self.problem(id, "dependency_manifest_required");
            return;
        }
        return error.UnknownResource;
    }

    fn visitCapability(self: *Builder, id: []const u8, depth: usize) anyerror!void {
        if (depth > 64) return error.CapabilityPackageTooLarge;
        if (self.visiting.contains(id)) return error.CapabilityDependencyCycle;
        if (named(self.capabilities.items, id) != null) return;
        if (self.capabilities.items.len >= 256) return error.CapabilityPackageTooLarge;
        const root = model.spec(self.declaration.value);
        const capability = named(model.items(root, "capabilities"), id) orelse return error.UnknownCapability;
        try self.visiting.put(self.alloc, id, {});
        defer _ = self.visiting.remove(id);
        for (self.declaration.semantic.capabilityHierarchy) |row| {
            if (!std.mem.eql(u8, row.capability, id)) continue;
            for (row.dependsOn) |dependency| try self.visitCapability(dependency, depth + 1);
        }
        const choices = model.items(capability, "realisations");
        const requested = for (self.selections) |selection| {
            if (std.mem.eql(u8, selection.capability, id)) break selection.realisation;
        } else null;
        const selected = requested orelse if (choices.len == 1 and choices[0] == .string) choices[0].string else return error.RealisationSelectionRequired;
        var allowed = false;
        for (choices) |choice| if (choice == .string and std.mem.eql(u8, choice.string, selected)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.RealisationCapabilityMismatch;
        const realisation = named(model.items(root, "realisations"), selected) orelse return error.UnknownRealisation;
        const participants = model.items(realisation, "participants");
        for (model.items(capability, "requires")) |requirement| {
            if (model.field(requirement, "optional")) |optional| if (optional == .bool and optional.bool) continue;
            const requirement_id = model.text(requirement, "id");
            var supplied = false;
            for (participants) |participant| {
                const provider = findResource(root, model.text(participant, "resource")) orelse return error.UnknownResource;
                if (!std.mem.eql(u8, provider.family, model.text(requirement, "primitiveFamily"))) continue;
                for (model.items(participant, "supplies")) |supply| {
                    if (supply == .string and std.mem.eql(u8, supply.string, requirement_id)) supplied = true;
                }
            }
            if (!supplied) try self.problem(id, try self.alloc.print("requirement_not_supplied:{s}", .{requirement_id}));
        }
        for (participants) |participant| try self.resource(model.text(participant, "resource"));
        try self.capabilities.append(self.alloc, capability);
        try self.realisations.append(self.alloc, realisation);
    }
};

/// Resolve declared graph edges and explicit resource manifests. No executable
/// runs, provider credentials, or authority are copied into this plan.
pub fn describe(alloc: std.mem.Allocator, declaration: model.Declaration, selections: []const Selection) !Plan {
    if (selections.len == 0 or selections.len > 256) return error.InvalidCapabilitySelection;
    for (selections, 0..) |selection, index| {
        if (!authority.safeIdentity(selection.capability)) return error.InvalidCapabilitySelection;
        for (selections[0..index]) |previous| if (std.mem.eql(u8, selection.capability, previous.capability)) return error.DuplicateCapabilitySelection;
    }
    var builder: Builder = .{ .alloc = alloc, .declaration = declaration, .selections = selections };
    for (selections) |selection| try builder.visitCapability(selection.capability, 0);
    var hierarchy: std.ArrayList(DependencyEdge) = .empty;
    for (declaration.semantic.capabilityHierarchy) |row| {
        if (named(builder.capabilities.items, row.capability) != null and row.dependsOn.len > 0) try hierarchy.append(alloc, .{ .capability = row.capability, .dependsOn = row.dependsOn });
    }
    return .{ .hierarchy = hierarchy.items, .definition_hash = declaration.hash, .declaration_complete = builder.problems.items.len == 0, .capabilities = builder.capabilities.items, .realisations = builder.realisations.items, .resources = builder.resources.items, .paths = builder.paths.items, .external_dependencies = builder.external.items, .problems = builder.problems.items };
}

pub fn inspect(manager: workspace.Manager, selections: []const Selection) !Value {
    const revision = try manager.revision("trunk");
    const declaration = try manager.loadDeclaration(revision);
    if (!model.hasOperation(declaration, "omos_plan_capability_package")) return error.WorkspaceContractUpgradeRequired;
    const input = try std.json.parseFromSliceLeaky(Value, manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, .{ .selections = selections }, .{}), .{});
    try model.validateOperation(manager.alloc, declaration, "omos_plan_capability_package", input, .input);
    var plan = try describe(manager.alloc, declaration, selections);
    const manifest = try manager.fileManifest(revision);
    var files: std.ArrayList(File) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    try problems.appendSlice(manager.alloc, plan.problems);
    for (plan.paths) |requested| {
        var found = false;
        for (manifest) |file| {
            if (!std.mem.eql(u8, requested.path, file.path) and !(std.mem.endsWith(u8, requested.path, "/") and std.mem.startsWith(u8, file.path, requested.path))) continue;
            found = true;
            if (file.mode == .symlink) return error.WorkspaceSymlinkDenied;
            const seen = for (files.items) |previous| {
                if (std.mem.eql(u8, previous.path, file.path)) break true;
            } else false;
            if (seen) continue;
            if (files.items.len >= 10000) return error.CapabilityPackageTooLarge;
            try files.append(manager.alloc, .{ .path = file.path, .artifact = file.artifact orelse return error.WorkspaceVerificationFailed, .executable = file.mode == .executable });
        }
        if (!found) try problems.append(manager.alloc, .{ .subject = requested.resource, .reason = try manager.alloc.print("required_path_missing:{s}", .{requested.path}) });
    }
    plan.files = files.items;
    plan.problems = problems.items;
    plan.declaration_complete = plan.problems.len == 0;
    plan.file_verification = "manifest_inspected";
    const output = try std.json.parseFromSliceLeaky(Value, manager.alloc, try std.json.Stringify.valueAlloc(manager.alloc, .{ .workspace = manager.manifest.id, .revision = revision, .plan = plan }, .{}), .{});
    try model.validateOperation(manager.alloc, declaration, "omos_plan_capability_package", output, .output);
    return output;
}

test "capability packages enumerate native external requirements without claiming runtime verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plan = try describe(a, try model.parse(a, model.seed), &.{.{ .capability = "general_task" }});
    try std.testing.expect(plan.declaration_complete);
    try std.testing.expectEqual(@as(usize, 1), plan.capabilities.len);
    try std.testing.expectEqual(@as(usize, 2), plan.resources.len);
    try std.testing.expectEqual(@as(usize, 2), plan.external_dependencies.len);
    try std.testing.expectEqual(@as(usize, 0), plan.paths.len);
    try std.testing.expectEqualStrings("required", plan.runtime_verification);
    try std.testing.expectError(error.RealisationCapabilityMismatch, describe(a, try model.parse(a, model.seed), &.{.{ .capability = "general_task", .realisation = "coding_task_native" }}));
    try std.testing.expectError(error.DuplicateCapabilitySelection, describe(a, try model.parse(a, model.seed), &.{ .{ .capability = "general_task" }, .{ .capability = "general_task" } }));
}

test "capability packages distinguish copied skills from complete dependency declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = "\"implementation\":\"omos_repository\"";
    const index = std.mem.find(u8, model.seed, original) orelse return error.TestMissingFixture;
    const unbound = try a.print("{s}\"implementation\":\"fossil_skill\"{s}", .{ model.seed[0..index], model.seed[index + original.len ..] });
    const missing = try describe(a, try model.parse(a, unbound), &.{.{ .capability = "coding_task" }});
    try std.testing.expect(!missing.declaration_complete);
    try std.testing.expectEqualStrings("dependency_manifest_required", missing.problems[0].reason);
    const portable = try a.print("{s}\"implementation\":\"fossil_skill\",\"portability\":{{\"version\":\"omos.resource-portability/v1\",\"paths\":[\"skills/cv-builder/\"],\"dependencies\":[{{\"kind\":\"runtime\",\"handle\":\"node\",\"constraint\":\">=22\"}}]}}{s}", .{ model.seed[0..index], model.seed[index + original.len ..] });
    const declared = try describe(a, try model.parse(a, portable), &.{.{ .capability = "coding_task" }});
    try std.testing.expect(declared.declaration_complete);
    try std.testing.expectEqualStrings("skills/cv-builder/", declared.paths[0].path);
    try std.testing.expectEqual(@as(usize, 5), declared.external_dependencies.len);
    const invalid = try a.print("{s}\"implementation\":\"fossil_skill\",\"portability\":{{\"version\":\"omos.resource-portability/v1\",\"paths\":[\"skills/../outside\"]}}{s}", .{ model.seed[0..index], model.seed[index + original.len ..] });
    try std.testing.expectError(error.InvalidResourcePackagePath, describe(a, try model.parse(a, invalid), &.{.{ .capability = "coding_task" }}));
}

test "capability package imports preserve the native declaration and reject changed resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current = try model.parse(a, model.seed);
    const plan = try describe(a, current, &.{.{ .capability = "general_task" }});
    try std.testing.expectEqualStrings(current.hash, (try importDefinition(a, current, plan)).hash);
    var changed = plan;
    const resources = try a.dupe(Resource, plan.resources);
    var value = try std.json.parseFromSliceLeaky(Value, a, try model.canonical(a, resources[0].definition), .{});
    try value.object.put(a, "name", .{ .string = "Foreign replacement" });
    resources[0].definition = value;
    changed.resources = resources;
    try std.testing.expectError(error.CapabilityImportCollision, importDefinition(a, current, changed));
}
