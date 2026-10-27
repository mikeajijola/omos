//! Shared OmniForm declarations and the explicitly versioned native host profile.
const std = @import("std");
const sort_utils = @import("../shared/sort_utils.zig");
const schema = @import("declaration_schema.zig");
const record_json = @import("../shared/record_json.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const profile_id = "omos.workspace/v1";
pub const standard_version = "1.0.0-alpha.7";
pub const declaration_path = "omniform/company.json";
pub const execution_path = "execution/omos.json";
pub const seed = compactJson(@embedFile("standard/omos.json"));
pub const initial_declaration = seed;
const standard_schema = compactJson(@embedFile("standard/omniform.schema.json"));

// Keep the pinned source files readable while embedding only JSON token bytes.
fn compactJson(comptime source: []const u8) []const u8 {
    const compact = comptime blk: {
        @setEvalBranchQuota(@max(200000, source.len * 2));
        var bytes: [source.len]u8 = undefined;
        var length: usize = 0;
        var quoted = false;
        var escaped = false;
        for (source) |byte| {
            if (!quoted and (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n')) continue;
            bytes[length] = byte;
            length += 1;
            if (escaped) {
                escaped = false;
            } else if (quoted and byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                quoted = !quoted;
            }
        }
        break :blk bytes[0..length].*;
    };
    return &compact;
}

pub const Policy = struct {
    progress_interval: usize = 4,
    stalled_checks: usize = 3,
    max_actor_steps: usize = 100,
};
pub const ReviewPolicy = struct {
    pub const legacy: ReviewPolicy = .{ .reserved_calls = 1, .response_timeout_ms = 60_000, .attempt_timeout_ms = 60_000, .max_attempts = 1, .total_timeout_ms = 60_000 };
    max_calls: usize = 8,
    reserved_calls: usize = 2,
    response_timeout_ms: u32 = 120_000,
    attempt_timeout_ms: u32 = 300_000,
    max_attempts: usize = 3,
    total_timeout_ms: u32 = 900_000,
    max_context_bytes: usize = 512 * 1024,
    max_read_bytes: usize = 16 * 1024,
    max_tokens: ?u64 = null,

    pub fn validate(self: ReviewPolicy) !void {
        if (self.max_tokens) |limit| if (limit == 0 or limit > 4_000_000) return error.InvalidExecutionPolicy;
        if (self.max_calls < 3 or self.max_calls > 64 or self.reserved_calls == 0 or self.reserved_calls >= self.max_calls or
            self.response_timeout_ms < 1000 or self.response_timeout_ms > self.attempt_timeout_ms or
            self.attempt_timeout_ms > self.total_timeout_ms or self.total_timeout_ms > 3_600_000 or
            self.max_attempts == 0 or self.max_attempts > 20 or self.max_context_bytes < 16 * 1024 or self.max_context_bytes > 512 * 1024 or
            self.max_read_bytes < 256 or self.max_read_bytes > 16 * 1024) return error.InvalidExecutionPolicy;
    }
};
pub const ServerPolicy = struct {
    review_workers: usize = 2,
    validation_handle: ?[]const u8 = null,

    pub fn jsonStringify(self: ServerPolicy, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("review_workers");
        try writer.write(self.review_workers);
        if (self.validation_handle) |handle| {
            try writer.objectField("validation_handle");
            try writer.write(handle);
        }
        try writer.endObject();
    }
};

pub const ProjectionPolicy = struct { max_clean_bytes: u64 = 256 * 1024 * 1024, max_clean_views: usize = 32 };

pub const Execution = struct {
    version: []const u8 = "omos.execution/v1",
    defaults: Policy = .{},
    review: ReviewPolicy = ReviewPolicy.legacy,
    server: ?ServerPolicy = null,
    projections: ?ProjectionPolicy = null,

    pub fn reviewWorkers(self: Execution) usize {
        return if (self.server) |server| server.review_workers else 1;
    }

    pub fn validationHandle(self: Execution) []const u8 {
        return if (self.server) |server| server.validation_handle orelse "company-default" else "company-default";
    }

    // Preserve hashes of pre-server policies embedded in existing task bases.
    pub fn jsonStringify(self: Execution, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("version");
        try writer.write(self.version);
        try writer.objectField("defaults");
        try writer.write(self.defaults);
        try writer.objectField("review");
        try writer.write(self.review);
        if (self.server) |server| {
            try writer.objectField("server");
            try writer.write(server);
        }
        if (self.projections) |projections| {
            try writer.objectField("projections");
            try writer.write(projections);
        }
        try writer.endObject();
    }
};
pub const Entity = struct { id: []const u8, fields: Value = .null, required: []const []const u8 = &.{}, indexed: []const []const u8 = &.{} };
const Relationship = struct { id: []const u8, from: []const u8, to: []const u8, kind: enum { containment, dependency, applicability, provenance }, inheritScope: bool = false };
const Scope = struct { id: []const u8, entityType: []const u8, parent: ?[]const u8 = null, permissions: []const enum { discover, view, @"export" } = &.{ .discover, .view } };
const Hierarchy = struct { capability: []const u8, parent: ?[]const u8 = null, dependsOn: []const []const u8 = &.{} };
const Search = struct {
    version: u8 = 1,
    traversal: []const []const u8 = &.{},
    maxDepth: u8 = 4,
    ranking: struct { relevance: f64 = 0.5, precedent: f64 = 0.2, evidence: f64 = 0.2, recency: f64 = 0.1 } = .{},
};
pub const Semantic = struct {
    version: []const u8 = "omniseedos.semantic/v1",
    capabilityHierarchy: []const Hierarchy = &.{},
    entityTypes: []const Entity = &.{},
    relationships: []const Relationship = &.{},
    scopes: []const Scope = &.{},
    migration: ?Value = null,
    search: Search = .{},
};
pub const Report = struct { valid: bool, profile: []const u8 = profile_id, standard: []const u8 = standard_version, errors: []const []const u8 = &.{}, hash: ?[]const u8 = null };
pub const Basis = struct {
    profile: []const u8 = profile_id,
    definition_hash: []const u8,
    revision: []const u8,
    execution: Execution,
    execution_hash: ?[]const u8 = null,
    capability: ?[]const u8 = null,
};
pub const Declaration = struct { value: Value, hash: []const u8, semantic: Semantic };

/// Planning selects native task capabilities. Transport and record schemas stay
/// in the pinned declaration and remain enforced by the host on every operation.
pub fn planningSnapshot(alloc: Allocator, basis: Basis, declaration: Declaration) !Value {
    const selected = spec(declaration.value);
    const bytes = try std.json.Stringify.valueAlloc(alloc, .{
        .basis = basis,
        .declarationReference = .{ .path = declaration_path, .revision = basis.revision, .sha256 = declaration.hash },
        .projection = "task_planning_capabilities",
        .declaration = .{
            .apiVersion = field(declaration.value, "apiVersion"),
            .kind = field(declaration.value, "kind"),
            .metadata = field(declaration.value, "metadata"),
            .spec = .{
                .capabilities = field(selected, "capabilities"),
                .resources = field(selected, "resources"),
                .realisations = field(selected, "realisations"),
            },
        },
    }, .{});
    return (try std.json.parseFromSlice(Value, alloc, bytes, .{})).value;
}

pub fn field(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
pub fn items(value: Value, name: []const u8) []const Value {
    const child = field(value, name) orelse return &.{};
    return if (child == .array) child.array.items else &.{};
}
pub fn text(value: Value, name: []const u8) []const u8 {
    const child = field(value, name) orelse return "";
    return if (child == .string) child.string else "";
}
pub fn spec(value: Value) Value {
    return field(value, "spec") orelse .null;
}

pub fn validate(alloc: Allocator, bytes: []const u8) !Report {
    const declaration = parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .valid = false, .errors = try alloc.dupe([]const u8, &.{@errorName(err)}) },
    };
    return .{ .valid = true, .hash = declaration.hash };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Declaration {
    if (bytes.len > 1_000_000) return error.DeclarationTooLarge;
    const value = (try std.json.parseFromSlice(Value, alloc, bytes, .{ .allocate = .alloc_always })).value;
    var count: usize = 0;
    try schema.boundary(value, 0, &count);
    try publicData(value);
    const upstream_schema = (try std.json.parseFromSlice(Value, alloc, standard_schema, .{})).value;
    var source: std.json.ObjectMap = .empty;
    var declaration_spec: std.json.ObjectMap = .empty;
    if (value != .object or spec(value) != .object) return error.InvalidWorkspaceDefinition;
    var iterator = spec(value).object.iterator();
    while (iterator.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "semantic")) try declaration_spec.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    iterator = value.object.iterator();
    while (iterator.next()) |entry| try source.put(alloc, entry.key_ptr.*, if (std.mem.eql(u8, entry.key_ptr.*, "spec")) .{ .object = declaration_spec } else entry.value_ptr.*);
    if (!(try schema.validate(alloc, upstream_schema, .{ .object = source })).valid) return error.InvalidOmniformDeclaration;
    if (field(spec(value), "governance") != null) return error.UnsupportedGitGovernance;
    if (field(spec(value), "stewardship")) |stewardship| if (field(stewardship, "autonomy") != null) return error.UnsupportedGitStewardship;
    try references(alloc, value);
    const semantic_raw = field(spec(value), "semantic");
    if (semantic_raw) |raw| {
        if (field(raw, "version") == null) return error.MissingSemanticVersion;
        if (field(raw, "search")) |search| {
            const ranking = field(search, "ranking") orelse return error.MissingSearchRanking;
            for ([_][]const u8{ "relevance", "precedent", "evidence", "recency" }) |key| if (field(ranking, key) == null) return error.MissingSearchRanking;
        }
        for (items(raw, "entityTypes")) |entity| if (field(entity, "fields")) |fields| {
            if (fields == .null) return error.InvalidEntityFields;
        };
        for ([_][]const u8{ "scopes", "capabilityHierarchy" }) |key| for (items(raw, key)) |row| if (field(row, "parent")) |parent| {
            if (parent == .null) return error.InvalidSemanticParent;
        };
    }
    const semantic = if (semantic_raw) |raw| (try std.json.parseFromValue(Semantic, alloc, raw, .{})).value else Semantic{};
    try semantics(alloc, value, semantic);
    try migration(alloc, semantic);
    for (items(spec(value), "operations")) |operation| {
        try schema.supported(alloc, field(operation, "input").?);
        try schema.supported(alloc, field(operation, "output").?);
        if (std.mem.eql(u8, text(operation, "approval"), "required")) return error.UnsupportedOperationApproval;
    }
    return .{ .value = value, .hash = try digest(alloc, value), .semantic = semantic };
}

pub fn parseExecution(alloc: Allocator, bytes: []const u8) !Execution {
    const execution = try record_json.decode(Execution, alloc, bytes, .{});
    const p = execution.defaults;
    if (!std.mem.eql(u8, execution.version, "omos.execution/v1") or p.progress_interval == 0 or p.progress_interval > 100 or p.stalled_checks == 0 or p.stalled_checks > 20 or p.max_actor_steps < 2 or p.max_actor_steps > 10000) return error.InvalidExecutionPolicy;
    if (execution.reviewWorkers() < 1 or execution.reviewWorkers() > 4) return error.InvalidExecutionPolicy;
    if (execution.server) |server| if (server.validation_handle) |handle| {
        if (handle.len == 0 or handle.len > 128) return error.InvalidExecutionPolicy;
        for (handle) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidExecutionPolicy;
    };
    if (execution.projections) |pinned| if (pinned.max_clean_views > 1024 or pinned.max_clean_bytes > 4 * 1024 * 1024 * 1024) return error.InvalidExecutionPolicy;
    try execution.review.validate();
    return execution;
}

/// Automatic activation may tighten execution allowances, never enlarge them.
pub fn compatibleExecution(old: Execution, next: Execution) bool {
    const a = old.defaults;
    const b = next.defaults;
    const x = old.review;
    const y = next.review;
    if (!std.mem.eql(u8, old.validationHandle(), next.validationHandle())) return false;
    return next.reviewWorkers() <= old.reviewWorkers() and b.max_actor_steps <= a.max_actor_steps and b.progress_interval <= a.progress_interval and b.stalled_checks <= a.stalled_checks and
        y.max_calls <= x.max_calls and y.reserved_calls >= x.reserved_calls and y.response_timeout_ms <= x.response_timeout_ms and
        y.attempt_timeout_ms <= x.attempt_timeout_ms and y.max_attempts <= x.max_attempts and y.total_timeout_ms <= x.total_timeout_ms and
        y.max_context_bytes <= x.max_context_bytes and y.max_read_bytes <= x.max_read_bytes and
        (if (x.max_tokens) |limit| if (y.max_tokens) |next_limit| next_limit <= limit else false else true);
}

test "workspace declaration review policy bounds deadlines and reserves decision capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const policy = try parseExecution(alloc, "{\"review\":{\"max_calls\":12,\"reserved_calls\":2}}");
    try std.testing.expectEqual(@as(usize, 12), policy.review.max_calls);
    for ([_][]const u8{
        "{\"review\":{\"max_calls\":2}}",
        "{\"review\":{\"reserved_calls\":8}}",
        "{\"review\":{\"response_timeout_ms\":300001}}",
        "{\"review\":{\"max_read_bytes\":16385}}",
        "{\"review\":{\"unknown\":1}}",
    }) |raw| {
        if (parseExecution(alloc, raw)) |_| return error.ExpectedInvalidPolicy else |_| {}
    }
}

test "workspace declaration execution compatibility preserves legacy limits and rejects allowance escalation" {
    const old: Execution = .{ .review = .{} };
    var next = old;
    next.review.max_calls += 1;
    try std.testing.expect(!compatibleExecution(old, next));
    next = old;
    next.defaults.max_actor_steps = 3;
    try std.testing.expect(compatibleExecution(old, next));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const legacy_execution = try parseExecution(arena.allocator(), "{}");
    try std.testing.expectEqual(@as(u32, 60_000), legacy_execution.review.attempt_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), legacy_execution.review.max_attempts);
}

