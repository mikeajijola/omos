const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

var next_worktree_seq: std.atomic.Value(u64) = .init(0);

/// Per-child isolated Git worktree lease.
/// When `parent_workspace_root` is inside a Git repository with a valid `HEAD`,
/// `acquire` creates a detached worktree under `<git_common_dir>/omos-worktrees/`
/// and sets `workspace_root` to the corresponding directory (preserving any
/// relative subdirectory offset from the repository toplevel).
/// Otherwise, `acquire` returns a no-op lease pointing to `parent_workspace_root`
/// with `isolated = false`.
pub const Lease = struct {
    alloc: Allocator,
    workspace_root: []const u8,
    isolated: bool = false,
    cleaned: bool = false,
    toplevel: ?[]u8 = null,
    worktree_path: ?[]u8 = null,
    owned_workspace_root: ?[]u8 = null,

    pub fn acquire(
        alloc: Allocator,
        parent_workspace_root: []const u8,
        child_id: []const u8,
    ) Allocator.Error!Lease {
        const noop = Lease{
            .alloc = alloc,
            .workspace_root = parent_workspace_root,
            .isolated = false,
        };
        if (comptime builtin.target.cpu.arch.isWasm()) return noop;
        if (parent_workspace_root.len == 0) return noop;

        const raw_toplevel = (try runGitCapture(alloc, parent_workspace_root, &.{
            "rev-parse",
            "--show-toplevel",
        })) orelse return noop;
        defer alloc.free(raw_toplevel);

        const raw_common_dir = (try runGitCapture(alloc, parent_workspace_root, &.{
            "rev-parse",
            "--git-common-dir",
        })) orelse return noop;
        defer alloc.free(raw_common_dir);

        // Ensure HEAD exists (unborn branches cannot be checked out as detached worktrees).
        const head_rev = (try runGitCapture(alloc, parent_workspace_root, &.{
            "rev-parse",
            "--verify",
            "HEAD",
        })) orelse return noop;
        alloc.free(head_rev);

        var real_toplevel: ?[]u8 = io_mod.realpathAlloc(alloc, raw_toplevel) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return noop,
        };
        defer if (real_toplevel) |p| alloc.free(p);

        const real_parent = io_mod.realpathAlloc(alloc, parent_workspace_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return noop,
        };
        defer alloc.free(real_parent);

        const common_dir_abs = if (std.Io.Dir.path.isAbsolute(raw_common_dir))
            try alloc.dupe(u8, raw_common_dir)
        else
            try std.Io.Dir.path.resolveAlloc(alloc, &.{ parent_workspace_root, raw_common_dir });
        defer alloc.free(common_dir_abs);

        const worktrees_dir = try std.Io.Dir.path.join(alloc, &.{ common_dir_abs, "omos-worktrees" });
        defer alloc.free(worktrees_dir);

        std.Io.Dir.cwd().createDirPath(io_mod.getIo(), worktrees_dir) catch return noop;

        const sanitized = try sanitizeChildId(alloc, child_id);
        defer alloc.free(sanitized);

        const wt_path = try allocateUniqueWorktreePath(alloc, worktrees_dir, sanitized);
        defer alloc.free(wt_path);

        const created = try runGitSuccess(alloc, real_toplevel.?, &.{
            "worktree",
            "add",
            "--detach",
            wt_path,
            "HEAD",
        });
        if (!created) {
            return noop;
        }

        var real_wt_path: ?[]u8 = io_mod.realpathAlloc(alloc, wt_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try alloc.dupe(u8, wt_path),
        };
        defer if (real_wt_path) |p| alloc.free(p);

        const rel_subdir = relativeSubdir(real_toplevel.?, real_parent);
        var effective_root: ?[]u8 = if (rel_subdir.len > 0) blk: {
            const joined = try std.Io.Dir.path.join(alloc, &.{ real_wt_path.?, rel_subdir });
            errdefer alloc.free(joined);
            std.Io.Dir.cwd().createDirPath(io_mod.getIo(), joined) catch {};
            break :blk joined;
        } else try alloc.dupe(u8, real_wt_path.?);
        defer if (effective_root) |p| alloc.free(p);

        const owned_toplevel = real_toplevel;
        real_toplevel = null;
        const owned_wt_path = real_wt_path;
        real_wt_path = null;
        const owned_root = effective_root;
        effective_root = null;

        return .{
            .alloc = alloc,
            .workspace_root = owned_root.?,
            .isolated = true,
            .cleaned = false,
            .toplevel = owned_toplevel,
            .worktree_path = owned_wt_path,
            .owned_workspace_root = owned_root,
        };
    }

    /// Removes the worktree if it is clean; leaves it intact if there are
    /// uncommitted or untracked changes so subagent work is never lost.
    pub fn cleanup(self: *Lease) void {
        if (!self.isolated or self.cleaned) return;
        self.cleaned = true;
        if (comptime builtin.target.cpu.arch.isWasm()) return;

        const wt_path = self.worktree_path orelse return;
        const toplevel = self.toplevel orelse return;

        const status = runGitCapture(self.alloc, wt_path, &.{
            "status",
            "--porcelain",
        }) catch return;
        if (status) |output| {
            const is_clean = output.len == 0;
            self.alloc.free(output);
            if (!is_clean) return;
        } else {
            // If status check failed, preserve the worktree rather than risking data loss.
            return;
        }

        _ = runGitSuccess(self.alloc, toplevel, &.{
            "worktree",
            "remove",
            "--force",
            wt_path,
        }) catch {};
    }

    pub fn deinit(self: *Lease) void {
        self.cleanup();
        if (self.owned_workspace_root) |path| self.alloc.free(path);
        if (self.worktree_path) |path| self.alloc.free(path);
        if (self.toplevel) |path| self.alloc.free(path);
        self.* = undefined;
    }
};

