//! Immutable file identities from Fossil's public check-in artifact format.
//! https://fossil-scm.org/home/doc/trunk/www/fileformat.wiki#manifest
const std = @import("std");

pub const File = struct {
    path: []const u8,
    artifact: ?[]const u8,
    mode: enum { regular, executable, symlink } = .regular,
};
pub const Manifest = struct { baseline: ?[]const u8 = null, files: []const File };
pub const SizedFile = struct { path: []const u8, bytes: usize };
pub const Change = struct { path: []const u8, before: ?File, after: ?File };

/// Compare resolved inventories, including modes that Fossil's brief textual
/// diff omits when the content object remains unchanged.
pub fn compare(alloc: std.mem.Allocator, before: []const File, after: []const File) ![]const Change {
    var previous = std.StringHashMap(File).init(alloc);
    defer previous.deinit();
    var changes: std.ArrayList(Change) = .empty;
    for (before) |file| {
        if (file.artifact == null or (try previous.getOrPut(file.path)).found_existing) return error.InvalidFossilManifest;
        try previous.put(file.path, file);
    }
    for (after) |file| {
        if (file.artifact == null) return error.InvalidFossilManifest;
        if (previous.fetchRemove(file.path)) |old| {
            if (old.value.mode == file.mode and std.mem.eql(u8, old.value.artifact.?, file.artifact.?)) continue;
            try changes.append(alloc, .{ .path = file.path, .before = old.value, .after = file });
        } else try changes.append(alloc, .{ .path = file.path, .before = null, .after = file });
    }
    var deleted = previous.valueIterator();
    while (deleted.next()) |file| try changes.append(alloc, .{ .path = file.path, .before = file.*, .after = null });
    std.mem.sort(Change, changes.items, {}, struct {
        fn less(_: void, a: Change, b: Change) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    return changes.toOwnedSlice(alloc);
}

/// `branch list --all` has three fixed status columns. Strip the status,
/// never marker-like characters that are part of an actual branch name.
pub fn branchName(line: []const u8) ![]const u8 {
    if (line.len == 0) return line;
    if (line.len < 4 or (line[0] != ' ' and line[0] != '#') or (line[1] != ' ' and line[1] != '*') or line[2] != ' ') return error.InvalidFossilBranchList;
    return line[3..];
}

/// Fossil's test-integrity reports checksum failures in stdout but does not
/// necessarily return a failing exit status. Require its complete success
/// summary and database check before trusting verified object identities.
pub fn verifyIntegrityReport(raw: []const u8) !void {
    var summary = false;
    var database = false;
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "wrong hash on artifact ") or std.mem.startsWith(u8, line, "size mismatch on artifact ") or std.mem.find(u8, line, " is a delta from private artifact ") != null) return error.WorkspaceVerificationFailed;
        if (std.mem.find(u8, line, " non-phantom blobs (out of ") != null) {
            if (summary) return error.InvalidFossilIntegrityReport;
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            const checked = std.fmt.parseInt(usize, words.next() orelse return error.InvalidFossilIntegrityReport, 10) catch return error.InvalidFossilIntegrityReport;
            for ([_][]const u8{ "non-phantom", "blobs", "(out", "of" }) |expected| if (!std.mem.eql(u8, words.next() orelse return error.InvalidFossilIntegrityReport, expected)) return error.InvalidFossilIntegrityReport;
            const total = std.fmt.parseInt(usize, words.next() orelse return error.InvalidFossilIntegrityReport, 10) catch return error.InvalidFossilIntegrityReport;
            for ([_][]const u8{ "total)", "checked:" }) |expected| if (!std.mem.eql(u8, words.next() orelse return error.InvalidFossilIntegrityReport, expected)) return error.InvalidFossilIntegrityReport;
            const errors = std.fmt.parseInt(usize, words.next() orelse return error.InvalidFossilIntegrityReport, 10) catch return error.InvalidFossilIntegrityReport;
            if (!std.mem.eql(u8, words.next() orelse return error.InvalidFossilIntegrityReport, "errors") or words.next() != null) return error.InvalidFossilIntegrityReport;
            if (errors != 0) return error.WorkspaceVerificationFailed;
            if (checked != total) return error.WorkspaceMissingContent;
            summary = true;
        } else if (std.mem.startsWith(u8, line, "low-level database integrity-check: ")) {
            if (database) return error.InvalidFossilIntegrityReport;
            if (!std.mem.eql(u8, line, "low-level database integrity-check: ok")) return error.WorkspaceVerificationFailed;
            database = true;
        }
    }
    if (!summary or !database) return error.InvalidFossilIntegrityReport;
}