test "workspace declaration validates action subcontracts against pinned operation schemas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const declaration = try parse(alloc, seed);
    const valid = (try std.json.parseFromSlice(Value, alloc, "{\"calls\":[{\"id\":\"call-1\",\"name\":\"shell\",\"arguments\":\"{}\"}]}", .{})).value;
    try validateOperation(alloc, declaration, "omos_record_action", valid, .input);
    const invalid = (try std.json.parseFromSlice(Value, alloc, "{\"calls\":[{\"name\":\"shell\"}]}", .{})).value;
    try std.testing.expectError(error.InvalidOperationRecord, validateOperation(alloc, declaration, "omos_record_action", invalid, .input));
    try std.testing.expectError(error.UnknownOperation, validateOperation(alloc, declaration, "unadvertised", valid, .input));
}

test "workspace declaration contract upgrades are additive and repeatable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const current = try parse(alloc, seed);
    const first = try upgrade(alloc, current);
    const second = try upgrade(alloc, first);
    try std.testing.expectEqualStrings(current.hash, first.hash);
    try std.testing.expectEqualStrings(first.hash, second.hash);
    try std.testing.expect(try compatible(alloc, current, second));
}

/// Schemas belong to the pinned declaration; older tasks retain their legacy adapter.
pub fn validateOperation(alloc: Allocator, declaration: Declaration, id: []const u8, value: Value, direction: enum { input, output }) !void {
    const operation = named(items(spec(declaration.value), "operations"), id) orelse return error.UnknownOperation;
    const shape = field(operation, @tagName(direction)) orelse return error.InvalidOperationContract;
    if (!(try schema.validate(alloc, shape, value)).valid) return error.InvalidOperationRecord;
}

