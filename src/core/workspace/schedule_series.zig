//! Recurrence rules and portable series identities. Only materialized one-time
//! schedules can execute; calendar projections never grant execution authority.
const std = @import("std");
const scheduling = @import("scheduling.zig");

pub const api_version = "omos.schedule-series/v1";
pub const day_ms: i64 = 86_400_000;
pub const max_ms: i64 = 253_402_300_799_999;
pub const Rule = struct {
    cadence: enum { interval, daily, weekly, monthly },
    every: u32 = 1,
    interval_ms: ?i64 = null,
    weekdays_mask: u8 = 0,
    month_day: ?u8 = null,
    offset_minutes: i16 = 0,
};
pub const Event = struct {
    sequence: u64 = 0,
    at_ms: i64,
    kind: []const u8,
    reason: []const u8 = "",
    from_ms: ?i64 = null,
    to_ms: ?i64 = null,
    slots: u64 = 0,
};
pub const Series = struct {
    id: []const u8,
    template_task: []const u8,
    template_revision: []const u8,
    template_sha256: []const u8,
    rule_version: u32 = 1,
    rule: Rule,
    anchor_ms: i64,
    next_ms: ?i64,
    state: enum { active, paused, cancelled, completed } = .active,
    overlap: enum { block, skip } = .block,
    until_ms: ?i64 = null,
    max_occurrences: ?u32 = null,
    materialized_count: u32 = 0,
    event_sequence: u64 = 0,
    active_occurrence: ?struct { id: []const u8, nominal_ms: i64, at_ms: i64 } = null,
    last_materialized_ms: ?i64 = null,
    reason: []const u8 = "",
};
pub const Occurrence = struct {
    id: []const u8,
    series: []const u8,
    rule_version: u32,
    nominal_ms: i64,
    at_ms: i64,
    task: []const u8,
    session: []const u8,
    schedule: []const u8,
    base_revision: []const u8,
    contract_version: u32 = 1,
    preparation: enum { reserved, prepared, paused, skipped } = .reserved,
    outcome: ?scheduling.State = null,
    started_ms: ?i64 = null,
    finished_ms: ?i64 = null,
    schedule_history: []const scheduling.Event = &.{},
    reason: []const u8 = "",
};
pub const Store = struct { version: []const u8 = api_version, workspace: []const u8, series: []const Series = &.{} };
pub const Projection = struct { series: []const u8, rule_version: u32, at_ms: i64 };
pub const Snapshot = struct {
    version: []const u8 = api_version,
    workspace: []const u8,
    revision: []const u8,
    series: []const Series,
    occurrences: []const Occurrence,
    projected: []const Projection = &.{},
    events: []const Event = &.{},
    next_cursor: ?usize = null,
    next_event_cursor: ?usize = null,
    truncated: bool = false,
};
pub const Request = struct {
    version: []const u8 = api_version,
    action: enum { list, show, add, update, pause, @"resume", skip, move, cancel } = .list,
    id: ?[]const u8 = null,
    task: ?[]const u8 = null,
    occurrence: ?[]const u8 = null,
    at: ?[]const u8 = null,
    rule: ?Rule = null,
    overlap: ?@FieldType(Series, "overlap") = null,
    until: ?[]const u8 = null,
    clear_until: bool = false,
    max_occurrences: ?u32 = null,
    clear_count: bool = false,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    cursor: usize = 0,
    events_cursor: usize = 0,
    limit: usize = 50,
    revision: ?[]const u8 = null,
};
pub const Options = struct { request: Request = .{}, json: bool = false };

