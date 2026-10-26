//! Durable implementation descriptions and disposable host liveness. Neither
//! registration nor its cache grants actor authority over company state.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const io = @import("../shared/io.zig");
const jobs = @import("company_worker_jobs.zig");

pub const prefix = "company/runtimes/";
pub const Subject = struct { actor: []const u8, grant: []const u8 };
pub const Registration = struct {
    version: []const u8 = "omos.company-runtime-registration/v1",
    id: []const u8,
    workspace: []const u8,
    package_sha256: []const u8,
    model_handle: []const u8,
    isolation: []const u8 = "omos.linux-worker/v1",
    subjects: []const Subject,
    validation_handles: []const []const u8 = &.{},
};
pub const Request = struct {
    version: []const u8,
    change: enum { inspect, register, heartbeat, stop },
    id: ?[]const u8 = null,
    registration: ?Registration = null,
    revision: ?[]const u8 = null,
    registration_sha256: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    offset: usize = 0,
};

/// Rebuilt by authenticated coordinator heartbeats after every gateway restart.
/// Accepted state, implementation descriptions and jobs remain in Fossil.
pub const LiveHosts = struct {
    const Entry = struct { id: [64]u8 = @splat(0), digest: [64]u8 = @splat(0), instance: [64]u8 = @splat(0), expires_ms: i64 = 0, stopped: bool = false };
    mutex: std.Io.Mutex = .init,
    entries: [64]Entry = @splat(.{}),

    pub fn renew(self: *LiveHosts, id: []const u8, digest: []const u8, instance: []const u8, now: i64) !void {
        _ = try authority.hexBytes(32, id);
        _ = try authority.hexBytes(32, digest);
        _ = try authority.hexBytes(32, instance);
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        var free_entry: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (std.mem.eql(u8, &entry.id, id)) {
                if (entry.stopped and std.mem.eql(u8, &entry.instance, instance)) return error.CompanyRuntimeFenced;
                if (!entry.stopped and entry.expires_ms > now and !std.mem.eql(u8, &entry.instance, instance)) return error.CompanyRuntimeBusy;
                free_entry = entry;
                break;
            }
            if (free_entry == null and entry.expires_ms <= now) free_entry = entry;
        }
        const selected = free_entry orelse return error.CompanyRuntimeCapacity;
        @memcpy(&selected.id, id);
        @memcpy(&selected.digest, digest);
        @memcpy(&selected.instance, instance);
        selected.expires_ms = now + 60000;
        selected.stopped = false;
    }

    pub fn contains(self: *LiveHosts, id: []const u8, digest: []const u8, now: i64) bool {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        for (self.entries) |entry| if (!entry.stopped and entry.expires_ms > now and std.mem.eql(u8, &entry.id, id) and std.mem.eql(u8, &entry.digest, digest)) return true;
        return false;
    }

    pub fn stop(self: *LiveHosts, id: []const u8, instance: []const u8, now: i64) !void {
        self.mutex.lockUncancelable(io.getIo());
        defer self.mutex.unlock(io.getIo());
        for (&self.entries) |*entry| if (std.mem.eql(u8, &entry.id, id)) {
            if (!std.mem.eql(u8, &entry.instance, instance)) return error.CompanyRuntimeFenced;
            // Keep the stopped nonce through an in-flight request window, so
            // a heartbeat whose acknowledgement was lost cannot resurrect it.
            entry.stopped = true;
            entry.expires_ms = @max(entry.expires_ms, now + 60000);
            return;
        };
    }
};

fn json(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

pub fn path(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    _ = try authority.hexBytes(32, id);
    return alloc.print("{s}{s}.json", .{ prefix, id });
}

fn handle(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.' and byte != ':' and byte != '/') return false;
    return true;
}

pub fn validate(registration: Registration, filename: []const u8, alloc: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, registration.version, "omos.company-runtime-registration/v1") or !std.mem.eql(u8, registration.isolation, "omos.linux-worker/v1") or !std.mem.eql(u8, filename, try path(alloc, registration.id)) or !handle(registration.model_handle) or registration.subjects.len == 0 or registration.subjects.len > 32 or registration.validation_handles.len > 16) return error.InvalidCompanyRuntime;
    _ = try authority.hexBytes(32, registration.workspace);
    _ = try authority.hexBytes(32, registration.package_sha256);
    for (registration.subjects, 0..) |subject, index| {
        if (!authority.safeIdentity(subject.actor) or !authority.safeIdentity(subject.grant)) return error.InvalidCompanyRuntime;
        for (registration.subjects[0..index]) |prior| if (std.mem.eql(u8, prior.actor, subject.actor) and std.mem.eql(u8, prior.grant, subject.grant)) return error.InvalidCompanyRuntime;
    }
    for (registration.validation_handles, 0..) |value, index| {
        if (!handle(value)) return error.InvalidCompanyRuntime;
        for (registration.validation_handles[0..index]) |prior| if (std.mem.eql(u8, value, prior)) return error.InvalidCompanyRuntime;
    }
}

