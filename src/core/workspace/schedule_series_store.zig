//! Series transitions run under the workspace writer lease. A durable
//! reservation precedes every native session/task creation operation.
const std = @import("std");
const series = @import("schedule_series.zig");
const scheduling = @import("scheduling.zig");
const records = @import("../shared/record_json.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const Allocator = std.mem.Allocator;
const series_path = "schedules/series-v1.json";
const starts_path = "schedules/state.json";

pub const Write = struct { path: []const u8, content: ?[]const u8 };
pub const Template = struct { task: []const u8, revision: []const u8, content: []const u8 };
pub const Backend = struct {
    context: *anyopaque,
    alloc: Allocator,
    workspace: []const u8,
    revision_fn: *const fn (*anyopaque) anyerror![]const u8,
    read_fn: *const fn (*anyopaque, []const u8) anyerror!?[]const u8,
    paths_fn: *const fn (*anyopaque, []const u8) anyerror![]const []const u8,
    commit_fn: *const fn (*anyopaque, []const Write) anyerror!void,
    template_fn: *const fn (*anyopaque, []const u8) anyerror!Template,
    base_fn: *const fn (*anyopaque) anyerror![]const u8,
    prepare_fn: *const fn (*anyopaque, series.Series, series.Occurrence) anyerror!u32,
    accepted_fn: *const fn (*anyopaque, []const u8) anyerror!bool,
    authorize_fn: ?*const fn (*anyopaque, series.Series) anyerror!void = null,
    now_ms: i64,
    fault_fn: ?*const fn (*anyopaque, []const u8) anyerror!void = null,

    fn read(self: Backend, path: []const u8) !?[]const u8 {
        return self.read_fn(self.context, path);
    }
    fn fault(self: Backend, name: []const u8) !void {
        if (self.fault_fn) |invoke| try invoke(self.context, name);
    }
};

fn encode(backend: Backend, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(backend.alloc, value, .{});
}
fn digest(backend: Backend, value: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &hash, .{});
    return backend.alloc.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn validId(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
fn validRevision(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn load(backend: Backend) !series.Store {
    const bytes = (try backend.read(series_path)) orelse return .{ .workspace = backend.workspace };
    const store = try records.decode(series.Store, backend.alloc, bytes, .{});
    if (!std.mem.eql(u8, store.version, series.api_version) or !std.mem.eql(u8, store.workspace, backend.workspace) or store.series.len > 256) return error.InvalidScheduleSeriesStore;
    for (store.series, 0..) |value, index| {
        if (!validId(value.id) or !validId(value.template_task) or !validId(value.template_sha256) or !validRevision(value.template_revision) or value.rule_version == 0) return error.InvalidScheduleSeriesStore;
        try series.validateRule(value.rule, value.anchor_ms);
        if (value.max_occurrences) |count| if (count == 0 or count > 10_000) return error.InvalidScheduleSeriesStore;
        if (value.next_ms) |at| if (at < value.anchor_ms or at > series.max_ms) return error.InvalidScheduleSeriesStore;
        if (value.until_ms) |at| if (at <= value.anchor_ms or at > series.max_ms) return error.InvalidScheduleSeriesStore;
        if (value.last_materialized_ms) |at| if (at < 0 or at > series.max_ms) return error.InvalidScheduleSeriesStore;
        if (value.active_occurrence) |active| if (!validId(active.id) or active.nominal_ms < 0 or active.nominal_ms > series.max_ms or active.at_ms < 0 or active.at_ms > series.max_ms) return error.InvalidScheduleSeriesStore;
        for (store.series[0..index]) |previous| if (std.mem.eql(u8, previous.id, value.id)) return error.InvalidScheduleSeriesStore;
    }
    return store;
}

fn loadStarts(backend: Backend) !scheduling.Store {
    const bytes = (try backend.read(starts_path)) orelse return .{ .workspace = backend.workspace };
    const store = try records.decode(scheduling.Store, backend.alloc, bytes, .{});
    if (!std.mem.eql(u8, store.version, "omos.schedule/v1") or !std.mem.eql(u8, store.workspace, backend.workspace) or store.schedules.len > 1024) return error.InvalidScheduleStore;
    return store;
}
fn findStart(store: *scheduling.Store, id: []const u8) ?*scheduling.Schedule {
    // Stores loaded by the operation arena are mutable and have one writer.
    for (@constCast(store.schedules)) |*start| if (std.mem.eql(u8, start.id, id)) return start;
    return null;
}
fn removeStart(backend: Backend, store: *scheduling.Store, id: []const u8) !void {
    var retained: std.ArrayList(scheduling.Schedule) = .empty;
    for (store.schedules) |start| if (!std.mem.eql(u8, start.id, id)) try retained.append(backend.alloc, start);
    store.schedules = try retained.toOwnedSlice(backend.alloc);
}
fn startEvent(backend: Backend, start: *scheduling.Schedule, kind: []const u8) !void {
    const history = try backend.alloc.alloc(scheduling.Event, start.history.len + 1);
    @memcpy(history[0..start.history.len], start.history);
    history[start.history.len] = .{ .at_ms = backend.now_ms, .kind = kind, .scheduled_ms = start.at_ms, .contract_version = start.contract_version, .reason = start.reason };
    start.history = history;
}

fn occurrencePath(backend: Backend, series_id: []const u8, id: []const u8, at_ms: i64) ![]const u8 {
    return backend.alloc.print("schedules/occurrences/{s}/{d:0>15}-{s}.json", .{ series_id, @as(u64, @intCast(at_ms)), id });
}
fn activeOccurrence(backend: Backend, value: series.Series) !?series.Occurrence {
    const active = value.active_occurrence orelse return null;
    const path = try occurrencePath(backend, value.id, active.id, active.at_ms);
    const bytes = (try backend.read(path)) orelse return error.InvalidScheduleOccurrence;
    const occurrence = try records.decode(series.Occurrence, backend.alloc, bytes, .{});
    if (!std.mem.eql(u8, occurrence.id, active.id) or !std.mem.eql(u8, occurrence.series, value.id) or occurrence.nominal_ms != active.nominal_ms or occurrence.at_ms != active.at_ms or !validId(occurrence.task) or !validId(occurrence.session) or !validId(occurrence.schedule) or !validRevision(occurrence.base_revision) or occurrence.contract_version == 0) return error.InvalidScheduleOccurrence;
    if (occurrence.rule_version == 0 or occurrence.rule_version > value.rule_version) return error.InvalidScheduleOccurrence;
    const expected = try digest(backend, try backend.alloc.print("{s}:{d}:{d}", .{ value.id, occurrence.rule_version, occurrence.nominal_ms }));
    if (!std.mem.eql(u8, expected, occurrence.id) or !std.mem.eql(u8, occurrence.task, try digest(backend, try backend.alloc.print("task:{s}", .{expected}))) or !std.mem.eql(u8, occurrence.session, try digest(backend, try backend.alloc.print("session:{s}:{s}", .{ backend.workspace, expected }))) or !std.mem.eql(u8, occurrence.schedule, try digest(backend, try backend.alloc.print("schedule:{s}", .{expected})))) return error.InvalidScheduleOccurrence;
    return occurrence;
}

fn appendOccurrence(backend: Backend, writes: *std.ArrayList(Write), occurrence: series.Occurrence) !void {
    try writes.append(backend.alloc, .{ .path = try occurrencePath(backend, occurrence.series, occurrence.id, occurrence.at_ms), .content = try encode(backend, occurrence) });
}
fn appendEvent(backend: Backend, writes: *std.ArrayList(Write), value: *series.Series, original: series.Event) !void {
    value.event_sequence = try std.math.add(u64, value.event_sequence, 1);
    var event = original;
    event.sequence = value.event_sequence;
    const path = try backend.alloc.print("schedules/series-events/{s}/{d:0>20}.json", .{ value.id, event.sequence });
    try writes.append(backend.alloc, .{ .path = path, .content = try encode(backend, event) });
}

fn commit(backend: Backend, store: series.Store, starts: ?scheduling.Store, extra: []const Write) !void {
    var writes: std.ArrayList(Write) = .empty;
    try writes.appendSlice(backend.alloc, extra);
    try writes.append(backend.alloc, .{ .path = series_path, .content = try encode(backend, store) });
    if (starts) |value| try writes.append(backend.alloc, .{ .path = starts_path, .content = try encode(backend, value) });
    try backend.commit_fn(backend.context, writes.items);
}

pub fn execute(backend: Backend, request: series.Request) !series.Snapshot {
    if (backend.now_ms < 0 or backend.now_ms > series.max_ms) return error.InvalidScheduleTime;
    try series.validateRequest(request);
    const before = try backend.revision_fn(backend.context);
    if (request.revision) |revision| if (!std.mem.eql(u8, revision, before)) return error.WorkspaceRevisionChanged;
    var store = try load(backend);
    if (!series.mutation(request)) return snapshot(backend, store, request);
    var starts = try loadStarts(backend);
    const values = try backend.alloc.dupe(series.Series, store.series);
    store.series = values;
    var writes: std.ArrayList(Write) = .empty;
    var selected = request.id;
    if (request.action == .add) {
        if (store.series.len >= 256) return error.ScheduleSeriesLimitReached;
        const template = try backend.template_fn(backend.context, request.task.?);
        const anchor = try scheduling.parseTimestamp(request.at.?);
        try series.validateRule(request.rule.?, anchor);
        const until = if (request.until) |raw| try scheduling.parseTimestamp(raw) else null;
        if (until) |end| if (end <= anchor) return error.InvalidSeriesEnd;
        var nonce: [32]u8 = undefined;
        @import("../shared/io.zig").getIo().random(&nonce);
        var value: series.Series = .{ .id = try digest(backend, &nonce), .template_task = template.task, .template_revision = template.revision, .template_sha256 = try digest(backend, template.content), .rule = request.rule.?, .anchor_ms = anchor, .next_ms = anchor, .until_ms = until, .max_occurrences = request.max_occurrences, .overlap = request.overlap orelse .block };
        if (backend.authorize_fn) |authorize| try authorize(backend.context, value);
        try writes.append(backend.alloc, .{ .path = try backend.alloc.print("schedules/templates/{s}.json", .{value.id}), .content = template.content });
        try appendEvent(backend, &writes, &value, .{ .at_ms = backend.now_ms, .kind = "created" });
        const all = try backend.alloc.alloc(series.Series, values.len + 1);
        @memcpy(all[0..values.len], values);
        all[values.len] = value;
        store.series = all;
        selected = value.id;
    } else {
        const value = for (values) |*candidate| {
            if (std.mem.eql(u8, candidate.id, request.id.?)) break candidate;
        } else return error.ScheduleSeriesNotFound;
        if (value.state == .cancelled) return error.ScheduleSeriesIsFinal;
        var occurrence = try activeOccurrence(backend, value.*);
        switch (request.action) {
            .update => {
                if (request.at == null and request.rule == null and request.overlap == null and request.until == null and request.max_occurrences == null and !request.clear_until and !request.clear_count) return error.InvalidSeriesOption;
                if (request.at) |at| value.anchor_ms = try scheduling.parseTimestamp(at);
                if (request.rule) |rule| value.rule = rule;
                try series.validateRule(value.rule, value.anchor_ms);
                if (request.overlap) |overlap| value.overlap = overlap;
                if (request.clear_until) value.until_ms = null else if (request.until) |until| value.until_ms = try scheduling.parseTimestamp(until);
                if (value.until_ms) |until| if (until <= value.anchor_ms) return error.InvalidSeriesEnd;
                if (request.clear_count) value.max_occurrences = null else if (request.max_occurrences) |count| {
                    if (count < value.materialized_count) return error.InvalidSeriesCount;
                    value.max_occurrences = count;
                }
                value.rule_version = try std.math.add(u32, value.rule_version, 1);
                value.next_ms = if (value.last_materialized_ms) |last| try series.next(value.rule, value.anchor_ms, last) else value.anchor_ms;
                if (value.state == .completed) value.state = .active;
                value.reason = "";
            },
            .pause => {
                if (value.state != .active) return error.InvalidSeriesTransition;
                value.state = .paused;
                if (occurrence) |*item| {
                    if (item.preparation == .reserved) item.preparation = .paused else if (findStart(&starts, item.schedule)) |start| if (start.state == .scheduled) {
                        start.state = .cancelled;
                        start.reason = "Recurring series paused; this unclaimed start is retained.";
                        start.finished_ms = backend.now_ms;
                        try startEvent(backend, start, "series_paused");
                        item.preparation = .paused;
                    };
                }
            },
            .@"resume" => {
                if (value.state != .paused) return error.InvalidSeriesTransition;
                if (backend.authorize_fn) |authorize| try authorize(backend.context, value.*);
                value.state = .active;
                value.reason = "";
                if (occurrence) |*item| if (item.preparation == .paused) {
                    if (findStart(&starts, item.schedule)) |start| {
                        if (start.state != .cancelled) return error.InvalidScheduleOccurrence;
                        start.state = .scheduled;
                        start.reason = "";
                        start.finished_ms = null;
                        try startEvent(backend, start, "series_resumed");
                        item.preparation = .prepared;
                    } else item.preparation = .reserved;
                };
            },
            .move => {
                const item = if (occurrence) |*active| active else return error.ScheduleOccurrenceNotFound;
                if (!std.mem.eql(u8, item.id, request.occurrence.?)) return error.ScheduleOccurrenceNotFound;
                if (item.outcome != null or item.started_ms != null or item.preparation == .skipped) return error.ScheduleOccurrenceIsFinal;
                if (item.preparation == .prepared and try backend.accepted_fn(backend.context, item.task)) return error.ScheduleOccurrenceIsFinal;
                const at = try scheduling.parseTimestamp(request.at.?);
                if (value.until_ms) |until| if (at > until) return error.InvalidSeriesEnd;
                try writes.append(backend.alloc, .{ .path = try occurrencePath(backend, item.series, item.id, item.at_ms), .content = null });
                if (findStart(&starts, item.schedule)) |start| {
                    if (start.state == .running or start.started_ms != null) return error.ScheduleIsRunning;
                    if (start.state != .scheduled and item.preparation != .paused) return error.ScheduleOccurrenceIsFinal;
                    start.at_ms = at;
                    try startEvent(backend, start, "rescheduled");
                }
                item.at_ms = at;
                value.active_occurrence.?.at_ms = at;
            },
            .skip, .cancel => {
                if (request.action == .cancel) value.state = .cancelled;
                if (occurrence) |*item| {
                    if (request.occurrence) |id| if (!std.mem.eql(u8, id, item.id)) return error.ScheduleOccurrenceNotFound;
                    const running = if (findStart(&starts, item.schedule)) |start| start.state == .running else false;
                    const accepted = item.preparation == .prepared and try backend.accepted_fn(backend.context, item.task);
                    if (request.action == .skip and (accepted or item.outcome == .completed or item.outcome == .cancelled)) return error.ScheduleOccurrenceIsFinal;
                    if (running and request.action == .skip) return error.ScheduleIsRunning;
                    if (accepted or !running) {
                        if (findStart(&starts, item.schedule)) |start| {
                            item.started_ms = start.started_ms;
                            item.schedule_history = start.history;
                        }
                        try removeStart(backend, &starts, item.schedule);
                        if (!accepted) item.preparation = .skipped;
                        item.outcome = if (accepted) .completed else .cancelled;
                        item.finished_ms = backend.now_ms;
                        item.reason = if (accepted) "Verified publication accepted before series cancellation." else if (request.action == .skip) "Occurrence explicitly skipped; existing work is retained." else "Series cancelled; existing work is retained.";
                        value.active_occurrence = null;
                    }
                } else if (request.action == .skip) return error.ScheduleOccurrenceNotFound;
            },
            else => return error.InvalidSeriesOption,
        }
        if (occurrence) |item| try appendOccurrence(backend, &writes, item);
        if (value.state != .cancelled and value.active_occurrence == null and ((value.max_occurrences != null and value.materialized_count >= value.max_occurrences.?) or value.next_ms == null or (value.until_ms != null and value.next_ms.? > value.until_ms.?))) value.state = .completed;
        try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = @tagName(request.action) });
    }
    try commit(backend, store, starts, writes.items);
    var response = request;
    response.id = selected;
    response.action = .show;
    response.revision = null;
    return snapshot(backend, store, response);
}

pub fn hasDue(backend: Backend) !bool {
    for ((try load(backend)).series) |value| {
        if (value.active_occurrence != null) return true;
        if (value.state == .active) if (value.next_ms) |next_ms| if (next_ms <= backend.now_ms) return true;
    }
    return false;
}

pub fn ownsStart(backend: Backend, id: []const u8) !bool {
    return (try occurrenceForStart(backend, id)) != null;
}

pub fn occurrenceForStart(backend: Backend, id: []const u8) !?series.Occurrence {
    for ((try load(backend)).series) |value| {
        if (try activeOccurrence(backend, value)) |occurrence| if (std.mem.eql(u8, occurrence.schedule, id)) return occurrence;
    }
    return null;
}

fn advance(value: *series.Series, after: i64) !void {
    value.next_ms = try series.next(value.rule, value.anchor_ms, after);
    if (value.until_ms) |until| if (value.next_ms != null and value.next_ms.? > until) {
        value.next_ms = null;
    };
    if (value.max_occurrences) |count| if (value.materialized_count >= count) {
        value.next_ms = null;
    };
}

fn skipThrough(backend: Backend, value: *series.Series, through: i64, writes: *std.ArrayList(Write)) !bool {
    const next_ms = value.next_ms orelse return false;
    const cutoff = if (value.until_ms) |until| @min(until, through) else through;
    if (next_ms > cutoff) return false;
    const last = (try series.latest(value.rule, value.anchor_ms, cutoff)) orelse return false;
    if (last < next_ms) return false;
    const count = try series.ordinal(value.rule, value.anchor_ms, last) - try series.ordinal(value.rule, value.anchor_ms, next_ms) + 1;
    try appendEvent(backend, writes, value, .{ .at_ms = backend.now_ms, .kind = "overlap_skipped", .from_ms = next_ms, .to_ms = last, .slots = count });
    try advance(value, last);
    return true;
}

/// Reconciles old reservations before generating work. The owner holds both
/// the writer lease and the workspace execution lease; no actor runs here.
/// One invocation prepares at most one new occurrence across the workspace.
pub fn materialize(backend: Backend) !bool {
    if (backend.now_ms < 0 or backend.now_ms > series.max_ms) return error.InvalidScheduleTime;
    var store = try load(backend);
    const values = try backend.alloc.dupe(series.Series, store.series);
    store.series = values;
    var starts = try loadStarts(backend);
    var writes: std.ArrayList(Write) = .empty;
    var changed = false;
    for (values) |*value| {
        var occurrence = try activeOccurrence(backend, value.*);
        if (occurrence) |*item| if (item.preparation == .prepared) {
            const start = findStart(&starts, item.schedule) orelse return error.InvalidScheduleOccurrence;
            if (start.state == .scheduled) try backend.fault("series_after_schedule");
            const accepted = try backend.accepted_fn(backend.context, item.task);
            if (accepted or start.state == .completed or start.state == .cancelled) {
                // A completed row without an independently published contract
                // cannot settle an occurrence, even if its store was edited.
                if (start.state == .completed and !accepted) return error.WorkspaceReviewRequired;
                if (value.overlap == .skip) {
                    const resolved_ms = if (start.state == .completed) @min(backend.now_ms, start.finished_ms orelse backend.now_ms) else backend.now_ms;
                    _ = try skipThrough(backend, value, resolved_ms, &writes);
                }
                item.outcome = if (accepted) .completed else .cancelled;
                item.started_ms = start.started_ms;
                item.finished_ms = start.finished_ms orelse backend.now_ms;
                item.reason = start.reason;
                item.schedule_history = start.history;
                try appendOccurrence(backend, &writes, item.*);
                try removeStart(backend, &starts, item.schedule);
                value.active_occurrence = null;
                try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = if (accepted) "occurrence_completed" else "occurrence_cancelled" });
                occurrence = null;
                changed = true;
            } else if ((start.state == .waiting or start.state == .failed) and (item.outcome != start.state or !std.mem.eql(u8, item.reason, start.reason))) {
                item.outcome = start.state;
                item.started_ms = start.started_ms;
                item.finished_ms = start.finished_ms;
                item.reason = start.reason;
                item.schedule_history = start.history;
                try appendOccurrence(backend, &writes, item.*);
                changed = true;
            }
        };
        if (occurrence == null and value.state != .cancelled and value.state != .completed) {
            if ((value.max_occurrences != null and value.materialized_count >= value.max_occurrences.?) or value.next_ms == null or (value.until_ms != null and value.next_ms.? > value.until_ms.?)) {
                value.state = .completed;
                value.next_ms = null;
                try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = "completed" });
                changed = true;
                continue;
            }
        }
        if (value.state != .active) continue;
        if (occurrence) |item| {
            if (item.preparation != .reserved) {
                if (value.overlap == .skip and try skipThrough(backend, value, backend.now_ms, &writes)) changed = true;
                continue;
            }
        } else {
            if (value.next_ms.? > backend.now_ms) continue;
            const cutoff = if (value.until_ms) |until| @min(until, backend.now_ms) else backend.now_ms;
            const nominal = (try series.latest(value.rule, value.anchor_ms, cutoff)) orelse continue;
            if (nominal < value.next_ms.?) continue;
            if (nominal > value.next_ms.?) {
                const count = try series.ordinal(value.rule, value.anchor_ms, nominal) - try series.ordinal(value.rule, value.anchor_ms, value.next_ms.?);
                try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = "missed_coalesced", .from_ms = value.next_ms, .to_ms = nominal, .slots = count });
            }
            const key = try digest(backend, try backend.alloc.print("{s}:{d}:{d}", .{ value.id, value.rule_version, nominal }));
            occurrence = .{ .id = key, .series = value.id, .rule_version = value.rule_version, .nominal_ms = nominal, .at_ms = nominal, .task = try digest(backend, try backend.alloc.print("task:{s}", .{key})), .session = try digest(backend, try backend.alloc.print("session:{s}:{s}", .{ backend.workspace, key })), .schedule = try digest(backend, try backend.alloc.print("schedule:{s}", .{key})), .base_revision = try backend.base_fn(backend.context) };
            value.active_occurrence = .{ .id = key, .nominal_ms = nominal, .at_ms = nominal };
            value.last_materialized_ms = nominal;
            value.materialized_count = try std.math.add(u32, value.materialized_count, 1);
            try appendOccurrence(backend, &writes, occurrence.?);
            try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = "reserved" });
            // This commit is the identity/count fence. Retrying preparation
            // must reuse it regardless of how many local steps completed.
            try commit(backend, store, starts, writes.items);
            writes.clearRetainingCapacity();
            changed = false;
            try backend.fault("series_after_reservation");
        }
        const item = &occurrence.?;
        try backend.fault("series_after_reservation");
        if (starts.schedules.len >= 1024) {
            value.state = .paused;
            value.reason = "ScheduleLimitReached";
            item.reason = value.reason;
            try appendOccurrence(backend, &writes, item.*);
            try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = "preparation_paused", .reason = value.reason });
            try commit(backend, store, starts, writes.items);
            return true;
        }
        item.contract_version = backend.prepare_fn(backend.context, value.*, item.*) catch |err| {
            if (err == error.Cancelled or err == error.OutOfMemory or err == error.InjectedFossilFault or err == error.WorkspaceInjectedFailure) return err;
            value.state = .paused;
            value.reason = @errorName(err);
            item.reason = @errorName(err);
            try appendOccurrence(backend, &writes, item.*);
            try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = "preparation_paused", .reason = @errorName(err) });
            try commit(backend, store, starts, writes.items);
            return true;
        };
        try backend.fault("series_before_schedule");
        if (findStart(&starts, item.schedule) != null) return error.InvalidScheduleOccurrence;
        if (starts.schedules.len >= 1024) return error.ScheduleLimitReached;
        const all = try backend.alloc.alloc(scheduling.Schedule, starts.schedules.len + 1);
        @memcpy(all[0..starts.schedules.len], starts.schedules);
        all[starts.schedules.len] = .{ .id = item.schedule, .task = item.task, .at_ms = item.at_ms, .contract_version = item.contract_version };
        try startEvent(backend, &all[starts.schedules.len], "created");
        starts.schedules = all;
        item.preparation = .prepared;
        item.reason = "";
        try advance(value, item.nominal_ms);
        try appendOccurrence(backend, &writes, item.*);
        try appendEvent(backend, &writes, value, .{ .at_ms = backend.now_ms, .kind = "prepared" });
        try commit(backend, store, starts, writes.items);
        try backend.fault("series_after_schedule");
        return true;
    }
    if (changed) try commit(backend, store, starts, writes.items);
    return changed;
}