/// Metadata from the public `ls -v -r` command supplies boundaries for bounded
/// multi-file reads. Preserve filenames, including spaces at their end.
pub fn sizes(alloc: std.mem.Allocator, raw: []const u8) ![]const SizedFile {
    var result: std.ArrayList(SizedFile) = .empty;
    var seen = std.StringHashMap(void).init(alloc);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const date = words.next() orelse return error.InvalidFossilInventory;
        const time = words.next() orelse return error.InvalidFossilInventory;
        const number = words.next() orelse return error.InvalidFossilInventory;
        if (date.len != 10 or date[4] != '-' or date[7] != '-' or time.len != 8 or time[2] != ':' or time[5] != ':') return error.InvalidFossilInventory;
        for (number) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidFossilInventory;
        const bytes = std.fmt.parseInt(usize, number, 10) catch return error.InvalidFossilInventory;
        var start = words.index;
        while (start < line.len and line[start] == ' ') : (start += 1) {}
        const name = line[start..];
        if (name.len == 0 or (try seen.getOrPut(name)).found_existing) return error.InvalidFossilInventory;
        try result.append(alloc, .{ .path = name, .bytes = bytes });
    }
    return result.toOwnedSlice(alloc);
}

pub fn validHash(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}

pub fn verifyObject(identity: []const u8, bytes: []const u8) !void {
    if (!validHash(identity)) return error.InvalidFossilManifest;
    if (identity.len == 40) {
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, identity, &std.fmt.bytesToHex(&digest, .lower))) return error.WorkspaceVerificationFailed;
    } else {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha3.Sha3_256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, identity, &std.fmt.bytesToHex(&digest, .lower))) return error.WorkspaceVerificationFailed;
    }
}

/// Legacy task records can contain Fossil's 40-character SHA-3 display prefix.
/// Only check-in references allow this form; file-object identities stay exact.
pub fn verifyCheckinReference(identity: []const u8, bytes: []const u8) !void {
    if (identity.len == 40 and validHash(identity)) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha3.Sha3_256.hash(bytes, &digest, .{});
        const full = std.fmt.bytesToHex(&digest, .lower);
        if (std.mem.eql(u8, identity, full[0..40])) return;
    }
    try verifyObject(identity, bytes);
}

fn path(alloc: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        if (encoded[index] == '\\') {
            index += 1;
            if (index >= encoded.len or encoded[index] != 's') return error.InvalidFossilManifest;
            try result.append(alloc, ' ');
        } else try result.append(alloc, encoded[index]);
    }
    if (!std.unicode.utf8ValidateSlice(result.items)) return error.InvalidFossilManifest;
    var parts = std.mem.splitScalar(u8, result.items, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidFossilManifest;
        for (part) |ch| if (ch < 32 or ch == 127 or ch == '\\') return error.InvalidFossilManifest;
    }
    return result.toOwnedSlice(alloc);
}

fn cards(raw: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, raw, "-----BEGIN PGP SIGNED MESSAGE-----\n")) return raw;
    const header_end = std.mem.find(u8, raw, "\n\n") orelse return error.InvalidFossilManifest;
    const payload = raw[header_end + 2 ..];
    const signature_end = std.mem.find(u8, payload, "-----BEGIN PGP SIGNATURE-----") orelse return error.InvalidFossilManifest;
    return payload[0..signature_end];
}

pub fn parse(alloc: std.mem.Allocator, raw: []const u8) !Manifest {
    var files: std.ArrayList(File) = .empty;
    var names = std.StringHashMap(void).init(alloc);
    var baseline: ?[]const u8 = null;
    var comment = false;
    var date = false;
    var checksum = false;
    var lines = std.mem.splitScalar(u8, try cards(raw), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 2 or line[1] != ' ') return error.InvalidFossilManifest;
        switch (line[0]) {
            'C' => comment = true,
            'D' => date = true,
            'Z' => checksum = true,
            'B' => {
                if (baseline != null or !validHash(line[2..])) return error.InvalidFossilManifest;
                baseline = line[2..];
            },
            'F' => {
                // A single trailing space after a UUID exists in old Fossil
                // check-ins. Tokenization accepts that historical form.
                var words = std.mem.tokenizeScalar(u8, line[2..], ' ');
                const name = try path(alloc, words.next() orelse return error.InvalidFossilManifest);
                if ((try names.getOrPut(name)).found_existing) return error.InvalidFossilManifest;
                const artifact = words.next();
                if (artifact) |identity| if (!validHash(identity)) return error.InvalidFossilManifest;
                const permission = words.next() orelse "";
                const mode: @FieldType(File, "mode") = if (permission.len == 0 or std.mem.eql(u8, permission, "w")) .regular else if (std.mem.eql(u8, permission, "x")) .executable else if (std.mem.eql(u8, permission, "l")) .symlink else return error.UnsupportedFossilFileMode;
                if (words.next()) |previous| _ = try path(alloc, previous);
                if (words.next() != null) return error.InvalidFossilManifest;
                try files.append(alloc, .{ .path = name, .artifact = artifact, .mode = mode });
            },
            else => {},
        }
    }
    if (!comment or !date or !checksum) return error.InvalidFossilManifest;
    if (baseline == null) for (files.items) |file| if (file.artifact == null) return error.InvalidFossilManifest;
    return .{ .baseline = baseline, .files = try files.toOwnedSlice(alloc) };
}

