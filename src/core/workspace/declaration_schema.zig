//! Bounded JSON Schema vocabulary used by the pinned declaration and omos profile.
const std = @import("std");
const pattern = @import("../mcp/json_schema_pattern.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const pattern_limits: pattern.Limits = .{ .max_depth = 64, .max_states = 4096, .max_repeat = 1024, .max_steps = 1000000 };

// Captures are unused by this boolean matcher. Preserve escapes and character
// classes while translating the standard's noncapturing groups.
fn acceptancePattern(alloc: Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var escaped = false;
    var in_class = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const byte = source[i];
        if (!escaped and !in_class and std.mem.startsWith(u8, source[i..], "(?:")) {
            try out.append(alloc, '(');
            i += 2;
            continue;
        }
        try out.append(alloc, byte);
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '[') in_class = true;
        if (byte == ']') in_class = false;
    }
    return out.toOwnedSlice(alloc);
}

pub const Result = struct { valid: bool, errors: []const []const u8 = &.{} };

pub fn validate(alloc: Allocator, schema: Value, value: Value) !Result {
    try supported(alloc, schema);
    var context = Context{ .alloc = alloc, .root = schema };
    var count: usize = 0;
    try boundary(value, 0, &count);
    context.check(schema, value, "$", 0) catch |err| switch (err) {
        error.SchemaViolation => return .{ .valid = false, .errors = try alloc.dupe([]const u8, &.{context.message orelse "Invalid declaration"}) },
        else => return err,
    };
    return .{ .valid = true };
}

pub fn boundary(value: Value, depth: usize, count: *usize) !void {
    count.* += 1;
    if (depth > 64 or count.* > 20000) return error.DeclarationTooComplex;
    switch (value) {
        .array => |items| for (items.items) |item| try boundary(item, depth + 1, count),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "__proto__") or std.mem.eql(u8, entry.key_ptr.*, "constructor") or std.mem.eql(u8, entry.key_ptr.*, "prototype")) return error.InvalidDeclarationKey;
                try boundary(entry.value_ptr.*, depth + 1, count);
            }
        },
        else => {},
    }
}

