//! Task-to-capability distillation: extract a promotable OmniForm capability,
//! realisation, structured contract rubric, and portable skill package from an
//! accepted local personal task while leaving private research, chat logs, and
//! scratch memory behind.
const std = @import("std");
const contract = @import("../agent/runtime/work_contract.zig");
const io = @import("../shared/io.zig");
const authority = @import("company_authority.zig");
const model = @import("definition.zig");
const package = @import("capability_package.zig");
const promotion = @import("capability_promotion.zig");
const workspace = @import("fossil_workspace.zig");
const Value = std.json.Value;

pub const DependencyKind = enum { runtime, configuration, service, host_implementation };

pub const DependencySpec = struct {
    kind: DependencyKind = .runtime,
    handle: []const u8,
    constraint: []const u8,
};

pub const Options = struct {
    task_id: []const u8,
    capability_id: []const u8,
    realisation_id: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    paths: ?[]const []const u8 = null,
    dependencies: []const DependencySpec = &.{},
    depends_on: []const []const u8 = &.{},
    apply: bool = false,
    promote_config: ?[]const u8 = null,
    summary: ?[]const u8 = null,
};

pub const Rubric = struct {
    source_task_id: []const u8,
    source_publication_revision: []const u8,
    source_receipt_sha256: []const u8,
    source_realisation_id: ?[]const u8 = null,
    objective: []const u8,
    plan_summary: ?[]const u8 = null,
    obligations: []const contract.Obligation,
    criteria: []const contract.Obligation = &.{},
    checks: []const []const u8 = &.{},
    required_tools: []const []const u8 = &.{},
    skill_bindings: []const []const u8 = &.{},
};

const GeneratedSkill = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: usize,
    content: []const u8,
};

const ActivationReceipt = struct {
    revision: []const u8,
    proposal_id: []const u8,
    state: []const u8,
    definition_hash: []const u8,
    files_verified: usize,
};

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

fn isOmniformId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!authority.safeIdentity(value)) return false;
    if (!std.ascii.isLower(value[0])) return false;
    var previous_underscore = false;
    for (value) |byte| {
        if (byte == '_') {
            if (previous_underscore) return false;
            previous_underscore = true;
            continue;
        }
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte)) return false;
        previous_underscore = false;
    }
    return !previous_underscore;
}

fn isForbiddenDistillPath(alloc: std.mem.Allocator, path: []const u8) !bool {
    if (path.len == 0 or path[0] == '.') return true;
    const lower = try std.ascii.allocLowerString(alloc, path);
    const forbidden_roots = [_][]const u8{
        "memory",
        "runtime",
        "tasks",
        "records",
        "history",
        "acceptances",
        "activations",
        "proposals",
        "authority",
        "company",
        "omniform",
        "execution",
        "artifacts",
        "workspace.json",
    };
    for (forbidden_roots) |root| {
        if (std.mem.eql(u8, lower, root)) return true;
        if (lower.len > root.len and std.mem.startsWith(u8, lower, root) and lower[root.len] == '/') return true;
    }
    return false;
}

fn titleCaseFromId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var new_word = true;
    for (id) |byte| {
        if (byte == '_' or byte == '-') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(alloc, ' ');
            }
            new_word = true;
            continue;
        }
        try out.append(alloc, if (new_word) std.ascii.toUpper(byte) else byte);
        new_word = false;
    }
    return out.items;
}

fn slugFromId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, id);
    for (out) |*byte| {
        if (byte.* == '_') byte.* = '-';
    }
    return out;
}

fn sanitizeSingleLine(alloc: std.mem.Allocator, text: []const u8, max_len: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last_space = true;
    for (text) |byte| {
        if (out.items.len >= max_len) break;
        if (byte == '\r' or byte == '\n' or byte == '\t' or byte == ' ') {
            if (!last_space) {
                try out.append(alloc, ' ');
                last_space = true;
            }
            continue;
        }
        try out.append(alloc, byte);
        last_space = false;
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

fn yamlQuote(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');
    for (text) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '"' => try out.appendSlice(alloc, "\\\""),
            '\r', '\n' => try out.append(alloc, ' '),
            else => try out.append(alloc, byte),
        }
    }
    try out.append(alloc, '"');
    return out.items;
}

fn skillNameFromPath(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "skills/")) return null;
    const rest = path["skills/".len..];
    if (rest.len == 0) return null;
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const candidate = rest[0..slash];
    return if (candidate.len > 0) candidate else null;
}

fn selectorMatchesPath(selector: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, selector, path) or (std.mem.endsWith(u8, selector, "/") and std.mem.startsWith(u8, path, selector));
}

fn collectDeclaredIds(alloc: std.mem.Allocator, declaration: model.Declaration) !std.array_hash_map.String(void) {
    var ids: std.array_hash_map.String(void) = .empty;
    const root = model.spec(declaration.value);
    for ([_][]const u8{ "capabilities", "realisations", "operations" }) |section| {
        for (model.items(root, section)) |row| {
            const id = model.text(row, "id");
            if (id.len > 0) try ids.put(alloc, id, {});
        }
    }
    if (model.field(root, "resources")) |families| {
        if (families == .object) {
            var it = families.object.iterator();
            while (it.next()) |family| {
                if (family.value_ptr.* != .array) continue;
                for (family.value_ptr.array.items) |resource| {
                    const id = model.text(resource, "id");
                    if (id.len > 0) try ids.put(alloc, id, {});
                }
            }
        }
    }
    return ids;
}

fn findOfferingResource(declaration: model.Declaration, family: []const u8, offer: []const u8, preferred_id: []const u8) ?[]const u8 {
    const resources = model.field(model.spec(declaration.value), "resources") orelse return null;
    const rows = model.items(resources, family);
    var fallback: ?[]const u8 = null;
    for (rows) |row| {
        const id = model.text(row, "id");
        var offers_match = false;
        for (model.items(row, "offers")) |entry| {
            if (entry == .string and std.mem.eql(u8, entry.string, offer)) {
                offers_match = true;
                break;
            }
        }
        if (!offers_match) continue;
        if (std.mem.eql(u8, id, preferred_id)) return id;
        if (fallback == null) fallback = id;
    }
    return fallback;
}