fn pathInstant(path: []const u8) !i64 {
    const base = std.Io.Dir.path.basename(path);
    if (base.len < 16 or base[15] != '-') return error.InvalidScheduleOccurrence;
    return std.fmt.parseInt(i64, base[0..15], 10) catch error.InvalidScheduleOccurrence;
}

fn snapshot(backend: Backend, store: series.Store, request: series.Request) !series.Snapshot {
    var selected: std.ArrayList(series.Series) = .empty;
    for (store.series) |value| {
        if (request.id) |id| if (!std.mem.eql(u8, value.id, id)) continue;
        try selected.append(backend.alloc, value);
    }
    if (request.id != null and selected.items.len == 0) return error.ScheduleSeriesNotFound;
    var paths: std.ArrayList([]const u8) = .empty;
    for (selected.items) |value| {
        const prefix = try backend.alloc.print("schedules/occurrences/{s}/", .{value.id});
        for (try backend.paths_fn(backend.context, prefix)) |path| {
            const at = try pathInstant(path);
            if (request.from) |from| if (at < try scheduling.parseTimestamp(from) or at >= try scheduling.parseTimestamp(request.to.?)) continue;
            try paths.append(backend.alloc, path);
        }
    }
    sort_utils.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, std.Io.Dir.path.basename(a), std.Io.Dir.path.basename(b)) == .gt;
        }
    }.less);
    const begin = @min(request.cursor, paths.items.len);
    const end = @min(begin + request.limit, paths.items.len);
    var occurrences: std.ArrayList(series.Occurrence) = .empty;
    var starts = try loadStarts(backend);
    for (paths.items[begin..end]) |path| {
        const bytes = (try backend.read(path)) orelse return error.InvalidScheduleOccurrence;
        var occurrence = try records.decode(series.Occurrence, backend.alloc, bytes, .{});
        if (findStart(&starts, occurrence.schedule)) |start| {
            occurrence.outcome = start.state;
            occurrence.started_ms = start.started_ms;
            occurrence.finished_ms = start.finished_ms;
            occurrence.schedule_history = start.history;
            occurrence.reason = start.reason;
        }
        try occurrences.append(backend.alloc, occurrence);
    }
    var projected: std.ArrayList(series.Projection) = .empty;
    var truncated = end < paths.items.len;
    if (request.from) |raw_from| {
        const from = @max(try scheduling.parseTimestamp(raw_from), backend.now_ms);
        const to = try scheduling.parseTimestamp(request.to.?);
        for (selected.items) |value| {
            if (value.state != .active or value.next_ms == null) continue;
            var remaining: u32 = if (value.max_occurrences) |count| count -| value.materialized_count else 10_000;
            var after = from - 1;
            if (value.last_materialized_ms) |last| after = @max(after, last);
            if (value.next_ms) |next_ms| after = @max(after, next_ms - 1);
            while (remaining > 0) : (remaining -= 1) {
                const at = (try series.next(value.rule, value.anchor_ms, after)) orelse break;
                if (at >= to) break;
                if (value.until_ms) |until| if (at > until) break;
                if (projected.items.len >= 2000) {
                    truncated = true;
                    break;
                }
                try projected.append(backend.alloc, .{ .series = value.id, .rule_version = value.rule_version, .at_ms = at });
                after = at;
            }
        }
    }
    var events: std.ArrayList(series.Event) = .empty;
    var next_event_cursor: ?usize = null;
    if (request.id) |id| {
        const event_paths = try backend.paths_fn(backend.context, try backend.alloc.print("schedules/series-events/{s}/", .{id}));
        const sorted = try backend.alloc.dupe([]const u8, event_paths);
        sort_utils.sort([]const u8, sorted, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .gt;
            }
        }.less);
        const first = @min(request.events_cursor, sorted.len);
        const last = @min(first + request.limit, sorted.len);
        for (sorted[first..last]) |path| try events.append(backend.alloc, try records.decode(series.Event, backend.alloc, (try backend.read(path)) orelse return error.InvalidScheduleSeriesStore, .{}));
        if (last < sorted.len) next_event_cursor = last;
    }
    return .{ .workspace = backend.workspace, .revision = try backend.revision_fn(backend.context), .series = try selected.toOwnedSlice(backend.alloc), .occurrences = try occurrences.toOwnedSlice(backend.alloc), .projected = try projected.toOwnedSlice(backend.alloc), .events = try events.toOwnedSlice(backend.alloc), .next_cursor = if (end < paths.items.len) end else null, .next_event_cursor = next_event_cursor, .truncated = truncated };
}