pub fn equal(a: Value, b: Value) bool {
    if ((a == .integer or a == .float) and (b == .integer or b == .float)) return number(a) == number(b);
    const Tag = @typeInfo(Value).@"union".tag_type.?;
    if (@as(Tag, a) != @as(Tag, b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer, .float => unreachable,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |items| blk: {
            if (items.items.len != b.array.items.len) break :blk false;
            for (items.items, b.array.items) |left, right| if (!equal(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != b.object.count()) break :blk false;
            var it = object.iterator();
            while (it.next()) |entry| if (!equal(entry.value_ptr.*, b.object.get(entry.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}

fn number(value: Value) f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => std.math.nan(f64),
    };
}

fn typeMatches(name: []const u8, value: Value) bool {
    if (std.mem.eql(u8, name, "object")) return value == .object;
    if (std.mem.eql(u8, name, "array")) return value == .array;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, name, "null")) return value == .null;
    if (std.mem.eql(u8, name, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, name, "integer")) return value == .integer or (value == .float and @floor(value.float) == value.float);
    return false;
}

pub fn supported(alloc: Allocator, schema: Value) !void {
    const context = Context{ .alloc = alloc, .root = schema };
    try context.checkSchema(schema, 0);
}

const Context = struct {
    alloc: Allocator,
    root: Value,
    message: ?[]const u8 = null,

    fn fail(self: *Context, path: []const u8, message: []const u8) !void {
        self.message = try self.alloc.print("{s}: {s}", .{ path, message });
        return error.SchemaViolation;
    }

    fn resolve(self: Context, ref: []const u8) !Value {
        if (!std.mem.startsWith(u8, ref, "#/$defs/")) return error.UnsupportedSchemaReference;
        const defs = if (self.root == .object) self.root.object.get("$defs") orelse return error.InvalidSchema else return error.InvalidSchema;
        if (defs != .object) return error.InvalidSchema;
        return defs.object.get(ref[8..]) orelse error.InvalidSchemaReference;
    }

    fn checkSchema(self: Context, schema: Value, depth: usize) anyerror!void {
        if (depth > 64) return error.DeclarationTooComplex;
        if (schema == .bool) return;
        if (schema != .object) return error.InvalidSchema;
        var it = schema.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "$ref")) {
                if (value != .string) return error.InvalidSchema;
                _ = try self.resolve(value.string);
            } else if (std.mem.eql(u8, key, "properties") or std.mem.eql(u8, key, "$defs")) {
                if (value != .object) return error.InvalidSchema;
                var children = value.object.iterator();
                while (children.next()) |child| try self.checkSchema(child.value_ptr.*, depth + 1);
            } else if (std.mem.eql(u8, key, "items") or std.mem.eql(u8, key, "additionalProperties")) {
                try self.checkSchema(value, depth + 1);
            } else if (std.mem.eql(u8, key, "required")) {
                if (value != .array) return error.InvalidSchema;
                for (value.array.items) |item| if (item != .string) return error.InvalidSchema;
            } else if (std.mem.eql(u8, key, "pattern")) {
                if (value != .string) return error.InvalidSchema;
                try pattern.validate(self.alloc, try acceptancePattern(self.alloc, value.string), pattern_limits);
            } else if (std.mem.eql(u8, key, "type")) {
                const kinds: []const Value = if (value == .string) &.{value} else if (value == .array and value.array.items.len > 0 and value.array.items.len <= 7) value.array.items else return error.InvalidSchema;
                for (kinds, 0..) |kind, index| {
                    if (kind != .string) return error.InvalidSchema;
                    var known = false;
                    for ([_][]const u8{ "object", "array", "string", "number", "integer", "boolean", "null" }) |name| known = known or std.mem.eql(u8, name, kind.string);
                    if (!known) return error.InvalidSchema;
                    for (kinds[0..index]) |previous| if (std.mem.eql(u8, previous.string, kind.string)) return error.InvalidSchema;
                }
            } else if (std.mem.eql(u8, key, "enum")) {
                if (value != .array or value.array.items.len == 0) return error.InvalidSchema;
            } else if (std.mem.eql(u8, key, "uniqueItems")) {
                if (value != .bool) return error.InvalidSchema;
            } else if (std.mem.eql(u8, key, "minLength") or std.mem.eql(u8, key, "maxLength") or std.mem.eql(u8, key, "minItems") or std.mem.eql(u8, key, "maxItems") or std.mem.eql(u8, key, "minProperties")) {
                if (value != .integer or value.integer < 0) return error.InvalidSchema;
            } else if (std.mem.eql(u8, key, "minimum") or std.mem.eql(u8, key, "maximum") or std.mem.eql(u8, key, "exclusiveMinimum") or std.mem.eql(u8, key, "exclusiveMaximum")) {
                if (value != .integer and value != .float) return error.InvalidSchema;
            } else {
                var annotation = false;
                for ([_][]const u8{ "$schema", "$id", "$comment", "title", "description", "default", "deprecated", "examples", "const" }) |name| annotation = annotation or std.mem.eql(u8, key, name);
                if (!annotation) return error.UnsupportedSchemaFeature;
            }
        }
    }

    fn check(self: *Context, schema: Value, value: Value, path: []const u8, depth: usize) anyerror!void {
        if (depth > 128) return error.DeclarationTooComplex;
        if (schema == .bool) return if (schema.bool) {} else self.fail(path, "Value is prohibited");
        if (schema != .object) return error.InvalidSchema;
        const fields = schema.object;
        if (fields.get("$ref")) |ref| try self.check(try self.resolve(ref.string), value, path, depth + 1);
        if (fields.get("type")) |kind| {
            const accepted = if (kind == .string) typeMatches(kind.string, value) else accepted: {
                for (kind.array.items) |option| if (typeMatches(option.string, value)) break :accepted true;
                break :accepted false;
            };
            if (!accepted) return self.fail(path, "Incorrect value type");
        }
        if (fields.get("const")) |expected| if (!equal(value, expected)) return self.fail(path, "Incorrect constant");
        if (fields.get("enum")) |options| {
            var found = false;
            for (options.array.items) |option| found = found or equal(value, option);
            if (!found) return self.fail(path, "Unsupported value");
        }
        switch (value) {
            .object => |object| {
                if (fields.get("minProperties")) |minimum| if (object.count() < minimum.integer) return self.fail(path, "Too few properties");
                if (fields.get("required")) |required| for (required.array.items) |key| {
                    if (!object.contains(key.string)) return self.fail(try self.alloc.print("{s}/{s}", .{ path, key.string }), "Required property is missing");
                };
                const properties = fields.get("properties");
                var it = object.iterator();
                while (it.next()) |entry| {
                    const child_path = try self.alloc.print("{s}/{s}", .{ path, entry.key_ptr.* });
                    if (if (properties) |props| props.object.get(entry.key_ptr.*) else null) |child| {
                        try self.check(child, entry.value_ptr.*, child_path, depth + 1);
                    } else if (fields.get("additionalProperties")) |additional| try self.check(additional, entry.value_ptr.*, child_path, depth + 1);
                }
            },
            .array => |array| {
                if (fields.get("minItems")) |minimum| if (array.items.len < minimum.integer) return self.fail(path, "Too few items");
                if (fields.get("maxItems")) |maximum| if (array.items.len > maximum.integer) return self.fail(path, "Too many items");
                for (array.items, 0..) |item, i| {
                    if (fields.get("items")) |item_schema| try self.check(item_schema, item, try self.alloc.print("{s}/{d}", .{ path, i }), depth + 1);
                    if (fields.get("uniqueItems")) |unique| if (unique.bool) for (array.items[0..i]) |earlier| {
                        if (equal(earlier, item)) return self.fail(path, "Duplicate item");
                    };
                }
            },
            .string => |text| {
                var length: usize = 0;
                for (text) |byte| if ((byte & 0xc0) != 0x80) {
                    length += 1;
                };
                if (fields.get("minLength")) |minimum| if (length < minimum.integer) return self.fail(path, "String is too short");
                if (fields.get("maxLength")) |maximum| if (length > maximum.integer) return self.fail(path, "String is too long");
                if (fields.get("pattern")) |expression| {
                    var steps: usize = 0;
                    if (!try pattern.matches(self.alloc, try acceptancePattern(self.alloc, expression.string), text, pattern_limits, &steps)) return self.fail(path, "String does not match its pattern");
                }
            },
            .integer, .float => {
                if (fields.get("exclusiveMinimum")) |minimum| if (number(value) <= number(minimum)) return self.fail(path, "Number must exceed its minimum");
                if (fields.get("exclusiveMaximum")) |maximum| if (number(value) >= number(maximum)) return self.fail(path, "Number must be below its maximum");
                if (fields.get("minimum")) |minimum| if (number(value) < number(minimum)) return self.fail(path, "Number is below its minimum");
                if (fields.get("maximum")) |maximum| if (number(value) > number(maximum)) return self.fail(path, "Number exceeds its maximum");
            },
            else => {},
        }
    }
};