fn extractTaskPlanRubric(manager: workspace.Manager, task: workspace.Task, revision: []const u8) !struct { summary: ?[]const u8, checks: []const []const u8 } {
    const alloc = manager.alloc;
    const prefix = try alloc.print("history/{s}/", .{task.id});
    const manifest = try manager.fileManifest(revision);
    var best_version: u32 = 0;
    var found = false;
    var best_summary: ?[]const u8 = null;
    var best_checks: []const []const u8 = &.{};

    for (manifest) |entry| {
        if (!std.mem.startsWith(u8, entry.path, prefix) or !std.mem.endsWith(u8, entry.path, ".json")) continue;
        if (entry.mode == .symlink) continue;
        const raw = manager.contentAt(entry.path, revision) catch continue;
        const parsed = std.json.parseFromSliceLeaky(Value, alloc, raw, .{}) catch continue;
        if (!std.mem.eql(u8, model.text(parsed, "kind"), "task_plan")) continue;
        if (!std.mem.eql(u8, model.text(parsed, "task"), task.id)) continue;
        const version_val = model.field(parsed, "contract_version") orelse continue;
        const version: u32 = if (version_val == .integer and version_val.integer >= 0) @intCast(version_val.integer) else 0;
        if (found and version < best_version) continue;
        const val = model.field(parsed, "value") orelse continue;
        const summary_raw = std.mem.trim(u8, model.text(val, "summary"), " \t\r\n");
        var checks: std.ArrayList([]const u8) = .empty;
        for (model.items(val, "checks")) |item| {
            if (item != .string) continue;
            const trimmed = std.mem.trim(u8, item.string, " \t\r\n");
            if (trimmed.len > 0) try checks.append(alloc, trimmed);
        }
        found = true;
        best_version = version;
        best_summary = if (summary_raw.len > 0) summary_raw else null;
        best_checks = checks.items;
    }
    return .{ .summary = best_summary, .checks = best_checks };
}

fn synthesizeSkillMarkdown(
    alloc: std.mem.Allocator,
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    rubric: Rubric,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    const short_desc = try sanitizeSingleLine(alloc, description, 256);
    try w.print("---\nname: {s}\ndescription: {s}\n---\n\n", .{ slug, try yamlQuote(alloc, short_desc) });
    try w.print("# {s}\n\n", .{name});
    try w.writeAll("## Objective\n\n");
    try w.print("{s}\n\n", .{std.mem.trim(u8, rubric.objective, " \t\r\n")});

    try w.writeAll("## Obligations\n\n");
    for (rubric.obligations) |obligation| {
        try w.print("- `{s}`: {s}\n", .{ obligation.id, std.mem.trim(u8, obligation.description, " \t\r\n") });
    }
    try w.writeByte('\n');

    if (rubric.criteria.len > 0 or rubric.checks.len > 0) {
        try w.writeAll("## Verification Criteria\n\n");
        for (rubric.criteria) |criterion| {
            try w.print("- `{s}`: {s}\n", .{ criterion.id, std.mem.trim(u8, criterion.description, " \t\r\n") });
        }
        for (rubric.checks) |check| {
            try w.print("- {s}\n", .{check});
        }
        try w.writeByte('\n');
    }

    if (rubric.required_tools.len > 0) {
        try w.writeAll("## Required Tools\n\n");
        for (rubric.required_tools) |tool| {
            try w.print("- `{s}`\n", .{tool});
        }
        try w.writeByte('\n');
    }

    if (rubric.skill_bindings.len > 0) {
        try w.writeAll("## Referenced Skills\n\n");
        for (rubric.skill_bindings) |binding| {
            try w.print("- `{s}`\n", .{binding});
        }
        try w.writeByte('\n');
    }

    try w.writeAll("## Provenance\n\n");
    try w.print("- Source task: `{s}`\n", .{rubric.source_task_id});
    try w.print("- Publication revision: `{s}`\n", .{rubric.source_publication_revision});
    try w.print("- Acceptance receipt SHA-256: `{s}`\n", .{rubric.source_receipt_sha256});
    return out.toOwnedSlice();
}

fn selectPortablePaths(
    manager: workspace.Manager,
    task: workspace.Task,
    task_source_rev: []const u8,
    trunk_rev: []const u8,
    capability_id: []const u8,
    name: []const u8,
    description: []const u8,
    rubric: Rubric,
    explicit_paths: ?[]const []const u8,
) !struct { paths: []const []const u8, generated: ?GeneratedSkill } {
    const alloc = manager.alloc;
    const trunk_manifest = try manager.fileManifest(trunk_rev);

    if (explicit_paths) |requested| {
        if (requested.len == 0 or requested.len > 128) return error.InvalidResourcePackagePath;
        var selected: std.ArrayList([]const u8) = .empty;
        var seen: std.array_hash_map.String(void) = .empty;
        for (requested) |raw_path| {
            const is_dir = std.mem.endsWith(u8, raw_path, "/");
            if (!authority.validPath(raw_path, is_dir)) return error.InvalidResourcePackagePath;
            if (try isForbiddenDistillPath(alloc, raw_path)) return error.DistillPathDenied;
            var matched = false;
            for (trunk_manifest) |entry| {
                if (!selectorMatchesPath(raw_path, entry.path)) continue;
                if (entry.mode == .symlink) return error.WorkspaceSymlinkDenied;
                matched = true;
                break;
            }
            if (!matched) return error.DistillPathNotFound;
            if ((try seen.getOrPut(alloc, raw_path)).found_existing) continue;
            try selected.append(alloc, raw_path);
        }
        std.mem.sort([]const u8, selected.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.less);
        return .{ .paths = selected.items, .generated = null };
    }

    // Automatic portable path selection: inspect only published skills/ paths
    // created or updated by this task (or referenced by skill_bindings on trunk),
    // strictly excluding memory/, runtime/, tasks/, records/, and scratch files.
    const base_manifest = try manager.fileManifest(task.base_revision);
    const task_manifest = try manager.fileManifest(task_source_rev);

    const EntryIdentity = struct { artifact: []const u8, mode: @TypeOf(base_manifest[0].mode) };
    var base_index: std.array_hash_map.String(EntryIdentity) = .empty;
    for (base_manifest) |entry| {
        try base_index.put(alloc, entry.path, .{ .artifact = entry.artifact orelse "", .mode = entry.mode });
    }
    var trunk_index: std.array_hash_map.String(void) = .empty;
    var trunk_lower: std.array_hash_map.String(void) = .empty;
    for (trunk_manifest) |entry| {
        if (entry.mode != .symlink) {
            try trunk_index.put(alloc, entry.path, {});
        }
        try trunk_lower.put(alloc, try std.ascii.allocLowerString(alloc, entry.path), {});
    }

    var discovered: std.ArrayList([]const u8) = .empty;
    var seen_selectors: std.array_hash_map.String(void) = .empty;

    for (task_manifest) |entry| {
        if (!std.mem.startsWith(u8, entry.path, "skills/")) continue;
        if (entry.mode == .symlink) continue;
        if (!trunk_index.contains(entry.path)) continue;
        const changed = if (base_index.get(entry.path)) |previous|
            (!std.mem.eql(u8, previous.artifact, entry.artifact orelse "") or previous.mode != entry.mode)
        else
            true;
        if (!changed) continue;
        const selector = if (skillNameFromPath(entry.path)) |dir_name| blk: {
            const candidate_dir = try alloc.print("skills/{s}/", .{dir_name});
            break :blk if (std.mem.startsWith(u8, entry.path, candidate_dir)) candidate_dir else entry.path;
        } else entry.path;
        if (!authority.validPath(selector, std.mem.endsWith(u8, selector, "/"))) continue;
        if ((try seen_selectors.getOrPut(alloc, selector)).found_existing) continue;
        try discovered.append(alloc, selector);
    }

    for (task.definition.skill_bindings) |binding| {
        if (!authority.safeIdentity(binding)) continue;
        const candidate_dir = try alloc.print("skills/{s}/", .{binding});
        if (!authority.validPath(candidate_dir, true)) continue;
        var has_file = false;
        for (trunk_manifest) |entry| {
            if (entry.mode != .symlink and std.mem.startsWith(u8, entry.path, candidate_dir)) {
                has_file = true;
                break;
            }
        }
        if (!has_file) continue;
        if ((try seen_selectors.getOrPut(alloc, candidate_dir)).found_existing) continue;
        try discovered.append(alloc, candidate_dir);
    }

    if (discovered.items.len > 0) {
        std.mem.sort([]const u8, discovered.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.less);
        return .{ .paths = discovered.items, .generated = null };
    }

    // No skill files were created by the task: synthesize a deterministic
    // skills/<slug>/SKILL.md containing the structured rubric without clobbering
    // any existing skill file on trunk.
    const slug = try slugFromId(alloc, capability_id);
    const skill_dir = try alloc.print("skills/{s}/", .{slug});
    const skill_md_path = try alloc.print("skills/{s}/SKILL.md", .{slug});
    const lower_skill_md = try std.ascii.allocLowerString(alloc, skill_md_path);
    if (trunk_lower.contains(lower_skill_md)) return error.DistillSkillPathCollision;

    const md = try synthesizeSkillMarkdown(alloc, slug, name, description, rubric);
    const digest = try workspace.hash(alloc, md);
    const paths = try alloc.dupe([]const u8, &.{skill_dir});
    return .{
        .paths = paths,
        .generated = .{
            .path = skill_md_path,
            .sha256 = digest,
            .bytes = md.len,
            .content = md,
        },
    };
}

