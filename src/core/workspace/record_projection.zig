//! Rebuildable OmniForm views over canonical host events. These projections
//! describe provenance; their presence never establishes an obligation as met.
const std = @import("std");
const model = @import("definition.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Edge = struct {
    relationship: []const u8,
    from: []const u8,
    to: []const u8,
    task: []const u8,
    authority: enum { host_observed, assessor_claim },
    obligation: ?[]const u8 = null,
};

pub const Projection = struct {
    records: std.ArrayList(Value) = .empty,
    relationships: std.ArrayList(Edge) = .empty,
    source_path: []const u8 = "",

    pub fn append(self: *Projection, alloc: Allocator, row: Value, id: []const u8) !void {
        const kind = model.text(row, "kind");
        const task = model.text(row, "task");
        self.source_path = try alloc.print("history/{s}/{s}.json", .{ task, id });
        const value = model.field(row, "value") orelse return error.InvalidWorkspaceJournal;
        if (std.mem.eql(u8, kind, "action_intent")) {
            for (model.items(value, "calls")) |call| {
                const execution_id = model.text(call, "execution_id");
                const action = try actionId(alloc, task, if (execution_id.len > 0) execution_id else model.text(call, "id"));
                try self.record(alloc, "omos_action", action, .{ .task = task, .calls = &[_]Value{call} }, row);
            }
        } else if (std.mem.eql(u8, kind, "tool_evidence")) {
            if (value != .array) return error.InvalidWorkspaceJournal;
            for (value.array.items) |item| {
                const evidence_id = model.text(item, "id");
                try self.record(alloc, "omos_evidence", evidence_id, .{ .task = task, .records = &[_]Value{item} }, row);
                const action = model.text(item, "action_id");
                if (action.len > 0) try self.relationships.append(alloc, .{ .relationship = "omos_action_evidence", .from = try actionId(alloc, task, action), .to = evidence_id, .task = task, .authority = .host_observed });
            }
        } else if (std.mem.eql(u8, kind, "command_receipt")) {
            const content = try std.json.Stringify.valueAlloc(alloc, value, .{});
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
            const receipt = try alloc.print("command-receipt:{s}", .{std.fmt.bytesToHex(&digest, .lower)});
            try self.record(alloc, "omos_evidence", receipt, .{ .task = task, .records = &.{.{ .id = receipt, .kind = "verification", .content = content }} }, row);
            try self.relationships.append(alloc, .{ .relationship = "omos_evidence_receipt", .from = model.text(value, "evidence_id"), .to = receipt, .task = task, .authority = .host_observed });
        } else if (std.mem.eql(u8, kind, "task_plan")) {
            try self.record(alloc, "omos_plan", id, value, row);
        } else if (std.mem.eql(u8, kind, "paused_result")) {
            const status = model.text(value, "status");
            try self.record(alloc, "omos_result", id, .{ .task = task, .status = if (status.len > 0) status else "paused", .summary = model.text(value, "summary"), .remaining = model.field(value, "remaining_contract") orelse .null }, row);
        } else if (std.mem.eql(u8, kind, "review_assessment")) {
            const decision = (try std.json.parseFromSlice(Value, alloc, model.text(value, "data"), .{})).value;
            try self.record(alloc, "omos_assessment", id, .{ .task = task, .phase = "completion", .decision = decision }, row);
            for (model.items(decision, "obligations")) |obligation| for (model.items(obligation, "evidence")) |reference| {
                if (reference != .string) return error.InvalidWorkspaceJournal;
                try self.relationships.append(alloc, .{ .relationship = "omos_evidence_assessment", .from = reference.string, .to = id, .task = task, .authority = .assessor_claim, .obligation = model.text(obligation, "id") });
            };
        } else {
            try self.record(alloc, "omos_event", id, .{ .task = task, .kind = kind, .payload = value }, row);
        }
    }

    fn record(self: *Projection, alloc: Allocator, entity: []const u8, id: []const u8, data: anytype, source: Value) !void {
        const provenance = .{ .task = model.text(source, "task"), .kind = model.text(source, "kind"), .contract_version = model.field(source, "contract_version") orelse .null };
        try self.records.append(alloc, (try std.json.parseFromSlice(Value, alloc, try std.json.Stringify.valueAlloc(alloc, .{ .entity = entity, .id = id, .data = data, .source = provenance, .source_path = self.source_path }, .{}), .{})).value);
    }
};