pub fn resolve(alloc: std.mem.Allocator, baseline: ?Manifest, changes: Manifest) ![]const File {
    if ((baseline == null) != (changes.baseline == null)) return error.InvalidFossilBaseline;
    var files = std.StringHashMap(File).init(alloc);
    if (baseline) |base| {
        if (base.baseline != null) return error.InvalidFossilBaseline;
        for (base.files) |file| {
            if (file.artifact == null) return error.InvalidFossilManifest;
            try files.put(file.path, file);
        }
    }
    for (changes.files) |file| {
        if (file.artifact != null) try files.put(file.path, file) else if (!files.remove(file.path)) return error.InvalidFossilManifest;
    }
    const result = try alloc.alloc(File, files.count());
    var values = files.valueIterator();
    var index: usize = 0;
    while (values.next()) |file| : (index += 1) result[index] = file.*;
    std.mem.sort(File, result, {}, struct {
        fn less(_: void, left: File, right: File) bool {
            const order = std.ascii.orderIgnoreCase(left.path, right.path);
            return if (order == .eq) std.mem.lessThan(u8, left.path, right.path) else order == .lt;
        }
    }.less);
    return result;
}

const h = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const envelope = "C test\nD 2026-01-01T00:00:00\n";
const end = "Z 0123456789abcdef0123456789abcdef\n";

test "Fossil manifest comparison includes content mode additions and deletions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = [_]File{
        .{ .path = "memory/unchanged", .artifact = h },
        .{ .path = "skills/run.sh", .artifact = h },
        .{ .path = "documents/changed", .artifact = h },
        .{ .path = "memory/deleted", .artifact = h },
    };
    const after = [_]File{
        .{ .path = "memory/unchanged", .artifact = h },
        .{ .path = "skills/run.sh", .artifact = h, .mode = .executable },
        .{ .path = "documents/changed", .artifact = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .{ .path = "memory/added", .artifact = h },
    };
    const changes = try compare(arena.allocator(), &before, &after);
    try std.testing.expectEqual(@as(usize, 4), changes.len);
    try std.testing.expectEqualStrings("documents/changed", changes[0].path);
    try std.testing.expectEqualStrings("memory/added", changes[1].path);
    try std.testing.expect(changes[1].before == null);
    try std.testing.expectEqualStrings("memory/deleted", changes[2].path);
    try std.testing.expect(changes[2].after == null);
    try std.testing.expectEqualStrings("skills/run.sh", changes[3].path);
    try std.testing.expectEqual(.regular, changes[3].before.?.mode);
    try std.testing.expectEqual(.executable, changes[3].after.?.mode);
    try std.testing.expectEqualStrings(changes[3].before.?.artifact.?, changes[3].after.?.artifact.?);
}

test "Fossil manifest resolves escaped names and executable and symlink metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), envelope ++ "F skills/my\\sskill/run.sh " ++ h ++ " x\nF ui/link " ++ h ++ " l\n" ++ end);
    const entries = try resolve(arena.allocator(), null, parsed);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("skills/my skill/run.sh", entries[0].path);
    try std.testing.expectEqual(.executable, entries[0].mode);
    try std.testing.expectEqual(.symlink, entries[1].mode);
}

test "Fossil manifest overlays delta additions updates and deletions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try parse(alloc, envelope ++ "F memory/a " ++ h ++ "\nF memory/b " ++ h ++ "\n" ++ end);
    const delta = try parse(alloc, "B " ++ h ++ "\n" ++ envelope ++ "F memory/a\nF memory/b " ++ "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++ "\nF memory/c " ++ h ++ "\n" ++ end);
    const entries = try resolve(alloc, base, delta);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("memory/b", entries[0].path);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", entries[0].artifact.?);
    try std.testing.expectEqualStrings("memory/c", entries[1].path);
    try std.testing.expectError(error.InvalidFossilBaseline, resolve(alloc, null, delta));
    try std.testing.expectError(error.InvalidFossilBaseline, resolve(alloc, delta, delta));
}