/// Extract a promotable OmniForm capability, realisation, rubric, and portable
/// skill package from an accepted personal task. Preview is strictly read-only;
/// apply activates the additive declaration locally on trunk; promote applies
/// locally and submits the distilled package to the central company service.
pub fn distill(manager: workspace.Manager, options: Options) !Value {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const alloc = manager.alloc;

    if (!isOmniformId(options.capability_id)) return error.InvalidCapabilityId;
    const realisation_id = options.realisation_id orelse try alloc.print("{s}_skill", .{options.capability_id});
    const resource_id = options.resource_id orelse try alloc.print("{s}_package", .{options.capability_id});
    const requirement_id = try alloc.print("{s}_playbook", .{options.capability_id});
    if (!isOmniformId(realisation_id) or !isOmniformId(resource_id) or !isOmniformId(requirement_id)) {
        return error.InvalidCapabilityId;
    }
    if (std.mem.eql(u8, options.capability_id, realisation_id) or
        std.mem.eql(u8, options.capability_id, resource_id) or
        std.mem.eql(u8, realisation_id, resource_id))
    {
        return error.DuplicateDefinitionIdentity;
    }
    if (options.dependencies.len > 64) return error.InvalidResourceDependency;
    for (options.dependencies) |dep| {
        if (!authority.safeIdentity(dep.handle) or dep.constraint.len == 0 or dep.constraint.len > 256 or !std.unicode.utf8ValidateSlice(dep.constraint)) {
            return error.InvalidResourceDependency;
        }
    }

    // 1. Validate the source task is a retained, accepted personal task with verified publication on trunk.
    const task = try manager.loadTask(options.task_id);
    if (task.authority != null or task.state != .accepted or !std.mem.eql(u8, task.parent, "trunk")) {
        return error.TaskNotAcceptedForDistill;
    }
    const pub_summary = manager.publicationSummary(task) catch return error.TaskNotAcceptedForDistill;
    const pub_revision = model.text(pub_summary, "revision");
    const receipt_sha256 = model.text(pub_summary, "receipt_sha256");
    if (pub_revision.len == 0 or receipt_sha256.len == 0) return error.TaskNotAcceptedForDistill;
    const task_source_rev = try manager.currentRevision(task);

    // 2. Load current trunk declaration and verify zero collisions with existing IDs.
    const trunk_rev = try manager.revision("trunk");
    const current = try manager.loadDeclaration(trunk_rev);
    const existing_ids = try collectDeclaredIds(alloc, current);
    if (existing_ids.contains(options.capability_id) or
        existing_ids.contains(realisation_id) or
        existing_ids.contains(resource_id))
    {
        return error.CapabilityAlreadyExists;
    }

    // Validate depends_on parent capabilities exist in current declaration.
    var seen_deps: std.array_hash_map.String(void) = .empty;
    var depends_on: std.ArrayList([]const u8) = .empty;
    for (options.depends_on) |dep_cap| {
        if (!isOmniformId(dep_cap) or std.mem.eql(u8, dep_cap, options.capability_id)) return error.InvalidCapabilitySelection;
        var exists = false;
        for (model.items(model.spec(current.value), "capabilities")) |row| {
            if (std.mem.eql(u8, model.text(row, "id"), dep_cap)) {
                exists = true;
                break;
            }
        }
        if (!exists) return error.UnknownCapability;
        if ((try seen_deps.getOrPut(alloc, dep_cap)).found_existing) continue;
        try depends_on.append(alloc, dep_cap);
    }

    const inference_resource = findOfferingResource(current, "inference", "reasoning", "configured_model") orelse return error.UnknownResource;
    const memory_resource = findOfferingResource(current, "memory", "retained_workspace", "fossil_workspace") orelse return error.UnknownResource;

    // 3. Extract structured rubric (never raw chat transcripts or private memory/).
    const plan_meta = try extractTaskPlanRubric(manager, task, task_source_rev);
    const rubric: Rubric = .{
        .source_task_id = task.id,
        .source_publication_revision = pub_revision,
        .source_receipt_sha256 = receipt_sha256,
        .source_realisation_id = task.definition.realisation_id,
        .objective = task.definition.objective,
        .plan_summary = plan_meta.summary,
        .obligations = task.definition.obligations,
        .criteria = task.definition.criteria,
        .checks = plan_meta.checks,
        .required_tools = task.definition.required_tools,
        .skill_bindings = task.definition.skill_bindings,
    };

    const derived_name = if (options.name) |custom| blk: {
        const trimmed = std.mem.trim(u8, custom, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 256 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidCapabilityMetadata;
        break :blk trimmed;
    } else try titleCaseFromId(alloc, options.capability_id);

    const derived_desc = if (options.description) |custom| blk: {
        const trimmed = std.mem.trim(u8, custom, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 1024 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidCapabilityMetadata;
        break :blk trimmed;
    } else try sanitizeSingleLine(alloc, plan_meta.summary orelse task.definition.objective, 1024);

    // 4. Select portable skill files or synthesize a clean SKILL.md rubric document.
    const portable = try selectPortablePaths(
        manager,
        task,
        task_source_rev,
        trunk_rev,
        options.capability_id,
        derived_name,
        derived_desc,
        rubric,
        options.paths,
    );

    // Derive skill metadata for realisation_selection discovery.
    var skill_names: std.ArrayList([]const u8) = .empty;
    var seen_skills: std.array_hash_map.String(void) = .empty;
    for (portable.paths) |p| {
        if (skillNameFromPath(p)) |skill_slug| {
            if (!(try seen_skills.getOrPut(alloc, skill_slug)).found_existing) {
                try skill_names.append(alloc, skill_slug);
            }
        }
    }
    for (rubric.skill_bindings) |binding| {
        if (!(try seen_skills.getOrPut(alloc, binding)).found_existing) {
            try skill_names.append(alloc, binding);
        }
    }
    if (skill_names.items.len == 0) {
        try skill_names.append(alloc, try slugFromId(alloc, options.capability_id));
    }
    const primary_skill = skill_names.items[0];

    // 5. Build additive OmniForm declaration candidate.
    var candidate_val = try std.json.parseFromSliceLeaky(Value, alloc, try model.canonical(alloc, current.value), .{});
    const spec_obj = candidate_val.object.getPtr("spec").?;

    // Build fossil_skill resource spec.
    var resource_spec_obj: std.json.ObjectMap = .empty;
    try resource_spec_obj.put(alloc, "implementation", .{ .string = "fossil_skill" });
    try resource_spec_obj.put(alloc, "skill", .{ .string = primary_skill });
    if (skill_names.items.len > 1) {
        try resource_spec_obj.put(alloc, "skills", try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, skill_names.items), .{}));
    }
    if (rubric.required_tools.len > 0) {
        try resource_spec_obj.put(alloc, "tools", try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, rubric.required_tools), .{}));
    }
    try resource_spec_obj.put(alloc, "portability", try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .version = "omos.resource-portability/v1",
        .paths = portable.paths,
        .dependencies = options.dependencies,
    }), .{}));
    try resource_spec_obj.put(alloc, "distilled_from", try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .task_id = rubric.source_task_id,
        .publication_revision = rubric.source_publication_revision,
        .receipt_sha256 = rubric.source_receipt_sha256,
    }), .{}));

    var resource_val = try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .id = resource_id,
        .name = try alloc.print("{s} skill package", .{derived_name}),
        .offers = &.{requirement_id},
    }), .{});
    try resource_val.object.put(alloc, "spec", .{ .object = resource_spec_obj });

    if (spec_obj.object.getPtr("resources") == null) {
        try spec_obj.object.put(alloc, "resources", .{ .object = .empty });
    }
    const resources_obj = spec_obj.object.getPtr("resources").?;
    if (resources_obj.object.getPtr("skills") == null) {
        try resources_obj.object.put(alloc, "skills", .{ .array = .init(alloc) });
    }
    try resources_obj.object.getPtr("skills").?.array.append(resource_val);

    const skill_req_desc = try alloc.print("skill:{s} distilled from task {s}", .{ primary_skill, task.id });
    const capability_val = try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .id = options.capability_id,
        .name = derived_name,
        .description = derived_desc,
        .requires = .{
            .{ .id = "reasoning", .primitiveFamily = "inference" },
            .{ .id = "retained_workspace", .primitiveFamily = "memory" },
            .{ .id = requirement_id, .primitiveFamily = "skills", .description = skill_req_desc },
        },
        .realisations = &.{realisation_id},
    }), .{});
    try spec_obj.object.getPtr("capabilities").?.array.append(capability_val);

    if (spec_obj.object.getPtr("realisations") == null) {
        try spec_obj.object.put(alloc, "realisations", .{ .array = .init(alloc) });
    }
    const realisation_val = try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .id = realisation_id,
        .name = try alloc.print("{s} in omos", .{derived_name}),
        .capability = options.capability_id,
        .description = derived_desc,
        .participants = .{
            .{ .resource = inference_resource, .supplies = &.{"reasoning"} },
            .{ .resource = memory_resource, .supplies = &.{"retained_workspace"} },
            .{ .resource = resource_id, .supplies = &.{requirement_id} },
        },
    }), .{});
    try spec_obj.object.getPtr("realisations").?.array.append(realisation_val);

    if (depends_on.items.len > 0) {
        const semantic_obj = spec_obj.object.getPtr("semantic") orelse return error.MissingSemanticVersion;
        if (semantic_obj.object.getPtr("capabilityHierarchy") == null) {
            try semantic_obj.object.put(alloc, "capabilityHierarchy", .{ .array = .init(alloc) });
        }
        try semantic_obj.object.getPtr("capabilityHierarchy").?.array.append(try std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
            .capability = options.capability_id,
            .dependsOn = depends_on.items,
        }), .{}));
    }

    // 6. Validate candidate declaration, additive compatibility, and package completeness.
    const candidate_json = try model.canonical(alloc, candidate_val);
    const candidate = try model.parse(alloc, candidate_json);
    if (!try model.compatible(alloc, current, candidate)) return error.CapabilityImportCollision;

    const selections: []const package.Selection = &.{.{ .capability = options.capability_id, .realisation = realisation_id }};
    const plan = try package.describe(alloc, candidate, selections);
    if (!plan.declaration_complete or plan.problems.len != 0) return error.IncompleteCapabilityPackage;
    const graph_hash = try package.graphHash(alloc, plan);

    // Guarantee Layer 1's importDefinition accepts the exact plan cleanly.
    _ = try package.importDefinition(alloc, current, plan);

    const do_apply = options.apply or options.promote_config != null;
    var activation: ?ActivationReceipt = null;
    var promotion_receipt: ?Value = null;

    if (do_apply) {
        const proposal_bytes = if (portable.generated) |gen|
            try manager.proposeDefinitionWithFiles(null, candidate_json, null, &.{.{ .path = gen.path, .content = gen.content }})
        else
            try manager.proposeDefinition(null, candidate_json, null);
        const proposal_val = try std.json.parseFromSliceLeaky(Value, alloc, proposal_bytes, .{});
        const state = model.text(proposal_val, "state");
        if (!std.mem.eql(u8, state, "activated")) return error.CapabilityImportCollision;

        // Verify the activated capability package on trunk passes full manifest inspection.
        const inspected = try package.inspect(manager, selections);
        const inspected_plan = model.field(inspected, "plan") orelse return error.IncompleteCapabilityPackage;
        const complete = if (model.field(inspected_plan, "declaration_complete")) |flag| (flag == .bool and flag.bool) else false;
        if (!complete) return error.IncompleteCapabilityPackage;

        activation = .{
            .revision = model.text(inspected, "revision"),
            .proposal_id = model.text(proposal_val, "id"),
            .state = state,
            .definition_hash = candidate.hash,
            .files_verified = model.items(inspected_plan, "files").len,
        };

        if (options.promote_config) |raw_config| {
            promotion_receipt = try promotion.promote(manager, raw_config, selections, options.summary);
        }
    }

    const mode: []const u8 = if (options.promote_config != null) "promote" else if (do_apply) "apply" else "preview";

    return std.json.parseFromSliceLeaky(Value, alloc, try encode(alloc, .{
        .version = "omos.capability-distill/v1",
        .mode = mode,
        .applied = do_apply,
        .workspace = manager.manifest.id,
        .task_id = task.id,
        .capability = options.capability_id,
        .realisation = realisation_id,
        .resource = resource_id,
        .name = derived_name,
        .description = derived_desc,
        .paths = portable.paths,
        .dependencies = options.dependencies,
        .depends_on = depends_on.items,
        .rubric = rubric,
        .generated_skill_md = portable.generated,
        .plan = .{
            .declaration_complete = plan.declaration_complete,
            .graph_hash = graph_hash,
            .definition_hash = candidate.hash,
            .paths = plan.paths,
            .external_dependencies = plan.external_dependencies,
            .problems = plan.problems,
        },
        .activation = activation,
        .promotion = promotion_receipt,
    }), .{});
}

