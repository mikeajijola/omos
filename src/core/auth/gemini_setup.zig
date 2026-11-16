const std = @import("std");
const config = @import("../config/config_runtime.zig");
const configured_provider = @import("../config/configured_provider.zig");
const model_provider = @import("../config/model_provider.zig");

pub const key_slot = "GEMINI_API_KEY";
pub const default_model = "gemini-2.5-flash";
// Google's OpenAI compatibility endpoint supports bearer API keys, streaming,
// and function calls: https://ai.google.dev/gemini-api/docs/openai.
pub const definition_json =
    \\{"protocol":"openai-chat-completions","base_url":"https://generativelanguage.googleapis.com/v1beta/openai","auth":{"type":"bearer","env":"GEMINI_API_KEY"},"tool_choice_mode":"send","reviewer_model":"gemini-2.5-flash","model_metadata":{"gemini-2.5-flash":{"supports_tool_use":true,"supports_vision":true}}}
;

/// Refuse to replace another endpoint's credential slot when its owner has
/// already used the preset name. No secrets are loaded during this check.
pub fn checkConnection(alloc: std.mem.Allocator) !void {
    var existing = try config.loadConfiguredProviders(alloc);
    defer existing.deinit(alloc);
    var preset = try configured_provider.Registry.parse_json(alloc, "{\"gemini\":" ++ definition_json ++ "}");
    defer preset.deinit(alloc);
    if (existing.get("gemini")) |definition| {
        if (!std.mem.eql(u8, &definition.binding_identity(), &preset.get("gemini").?.binding_identity())) return error.ConnectionAlreadyExists;
    }
}

pub fn saveConnection(alloc: std.mem.Allocator) !void {
    const provider = model_provider.parse("gemini").?;
    var outcome = try config.setUserPreferences(alloc, .{
        .connection = .{ .id = "gemini", .definition_json = definition_json },
        .provider = provider,
        .model_preference = .{ .provider = provider, .model = default_model },
    });
    defer outcome.deinit(alloc);
}
