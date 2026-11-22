const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TrustTier = enum {
    private,
    shared,
    untrusted,

    pub fn label(self: TrustTier) []const u8 {
        return switch (self) {
            .private => "private",
            .shared => "shared",
            .untrusted => "untrusted",
        };
    }
};

pub const UntrustedMode = enum {
    chat,
    reader,

    pub fn label(self: UntrustedMode) []const u8 {
        return switch (self) {
            .chat => "chat",
            .reader => "reader",
        };
    }
};

pub const CallDecision = union(enum) {
    allowed,
    denied: []const u8,
};

pub const Policy = struct {
    tier: TrustTier = .private,
    untrusted_mode: UntrustedMode = .chat,

    pub const private: Policy = .{ .tier = .private, .untrusted_mode = .chat };

    pub fn allowsPersonalFossil(self: Policy) bool {
        return self.tier == .private;
    }

    pub fn allowsProjectContext(self: Policy) bool {
        return self.tier != .untrusted;
    }

    pub fn allowsPersonalSkills(self: Policy) bool {
        return self.tier == .private;
    }

    pub fn allowsWorkspaceSkills(self: Policy) bool {
        return self.tier != .untrusted;
    }

    pub fn allowsMcp(self: Policy) bool {
        return self.tier != .untrusted;
    }

    pub fn allowsMcpServer(self: Policy, server_name: []const u8) bool {
        return switch (self.tier) {
            .private => true,
            .shared => !isAuthenticatedBrowserMcpName(server_name),
            .untrusted => false,
        };
    }

    pub fn allowsMcpTool(self: Policy, tool_name: []const u8) bool {
        return switch (self.tier) {
            .private => true,
            .shared => !isAuthenticatedBrowserMcpName(tool_name),
            .untrusted => false,
        };
    }

    pub fn allowsToolAdvertisement(self: Policy, tool_name: []const u8) bool {
        return switch (self.tier) {
            .private => true,
            .untrusted => switch (self.untrusted_mode) {
                .chat => false,
                .reader => isUntrustedReaderTool(tool_name),
            },
            .shared => !isSharedBlockedTool(tool_name),
        };
    }

    pub fn checkToolCall(self: Policy, tool_name: []const u8, arguments_json: []const u8) CallDecision {
        return switch (self.tier) {
            .private => .allowed,
            .untrusted => switch (self.untrusted_mode) {
                .chat => .{ .denied = "Tool execution is disabled in the untrusted chat trust tier." },
                .reader => if (isUntrustedReaderTool(tool_name))
                    .allowed
                else
                    .{ .denied = "Only web_fetch and web_search are permitted in the untrusted reader trust tier." },
            },
            .shared => checkSharedToolCall(tool_name, arguments_json),
        };
    }

    /// Returns true when the host must require explicit owner approval before
    /// executing this tool call and never auto-clear it via yolo, auto-review,
    /// direct-command bypass, or inherited personal allow rules.
    pub fn requiresExplicitApproval(self: Policy, tool_name: []const u8, is_dynamic_or_command: bool) bool {
        if (self.tier != .shared) return false;
        if (is_dynamic_or_command) return true;
        return std.mem.eql(u8, tool_name, "shell") or
            std.mem.eql(u8, tool_name, "bash") or
            std.mem.eql(u8, tool_name, "run_command") or
            std.mem.eql(u8, tool_name, "write_file") or
            std.mem.eql(u8, tool_name, "edit_file") or
            std.mem.eql(u8, tool_name, "install_skill") or
            std.mem.eql(u8, tool_name, "subagent") or
            std.mem.eql(u8, tool_name, "fossil_workspace") or
            std.mem.eql(u8, tool_name, "mcp_features");
    }
};

pub fn parseTrustTier(raw: []const u8) ?TrustTier {
    if (std.mem.eql(u8, raw, "private")) return .private;
    if (std.mem.eql(u8, raw, "shared")) return .shared;
    if (std.mem.eql(u8, raw, "untrusted")) return .untrusted;
    return null;
}

pub fn parseUntrustedMode(raw: []const u8) ?UntrustedMode {
    if (std.mem.eql(u8, raw, "chat")) return .chat;
    if (std.mem.eql(u8, raw, "reader")) return .reader;
    return null;
}