// --- Tests ---

const TestEnv = struct {
    environ: std.process.Environ.Map,
    previous: ?*const std.process.Environ.Map,

    fn init(alloc: std.mem.Allocator, home: []const u8) !TestEnv {
        var env = std.process.Environ.Map.init(alloc);
        try env.put("HOME", home);
        if (io.getenv("PATH")) |p| try env.put("PATH", p);
        const prev = io.environMap();
        return .{ .environ = env, .previous = prev };
    }

    fn install(self: *const TestEnv) void {
        io.setEnvironMap(&self.environ);
    }

    fn restore(self: *const TestEnv) void {
        if (self.previous) |prev| io.setEnvironMap(prev) else io.setLibcEnviron();
    }
};

fn acceptPersonalTask(
    manager: workspace.Manager,
    alloc: std.mem.Allocator,
    task: workspace.Task,
    candidate_answer: []const u8,
) ![]const u8 {
    const rev = try manager.currentRevision(task);
    var reports: std.ArrayList(contract.Report) = .empty;
    for (task.definition.obligations) |ob| {
        try reports.append(alloc, .{
            .id = ob.id,
            .status = .met,
            .evidence = &.{"verified"},
            .note = "Met",
        });
    }
    const assess_json = try encode(alloc, .{
        .contractId = task.id,
        .version = task.definition.version,
        .obligations = reports.items,
    });
    return manager.publish(task, .{
        .task_id = task.id,
        .revision = rev,
        .contract_version = task.definition.version,
        .disposition = "fulfilled",
        .candidate = candidate_answer,
        .assessment = assess_json,
    });
}

