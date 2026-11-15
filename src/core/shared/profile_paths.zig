const std = @import("std");
const io_mod = @import("io.zig");

const Allocator = std.mem.Allocator;

pub const root_dir_name = ".fx";
pub const omos_root_dir_name = ".omos";
pub const workspace_binding_file_name = "omos-workspace.json";
pub const classifier_config_file_name = "classifier.json";
pub const auth_file_name = "auth.json";
pub const chatgpt_auth_file_name = "chatgpt-auth.json";
pub const grok_auth_file_name = "grok-auth.json";
pub const api_key_file_name = "api-key";
pub const sessions_dir_name = "sessions";
/// Side folders older v2 sessions kept (D27): v1's per-session layout, one
/// folder per session id. A session moves out on its first open (D47).
pub const session_files_dir_name = "session-files";
/// Hosted terminal state of v2 sessions, one folder per session id (D45).
pub const terminal_dir_name = "terminal";
pub const prompt_history_file_name = "history.jsonl";
pub const usage_file_name = "usage.jsonl";
pub const usage_recovery_dir_name = "usage-recovery";
pub const backups_dir_name = "backups";
pub const mcp_credentials_dir_name = "mcp-credentials";
pub const mcp_credentials_file_name = "credentials.json";

const settings_file_name = "settings.json";
const mcp_config_file_name = "mcp.json";
const managed_skills_dir_name = "skills";
const logs_dir_name = "logs";
const trace_log_file_name = "trace.log";
const recordings_dir_name = "recordings";

fn dirExistsAbsolute(home: []const u8, sub_name: []const u8) bool {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return false;
    if (home.len == 0 or !std.Io.Dir.path.isAbsolute(home)) return false;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const candidate = std.mem.print(&buf, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), sub_name }) catch return false;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), candidate, .{}) catch return false;
    dir.close(io_mod.getIo());
    return true;
}

pub fn activeRootDirName(home: []const u8) []const u8 {
    if (io_mod.getenv("OMOS_PROFILE_DIR")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, trimmed, ".omos") or std.ascii.eqlIgnoreCase(trimmed, "omos")) return omos_root_dir_name;
        if (std.mem.eql(u8, trimmed, ".fx") or std.ascii.eqlIgnoreCase(trimmed, "fx")) return root_dir_name;
    }
    if (dirExistsAbsolute(home, root_dir_name)) return root_dir_name;
    if (dirExistsAbsolute(home, omos_root_dir_name)) return omos_root_dir_name;
    return root_dir_name;
}

pub fn rootDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home) });
}

pub fn workspaceBindingPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), workspace_binding_file_name });
}

pub fn classifierConfigPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), classifier_config_file_name });
}

pub fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), settings_file_name });
}

pub fn mcpConfigPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), mcp_config_file_name });
}

pub fn mcpCredentialsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), mcp_credentials_dir_name });
}

pub fn mcpCredentialsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{
        home,
        activeRootDirName(home),
        mcp_credentials_dir_name,
        mcp_credentials_file_name,
    });
}

pub fn managedSkillsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), managed_skills_dir_name });
}

pub fn authPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), auth_file_name });
}

pub fn chatgptAuthPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), chatgpt_auth_file_name });
}

pub fn apiKeyPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), api_key_file_name });
}

pub fn sessionsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), sessions_dir_name });
}

pub fn promptHistoryPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), prompt_history_file_name });
}

pub fn backupsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), backups_dir_name });
}

pub fn logsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), logs_dir_name });
}

pub fn traceLogPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), logs_dir_name, trace_log_file_name });
}

pub const diagnostics_dir_name = "diagnostics";
pub const last_shutdown_report_file_name = "last-shutdown.json";

pub fn lastShutdownReportPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), diagnostics_dir_name, last_shutdown_report_file_name });
}

pub fn recordingsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, activeRootDirName(home), recordings_dir_name });
}

test "profile path helpers preserve current default locations" {
    const alloc = std.testing.allocator;

    const root = try rootDir(alloc, "/tmp/fake-home");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx", root);

    const settings = try settingsPath(alloc, "/tmp/fake-home");
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/settings.json", settings);

    const mcp = try mcpConfigPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/mcp.json", mcp);

    const mcp_credentials_dir = try mcpCredentialsDir(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials_dir);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials",
        mcp_credentials_dir,
    );

    const mcp_credentials = try mcpCredentialsPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials/credentials.json",
        mcp_credentials,
    );

    const skills = try managedSkillsDir(alloc, "/tmp/fake-home");
    defer alloc.free(skills);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/skills", skills);

    const auth = try authPath(alloc, "/tmp/fake-home");
    defer alloc.free(auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/auth.json", auth);

    const chatgpt_auth = try chatgptAuthPath(alloc, "/tmp/fake-home");
    defer alloc.free(chatgpt_auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/chatgpt-auth.json", chatgpt_auth);

    const api_key = try apiKeyPath(alloc, "/tmp/fake-home");
    defer alloc.free(api_key);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/api-key", api_key);

    const sessions = try sessionsDir(alloc, "/tmp/fake-home");
    defer alloc.free(sessions);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/sessions", sessions);

    const history = try promptHistoryPath(alloc, "/tmp/fake-home");
    defer alloc.free(history);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/history.jsonl", history);

    const backups = try backupsDir(alloc, "/tmp/fake-home");
    defer alloc.free(backups);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/backups", backups);

    const logs = try logsDir(alloc, "/tmp/fake-home");
    defer alloc.free(logs);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs", logs);

    const trace = try traceLogPath(alloc, "/tmp/fake-home");
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs/trace.log", trace);

    const recordings = try recordingsDir(alloc, "/tmp/fake-home");
    defer alloc.free(recordings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/recordings", recordings);

    const binding = try workspaceBindingPath(alloc, "/tmp/fake-home");
    defer alloc.free(binding);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/omos-workspace.json", binding);

    const classifier = try classifierConfigPath(alloc, "/tmp/fake-home");
    defer alloc.free(classifier);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/classifier.json", classifier);
}

test "activeRootDirName selects .omos when only .omos exists and preserves .fx when .fx exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "omos-only/.omos");
    const omos_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "omos-only");
    defer alloc.free(omos_home);
    try std.testing.expectEqualStrings(".omos", activeRootDirName(omos_home));

    try tmp.dir.createDirPath(std.testing.io, "omos-only/.fx");
    try std.testing.expectEqualStrings(".fx", activeRootDirName(omos_home));
}