test "workspace declaration schema validates nested shapes and rejects unsupported enforcement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema = (try std.json.parseFromSlice(Value, alloc, "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":2}},\"additionalProperties\":false}", .{})).value;
    try supported(alloc, schema);
    const good = (try std.json.parseFromSlice(Value, alloc, "{\"name\":\"example\"}", .{})).value;
    const bad = (try std.json.parseFromSlice(Value, alloc, "{\"name\":\"x\",\"extra\":true}", .{})).value;
    try std.testing.expect((try validate(alloc, schema, good)).valid);
    try std.testing.expect(!(try validate(alloc, schema, bad)).valid);
    const unsupported = (try std.json.parseFromSlice(Value, alloc, "{\"format\":\"email\"}", .{})).value;
    try std.testing.expectError(error.UnsupportedSchemaFeature, supported(alloc, unsupported));
}

test "workspace declaration schema accepts nullable type unions without weakening other constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema = (try std.json.parseFromSlice(Value, alloc, "{\"type\":[\"string\",\"null\"],\"minLength\":2}", .{})).value;
    try std.testing.expect((try validate(alloc, schema, .null)).valid);
    try std.testing.expect((try validate(alloc, schema, .{ .string = "photo" })).valid);
    try std.testing.expect(!(try validate(alloc, schema, .{ .string = "x" })).valid);
    try std.testing.expect(!(try validate(alloc, schema, .{ .integer = 1 })).valid);
    for ([_][]const u8{ "{\"type\":[]}", "{\"type\":[\"string\",\"string\"]}", "{\"type\":[\"string\",1]}", "{\"type\":[\"unknown\"]}" }) |raw| {
        const invalid = (try std.json.parseFromSlice(Value, alloc, raw, .{})).value;
        try std.testing.expectError(error.InvalidSchema, supported(alloc, invalid));
    }
}