test "capability distill rejects non-accepted, paused, and company-authority tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const env = try TestEnv.init(alloc, root);
    env.install();
    defer env.restore();
    const repo = try std.Io.Dir.path.join(alloc, &.{ root, "local.fossil" });
    var queue: workspace.WriterQueue = .{};
    defer queue.deinit();
    var manager = try workspace.Manager.init(alloc, repo);
    manager.writer_queue = &queue;

    // Active task is rejected.
    const active_task = try manager.start("sess-1", root, "Research invoice workflow", null);
    try std.testing.expectError(error.TaskNotAcceptedForDistill, distill(manager, .{
        .task_id = active_task.id,
        .capability_id = "invoice_review",
    }));

    // Paused task is rejected.
    const paused_task = try manager.setState(active_task.id, .paused);
    try std.testing.expectError(error.TaskNotAcceptedForDistill, distill(manager, .{
        .task_id = paused_task.id,
        .capability_id = "invoice_review",
    }));

    // Company-authority task is rejected cleanly.
    const company_lease = try manager.companyOperationLease();
    defer company_lease.release();
    var company_mgr = manager;
    company_mgr.company_operation_held = true;
    const company_task = try company_mgr.startCompany("sess-2", root, "Company scoped work", .{
        .actor = "actor_a",
        .grant = "grant_a",
    });
    try std.testing.expectError(error.TaskNotAcceptedForDistill, distill(manager, .{
        .task_id = company_task.id,
        .capability_id = "company_cap",
    }));

    // Invalid capability ID format is rejected.
    try std.testing.expectError(error.InvalidCapabilityId, distill(manager, .{
        .task_id = active_task.id,
        .capability_id = "Bad-Cap-Id",
    }));
}

