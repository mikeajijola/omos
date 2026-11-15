//! Direct read-only SQLite reader for Fossil repositories.
//!
//! Reads `blob` and `delta` tables directly via libsqlite3 with
//! `SQLITE_OPEN_READONLY` and `sqlite3_busy_timeout`, bypassing `fossil`
//! subprocess spawning for read-only queries, revision lookups, and file
//! retrieval at a revision.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const fossil_manifest = @import("fossil_manifest.zig");

const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};

    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_PERM: c_int = 3;
    pub const SQLITE_BUSY: c_int = 5;
    pub const SQLITE_READONLY: c_int = 8;
    pub const SQLITE_CORRUPT: c_int = 11;
    pub const SQLITE_CANTOPEN: c_int = 14;
    pub const SQLITE_NOTADB: c_int = 26;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;

    pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
    pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;

    pub const SQLITE_INTEGER: c_int = 1;
    pub const SQLITE_FLOAT: c_int = 2;
    pub const SQLITE_TEXT: c_int = 3;
    pub const SQLITE_BLOB: c_int = 4;
    pub const SQLITE_NULL: c_int = 5;

    pub const SQLITE_STATIC: ?*const fn (?*anyopaque) callconv(.c) void = null;

    pub extern "c" fn sqlite3_open_v2(
        filename: [*:0]const u8,
        ppDb: *?*sqlite3,
        flags: c_int,
        zVfs: ?[*:0]const u8,
    ) c_int;
    pub extern "c" fn sqlite3_close(db: *sqlite3) c_int;
    pub extern "c" fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
    pub extern "c" fn sqlite3_prepare_v2(
        db: *sqlite3,
        zSql: [*]const u8,
        nByte: c_int,
        ppStmt: *?*sqlite3_stmt,
        pzTail: ?*?[*:0]const u8,
    ) c_int;
    pub extern "c" fn sqlite3_finalize(pStmt: *sqlite3_stmt) c_int;
    pub extern "c" fn sqlite3_stmt_readonly(pStmt: *sqlite3_stmt) c_int;
    pub extern "c" fn sqlite3_bind_text(
        pStmt: *sqlite3_stmt,
        idx: c_int,
        val: [*]const u8,
        n: c_int,
        destructor: ?*const fn (?*anyopaque) callconv(.c) void,
    ) c_int;
    pub extern "c" fn sqlite3_bind_int64(pStmt: *sqlite3_stmt, idx: c_int, val: i64) c_int;
    pub extern "c" fn sqlite3_step(pStmt: *sqlite3_stmt) c_int;
    pub extern "c" fn sqlite3_column_count(pStmt: *sqlite3_stmt) c_int;
    pub extern "c" fn sqlite3_column_name(pStmt: *sqlite3_stmt, N: c_int) ?[*:0]const u8;
    pub extern "c" fn sqlite3_column_type(pStmt: *sqlite3_stmt, iCol: c_int) c_int;
    pub extern "c" fn sqlite3_column_int64(pStmt: *sqlite3_stmt, iCol: c_int) i64;
    pub extern "c" fn sqlite3_column_double(pStmt: *sqlite3_stmt, iCol: c_int) f64;
    pub extern "c" fn sqlite3_column_bytes(pStmt: *sqlite3_stmt, iCol: c_int) c_int;
    pub extern "c" fn sqlite3_column_text(pStmt: *sqlite3_stmt, iCol: c_int) ?[*]const u8;
    pub extern "c" fn sqlite3_column_blob(pStmt: *sqlite3_stmt, iCol: c_int) ?*const anyopaque;
    pub extern "c" fn sqlite3_exec(
        db: *sqlite3,
        sql: [*:0]const u8,
        callback: ?*const anyopaque,
        arg: ?*anyopaque,
        errmsg: ?*[*:0]u8,
    ) c_int;
};

const Allocator = std.mem.Allocator;

const max_delta_chain_depth: usize = 256;
const max_artifact_bytes: usize = 64 * 1024 * 1024;
const busy_timeout_ms: c_int = 5000;

pub const Value = union(enum) {
    null_val,
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
};