pub fn parsePolicy(
    trust_tier_raw: ?[]const u8,
    untrusted_mode_raw: ?[]const u8,
) error{InvalidTrustTier}!Policy {
    const tier = if (trust_tier_raw) |raw|
        parseTrustTier(raw) orelse return error.InvalidTrustTier
    else
        TrustTier.private;

    if (untrusted_mode_raw) |mode_raw| {
        if (tier != .untrusted) return error.InvalidTrustTier;
        const mode = parseUntrustedMode(mode_raw) orelse return error.InvalidTrustTier;
        return .{ .tier = .untrusted, .untrusted_mode = mode };
    }

    return .{ .tier = tier, .untrusted_mode = .chat };
}

pub fn isAuthenticatedBrowserMcpName(name: []const u8) bool {
    return asciiStartsWithIgnoreCase(name, "mcp_browseros-neo_") or
        asciiStartsWithIgnoreCase(name, "mcp_browseros_neo_") or
        asciiStartsWithIgnoreCase(name, "browseros-neo") or
        asciiStartsWithIgnoreCase(name, "browseros_neo");
}

pub fn formatDeniedJson(
    alloc: Allocator,
    tool_name: []const u8,
    policy: Policy,
    reason: []const u8,
) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .@"error" = .{
            .code = "TrustTierDenied",
            .tool = tool_name,
            .trust_tier = policy.tier.label(),
            .untrusted_mode = if (policy.tier == .untrusted) policy.untrusted_mode.label() else null,
            .message = reason,
        },
    }, .{}) catch return error.OutOfMemory;
}

fn isUntrustedReaderTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch") or
        std.mem.eql(u8, tool_name, "web_search");
}

fn isSharedBlockedTool(tool_name: []const u8) bool {
    if (isAuthenticatedBrowserMcpName(tool_name)) return true;
    return std.mem.eql(u8, tool_name, "fossil_workspace") or
        std.mem.eql(u8, tool_name, "workspace_content") or
        std.mem.eql(u8, tool_name, "install_skill") or
        std.mem.eql(u8, tool_name, "subagent");
}

fn checkSharedToolCall(tool_name: []const u8, arguments_json: []const u8) CallDecision {
    if (isAuthenticatedBrowserMcpName(tool_name)) {
        return .{ .denied = "Authenticated browser MCP tools are blocked in the shared trust tier." };
    }
    if (std.mem.eql(u8, tool_name, "workspace_content")) {
        return .{ .denied = "Personal workspace content retrieval is blocked in the shared trust tier." };
    }
    if (std.mem.eql(u8, tool_name, "install_skill")) {
        return .{ .denied = "Skill installation is blocked in the shared trust tier." };
    }
    if (std.mem.eql(u8, tool_name, "subagent")) {
        return .{ .denied = "Subagent delegation is blocked in the shared trust tier." };
    }
    if (std.mem.eql(u8, tool_name, "fossil_workspace")) {
        return checkSharedFossilWorkspaceCall(arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "mcp_select_tool")) {
        return checkSharedMcpSelection(arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "mcp_features") or std.mem.eql(u8, tool_name, "capability_search")) {
        return checkSharedMcpServerArg(arguments_json);
    }
    return .allowed;
}

fn checkSharedFossilWorkspaceCall(arguments_json: []const u8) CallDecision {
    var buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), arguments_json, .{}) catch {
        return .{ .denied = "Fossil workspace mutations and private actions are blocked in the shared trust tier." };
    };
    if (parsed.value != .object) {
        return .{ .denied = "Fossil workspace mutations and private actions are blocked in the shared trust tier." };
    }
    const obj = parsed.value.object;
    const action_val = obj.get("action") orelse {
        return .{ .denied = "Fossil workspace mutations and private actions are blocked in the shared trust tier." };
    };
    if (action_val != .string) {
        return .{ .denied = "Fossil workspace mutations and private actions are blocked in the shared trust tier." };
    }
    const action = action_val.string;

    // Block all mutating, governance, and private inventory/record actions.
    if (std.mem.eql(u8, action, "write") or
        std.mem.eql(u8, action, "artifact") or
        std.mem.eql(u8, action, "record") or
        std.mem.eql(u8, action, "propose_definition") or
        std.mem.eql(u8, action, "promote_capability") or
        std.mem.eql(u8, action, "distill_capability") or
        std.mem.eql(u8, action, "restore_ui") or
        std.mem.eql(u8, action, "verify_runtime") or
        std.mem.eql(u8, action, "dispatch") or
        std.mem.eql(u8, action, "workers") or
        std.mem.eql(u8, action, "query") or
        std.mem.eql(u8, action, "history") or
        std.mem.eql(u8, action, "status"))
    {
        return .{ .denied = "Fossil workspace mutating and private actions are blocked in the shared trust tier." };
    }

    if (std.mem.eql(u8, action, "read")) {
        const path_val = obj.get("path") orelse {
            return .{ .denied = "Reading private Fossil paths is blocked in the shared trust tier." };
        };
        if (path_val != .string or isPrivateFossilPath(path_val.string)) {
            return .{ .denied = "Reading private Fossil memory or runtime paths is blocked in the shared trust tier." };
        }
        return .allowed;
    }

    if (std.mem.eql(u8, action, "definition") or
        std.mem.eql(u8, action, "diff") or
        std.mem.eql(u8, action, "verify_manifest"))
    {
        if (obj.get("path")) |path_val| {
            if (path_val != .string or isPrivateFossilPath(path_val.string)) {
                return .{ .denied = "Accessing private Fossil memory or runtime paths is blocked in the shared trust tier." };
            }
        }
        return .allowed;
    }

    return .{ .denied = "Unsupported Fossil workspace action is blocked in the shared trust tier." };
}

