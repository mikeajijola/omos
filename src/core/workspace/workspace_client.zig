//! Thin authenticated client. Mutations are never retried after an uncertain
//! response; the caller must reconcile against the server's retained records.
const std = @import("std");
const io = @import("../shared/io.zig");
const authority = @import("company_authority.zig");
const records = @import("../shared/record_json.zig");
const workspace = @import("fossil_workspace.zig");

pub const Company = struct {
    version: []const u8,
    workspace: []const u8,
    issuer: []const u8,
    epoch: u64,
    features: ?struct { file_attributes: ?[]const u8 = null, checkpoint_attributes: bool = false, capability_packages: bool = false } = null,
};

pub const Control = @import("../shared/bounded_operation.zig").Control;

pub fn companyBootstrap(alloc: std.mem.Allocator, base_url: []const u8) !Company {
    return companyBootstrapControlled(alloc, base_url, null);
}

pub fn companyBootstrapControlled(alloc: std.mem.Allocator, base_url: []const u8, control: ?Control) !Company {
    const value = try httpControlled(alloc, base_url, "/v1/company", null, null, control);
    const company = try std.json.parseFromValueLeaky(Company, alloc, value, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, company.version, "omos.company/v1") or !authority.safeIdentity(company.workspace) or company.epoch == 0) return error.InvalidCompanyInstance;
    _ = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try authority.hexBytes(32, company.issuer));
    return company;
}

pub fn verifyCompanyReceipt(alloc: std.mem.Allocator, company: Company, raw_request: []const u8, response: std.json.Value) !void {
    const envelope = try records.decode(authority.Envelope, alloc, raw_request, .{});
    const request = try records.decode(authority.Request, alloc, envelope.payload, .{});
    const Receipt = struct { payload: []const u8, signature: []const u8, issuer: []const u8 };
    const receipt = try std.json.parseFromValueLeaky(Receipt, alloc, response, .{});
    if (!std.mem.eql(u8, receipt.issuer, company.issuer)) return error.CompanySignatureRejected;
    const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(try authority.hexBytes(32, company.issuer));
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(try authority.hexBytes(64, receipt.signature));
    signature.verifyStrict(receipt.payload, public) catch return error.CompanySignatureRejected;
    const Claims = struct {
        version: []const u8,
        workspace: []const u8,
        actor: []const u8,
        grant: []const u8,
        operation: []const u8,
        request_hash: []const u8,
        action: authority.Action,
        epoch: u64,
        result: std.json.Value,
    };
    const claims = try records.decode(Claims, alloc, receipt.payload, .{});
    if (!std.mem.eql(u8, claims.version, "omos.company-receipt/v1") or !std.mem.eql(u8, claims.workspace, company.workspace) or !std.mem.eql(u8, claims.workspace, request.workspace) or !std.mem.eql(u8, claims.actor, request.actor) or !std.mem.eql(u8, claims.grant, request.grant) or !std.mem.eql(u8, claims.operation, request.operation) or !std.mem.eql(u8, claims.request_hash, try workspace.hash(alloc, envelope.payload)) or claims.action != request.action or claims.epoch != company.epoch) return error.CompanyReceiptMismatch;
}

/// The caller pins one instance for a sequence of reads. An issuer rotation
/// or mismatched receipt ends that sequence instead of mixing trust contexts.
pub fn companyCall(alloc: std.mem.Allocator, base_url: []const u8, company: Company, raw: []const u8) !std.json.Value {
    return companyCallControlled(alloc, base_url, company, raw, null);
}

pub fn companyCallControlled(alloc: std.mem.Allocator, base_url: []const u8, company: Company, raw: []const u8, control: ?Control) !std.json.Value {
    const envelope = try records.decode(authority.Envelope, alloc, raw, .{});
    const request = try records.decode(authority.Request, alloc, envelope.payload, .{});
    if (!authority.supportedRequestVersion(request) or !std.mem.eql(u8, request.workspace, company.workspace)) return error.WorkspaceIdentityMismatch;
    const response = httpControlled(alloc, base_url, "/v1/company", raw, null, control) catch |err| {
        if (authority.isMutation(request.action)) {
            @import("../shared/debug_trace.zig").logf("workspace", "company response outcome unknown operation={s} cause={s}; reconcile the original operation before retrying", .{ request.operation, @errorName(err) });
            return error.WorkspaceServiceOutcomeUnknown;
        }
        return err;
    };
    verifyCompanyReceipt(alloc, company, raw, response) catch |err| {
        if (authority.isMutation(request.action)) {
            @import("../shared/debug_trace.zig").logf("workspace", "company response unverified operation={s} cause={s}; reconcile the original operation before retrying", .{ request.operation, @errorName(err) });
            return error.WorkspaceServiceOutcomeUnverified;
        }
        return err;
    };
    return response;
}