pub fn hasOperation(declaration: Declaration, id: []const u8) bool {
    return named(items(spec(declaration.value), "operations"), id) != null;
}

/// Explicit migration adds native contracts and extends known transport schemas.
/// Existing task bases and the strict proposal compatibility rule stay unchanged.
pub fn upgrade(alloc: Allocator, previous: Declaration) !Declaration {
    var value = (try std.json.parseFromSlice(Value, alloc, try canonical(alloc, previous.value), .{})).value;
    const native = try parse(alloc, seed);
    var comparison = (try std.json.parseFromSlice(Value, alloc, try canonical(alloc, previous.value), .{})).value;
    const comparison_operations = comparison.object.getPtr("spec").?.object.getPtr("operations").?;
    const root = value.object.getPtr("spec").?;
    const operations = root.object.getPtr("operations").?;
    for (items(spec(native.value), "operations")) |operation| {
        const existing = for (operations.array.items, 0..) |row, index| {
            if (std.mem.eql(u8, text(row, "id"), text(operation, "id"))) break index;
        } else null;
        if (existing) |index| {
            if (try extendNativeTransport(alloc, &operations.array.items[index], operation)) {
                // Only the explicit migrator permits these bounded transport
                // extensions. Definition proposals still compare whole schemas.
                for (comparison_operations.array.items) |*row| if (std.mem.eql(u8, text(row.*, "id"), text(operation, "id"))) {
                    row.* = operations.array.items[index];
                    break;
                };
            }
        } else try operations.array.append(operation);
    }
    if (root.object.get("semantic") == null) try root.object.put(alloc, "semantic", .{ .object = .empty });
    const semantic = root.object.getPtr("semantic").?;
    if (semantic.object.get("version") == null) try semantic.object.put(alloc, "version", .{ .string = "omniseedos.semantic/v1" });
    for ([_][]const u8{ "entityTypes", "relationships" }) |key| {
        if (semantic.object.get(key) == null) try semantic.object.put(alloc, key, .{ .array = .init(alloc) });
        const rows = semantic.object.getPtr(key).?;
        for (items(field(spec(native.value), "semantic").?, key)) |addition| {
            const existing = for (rows.array.items) |*row| {
                if (std.mem.eql(u8, text(row.*, "id"), text(addition, "id"))) break row;
            } else null;
            if (existing) |row| {
                if (!std.mem.eql(u8, key, "entityTypes")) continue;
                if (row.object.get("fields") == null) try row.object.put(alloc, "fields", .{ .object = .empty });
                const fields = row.object.getPtr("fields").?;
                var it = field(addition, "fields").?.object.iterator();
                while (it.next()) |entry| if (!fields.object.contains(entry.key_ptr.*)) try fields.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
            } else try rows.array.append(addition);
        }
    }
    const result = try parse(alloc, try canonical(alloc, value));
    if (!try compatible(alloc, try parse(alloc, try canonical(alloc, comparison)), result)) return error.IncompatibleContractMigration;
    return result;
}

