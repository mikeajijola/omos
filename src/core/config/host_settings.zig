//! Typed owner controls shared with the trusted local browser shell.
//! Never expose this mutation endpoint to workspace-authored JavaScript.
const std = @import("std");
const config = @import("config_runtime.zig");
const store = @import("settings_store.zig");
const providers = @import("model_provider.zig");
const catalog = @import("settings_catalog.zig");
const types = @import("../shared/types.zig");
const io = @import("../shared/io.zig");

pub const Request = struct {
    action: enum { read, set, workspace, permission } = .read,
    key: []const u8 = "",
    value: []const u8 = "",
    category: []const u8 = "",
};

fn boolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return error.InvalidSettingValue;
}

fn patchFor(settings: *const config.Settings, key: []const u8, value: []const u8) !store.UserSettingsPatch {
    var patch: store.UserSettingsPatch = .{};
    if (std.mem.eql(u8, key, "provider")) {
        const selected = providers.parse(value) orelse return error.InvalidProvider;
        patch.provider = try selected.bind(settings.providers orelse .{});
    } else if (std.mem.eql(u8, key, "review_model")) {
        if (value.len == 0) patch.clear_review_model = true else {
            try store.validateModel(value);
            patch.review_model = value;
        }
    } else if (std.mem.eql(u8, key, "model")) {
        try store.validateModel(value);
        patch.model_preference = .{ .provider = settings.provider orelse .gateway, .model = value };
    } else if (std.mem.eql(u8, key, "effort")) {
        patch.effort = types.ReasoningEffort.parse(value) orelse return error.InvalidSettingValue;
    } else if (std.mem.eql(u8, key, "permission_mode")) {
        patch.permission_mode = types.PermissionMode.parse(value) orelse return error.InvalidSettingValue;
        if (patch.permission_mode.? == .yolo) patch.yolo_acknowledged = true;
    } else if (std.mem.eql(u8, key, "sound_level")) {
        if (!std.mem.eql(u8, value, "off") and !std.mem.eql(u8, value, "on") and !std.mem.eql(u8, value, "max")) return error.InvalidSettingValue;
        patch.notification_turn_end = !std.mem.eql(u8, value, "off");
        patch.notification_attention_required = patch.notification_turn_end;
        patch.notification_max = std.mem.eql(u8, value, "max");
    } else if (std.mem.startsWith(u8, key, "statusline_")) {
        const item = std.meta.stringToEnum(store.StatuslineItem, key[11..]) orelse return error.UnknownSetting;
        patch.statusline_item = .{ .item = item, .enabled = try boolean(value) };
    } else if (std.mem.eql(u8, key, "prompt_history")) {
        patch.prompt_history_enabled = try boolean(value);
    } else {
        inline for (.{ "fast_mode", "ultrafast_mode", "slash_menu_categories", "collapse_tool_calls", "session_titles", "startup_scrollback" }) |field| {
            if (std.mem.eql(u8, key, field)) {
                @field(patch, field) = try boolean(value);
                return patch;
            }
        }
        return error.UnknownSetting;
    }
    return patch;
}

pub fn execute(alloc: std.mem.Allocator, request: Request) ![]const u8 {
    if (request.key.len > 128 or request.value.len > 4096 or request.category.len > 128) return error.InvalidSettingValue;
    const root = try io.realpathAlloc(alloc, ".");
    var settings = try config.loadMergedSettings(alloc, root);
    defer settings.deinit(alloc);
    if (request.action == .set) {
        var result = try config.setUserPreferences(alloc, try patchFor(&settings, request.key, request.value));
        defer result.deinit(alloc);
        return std.json.Stringify.valueAlloc(alloc, .{ .saved = true, .applies = "next_turn", .scope = "user" }, .{});
    }
    if (request.action == .workspace) {
        const patch: store.WorkspaceDirectoryPatch = if (std.mem.eql(u8, request.key, "add")) .{ .add = request.value } else if (std.mem.eql(u8, request.key, "remove")) .{ .remove = request.value } else if (std.mem.eql(u8, request.key, "clear")) .clear else return error.UnknownSetting;
        var result = try config.mutateWorkspaceDirectory(alloc, .{ .workspace_root = root, .patch = patch });
        defer result.deinit(alloc);
        return std.json.Stringify.valueAlloc(alloc, .{ .saved = true, .applies = "next_turn" }, .{});
    }
    if (request.action == .permission) {
        const patch: store.PermissionPatch = if (std.mem.eql(u8, request.key, "remove")) .{ .remove = .{ .category = request.category, .pattern = request.value } } else .{ .add = .{ .category = request.category, .pattern = request.value, .action = config.parsePermissionAction(request.key) orelse return error.InvalidSettingValue } };
        var result = try config.mutatePermission(alloc, .{ .scope = .user, .workspace_root = root, .patch = patch });
        defer result.deinit(alloc);
        return std.json.Stringify.valueAlloc(alloc, .{ .saved = true, .applies = "next_turn" }, .{});
    }
    const provider = settings.provider orelse .gateway;
    const snapshot: catalog.Snapshot = .{
        .model = settings.models.get(provider) orelse "",
        .effort = if (settings.effort) |effort| effort.label() else "default",
        .permission_mode = @tagName(settings.permission_mode orelse config.default_permission_mode),
        .fast_mode = settings.fast_mode orelse false,
        .ultrafast_mode = settings.ultrafast_mode orelse false,
        .slash_menu_categories = settings.slash_menu_categories orelse true,
        .collapse_tool_calls = settings.collapse_tool_calls orelse false,
        .session_titles = settings.session_titles orelse true,
        .startup_scrollback = settings.startup_scrollback orelse true,
        .prompt_history = settings.prompt_history_enabled orelse true,
        .statusline_context = settings.statusline_context orelse false,
        .statusline_session = settings.statusline_session orelse false,
        .statusline_workspace = settings.statusline_workspace orelse false,
        .sound_level = catalog.notificationLevel(settings.notification_turn_end orelse true, settings.notification_attention_required orelse true, settings.notification_max orelse false),
    };
    const Row = struct { key: []const u8, label: []const u8, description: []const u8, value: []const u8, category: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    for (0..catalog.filteredCount(snapshot, .all, "")) |index| {
        const item = catalog.itemAt(snapshot, .all, "", index).?;
        try rows.append(alloc, .{ .key = @tagName(item.id), .label = item.label, .description = item.description, .value = item.value, .category = item.category.label() });
    }
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(alloc, &.{ "gateway", "codex", "grok" });
    if (settings.providers) |registry| for (registry.definitions) |definition| try names.append(alloc, definition.id);
    return std.json.Stringify.valueAlloc(alloc, .{ .settings = rows.items, .provider = provider.label(), .providers = names.items, .review_model = settings.review_model orelse "", .scope = "user", .note = "Saved defaults apply to future turns. Environment and workspace overrides may take precedence. Terminal preferences affect the CLI." }, .{});
}

test "host settings reject unknown keys and invalid values before mutation" {
    const settings: config.Settings = .{};
    try std.testing.expectError(error.UnknownSetting, patchFor(&settings, "credentials", "secret"));
    try std.testing.expectError(error.InvalidSettingValue, patchFor(&settings, "fast_mode", "yes"));
    try std.testing.expectError(error.InvalidSettingValue, patchFor(&settings, "permission_mode", "anything"));
    try std.testing.expect((try patchFor(&settings, "review_model", "")).clear_review_model);
    try std.testing.expectEqual(false, (try patchFor(&settings, "prompt_history", "off")).prompt_history_enabled.?);
}