pub fn call(alloc: std.mem.Allocator, base_url: []const u8, body: ?[]const u8) !std.json.Value {
    const company = if (body) |raw| blk: {
        const envelope = (std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch break :blk false).value;
        break :blk envelope == .object and envelope.object.contains("payload") and envelope.object.contains("signature");
    } else false;
    if (company) return companyCall(alloc, base_url, try companyBootstrap(alloc, base_url), body.?);
    const token = io.getenv("OMOS_WORKSPACE_TOKEN") orelse return error.MissingWorkspaceServiceToken;
    return http(alloc, base_url, if (body == null) "/v1/definition" else "/v1/workspace", body, token);
}

fn http(alloc: std.mem.Allocator, base_url: []const u8, endpoint: []const u8, body: ?[]const u8, token: ?[]const u8) !std.json.Value {
    return httpControlled(alloc, base_url, endpoint, body, token, null);
}

/// The isolated launcher installs the fixed Unix broker before any threads.
/// Neither the worker nor this request chooses a remote endpoint or identity.
pub fn workerProjection(alloc: std.mem.Allocator, body: []const u8, control: ?Control) !std.json.Value {
    if (io.getenv("OMOS_WORKER_BROKER") == null) return error.WorkerProjectionUnavailable;
    return httpControlled(alloc, "http://127.0.0.1:1", "/company/projection", body, null, control);
}

const Body = struct {
    bytes: []u8,
    pub fn deinit(self: *Body, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

fn httpControlled(alloc: std.mem.Allocator, base_url: []const u8, endpoint: []const u8, body: ?[]const u8, token: ?[]const u8, control: ?Control) !std.json.Value {
    var cancelled = std.atomic.Value(bool).init(false);
    const per_request: std.Io.Clock.Timestamp = .{ .clock = .awake, .raw = std.Io.Clock.Timestamp.now(io.getIo(), .awake).raw.addDuration(.fromSeconds(30)) };
    const deadline = if (control) |value| if (std.Io.Clock.Timestamp.compare(value.deadline, .lt, per_request)) value.deadline else per_request else per_request;
    const Operation = struct {
        alloc: std.mem.Allocator,
        base_url: []const u8,
        endpoint: []const u8,
        body: ?[]const u8,
        token: ?[]const u8,
        pub fn run(self: @This()) !Body {
            return .{ .bytes = try httpBody(self.alloc, self.base_url, self.endpoint, self.body, self.token) };
        }
    };
    var result = try @import("../shared/bounded_operation.zig").run(Body, alloc, if (control) |value| value.cancel else &cancelled, deadline, Operation{ .alloc = alloc, .base_url = base_url, .endpoint = endpoint, .body = body, .token = token });
    defer result.deinit(alloc);
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, result.bytes, .{ .allocate = .alloc_always });
}

fn httpBody(alloc: std.mem.Allocator, base_url: []const u8, endpoint: []const u8, body: ?[]const u8, token: ?[]const u8) ![]u8 {
    const base = try std.Uri.parse(base_url);
    if (base.user != null or base.password != null or base.query != null or base.fragment != null or base.host == null) return error.InvalidWorkspaceEndpoint;
    const host = try base.host.?.toRawMaybeAlloc(alloc);
    const loopback = std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "[::1]");
    if (!std.ascii.eqlIgnoreCase(base.scheme, "https") and !(std.ascii.eqlIgnoreCase(base.scheme, "http") and loopback)) return error.InsecureWorkspaceEndpoint;
    if (token) |value| if (value.len < 32 or value.len > 1024 or std.mem.findScalar(u8, value, '\r') != null or std.mem.findScalar(u8, value, '\n') != null) return error.InvalidWorkspaceServiceToken;
    const url = try alloc.print("{s}{s}", .{ std.mem.trimEnd(u8, base_url, "/"), endpoint });
    const bearer = if (token) |value| try alloc.print("Bearer {s}", .{value}) else null;
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var request = try client.request(if (body == null) .GET else .POST, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .authorization = if (bearer) |value| .{ .override = value } else .omit, .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
    });
    defer request.deinit();
    if (body) |raw| try request.sendBodyComplete(@constCast(raw)) else try request.sendBodiless();
    var response = request.receiveHead(&.{}) catch return error.WorkspaceServiceOutcomeUnknown;
    if (response.head.status == .conflict) return error.WorkspaceServiceConflict;
    if (response.head.status == .unauthorized or response.head.status == .forbidden) return error.WorkspaceServiceDenied;
    if (response.head.status != .ok) return error.WorkspaceServiceRejected;
    var transfer: [4096]u8 = undefined;
    return response.reader(&transfer).allocRemaining(alloc, .limited(1024 * 1024)) catch return error.WorkspaceServiceOutcomeUnknown;
}