const TestStore = struct {
    alloc: Allocator,
    files: std.StringHashMap([]const u8),
    sessions: std.StringHashMap(void),
    tasks: std.StringHashMap(void),
    accepted: std.StringHashMap(void),
    revision: u64 = 0,
    now: i64,
    fail: ?[]const u8 = null,

    fn init(alloc: Allocator, now: i64) TestStore {
        return .{ .alloc = alloc, .files = .init(alloc), .sessions = .init(alloc), .tasks = .init(alloc), .accepted = .init(alloc), .now = now };
    }
    fn self(raw: *anyopaque) *TestStore {
        return @ptrCast(@alignCast(raw));
    }
    fn revisionFn(raw: *anyopaque) ![]const u8 {
        const value = self(raw);
        return value.alloc.print("{d}", .{value.revision});
    }
    fn readFn(raw: *anyopaque, path: []const u8) !?[]const u8 {
        return self(raw).files.get(path);
    }
    fn pathsFn(raw: *anyopaque, prefix: []const u8) ![]const []const u8 {
        const value = self(raw);
        var paths: std.ArrayList([]const u8) = .empty;
        var iterator = value.files.keyIterator();
        while (iterator.next()) |path| if (std.mem.startsWith(u8, path.*, prefix)) try paths.append(value.alloc, path.*);
        return paths.toOwnedSlice(value.alloc);
    }
    fn commitFn(raw: *anyopaque, writes: []const Write) !void {
        const value = self(raw);
        for (writes) |write| if (write.content) |bytes| {
            try value.files.put(try value.alloc.dupe(u8, write.path), try value.alloc.dupe(u8, bytes));
        } else {
            _ = value.files.remove(write.path);
        };
        value.revision += 1;
    }
    fn templateFn(_: *anyopaque, task: []const u8) !Template {
        return .{ .task = task, .revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .content = "fixture template" };
    }
    fn baseFn(_: *anyopaque) ![]const u8 {
        return "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    }
    fn faultFn(raw: *anyopaque, name: []const u8) !void {
        if (self(raw).fail) |fail| if (std.mem.eql(u8, fail, name)) return error.InjectedFossilFault;
    }
    fn prepareFn(raw: *anyopaque, _: series.Series, occurrence: series.Occurrence) !u32 {
        const value = self(raw);
        try value.sessions.put(occurrence.session, {});
        try faultFn(raw, "series_after_session");
        try value.tasks.put(occurrence.task, {});
        try faultFn(raw, "series_after_task");
        return 1;
    }
    fn acceptedFn(raw: *anyopaque, task: []const u8) !bool {
        return self(raw).accepted.contains(task);
    }
    fn backend(value: *TestStore) Backend {
        return .{ .context = value, .alloc = value.alloc, .workspace = "workspace", .revision_fn = revisionFn, .read_fn = readFn, .paths_fn = pathsFn, .commit_fn = commitFn, .template_fn = templateFn, .base_fn = baseFn, .prepare_fn = prepareFn, .accepted_fn = acceptedFn, .now_ms = value.now, .fault_fn = faultFn };
    }
    fn create(value: *TestStore, count: ?u32) !series.Snapshot {
        return execute(value.backend(), .{ .action = .add, .task = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .at = "2026-10-26T09:00:00Z", .rule = .{ .cadence = .interval, .interval_ms = 60_000 }, .max_occurrences = count, .revision = try revisionFn(value) });
    }
};

test "recurring reservations recover every preparation boundary without duplicate identities" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    for ([_][]const u8{ "series_after_reservation", "series_after_session", "series_after_task", "series_before_schedule", "series_after_schedule" }) |point| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var store = TestStore.init(arena.allocator(), anchor);
        const created = try store.create(2);
        store.fail = point;
        try std.testing.expectError(error.InjectedFossilFault, materialize(store.backend()));
        const reservation = (try load(store.backend())).series[0].active_occurrence.?;
        store.fail = null;
        _ = try materialize(store.backend());
        _ = try materialize(store.backend());
        const after = try execute(store.backend(), .{ .action = .show, .id = created.series[0].id });
        try std.testing.expectEqual(@as(u32, 1), after.series[0].materialized_count);
        try std.testing.expectEqualStrings(reservation.id, after.occurrences[0].id);
        try std.testing.expectEqual(@as(usize, 1), store.sessions.count());
        try std.testing.expectEqual(@as(usize, 1), store.tasks.count());
        try std.testing.expectEqual(@as(usize, 1), (try loadStarts(store.backend())).schedules.len);
    }
}