fn isPrivateFossilPath(raw_path: []const u8) bool {
    const path = std.mem.trimStart(u8, raw_path, " \t\r\n");
    if (path.len == 0) return true;
    if (path[0] == '/' or path[0] == '\\') return true;
    if (std.mem.find(u8, path, "..") != null) return true;
    var trimmed = path;
    while (std.mem.startsWith(u8, trimmed, "./")) {
        trimmed = trimmed[2..];
    }
    const private_roots = [_][]const u8{ "memory", "runtime", "tasks", "records", "history" };
    for (private_roots) |root| {
        if (std.mem.eql(u8, trimmed, root)) return true;
        if (trimmed.len > root.len and
            std.mem.startsWith(u8, trimmed, root) and
            (trimmed[root.len] == '/' or trimmed[root.len] == '\\'))
        {
            return true;
        }
    }
    return false;
}

fn checkSharedMcpSelection(arguments_json: []const u8) CallDecision {
    var buf: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), arguments_json, .{}) catch return .allowed;
    if (parsed.value != .object) return .allowed;
    if (parsed.value.object.get("name")) |name_val| {
        if (name_val == .string and isAuthenticatedBrowserMcpName(name_val.string)) {
            return .{ .denied = "Authenticated browser MCP tools are blocked in the shared trust tier." };
        }
    }
    return .allowed;
}

fn checkSharedMcpServerArg(arguments_json: []const u8) CallDecision {
    var buf: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), arguments_json, .{}) catch return .allowed;
    if (parsed.value != .object) return .allowed;
    if (parsed.value.object.get("server")) |server_val| {
        if (server_val == .string and isAuthenticatedBrowserMcpName(server_val.string)) {
            return .{ .denied = "Authenticated browser MCP servers are blocked in the shared trust tier." };
        }
    }
    return .allowed;
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

test "parseTrustTier and parseUntrustedMode parse exact canonical labels" {
    try std.testing.expectEqual(@as(?TrustTier, .private), parseTrustTier("private"));
    try std.testing.expectEqual(@as(?TrustTier, .shared), parseTrustTier("shared"));
    try std.testing.expectEqual(@as(?TrustTier, .untrusted), parseTrustTier("untrusted"));
    try std.testing.expectEqual(@as(?TrustTier, null), parseTrustTier("admin"));
    try std.testing.expectEqual(@as(?TrustTier, null), parseTrustTier("PRIVATE"));
    try std.testing.expectEqual(@as(?TrustTier, null), parseTrustTier(""));

    try std.testing.expectEqual(@as(?UntrustedMode, .chat), parseUntrustedMode("chat"));
    try std.testing.expectEqual(@as(?UntrustedMode, .reader), parseUntrustedMode("reader"));
    try std.testing.expectEqual(@as(?UntrustedMode, null), parseUntrustedMode("shell"));
    try std.testing.expectEqual(@as(?UntrustedMode, null), parseUntrustedMode(""));

    try std.testing.expectEqualStrings("private", TrustTier.private.label());
    try std.testing.expectEqualStrings("shared", TrustTier.shared.label());
    try std.testing.expectEqualStrings("untrusted", TrustTier.untrusted.label());
    try std.testing.expectEqualStrings("chat", UntrustedMode.chat.label());
    try std.testing.expectEqualStrings("reader", UntrustedMode.reader.label());
}