test "company client verifies issuer, signature and exact request receipt binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(12));
    const issuer = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    const company: Company = .{ .version = "omos.company/v1", .workspace = "company", .issuer = &issuer, .epoch = 3 };
    const payload = try std.json.Stringify.valueAlloc(alloc, authority.Request{ .version = "omos.company/v1", .workspace = "company", .actor = "alice", .grant = "team", .operation = "once", .expires_ms = 10000, .action = .read, .path = "documents/team/report.md" }, .{});
    const original = try std.json.Stringify.valueAlloc(alloc, authority.Envelope{ .payload = payload, .signature = "unused-outgoing-signature" }, .{});
    const raw = try std.json.Stringify.valueAlloc(alloc, .{ .version = "omos.company-receipt/v1", .workspace = "company", .actor = "alice", .grant = "team", .operation = "once", .request_hash = try workspace.hash(alloc, payload), .action = "read", .epoch = 3, .result = .{ .bytes = 20 } }, .{});
    const encode = struct {
        fn signed(a: std.mem.Allocator, signer: std.crypto.sign.Ed25519.KeyPair, value: []const u8) !std.json.Value {
            const signature = try signer.sign(value, null);
            const encoded = try std.json.Stringify.valueAlloc(a, .{ .payload = value, .signature = &std.fmt.bytesToHex(signature.toBytes(), .lower), .issuer = &std.fmt.bytesToHex(signer.public_key.toBytes(), .lower) }, .{});
            return std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{});
        }
    };
    const receipt = try encode.signed(alloc, key, raw);
    try verifyCompanyReceipt(alloc, company, original, receipt);
    var wrong_issuer = company;
    wrong_issuer.issuer = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.CompanySignatureRejected, verifyCompanyReceipt(alloc, wrong_issuer, original, receipt));
    const changed_request = try std.json.Stringify.valueAlloc(alloc, authority.Envelope{ .payload = try alloc.print("{s} ", .{payload}), .signature = "unused-outgoing-signature" }, .{});
    try std.testing.expectError(error.CompanyReceiptMismatch, verifyCompanyReceipt(alloc, company, changed_request, receipt));
    for ([_]struct { name: []const u8, value: std.json.Value }{
        .{ .name = "workspace", .value = .{ .string = "other" } },
        .{ .name = "actor", .value = .{ .string = "bob" } },
        .{ .name = "grant", .value = .{ .string = "other" } },
        .{ .name = "operation", .value = .{ .string = "replayed" } },
        .{ .name = "action", .value = .{ .string = "submit" } },
        .{ .name = "epoch", .value = .{ .integer = 4 } },
    }) |change| {
        var claims = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
        try claims.object.put(alloc, change.name, change.value);
        const mismatched = try encode.signed(alloc, key, try std.json.Stringify.valueAlloc(alloc, claims, .{}));
        try std.testing.expectError(error.CompanyReceiptMismatch, verifyCompanyReceipt(alloc, company, original, mismatched));
    }
    var tampered = try encode.signed(alloc, key, raw);
    try tampered.object.put(alloc, "payload", .{ .string = try alloc.print("{s} ", .{raw}) });
    try std.testing.expectError(error.CompanySignatureRejected, verifyCompanyReceipt(alloc, company, original, tampered));
}