test "capability distill extracts rubric and skill files while excluding private memory and preserves existing skill files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const env = try TestEnv.init(alloc, root);
    env.install();
    defer env.restore();
    const repo = try std.Io.Dir.path.join(alloc, &.{ root, "local.fossil" });
    var queue: workspace.WriterQueue = .{};
    defer queue.deinit();
    var manager = try workspace.Manager.init(alloc, repo);
    manager.writer_queue = &queue;

    // Start a personal task with specialist tools, plan checks, private memory research, and a authored skill.
    const selection = @import("realisation_selection.zig");
    var task = try manager.startWithAssignment("sess-research", root, "Build a repeatable invoice audit workflow", null, .{
        .capability = "general_task",
        .realisation = "general_task_native",
        .ranking = .{ .relevance = 0.9, .precedent = 0.5, .evidence = 1.0, .recency = 0.5, .score = 0.8 },
        .required_tools = &.{ "read_file", "write_file" },
        .declared_skills = &.{"invoice-audit"},
    });
    task = try manager.setPlan(
        task,
        "general_task",
        "Audit vendor invoices against PO totals and flag mismatches.",
        &.{.{ .id = "audit_rules", .description = "Verify tax and line item sums match purchase orders." }},
        &.{ "Check every invoice total matches sum of line items", "Verify vendor tax ID format" },
    );

    const private_research = "PRIVATE SCRATCHPAD: internal vendor salary notes and raw brainstorms";
    const authored_skill = "---\nname: invoice-audit\ndescription: User-authored invoice audit playbook.\n---\n# Invoice Audit\nCustom authored rules.\n";
    const helper_script = "#!/usr/bin/env python3\nprint('ok')\n";
    try manager.writeContent(task, "memory/private-research.md", private_research);
    try manager.writeContent(task, "skills/invoice-audit/SKILL.md", authored_skill);
    try manager.writeContent(task, "skills/invoice-audit/check.py", helper_script);
    _ = try acceptPersonalTask(manager, alloc, task, "Completed invoice audit playbook and verified checks.");

    const trunk_before = try manager.revision("trunk");

    // 1. Preview mode makes ZERO writes to Fossil and excludes memory/.
    const preview = try distill(manager, .{
        .task_id = task.id,
        .capability_id = "invoice_audit",
        .dependencies = &.{.{ .kind = .runtime, .handle = "python", .constraint = ">=3.10" }},
    });
    try std.testing.expectEqualStrings(trunk_before, try manager.revision("trunk"));
    try std.testing.expectEqualStrings("preview", model.text(preview, "mode"));
    try std.testing.expect(!model.field(preview, "applied").?.bool);
    try std.testing.expect(model.field(preview, "generated_skill_md").? == .null);
    const preview_paths = model.items(preview, "paths");
    try std.testing.expectEqual(@as(usize, 1), preview_paths.len);
    try std.testing.expectEqualStrings("skills/invoice-audit/", preview_paths[0].string);
    const preview_rubric = model.field(preview, "rubric").?;
    try std.testing.expectEqual(@as(usize, 2), model.items(preview_rubric, "checks").len);
    try std.testing.expectEqual(@as(usize, 2), model.items(preview_rubric, "required_tools").len);
    try std.testing.expect(model.field(model.field(preview, "plan").?, "declaration_complete").?.bool);

    // Explicit forbidden path (memory/) is rejected cleanly.
    try std.testing.expectError(error.DistillPathDenied, distill(manager, .{
        .task_id = task.id,
        .capability_id = "invoice_audit",
        .paths = &.{"memory/private-research.md"},
    }));

    // 2. Apply mode activates the additive declaration without clobbering the user-authored SKILL.md.
    const applied = try distill(manager, .{
        .task_id = task.id,
        .capability_id = "invoice_audit",
        .dependencies = &.{.{ .kind = .runtime, .handle = "python", .constraint = ">=3.10" }},
        .apply = true,
    });
    try std.testing.expectEqualStrings("apply", model.text(applied, "mode"));
    try std.testing.expect(model.field(applied, "applied").?.bool);
    try std.testing.expectEqualStrings(authored_skill, try manager.trunkContent("skills/invoice-audit/SKILL.md"));

    // package plan / inspect succeeds with declaration_complete == true and excludes memory/.
    const inspected = try package.inspect(manager, &.{.{ .capability = "invoice_audit" }});
    const inspected_plan = model.field(inspected, "plan").?;
    try std.testing.expect(model.field(inspected_plan, "declaration_complete").?.bool);
    const inspected_files = model.items(inspected_plan, "files");
    try std.testing.expectEqual(@as(usize, 2), inspected_files.len);
    for (inspected_files) |f| {
        try std.testing.expect(!std.mem.startsWith(u8, model.text(f, "path"), "memory/"));
    }

    // realisation_selection sees the new capability, its tools, and its declared skill!
    const decl_after = try manager.loadDeclaration("trunk");
    const tools = try selection.requiredToolsForRealisation(alloc, decl_after, "invoice_audit_skill");
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    const skills = try selection.declaredSkillsForRealisation(alloc, decl_after, "invoice_audit_skill");
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("invoice-audit", skills[0]);

    // 3. Colliding capability ID is rejected cleanly without modifying trunk.
    const trunk_after_apply = try manager.revision("trunk");
    try std.testing.expectError(error.CapabilityAlreadyExists, distill(manager, .{
        .task_id = task.id,
        .capability_id = "invoice_audit",
        .apply = true,
    }));
    try std.testing.expectEqualStrings(trunk_after_apply, try manager.revision("trunk"));
}

test "capability distill synthesizes a clean SKILL.md rubric when the task has no skill files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const env = try TestEnv.init(alloc, root);
    env.install();
    defer env.restore();
    const repo = try std.Io.Dir.path.join(alloc, &.{ root, "local.fossil" });
    var queue: workspace.WriterQueue = .{};
    defer queue.deinit();
    var manager = try workspace.Manager.init(alloc, repo);
    manager.writer_queue = &queue;

    // Research-only task that wrote only private memory notes and no skills/.
    var task = try manager.start("sess-pure", root, "Evaluate vendor SOC2 compliance questionnaires", null);
    task = try manager.setPlan(
        task,
        "general_task",
        "Verify SOC2 control evidence and summarize material gaps.",
        &.{.{ .id = "soc2_evidence", .description = "Cite control IDs and missing attestations." }},
        &.{"Check encryption at rest and access logging controls"},
    );
    try manager.writeContent(task, "memory/scratch.md", "SUPER SECRET PRIVATE NOTES");
    _ = try acceptPersonalTask(manager, alloc, task, "SOC2 rubric validated.");

    const trunk_before = try manager.revision("trunk");

    // Preview synthesizes SKILL.md in memory without touching trunk.
    const preview = try distill(manager, .{
        .task_id = task.id,
        .capability_id = "soc2_triage",
    });
    try std.testing.expectEqualStrings(trunk_before, try manager.revision("trunk"));
    const gen = model.field(preview, "generated_skill_md").?;
    try std.testing.expectEqualStrings("skills/soc2-triage/SKILL.md", model.text(gen, "path"));
    const content = model.text(gen, "content");
    try std.testing.expect(std.mem.find(u8, content, "Evaluate vendor SOC2 compliance questionnaires") != null);
    try std.testing.expect(std.mem.find(u8, content, "soc2_evidence") != null);
    try std.testing.expect(std.mem.find(u8, content, "Check encryption at rest and access logging controls") != null);
    try std.testing.expect(std.mem.find(u8, content, "SUPER SECRET PRIVATE NOTES") == null);

    // Apply writes skills/soc2-triage/SKILL.md + activates declaration atomically.
    const applied = try distill(manager, .{
        .task_id = task.id,
        .capability_id = "soc2_triage",
        .apply = true,
    });
    try std.testing.expect(model.field(applied, "applied").?.bool);
    try std.testing.expectEqualStrings(content, try manager.trunkContent("skills/soc2-triage/SKILL.md"));

    // package inspect and local export immediately succeed with declaration_complete == true.
    const inspected = try package.inspect(manager, &.{.{ .capability = "soc2_triage" }});
    try std.testing.expect(model.field(model.field(inspected, "plan").?, "declaration_complete").?.bool);
    const archive_path = try std.Io.Dir.path.join(alloc, &.{ root, "soc2.tar" });
    const exported = try promotion.exportArchive(manager, &.{.{ .capability = "soc2_triage" }}, archive_path);
    try std.testing.expectEqual(@as(i64, 1), model.field(exported, "files").?.integer);
}