fn relativeSubdir(toplevel: []const u8, parent: []const u8) []const u8 {
    if (std.mem.eql(u8, toplevel, parent)) return "";
    if (parent.len <= toplevel.len) return "";
    if (!std.mem.startsWith(u8, parent, toplevel)) return "";
    if (std.mem.eql(u8, toplevel, "/")) {
        return parent[1..];
    }
    if (parent[toplevel.len] != std.Io.Dir.path.sep) return "";
    return parent[toplevel.len + 1 ..];
}

fn sanitizeChildId(alloc: Allocator, child_id: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (child_id) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
        const mapped: u8 = if (safe) ch else '_';
        if (out.items.len == 0 and mapped == '.') {
            try out.append(alloc, '_');
        } else {
            try out.append(alloc, mapped);
        }
    }
    if (out.items.len == 0) {
        try out.appendSlice(alloc, "child");
    }
    return out.toOwnedSlice(alloc);
}

fn allocateUniqueWorktreePath(
    alloc: Allocator,
    worktrees_dir: []const u8,
    sanitized_id: []const u8,
) Allocator.Error![]u8 {
    const first = try std.Io.Dir.path.join(alloc, &.{ worktrees_dir, sanitized_id });
    if (!pathExists(first)) return first;
    alloc.free(first);

    while (true) {
        const seq = next_worktree_seq.fetchAdd(1, .monotonic) + 1;
        const name = try alloc.print("{s}-{d}", .{ sanitized_id, seq });
        defer alloc.free(name);
        const candidate = try std.Io.Dir.path.join(alloc, &.{ worktrees_dir, name });
        if (!pathExists(candidate)) return candidate;
        alloc.free(candidate);
    }
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn runGitCapture(
    alloc: Allocator,
    cwd: []const u8,
    args: []const []const u8,
) Allocator.Error!?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.ensureTotalCapacity(alloc, 3 + args.len);
    argv.appendAssumeCapacity("git");
    argv.appendAssumeCapacity("-C");
    argv.appendAssumeCapacity(cwd);
    argv.appendSliceAssumeCapacity(args);

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);

    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        alloc.free(result.stdout);
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == result.stdout.len) return result.stdout;
    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(result.stdout);
    return owned;
}

fn runGitSuccess(
    alloc: Allocator,
    cwd: []const u8,
    args: []const []const u8,
) Allocator.Error!bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.ensureTotalCapacity(alloc, 3 + args.len);
    argv.appendAssumeCapacity("git");
    argv.appendAssumeCapacity("-C");
    argv.appendAssumeCapacity(cwd);
    argv.appendSliceAssumeCapacity(args);

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn testRunGit(alloc: Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    return (try runGitCapture(alloc, cwd, args)) orelse return error.GitCommandFailed;
}

fn testExecGit(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try testRunGit(alloc, cwd, args);
    alloc.free(out);
}

fn testInitRepo(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    try dir.createDirPath(std.testing.io, sub_path);
    const repo_path = try io_mod.dirRealpathAlloc(alloc, dir, sub_path);
    errdefer alloc.free(repo_path);

    try testExecGit(alloc, repo_path, &.{"init"});
    try testExecGit(alloc, repo_path, &.{ "config", "user.email", "test@example.com" });
    try testExecGit(alloc, repo_path, &.{ "config", "user.name", "Test User" });

    var repo_dir = try std.Io.Dir.cwd().openDir(std.testing.io, repo_path, .{});
    defer repo_dir.close(std.testing.io);
    try repo_dir.writeFile(std.testing.io, .{ .sub_path = "shared.txt", .data = "base\n" });

    try testExecGit(alloc, repo_path, &.{ "add", "shared.txt" });
    try testExecGit(alloc, repo_path, &.{ "commit", "-m", "initial" });
    return repo_path;
}