pub const QueryResult = struct {
    columns: []const []const u8,
    rows: []const []const Value,

    pub fn deinit(self: QueryResult, alloc: Allocator) void {
        for (self.columns) |col| alloc.free(col);
        alloc.free(self.columns);
        for (self.rows) |row| {
            for (row) |cell| {
                switch (cell) {
                    .text => |s| alloc.free(s),
                    .blob => |b| alloc.free(b),
                    .null_val, .integer, .float => {},
                }
            }
            alloc.free(row);
        }
        alloc.free(self.rows);
    }
};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn openReadOnly(alloc: Allocator, repo_path: []const u8) !Db {
        const path_z = try alloc.dupeSentinel(u8, repo_path, 0);
        defer alloc.free(path_z);

        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX;
        const rc = c.sqlite3_open_v2(path_z.ptr, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return mapSqliteOpenError(rc);
        }
        const handle = db orelse return error.SqliteOpenFailed;
        errdefer _ = c.sqlite3_close(handle);

        _ = c.sqlite3_busy_timeout(handle, busy_timeout_ms);
        return .{ .handle = handle };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Resolve a revision, branch, tag, or `"tip"` to its full check-in UUID.
    /// Equivalent to `fossil whatis --type ci <rev_or_branch>`.
    pub fn fullRevision(self: *Db, alloc: Allocator, rev_or_branch: []const u8) ![]u8 {
        const resolved = try self.resolveCheckin(alloc, rev_or_branch);
        return resolved.uuid;
    }

    /// Reconstruct and return the raw bytes of `file_path` at `rev_or_branch`.
    /// Equivalent to `fossil cat -r <rev_or_branch> <file_path>`.
    pub fn readFileAtRevision(
        self: *Db,
        alloc: Allocator,
        rev_or_branch: []const u8,
        file_path: []const u8,
    ) ![]u8 {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const checkin_ref = try self.resolveCheckin(arena, rev_or_branch);
        const manifest_bytes = try self.reconstructRid(arena, checkin_ref.rid);
        const parsed = try fossil_manifest.parse(arena, manifest_bytes);

        const files = if (parsed.baseline) |baseline_uuid| blk: {
            const baseline_rid = (try self.findRidByExactUuid(baseline_uuid)) orelse return error.MissingBaselineManifest;
            const baseline_bytes = try self.reconstructRid(arena, baseline_rid);
            const baseline_manifest = try fossil_manifest.parse(arena, baseline_bytes);
            break :blk try fossil_manifest.resolve(arena, baseline_manifest, parsed);
        } else parsed.files;

        for (files) |file| {
            if (std.mem.eql(u8, file.path, file_path)) {
                const artifact_uuid = file.artifact orelse return error.InvalidFossilManifest;
                const artifact_rid = (try self.findRidByExactUuid(artifact_uuid)) orelse return error.MissingArtifact;
                const content = try self.reconstructRid(alloc, artifact_rid);
                errdefer alloc.free(content);
                try fossil_manifest.verifyObject(artifact_uuid, content);
                return content;
            }
        }
        return error.FileNotFoundInRevision;
    }

    /// Execute a read-only SQL query against the Fossil SQLite database.
    pub fn queryReadOnly(self: *Db, alloc: Allocator, sql: []const u8) !QueryResult {
        const sql_z = try alloc.dupeSentinel(u8, sql, 0);
        defer alloc.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql_z.ptr, @intCast(sql_z.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        const prepared = stmt orelse return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(prepared);

        // Enforce read-only statement semantics even if caller passes unexpected SQL.
        if (c.sqlite3_stmt_readonly(prepared) == 0) return error.SqliteWriteNotAllowed;

        const col_count_i = c.sqlite3_column_count(prepared);
        const col_count: usize = @intCast(@max(col_count_i, 0));
        const columns = try alloc.alloc([]const u8, col_count);
        var cols_initialized: usize = 0;
        errdefer {
            for (columns[0..cols_initialized]) |col| alloc.free(col);
            alloc.free(columns);
        }
        for (0..col_count) |i| {
            const name_ptr = c.sqlite3_column_name(prepared, @intCast(i));
            const name: []const u8 = if (name_ptr) |p| std.mem.span(p) else "";
            columns[i] = try alloc.dupe(u8, name);
            cols_initialized += 1;
        }

        var rows: std.ArrayList([]const Value) = .empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |cell| switch (cell) {
                    .text => |s| alloc.free(s),
                    .blob => |b| alloc.free(b),
                    .null_val, .integer, .float => {},
                };
                alloc.free(row);
            }
            rows.deinit(alloc);
        }

        while (true) {
            const step_rc = c.sqlite3_step(prepared);
            if (step_rc == c.SQLITE_DONE) break;
            if (step_rc != c.SQLITE_ROW) return mapSqliteStepError(step_rc);

            const row = try alloc.alloc(Value, col_count);
            var cells_initialized: usize = 0;
            errdefer {
                for (row[0..cells_initialized]) |cell| switch (cell) {
                    .text => |s| alloc.free(s),
                    .blob => |b| alloc.free(b),
                    .null_val, .integer, .float => {},
                };
                alloc.free(row);
            }

            for (0..col_count) |i| {
                const col_idx: c_int = @intCast(i);
                const col_type = c.sqlite3_column_type(prepared, col_idx);
                row[i] = switch (col_type) {
                    c.SQLITE_NULL => .null_val,
                    c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(prepared, col_idx) },
                    c.SQLITE_FLOAT => .{ .float = c.sqlite3_column_double(prepared, col_idx) },
                    c.SQLITE_TEXT => blk: {
                        const ptr = c.sqlite3_column_text(prepared, col_idx);
                        const len: usize = @intCast(@max(c.sqlite3_column_bytes(prepared, col_idx), 0));
                        const slice = if (ptr != null and len > 0) ptr.?[0..len] else "";
                        break :blk .{ .text = try alloc.dupe(u8, slice) };
                    },
                    c.SQLITE_BLOB => blk: {
                        const ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(prepared, col_idx));
                        const len: usize = @intCast(@max(c.sqlite3_column_bytes(prepared, col_idx), 0));
                        const slice = if (ptr != null and len > 0) ptr.?[0..len] else "";
                        break :blk .{ .blob = try alloc.dupe(u8, slice) };
                    },
                    else => .null_val,
                };
                cells_initialized += 1;
            }
            try rows.append(alloc, row);
        }

        return .{
            .columns = columns,
            .rows = try rows.toOwnedSlice(alloc),
        };
    }

    const CheckinRef = struct {
        rid: i64,
        uuid: []u8,
    };

    fn resolveCheckin(self: *Db, alloc: Allocator, rev_or_branch: []const u8) !CheckinRef {
        if (rev_or_branch.len == 0) return error.InvalidRevision;

        if (std.mem.eql(u8, rev_or_branch, "tip")) {
            return (try self.querySingleCheckin(
                alloc,
                "SELECT blob.rid, blob.uuid FROM event JOIN blob ON blob.rid = event.objid " ++
                    "WHERE event.type = 'ci' ORDER BY event.mtime DESC, event.objid DESC LIMIT 1;",
                null,
            )) orelse error.RevisionNotFound;
        }

        if (isHexPrefix(rev_or_branch)) {
            if (rev_or_branch.len == 40 or rev_or_branch.len == 64) {
                if (try self.querySingleCheckin(
                    alloc,
                    "SELECT blob.rid, blob.uuid FROM blob JOIN event ON event.objid = blob.rid " ++
                        "WHERE event.type = 'ci' AND (blob.uuid = ?1 OR (length(?1) = 40 AND length(blob.uuid) = 64 AND substr(blob.uuid, 1, 40) = ?1)) LIMIT 2;",
                    rev_or_branch,
                )) |found| return found;
            } else {
                const pattern = try alloc.print("{s}%", .{rev_or_branch});
                defer alloc.free(pattern);
                if (try self.queryUniqueCheckinByPrefix(alloc, pattern)) |found| return found;
            }
        }

        const sym_tag = if (std.mem.startsWith(u8, rev_or_branch, "sym-"))
            try alloc.dupe(u8, rev_or_branch)
        else
            try alloc.print("sym-{s}", .{rev_or_branch});
        defer alloc.free(sym_tag);

        return (try self.querySingleCheckin(
            alloc,
            "SELECT blob.rid, blob.uuid " ++
                "FROM tag " ++
                "JOIN tagxref ON tagxref.tagid = tag.tagid " ++
                "JOIN event ON event.objid = tagxref.rid AND event.type = 'ci' " ++
                "JOIN blob ON blob.rid = tagxref.rid " ++
                "WHERE tag.tagname = ?1 AND tagxref.tagtype > 0 " ++
                "ORDER BY event.mtime DESC, tagxref.rid DESC LIMIT 1;",
            sym_tag,
        )) orelse error.RevisionNotFound;
    }

    fn querySingleCheckin(self: *Db, alloc: Allocator, sql: [:0]const u8, param: ?[]const u8) !?CheckinRef {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        const prepared = stmt orelse return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(prepared);

        if (param) |p| {
            if (c.sqlite3_bind_text(prepared, 1, p.ptr, @intCast(p.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
                return error.SqliteBindFailed;
            }
        }

        const rc = c.sqlite3_step(prepared);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return mapSqliteStepError(rc);

        const rid = c.sqlite3_column_int64(prepared, 0);
        const uuid_ptr = c.sqlite3_column_text(prepared, 1);
        const uuid_len: usize = @intCast(@max(c.sqlite3_column_bytes(prepared, 1), 0));
        if (uuid_ptr == null or uuid_len == 0) return error.InvalidFossilDatabase;
        return .{
            .rid = rid,
            .uuid = try alloc.dupe(u8, uuid_ptr.?[0..uuid_len]),
        };
    }

    fn queryUniqueCheckinByPrefix(self: *Db, alloc: Allocator, like_pattern: []const u8) !?CheckinRef {
        const sql: [:0]const u8 =
            "SELECT blob.rid, blob.uuid FROM blob JOIN event ON event.objid = blob.rid " ++
            "WHERE event.type = 'ci' AND blob.uuid LIKE ?1 LIMIT 2;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        const prepared = stmt orelse return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(prepared);

        if (c.sqlite3_bind_text(prepared, 1, like_pattern.ptr, @intCast(like_pattern.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }

        const rc1 = c.sqlite3_step(prepared);
        if (rc1 == c.SQLITE_DONE) return null;
        if (rc1 != c.SQLITE_ROW) return mapSqliteStepError(rc1);

        const rid = c.sqlite3_column_int64(prepared, 0);
        const uuid_ptr = c.sqlite3_column_text(prepared, 1);
        const uuid_len: usize = @intCast(@max(c.sqlite3_column_bytes(prepared, 1), 0));
        if (uuid_ptr == null or uuid_len == 0) return error.InvalidFossilDatabase;
        const uuid_copy = try alloc.dupe(u8, uuid_ptr.?[0..uuid_len]);
        errdefer alloc.free(uuid_copy);

        const rc2 = c.sqlite3_step(prepared);
        if (rc2 == c.SQLITE_ROW) {
            alloc.free(uuid_copy);
            return error.AmbiguousRevision;
        }
        if (rc2 != c.SQLITE_DONE) return mapSqliteStepError(rc2);

        return .{ .rid = rid, .uuid = uuid_copy };
    }

    fn findRidByExactUuid(self: *Db, uuid: []const u8) !?i64 {
        const sql: [:0]const u8 = "SELECT rid FROM blob WHERE uuid = ?1 LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        const prepared = stmt orelse return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(prepared);

        if (c.sqlite3_bind_text(prepared, 1, uuid.ptr, @intCast(uuid.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }

        const rc = c.sqlite3_step(prepared);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return mapSqliteStepError(rc);
        return c.sqlite3_column_int64(prepared, 0);
    }

    /// Reconstruct the uncompressed, un-deltified artifact bytes for `rid`.
    pub fn reconstructRid(self: *Db, alloc: Allocator, rid: i64) ![]u8 {
        var chain: std.ArrayList(DeltaLink) = .empty;
        defer {
            for (chain.items) |item| alloc.free(item.inflated);
            chain.deinit(alloc);
        }

        var current_rid = rid;
        while (true) {
            if (chain.items.len >= max_delta_chain_depth) return error.DeltaChainTooDeep;
            for (chain.items) |seen| {
                if (seen.rid == current_rid) return error.DeltaCycleDetected;
            }

            const raw_inflated = try self.readAndInflateBlob(alloc, current_rid);
            errdefer alloc.free(raw_inflated);

            const src_rid = try self.findDeltaSource(current_rid);
            try chain.append(alloc, .{ .rid = current_rid, .inflated = raw_inflated });

            if (src_rid) |next_rid| {
                current_rid = next_rid;
            } else {
                break;
            }
        }

        // Base artifact is at the end of `chain`.
        var current_bytes = chain.items[chain.items.len - 1].inflated;
        // Ownership of the base slice transfers out of `chain` if there are no deltas,
        // or gets replaced as we step backwards from base to target.
        chain.items[chain.items.len - 1].inflated = &.{};
        errdefer alloc.free(current_bytes);

        var idx: usize = chain.items.len - 1;
        while (idx > 0) {
            idx -= 1;
            const delta_bytes = chain.items[idx].inflated;
            const next_bytes = try applyFossilDelta(alloc, current_bytes, delta_bytes);
            alloc.free(current_bytes);
            current_bytes = next_bytes;
        }

        return current_bytes;
    }

    const DeltaLink = struct {
        rid: i64,
        inflated: []u8,
    };

    fn findDeltaSource(self: *Db, rid: i64) !?i64 {
        const sql: [:0]const u8 = "SELECT srcid FROM delta WHERE rid = ?1 LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        const prepared = stmt orelse return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(prepared);

        if (c.sqlite3_bind_int64(prepared, 1, rid) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }

        const rc = c.sqlite3_step(prepared);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return mapSqliteStepError(rc);
        return c.sqlite3_column_int64(prepared, 0);
    }

    fn readAndInflateBlob(self: *Db, alloc: Allocator, rid: i64) ![]u8 {
        const sql: [:0]const u8 = "SELECT size, content FROM blob WHERE rid = ?1 LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        const prepared = stmt orelse return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(prepared);

        if (c.sqlite3_bind_int64(prepared, 1, rid) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }

        const rc = c.sqlite3_step(prepared);
        if (rc == c.SQLITE_DONE) return error.MissingArtifact;
        if (rc != c.SQLITE_ROW) return mapSqliteStepError(rc);

        const declared_size = c.sqlite3_column_int64(prepared, 0);
        if (declared_size < 0) return error.MissingBlobContent;
        if (c.sqlite3_column_type(prepared, 1) != c.SQLITE_BLOB) return error.MissingBlobContent;

        const ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(prepared, 1));
        const len: usize = @intCast(@max(c.sqlite3_column_bytes(prepared, 1), 0));
        if (ptr == null or len < 4) return error.MissingBlobContent;
        const compressed = ptr.?[0..len];

        return inflateFossilBlob(alloc, compressed);
    }
};

/// Enable WAL journal mode on the Fossil SQLite database via a short-lived
/// read-write connection.
pub fn enableWalMode(alloc: Allocator, repo_path: []const u8) !void {
    const path_z = try alloc.dupeSentinel(u8, repo_path, 0);
    defer alloc.free(path_z);

    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX;
    const rc = c.sqlite3_open_v2(path_z.ptr, &db, flags, null);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return mapSqliteOpenError(rc);
    }
    const handle = db orelse return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(handle);

    _ = c.sqlite3_busy_timeout(handle, busy_timeout_ms);

    const sql: [:0]const u8 = "PRAGMA journal_mode=WAL;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    const prepared = stmt orelse return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(prepared);

    const step_rc = c.sqlite3_step(prepared);
    if (step_rc != c.SQLITE_ROW and step_rc != c.SQLITE_DONE) {
        return mapSqliteStepError(step_rc);
    }
}

/// Convenience wrapper for `Db.openReadOnly` + `fullRevision`.
pub fn fullRevision(alloc: Allocator, repo_path: []const u8, rev_or_branch: []const u8) ![]u8 {
    var db = try Db.openReadOnly(alloc, repo_path);
    defer db.close();
    return db.fullRevision(alloc, rev_or_branch);
}

/// Convenience wrapper for `Db.openReadOnly` + `readFileAtRevision`.
pub fn readFileAtRevision(
    alloc: Allocator,
    repo_path: []const u8,
    rev_or_branch: []const u8,
    file_path: []const u8,
) ![]u8 {
    var db = try Db.openReadOnly(alloc, repo_path);
    defer db.close();
    return db.readFileAtRevision(alloc, rev_or_branch, file_path);
}

/// Convenience wrapper for `Db.openReadOnly` + `queryReadOnly`.
pub fn queryReadOnly(alloc: Allocator, repo_path: []const u8, sql: []const u8) !QueryResult {
    var db = try Db.openReadOnly(alloc, repo_path);
    defer db.close();
    return db.queryReadOnly(alloc, sql);
}

/// Inflate a Fossil `blob.content` value (4-byte big-endian uncompressed size
/// prefix followed by a zlib-compressed stream).
fn inflateFossilBlob(alloc: Allocator, compressed: []const u8) ![]u8 {
    if (compressed.len < 4) return error.InvalidFossilBlob;
    const expected_size: usize = std.mem.readInt(u32, compressed[0..4], .big);
    if (expected_size > max_artifact_bytes) return error.ArtifactTooLarge;
    if (expected_size == 0) return alloc.alloc(u8, 0);

    var in_reader: std.Io.Reader = .fixed(compressed[4..]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&in_reader, .zlib, &window);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, expected_size);

    decompress.reader.appendRemaining(alloc, &out, .limited(expected_size + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidFossilBlob,
        else => return error.InvalidFossilBlob,
    };
    if (out.items.len != expected_size) return error.InvalidFossilBlob;
    return out.toOwnedSlice(alloc);
}

/// Apply a Fossil delta to `src`, returning the newly allocated target buffer.
/// Format: `<target_size>\n` followed by `<len>@<offset>,`, `<len>:<bytes>`,
/// and `<checksum>;`.
pub fn applyFossilDelta(alloc: Allocator, src: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;
    const target_size = try readDeltaInt(delta, &pos);
    if (target_size > max_artifact_bytes) return error.ArtifactTooLarge;
    if (pos >= delta.len or delta[pos] != '\n') return error.InvalidFossilDelta;
    pos += 1;

    const out = try alloc.alloc(u8, target_size);
    errdefer alloc.free(out);
    var out_pos: usize = 0;

    while (pos < delta.len) {
        const count = try readDeltaInt(delta, &pos);
        if (pos >= delta.len) return error.InvalidFossilDelta;
        const op = delta[pos];
        pos += 1;

        switch (op) {
            '@' => {
                const offset = try readDeltaInt(delta, &pos);
                if (pos >= delta.len or delta[pos] != ',') return error.InvalidFossilDelta;
                pos += 1;
                if (offset > src.len or count > src.len - offset) return error.InvalidFossilDelta;
                if (count > out.len - out_pos) return error.InvalidFossilDelta;
                @memcpy(out[out_pos .. out_pos + count], src[offset .. offset + count]);
                out_pos += count;
            },
            ':' => {
                if (count > delta.len - pos) return error.InvalidFossilDelta;
                if (count > out.len - out_pos) return error.InvalidFossilDelta;
                @memcpy(out[out_pos .. out_pos + count], delta[pos .. pos + count]);
                pos += count;
                out_pos += count;
            },
            ';' => {
                if (out_pos != target_size) return error.InvalidFossilDelta;
                const expected_checksum: u32 = @truncate(count);
                const actual_checksum = fossilDeltaChecksum(out);
                if (actual_checksum != expected_checksum) return error.DeltaChecksumMismatch;
                return out;
            },
            else => return error.InvalidFossilDelta,
        }
    }
    return error.InvalidFossilDelta;
}

fn readDeltaInt(delta: []const u8, pos: *usize) !usize {
    var value: usize = 0;
    var digits: usize = 0;
    while (pos.* < delta.len) {
        const digit = deltaBase64Digit(delta[pos.*]) orelse break;
        if (value > (std.math.maxInt(usize) >> 6)) return error.InvalidFossilDelta;
        value = (value << 6) | digit;
        pos.* += 1;
        digits += 1;
    }
    if (digits == 0) return error.InvalidFossilDelta;
    return value;
}

fn deltaBase64Digit(ch: u8) ?usize {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'A'...'Z' => ch - 'A' + 10,
        '_' => 36,
        'a'...'z' => ch - 'a' + 37,
        '~' => 63,
        else => null,
    };
}

fn fossilDeltaChecksum(data: []const u8) u32 {
    var sum0: u32 = 0;
    var sum1: u32 = 0;
    var sum2: u32 = 0;
    var sum3: u32 = 0;
    var i: usize = 0;
    while (i + 16 <= data.len) : (i += 16) {
        sum0 +%= @as(u32, data[i + 0]) +% data[i + 4] +% data[i + 8] +% data[i + 12];
        sum1 +%= @as(u32, data[i + 1]) +% data[i + 5] +% data[i + 9] +% data[i + 13];
        sum2 +%= @as(u32, data[i + 2]) +% data[i + 6] +% data[i + 10] +% data[i + 14];
        sum3 +%= @as(u32, data[i + 3]) +% data[i + 7] +% data[i + 11] +% data[i + 15];
    }
    while (i + 4 <= data.len) : (i += 4) {
        sum0 +%= data[i + 0];
        sum1 +%= data[i + 1];
        sum2 +%= data[i + 2];
        sum3 +%= data[i + 3];
    }
    sum3 +%= (sum2 << 8) +% (sum1 << 16) +% (sum0 << 24);
    const rem = data.len - i;
    if (rem >= 3) sum3 +%= (@as(u32, data[i + 2]) << 8);
    if (rem >= 2) sum3 +%= (@as(u32, data[i + 1]) << 16);
    if (rem >= 1) sum3 +%= (@as(u32, data[i + 0]) << 24);
    return sum3;
}

fn isHexPrefix(s: []const u8) bool {
    if (s.len < 4 or s.len > 64) return false;
    for (s) |ch| {
        if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    }
    return true;
}

fn mapSqliteOpenError(rc: c_int) anyerror {
    return switch (rc) {
        c.SQLITE_BUSY => error.SqliteBusy,
        c.SQLITE_CANTOPEN => error.FileNotFound,
        c.SQLITE_PERM, c.SQLITE_READONLY => error.AccessDenied,
        else => error.SqliteOpenFailed,
    };
}

fn mapSqliteStepError(rc: c_int) anyerror {
    return switch (rc) {
        c.SQLITE_BUSY => error.SqliteBusy,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.InvalidFossilDatabase,
        else => error.SqliteStepFailed,
    };
}

// --- Tests ---

fn runFossilForTest(alloc: Allocator, cwd: ?[]const u8, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(alloc, std.testing.io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    alloc.free(result.stdout);
    return error.FossilTestCommandFailed;
}

fn parseWhatisArtifact(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "artifact:")) {
            return std.mem.trim(u8, line["artifact:".len..], " \t\r");
        }
    }
    return null;
}