test "recurring coalescing counts fresh materializations and ends after verified outcomes" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor + 4 * 60_000);
    const id = (try store.create(2)).series[0].id;
    _ = try materialize(store.backend());
    const first = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(anchor + 4 * 60_000, first.occurrences[0].nominal_ms);
    try std.testing.expectEqual(@as(u32, 1), first.series[0].materialized_count);
    const coalesced = for (first.events) |event| {
        if (std.mem.eql(u8, event.kind, "missed_coalesced")) break event;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 4), coalesced.slots);
    try store.accepted.put(first.occurrences[0].task, {});
    store.now += 60_000;
    _ = try materialize(store.backend());
    const second = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(@as(u32, 2), second.series[0].materialized_count);
    try std.testing.expectEqual(@as(usize, 2), second.occurrences.len);
    try std.testing.expect(!std.mem.eql(u8, second.occurrences[0].task, second.occurrences[1].task));
    try std.testing.expect(!std.mem.eql(u8, second.occurrences[0].session, second.occurrences[1].session));
    try std.testing.expectEqual(@FieldType(series.Series, "state").active, second.series[0].state);
    try store.accepted.put(second.occurrences[0].task, {});
    _ = try materialize(store.backend());
    const final = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(@FieldType(series.Series, "state").completed, final.series[0].state);
    try std.testing.expectEqual(@as(usize, 0), (try loadStarts(store.backend())).schedules.len);
    try std.testing.expectEqual(@as(usize, 2), store.sessions.count());
    try std.testing.expectEqual(@as(usize, 2), store.tasks.count());
}