pub fn parseArgs(args: []const [:0]const u8) !Options {
    var result: Options = .{};
    var index: usize = 0;
    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) {
        result.request.action = if (std.mem.eql(u8, args[0], "create")) .add else std.meta.stringToEnum(@FieldType(Request, "action"), args[0]) orelse return error.InvalidScheduleSeriesAction;
        index += 1;
    }
    if (result.request.action != .list) {
        if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.ScheduleSeriesIdRequired;
        if (result.request.action == .add) result.request.task = args[index] else result.request.id = args[index];
        index += 1;
    }
    var every: ?[]const u8 = null;
    var frequency: ?u32 = null;
    var weekdays: ?[]const u8 = null;
    var month_day: ?u8 = null;
    // Arguments are bounded by the command parser. This small stack tracks
    // duplicate options without allocating through a process-global allocator.
    var option_names: [20][]const u8 = undefined;
    var seen_count: usize = 0;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        for (option_names[0..seen_count]) |name| if (std.mem.eql(u8, name, flag)) return error.InvalidSeriesOption;
        if (seen_count == option_names.len) return error.InvalidSeriesOption;
        option_names[seen_count] = flag;
        seen_count += 1;
        if (std.mem.eql(u8, flag, "--json")) {
            result.json = true;
            continue;
        }
        if (std.mem.eql(u8, flag, "--clear-until")) {
            result.request.clear_until = true;
            continue;
        }
        if (std.mem.eql(u8, flag, "--clear-count")) {
            result.request.clear_count = true;
            continue;
        }
        if (index + 1 == args.len) return error.MissingSeriesOptionValue;
        index += 1;
        const value = args[index];
        if (std.mem.eql(u8, flag, "--at")) result.request.at = value else if (std.mem.eql(u8, flag, "--every")) every = value else if (std.mem.eql(u8, flag, "--frequency")) frequency = std.fmt.parseInt(u32, value, 10) catch return error.InvalidRecurrenceRule else if (std.mem.eql(u8, flag, "--weekdays")) weekdays = value else if (std.mem.eql(u8, flag, "--month-day")) month_day = std.fmt.parseInt(u8, value, 10) catch return error.InvalidRecurrenceRule else if (std.mem.eql(u8, flag, "--count")) result.request.max_occurrences = std.fmt.parseInt(u32, value, 10) catch return error.InvalidSeriesCount else if (std.mem.eql(u8, flag, "--until")) result.request.until = value else if (std.mem.eql(u8, flag, "--overlap")) result.request.overlap = std.meta.stringToEnum(@FieldType(Series, "overlap"), value) orelse return error.InvalidSeriesOverlap else if (std.mem.eql(u8, flag, "--revision")) result.request.revision = value else if (std.mem.eql(u8, flag, "--occurrence")) result.request.occurrence = value else if (std.mem.eql(u8, flag, "--from")) result.request.from = value else if (std.mem.eql(u8, flag, "--to")) result.request.to = value else if (std.mem.eql(u8, flag, "--cursor")) result.request.cursor = std.fmt.parseInt(usize, value, 10) catch return error.InvalidSeriesPage else if (std.mem.eql(u8, flag, "--events-cursor")) result.request.events_cursor = std.fmt.parseInt(usize, value, 10) catch return error.InvalidSeriesPage else if (std.mem.eql(u8, flag, "--limit")) result.request.limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidSeriesPage else return error.InvalidSeriesOption;
    }
    if (every) |raw| {
        const at = result.request.at orelse return error.ScheduleTimeRequired;
        const anchor = try scheduling.parseTimestamp(at);
        var rule: Rule = .{ .cadence = .interval, .offset_minutes = try offsetMinutes(at) };
        if (std.meta.stringToEnum(@FieldType(Rule, "cadence"), raw)) |cadence| {
            if (cadence == .interval) return error.InvalidRecurrenceRule;
            rule.cadence = cadence;
            rule.every = frequency orelse 1;
        } else {
            if (raw.len < 2 or frequency != null) return error.InvalidRecurrenceRule;
            const count = std.fmt.parseInt(u64, raw[0 .. raw.len - 1], 10) catch return error.InvalidRecurrenceRule;
            const unit: u64 = switch (raw[raw.len - 1]) {
                'm' => 60_000,
                'h' => 3_600_000,
                'd' => day_ms,
                'w' => day_ms * 7,
                else => return error.InvalidRecurrenceRule,
            };
            const duration = @mulWithOverflow(count, unit);
            if (duration[1] != 0 or duration[0] > max_ms) return error.InvalidRecurrenceRule;
            rule.interval_ms = @intCast(duration[0]);
        }
        if (rule.cadence == .weekly) {
            rule.weekdays_mask = if (weekdays) |tokens| try weekdayMask(tokens) else @as(u8, 1) << @as(u3, @intCast(weekday(@divFloor(anchor + @as(i64, rule.offset_minutes) * 60_000, day_ms))));
        } else if (weekdays != null) return error.InvalidRecurrenceRule;
        if (rule.cadence == .monthly) rule.month_day = month_day orelse @intCast(civil(@divFloor(anchor + @as(i64, rule.offset_minutes) * 60_000, day_ms)).day) else if (month_day != null) return error.InvalidRecurrenceRule;
        result.request.rule = rule;
    } else if (frequency != null or weekdays != null or month_day != null) return error.InvalidRecurrenceRule;
    var checked = result.request;
    // The owner CLI reads the current revision when no explicit fence was
    // supplied. Native and HTTP mutations always supply their read revision.
    if (mutation(checked) and checked.revision == null) checked.revision = "";
    try validateRequest(checked);
    return result;
}