fn load(manager: workspace.Manager, id: []const u8) !Registration {
    const filename = try path(manager.alloc, id);
    const selected = try records.decode(Registration, manager.alloc, try manager.companyContent(filename), .{});
    try validate(selected, filename, manager.alloc);
    if (!std.mem.eql(u8, selected.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    return selected;
}

pub fn administer(manager: workspace.Manager, request: Request) ![]const u8 {
    if (!manager.company_operation_held) return error.CompanyOperationLeaseRequired;
    if (!std.mem.eql(u8, request.version, "omos.company-runtime/v1")) return error.UnsupportedCompanyApi;
    const current = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    if (request.change == .inspect) {
        if (request.registration != null or request.revision != null or request.registration_sha256 != null or request.instance != null or request.offset > 64) return error.InvalidCompanyRuntime;
        var rows: std.ArrayList(std.json.Value) = .empty;
        var count: usize = 0;
        for (try manager.inventory(current)) |filename| {
            if (!std.mem.startsWith(u8, filename, prefix)) continue;
            const selected = try records.decode(Registration, manager.alloc, try manager.contentAt(filename, current), .{});
            try validate(selected, filename, manager.alloc);
            if (request.id) |id| if (!std.mem.eql(u8, id, selected.id)) continue;
            if (count >= request.offset and rows.items.len < 32) {
                const digest = try workspace.hash(manager.alloc, try json(manager.alloc, selected));
                const live = if (manager.company_runtime_live) |cache| cache.contains(selected.id, digest, io.milliTimestamp()) else false;
                try rows.append(manager.alloc, try std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, try json(manager.alloc, .{ .registration = selected, .sha256 = digest, .live = live }), .{}));
            }
            count += 1;
        }
        return json(manager.alloc, .{ .revision = current, .runtimes = rows.items, .total = count, .next_offset = if (request.offset + rows.items.len < count) @as(?usize, request.offset + rows.items.len) else null });
    }
    if (request.offset != 0) return error.InvalidCompanyRuntime;
    const id = request.id orelse return error.InvalidCompanyRuntime;
    if (request.change == .register) {
        if (request.registration_sha256 != null or request.instance != null or request.revision == null or !std.mem.eql(u8, request.revision.?, current)) return error.WorkspaceRevisionChanged;
        const selected = request.registration orelse return error.InvalidCompanyRuntime;
        const filename = try path(manager.alloc, id);
        try validate(selected, filename, manager.alloc);
        if (!std.mem.eql(u8, selected.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
        var count: usize = 0;
        var exists = false;
        for (try manager.inventory(current)) |entry| if (std.mem.startsWith(u8, entry, prefix)) {
            count += 1;
            exists = exists or std.mem.eql(u8, entry, filename);
        };
        if (!exists and count >= 64) return error.CompanyRuntimeCapacity;
        const raw = try json(manager.alloc, selected);
        const committed = try manager.companyWrite(current, &.{.{ .path = filename, .content = raw }});
        return json(manager.alloc, .{ .revision = committed, .id = id, .sha256 = try workspace.hash(manager.alloc, raw), .registered = true });
    }
    if (request.registration != null or request.revision != null) return error.InvalidCompanyRuntime;
    const selected = try load(manager, id);
    const digest = try workspace.hash(manager.alloc, try json(manager.alloc, selected));
    if (!std.mem.eql(u8, request.registration_sha256 orelse return error.InvalidCompanyRuntime, digest)) return error.CompanyRuntimeChanged;
    const instance = request.instance orelse return error.InvalidCompanyRuntime;
    _ = try authority.hexBytes(32, instance);
    const live = manager.company_runtime_live orelse return error.CompanyRuntimeServiceRequired;
    if (request.change == .heartbeat) try live.renew(id, digest, instance, io.milliTimestamp()) else try live.stop(id, instance, io.milliTimestamp());
    return json(manager.alloc, .{ .revision = current, .id = id, .sha256 = digest, .live = live.contains(id, digest, io.milliTimestamp()) });
}

pub fn available(manager: workspace.Manager, grant: ?authority.Grant, validation_handle: ?[]const u8) !bool {
    const live = manager.company_runtime_live orelse return false;
    const revision = (try manager.companyRevision()) orelse return false;
    const declaration = try manager.loadDeclaration(((try manager.modelBasis("trunk")) orelse return false).revision);
    if (!model.hasOperation(declaration, "omos_company_runtime_admin")) return false;
    for (try manager.inventory(revision)) |filename| {
        if (!std.mem.startsWith(u8, filename, prefix)) continue;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        var reader = manager;
        reader.alloc = scratch.allocator();
        const selected = try records.decode(Registration, reader.alloc, try reader.contentAt(filename, revision), .{});
        try validate(selected, filename, reader.alloc);
        if (!std.mem.eql(u8, selected.workspace, manager.manifest.id) or !live.contains(selected.id, try workspace.hash(reader.alloc, try json(reader.alloc, selected)), io.milliTimestamp())) continue;
        if (grant) |actor| {
            const allowed = for (selected.subjects) |subject| {
                if (std.mem.eql(u8, subject.actor, actor.actor) and std.mem.eql(u8, subject.grant, actor.id)) break true;
            } else false;
            if (!allowed) continue;
        }
        if (validation_handle) |required| {
            const supported = for (selected.validation_handles) |candidate| {
                if (std.mem.eql(u8, candidate, required)) break true;
            } else false;
            if (!supported) continue;
        }
        return true;
    }
    return false;
}

/// Only the owning signed view service uses this projection. The operator API
/// retains its separate, complete job inspection and mutation contract.
pub fn taskJob(manager: workspace.Manager, view: []const u8) !?jobs.Record {
    const filename = try jobs.path(manager.alloc, try workspace.hash(manager.alloc, view));
    const revision = (try manager.companyRevision()) orelse return error.CompanyNotInitialized;
    for (try manager.inventory(revision)) |entry| if (std.mem.eql(u8, entry, filename)) {
        const record = try records.decode(jobs.Record, manager.alloc, try manager.contentAt(filename, revision), .{});
        try jobs.validateStored(manager.alloc, record, filename);
        if (!std.mem.eql(u8, record.binding.view, view)) return error.WorkspaceIdentityMismatch;
        return record;
    };
    return null;
}

pub fn validationHandle(task: workspace.Task) ?[]const u8 {
    const basis = task.model_basis orelse return null;
    if (!std.mem.eql(u8, basis.capability orelse return null, "coding_task")) return null;
    return basis.execution.validationHandle();
}

pub fn taskStatus(manager: workspace.Manager, grant: authority.Grant, task: workspace.Task, view: []const u8) ![]const u8 {
    const record = try taskJob(manager, view);
    return json(manager.alloc, .{ .available = authority.permitsAction(grant, .execute_task) and try available(manager, grant, validationHandle(task)), .job = if (record) |job| .{ .id = job.id, .state = @tagName(job.state), .invocations = job.invocations, .max_invocations = job.max_invocations, .max_runtime_ms = job.max_runtime_ms, .note = job.note } else null });
}

/// Queueing spends no actor step and invokes no model. Explicit compute
/// authority is checked by signed request authentication before this call.
pub fn requestTask(manager: workspace.Manager, grant: authority.Grant, task: workspace.Task, view: []const u8, operation: []const u8, revision: ?[]const u8) ![]const u8 {
    const previous = try taskJob(manager, view);
    if (previous) |record| {
        // Replay after a committed queue acknowledgement was lost, including
        // when the worker has already advanced the view's source revision.
        const filename = try manager.alloc.print("company/workers/operations/{s}/{s}.json", .{ record.id, try workspace.hash(manager.alloc, operation) });
        for (try manager.inventory((try manager.companyRevision()) orelse return error.CompanyNotInitialized)) |entry| if (std.mem.eql(u8, entry, filename)) return taskStatus(manager, grant, task, view);
    }
    if (revision == null or !std.mem.eql(u8, revision.?, try manager.currentRevision(task))) return error.WorkspaceRevisionChanged;
    if (previous) |record| switch (record.state) {
        .queued, .running, .completed => return taskStatus(manager, grant, task, view),
        .submitted => if (task.review_job) |id| {
            const review = try manager.loadReviewJob(task, id);
            if (review.state == .queued or review.state == .running) return taskStatus(manager, grant, task, view);
        },
        .cancelled => return error.CompanyWorkerCancelled,
        else => {},
    };
    if (!try available(manager, grant, validationHandle(task))) return error.CompanyImplementationUnavailable;
    const request: jobs.Request = .{ .change = if (previous == null) .queue else .requeue, .view = view, .operation = operation, .expected_sha256 = if (previous) |record| try workspace.hash(manager.alloc, try manager.companyContent(try jobs.path(manager.alloc, record.id))) else null };
    _ = try jobs.administer(manager, request);
    return taskStatus(manager, grant, task, view);
}

test "company runtime liveness is disposable, bounded, and fenced by process instance and registration" {
    var cache: LiveHosts = .{};
    const id: [64]u8 = @splat('a');
    const digest: [64]u8 = @splat('b');
    const first: [64]u8 = @splat('c');
    const second: [64]u8 = @splat('d');
    try cache.renew(&id, &digest, &first, 100);
    try std.testing.expect(cache.contains(&id, &digest, 101));
    try std.testing.expect(!cache.contains(&id, &first, 101));
    try std.testing.expectError(error.CompanyRuntimeBusy, cache.renew(&id, &digest, &second, 200));
    try std.testing.expectError(error.CompanyRuntimeFenced, cache.stop(&id, &second, 200));
    try std.testing.expect(!cache.contains(&id, &digest, 60100));
    try cache.renew(&id, &digest, &second, 60100);
    try std.testing.expectError(error.CompanyRuntimeFenced, cache.stop(&id, &first, 60100));
    try cache.stop(&id, &second, 60100);
    try std.testing.expect(!cache.contains(&id, &digest, 60101));
    try std.testing.expectError(error.CompanyRuntimeFenced, cache.renew(&id, &digest, &second, 60102));
    try cache.renew(&id, &digest, &first, 60103);
    try std.testing.expect(cache.contains(&id, &digest, 60104));
    try std.testing.expectError(error.CompanyRuntimeBusy, cache.renew(&id, &digest, &second, 60105));
}