test "recurring pause fences dispatch and resume never replays a waiting run" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor);
    const created = try store.create(2);
    const id = created.series[0].id;
    _ = try materialize(store.backend());
    try std.testing.expectError(error.WorkspaceRevisionChanged, execute(store.backend(), .{ .action = .pause, .id = id, .revision = created.revision }));
    _ = try execute(store.backend(), .{ .action = .pause, .id = id, .revision = try TestStore.revisionFn(&store) });
    try std.testing.expectEqual(scheduling.State.cancelled, (try loadStarts(store.backend())).schedules[0].state);
    store.now += 3 * 60_000;
    _ = try materialize(store.backend());
    try std.testing.expectEqual(@as(usize, 1), store.tasks.count());
    _ = try execute(store.backend(), .{ .action = .@"resume", .id = id, .revision = try TestStore.revisionFn(&store) });
    var starts = try loadStarts(store.backend());
    const start = findStart(&starts, starts.schedules[0].id).?;
    start.state = .waiting;
    start.started_ms = anchor;
    start.reason = "Needs user input";
    try TestStore.commitFn(&store, &.{.{ .path = starts_path, .content = try encode(store.backend(), starts) }});
    _ = try materialize(store.backend());
    _ = try execute(store.backend(), .{ .action = .pause, .id = id, .revision = try TestStore.revisionFn(&store) });
    _ = try execute(store.backend(), .{ .action = .@"resume", .id = id, .revision = try TestStore.revisionFn(&store) });
    try std.testing.expectEqual(scheduling.State.waiting, (try loadStarts(store.backend())).schedules[0].state);
    _ = try materialize(store.backend());
    try std.testing.expectEqual(@as(usize, 1), store.tasks.count());
    _ = try execute(store.backend(), .{ .action = .skip, .id = id, .revision = try TestStore.revisionFn(&store) });
    _ = try materialize(store.backend());
    const after = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(@as(u32, 2), after.series[0].materialized_count);
    try std.testing.expectEqual(@as(usize, 2), store.tasks.count());
    try std.testing.expectEqual(scheduling.State.cancelled, after.occurrences[1].outcome.?);
}

