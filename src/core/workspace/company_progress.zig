//! Resumable revision notifications over a caller's own view. Signed positions
//! follow immutable first parents and never depend on SQLite row identities.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const keys = @import("company_keys.zig");
const io = @import("../shared/io.zig");
const manifest = @import("fossil_manifest.zig");

const Cursor = struct {
    version: []const u8 = "omos.company-progress-cursor/v1",
    workspace: []const u8,
    actor: []const u8,
    grant: []const u8,
    view: []const u8,
    epoch: u64,
    after: []const u8,
    head: ?[]const u8 = null,
    next: ?[]const u8 = null,
};
const Event = struct { kind: []const u8 = "view_revision", revision: []const u8, parent: ?[]const u8, committed_at: []const u8 };

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

fn seal(manager: workspace.Manager, current: authority.State, cursor: Cursor) ![]const u8 {
    const payload = try encode(manager.alloc, cursor);
    const key = try keys.current(manager, current.epoch, current.issuer);
    const signature = try key.sign(payload, null);
    return encode(manager.alloc, .{ .payload = payload, .signature = &std.fmt.bytesToHex(signature.toBytes(), .lower) });
}

fn open(manager: workspace.Manager, current: authority.State, grant: authority.Grant, view: []const u8, raw: []const u8) !Cursor {
    if (raw.len > 4096) return error.InvalidCompanyProgressCursor;
    const envelope = records.decode(authority.Envelope, manager.alloc, raw, .{}) catch return error.InvalidCompanyProgressCursor;
    const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try authority.hexBytes(32, current.issuer));
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(authority.hexBytes(64, envelope.signature) catch return error.InvalidCompanyProgressCursor);
    signature.verifyStrict(envelope.payload, public) catch return error.InvalidCompanyProgressCursor;
    const cursor = records.decode(Cursor, manager.alloc, envelope.payload, .{}) catch return error.InvalidCompanyProgressCursor;
    if (!std.mem.eql(u8, cursor.version, "omos.company-progress-cursor/v1") or !std.mem.eql(u8, cursor.workspace, current.workspace) or !std.mem.eql(u8, cursor.actor, grant.actor) or !std.mem.eql(u8, cursor.grant, grant.id) or !std.mem.eql(u8, cursor.view, view) or cursor.epoch != current.epoch or !manifest.validHash(cursor.after) or (cursor.head == null) != (cursor.next == null)) return error.InvalidCompanyProgressCursor;
    if (cursor.head) |head| if (!manifest.validHash(head) or !manifest.validHash(cursor.next.?)) return error.InvalidCompanyProgressCursor;
    return cursor;
}

pub fn page(original: workspace.Manager, current: authority.State, grant: authority.Grant, task: workspace.Task, view: []const u8, base: []const u8, head: []const u8, raw: []const u8, limit: usize) !std.json.Value {
    if (limit == 0) return error.InvalidEvidenceOffset;
    var manager = original;
    var cancelled = std.atomic.Value(bool).init(false);
    if (manager.operation_control == null) manager.operation_control = .{
        .cancel = &cancelled,
        .deadline = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(30)) },
    };
    var cursor = if (raw.len == 0) Cursor{ .workspace = current.workspace, .actor = grant.actor, .grant = grant.id, .view = view, .epoch = current.epoch, .after = (try manager.companyReadRevision(task, base)) orelse return error.CompanyAccessDenied } else try open(manager, current, grant, view, raw);
    if (cursor.head == null) {
        // Signed resume positions select the current view head once. Later
        // pages retain that head even if another checkpoint arrives.
        cursor.head = head;
        cursor.next = head;
    }
    if ((try manager.companyReadRevision(task, cursor.head.?)) == null) return error.CompanyAccessDenied;
    var events: std.ArrayList(Event) = .empty;
    while (!std.mem.eql(u8, cursor.next.?, cursor.after) and events.items.len < @min(limit, 32)) {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const revision = cursor.next.?;
        const metadata = try reader.checkinMetadata(revision);
        // Reaching the root before the signed stop position is corruption,
        // never permission to continue through unrelated company history.
        const parent = metadata.parent orelse return error.InvalidCompanyProgressCursor;
        try events.append(manager.alloc, .{ .revision = revision, .parent = try manager.alloc.dupe(u8, parent), .committed_at = try manager.alloc.dupe(u8, metadata.timestamp) });
        cursor.next = events.items[events.items.len - 1].parent;
    }
    const complete = std.mem.eql(u8, cursor.next.?, cursor.after);
    var next_subscription = cursor;
    next_subscription.after = cursor.head.?;
    next_subscription.head = null;
    next_subscription.next = null;
    return std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try encode(manager.alloc, .{
        .version = "omos.company-progress/v1",
        .view = view,
        .revision = cursor.head.?,
        .order = "newest_first",
        .events = events.items,
        .next_cursor = if (complete) @as(?[]const u8, null) else try seal(manager, current, cursor),
        .resume_cursor = try seal(manager, current, next_subscription),
    }), .{});
}
