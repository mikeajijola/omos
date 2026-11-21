//! Portable issuer attestations over an independently reviewed publication.
//! Trust starts with the company issuer; keys are never required for verification.
const std = @import("std");
const authority = @import("company_authority.zig");
const keys = @import("company_keys.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");

pub const Claims = struct {
    version: []const u8 = "omos.company-publication/v1",
    workspace: []const u8,
    actor: []const u8,
    grant: []const u8,
    operation: []const u8,
    task: []const u8,
    source: []const u8,
    target: []const u8,
    target_base: []const u8,
    contract_sha256: []const u8,
    candidate_sha256: []const u8,
    assessment_sha256: []const u8,
    authority_revision: []const u8,
    epoch: u64,
    issued_ms: i64,
    approval_sha256: ?[]const u8 = null,
    reads_sha256: ?[]const u8 = null,
    promotion_sha256: ?[]const u8 = null,

    // Preserve exact byte hashes of historical non-promotion claims while
    // binding capability promotions to their graph hash.
    pub fn jsonStringify(self: Claims, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (.{
            "version",
            "workspace",
            "actor",
            "grant",
            "operation",
            "task",
            "source",
            "target",
            "target_base",
            "contract_sha256",
            "candidate_sha256",
            "assessment_sha256",
            "authority_revision",
            "epoch",
            "issued_ms",
            "approval_sha256",
            "reads_sha256",
        }) |field_name| {
            try writer.objectField(field_name);
            try writer.write(@field(self, field_name));
        }
        if (self.promotion_sha256) |promotion| {
            try writer.objectField("promotion_sha256");
            try writer.write(promotion);
        }
        try writer.endObject();
    }
};
pub const Proof = struct { payload: []const u8, signature: []const u8, issuer: []const u8 };

fn state(manager: workspace.Manager, revision: []const u8) !authority.State {
    const retained = try records.decode(authority.State, manager.alloc, try manager.contentAt("authority/state.json", revision), .{});
    if (!std.mem.eql(u8, retained.version, "omos.company-authority/v1") or !std.mem.eql(u8, retained.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    return retained;
}

pub fn seal(manager: workspace.Manager, claims: Claims) !Proof {
    const current = try state(manager, claims.authority_revision);
    if (current.epoch != claims.epoch) return error.CompanyIssuerRecoveryRequired;
    const key = try keys.current(manager, current.epoch, current.issuer);
    const payload = try std.json.Stringify.valueAlloc(manager.alloc, claims, .{});
    const signature = try key.sign(payload, null);
    return .{ .payload = payload, .signature = try manager.alloc.dupe(u8, &std.fmt.bytesToHex(signature.toBytes(), .lower)), .issuer = current.issuer };
}

pub fn verify(manager: workspace.Manager, proof: Proof) !Claims {
    const claims = try records.decode(Claims, manager.alloc, proof.payload, .{});
    if (!std.mem.eql(u8, claims.version, "omos.company-publication/v1") or !std.mem.eql(u8, claims.workspace, manager.manifest.id)) return error.WorkspaceIdentityMismatch;
    const retained = try state(manager, claims.authority_revision);
    if (retained.epoch != claims.epoch or !std.mem.eql(u8, retained.issuer, proof.issuer)) return error.CompanySignatureRejected;
    const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try authority.hexBytes(32, proof.issuer));
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(try authority.hexBytes(64, proof.signature));
    signature.verifyStrict(proof.payload, public) catch return error.CompanySignatureRejected;
    const grant = try authority.liveGrant(retained, claims.grant, claims.issued_ms);
    const is_promotion = claims.promotion_sha256 != null;
    const permitted = if (is_promotion) authority.permitsAction(grant, .promote_capability) else authority.permitsAction(grant, .submit);
    if (!std.mem.eql(u8, grant.actor, claims.actor) or !permitted) return error.CompanyAccessDenied;
    const promotion_policy = @import("company_promotion_policy.zig");
    const policy = try promotion_policy.loadAt(manager, claims.authority_revision);
    if (promotion_policy.requiresHumanApproval(policy, grant, is_promotion) and claims.approval_sha256 == null) return error.CompanyApprovalRequired;
    return claims;
}