test "recurring projections are bounded read-only data" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor);
    const id = (try store.create(null)).series[0].id;
    const snapshot_value = try execute(store.backend(), .{ .action = .show, .id = id, .from = "2026-10-26T09:00:00Z", .to = "2026-10-29T09:00:00Z" });
    try std.testing.expectEqual(@as(usize, 2000), snapshot_value.projected.len);
    try std.testing.expect(snapshot_value.truncated);
    try std.testing.expectEqual(@as(u32, 0), snapshot_value.series[0].materialized_count);
    try std.testing.expectEqual(@as(usize, 0), store.tasks.count());
    try std.testing.expectEqual(@as(usize, 0), (try loadStarts(store.backend())).schedules.len);
}

test "recurring overlap skipping separates active slots from later downtime" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor);
    const id = (try store.create(null)).series[0].id;
    _ = try execute(store.backend(), .{ .action = .update, .id = id, .overlap = .skip, .revision = try TestStore.revisionFn(&store) });
    _ = try materialize(store.backend());
    var starts = try loadStarts(store.backend());
    const task = starts.schedules[0].task;
    const start = findStart(&starts, starts.schedules[0].id).?;
    start.state = .completed;
    start.finished_ms = anchor + 2 * 60_000;
    try TestStore.commitFn(&store, &.{.{ .path = starts_path, .content = try encode(store.backend(), starts) }});
    try store.accepted.put(task, {});
    store.now = anchor + 5 * 60_000;
    _ = try materialize(store.backend());
    const result = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(@as(u32, 2), result.series[0].materialized_count);
    try std.testing.expectEqual(anchor + 5 * 60_000, result.occurrences[0].nominal_ms);
    var skipped: u64 = 0;
    var coalesced: u64 = 0;
    for (result.events) |event| {
        if (std.mem.eql(u8, event.kind, "overlap_skipped")) skipped += event.slots;
        if (std.mem.eql(u8, event.kind, "missed_coalesced")) coalesced += event.slots;
    }
    try std.testing.expectEqual(@as(u64, 2), skipped);
    try std.testing.expectEqual(@as(u64, 2), coalesced);
}