test "worktree_isolation creates distinct HEAD worktrees without collision and cleans up clean ones" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo_path = try testInitRepo(alloc, tmp.dir, "repo");
    defer alloc.free(repo_path);

    const parent_head = try testRunGit(alloc, repo_path, &.{ "rev-parse", "HEAD" });
    defer alloc.free(parent_head);

    var lease_a = try Lease.acquire(alloc, repo_path, "child-a");
    defer lease_a.deinit();
    var lease_b = try Lease.acquire(alloc, repo_path, "child-b");
    defer lease_b.deinit();

    try std.testing.expect(lease_a.isolated);
    try std.testing.expect(lease_b.isolated);
    try std.testing.expect(!std.mem.eql(u8, lease_a.workspace_root, repo_path));
    try std.testing.expect(!std.mem.eql(u8, lease_b.workspace_root, repo_path));
    try std.testing.expect(!std.mem.eql(u8, lease_a.workspace_root, lease_b.workspace_root));

    const head_a = try testRunGit(alloc, lease_a.workspace_root, &.{ "rev-parse", "HEAD" });
    defer alloc.free(head_a);
    const head_b = try testRunGit(alloc, lease_b.workspace_root, &.{ "rev-parse", "HEAD" });
    defer alloc.free(head_b);
    try std.testing.expectEqualStrings(parent_head, head_a);
    try std.testing.expectEqualStrings(parent_head, head_b);

    // Modify the same filename in both worktrees concurrently without colliding or dirtying parent.
    var dir_a = try std.Io.Dir.cwd().openDir(std.testing.io, lease_a.workspace_root, .{});
    defer dir_a.close(std.testing.io);
    try dir_a.writeFile(std.testing.io, .{ .sub_path = "shared.txt", .data = "from-a\n" });

    var dir_b = try std.Io.Dir.cwd().openDir(std.testing.io, lease_b.workspace_root, .{});
    defer dir_b.close(std.testing.io);
    try dir_b.writeFile(std.testing.io, .{ .sub_path = "shared.txt", .data = "from-b\n" });

    var parent_dir = try std.Io.Dir.cwd().openDir(std.testing.io, repo_path, .{});
    defer parent_dir.close(std.testing.io);
    const parent_contents = try parent_dir.readFileAlloc(std.testing.io, "shared.txt", alloc, .limited(1024));
    defer alloc.free(parent_contents);
    try std.testing.expectEqualStrings("base\n", parent_contents);

    const a_contents = try dir_a.readFileAlloc(std.testing.io, "shared.txt", alloc, .limited(1024));
    defer alloc.free(a_contents);
    try std.testing.expectEqualStrings("from-a\n", a_contents);

    const b_contents = try dir_b.readFileAlloc(std.testing.io, "shared.txt", alloc, .limited(1024));
    defer alloc.free(b_contents);
    try std.testing.expectEqualStrings("from-b\n", b_contents);

    const parent_status = try testRunGit(alloc, repo_path, &.{ "status", "--porcelain" });
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("", parent_status);

    // Dirty worktree A must be preserved on cleanup; clean worktree C must be removed.
    const wt_a_path = try alloc.dupe(u8, lease_a.worktree_path.?);
    defer alloc.free(wt_a_path);
    lease_a.cleanup();
    try std.Io.Dir.cwd().access(std.testing.io, wt_a_path, .{});

    var lease_c = try Lease.acquire(alloc, repo_path, "child-c");
    defer lease_c.deinit();
    try std.testing.expect(lease_c.isolated);
    const wt_c_path = try alloc.dupe(u8, lease_c.worktree_path.?);
    defer alloc.free(wt_c_path);
    try std.Io.Dir.cwd().access(std.testing.io, wt_c_path, .{});
    lease_c.cleanup();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, wt_c_path, .{}));
}

test "worktree_isolation preserves subdirectory offset and falls back on non-git directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo_path = try testInitRepo(alloc, tmp.dir, "repo");
    defer alloc.free(repo_path);

    const subdir = try std.Io.Dir.path.join(alloc, &.{ repo_path, "packages", "sub" });
    defer alloc.free(subdir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, subdir);

    var sub_lease = try Lease.acquire(alloc, subdir, "child/with:unsafe*chars");
    defer sub_lease.deinit();
    try std.testing.expect(sub_lease.isolated);
    try std.testing.expect(std.mem.endsWith(u8, sub_lease.workspace_root, "/packages/sub"));
    try std.Io.Dir.cwd().access(std.testing.io, sub_lease.workspace_root, .{});

    // Non-git directory fallback (must be outside the repository's .zig-cache tree).
    const non_git_path = "/tmp/opencode/wt-non-git-test";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, non_git_path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, non_git_path) catch {};

    var plain_lease = try Lease.acquire(alloc, non_git_path, "child-plain");
    defer plain_lease.deinit();
    try std.testing.expect(!plain_lease.isolated);
    try std.testing.expectEqualStrings(non_git_path, plain_lease.workspace_root);
}