const TestCompanyHttpServer = struct {
    central_mgr: workspace.Manager,
    listener: std.Io.net.Server,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *TestCompanyHttpServer) void {
        while (!self.stop.load(.acquire)) {
            var stream = self.listener.accept(io.getIo()) catch break;
            defer stream.close(io.getIo());
            if (self.stop.load(.acquire)) break;
            self.handle(&stream) catch {};
        }
    }

    fn handle(self: *TestCompanyHttpServer, stream: *std.Io.net.Stream) !void {
        var req_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer req_arena.deinit();
        const alloc = req_arena.allocator();

        var raw: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        var reader = stream.reader(io.getIo(), &buf);

        while (true) {
            const byte = reader.interface.takeByte() catch return;
            try raw.append(alloc, byte);
            if (raw.items.len > 65536) return;
            if (raw.items.len >= 4 and std.mem.eql(u8, raw.items[raw.items.len - 4 ..], "\r\n\r\n")) break;
        }
        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, raw.items[0 .. raw.items.len - 4], "\r\n");
        const req_line = lines.next() orelse return;
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const val = std.mem.trim(u8, line["content-length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }
        const body = try alloc.alloc(u8, content_length);
        if (content_length > 0) {
            try reader.interface.readSliceAll(body);
        }

        var mgr = self.central_mgr;
        mgr.alloc = alloc;
        const company_svc = @import("company_service.zig");
        const reply_body = if (std.mem.startsWith(u8, req_line, "GET /v1/company"))
            try company_svc.bootstrap(mgr)
        else if (std.mem.startsWith(u8, req_line, "POST /v1/company"))
            try company_svc.execute(mgr, body, true)
        else
            "{\"error\":\"not_found\"}";

        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io.getIo(), &wbuf);
        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{reply_body.len});
        try writer.interface.writeAll(reply_body);
        try writer.interface.flush();
    }
};