test "recurring until includes its last slot and unlimited series can exceed count option bounds" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor + 60_000);
    const id = (try store.create(null)).series[0].id;
    var portable = try load(store.backend());
    const values = try store.alloc.dupe(series.Series, portable.series);
    values[0].materialized_count = 10_000;
    portable.series = values;
    try TestStore.commitFn(&store, &.{.{ .path = series_path, .content = try encode(store.backend(), portable) }});
    _ = try execute(store.backend(), .{ .action = .update, .id = id, .until = "2026-10-26T09:01:00Z", .revision = try TestStore.revisionFn(&store) });
    _ = try materialize(store.backend());
    const result = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(@as(u32, 10_001), result.series[0].materialized_count);
    try std.testing.expectEqual(anchor + 60_000, result.occurrences[0].at_ms);
    try store.accepted.put(result.occurrences[0].task, {});
    store.now += 60_000;
    _ = try materialize(store.backend());
    try std.testing.expectEqual(@FieldType(series.Series, "state").completed, (try load(store.backend())).series[0].state);
}

test "recurring rule edits preserve slot identity and moved starts preserve nominal cadence" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor);
    const id = (try store.create(3)).series[0].id;
    _ = try materialize(store.backend());
    const first = try execute(store.backend(), .{ .action = .show, .id = id });
    _ = try execute(store.backend(), .{ .action = .move, .id = id, .occurrence = first.occurrences[0].id, .at = "2026-10-26T09:00:30Z", .revision = try TestStore.revisionFn(&store) });
    const moved = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(anchor, moved.occurrences[0].nominal_ms);
    try std.testing.expectEqual(anchor + 30_000, moved.occurrences[0].at_ms);
    try std.testing.expectEqual(@as(usize, 1), moved.occurrences.len);
    _ = try execute(store.backend(), .{ .action = .update, .id = id, .rule = .{ .cadence = .interval, .interval_ms = 120_000 }, .revision = try TestStore.revisionFn(&store) });
    try store.accepted.put(first.occurrences[0].task, {});
    store.now = anchor + 120_000;
    _ = try materialize(store.backend());
    const after = try execute(store.backend(), .{ .action = .show, .id = id });
    try std.testing.expectEqual(@as(u32, 2), after.series[0].materialized_count);
    try std.testing.expectEqual(@as(u32, 2), after.occurrences[0].rule_version);
    try std.testing.expectEqual(anchor + 120_000, after.occurrences[0].nominal_ms);
}

