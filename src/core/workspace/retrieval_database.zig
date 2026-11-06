//! Structured, read-only queries over a verified SQLite artifact. The existing
//! Fossil helper supplies SQLite; callers never submit SQL or filesystem paths.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const retrieval = @import("retrieval.zig");
const model = @import("definition.zig");
const value = @import("capabilities.zig").value;

pub fn query(manager: workspace.Manager, request: retrieval.Request, revision: []const u8, artifact: []const u8, bytes: []const u8) !std.json.Value {
    const alloc = manager.alloc;
    if (request.pointer.len != 0) return error.DatabaseQueryDoesNotUsePointer;
    const schema = try run(manager, artifact, bytes, "SELECT json_group_array(json_object('name',name,'sql',sql)) AS value FROM (SELECT name,sql FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 129);");
    if (schema != .array or schema.array.items.len > 128) return error.DatabaseSchemaTooLarge;
    var tables: std.ArrayList([]const u8) = .empty;
    for (schema.array.items) |table| {
        // Virtual tables and views can invoke external modules or functions.
        // Only ordinary stored tables participate in this read contract.
        if (!ordinaryTable(model.text(table, "sql"))) continue;
        try tables.append(alloc, model.text(table, "name"));
    }
    const entity = request.entity orelse return value(alloc, .{ .version = "omos.retrieval/v1", .revision = revision, .path = request.path, .artifact = artifact, .tables = tables.items, .next_offset = @as(?usize, null), .instruction = "Set entity to a table name, then use filters and order_by with column names.", .authority = "source_schema" });
    if (!contains(tables.items, entity)) return error.UnknownDatabaseTable;
    const columns = try run(manager, artifact, bytes, try alloc.print("SELECT json_group_array(json_object('name',name,'type',type,'pk',pk)) AS value FROM pragma_table_info({s});", .{try quoted(alloc, entity, '\'')}));
    if (columns != .array or columns.array.items.len == 0 or columns.array.items.len > 128) return error.DatabaseSchemaTooLarge;
    var names: std.ArrayList([]const u8) = .empty;
    var primary: std.ArrayList([]const u8) = .empty;
    var fields: std.Io.Writer.Allocating = .init(alloc);
    for (columns.array.items, 0..) |column, i| {
        const name = model.text(column, "name");
        try names.append(alloc, name);
        const pk = column.object.get("pk") orelse return error.InvalidDatabaseSchema;
        if (pk == .integer and pk.integer > 0) try primary.append(alloc, name);
        if (i > 0) try fields.writer.writeByte(',');
        const identifier = try quoted(alloc, name, '"');
        try fields.writer.print("{s},CASE WHEN typeof({s})='blob' THEN hex({s}) ELSE {s} END", .{ try quoted(alloc, name, '\''), identifier, identifier, identifier });
    }
    var where: std.Io.Writer.Allocating = .init(alloc);
    try where.writer.writeAll(" WHERE 1");
    for (request.filters) |filter| {
        if (!contains(names.items, filter.field)) return error.UnknownDatabaseColumn;
        try where.writer.print(" AND {s}={s}", .{ try quoted(alloc, filter.field, '"'), try quoted(alloc, filter.equals, '\'') });
    }
    var order: std.Io.Writer.Allocating = .init(alloc);
    try order.writer.writeAll(" ORDER BY ");
    if (request.order_by) |field| {
        if (!contains(names.items, field)) return error.UnknownDatabaseColumn;
        try order.writer.print("{s} {s},", .{ try quoted(alloc, field, '"'), if (request.descending) "DESC" else "ASC" });
    }
    if (primary.items.len == 0) {
        try order.writer.writeAll("rowid");
    } else {
        for (primary.items, 0..) |field, i| {
            if (i > 0) try order.writer.writeByte(',');
            try order.writer.writeAll(try quoted(alloc, field, '"'));
        }
    }
    const table = try quoted(alloc, entity, '"');
    const sql = try alloc.print("SELECT json_object('total',(SELECT count(*) FROM {s}{s}),'rows',json((SELECT json_group_array(json(row)) FROM (SELECT json_object({s}) AS row FROM {s}{s}{s} LIMIT {d} OFFSET {d})))) AS value;", .{ table, where.written(), fields.written(), table, where.written(), order.written(), request.limit, request.offset });
    const result = try run(manager, artifact, bytes, sql);
    if (result != .object) return error.InvalidDatabaseResult;
    const total = result.object.get("total") orelse return error.InvalidDatabaseResult;
    const rows = result.object.get("rows") orelse return error.InvalidDatabaseResult;
    if (total != .integer or total.integer < 0 or rows != .array) return error.InvalidDatabaseResult;
    var records: std.ArrayList(std.json.Value) = .empty;
    for (rows.array.items, 0..) |row, i| try records.append(alloc, try value(alloc, .{ .index = request.offset +| i, .record = row }));
    const next = request.offset +| rows.array.items.len;
    return value(alloc, .{ .version = "omos.retrieval/v1", .revision = revision, .path = request.path, .artifact = artifact, .entity = entity, .columns = columns, .records = records.items, .total = total, .next_offset = if (next < @as(u64, @intCast(total.integer))) @as(?usize, next) else null, .ordering = "SQLite column affinity; primary key or rowid breaks ties; BLOB values are hex", .authority = "source_records" });
}

fn run(manager: workspace.Manager, artifact: []const u8, bytes: []const u8, sql: []const u8) !std.json.Value {
    const rows = try std.json.parseFromSliceLeaky([]const struct { value: []const u8 }, manager.alloc, try manager.retrievalDatabase(artifact, bytes, sql), .{});
    if (rows.len != 1) return error.InvalidDatabaseResult;
    return std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, rows[0].value, .{});
}
fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}
fn ordinaryTable(sql: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, sql, " \r\n\t");
    return std.ascii.eqlIgnoreCase(words.next() orelse "", "CREATE") and std.ascii.eqlIgnoreCase(words.next() orelse "", "TABLE");
}
fn quoted(alloc: std.mem.Allocator, input: []const u8, delimiter: u8) ![]const u8 {
    if (input.len > 4096 or std.mem.findScalar(u8, input, 0) != null) return error.InvalidDatabaseField;
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeByte(delimiter);
    for (input) |byte| {
        try out.writer.writeByte(byte);
        if (byte == delimiter) try out.writer.writeByte(byte);
    }
    try out.writer.writeByte(delimiter);
    return out.toOwnedSlice();
}

test "database queries quote literal and identifier delimiters and exclude virtual tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("'x''; DROP TABLE job;--'", try quoted(arena.allocator(), "x'; DROP TABLE job;--", '\''));
    try std.testing.expectEqualStrings("\"a\"\"b\"", try quoted(arena.allocator(), "a\"b", '"'));
    try std.testing.expect(ordinaryTable("CREATE TABLE jobs(id TEXT)"));
    try std.testing.expect(!ordinaryTable("CREATE   VIRTUAL TABLE jobs USING fsdir"));
    try std.testing.expect(!ordinaryTable("CREATE VIEW jobs AS SELECT readfile('private')"));
}