test "parsePolicy rejects invalid tier and untrusted_mode outside untrusted tier" {
    const default_policy = try parsePolicy(null, null);
    try std.testing.expectEqual(TrustTier.private, default_policy.tier);
    try std.testing.expectEqual(UntrustedMode.chat, default_policy.untrusted_mode);

    const shared_policy = try parsePolicy("shared", null);
    try std.testing.expectEqual(TrustTier.shared, shared_policy.tier);

    const reader_policy = try parsePolicy("untrusted", "reader");
    try std.testing.expectEqual(TrustTier.untrusted, reader_policy.tier);
    try std.testing.expectEqual(UntrustedMode.reader, reader_policy.untrusted_mode);

    const default_untrusted = try parsePolicy("untrusted", null);
    try std.testing.expectEqual(TrustTier.untrusted, default_untrusted.tier);
    try std.testing.expectEqual(UntrustedMode.chat, default_untrusted.untrusted_mode);

    try std.testing.expectError(error.InvalidTrustTier, parsePolicy("bogus", null));
    try std.testing.expectError(error.InvalidTrustTier, parsePolicy(null, "reader"));
    try std.testing.expectError(error.InvalidTrustTier, parsePolicy("private", "chat"));
    try std.testing.expectError(error.InvalidTrustTier, parsePolicy("shared", "reader"));
    try std.testing.expectError(error.InvalidTrustTier, parsePolicy("untrusted", "bogus"));
}

test "private trust tier keeps full default access" {
    const policy = Policy.private;
    try std.testing.expect(policy.allowsPersonalFossil());
    try std.testing.expect(policy.allowsProjectContext());
    try std.testing.expect(policy.allowsPersonalSkills());
    try std.testing.expect(policy.allowsMcp());
    try std.testing.expect(policy.allowsMcpServer("browseros-neo"));
    try std.testing.expect(policy.allowsMcpTool("mcp_browseros-neo_run"));
    try std.testing.expect(policy.allowsToolAdvertisement("shell"));
    try std.testing.expect(policy.allowsToolAdvertisement("fossil_workspace"));
    try std.testing.expect(policy.allowsToolAdvertisement("read_file"));
    try std.testing.expect(policy.allowsToolAdvertisement("write_file"));
    try std.testing.expect(policy.checkToolCall("shell", "{\"action\":\"run\",\"command\":\"ls\"}") == .allowed);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"write\",\"path\":\"memory/a.md\",\"content\":\"x\"}") == .allowed);
    try std.testing.expect(policy.checkToolCall("mcp_browseros-neo_run", "{}") == .allowed);
    try std.testing.expect(!policy.requiresExplicitApproval("shell", true));
    try std.testing.expect(!policy.requiresExplicitApproval("write_file", false));
}

test "untrusted chat trust tier denies all tools at advertisement and dispatch" {
    const policy: Policy = .{ .tier = .untrusted, .untrusted_mode = .chat };
    try std.testing.expect(!policy.allowsPersonalFossil());
    try std.testing.expect(!policy.allowsProjectContext());
    try std.testing.expect(!policy.allowsPersonalSkills());
    try std.testing.expect(!policy.allowsWorkspaceSkills());
    try std.testing.expect(!policy.allowsMcp());
    try std.testing.expect(!policy.allowsMcpServer("any-server"));
    try std.testing.expect(!policy.allowsMcpTool("mcp_any_tool"));

    for ([_][]const u8{
        "read_file",
        "write_file",
        "edit_file",
        "glob_files",
        "grep_files",
        "shell",
        "fossil_workspace",
        "workspace_content",
        "subagent",
        "web_fetch",
        "web_search",
        "mcp_browseros-neo_run",
    }) |tool_name| {
        try std.testing.expect(!policy.allowsToolAdvertisement(tool_name));
        try std.testing.expect(policy.checkToolCall(tool_name, "{}") == .denied);
    }
}

test "untrusted reader trust tier allows only web_fetch and web_search" {
    const policy: Policy = .{ .tier = .untrusted, .untrusted_mode = .reader };
    try std.testing.expect(!policy.allowsPersonalFossil());
    try std.testing.expect(!policy.allowsProjectContext());
    try std.testing.expect(!policy.allowsMcp());

    try std.testing.expect(policy.allowsToolAdvertisement("web_fetch"));
    try std.testing.expect(policy.allowsToolAdvertisement("web_search"));
    try std.testing.expect(policy.checkToolCall("web_fetch", "{\"url\":\"https://example.com\"}") == .allowed);
    try std.testing.expect(policy.checkToolCall("web_search", "{\"query\":\"zig\"}") == .allowed);

    for ([_][]const u8{
        "shell",
        "read_file",
        "write_file",
        "edit_file",
        "glob_files",
        "grep_files",
        "fossil_workspace",
        "workspace_content",
        "subagent",
        "skill",
        "install_skill",
        "capability_search",
        "mcp_select_tool",
        "mcp_browseros-neo_run",
    }) |tool_name| {
        try std.testing.expect(!policy.allowsToolAdvertisement(tool_name));
        try std.testing.expect(policy.checkToolCall(tool_name, "{}") == .denied);
    }
}