fn actionId(alloc: Allocator, task: []const u8, id: []const u8) ![]const u8 {
    return alloc.print("{s}:action:{s}", .{ task, id });
}

test "workspace projections distinguish observed provenance from assessment claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var projection: Projection = .{};
    const raw = "{\"kind\":\"tool_evidence\",\"task\":\"task\",\"value\":[{\"id\":\"evidence\",\"action_id\":\"call-1\",\"content\":\"result\"}]}";
    try projection.append(alloc, (try std.json.parseFromSlice(Value, alloc, raw, .{})).value, "event");
    try std.testing.expectEqualStrings("omos_evidence", model.text(projection.records.items[0], "entity"));
    try std.testing.expectEqualStrings("task:action:call-1", projection.relationships.items[0].from);
    try std.testing.expectEqual(.host_observed, projection.relationships.items[0].authority);
}

/// Keep only link identities while record bodies are consumed in scratch arenas.
pub const PlanLinks = struct {
    const Action = struct { id: []const u8, task: []const u8, group: []const u8 };
    plans: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    actions: std.ArrayList(Action) = .empty,

    pub fn remember(self: *PlanLinks, alloc: Allocator, row: Value) !void {
        const entity = model.text(row, "entity");
        const is_plan = std.mem.eql(u8, entity, "omos_plan");
        if (!is_plan and !std.mem.eql(u8, entity, "omos_action")) return;
        const source = model.field(row, "source") orelse return;
        const version = model.field(source, "contract_version") orelse return;
        const task = model.text(source, "task");
        const group = try std.json.Stringify.valueAlloc(alloc, .{ task, version }, .{});
        const id = try alloc.dupe(u8, model.text(row, "id"));
        if (is_plan) {
            const entry = try self.plans.getOrPut(alloc, group);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(alloc, id);
        } else try self.actions.append(alloc, .{ .id = id, .task = try alloc.dupe(u8, task), .group = group });
    }

    pub fn emit(self: PlanLinks, page: anytype) !void {
        for (self.actions.items) |action| {
            const plans = self.plans.get(action.group) orelse continue;
            for (plans.items) |plan| try page.edge(.{ .relationship = "omos_plan_actions", .from = plan, .to = action.id, .task = action.task, .authority = .host_observed });
        }
    }
};

test "workspace projections stream plan links after their source bodies are released" {
    var retained = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer retained.deinit();
    var links: PlanLinks = .{};
    {
        var temporary = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer temporary.deinit();
        for ([_][]const u8{
            "{\"entity\":\"omos_plan\",\"id\":\"plan\",\"source\":{\"task\":\"task\",\"contract_version\":1}}",
            "{\"entity\":\"omos_action\",\"id\":\"action\",\"source\":{\"task\":\"task\",\"contract_version\":1}}",
            "{\"entity\":\"omos_action\",\"id\":\"other-version\",\"source\":{\"task\":\"task\",\"contract_version\":2}}",
        }) |raw| try links.remember(retained.allocator(), try std.json.parseFromSliceLeaky(Value, temporary.allocator(), raw, .{}));
    }
    const Sink = struct {
        count: usize = 0,
        pub fn edge(self: *@This(), item: Edge) !void {
            try std.testing.expectEqualStrings("plan", item.from);
            try std.testing.expectEqualStrings("action", item.to);
            self.count += 1;
        }
    };
    var sink: Sink = .{};
    try links.emit(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
}
