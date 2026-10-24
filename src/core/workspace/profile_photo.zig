//! Portable profile appearance. The local host owns account identity; workspace
//! UI source can request an explicit photo update but cannot select another user.
const std = @import("std");

pub const Photo = struct { content: []const u8, mime: []const u8, sha256: []const u8 };
pub fn decode(alloc: std.mem.Allocator, encoded: []const u8) !Photo {
    if (encoded.len > 700000) return error.ProfilePhotoTooLarge;
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidProfilePhoto;
    if (size == 0 or size > 512 * 1024) return error.ProfilePhotoTooLarge;
    const bytes = try alloc.alloc(u8, size);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    const canonical = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(size));
    if (!std.mem.eql(u8, std.base64.standard.Encoder.encode(canonical, bytes), encoded)) return error.InvalidProfilePhoto;
    const mime = if (bytes.len >= 24 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) "image/png" else if (bytes.len >= 4 and std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) "image/jpeg" else if (bytes.len >= 16 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) "image/webp" else return error.InvalidProfilePhoto;
    return .{ .content = bytes, .mime = mime, .sha256 = try @import("fossil_workspace.zig").hash(alloc, bytes) };
}

test "workspace profile photo validates bytes and rejects active content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(error.InvalidProfilePhoto, decode(alloc, "PHN2Zz48c2NyaXB0Pjwvc2NyaXB0Pjwvc3ZnPg=="));
    const data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB";
    const result = try decode(alloc, data);
    try std.testing.expectEqualStrings("image/png", result.mime);
    try std.testing.expectEqual(@as(usize, 24), result.content.len);
}
