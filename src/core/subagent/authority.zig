const std = @import("std");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const permissions = @import("../permissions/permissions.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const trust_tier = @import("../permissions/trust_tier.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const PermissionAdmissionError = error{PermissionEscalation};

fn permissionRank(mode: types.PermissionMode) u2 {
    return switch (mode) {
        .ask => 0,
        .auto => 1,
        .yolo => 2,
    };
}

pub fn admitChildPermission(
    parent: types.PermissionMode,
    requested: ?types.PermissionMode,
) PermissionAdmissionError!types.PermissionMode {
    const child = requested orelse parent;
    if (permissionRank(child) > permissionRank(parent)) {
        return error.PermissionEscalation;
    }
    return child;
}

pub const Error = error{
    OutOfMemory,
    ChildNotAttached,
    InvalidControlRecord,
    StoreUnavailable,
    HostAuthorityUnavailable,
};

pub const HostAuthority = struct {
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    mcp_view: ?mcp_access.View = null,

    pub fn capture(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        rules: types.PermissionRuleSet,
        grants: []const types.PermissionGrant,
    ) !HostAuthority {
        return captureWithPermissionStateAndMcpView(
            alloc,
            tools,
            integrations,
            rules,
            grants,
            .{},
            null,
        );
    }

    pub fn captureWithPermissionStateAndMcpView(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        rules: types.PermissionRuleSet,
        grants: []const types.PermissionGrant,
        permission_state: session_permission_state.State,
        mcp_view: ?*const mcp_access.View,
    ) !HostAuthority {
        const owned_tools = try cloneStrings(alloc, tools);
        errdefer freeStrings(alloc, owned_tools);
        const owned_integrations = try cloneStrings(alloc, integrations);
        errdefer freeStrings(alloc, owned_integrations);
        var owned_rules = try types.dupePermissionRuleSet(alloc, rules);
        errdefer owned_rules.deinit(alloc);
        const owned_permission_state = try session_permission_state.projectForChild(
            alloc,
            permission_state,
            &.{},
        );
        errdefer {
            var value = owned_permission_state;
            value.deinit(alloc);
        }
        var owned_mcp_view = if (mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (owned_mcp_view) |*view| view.deinit(alloc);
        return .{
            .generation = hostGeneration(
                tools,
                integrations,
                rules,
                grants,
                owned_permission_state,
                mcp_view,
            ),
            .tools = owned_tools,
            .integrations = owned_integrations,
            .rules = owned_rules,
            .grants = try types.dupePermissionGrantSlice(alloc, grants),
            .permission_state = owned_permission_state,
            .mcp_view = owned_mcp_view,
        };
    }

    pub fn deinit(self: *HostAuthority, alloc: Allocator) void {
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }
};

pub const HostResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) HostResolveError!HostAuthority,

    fn resolve(
        self: HostResolver,
        alloc: Allocator,
        root_id: []const u8,
    ) Error!HostAuthority {
        return self.resolve_fn(self.context, alloc, root_id);
    }
};

pub const HostResolveError = error{
    OutOfMemory,
    HostAuthorityUnavailable,
};

pub const LiveAuthority = struct {
    generation: u64,
    root_id: []const u8,
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_mode: types.PermissionMode,
    trust_policy: trust_tier.Policy = .{},
};

pub const Snapshot = struct {
    child_id: []u8,
    root_id: []u8,
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    permission_mode: types.PermissionMode,
    trust_policy: trust_tier.Policy = .{},
    mcp_view: ?mcp_access.View = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }

    pub fn view(self: *const Snapshot) LiveAuthority {
        return .{
            .generation = self.generation,
            .root_id = self.root_id,
            .tools = self.tools,
            .integrations = self.integrations,
            .rules = self.rules,
            .grants = self.grants,
            .permission_mode = self.permission_mode,
            .trust_policy = self.trust_policy,
        };
    }
};

