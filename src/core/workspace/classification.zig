//! Typed decisions shared by routing, tools and external adapters. Decisions
//! are advisory: neither a label nor a probability grants execution authority.
const std = @import("std");
const io = @import("../shared/io.zig");
const bounded = @import("../shared/bounded_operation.zig");

pub const Choice = struct { label: []const u8, description: []const u8 };
pub const Question = struct { id: []const u8, instructions: []const u8, choices: []const Choice };
pub const Request = struct { state: std.json.Value, questions: []const Question };
pub const Probability = struct { label: []const u8, probability: f64 };
pub const Decision = struct { question: []const u8, choice: []const u8, confidence: f64, probabilities: []const Probability };
pub const Result = struct {
    version: []const u8 = "omos.classification/v1",
    model: []const u8,
    elapsed_ms: i64,
    advisory: bool = true,
    truncated: bool = false,
    decisions: []const Decision,
};

const Configuration = struct {
    version: []const u8 = "omos.classifier/v1",
    endpoint: []const u8,
    model: []const u8 = "laya:en",
    token: ?[]const u8 = null,
};

fn configuration(alloc: std.mem.Allocator) !Configuration {
    if (io.getenv("OMOS_CLASSIFIER_URL")) |endpoint| return .{ .endpoint = endpoint, .model = io.getenv("OMOS_CLASSIFIER_MODEL") orelse "laya:en", .token = io.getenv("OMOS_CLASSIFIER_TOKEN") };
    const home = io.getenv("HOME") orelse return error.ClassifierNotConfigured;
    const path = try alloc.print("{s}/.fx/classifier.json", .{home});
    var file = std.Io.Dir.openFileAbsolute(io.getIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.ClassifierNotConfigured,
        else => return err,
    };
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeClassifierConfiguration;
    const config = try std.json.parseFromSliceLeaky(Configuration, alloc, try io.readFileToEnd(alloc, &file, 16384), .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, config.version, "omos.classifier/v1")) return error.UnsupportedClassifierConfiguration;
    return config;
}

pub fn configured() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = configuration(arena.allocator()) catch return false;
    return true;
}

pub fn validate(request: Request) !void {
    if (request.state != .string and request.state != .object and request.state != .array) return error.InvalidClassificationState;
    if (request.questions.len == 0 or request.questions.len > 8) return error.InvalidClassificationQuestions;
    for (request.questions, 0..) |question, i| {
        if (question.id.len == 0 or question.id.len > 64 or question.instructions.len == 0 or question.instructions.len > 2048) return error.InvalidClassificationQuestion;
        for (request.questions[0..i]) |previous| if (std.mem.eql(u8, question.id, previous.id)) return error.DuplicateClassificationQuestion;
        if (question.choices.len < 2 or question.choices.len > 32) return error.InvalidClassificationChoices;
        for (question.choices, 0..) |choice, j| {
            if (choice.label.len == 0 or choice.label.len > 128 or choice.description.len > 2048) return error.InvalidClassificationChoice;
            for (question.choices[0..j]) |previous| if (std.mem.eql(u8, choice.label, previous.label)) return error.DuplicateClassificationChoice;
        }
    }
}

/// All result storage belongs to the caller's request arena. Endpoint and model
/// are owner configuration, never model-supplied tool arguments.
pub fn execute(alloc: std.mem.Allocator, request: Request, cancel: ?*std.atomic.Value(bool)) !Result {
    try validate(request);
    const config = try configuration(alloc);
    const endpoint = config.endpoint;
    const model = config.model;
    const token = config.token;
    const body = try encode(alloc, request, model);
    defer alloc.free(body);
    if (body.len > 32768) return error.ClassificationInputTooLarge;
    var stopped = std.atomic.Value(bool).init(false);
    const started = io.milliTimestamp();
    const operation: Operation = .{ .alloc = alloc, .endpoint = endpoint, .body = body, .token = token };
    var response = try bounded.run(Body, alloc, cancel orelse &stopped, .fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(10000) }), operation);
    defer response.deinit(alloc);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.bytes, .{});
    defer parsed.deinit();
    return decode(alloc, request, parsed.value, io.milliTimestamp() - started);
}

fn encode(alloc: std.mem.Allocator, request: Request, model: []const u8) ![]u8 {
    var questions: std.json.ObjectMap = .empty;
    defer {
        for (questions.values()) |*value| {
            value.object.getPtr("criteria").?.object.deinit(alloc);
            value.object.deinit(alloc);
        }
        questions.deinit(alloc);
    }
    for (request.questions) |question| {
        var criteria: std.json.ObjectMap = .empty;
        errdefer criteria.deinit(alloc);
        for (question.choices) |choice| try criteria.put(alloc, choice.label, .{ .string = choice.description });
        var value: std.json.ObjectMap = .empty;
        errdefer value.deinit(alloc);
        try value.put(alloc, "type", .{ .string = "choice" });
        try value.put(alloc, "instructions", .{ .string = question.instructions });
        try value.put(alloc, "criteria", .{ .object = criteria });
        try questions.put(alloc, question.id, .{ .object = value });
    }
    return std.json.Stringify.valueAlloc(alloc, .{ .model = model, .state = request.state, .questions = std.json.Value{ .object = questions } }, .{});
}