fn extendNativeTransport(alloc: Allocator, operation: *Value, native: Value) !bool {
    const id = text(operation.*, "id");
    if (!std.mem.eql(u8, id, "omos_company_operation") and !std.mem.eql(u8, id, "omos_company_capability") and !std.mem.eql(u8, id, "omos_export_scope") and !std.mem.eql(u8, id, "omos_verify_scope")) return false;
    var changed = false;
    for ([_][]const u8{ "input", "output" }) |direction| {
        const shape = operation.object.getPtr(direction) orelse continue;
        const native_shape = field(native, direction) orelse continue;
        if (!std.mem.eql(u8, text(shape.*, "type"), "object")) continue;
        const properties = shape.object.getPtr("properties") orelse continue;
        const native_properties = field(native_shape, "properties") orelse continue;
        if (properties.* != .object or native_properties != .object) continue;
        var entries = native_properties.object.iterator();
        while (entries.next()) |entry| {
            const key = entry.key_ptr.*;
            if (properties.object.getPtr(key)) |existing| {
                // Recognize only the minimal native version constraints. Other
                // constraints, company field types and required lists survive.
                if (!std.mem.eql(u8, key, "version") or existing.* != .object or existing.object.count() != 1) continue;
                const versions = field(entry.value_ptr.*, "enum") orelse continue;
                if (versions != .array) continue;
                var recognized = false;
                if (field(existing.*, "const")) |old_version| {
                    recognized = old_version == .string and contains(versions.array.items, old_version.string);
                } else if (field(existing.*, "enum")) |old_versions| {
                    if (old_versions == .array and old_versions.array.items.len > 0) {
                        recognized = true;
                        for (old_versions.array.items) |old_version| if (old_version != .string or !contains(versions.array.items, old_version.string)) {
                            recognized = false;
                            break;
                        };
                    }
                }
                if (recognized and !std.mem.eql(u8, try canonical(alloc, existing.*), try canonical(alloc, entry.value_ptr.*))) {
                    existing.* = entry.value_ptr.*;
                    changed = true;
                }
            } else if (!contains(items(native_shape, "required"), key) and !contains(items(shape.*, "required"), key)) {
                try properties.object.put(alloc, key, entry.value_ptr.*);
                changed = true;
            }
        }
    }
    return changed;
}

fn publicData(value: Value) anyerror!void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                var normalized: [64]u8 = undefined;
                var used: usize = 0;
                for (entry.key_ptr.*) |byte| {
                    if (byte == '_' or byte == '-') continue;
                    if (used == normalized.len) break;
                    normalized[used] = std.ascii.toLower(byte);
                    used += 1;
                }
                for ([_][]const u8{ "secret", "apikey", "clientsecret", "password", "privatekey", "accesstoken", "refreshtoken", "token", "credentials", "credential" }) |name| if (std.mem.eql(u8, name, normalized[0..used])) return error.SecretLiteralForbidden;
                try publicData(entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |item| try publicData(item),
        else => {},
    }
}

fn named(rows: []const Value, id: []const u8) ?Value {
    for (rows) |row| if (std.mem.eql(u8, text(row, "id"), id)) return row;
    return null;
}
fn contains(values: []const Value, id: []const u8) bool {
    for (values) |value| if (value == .string and std.mem.eql(u8, value.string, id)) return true;
    return false;
}