fn weekdayMask(raw: []const u8) !u8 {
    var mask: u8 = 0;
    var tokens = std.mem.splitScalar(u8, raw, ',');
    while (tokens.next()) |token| {
        const day = for ([_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" }, 0..) |name, index| {
            if (std.mem.eql(u8, token, name)) break index;
        } else return error.InvalidRecurrenceRule;
        const bit = @as(u8, 1) << @as(u3, @intCast(day));
        if (mask & bit != 0) return error.InvalidRecurrenceRule;
        mask |= bit;
    }
    return mask;
}

fn offsetMinutes(raw: []const u8) !i16 {
    _ = try scheduling.parseTimestamp(raw);
    if (std.mem.endsWith(u8, raw, "Z")) return 0;
    const suffix = raw[raw.len - 6 ..];
    const hours = try std.fmt.parseInt(i16, suffix[1..3], 10);
    const minutes = try std.fmt.parseInt(i16, suffix[4..6], 10);
    return (hours * 60 + minutes) * @as(i16, if (suffix[0] == '-') -1 else 1);
}

pub fn mutation(request: Request) bool {
    return request.action != .list and request.action != .show;
}

pub fn validateRequest(request: Request) !void {
    if (!std.mem.eql(u8, request.version, api_version)) return error.UnsupportedScheduleSeriesApi;
    if (request.limit == 0 or request.limit > 2000) return error.InvalidSeriesPage;
    if (request.cursor > std.math.maxInt(usize) - request.limit or request.events_cursor > std.math.maxInt(usize) - request.limit) return error.InvalidSeriesPage;
    if (request.action == .add) {
        if (request.task == null or request.id != null or request.rule == null or request.at == null) return error.SeriesTemplateAndRuleRequired;
        if (request.clear_count or request.clear_until) return error.InvalidSeriesOption;
    } else if (request.task != null) return error.InvalidSeriesOption;
    if (request.action != .add and request.action != .list and request.id == null) return error.ScheduleSeriesIdRequired;
    if (request.action == .list and request.id != null) return error.InvalidSeriesOption;
    if (mutation(request) and request.revision == null) return error.WorkspaceRevisionRequired;
    if (request.action == .add or request.action == .update) {
        if (request.at) |at| {
            const anchor = try scheduling.parseTimestamp(at);
            if (request.rule) |rule| try validateRule(rule, anchor);
        }
    } else {
        if (request.rule != null or request.overlap != null or request.until != null or request.max_occurrences != null or request.clear_until or request.clear_count) return error.InvalidSeriesOption;
        if (request.at != null and request.action != .move) return error.InvalidSeriesOption;
    }
    if (request.action == .move and (request.at == null or request.occurrence == null)) return error.SeriesOccurrenceAndTimeRequired;
    if (request.occurrence != null and request.action != .move and request.action != .skip) return error.InvalidSeriesOption;
    if (request.max_occurrences) |count| if (count == 0 or count > 10_000 or request.clear_count) return error.InvalidSeriesCount;
    if (request.until != null and request.clear_until) return error.InvalidSeriesOption;
    if (request.until) |until| _ = try scheduling.parseTimestamp(until);
    if (request.at) |at| _ = try scheduling.parseTimestamp(at);
    if ((request.from == null) != (request.to == null)) return error.InvalidSeriesRange;
    if (request.from) |raw| {
        if (mutation(request)) return error.InvalidSeriesOption;
        const from = try scheduling.parseTimestamp(raw);
        const to = try scheduling.parseTimestamp(request.to.?);
        if (to <= from or to - from > 366 * day_ms) return error.InvalidSeriesRange;
    }
}

pub fn validateRule(rule: Rule, anchor: i64) !void {
    if (anchor < 0 or anchor > max_ms or rule.every == 0 or rule.every > 10_000 or rule.offset_minutes < -1439 or rule.offset_minutes > 1439) return error.InvalidRecurrenceRule;
    const local = anchor + @as(i64, rule.offset_minutes) * 60_000;
    if (local < 0 or local > max_ms) return error.InvalidRecurrenceAnchor;
    const days = @divFloor(local, day_ms);
    switch (rule.cadence) {
        .interval => if (rule.every != 1 or rule.interval_ms == null or rule.interval_ms.? < 60_000 or rule.interval_ms.? > max_ms or rule.weekdays_mask != 0 or rule.month_day != null) return error.InvalidRecurrenceRule,
        .daily => if (rule.interval_ms != null or rule.weekdays_mask != 0 or rule.month_day != null) return error.InvalidRecurrenceRule,
        .weekly => {
            if (rule.interval_ms != null or rule.month_day != null or rule.weekdays_mask == 0 or rule.weekdays_mask > 127) return error.InvalidRecurrenceRule;
            if (rule.weekdays_mask & (@as(u8, 1) << @as(u3, @intCast(weekday(days)))) == 0) return error.InvalidRecurrenceAnchor;
        },
        .monthly => {
            const day = rule.month_day orelse return error.InvalidRecurrenceRule;
            if (rule.interval_ms != null or rule.weekdays_mask != 0 or day == 0 or day > 31) return error.InvalidRecurrenceRule;
            const date = civil(days);
            if (date.day != @min(day, monthDays(date.year, date.month))) return error.InvalidRecurrenceAnchor;
        },
    }
}

/// Strictly future slot, anchored to the original rule. Null means its calendar
/// would fall outside the supported UTC range.
pub fn next(rule: Rule, anchor: i64, after: i64) !?i64 {
    return adjacent(rule, anchor, after, true);
}
/// Latest nominal slot at or before now. This coalesces downtime without
/// walking every missed interval.
pub fn latest(rule: Rule, anchor: i64, now: i64) !?i64 {
    return adjacent(rule, anchor, now, false);
}

fn adjacent(rule: Rule, anchor: i64, instant: i64, future: bool) !?i64 {
    try validateRule(rule, anchor);
    if (instant > max_ms) return if (future) null else adjacent(rule, anchor, max_ms, false);
    if (instant < anchor) return if (future) anchor else null;
    if (rule.cadence == .interval or rule.cadence == .daily) {
        const step = if (rule.cadence == .interval) rule.interval_ms.? else @as(i64, rule.every) * day_ms;
        const index = @divFloor(instant - anchor, step) + @as(i64, if (future) 1 else 0);
        return normalize(@as(i128, anchor) + @as(i128, index) * step);
    }
    const offset = @as(i64, rule.offset_minutes) * 60_000;
    const clock = @mod(anchor + offset, day_ms);
    const anchor_days = @divFloor(anchor + offset, day_ms);
    const target_days = @divFloor(instant + offset, day_ms);
    var chosen: ?i64 = null;
    if (rule.cadence == .weekly) {
        const monday = anchor_days - weekday(anchor_days);
        const target_monday = target_days - weekday(target_days);
        const period = @divFloor(target_monday - monday, @as(i64, rule.every) * 7);
        for (0..2) |attempt| {
            const k = period + @as(i64, @intCast(attempt)) * (if (future) @as(i64, 1) else -1);
            if (k < 0) continue;
            for (0..7) |day| {
                if (rule.weekdays_mask & (@as(u8, 1) << @as(u3, @intCast(day))) == 0) continue;
                const candidate = normalize((@as(i128, monday) + @as(i128, k) * rule.every * 7 + day) * day_ms + clock - offset) orelse continue;
                select(&chosen, candidate, anchor, instant, future);
            }
        }
    } else {
        const start = civil(anchor_days);
        const target = civil(target_days);
        const start_month = start.year * 12 + start.month - 1;
        const target_month = target.year * 12 + target.month - 1;
        const period = @divFloor(target_month - start_month, rule.every);
        for (0..2) |attempt| {
            const k = period + @as(i64, @intCast(attempt)) * (if (future) @as(i64, 1) else -1);
            if (k < 0) continue;
            const month_index = start_month + k * rule.every;
            const year = @divFloor(month_index, 12);
            const month = @mod(month_index, 12) + 1;
            if (year < 1970 or year > 9999) continue;
            const days = dateDays(year, month, @min(rule.month_day.?, monthDays(year, month)));
            const candidate = normalize(@as(i128, days) * day_ms + clock - offset) orelse continue;
            select(&chosen, candidate, anchor, instant, future);
        }
    }
    return chosen;
}

fn select(chosen: *?i64, candidate: i64, anchor: i64, instant: i64, future: bool) void {
    if (candidate < anchor or (if (future) candidate <= instant else candidate > instant)) return;
    if (chosen.* == null or (if (future) candidate < chosen.*.? else candidate > chosen.*.?)) chosen.* = candidate;
}
fn normalize(value: i128) ?i64 {
    return if (value < 0 or value > max_ms) null else @intCast(value);
}
fn weekday(days: i64) i64 {
    return @mod(days + 3, 7);
}
fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}
fn monthDays(year: i64, month: i64) i64 {
    return ([_]i64{ 31, if (leap(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[@intCast(month - 1)];
}
fn yearDays(year: i64) i64 {
    return 365 * (year - 1970) + @divFloor(year - 1, 4) - @divFloor(1969, 4) - @divFloor(year - 1, 100) + @divFloor(1969, 100) + @divFloor(year - 1, 400) - @divFloor(1969, 400);
}
fn dateDays(year: i64, month: i64, day: i64) i64 {
    var count = yearDays(year) + day - 1;
    var m: i64 = 1;
    while (m < month) : (m += 1) count += monthDays(year, m);
    return count;
}
fn civil(days: i64) struct { year: i64, month: i64, day: i64 } {
    var low: i64 = 1969;
    var high: i64 = 10001;
    while (high - low > 1) {
        const middle = @divFloor(low + high, 2);
        if (yearDays(middle) <= days) low = middle else high = middle;
    }
    var remaining = days - yearDays(low);
    var month: i64 = 1;
    while (month < 12 and remaining >= monthDays(low, month)) : (month += 1) remaining -= monthDays(low, month);
    return .{ .year = low, .month = month, .day = remaining + 1 };
}

/// Zero-based nominal ordinal; callers pass a slot returned by next/latest.
pub fn ordinal(rule: Rule, anchor: i64, slot: i64) !u64 {
    try validateRule(rule, anchor);
    if (slot < anchor) return error.InvalidRecurrenceSlot;
    if (rule.cadence == .interval or rule.cadence == .daily) return @intCast(@divFloor(slot - anchor, if (rule.cadence == .interval) rule.interval_ms.? else @as(i64, rule.every) * day_ms));
    const offset = @as(i64, rule.offset_minutes) * 60_000;
    const start_days = @divFloor(anchor + offset, day_ms);
    const slot_days = @divFloor(slot + offset, day_ms);
    if (rule.cadence == .monthly) {
        const a = civil(start_days);
        const b = civil(slot_days);
        return @intCast(@divFloor((b.year - a.year) * 12 + b.month - a.month, rule.every));
    }
    const periods = @divFloor(slot_days - weekday(slot_days) - (start_days - weekday(start_days)), @as(i64, rule.every) * 7);
    var before: i64 = 0;
    var within: i64 = 0;
    for (0..7) |d| if (rule.weekdays_mask & (@as(u8, 1) << @as(u3, @intCast(d))) != 0) {
        if (d < weekday(start_days)) before += 1;
        if (d <= weekday(slot_days)) within += 1;
    };
    return @intCast(periods * @popCount(rule.weekdays_mask) + within - before - 1);
}

test "recurring calendar slots retain monthly anchors and fixed offsets" {
    const anchor = try scheduling.parseTimestamp("2024-01-31T09:00:00+01:00");
    const rule: Rule = .{ .cadence = .monthly, .month_day = 31, .offset_minutes = 60 };
    const feb = (try next(rule, anchor, anchor)).?;
    try std.testing.expectEqual(try scheduling.parseTimestamp("2024-02-29T09:00:00+01:00"), feb);
    try std.testing.expectEqual(try scheduling.parseTimestamp("2024-03-31T09:00:00+01:00"), (try next(rule, anchor, feb)).?);
    try std.testing.expectEqual(try scheduling.parseTimestamp("2024-03-31T09:00:00+01:00"), (try latest(rule, anchor, try scheduling.parseTimestamp("2024-04-01T00:00:00Z"))).?);
    try std.testing.expectEqual(@as(u64, 2), try ordinal(rule, anchor, (try next(rule, anchor, feb)).?));
}

test "recurring weekly multiples and offline coalescing use nominal slots" {
    const anchor = try scheduling.parseTimestamp("2026-10-26T09:00:00Z");
    const rule: Rule = .{ .cadence = .weekly, .every = 2, .weekdays_mask = 1 | 4 | 16 };
    const friday = (try latest(rule, anchor, try scheduling.parseTimestamp("2026-11-08T23:00:00Z"))).?;
    try std.testing.expectEqual(try scheduling.parseTimestamp("2026-10-30T09:00:00Z"), friday);
    try std.testing.expectEqual(try scheduling.parseTimestamp("2026-11-09T09:00:00Z"), (try next(rule, anchor, friday)).?);
    try std.testing.expectEqual(@as(u64, 2), try ordinal(rule, anchor, friday));
    const interval: Rule = .{ .cadence = .interval, .interval_ms = 60_000 };
    try std.testing.expectEqual(anchor + 4 * 60_000, (try latest(interval, anchor, anchor + 4 * 60_000 + 1)).?);
    try std.testing.expectEqual(anchor + 5 * 60_000, (try next(interval, anchor, anchor + 4 * 60_000 + 1)).?);
    try std.testing.expectEqual(@as(?i64, null), try next(interval, max_ms - 1, max_ms));
    try std.testing.expectError(error.InvalidRecurrenceRule, validateRule(.{ .cadence = .interval, .interval_ms = 59_999 }, anchor));
}

test "recurring CLI distinguishes durations from calendar rules and rejects ignored fields" {
    const duration = try parseArgs(&.{ "add", "template", "--at", "2026-10-26T09:00:00+01:00", "--every", "1d", "--count", "2", "--json" });
    try std.testing.expectEqual(@as(?i64, day_ms), duration.request.rule.?.interval_ms);
    try std.testing.expectEqual(@as(i16, 60), duration.request.rule.?.offset_minutes);
    try std.testing.expectEqual(@as(?u32, 2), duration.request.max_occurrences);
    try std.testing.expect(duration.json);
    const weekly = try parseArgs(&.{ "add", "template", "--at", "2026-10-26T09:00:00Z", "--every", "weekly", "--weekdays", "mon,wed,fri", "--frequency", "2" });
    try std.testing.expectEqual(@as(u8, 21), weekly.request.rule.?.weekdays_mask);
    try std.testing.expectEqual(@as(u32, 2), weekly.request.rule.?.every);
    try std.testing.expectError(error.InvalidRecurrenceRule, parseArgs(&.{ "add", "template", "--at", "2026-10-26T09:00:00Z", "--every", "1d", "--weekdays", "mon" }));
    try std.testing.expectError(error.InvalidRecurrenceAnchor, parseArgs(&.{ "add", "template", "--at", "2026-10-26T09:00:00Z", "--every", "weekly", "--weekdays", "tue" }));
    try std.testing.expectError(error.InvalidSeriesCount, parseArgs(&.{ "add", "template", "--at", "2026-10-26T09:00:00Z", "--every", "daily", "--count", "0" }));
    try std.testing.expectError(error.InvalidSeriesOption, parseArgs(&.{ "list", "--json", "--json" }));
    try std.testing.expectError(error.WorkspaceRevisionRequired, validateRequest(.{ .action = .pause, .id = "series" }));
}