const fossil_bin = "/home/coder/.local/bin/fossil";

test "fossil_sqlite_reader: parity with fossil cat and whatis across delta chains and branches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const repo_path = try std.Io.Dir.path.join(alloc, &.{ root, "repo.fossil" });
    defer alloc.free(repo_path);
    const work_dir = try std.Io.Dir.path.join(alloc, &.{ root, "work" });
    defer alloc.free(work_dir);
    try tmp.dir.createDir(std.testing.io, "work", .default_dir);

    {
        const out = try runFossilForTest(alloc, root, &.{ fossil_bin, "init", "--admin-user", "tester", repo_path });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "open", repo_path });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "user", "default", "tester" });
        alloc.free(out);
    }

    // Revision 1: initial file with enough repeating structure to encourage delta compression later.
    var rev1_buf: std.ArrayList(u8) = .empty;
    defer rev1_buf.deinit(alloc);
    for (0..80) |i| {
        const line = try alloc.print("line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
        defer alloc.free(line);
        try rev1_buf.appendSlice(alloc, line);
    }
    const work_sub = try tmp.dir.openDir(std.testing.io, "work", .{});
    defer work_sub.close(std.testing.io);

    try work_sub.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = rev1_buf.items });
    try work_sub.createDirPath(std.testing.io, "docs/sub");
    try work_sub.writeFile(std.testing.io, .{ .sub_path = "docs/sub/readme with spaces.md", .data = "nested file v1\n" });
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "add", "notes.txt", "docs/sub/readme with spaces.md" });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "commit", "-m", "rev1" });
        alloc.free(out);
    }
    const rev1_whatis = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "whatis", "--type", "ci", "trunk" });
    defer alloc.free(rev1_whatis);
    const rev1_uuid = try alloc.dupe(u8, parseWhatisArtifact(rev1_whatis) orelse return error.MissingTestArtifact);
    defer alloc.free(rev1_uuid);

    // Revision 2: small edit to notes.txt so Fossil stores a delta.
    var rev2_buf: std.ArrayList(u8) = .empty;
    defer rev2_buf.deinit(alloc);
    try rev2_buf.appendSlice(alloc, rev1_buf.items);
    try rev2_buf.appendSlice(alloc, "appended line in rev2\n");
    try work_sub.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = rev2_buf.items });
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "commit", "-m", "rev2" });
        alloc.free(out);
    }

    // Revision 3: another small edit to chain deltas.
    var rev3_buf: std.ArrayList(u8) = .empty;
    defer rev3_buf.deinit(alloc);
    try rev3_buf.appendSlice(alloc, rev2_buf.items);
    try rev3_buf.appendSlice(alloc, "appended line in rev3\n");
    try work_sub.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = rev3_buf.items });
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "commit", "-m", "rev3" });
        alloc.free(out);
    }

    // Branch `feat` with a modification.
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "branch", "new", "feat", "trunk" });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "update", "feat" });
        alloc.free(out);
    }
    try work_sub.writeFile(std.testing.io, .{ .sub_path = "docs/sub/readme with spaces.md", .data = "nested file on feat\n" });
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "commit", "-m", "feat1" });
        alloc.free(out);
    }

    // Enable WAL mode on the repository.
    try enableWalMode(alloc, repo_path);

    // Verify at least one delta actually exists in the repository.
    {
        const qr = try queryReadOnly(alloc, repo_path, "SELECT count(*) FROM delta;");
        defer qr.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), qr.rows.len);
        try std.testing.expect(qr.rows[0][0].integer > 0);
    }

    // Parity: fullRevision vs fossil whatis --type ci
    for ([_][]const u8{ "trunk", "feat", rev1_uuid[0..12], rev1_uuid[0..40], rev1_uuid }) |ref| {
        const expected_whatis = try runFossilForTest(alloc, root, &.{ fossil_bin, "whatis", "--type", "ci", "-R", repo_path, ref });
        defer alloc.free(expected_whatis);
        const expected_uuid = parseWhatisArtifact(expected_whatis) orelse return error.MissingTestArtifact;

        const actual_uuid = try fullRevision(alloc, repo_path, ref);
        defer alloc.free(actual_uuid);
        try std.testing.expectEqualStrings(expected_uuid, actual_uuid);
    }

    // Parity: readFileAtRevision vs fossil cat -r
    const Cases = struct { rev: []const u8, path: []const u8 };
    for ([_]Cases{
        .{ .rev = rev1_uuid, .path = "notes.txt" },
        .{ .rev = "trunk", .path = "notes.txt" },
        .{ .rev = "feat", .path = "notes.txt" },
        .{ .rev = "trunk", .path = "docs/sub/readme with spaces.md" },
        .{ .rev = "feat", .path = "docs/sub/readme with spaces.md" },
    }) |case| {
        const expected_bytes = try runFossilForTest(alloc, root, &.{ fossil_bin, "cat", "-R", repo_path, "-r", case.rev, case.path });
        defer alloc.free(expected_bytes);

        const actual_bytes = try readFileAtRevision(alloc, repo_path, case.rev, case.path);
        defer alloc.free(actual_bytes);
        try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
    }
}