fn number(value: std.json.Value) !f64 {
    const result: f64 = switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => return error.InvalidClassifierResponse,
    };
    if (!std.math.isFinite(result) or result < 0 or result > 1) return error.InvalidClassifierResponse;
    return result;
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidClassifierResponse;
    return value.object.get(name) orelse error.InvalidClassifierResponse;
}

fn text(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidClassifierResponse;
    return value.string;
}

fn decode(alloc: std.mem.Allocator, request: Request, raw: std.json.Value, elapsed_ms: i64) !Result {
    const answers = try field(raw, "answers");
    if (answers != .object or answers.object.count() != request.questions.len) return error.InvalidClassifierResponse;
    const decisions = try alloc.alloc(Decision, request.questions.len);
    for (request.questions, decisions) |question, *decision| {
        const answer = try field(answers, question.id);
        if (!std.mem.eql(u8, try text(try field(answer, "type")), "choice")) return error.InvalidClassifierResponse;
        const choice = try text(try field(answer, "choice"));
        const probabilities = try field(answer, "probabilities");
        if (probabilities != .object or probabilities.object.count() != question.choices.len) return error.InvalidClassifierResponse;
        var found = false;
        var sum: f64 = 0;
        const scores = try alloc.alloc(Probability, question.choices.len);
        for (question.choices, scores) |option, *score| {
            found = found or std.mem.eql(u8, choice, option.label);
            const probability = try number(try field(probabilities, option.label));
            sum += probability;
            score.* = .{ .label = try alloc.dupe(u8, option.label), .probability = probability };
        }
        if (!found or @abs(sum - 1) > 0.005) return error.InvalidClassifierResponse;
        decision.* = .{ .question = try alloc.dupe(u8, question.id), .choice = try alloc.dupe(u8, choice), .confidence = try number(try field(answer, "confidence")), .probabilities = scores };
    }
    return .{ .model = try alloc.dupe(u8, try text(try field(raw, "model"))), .elapsed_ms = elapsed_ms, .decisions = decisions };
}

const Body = struct {
    bytes: []u8,
    pub fn deinit(self: *Body, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};
const Operation = struct {
    alloc: std.mem.Allocator,
    endpoint: []const u8,
    body: []const u8,
    token: ?[]const u8,
    pub fn run(self: @This()) !Body {
        const uri = try std.Uri.parse(self.endpoint);
        if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidClassifierEndpoint;
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidClassifierEndpoint;
        if (self.token) |token| if (std.mem.findAny(u8, token, "\r\n") != null) return error.InvalidClassifierToken;
        const url = try self.alloc.print("{s}/v1/systemone", .{std.mem.trimEnd(u8, self.endpoint, "/")});
        defer self.alloc.free(url);
        const bearer = if (self.token) |token| try self.alloc.print("Bearer {s}", .{token}) else null;
        defer if (bearer) |value| self.alloc.free(value);
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io.getIo() };
        defer client.deinit();
        var request = try client.request(.POST, try std.Uri.parse(url), .{ .redirect_behavior = .unhandled, .headers = .{ .authorization = if (bearer) |value| .{ .override = value } else .omit, .content_type = .{ .override = "application/json" }, .accept_encoding = .omit } });
        defer request.deinit();
        try request.sendBodyComplete(@constCast(self.body));
        var response = try request.receiveHead(&.{});
        if (response.head.status == .unprocessable_entity) return error.ClassificationInputRejected;
        if (response.head.status != .ok) return error.ClassifierUnavailable;
        var buffer: [4096]u8 = undefined;
        return .{ .bytes = try response.reader(&buffer).allocRemaining(self.alloc, .limited(65536)) };
    }
};

test "classification rejects duplicate choices and malformed model answers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const request: Request = .{ .state = .{ .string = "find last application" }, .questions = &.{.{ .id = "route", .instructions = "Choose a route", .choices = &.{ .{ .label = "read", .description = "Read content" }, .{ .label = "work", .description = "Change state" } } }} };
    try validate(request);
    const valid = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"model\":\"test\",\"answers\":{\"route\":{\"type\":\"choice\",\"choice\":\"read\",\"confidence\":0.8,\"probabilities\":{\"read\":0.9,\"work\":0.1}}}}", .{});
    const result = try decode(alloc, request, valid, 12);
    try std.testing.expectEqualStrings("read", result.decisions[0].choice);
    var invalid = valid;
    try invalid.object.getPtr("answers").?.object.getPtr("route").?.object.put(alloc, "choice", .{ .string = "unoffered" });
    try std.testing.expectError(error.InvalidClassifierResponse, decode(alloc, request, invalid, 0));
    const duplicate: Request = .{ .state = request.state, .questions = &.{.{ .id = "route", .instructions = "Choose", .choices = &.{ .{ .label = "same", .description = "one" }, .{ .label = "same", .description = "two" } } }} };
    try std.testing.expectError(error.DuplicateClassificationChoice, validate(duplicate));
}