test "shared trust tier blocks browseros-neo MCP, private Fossil actions, and requires explicit approval for mutations" {
    const policy: Policy = .{ .tier = .shared };
    try std.testing.expect(!policy.allowsPersonalFossil());
    try std.testing.expect(policy.allowsProjectContext());
    try std.testing.expect(!policy.allowsPersonalSkills());
    try std.testing.expect(policy.allowsWorkspaceSkills());
    try std.testing.expect(policy.allowsMcp());

    // Authenticated browser MCP blocked
    try std.testing.expect(!policy.allowsMcpServer("browseros-neo"));
    try std.testing.expect(!policy.allowsMcpServer("BrowserOS-Neo"));
    try std.testing.expect(policy.allowsMcpServer("github"));
    try std.testing.expect(!policy.allowsMcpTool("mcp_browseros-neo_run"));
    try std.testing.expect(!policy.allowsMcpTool("browseros-neo_tabs"));
    try std.testing.expect(policy.allowsMcpTool("mcp_github_list_issues"));
    try std.testing.expect(policy.checkToolCall("mcp_browseros-neo_run", "{}") == .denied);
    try std.testing.expect(policy.checkToolCall("mcp_select_tool", "{\"name\":\"mcp_browseros-neo_run\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("mcp_select_tool", "{\"name\":\"mcp_\\u0062rowseros-neo_run\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("mcp_features", "{\"server\":\"browseros-neo\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("capability_search", "{\"query\":\"browser\",\"server\":\"browseros-neo\"}") == .denied);

    // Private/mutating Fossil actions blocked
    try std.testing.expect(!policy.allowsToolAdvertisement("fossil_workspace"));
    try std.testing.expect(!policy.allowsToolAdvertisement("workspace_content"));
    try std.testing.expect(!policy.allowsToolAdvertisement("install_skill"));
    try std.testing.expect(!policy.allowsToolAdvertisement("subagent"));
    try std.testing.expect(policy.checkToolCall("workspace_content", "{\"action\":\"conversations\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"read\",\"path\":\"memory/notes.md\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"read\",\"path\":\"\\u006demory/notes.md\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"read\",\"path\":\"./memory/notes.md\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"read\",\"path\":\"documents/../memory/notes.md\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"write\",\"path\":\"documents/a.md\",\"content\":\"hi\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"propose_definition\",\"content\":\"{}\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"promote_capability\",\"path\":\"c.json\",\"entity\":\"cap\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"distill_capability\",\"task_id\":\"t1\",\"capability_id\":\"c1\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"restore_ui\",\"revision\":\"abc\"}") == .denied);
    try std.testing.expect(policy.checkToolCall("fossil_workspace", "{\"action\":\"dispatch\"}") == .denied);

    // Explicit approval required for shell, file writes/edits, and dynamic MCP tools
    try std.testing.expect(policy.requiresExplicitApproval("shell", true));
    try std.testing.expect(policy.requiresExplicitApproval("shell", false));
    try std.testing.expect(policy.requiresExplicitApproval("write_file", false));
    try std.testing.expect(policy.requiresExplicitApproval("edit_file", false));
    try std.testing.expect(policy.requiresExplicitApproval("mcp_github_create_issue", true));
    try std.testing.expect(!policy.requiresExplicitApproval("read_file", false));
    try std.testing.expect(!policy.requiresExplicitApproval("glob_files", false));
    try std.testing.expect(!policy.requiresExplicitApproval("grep_files", false));
}

test "formatDeniedJson emits structured TrustTierDenied payload" {
    const alloc = std.testing.allocator;
    const json = try formatDeniedJson(
        alloc,
        "shell",
        .{ .tier = .untrusted, .untrusted_mode = .reader },
        "Only web_fetch and web_search are permitted in the untrusted reader trust tier.",
    );
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"code\":\"TrustTierDenied\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"tool\":\"shell\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"trust_tier\":\"untrusted\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"untrusted_mode\":\"reader\"") != null);
}
