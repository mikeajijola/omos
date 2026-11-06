//! Fresh native sessions for reserved recurring occurrences. Source history,
//! permissions, credentials and replay state never enter the new session.
const std = @import("std");
const sessions = @import("../session/session_store.zig");
const codec = @import("../session/session_codec.zig");
const session = @import("../session/session.zig");
const io = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const Blueprint = struct {
    preferences: struct {
        provider: @import("../config/model_provider.zig").ProviderId,
        model: []const u8,
        effort: []const u8,
        fast_mode: bool,
        ultrafast_mode: bool = false,
    },
    language: []const u8,
};

/// The caller owns all returned string slices through alloc; an operation
/// arena can release them together after the template is serialized.
pub fn pin(alloc: std.mem.Allocator, project: []const u8, source_session_hash: []const u8) !Blueprint {
    var store = try sessions.Store.initReadOnly(alloc, project);
    defer store.deinit(alloc);
    var candidates = try store.list(alloc);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(alloc);
        candidates.deinit(alloc);
    }
    for (candidates.items) |candidate| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(candidate.id, &hash, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), source_session_hash)) continue;
        var source = try store.loadReadOnly(alloc, candidate.id);
        defer source.deinit(alloc);
        if (source.subagent_child or !std.mem.eql(u8, source.workspace_root, project)) return error.TaskProjectMismatch;
        return .{ .preferences = .{ .provider = source.preferences.provider, .model = try alloc.dupe(u8, source.preferences.model), .effort = try alloc.dupe(u8, source.preferences.effort.label()), .fast_mode = source.preferences.fast_mode, .ultrafast_mode = source.preferences.ultrafast_mode }, .language = try alloc.dupe(u8, source.conversation_language.view()) };
    }
    return error.NativeSessionUnavailable;
}

/// Creates or verifies the same pristine session after an interrupted
/// reservation. A non-pristine collision is retained for inspection.
pub fn prepare(alloc: std.mem.Allocator, project: []const u8, id: []const u8, blueprint: Blueprint) !void {
    const effort = types.ReasoningEffort.parse(blueprint.preferences.effort) orelse return error.InvalidSeriesTemplate;
    const language = try session.ConversationLanguage.fromSlice(blueprint.language);
    if (blueprint.preferences.model.len == 0 or blueprint.preferences.model.len > 4096) return error.InvalidSeriesTemplate;
    if (blueprint.preferences.provider == .configured) {
        var registry = try @import("../config/config_runtime.zig").loadConfiguredProviders(alloc);
        defer registry.deinit(alloc);
        _ = try blueprint.preferences.provider.bind(registry);
    }
    const canonical = try io.realpathAlloc(alloc, project);
    defer alloc.free(canonical);
    if (!std.mem.eql(u8, canonical, project)) return error.TaskProjectMismatch;
    var store = try sessions.Store.init(alloc, project);
    defer store.deinit(alloc);
    var existing: ?codec.DurableSessionState = store.loadReadOnly(alloc, id) catch |err| switch (err) {
        error.SessionNotFound, error.FileNotFound => null,
        else => return err,
    };
    if (existing) |*state| {
        defer state.deinit(alloc);
        if (!std.mem.eql(u8, state.workspace_root, project) or !std.mem.eql(u8, state.origin_workspace_root, project) or state.history.len != 0 or state.recovery_checkpoint != null or state.subagent_child or state.permission_state.rules.items.len != 0 or state.total_input_tokens != 0 or state.total_output_tokens != 0) return error.AmbiguousRecurringSession;
        if (!state.preferences.provider.eql(blueprint.preferences.provider) or !std.mem.eql(u8, state.preferences.model, blueprint.preferences.model) or !std.mem.eql(u8, state.preferences.effort.label(), blueprint.preferences.effort) or state.preferences.fast_mode != blueprint.preferences.fast_mode or state.preferences.ultrafast_mode != blueprint.preferences.ultrafast_mode or !std.mem.eql(u8, state.conversation_language.view(), blueprint.language)) return error.AmbiguousRecurringSession;
        return;
    }
    const now = io.milliTimestamp();
    var initial: codec.DurableSessionState = .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, project),
        .workspace_root = try alloc.dupe(u8, project),
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = language,
        .preferences = .{ .provider = blueprint.preferences.provider, .model = try alloc.dupe(u8, blueprint.preferences.model), .effort = effort, .fast_mode = blueprint.preferences.fast_mode, .ultrafast_mode = blueprint.preferences.ultrafast_mode },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    defer initial.deinit(alloc);
    var created = try store.startWritableSession(alloc, initial);
    defer created.deinit(alloc);
}