fn references(alloc: Allocator, value: Value) !void {
    const definition = spec(value);
    const capabilities = items(definition, "capabilities");
    const realisations = items(definition, "realisations");
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var resources: std.StringHashMapUnmanaged(Value) = .empty;
    for (capabilities) |capability| {
        if ((try ids.getOrPut(alloc, text(capability, "id"))).found_existing) return error.DuplicateDefinitionIdentity;
        var requirements: std.StringHashMapUnmanaged(void) = .empty;
        for (items(capability, "requires")) |requirement| if ((try requirements.getOrPut(alloc, text(requirement, "id"))).found_existing) return error.DuplicateCapabilityRequirement;
    }
    if (field(definition, "resources")) |families| {
        var it = families.object.iterator();
        while (it.next()) |family| for (family.value_ptr.array.items) |resource| {
            const id = text(resource, "id");
            if ((try ids.getOrPut(alloc, id)).found_existing) return error.DuplicateDefinitionIdentity;
            try resources.put(alloc, id, resource);
        };
    }
    for (realisations) |realisation| {
        if ((try ids.getOrPut(alloc, text(realisation, "id"))).found_existing) return error.DuplicateDefinitionIdentity;
        const capability = named(capabilities, text(realisation, "capability")) orelse return error.UnknownCapability;
        for (items(realisation, "participants")) |participant| {
            const resource = resources.get(text(participant, "resource")) orelse return error.UnknownResource;
            for (items(participant, "supplies")) |supply| {
                _ = named(items(capability, "requires"), supply.string) orelse return error.UnknownCapabilityRequirement;
                if (!contains(items(resource, "offers"), supply.string)) return error.ResourceDoesNotSupplyRequirement;
            }
        }
    }
    for (capabilities) |capability| {
        if (field(capability, "realisation")) |legacy| for (items(legacy, "resources")) |resource| {
            if (!resources.contains(resource.string)) return error.UnknownResource;
        };
        for (items(capability, "realisations")) |ref| {
            const realisation = named(realisations, ref.string) orelse return error.UnknownRealisation;
            if (!std.mem.eql(u8, text(realisation, "capability"), text(capability, "id"))) return error.RealisationCapabilityMismatch;
        }
    }
    for (items(definition, "operations")) |operation| {
        if ((try ids.getOrPut(alloc, text(operation, "id"))).found_existing) return error.DuplicateDefinitionIdentity;
        const capability = named(capabilities, text(operation, "capability")) orelse return error.UnknownCapability;
        for (items(operation, "providerDependencies")) |family| {
            var found = false;
            for (items(capability, "requires")) |requirement| found = found or std.mem.eql(u8, text(requirement, "primitiveFamily"), family.string);
            if (!found) return error.UnknownProviderRequirement;
        }
    }
    if (field(definition, "stewardship")) |stewardship| {
        _ = named(capabilities, text(stewardship, "capability")) orelse return error.UnknownCapability;
        const realisation = named(realisations, text(stewardship, "realisation")) orelse return error.UnknownRealisation;
        if (!std.mem.eql(u8, text(realisation, "capability"), text(stewardship, "capability"))) return error.RealisationCapabilityMismatch;
    }
}

fn semanticId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or !std.ascii.isAlphabetic(id[0])) return false;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
    return true;
}

fn semantics(alloc: Allocator, value: Value, semantic: Semantic) !void {
    if (!std.mem.eql(u8, semantic.version, "omniseedos.semantic/v1") or semantic.search.version != 1 or semantic.search.maxDepth > 16) return error.UnsupportedSemanticVersion;
    for ([_]f64{ semantic.search.ranking.relevance, semantic.search.ranking.precedent, semantic.search.ranking.evidence, semantic.search.ranking.recency }) |weight| if (weight < 0 or weight > 1) return error.InvalidSearchWeight;
    const weights = semantic.search.ranking;
    if (@abs(weights.relevance + weights.precedent + weights.evidence + weights.recency - 1) > 1e-9) return error.InvalidSearchRanking;
    var entities: std.StringHashMapUnmanaged(void) = .empty;
    for (semantic.entityTypes) |entity| {
        if (!semanticId(entity.id) or std.mem.eql(u8, entity.id, "documents")) return error.InvalidEntityIdentity;
        if ((try entities.getOrPut(alloc, entity.id)).found_existing) return error.DuplicateEntityType;
        if (entity.fields != .object and entity.fields != .null) return error.InvalidEntityFields;
        if (entity.fields == .object) {
            var it = entity.fields.object.iterator();
            while (it.next()) |entry| {
                if (!semanticId(entry.key_ptr.*) or entry.value_ptr.* != .string) return error.InvalidEntityField;
                var valid_type = false;
                for ([_][]const u8{ "string", "number", "boolean", "json" }) |kind| valid_type = valid_type or std.mem.eql(u8, entry.value_ptr.string, kind);
                if (!valid_type) return error.InvalidEntityFieldType;
            }
        }
        for ([_][]const []const u8{ entity.required, entity.indexed }) |list| for (list) |name| {
            if (field(entity.fields, name) == null) return error.UnknownEntityField;
        };
    }
    var relations: std.StringHashMapUnmanaged(void) = .empty;
    for (semantic.relationships) |relationship| {
        if (!semanticId(relationship.id) or (try relations.getOrPut(alloc, relationship.id)).found_existing) return error.InvalidRelationshipIdentity;
        if (!entities.contains(relationship.from) or !entities.contains(relationship.to)) return error.UnknownRelationshipEntity;
        if (relationship.inheritScope and relationship.kind != .containment) return error.InvalidScopeInheritance;
    }
    var scopes: std.StringHashMapUnmanaged(void) = .empty;
    for (semantic.scopes) |scope| {
        if (!semanticId(scope.id) or (try scopes.getOrPut(alloc, scope.id)).found_existing) return error.InvalidScopeIdentity;
        if (!entities.contains(scope.entityType)) return error.UnknownScopeEntity;
    }
    for (semantic.scopes) |scope| {
        var parent = scope.parent;
        var depth: usize = 0;
        while (parent) |id| {
            if (!scopes.contains(id)) return error.UnknownScope;
            depth += 1;
            if (depth > semantic.scopes.len) return error.CyclicScope;
            for (semantic.scopes) |candidate| if (std.mem.eql(u8, candidate.id, id)) {
                parent = candidate.parent;
                break;
            };
        }
    }
    const capabilities = items(spec(value), "capabilities");
    var hierarchy: std.StringHashMapUnmanaged(void) = .empty;
    var visited: std.StringHashMapUnmanaged(u8) = .empty;
    for (semantic.capabilityHierarchy) |row| {
        if ((try hierarchy.getOrPut(alloc, row.capability)).found_existing) return error.DuplicateCapabilityHierarchy;
        _ = named(capabilities, row.capability) orelse return error.UnknownCapability;
        if (row.parent) |parent| {
            _ = named(capabilities, parent) orelse return error.UnknownCapability;
        }
        for (row.dependsOn) |parent| {
            _ = named(capabilities, parent) orelse return error.UnknownCapability;
        }
        try hierarchyWalk(alloc, semantic.capabilityHierarchy, row.capability, &visited, 0);
    }
    var containment: std.ArrayList(Hierarchy) = .empty;
    var containment_seen: std.StringHashMapUnmanaged(u8) = .empty;
    for (semantic.entityTypes) |entity| {
        var children: std.ArrayList([]const u8) = .empty;
        for (semantic.relationships) |relationship| if (relationship.kind == .containment and std.mem.eql(u8, relationship.from, entity.id)) try children.append(alloc, relationship.to);
        try containment.append(alloc, .{ .capability = entity.id, .dependsOn = children.items });
    }
    for (semantic.entityTypes) |entity| try hierarchyWalk(alloc, containment.items, entity.id, &containment_seen, 0);
    for (semantic.search.traversal) |id| if (!relations.contains(id)) return error.UnknownSearchRelationship;
}