test "capability distill end-to-end: accepted local task -> distill --promote -> central approval -> Actor B discovers and exports with zero private memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    const env = try TestEnv.init(alloc, root);
    env.install();
    defer env.restore();

    const local_repo = try std.Io.Dir.path.join(alloc, &.{ root, "local.fossil" });
    const central_repo = try std.Io.Dir.path.join(alloc, &.{ root, "central.fossil" });
    var local_queue: workspace.WriterQueue = .{};
    defer local_queue.deinit();
    var central_queue: workspace.WriterQueue = .{};
    defer central_queue.deinit();
    var local_mgr = try workspace.Manager.init(alloc, local_repo);
    local_mgr.writer_queue = &local_queue;
    var central_mgr = try workspace.Manager.init(alloc, central_repo);
    central_mgr.writer_queue = &central_queue;

    // 1. Initialize central company authority and enroll Actor A (promote_capability) & Actor B (discover + export_scope).
    const company_svc = @import("company_service.zig");
    const identity_mod = @import("company_identity.zig");

    _ = try company_svc.administer(central_mgr, "{\"version\":\"omos.company-admin/v1\",\"action\":\"initialize\"}");
    const status_val = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, "{\"version\":\"omos.company-admin/v1\",\"action\":\"status\"}"), .{});
    const bootstrap_val = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.bootstrap(central_mgr), .{});
    const issuer_pub = model.text(bootstrap_val, "issuer");
    var admin_rev = model.text(status_val, "revision");

    var key_nonce: [8]u8 = undefined;
    io.getIo().random(&key_nonce);
    const key_handle = try alloc.print("distill-e2e-{s}", .{std.fmt.bytesToHex(&key_nonce, .lower)});
    const actor_a_id = try identity_mod.create(alloc, key_handle);
    const kp_b = std.crypto.sign.Ed25519.KeyPair.generate(io.getIo());
    const pub_b = try alloc.dupe(u8, &std.fmt.bytesToHex(kp_b.public_key.toBytes(), .lower));

    const expires = io.milliTimestamp() + 3_600_000;
    const grant_a_res = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "grant",
        .revision = admin_rev,
        .grant = authority.Grant{
            .id = "grant_a_distill",
            .actor = "actor_a",
            .public_key = actor_a_id.public_key,
            .paths = &.{"skills/"},
            .actions = &.{ .create_view, .checkpoint, .status, .promote_capability },
            .expires_ms = expires,
            .human_approval = false,
        },
    })), .{});
    admin_rev = model.text(grant_a_res, "revision");

    const grant_b_res = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "grant",
        .revision = admin_rev,
        .grant = authority.Grant{
            .id = "grant_b_consumer",
            .actor = "actor_b",
            .public_key = pub_b,
            .paths = &.{"skills/"},
            .actions = &.{ .discover, .export_scope },
            .expires_ms = expires,
            .human_approval = false,
        },
    })), .{});
    admin_rev = model.text(grant_b_res, "revision");

    // 2. Complete an accepted local personal task containing BOTH private research in memory/ AND a portable skill in skills/.
    var task = try local_mgr.start("sess-e2e", root, "Build a quarterly compliance report capability", null);
    task = try local_mgr.setPlan(
        task,
        "general_task",
        "Generate quarterly compliance checklist and verify control signoffs.",
        &.{.{ .id = "signoff_check", .description = "Verify every control has an owner and timestamp." }},
        &.{"Confirm all mandatory compliance controls are signed"},
    );
    const private_notes = "CONFIDENTIAL LOCAL RESEARCH: never leave local workspace";
    const skill_body = "---\nname: quarterly-compliance\ndescription: Quarterly compliance checklist playbook.\n---\n# Quarterly Compliance\nFollow every verification step.\n";
    try local_mgr.writeContent(task, "memory/private-notes.md", private_notes);
    try local_mgr.writeContent(task, "skills/quarterly-compliance/SKILL.md", skill_body);
    _ = try acceptPersonalTask(local_mgr, alloc, task, "Quarterly compliance playbook ready.");

    // 3. Start loopback HTTP server for central company service.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: TestCompanyHttpServer = .{
        .central_mgr = central_mgr,
        .listener = try addr.listen(io.getIo(), .{ .reuse_address = true }),
    };
    const port = server.listener.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, TestCompanyHttpServer.run, .{&server});
    defer {
        server.stop.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |wake_addr| {
            if (wake_addr.connect(io.getIo(), .{ .mode = .stream })) |stream| {
                stream.close(io.getIo());
            } else |_| {}
        } else |_| {}
        thread.join();
        server.listener.deinit(io.getIo());
    }

    // 4. Run distill with promote_config in one shot!
    const promote_cfg = try encode(alloc, .{
        .version = "omos.capability-promote-request/v1",
        .endpoint = try alloc.print("http://127.0.0.1:{d}", .{port}),
        .workspace = central_mgr.manifest.id,
        .actor = "actor_a",
        .grant = "grant_a_distill",
        .key_handle = key_handle,
        .issuer = issuer_pub,
    });
    const result = try distill(local_mgr, .{
        .task_id = task.id,
        .capability_id = "quarterly_compliance",
        .apply = true,
        .promote_config = promote_cfg,
        .summary = "Promote distilled quarterly_compliance capability",
    });

    try std.testing.expectEqualStrings("promote", model.text(result, "mode"));
    try std.testing.expect(model.field(result, "applied").?.bool);
    const promo = model.field(result, "promotion").?;
    try std.testing.expectEqualStrings("approval_required", model.text(promo, "state"));
    try std.testing.expect(model.field(promo, "approval_required").?.bool);
    try std.testing.expectEqual(@as(i64, 1), model.field(promo, "files").?.integer);
    const view_id = model.text(promo, "view");

    // 5. Central operator inspects proposal (confirming zero memory/ files!), approves, and independent review publishes it.
    const status_after_promo = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, "{\"version\":\"omos.company-admin/v1\",\"action\":\"status\"}"), .{});
    admin_rev = model.text(status_after_promo, "revision");
    const insp = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "inspect_proposal",
        .revision = admin_rev,
        .view = view_id,
    })), .{});
    const cand = model.field(insp, "candidate").?;
    const central_task_id = model.text(cand, "task");
    const cand_hash = model.text(insp, "candidate_hash");
    const staged_task = try central_mgr.loadTask(central_task_id);
    const staged_changed = try central_mgr.changedPaths(staged_task.base_revision, try central_mgr.revision(staged_task.branch));
    var staged_skill_seen = false;
    for (staged_changed) |changed_path| {
        try std.testing.expect(!std.mem.startsWith(u8, changed_path, "memory/"));
        if (std.mem.eql(u8, changed_path, "skills/quarterly-compliance/SKILL.md")) staged_skill_seen = true;
    }
    try std.testing.expect(staged_skill_seen);

    const approved = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "approve",
        .revision = admin_rev,
        .view = view_id,
        .candidate_hash = cand_hash,
        .expires_ms = io.milliTimestamp() + 300_000,
    })), .{});
    admin_rev = model.text(approved, "revision");

    const central_task = try central_mgr.loadTask(central_task_id);
    _ = try central_mgr.claimReview("distill-e2e-reviewer");
    const job = try central_mgr.loadReviewJob(central_task, central_task.review_job.?);
    var pub_mgr = central_mgr;
    pub_mgr.review_fence = .{ .task = central_task.id, .job = job.id, .generation = job.generation, .owner = job.owner };
    const assess_central = try encode(alloc, .{
        .contractId = central_task.id,
        .version = central_task.definition.version,
        .obligations = &.{.{ .id = "request_complete", .status = "met", .evidence = &.{"skills/quarterly-compliance/SKILL.md"}, .note = "Verified" }},
    });
    _ = try pub_mgr.publish(central_task, .{
        .task_id = central_task.id,
        .revision = try pub_mgr.revision(central_task.branch),
        .contract_version = central_task.definition.version,
        .disposition = "fulfilled",
        .candidate = "Promote distilled quarterly_compliance capability",
        .assessment = assess_central,
    });

    // Confirm central trunk has the distilled capability + skill and ZERO private memory!
    try std.testing.expectEqualStrings(skill_body, try central_mgr.trunkContent("skills/quarterly-compliance/SKILL.md"));
    try std.testing.expectError(error.FossilCommandFailed, central_mgr.trunkContent("memory/private-notes.md"));

    // 6. Operator grants Actor B metadata access to quarterly_compliance -> Actor B discovers and exports it!
    const status_after_pub = try std.json.parseFromSliceLeaky(Value, alloc, try company_svc.administer(central_mgr, "{\"version\":\"omos.company-admin/v1\",\"action\":\"status\"}"), .{});
    admin_rev = model.text(status_after_pub, "revision");
    _ = try company_svc.administer(central_mgr, try encode(alloc, .{
        .version = "omos.company-admin/v1",
        .action = "grant_capabilities",
        .revision = admin_rev,
        .id = "grant_b_consumer",
        .capabilities = &.{"quarterly_compliance"},
    }));

    const req_expires = io.milliTimestamp() + 60_000;
    const call_b_payload = try encode(alloc, .{
        .version = "omos.company/v2",
        .workspace = central_mgr.manifest.id,
        .actor = "actor_b",
        .grant = "grant_b_consumer",
        .operation = "op-b-export-distilled",
        .expires_ms = req_expires,
        .action = "export_scope",
        .revision = try central_mgr.revision("trunk"),
        .capability = "quarterly_compliance",
        .capability_selections = &.{.{ .capability = "quarterly_compliance" }},
    });
    const sig_b = try kp_b.sign(call_b_payload, null);
    const env_b = try encode(alloc, .{ .payload = call_b_payload, .signature = &std.fmt.bytesToHex(sig_b.toBytes(), .lower) });
    const raw_b = try company_svc.execute(central_mgr, env_b, false);
    const parsed_b = try std.json.parseFromSliceLeaky(Value, alloc, raw_b, .{});
    const claims_b = try std.json.parseFromSliceLeaky(Value, alloc, model.text(parsed_b, "payload"), .{});
    const b_export = model.field(claims_b, "result").?;
    try std.testing.expectEqualStrings("declared_complete", model.text(b_export, "dependency_closure"));
    try std.testing.expectEqual(@as(i64, 1), model.field(b_export, "total").?.integer);
}