test "fossil_sqlite_reader: concurrent multi-thread reads succeed while lock files and active writer exist" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const repo_path = try std.Io.Dir.path.join(alloc, &.{ root, "repo.fossil" });
    defer alloc.free(repo_path);
    const work_dir = try std.Io.Dir.path.join(alloc, &.{ root, "work" });
    defer alloc.free(work_dir);
    try tmp.dir.createDir(std.testing.io, "work", .default_dir);

    {
        const out = try runFossilForTest(alloc, root, &.{ fossil_bin, "init", "--admin-user", "tester", repo_path });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "open", repo_path });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "user", "default", "tester" });
        alloc.free(out);
    }

    const work_sub = try tmp.dir.openDir(std.testing.io, "work", .{});
    defer work_sub.close(std.testing.io);
    try work_sub.writeFile(std.testing.io, .{ .sub_path = "shared.txt", .data = "concurrent read payload\n" });
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "add", "shared.txt" });
        alloc.free(out);
    }
    {
        const out = try runFossilForTest(alloc, work_dir, &.{ fossil_bin, "commit", "-m", "initial" });
        alloc.free(out);
    }

    try enableWalMode(alloc, repo_path);

    // Simulate held workspace lock files (`command.lock`, `writer.lock`) and an
    // active SQLite WAL writer transaction on another connection.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "command.lock", .data = "held" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "writer.lock", .data = "held" });

    const repo_path_z = try alloc.dupeSentinel(u8, repo_path, 0);
    defer alloc.free(repo_path_z);
    var writer_db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(repo_path_z.ptr, &writer_db, c.SQLITE_OPEN_READWRITE, null));
    defer if (writer_db) |w| {
        _ = c.sqlite3_exec(w, "ROLLBACK;", null, null, null);
        _ = c.sqlite3_close(w);
    };
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(writer_db.?, "BEGIN IMMEDIATE;", null, null, null));

    const WorkerCtx = struct {
        repo_path: []const u8,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var ctx = WorkerCtx{ .repo_path = repo_path };

    const worker_fn = struct {
        fn run(c_ptr: *WorkerCtx) void {
            const thread_alloc = std.heap.c_allocator;
            for (0..8) |_| {
                const rev = fullRevision(thread_alloc, c_ptr.repo_path, "trunk") catch {
                    c_ptr.failed.store(true, .release);
                    return;
                };
                defer thread_alloc.free(rev);
                const bytes = readFileAtRevision(thread_alloc, c_ptr.repo_path, rev, "shared.txt") catch {
                    c_ptr.failed.store(true, .release);
                    return;
                };
                defer thread_alloc.free(bytes);
                if (!std.mem.eql(u8, bytes, "concurrent read payload\n")) {
                    c_ptr.failed.store(true, .release);
                    return;
                }
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker_fn, .{&ctx});
    }
    for (&threads) |*t| t.join();

    try std.testing.expect(!ctx.failed.load(.acquire));
}
