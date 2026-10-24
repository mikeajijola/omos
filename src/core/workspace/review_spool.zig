//! Rebuildable review payloads. Canonical records remain in Fossil; this cache
//! lets the assessor retain their identities without retaining all their bytes.
const std = @import("std");
const io = @import("../shared/io.zig");
const evidence = @import("../agent/runtime/review_evidence.zig");

pub const Detached = struct { record: evidence.Evidence, payload: ?evidence.PayloadRef };

pub fn detach(alloc: std.mem.Allocator, root: []const u8, original: evidence.Evidence) !Detached {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const payload = try std.json.Stringify.valueAlloc(a, .{ .arguments = original.arguments, .content = original.content }, .{});
    if (payload.len > 64 * 1024 * 1024) return error.WorkspaceRecordTooLarge;
    var reference: ?evidence.PayloadRef = null;
    var record = original;
    if (payload.len > 2048) {
        const directory = try std.Io.Dir.path.join(a, &.{ root, "review-payloads" });
        _ = try std.Io.Dir.cwd().createDirPathStatus(io.getIo(), directory, .fromMode(0o700));
        var dir = try io.openDirAbsoluteNoFollow(directory, .{ .iterate = true });
        defer dir.close(io.getIo());
        try dir.setPermissions(io.getIo(), .fromMode(0o700));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        const hash = std.fmt.bytesToHex(&digest, .lower);
        const matches = blk: {
            var file = dir.openFile(io.getIo(), &hash, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            defer file.close(io.getIo());
            const stat = try file.stat(io.getIo());
            if (stat.kind != .file or stat.size != payload.len) break :blk false;
            const bytes = try io.readFileToEnd(a, &file, 64 * 1024 * 1024);
            break :blk std.mem.eql(u8, bytes, payload);
        };
        if (!matches) {
            var nonce: [16]u8 = undefined;
            io.getIo().random(&nonce);
            const pending = try a.print("payload-{s}.pending", .{std.fmt.bytesToHex(&nonce, .lower)});
            var file = try dir.createFile(io.getIo(), pending, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            defer file.close(io.getIo());
            defer dir.deleteFile(io.getIo(), pending) catch {};
            try file.writeStreamingAll(io.getIo(), payload);
            try file.sync(io.getIo());
            try dir.rename(pending, dir, &hash, io.getIo());
        }
        reference = .{ .id = try alloc.dupe(u8, record.id), .path = try std.Io.Dir.path.join(alloc, &.{ directory, &hash }), .bytes = payload.len, .sha256 = try alloc.dupe(u8, &hash), .identity_sha256 = try alloc.dupe(u8, &try evidence.progressIdentity(a, payload, record.tool)) };
        record.content = evidence.View.prefix(record.content, 256);
        record.arguments = if (record.arguments) |arguments| evidence.View.prefix(arguments, 512) else null;
    }
    // Every metadata slice must outlive the one-record scratch arena upstream.
    const detached = try std.json.Stringify.valueAlloc(a, record, .{});
    return .{ .record = try std.json.parseFromSliceLeaky(evidence.Evidence, alloc, detached, .{ .allocate = .alloc_always }), .payload = reference };
}

test "completion review spool keeps a multi-megabyte payload outside the bounded manifest allocator" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io.getIo(), ".", alloc);
    const large = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    @memset(large, 'x');
    @memcpy(large[large.len - 6 ..], "needle");
    const detached = try detach(alloc, root, .{ .id = "large", .tool = "fixture", .status = .success, .content = large });
    std.testing.allocator.free(large);
    try std.testing.expect(detached.payload != null);
    try std.testing.expect(detached.record.content.len <= 256);
    var manifest_buffer: [16 * 1024]u8 = undefined;
    var manifest_allocator = std.heap.FixedBufferAllocator.init(&manifest_buffer);
    var view = try evidence.View.initWithBacking(manifest_allocator.allocator(), &.{detached.record}, &.{detached.payload.?});
    try std.testing.expectEqual(@as(usize, 0), view.payloads[0].len);
    const rows = try view.index(manifest_allocator.allocator(), 0, 1);
    try std.testing.expect(rows[0].bytes > 4 * 1024 * 1024);
    try std.testing.expect(!rows[0].complete);
    const found = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try view.retrieve(alloc, "{\"action\":\"search\",\"query\":\"needle\"}"), .{});
    try std.testing.expectEqual(@as(i64, 1), found.object.get("total").?.integer);
    try std.testing.expectError(error.UninspectedContractEvidence, view.requireInspected("large"));
    const page = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try view.page(alloc, "{\"action\":\"read\",\"id\":\"large\",\"limit\":1024}"), .{});
    try std.testing.expectEqual(@as(usize, 1024), page.object.get("content").?.string.len);
    try std.testing.expect(!page.object.get("fullyInspected").?.bool);
    try std.testing.expect(manifest_allocator.end_index < manifest_buffer.len);
    try std.testing.expectError(error.InvalidContractEvidence, evidence.View.initWithBacking(alloc, &.{detached.record}, &.{ detached.payload.?, detached.payload.? }));
    var absent = detached.payload.?;
    absent.id = "absent";
    try std.testing.expectError(error.InvalidContractEvidence, evidence.View.initWithBacking(alloc, &.{detached.record}, &.{absent}));
    var file = try std.Io.Dir.cwd().createFile(io.getIo(), detached.payload.?.path, .{ .truncate = true });
    defer file.close(io.getIo());
    try file.writeStreamingAll(io.getIo(), "corrupt");
    try std.testing.expectError(error.InvalidContractEvidence, view.page(alloc, "{\"action\":\"read\",\"id\":\"large\",\"limit\":1024}"));
}
