//! Local operator decisions over immutable proposal inputs. Approval never
//! substitutes for independent assessment or authorizes a different candidate.
const std = @import("std");
const workspace = @import("fossil_workspace.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const model = @import("definition.zig");
const keys = @import("company_keys.zig");
const io = @import("../shared/io.zig");

pub const Candidate = struct {
    workspace: []const u8,
    task: []const u8,
    actor: []const u8,
    grant: []const u8,
    epoch: u64,
    base_revision: []const u8,
    proposal_revision: []const u8,
    integration_revision: []const u8,
    proposal_operation: []const u8,
    contract_sha256: []const u8,
    definition_sha256: []const u8,
    candidate_sha256: []const u8,
    changes_sha256: []const u8,
    reads_sha256: ?[]const u8 = null,
};
pub const Decision = struct {
    version: []const u8 = "omos.company-approval/v1",
    candidate: Candidate,
    approved: bool,
    operator: []const u8 = "local-operator",
    decided_ms: i64,
    expires_ms: i64,
};
pub const Record = struct { version: []const u8 = "omos.company-approval-record/v1", task: []const u8, payload: []const u8, signature: []const u8, issuer: []const u8 };

fn encode(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

pub fn path(alloc: std.mem.Allocator, task: []const u8) ![]const u8 {
    if (!authority.safeIdentity(task)) return error.InvalidCompanyIdentity;
    return alloc.print("company/approvals/{s}.json", .{task});
}

fn changesHash(manager: workspace.Manager, task: workspace.Task, revision: []const u8) ![]const u8 {
    const paths = try manager.alloc.dupe([]const u8, try manager.changedPaths(task.base_revision, revision));
    std.mem.sort([]const u8, paths, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    const inventory = try manager.inventory(revision);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths) |changed| {
        if (!authority.validPath(changed, false)) continue;
        if (task.request_artifact) |request| if (std.mem.eql(u8, request, changed)) continue;
        var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer scratch.deinit();
        var scoped = manager;
        scoped.alloc = scratch.allocator();
        const exists = for (inventory) |entry| {
            if (std.mem.eql(u8, entry, changed)) break true;
        } else false;
        const digest = if (exists) try workspace.hash(scoped.alloc, try scoped.contentAt(changed, revision)) else null;
        hasher.update(try encode(scoped.alloc, .{ .path = changed, .sha256 = digest }));
        hasher.update("\n");
    }
    const digest = hasher.finalResult();
    return manager.alloc.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// Load the host-retained proposal while preserving its original operation and
/// candidate revision across subsequent integration receipts.
pub fn retainedProposal(manager: workspace.Manager, task: workspace.Task, revision: []const u8) !std.json.Value {
    const binding = task.authority orelse return error.CompanyAccessDenied;
    var proposal: std.ArrayList(u8) = .empty;
    defer proposal.deinit(std.heap.page_allocator);
    var proposal_at: i64 = -1;
    var cursor = try manager.historyCursor(task, revision);
    while (cursor.offset < cursor.paths.len) {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const batch = (try cursor.next(a)) orelse break;
        for (batch) |bytes| {
            const row = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
            if (!std.mem.eql(u8, model.text(row, "kind"), "company_proposal")) continue;
            const value = model.field(row, "value") orelse continue;
            if (!std.mem.eql(u8, model.text(value, "actor"), binding.actor) or !std.mem.eql(u8, model.text(value, "grant"), binding.grant)) continue;
            const at = model.field(row, "recorded_at_ms") orelse continue;
            if (at != .integer or at.integer < proposal_at) continue;
            proposal.clearRetainingCapacity();
            try proposal.appendSlice(std.heap.page_allocator, try encode(a, value));
            proposal_at = at.integer;
        }
    }
    if (proposal_at < 0) return error.CompanyProposalRequired;
    return std.json.parseFromSliceLeaky(std.json.Value, manager.alloc, proposal.items, .{ .allocate = .alloc_always });
}

pub fn candidate(manager: workspace.Manager, task: workspace.Task, revision: []const u8, current: authority.State) !Candidate {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const answer = (try manager.retainedReviewCandidateAt(task, revision)) orelse return error.NoRetainedReviewCandidate;
    const value = try retainedProposal(manager, task, revision);
    const integration = model.text(value, "integration_revision");
    if (integration.len == 0) return error.CompanyProposalResubmissionRequired;
    if (!try manager.revisionDescendsFrom(revision, integration)) return error.CompanyApprovalStale;
    const changes = try changesHash(manager, task, revision);
    // Compare the original proposal against its own recorded base. A crash
    // can occur after refresh commits a new base but before the integration
    // reference is checkpointed; the immutable proposal remains inspectable.
    const original = try records.decode(workspace.Task, manager.alloc, try manager.contentAt(try manager.alloc.print("tasks/{s}.json", .{task.id}), integration), .{});
    if (!std.mem.eql(u8, original.id, task.id) or !std.mem.eql(u8, original.workspace_id, task.workspace_id)) return error.CompanyApprovalStale;
    if (!std.mem.eql(u8, changes, try changesHash(manager, original, integration))) return error.CompanyApprovalStale;
    return .{
        .workspace = manager.manifest.id,
        .task = task.id,
        .actor = binding.actor,
        .grant = binding.grant,
        .epoch = current.epoch,
        .base_revision = task.base_revision,
        .proposal_revision = model.text(value, "candidate_revision"),
        .integration_revision = integration,
        .proposal_operation = model.text(value, "operation"),
        .contract_sha256 = try workspace.hash(manager.alloc, try encode(manager.alloc, task.definition)),
        .definition_sha256 = try workspace.hash(manager.alloc, try encode(manager.alloc, task.model_basis)),
        .candidate_sha256 = try workspace.hash(manager.alloc, answer),
        .changes_sha256 = changes,
        .reads_sha256 = if (task.company_reads.len == 0) null else try workspace.hash(manager.alloc, try encode(manager.alloc, task.company_reads)),
    };
}

pub fn decide(manager: workspace.Manager, task: workspace.Task, current: authority.State, expected: []const u8, approved: bool, expires_ms: i64) !Record {
    const binding = task.authority orelse return error.CompanyAccessDenied;
    const grant = try authority.liveGrant(current, binding.grant, io.milliTimestamp());
    if (!std.mem.eql(u8, grant.actor, binding.actor)) return error.CompanyAccessDenied;
    if (!grant.human_approval or !authority.permitsAction(grant, .submit)) return error.CompanyApprovalNotRequired;
    if (task.state == .accepted or task.state == .publication_pending) return error.TaskIsReadOnly;
    if (!try manager.sameRevision(task.base_revision, try manager.revision(task.parent))) return error.CompanyReconciliationRequired;
    const inputs = try candidate(manager, task, try manager.currentRevision(task), current);
    if (!std.mem.eql(u8, expected, try workspace.hash(manager.alloc, try encode(manager.alloc, inputs)))) return error.CompanyApprovalStale;
    const now = io.milliTimestamp();
    if (expires_ms <= now or expires_ms > grant.expires_ms or expires_ms - now > 24 * 60 * 60 * 1000) return error.InvalidCompanyApprovalExpiry;
    const decision: Decision = .{ .candidate = inputs, .approved = approved, .decided_ms = now, .expires_ms = expires_ms };
    const payload = try encode(manager.alloc, decision);
    const key = try keys.current(manager, current.epoch, current.issuer);
    const signature = try key.sign(payload, null);
    return .{ .task = task.id, .payload = payload, .signature = try manager.alloc.dupe(u8, &std.fmt.bytesToHex(signature.toBytes(), .lower)), .issuer = current.issuer };
}

/// `control` and `now` can be the retained authority revision and publication
/// time during offline verification; live publication supplies current values.
pub fn authorize(manager: workspace.Manager, task: workspace.Task, revision: []const u8, control: []const u8, current: authority.State, now: i64) ![]const u8 {
    if (comptime @import("builtin").target.cpu.arch.isWasm()) return error.UnsupportedPlatform;
    const raw = manager.contentAt(try path(manager.alloc, task.id), control) catch |err| switch (err) {
        error.FossilCommandFailed => return error.CompanyApprovalRequired,
        else => return err,
    };
    const retained = try records.decode(Record, manager.alloc, raw, .{});
    if (!std.mem.eql(u8, retained.version, "omos.company-approval-record/v1") or !std.mem.eql(u8, retained.task, task.id) or !std.mem.eql(u8, retained.issuer, current.issuer)) return error.CompanyApprovalStale;
    const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try authority.hexBytes(32, retained.issuer));
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(try authority.hexBytes(64, retained.signature));
    signature.verifyStrict(retained.payload, public) catch return error.CompanySignatureRejected;
    const decision = try records.decode(Decision, manager.alloc, retained.payload, .{});
    if (!std.mem.eql(u8, decision.version, "omos.company-approval/v1") or !std.mem.eql(u8, decision.operator, "local-operator")) return error.InvalidCompanyApproval;
    if (!decision.approved) return error.CompanyApprovalDenied;
    if (decision.decided_ms > now or decision.expires_ms <= now) return error.CompanyApprovalExpired;
    const inputs = try candidate(manager, task, revision, current);
    if (!std.mem.eql(u8, try encode(manager.alloc, inputs), try encode(manager.alloc, decision.candidate))) return error.CompanyApprovalStale;
    return workspace.hash(manager.alloc, raw);
}