test "Fossil manifest refuses ambiguous malformed and escaping entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "F memory/../private " ++ h, "F memory/\\nprivate " ++ h, "F memory/a not-a-hash", "F memory/a", "F memory/a " ++ h ++ "\nF memory/a " ++ h }) |invalid| {
        try std.testing.expectError(error.InvalidFossilManifest, parse(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{s}{s}\n{s}", .{ envelope, invalid, end })));
    }
    try std.testing.expectError(error.UnsupportedFossilFileMode, parse(arena.allocator(), envelope ++ "F memory/a " ++ h ++ " unknown\n" ++ end));
}

test "Fossil manifest reads clearsigned cards and old trailing whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n" ++ envelope ++ "F memory/a " ++ h ++ " \n" ++ end ++ "-----BEGIN PGP SIGNATURE-----\nfixture\n");
    try std.testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "Fossil object identity verifies both supported algorithms" {
    const content = "exact artifact bytes";
    var sha1: [20]u8 = undefined;
    var sha3: [32]u8 = undefined;
    std.crypto.hash.Sha1.hash(content, &sha1, .{});
    std.crypto.hash.sha3.Sha3_256.hash(content, &sha3, .{});
    try verifyObject(&std.fmt.bytesToHex(&sha1, .lower), content);
    try verifyObject(&std.fmt.bytesToHex(&sha3, .lower), content);
    try std.testing.expectError(error.WorkspaceVerificationFailed, verifyObject(&std.fmt.bytesToHex(&sha3, .lower), "changed"));
    try std.testing.expectError(error.InvalidFossilManifest, verifyObject("abcd", content));
}

test "Fossil inventory sizes preserve exact names and reject ambiguous boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = try sizes(alloc, "2026-01-01 12:34:56        0  memory/empty\n2026-01-01 12:34:56       42  documents/with space \n");
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 0), entries[0].bytes);
    try std.testing.expectEqual(@as(usize, 42), entries[1].bytes);
    try std.testing.expectEqualStrings("documents/with space ", entries[1].path);
    for ([_][]const u8{ "invalid", "2026-01-01 12:34:56 -1 memory/a", "2026-01-01 12:34:56 42", "2026-01-01 12:34:56 1 memory/a\n2026-01-01 12:34:56 2 memory/a\n" }) |invalid| {
        try std.testing.expectError(error.InvalidFossilInventory, sizes(alloc, invalid));
    }
}

test "Fossil integrity requires complete successful checks rather than an exit code" {
    const success = "3 non-phantom blobs (out of 3 total) checked:  0 errors\nlow-level database integrity-check: ok\n";
    try verifyIntegrityReport("  1/3\r  2/3\r  3/3\r" ++ success);
    try std.testing.expectError(error.WorkspaceVerificationFailed, verifyIntegrityReport("wrong hash on artifact 1\n" ++ success));
    try std.testing.expectError(error.WorkspaceVerificationFailed, verifyIntegrityReport("3 non-phantom blobs (out of 3 total) checked:  1 errors\nlow-level database integrity-check: ok\n"));
    try std.testing.expectError(error.WorkspaceMissingContent, verifyIntegrityReport("2 non-phantom blobs (out of 3 total) checked:  0 errors\nlow-level database integrity-check: ok\n"));
    try std.testing.expectError(error.WorkspaceVerificationFailed, verifyIntegrityReport("3 non-phantom blobs (out of 3 total) checked:  0 errors\nlow-level database integrity-check: damaged\n"));
    try std.testing.expectError(error.InvalidFossilIntegrityReport, verifyIntegrityReport("0 errors\n"));
    try std.testing.expectError(error.InvalidFossilIntegrityReport, verifyIntegrityReport(success ++ success));
}

test "Fossil branch status preserves names and recognizes private and current markers" {
    try std.testing.expectEqualStrings("trunk", try branchName("   trunk"));
    try std.testing.expectEqualStrings("task/example", try branchName("#  task/example"));
    try std.testing.expectEqualStrings("task/example", try branchName("#* task/example"));
    try std.testing.expectEqualStrings("trunk", try branchName(" * trunk"));
    try std.testing.expectEqualStrings("#task/example", try branchName("#  #task/example"));
    try std.testing.expectError(error.InvalidFossilBranchList, branchName("#task/example"));
}

test "Fossil object legacy check-in prefixes preserve strict file identities" {
    const content = "D 2026-10-24T00:00:00\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(content, &digest, .{});
    const full = std.fmt.bytesToHex(&digest, .lower);
    try verifyCheckinReference(full[0..40], content);
    try verifyCheckinReference(&full, content);
    try std.testing.expectError(error.WorkspaceVerificationFailed, verifyCheckinReference(full[0..40], "changed"));
    try std.testing.expectError(error.WorkspaceVerificationFailed, verifyObject(full[0..40], content));
    try std.testing.expectError(error.InvalidFossilManifest, verifyCheckinReference(full[0..39], content));
}