pub const Resolver = struct {
    backend: child_state.Backend,
    root_id: []const u8 = "",
    host: HostResolver,
    child_store_options: session_child_store.Options = .{},

    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!Snapshot {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        domain.validateId(self.root_id) catch return error.ChildNotAttached;
        var store = child_state.Store{
            .backend = self.backend,
            .parent_id = self.root_id,
            .options = self.child_store_options,
        };
        const work_generation = blk: {
            var lock = store.acquireLock(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer lock.release();
            var registry = store.load(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildNotAttached;
            if (child.active == null) return error.ChildNotAttached;
            break :blk child.work_generation;
        };

        // Host resolution may connect MCP servers; parent state observation must remain available.
        var host = try self.host.resolve(alloc, self.root_id);
        defer host.deinit(alloc);

        const current = blk: {
            var lock = store.acquireLock(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer lock.release();
            var registry = store.load(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildNotAttached;
            const active = child.active orelse return error.ChildNotAttached;
            if (child.work_generation != work_generation) return error.ChildNotAttached;
            break :blk .{
                .generation = registry.generation,
                .permission_mode = active.permission_mode,
                .trust_policy = active.trust_policy,
            };
        };

        const child_policy = current.trust_policy;
        const owned_child_id = try alloc.dupe(u8, child_id);
        errdefer alloc.free(owned_child_id);
        const owned_root_id = try alloc.dupe(u8, self.root_id);
        errdefer alloc.free(owned_root_id);
        const tools = try cloneToolsForChild(alloc, host.tools, child_policy);
        errdefer freeStrings(alloc, tools);
        const integrations = try cloneIntegrationsForChild(alloc, host.integrations, child_policy);
        errdefer freeStrings(alloc, integrations);
        var rules = if (child_policy.tier == .untrusted)
            types.PermissionRuleSet{}
        else
            try types.dupePermissionRuleSet(alloc, host.rules);
        errdefer rules.deinit(alloc);
        const permission_state: session_permission_state.State = if (child_policy.allowsPersonalFossil())
            session_permission_state.dupe(
                alloc,
                host.permission_state,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidControlRecord,
            }
        else
            .{};
        errdefer {
            var value = permission_state;
            value.deinit(alloc);
        }
        var mcp_view: ?mcp_access.View = if (!child_policy.allowsMcp())
            null
        else if (host.mcp_view) |view|
            try cloneMcpViewForChild(alloc, view, child_policy)
        else
            null;
        errdefer if (mcp_view) |*view| view.deinit(alloc);
        if (mcp_view) |*view| {
            try rebindMcpViewOwnership(alloc, view, child_id, self.root_id);
        }
        const grants = if (child_policy.allowsPersonalFossil())
            try types.dupePermissionGrantSlice(alloc, host.grants)
        else
            try alloc.alloc(types.PermissionGrant, 0);
        return .{
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .generation = authorityGeneration(
                child_id,
                self.root_id,
                current.generation,
                host.generation,
            ),
            .tools = tools,
            .integrations = integrations,
            .rules = rules,
            .grants = grants,
            .permission_state = permission_state,
            .permission_mode = current.permission_mode,
            .trust_policy = child_policy,
            .mcp_view = mcp_view,
        };
    }
};

pub const ToolAuthorityDecision = enum { allow, ask, deny, unavailable };

pub fn decideToolAuthority(
    alloc: Allocator,
    live: LiveAuthority,
    workspace_root: []const u8,
    tool_name: []const u8,
    target: []const u8,
    target_kind: permissions.PermissionTargetKind,
) !ToolAuthorityDecision {
    if (!live.trust_policy.allowsToolAdvertisement(tool_name)) {
        return .unavailable;
    }
    if (live.trust_policy.checkToolCall(tool_name, "{}") == .denied) {
        return .deny;
    }
    if (!contains(live.tools, tool_name) and
        !contains(live.integrations, tool_name))
    {
        return .unavailable;
    }
    if (live.permission_mode == .yolo) return .allow;
    const permission_name = if (target_kind == .command_cwd and
        std.mem.eql(u8, tool_name, "shell"))
        "terminal"
    else
        tool_name;
    return switch (try permissions.ruleDecisionFor(
        alloc,
        live.rules,
        workspace_root,
        permission_name,
        target,
        target_kind,
    )) {
        .allow => .allow,
        .deny => .deny,
        .ask, .none => if (permissions.sessionGrantAllowed(
            live.grants,
            permission_name,
            target,
        )) .allow else .ask,
    };
}

fn rebindMcpViewOwnership(
    alloc: Allocator,
    view: *mcp_access.View,
    child_id: []const u8,
    parent_id: []const u8,
) !void {
    const owner = try alloc.dupe(u8, child_id);
    errdefer alloc.free(owner);
    const parent = try alloc.dupe(u8, parent_id);
    alloc.free(view.owner_id);
    alloc.free(view.parent_id);
    view.owner_id = owner;
    view.parent_id = parent;
}

fn hostGeneration(
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.host-authority.v3\x00");
    for (tools) |tool| hashString(&hash, tool);
    for (integrations) |integration| hashString(&hash, integration);
    for (rules.rules) |rule| {
        hashString(&hash, rule.permission);
        hashString(&hash, rule.pattern);
        hashString(&hash, @tagName(rule.action));
    }
    for (grants) |grant| {
        hashString(&hash, grant.tool_name);
        hashString(&hash, grant.target_path);
    }
    hashU64(&hash, permission_state.version);
    hashU64(&hash, permission_state.next_generation);
    if (mcp_view) |view| {
        hashU64(&hash, view.runtime_generation);
        hashString(&hash, view.owner_id);
        hashString(&hash, view.parent_id);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn authorityGeneration(
    child_id: []const u8,
    root_id: []const u8,
    child_generation: u64,
    host_generation: u64,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.live-authority.v2\x00");
    hashString(&hash, child_id);
    hashString(&hash, root_id);
    hashU64(&hash, child_generation);
    hashU64(&hash, host_generation);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, values.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn cloneToolsForChild(
    alloc: Allocator,
    values: []const []const u8,
    policy: trust_tier.Policy,
) ![][]u8 {
    var count: usize = 0;
    for (values) |value| {
        if (!std.mem.eql(u8, value, "subagent") and policy.allowsToolAdvertisement(value)) count += 1;
    }
    const out = try alloc.alloc([]u8, count);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        if (std.mem.eql(u8, value, "subagent") or !policy.allowsToolAdvertisement(value)) continue;
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn cloneIntegrationsForChild(
    alloc: Allocator,
    values: []const []const u8,
    policy: trust_tier.Policy,
) ![][]u8 {
    if (!policy.allowsMcp()) return alloc.alloc([]u8, 0);
    var count: usize = 0;
    for (values) |value| {
        if (policy.allowsMcpTool(value)) count += 1;
    }
    const out = try alloc.alloc([]u8, count);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        if (!policy.allowsMcpTool(value)) continue;
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn cloneMcpViewForChild(
    alloc: Allocator,
    view: mcp_access.View,
    policy: trust_tier.Policy,
) !mcp_access.View {
    if (policy.tier == .private) return view.clone(alloc);
    const owner_id = try alloc.dupe(u8, view.owner_id);
    errdefer alloc.free(owner_id);
    const parent_id = try alloc.dupe(u8, view.parent_id);
    errdefer alloc.free(parent_id);

    var server_count: usize = 0;
    for (view.servers) |server| {
        if (policy.allowsMcpServer(server.name)) server_count += 1;
    }
    const servers = try alloc.alloc(mcp_access.ServerIdentity, server_count);
    var built_servers: usize = 0;
    errdefer {
        for (servers[0..built_servers]) |*item| item.deinit(alloc);
        alloc.free(servers);
    }
    for (view.servers) |server| {
        if (!policy.allowsMcpServer(server.name)) continue;
        servers[built_servers] = .{
            .name = try alloc.dupe(u8, server.name),
            .source = server.source,
            .scope = server.scope,
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .auth_generation = server.auth_generation,
        };
        built_servers += 1;
    }

    var tool_count: usize = 0;
    for (view.tools) |tool| {
        if (policy.allowsMcpServer(tool.server_name) and policy.allowsMcpTool(tool.name)) tool_count += 1;
    }
    const tools = try alloc.alloc(mcp_access.ToolIdentity, tool_count);
    var built_tools: usize = 0;
    errdefer {
        for (tools[0..built_tools]) |*item| item.deinit(alloc);
        alloc.free(tools);
    }
    for (view.tools) |tool| {
        if (!policy.allowsMcpServer(tool.server_name) or !policy.allowsMcpTool(tool.name)) continue;
        const name = try alloc.dupe(u8, tool.name);
        errdefer alloc.free(name);
        const server_name = try alloc.dupe(u8, tool.server_name);
        tools[built_tools] = .{ .name = name, .server_name = server_name };
        built_tools += 1;
    }

    return .{
        .runtime_generation = view.runtime_generation,
        .owner_id = owner_id,
        .parent_id = parent_id,
        .features_visible = view.features_visible,
        .servers = servers,
        .tools = tools,
    };
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

test "child permission admission inherits without elevation" {
    try std.testing.expectEqual(
        types.PermissionMode.auto,
        try admitChildPermission(.auto, null),
    );
    try std.testing.expectError(
        error.PermissionEscalation,
        admitChildPermission(.ask, .auto),
    );
}

test "tool authority excludes nested subagents and preserves rules" {
    const alloc = std.testing.allocator;
    const decision = try decideToolAuthority(alloc, .{
        .generation = 1,
        .root_id = "root",
        .tools = &.{"read_file"},
        .integrations = &.{},
        .rules = .{},
        .grants = &.{},
        .permission_mode = .yolo,
    }, "/tmp", "subagent", "subagent", .none);
    try std.testing.expectEqual(ToolAuthorityDecision.unavailable, decision);
}

test "authority capture permits registry access and rejects changed work" {
    const io_mod = @import("../shared/io.zig");
    const Fixture = struct {
        const Change = enum { none, finish, replace, permission, sibling, host_failure };
        store: child_state.Store,
        change: Change,
        calls: usize = 0,

        fn resolve(raw: ?*anyopaque, alloc: Allocator, _: []const u8) HostResolveError!HostAuthority {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            var lock = self.store.acquireLock(alloc) catch return error.HostAuthorityUnavailable;
            defer lock.release();
            var registry = self.store.load(alloc) catch return error.HostAuthorityUnavailable;
            defer registry.deinit(alloc);
            switch (self.change) {
                .none => {},
                .host_failure => return error.HostAuthorityUnavailable,
                .finish, .replace => {
                    registry.finish(alloc, "authority-child", "work-one", .completed, null) catch
                        return error.HostAuthorityUnavailable;
                    if (self.change != .finish) {
                        var work = child_state.ActiveWork{
                            .id = try alloc.dupe(u8, "work-two"),
                            .message = try alloc.dupe(u8, "replacement"),
                            .created_at_ms = 2,
                        };
                        defer work.deinit(alloc);
                        _ = registry.startPersistentWork(alloc, "worker", null, work) catch
                            return error.HostAuthorityUnavailable;
                    }
                },
                .permission => {
                    registry.children[0].active.?.permission_mode = .auto;
                    registry.generation += 1;
                },
                .sibling => {
                    var work = child_state.ActiveWork{
                        .id = try alloc.dupe(u8, "sibling-work"),
                        .message = try alloc.dupe(u8, "independent work"),
                        .created_at_ms = 2,
                    };
                    defer work.deinit(alloc);
                    registry.appendOneOff(alloc, "authority-sibling", work) catch
                        return error.HostAuthorityUnavailable;
                },
            }
            self.store.save(alloc, registry) catch return error.HostAuthorityUnavailable;
            return HostAuthority.capture(alloc, &.{ "read_file", "subagent" }, &.{}, .{}, &.{}) catch
                return error.OutOfMemory;
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    var state: @import("../session/session_codec.zig").DurableSessionState = .{
        .id = try alloc.dupe(u8, "authority-parent"),
        .origin_workspace_root = try alloc.dupe(u8, home),
        .workspace_root = try alloc.dupe(u8, home),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = types.ReasoningEffort.literal("low"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    defer state.deinit(alloc);
    var parent = try sessions.startWritableSession(alloc, state);
    defer parent.deinit(alloc);
    const store = child_state.Store{ .backend = .{ .v1 = &sessions }, .parent_id = state.id };

    for (std.enums.values(Fixture.Change)) |change| {
        var registry = try child_state.Registry.init(alloc, state.id);
        defer registry.deinit(alloc);
        var work = child_state.ActiveWork{
            .id = try alloc.dupe(u8, "work-one"),
            .message = try alloc.dupe(u8, "original"),
            .permission_mode = .ask,
            .created_at_ms = 1,
        };
        defer work.deinit(alloc);
        try registry.appendPersistent(alloc, "authority-child", "worker", "", work);
        try store.save(alloc, registry);
        var fixture = Fixture{ .store = store, .change = change };
        var resolver = Resolver{
            .backend = .{ .v1 = &sessions },
            .root_id = state.id,
            .host = .{ .context = &fixture, .resolve_fn = Fixture.resolve },
        };
        try std.testing.expectError(error.ChildNotAttached, resolver.resolve(alloc, "missing-child"));
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        switch (change) {
            .finish, .replace => try std.testing.expectError(
                error.ChildNotAttached,
                resolver.resolve(alloc, "authority-child"),
            ),
            .host_failure => try std.testing.expectError(
                error.HostAuthorityUnavailable,
                resolver.resolve(alloc, "authority-child"),
            ),
            .none, .permission, .sibling => {
                var snapshot = try resolver.resolve(alloc, "authority-child");
                defer snapshot.deinit(alloc);
                try std.testing.expectEqual(
                    if (change == .permission) types.PermissionMode.auto else types.PermissionMode.ask,
                    snapshot.permission_mode,
                );
                try std.testing.expectEqual(@as(usize, 1), snapshot.tools.len);
                try std.testing.expectEqualStrings("read_file", snapshot.tools[0]);
                var current = try store.load(alloc);
                defer current.deinit(alloc);
                var host = try HostAuthority.capture(alloc, &.{ "read_file", "subagent" }, &.{}, .{}, &.{});
                defer host.deinit(alloc);
                try std.testing.expectEqual(
                    authorityGeneration("authority-child", state.id, current.generation, host.generation),
                    snapshot.generation,
                );
            },
        }
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }
}

test "quarantined untrusted reader and chat child authority strips privileged tools and MCP" {
    const io_mod = @import("../shared/io.zig");
    const Fixture = struct {
        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) HostResolveError!HostAuthority {
            var servers = [_]mcp_access.ServerIdentity{.{
                .name = @constCast("browseros-neo"),
                .source = .profile,
                .scope = .profile,
                .connection_generation = 1,
                .catalog_generation = 1,
                .auth_generation = 1,
            }};
            var mcp_tools = [_]mcp_access.ToolIdentity{.{
                .name = @constCast("mcp_browseros-neo_run"),
                .server_name = @constCast("browseros-neo"),
            }};
            const view = mcp_access.View{
                .runtime_generation = 1,
                .owner_id = @constCast("parent"),
                .parent_id = @constCast("parent"),
                .features_visible = true,
                .servers = &servers,
                .tools = &mcp_tools,
            };
            const grants = [_]types.PermissionGrant{.{
                .tool_name = @constCast("shell"),
                .target_path = @constCast("*"),
            }};
            return HostAuthority.captureWithPermissionStateAndMcpView(
                alloc,
                &.{ "shell", "read_file", "write_file", "edit_file", "fossil_workspace", "subagent", "web_fetch", "web_search" },
                &.{"mcp_browseros-neo_run"},
                .{},
                &grants,
                .{},
                &view,
            ) catch return error.OutOfMemory;
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    var parent = try sessions.startWritableSession(alloc, .{
        .id = @constCast("quarantine-parent"),
        .origin_workspace_root = @constCast(home),
        .workspace_root = @constCast(home),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    });
    defer parent.deinit(alloc);

    const store = child_state.Store{ .backend = .{ .v1 = &sessions }, .parent_id = "quarantine-parent" };
    var registry = try child_state.Registry.init(alloc, "quarantine-parent");
    defer registry.deinit(alloc);

    var reader_work = child_state.ActiveWork{
        .id = try alloc.dupe(u8, "reader-work"),
        .message = try alloc.dupe(u8, "fetch page"),
        .permission_mode = .yolo,
        .trust_policy = .{ .tier = .untrusted, .untrusted_mode = .reader },
        .created_at_ms = 1,
    };
    defer reader_work.deinit(alloc);
    try registry.appendOneOff(alloc, "quarantine-reader", reader_work);

    var chat_work = child_state.ActiveWork{
        .id = try alloc.dupe(u8, "chat-work"),
        .message = try alloc.dupe(u8, "parse email"),
        .permission_mode = .yolo,
        .trust_policy = .{ .tier = .untrusted, .untrusted_mode = .chat },
        .created_at_ms = 2,
    };
    defer chat_work.deinit(alloc);
    try registry.appendOneOff(alloc, "quarantine-chat", chat_work);
    try store.save(alloc, registry);

    var resolver = Resolver{
        .backend = .{ .v1 = &sessions },
        .root_id = "quarantine-parent",
        .host = .{ .resolve_fn = Fixture.resolve },
    };

    // Untrusted reader child: ONLY web_fetch and web_search; zero MCP; zero personal grants.
    var reader_snapshot = try resolver.resolve(alloc, "quarantine-reader");
    defer reader_snapshot.deinit(alloc);
    try std.testing.expectEqual(trust_tier.TrustTier.untrusted, reader_snapshot.trust_policy.tier);
    try std.testing.expectEqual(trust_tier.UntrustedMode.reader, reader_snapshot.trust_policy.untrusted_mode);
    try std.testing.expectEqual(@as(usize, 2), reader_snapshot.tools.len);
    try std.testing.expectEqualStrings("web_fetch", reader_snapshot.tools[0]);
    try std.testing.expectEqualStrings("web_search", reader_snapshot.tools[1]);
    try std.testing.expectEqual(@as(usize, 0), reader_snapshot.integrations.len);
    try std.testing.expect(reader_snapshot.mcp_view == null);
    try std.testing.expectEqual(@as(usize, 0), reader_snapshot.grants.len);

    try std.testing.expectEqual(ToolAuthorityDecision.allow, try decideToolAuthority(alloc, reader_snapshot.view(), home, "web_fetch", "https://example.com", .none));
    try std.testing.expectEqual(ToolAuthorityDecision.allow, try decideToolAuthority(alloc, reader_snapshot.view(), home, "web_search", "zig", .none));
    for ([_][]const u8{ "shell", "read_file", "write_file", "edit_file", "fossil_workspace", "subagent", "mcp_browseros-neo_run" }) |blocked| {
        try std.testing.expectEqual(
            ToolAuthorityDecision.unavailable,
            try decideToolAuthority(alloc, reader_snapshot.view(), home, blocked, blocked, .none),
        );
    }

    // Untrusted chat child: ZERO tools, zero MCP, zero personal grants.
    var chat_snapshot = try resolver.resolve(alloc, "quarantine-chat");
    defer chat_snapshot.deinit(alloc);
    try std.testing.expectEqual(trust_tier.TrustTier.untrusted, chat_snapshot.trust_policy.tier);
    try std.testing.expectEqual(trust_tier.UntrustedMode.chat, chat_snapshot.trust_policy.untrusted_mode);
    try std.testing.expectEqual(@as(usize, 0), chat_snapshot.tools.len);
    try std.testing.expectEqual(@as(usize, 0), chat_snapshot.integrations.len);
    try std.testing.expect(chat_snapshot.mcp_view == null);
    try std.testing.expectEqual(@as(usize, 0), chat_snapshot.grants.len);
    try std.testing.expectEqual(
        ToolAuthorityDecision.unavailable,
        try decideToolAuthority(alloc, chat_snapshot.view(), home, "web_fetch", "https://example.com", .none),
    );
}