test "recurring final-state mutations cannot discard a verified publication" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor);
    const id = (try store.create(2)).series[0].id;
    _ = try materialize(store.backend());
    const first = try execute(store.backend(), .{ .action = .show, .id = id });
    try store.accepted.put(first.occurrences[0].task, {});
    try std.testing.expectError(error.ScheduleOccurrenceIsFinal, execute(store.backend(), .{ .action = .skip, .id = id, .revision = try TestStore.revisionFn(&store) }));
    try std.testing.expectError(error.ScheduleOccurrenceIsFinal, execute(store.backend(), .{ .action = .move, .id = id, .occurrence = first.occurrences[0].id, .at = "2026-10-26T09:01:00Z", .revision = try TestStore.revisionFn(&store) }));
    const cancelled = try execute(store.backend(), .{ .action = .cancel, .id = id, .revision = try TestStore.revisionFn(&store) });
    try std.testing.expectEqual(scheduling.State.completed, cancelled.occurrences[0].outcome.?);
    try std.testing.expectEqual(@FieldType(series.Series, "state").cancelled, cancelled.series[0].state);
}

test "recurring recovery rejects a reservation with substituted native identities" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TestStore.init(arena.allocator(), anchor);
    const id = (try store.create(1)).series[0].id;
    store.fail = "series_after_reservation";
    try std.testing.expectError(error.InjectedFossilFault, materialize(store.backend()));
    store.fail = null;
    const result = try execute(store.backend(), .{ .action = .show, .id = id });
    var occurrence = result.occurrences[0];
    occurrence.session = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try TestStore.commitFn(&store, &.{.{ .path = try occurrencePath(store.backend(), id, occurrence.id, occurrence.at_ms), .content = try encode(store.backend(), occurrence) }});
    try std.testing.expectError(error.InvalidScheduleOccurrence, materialize(store.backend()));
    try std.testing.expectEqual(@as(usize, 0), store.tasks.count());
    try std.testing.expectEqual(@as(usize, 0), store.sessions.count());
}