fn hierarchyWalk(alloc: Allocator, rows: []const Hierarchy, id: []const u8, visited: *std.StringHashMapUnmanaged(u8), depth: usize) anyerror!void {
    if (depth > 128) return error.DeclarationTooComplex;
    if (visited.get(id)) |state| {
        if (state == 1) return error.CyclicCapabilityHierarchy;
        return;
    }
    try visited.put(alloc, id, 1);
    for (rows) |row| {
        if (!std.mem.eql(u8, row.capability, id)) continue;
        if (row.parent) |parent| try hierarchyWalk(alloc, rows, parent, visited, depth + 1);
        for (row.dependsOn) |parent| try hierarchyWalk(alloc, rows, parent, visited, depth + 1);
    }
    try visited.put(alloc, id, 2);
}

pub fn nativeCapability(declaration: Declaration, id: []const u8) bool {
    if (!std.mem.eql(u8, id, "general_task") and !std.mem.eql(u8, id, "coding_task")) return false;
    const root = spec(declaration.value);
    const capability = named(items(root, "capabilities"), id) orelse return false;
    for (items(root, "realisations")) |realisation| {
        if (!std.mem.eql(u8, text(realisation, "capability"), id)) continue;
        var complete = true;
        for (items(capability, "requires")) |requirement| {
            var supplied = false;
            const family = text(requirement, "primitiveFamily");
            const implementation = if (std.mem.eql(u8, family, "inference")) "omos_model" else if (std.mem.eql(u8, family, "skills")) "omos_repository" else if (std.mem.eql(u8, family, "machines")) "omos_shell" else if (std.mem.eql(u8, family, "memory")) "omos_fossil" else "";
            for (items(realisation, "participants")) |participant| {
                if (!contains(items(participant, "supplies"), text(requirement, "id"))) continue;
                const resource = named(items(field(root, "resources") orelse .null, family), text(participant, "resource")) orelse continue;
                supplied = supplied or (implementation.len > 0 and std.mem.eql(u8, text(field(resource, "spec") orelse .null, "implementation"), implementation));
            }
            complete = complete and supplied;
        }
        if (complete) return true;
    }
    return false;
}

pub fn canonical(alloc: Allocator, value: Value) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    try writeCanonical(alloc, &writer.writer, value);
    return writer.toOwnedSlice();
}
fn writeCanonical(alloc: Allocator, writer: *std.Io.Writer, value: Value) anyerror!void {
    switch (value) {
        .object => |object| {
            const keys = try alloc.dupe([]const u8, object.keys());
            sort_utils.sort([]const u8, keys, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            try writer.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i > 0) try writer.writeByte(',');
                try std.json.Stringify.value(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonical(alloc, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeCanonical(alloc, writer, item);
            }
            try writer.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}
pub fn digest(alloc: Allocator, value: Value) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try canonical(alloc, value), &hash, .{});
    return alloc.dupe(u8, &std.fmt.bytesToHex(&hash, .lower));
}

test "workspace declaration planning references schemas and preserves capability selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const declaration = try parse(alloc, seed);
    const basis: Basis = .{ .definition_hash = declaration.hash, .revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .execution = .{}, .capability = "general_task" };
    const snapshot = try planningSnapshot(alloc, basis, declaration);
    try std.testing.expectEqualStrings(declaration.hash, text(field(snapshot, "declarationReference").?, "sha256"));
    try std.testing.expectEqualStrings(basis.revision, text(field(snapshot, "declarationReference").?, "revision"));
    try std.testing.expectEqualStrings("general_task", text(field(snapshot, "basis").?, "capability"));
    const projected = spec(field(snapshot, "declaration").?);
    for ([_][]const u8{ "capabilities", "resources", "realisations" }) |key| {
        try std.testing.expectEqualStrings(try canonical(alloc, field(spec(declaration.value), key).?), try canonical(alloc, field(projected, key).?));
    }
    try std.testing.expect(field(projected, "operations") == null);
    try std.testing.expect(field(spec(declaration.value), "operations") != null);
    try std.testing.expect((try canonical(alloc, snapshot)).len < 8192);
}

test "workspace declaration execution policy has bounded independent defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try parseExecution(arena.allocator(), "{}");
    try std.testing.expectEqual(@as(usize, 4), execution.defaults.progress_interval);
    try std.testing.expectEqual(@as(usize, 3), execution.defaults.stalled_checks);
    try std.testing.expectEqual(@as(usize, 100), execution.defaults.max_actor_steps);
    try std.testing.expectError(error.InvalidExecutionPolicy, parseExecution(arena.allocator(), "{\"defaults\":{\"max_actor_steps\":0}}"));
}

test "workspace declaration compact embeds preserve pinned JSON values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][2][]const u8{
        .{ @embedFile("standard/omos.json"), seed },
        .{ @embedFile("standard/omniform.schema.json"), standard_schema },
    }) |pair| {
        const original = (try std.json.parseFromSlice(Value, alloc, pair[0], .{})).value;
        const compact = (try std.json.parseFromSlice(Value, alloc, pair[1], .{})).value;
        try std.testing.expectEqualStrings(try canonical(alloc, original), try canonical(alloc, compact));
        try std.testing.expect(pair[1].len < pair[0].len);
    }
    try std.testing.expectEqualStrings("{\"text\":\"a \\\" b \\\\ c\"}", compactJson(" { \"text\" : \"a \\\" b \\\\ c\" } \n"));
}

test "workspace declaration seed shares the pinned OmniForm model and validates its references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const declaration = try parse(arena.allocator(), seed);
    try std.testing.expectEqual(@as(usize, 2), items(spec(declaration.value), "capabilities").len);
    try std.testing.expectEqual(@as(usize, 41), declaration.semantic.entityTypes.len);
    try std.testing.expectEqual(@as(usize, 64), declaration.hash.len);
}

fn migration(alloc: Allocator, semantic: Semantic) !void {
    const raw = semantic.migration orelse return;
    const Migration = struct { version: []const u8, defaults: Value = .null, removeFields: Value = .null, removeTypes: []const []const u8 = &.{} };
    const m = (try std.json.parseFromValue(Migration, alloc, raw, .{})).value;
    if (!std.mem.eql(u8, m.version, "omniseedos.data-migration/v1")) return error.UnsupportedDataMigration;
    // Destructive migration requires a separate host implementation. It is never
    // activated as an additive declaration proposal.
    if (m.removeTypes.len > 0 or (m.removeFields == .object and m.removeFields.object.count() > 0)) return error.UnsupportedDestructiveMigration;
    if (m.removeFields != .null and m.removeFields != .object) return error.InvalidDataMigration;
    if (m.defaults == .null) return;
    if (m.defaults != .object) return error.InvalidDataMigration;
    if (m.defaults.object.count() > 0) return error.UnsupportedDataMigrationDefaults;
    var it = m.defaults.object.iterator();
    while (it.next()) |entry| {
        try validateRecord(semantic, entry.key_ptr.*, entry.value_ptr.*, false);
        var fields = entry.value_ptr.object.iterator();
        while (fields.next()) |item| if (item.value_ptr.* == .null) return error.InvalidDataMigration;
    }
}

/// Caller owns returned validation errors through its operation arena.
pub fn validateRecord(semantic: Semantic, entity_id: []const u8, value: Value, require_all: bool) !void {
    const entity = for (semantic.entityTypes) |row| {
        if (std.mem.eql(u8, row.id, entity_id)) break row;
    } else return error.UnknownEntityType;
    if (value != .object) return error.InvalidEntityRecord;
    if (require_all) for (entity.required) |key| {
        if (field(value, key) == null) return error.MissingEntityField;
    };
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const kind = field(entity.fields, entry.key_ptr.*) orelse return error.UnknownEntityField;
        const item = entry.value_ptr.*;
        if (std.mem.eql(u8, kind.string, "json")) continue;
        const valid = if (std.mem.eql(u8, kind.string, "string")) item == .string else if (std.mem.eql(u8, kind.string, "number")) item == .integer or item == .float or item == .number_string else item == .bool;
        if (!valid) return error.InvalidEntityFieldType;
    }
}

/// Existing identities and contracts must remain byte-for-byte equivalent after
/// canonicalization. New entities may have required fields; existing entities
/// may gain optional fields. A definition never grants runtime permission.
pub fn compatible(alloc: Allocator, old: Declaration, next: Declaration) !bool {
    const a = spec(old.value);
    const b = spec(next.value);
    for ([_][]const u8{ "capabilities", "realisations", "operations" }) |key| {
        for (items(a, key)) |row| {
            const new = named(items(b, key), text(row, "id")) orelse return false;
            if (!std.mem.eql(u8, try canonical(alloc, row), try canonical(alloc, new))) return false;
        }
    }
    if (field(a, "providers")) |providers| {
        if (!std.mem.eql(u8, try canonical(alloc, providers), try canonical(alloc, field(b, "providers") orelse .null))) return false;
    }
    if (field(a, "resources")) |families| {
        var it = families.object.iterator();
        while (it.next()) |entry| for (entry.value_ptr.array.items) |row| {
            const new = named(items(field(b, "resources") orelse .null, entry.key_ptr.*), text(row, "id")) orelse return false;
            if (!std.mem.eql(u8, try canonical(alloc, row), try canonical(alloc, new))) return false;
        };
    }
    for (old.semantic.entityTypes) |entity| {
        const new = for (next.semantic.entityTypes) |candidate| {
            if (std.mem.eql(u8, entity.id, candidate.id)) break candidate;
        } else return false;
        if (entity.fields == .object) {
            var it = entity.fields.object.iterator();
            while (it.next()) |entry| {
                const kind = field(new.fields, entry.key_ptr.*) orelse return false;
                if (!std.mem.eql(u8, try canonical(alloc, kind), try canonical(alloc, entry.value_ptr.*))) return false;
            }
        }
        // Preserve required/indexed contracts, allowing additional indexes.
        for (entity.required) |key| if (!hasString(new.required, key)) return false;
        for (new.required) |key| if (!hasString(entity.required, key)) return false;
        for (entity.indexed) |key| if (!hasString(new.indexed, key)) return false;
    }
    inline for (.{ "relationships", "scopes", "capabilityHierarchy" }) |key| {
        for (@field(old.semantic, key)) |row| {
            var found = false;
            for (@field(next.semantic, key)) |candidate| {
                const id = if (comptime std.mem.eql(u8, key, "capabilityHierarchy")) "capability" else "id";
                if (std.mem.eql(u8, @field(row, id), @field(candidate, id))) {
                    found = std.mem.eql(u8, try std.json.Stringify.valueAlloc(alloc, row, .{}), try std.json.Stringify.valueAlloc(alloc, candidate, .{}));
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return true;
}
fn hasString(values: []const []const u8, key: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, key)) return true;
    return false;
}

test "workspace declaration compatible changes preserve every existing contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = try parse(alloc, seed);
    var changed = (try std.json.parseFromSlice(Value, alloc, seed, .{})).value;
    for (changed.object.getPtr("spec").?.object.getPtr("semantic").?.object.getPtr("entityTypes").?.array.items) |*entity| {
        if (!std.mem.eql(u8, text(entity.*, "id"), "omos_task")) continue;
        try entity.object.getPtr("fields").?.object.put(alloc, "objective", .{ .string = "boolean" });
    }
    const next = try parse(alloc, try canonical(alloc, changed));
    try std.testing.expect(try compatible(alloc, old, old));
    try std.testing.expect(!try compatible(alloc, old, next));
}

test "workspace declaration bounds server review capacity and preserves legacy policy hashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parseExecution(a, "{}");
    try std.testing.expectEqual(@as(usize, 1), old.reviewWorkers());
    const legacy = try std.json.Stringify.valueAlloc(a, old, .{});
    try std.testing.expect(std.mem.find(u8, legacy, "server") == null);
    const parallel = try parseExecution(a, "{\"server\":{\"review_workers\":2}}");
    try std.testing.expectEqual(@as(usize, 2), parallel.reviewWorkers());
    try std.testing.expectEqualStrings("{\"review_workers\":2}", try std.json.Stringify.valueAlloc(a, parallel.server.?, .{}));
    const checked = try parseExecution(a, "{\"server\":{\"review_workers\":2,\"validation_handle\":\"company-checks\"}}");
    try std.testing.expectEqualStrings("company-checks", checked.server.?.validation_handle.?);
    try std.testing.expect(!compatibleExecution(parallel, checked));
    try std.testing.expect(!compatibleExecution(checked, parallel));
    const changed = try parseExecution(a, "{\"server\":{\"review_workers\":2,\"validation_handle\":\"other-checks\"}}");
    try std.testing.expect(!compatibleExecution(checked, changed));
    try std.testing.expect(!compatibleExecution(old, parallel));
    try std.testing.expect(compatibleExecution(parallel, old));
    for ([_][]const u8{
        "{\"server\":{\"review_workers\":0}}",
        "{\"server\":{\"review_workers\":5}}",
        "{\"server\":{\"unknown\":1}}",
        "{\"server\":{\"validation_handle\":\"../checks\"}}",
        "{\"server\":{\"validation_handle\":\"\"}}",
    }) |raw| {
        if (parseExecution(a, raw)) |_| return error.ExpectedInvalidPolicy else |_| {}
    }
}

test "workspace declaration explicit transport upgrades preserve company constraints and proposal rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var value = (try std.json.parseFromSlice(Value, alloc, seed, .{})).value;
    var legacy_operation: ?*Value = null;
    for (value.object.getPtr("spec").?.object.getPtr("operations").?.array.items) |*operation| {
        if (std.mem.eql(u8, text(operation.*, "id"), "omos_company_operation")) legacy_operation = operation;
    }
    const properties = legacy_operation.?.object.getPtr("input").?.object.getPtr("properties").?;
    try properties.object.put(alloc, "version", (try std.json.parseFromSlice(Value, alloc, "{\"const\":\"omos.company/v1\"}", .{})).value);
    _ = properties.object.swapRemove("executable");
    _ = properties.object.swapRemove("previous_executable");
    _ = properties.object.swapRemove("upload");
    try properties.object.put(alloc, "company_note", (try std.json.parseFromSlice(Value, alloc, "{\"type\":\"string\",\"maxLength\":7}", .{})).value);
    const old = try parse(alloc, try canonical(alloc, value));
    const next = try upgrade(alloc, old);
    const operation = named(items(spec(next.value), "operations"), "omos_company_operation").?;
    const upgraded = field(field(operation, "input").?, "properties").?;
    try std.testing.expect(field(upgraded, "executable") != null);
    try std.testing.expect(field(upgraded, "upload") != null);
    try std.testing.expect(contains(items(field(upgraded, "version").?, "enum"), "omos.company/v2"));
    try std.testing.expectEqualStrings(try canonical(alloc, field(properties.*, "company_note").?), try canonical(alloc, field(upgraded, "company_note").?));
    try std.testing.expect(!try compatible(alloc, old, next));
    try std.testing.expectEqualStrings(next.hash, (try upgrade(alloc, next)).hash);
}

test "workspace projection policy preserves legacy hashes and bounds disposable cache budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try parseExecution(a, "{}");
    try std.testing.expect(legacy.projections == null);
    const raw = try std.json.Stringify.valueAlloc(a, legacy, .{});
    try std.testing.expect(std.mem.find(u8, raw, "projections") == null);
    const bounded = try parseExecution(a, "{\"projections\":{\"max_clean_views\":0,\"max_clean_bytes\":0}}");
    try std.testing.expectEqual(@as(usize, 0), bounded.projections.?.max_clean_views);
    try std.testing.expectError(error.InvalidExecutionPolicy, parseExecution(a, "{\"projections\":{\"max_clean_views\":1025}}"));
    try std.testing.expectError(error.InvalidExecutionPolicy, parseExecution(a, "{\"projections\":{\"max_clean_bytes\":4294967297}}"));
}
