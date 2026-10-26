#!/usr/bin/env node
// Optional stdio transport for the native company service. No product state is
// stored here: requests, authority, outcomes, and publication remain native.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createHash, createPrivateKey, createPublicKey, sign, verify } from "node:crypto";

const MAX = 1024 * 1024;
const versions = ["2025-11-25", "2025-06-18"];
const mutation = new Set(["create_view", "checkpoint", "submit", "delegate", "reconcile", "record", "execution", "execute_task"]);
const identity = value => typeof value === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(value);
const hex = (value, size) => typeof value === "string" && new RegExp(`^[0-9a-f]{${size * 2}}$`).test(value);
const fail = code => { throw new Error(code); };
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);

function boundary(value, maxDepth = 64, maxValues = 20000) {
  const pending = [[value, 0]];
  let count = 0;
  while (pending.length) {
    const [item, depth] = pending.pop();
    if (++count > maxValues || depth > maxDepth) fail("RequestTooComplex");
    if (item && typeof item === "object") {
      for (const key of Object.keys(item)) {
        if (["__proto__", "prototype", "constructor"].includes(key)) fail("InvalidRequestKey");
        pending.push([item[key], depth + 1]);
        if (pending.length > maxValues) fail("RequestTooComplex");
      }
    }
  }
}

function validate(value, schema) {
  const types = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  const type = value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
  if (types.length && !types.includes(type) && !(types.includes("integer") && Number.isSafeInteger(value))) fail("InvalidArguments");
  if (schema.enum && !schema.enum.includes(value)) fail("InvalidArguments");
  if (typeof value === "number" && (!Number.isSafeInteger(value) || value < (schema.minimum ?? -Infinity) || value > (schema.maximum ?? Infinity))) fail("InvalidArguments");
  if (typeof value === "string" && (value.length < (schema.minLength ?? 0) || value.length > (schema.maxLength ?? Infinity))) fail("InvalidArguments");
  if (object(value) && schema.properties) {
    for (const name of schema.required ?? []) if (!Object.hasOwn(value, name)) fail("InvalidArguments");
    for (const name of Object.keys(value)) {
      if (Object.hasOwn(schema.properties, name)) validate(value[name], schema.properties[name]);
      else if (schema.additionalProperties === false) fail("InvalidArguments");
    }
  }
}

// Sorting makes identical operation arguments retain identical request hashes
// when MCP clients reorder JSON keys. It does not rewrite string content.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (object(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

async function privateFile(filename, limit) {
  if (!path.isAbsolute(filename)) fail("AbsolutePrivatePathRequired");
  let parent = path.dirname(filename);
  for (;;) {
    const stat = await fs.lstat(parent);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail("UnsafePrivatePath");
    if (parent === path.dirname(parent)) break;
    parent = path.dirname(parent);
  }
  const before = await fs.lstat(filename);
  const handle = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || before.ino !== stat.ino || before.dev !== stat.dev || stat.nlink !== 1 || (stat.mode & 0o777) !== 0o600 || (process.getuid && stat.uid !== process.getuid()) || stat.size > limit) fail("UnsafePrivateFile");
    const bytes = Buffer.alloc(limit + 1);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      if (offset > limit) fail("PrivateFileTooLarge");
      return Buffer.from(bytes.subarray(0, offset));
    } finally { bytes.fill(0); }
  } finally { await handle.close(); }
}

async function configuration(filename, home = process.env.HOME) {
  const bytes = await privateFile(filename, 65536);
  let config;
  try { config = JSON.parse(bytes.toString("utf8")); } finally { bytes.fill(0); }
  boundary(config);
  if (!object(config) || config.version !== "omos.company-mcp/v1" || !identity(config.actor) || !identity(config.grant) || !identity(config.key_handle) || !hex(config.workspace, 32) || !hex(config.issuer, 32) || !Number.isSafeInteger(config.epoch) || config.epoch < 1) fail("InvalidConfiguration");
  const allowed = ["version", "endpoint", "workspace", "actor", "grant", "key_handle", "issuer", "epoch", "actions"];
  if (Object.keys(config).some(key => !allowed.includes(key))) fail("InvalidConfiguration");
  const endpoint = new URL(config.endpoint);
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || (endpoint.protocol !== "https:" && !(endpoint.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(endpoint.hostname)))) fail("InsecureCompanyEndpoint");
  const declaration = JSON.parse(await fs.readFile(new URL("../../src/core/workspace/standard/omos.json", import.meta.url), "utf8"));
  const schema = declaration.spec.operations.find(item => item.id === "omos_company_operation").input;
  if (!Array.isArray(config.actions) || !config.actions.length || config.actions.some(action => !schema.properties.action.enum.includes(action)) || new Set(config.actions).size !== config.actions.length) fail("InvalidConfiguredActions");
  const seed = await privateFile(path.join(home ?? fail("HomeUnavailable"), ".fx/company-keys", `${config.key_handle}.seed`), 32);
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  let key;
  try {
    if (seed.length !== 32) fail("InvalidCompanyKey");
    key = createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  } finally { seed.fill(0); der.fill(0); }
  const publicKey = createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(config.issuer, "hex")]), format: "der", type: "spki" });
  const inputSchema = structuredClone(schema);
  for (const name of ["workspace", "actor", "grant"]) delete inputSchema.properties[name];
  inputSchema.required = inputSchema.required.filter(name => !["workspace", "actor", "grant"].includes(name));
  inputSchema.properties.action.enum = config.actions;
  return { config, key, publicKey, issuer, inputSchema, url: endpoint.href.replace(/\/$/, "") + "/v1/company" };
}

async function http(state, body, signal) {
  // Do not forward process credentials, cookies, or the owner bearer token.
  const response = await fetch(state.url, { method: body ? "POST" : "GET", headers: { "content-type": "application/json" }, body, redirect: "error", credentials: "omit", signal });
  if (!response.body) fail("CompanyResponseMissing");
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > MAX) fail("CompanyResponseTooLarge");
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  if (response.status !== 200) fail(`CompanyHttp${response.status}`);
  const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  boundary(value);
  return value;
}

async function bootstrap(state, signal) {
  let boot;
  try { boot = await http(state, undefined, signal); }
  catch (error) {
    // A bootstrap GET has no effects. Recover one closed transport inside the
    // existing deadline; signed POST operations are never retried here.
    signal?.throwIfAborted();
    const code = error.cause?.code ?? error.code;
    if (!["ECONNRESET", "EPIPE", "UND_ERR_SOCKET"].includes(code)) throw error;
    boot = await http(state, undefined, signal);
  }
  if (boot.version !== "omos.company/v1" || boot.workspace !== state.config.workspace || boot.issuer !== state.config.issuer || boot.epoch !== state.config.epoch) fail("CompanyIdentityChanged");
  return boot;
}

async function call(state, name, args, signal) {
  boundary(args);
  if (!object(args)) fail("InvalidArguments");
  if (name === "company_context") {
    if (Object.keys(args).length) fail("InvalidArguments");
    return { content: [{ type: "text", text: JSON.stringify({ company: await bootstrap(state, signal), actor: state.config.actor, grant: state.config.grant, public_key: state.publicKey, configured_actions: state.config.actions, now_ms: Date.now(), authority: "checked by the native service on each signed operation" }) }] };
  }
  if (name !== "company_workspace") fail("UnknownTool");
  validate(args, state.inputSchema);
  if (!identity(args.operation) || args.expires_ms <= Date.now() || args.expires_ms > Date.now() + 300000) fail("InvalidOperationOrExpiry");
  const request = { ...args, workspace: state.config.workspace, actor: state.config.actor, grant: state.config.grant };
  const payload = canonical(request);
  const body = JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), state.key).toString("hex") });
  if (Buffer.byteLength(body) > MAX) fail("CompanyRequestTooLarge");
  // Read results already carry a verified issuer, epoch, request hash and
  // scope receipt. A second public GET would take the same native writer
  // boundary and compete with reviews while polling. Mutations retain the
  // preflight before dispatch; no signed POST is replayed on failure.
  if (mutation.has(args.action)) await bootstrap(state, signal);
  const request_hash = createHash("sha256").update(payload).digest("hex");
  let envelope;
  try { envelope = await http(state, body, signal); }
  catch {
    return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: mutation.has(args.action) ? "CompanyOutcomeUnknown" : "CompanyRequestFailed", operation: args.operation, request_hash, advice: "Inspect status or reconcile this operation before repeating a mutation. No retry was sent." }) }] };
  }
  try {
    if (envelope.issuer !== state.config.issuer || typeof envelope.payload !== "string" || !hex(envelope.signature, 64) || !verify(null, Buffer.from(envelope.payload), state.issuer, Buffer.from(envelope.signature, "hex"))) fail("InvalidCompanyReceipt");
    const receipt = JSON.parse(envelope.payload);
    // A bounded record page adds receipt and row wrappers around data that
    // already passed the native record boundary. Preserve those valid pages.
    boundary(receipt, 128, 65536);
    if (!object(receipt) || !Object.hasOwn(receipt, "result")) fail("InvalidCompanyReceipt");
    const expected = { version: "omos.company-receipt/v1", workspace: request.workspace, actor: request.actor, grant: request.grant, operation: request.operation, request_hash, action: request.action, epoch: state.config.epoch };
    for (const [key, value] of Object.entries(expected)) if (receipt[key] !== value) fail("CompanyReceiptMismatch");
    return { content: [{ type: "text", text: JSON.stringify(receipt.result) }], structuredContent: { receipt: envelope } };
  } catch {
    return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: "CompanyOutcomeUnverified", operation: args.operation, request_hash, advice: "Inspect status or reconcile this operation; the response did not prove its outcome. No retry was sent." }) }] };
  }
}

function tools(state) {
  return [
    { name: "company_context", description: "Inspect the configured company's public bootstrap, actor identity, current time, and configured actions. Authority is enforced on signed operations.", inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: true } },
    { name: "company_workspace", description: "Use the native signed company workspace service within this actor's grant. Supply a unique operation ID and expires_ms within five minutes; preserve them when resolving an uncertain outcome. Read bounded pages; edits require a pinned expected revision. When bootstrap advertises task_scopes, create_view can narrow its immutable scope to selected permitted file paths. Submission queues independent host review and does not mean acceptance.", inputSchema: structuredClone(state.inputSchema), annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true } },
  ];
}

function publicFailure(error, aborted = false) {
  const allowed = ["UnknownTool", "InvalidArguments", "InvalidOperationOrExpiry", "CompanyIdentityChanged", "CompanyRequestTooLarge", "RequestTooComplex", "InvalidRequestKey", "CompanyClientClosed", "CompanyWorkerScopeDenied", "CompanyWorkerExpired", "CompanyWorkerOperationBudgetExceeded"];
  const known = allowed.includes(error.message);
  const cause = aborted ? "RequestDeadline" : /^CompanyHttp[0-9]{3}$/.test(error.message) ? error.message : typeof error.cause?.code === "string" && /^[A-Z_0-9]{1,48}$/.test(error.cause.code) ? error.cause.code : ["SyntaxError", "TypeError", "AbortError"].includes(error.name) ? error.name : "RequestPreparationFailed";
  return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: known ? error.message : "CompanyRequestNotAttempted", ...(!known ? { failure_stage: "before_signed_dispatch", failure_code: cause } : {}) }) }] };
}

// The host bridge uses the same configuration, signing, authority, receipts,
// and uncertain-outcome rules as the installed stdio companion. Keys remain
// inside this closure and are never included in returned tools or results.
export async function createCompanyClient(filename, { home, binding } = {}) {
  let state = await configuration(filename, home);
  let scope;
  if (binding !== undefined) {
    const permitted = ["discover", "read", "checkpoint", "submit", "status", "reconcile", "query", "record"];
    if (!object(binding) || !identity(binding.view) || !object(binding.execution) || !identity(binding.execution.runtime) || !Number.isSafeInteger(binding.execution.generation) || binding.execution.generation < 1 || !Number.isSafeInteger(binding.expiresMs) || binding.expiresMs <= Date.now() || !Array.isArray(binding.actions) || !binding.actions.length || binding.actions.some(action => !permitted.includes(action) || !state.config.actions.includes(action)) || new Set(binding.actions).size !== binding.actions.length || Object.keys(binding).some(key => !["view", "execution", "expiresMs", "actions"].includes(key)) || Object.keys(binding.execution).some(key => !["runtime", "generation"].includes(key))) fail("InvalidWorkerBinding");
    scope = structuredClone(binding);
    state.config.actions = scope.actions;
    state.inputSchema.properties.action.enum = scope.actions;
  }
  const publicIdentity = Object.freeze(Object.fromEntries(["workspace", "actor", "grant", "issuer", "epoch"].map(name => [name, state.config[name]])));
  const active = new Set();
  const issued = new Set();
  return Object.freeze({
    identity: publicIdentity,
    scope: scope ? Object.freeze({ ...scope, execution: Object.freeze({ ...scope.execution }), actions: Object.freeze([...scope.actions]) }) : null,
    tools() {
      if (!state) fail("CompanyClientClosed");
      const result = tools(state);
      if (scope) {
        const schema = result[1].inputSchema;
        for (const field of ["view", "execution", "scope"]) { delete schema.properties[field]; schema.required = schema.required.filter(name => name !== field); }
        result[1].description += " The host pins the company view and execution generation. Supply neither view nor execution; authority cannot be expanded from this worker.";
      }
      return result;
    },
    async call(name, args, signal) {
      if (!state) return publicFailure(new Error("CompanyClientClosed"));
      const current = state, controller = new AbortController();
      active.add(controller);
      const timer = setTimeout(() => controller.abort(), 30000);
      const bounded = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
      try {
        if (scope) {
          if (scope.expiresMs <= Date.now()) fail("CompanyWorkerExpired");
          if (name === "company_workspace") {
            if (!object(args) || Object.hasOwn(args, "view") || Object.hasOwn(args, "execution") || Object.hasOwn(args, "scope") || !scope.actions.includes(args.action) || (args.outcome !== undefined && !issued.has(args.outcome))) fail("CompanyWorkerScopeDenied");
            if (mutation.has(args.action) && issued.size >= 1024 && !issued.has(args.operation)) fail("CompanyWorkerOperationBudgetExceeded");
            args = { ...structuredClone(args), view: scope.view, execution: scope.execution };
            if (mutation.has(args.action) && identity(args.operation)) issued.add(args.operation);
          }
          const expiry = setTimeout(() => controller.abort(), Math.max(1, scope.expiresMs - Date.now()));
          try {
            const result = await call(current, name, args, bounded);
            if (name === "company_context" && !result.isError) {
              const context = JSON.parse(result.content[0].text);
              context.execution_scope = structuredClone(scope);
              result.content[0].text = JSON.stringify(context);
            }
            return result;
          } finally { clearTimeout(expiry); }
        }
        return await call(current, name, args, bounded);
      }
      catch (error) { return publicFailure(error, bounded.aborted); }
      finally { clearTimeout(timer); active.delete(controller); }
    },
    close() {
      for (const controller of active) controller.abort();
      state = null;
    },
  });
}

async function main() {
  if (process.argv.length !== 3) fail("Usage: node deployment/company/mcp.mjs ABSOLUTE_CONFIG.json");
  const state = await configuration(process.argv[2]);
  let initialized = false, stopped = false, buffered = Buffer.alloc(0), queued = 0;
  const active = new Map();
  const stop = () => { stopped = true; for (const controller of active.values()) controller.abort(); process.stdin.destroy(); };
  const send = (id, result, error) => {
    if (stopped || id === undefined) return;
    const line = JSON.stringify({ jsonrpc: "2.0", id, ...(error ? { error } : { result }) }) + "\n";
    const bytes = Buffer.byteLength(line);
    if (bytes > 4 * MAX || queued + bytes > 8 * MAX) { stop(); return; }
    queued += bytes;
    if (!process.stdout.write(line, () => { queued -= bytes; })) process.stdin.pause();
  };
  process.stdout.on("drain", () => { if (!stopped) process.stdin.resume(); });
  process.stdout.on("error", stop);
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  const dispatch = async line => {
    let message;
    try {
      message = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line));
      boundary(message);
    } catch { send(null, null, { code: -32700, message: "Invalid or excessive JSON" }); return; }
    if (!object(message) || message.jsonrpc !== "2.0" || typeof message.method !== "string" || (message.id !== undefined && typeof message.id !== "string" && !Number.isSafeInteger(message.id))) { send(null, null, { code: -32600, message: "Invalid request" }); return; }
    const { id, method, params = {} } = message;
    if (!object(params)) { send(id, null, { code: -32602, message: "Invalid params" }); return; }
    const requested = method === "initialize" ? params.protocolVersion : params._meta?.["io.modelcontextprotocol/protocolVersion"];
    if (requested && !versions.includes(requested)) { send(id, null, { code: -32022, message: "Unsupported protocol version", data: { supported: versions, requested } }); return; }
    if (method === "notifications/cancelled") { active.get(JSON.stringify(params.requestId))?.abort(); return; }
    if (id === undefined) return;
    if (method === "initialize") {
      if (!versions.includes(params.protocolVersion)) { send(id, null, { code: -32022, message: "Unsupported protocol version", data: { supported: versions, requested: params.protocolVersion } }); return; }
      initialized = true;
      send(id, { protocolVersion: params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "omos-company", version: "1" } });
      return;
    }
    if (!initialized) { send(id, null, { code: -32000, message: "Initialize first" }); return; }
    if (method === "ping") { send(id, {}); return; }
    if (method === "tools/list") {
      send(id, { tools: tools(state) });
      return;
    }
    if (method !== "tools/call") { send(id, null, { code: -32601, message: "Method not found" }); return; }
    const key = JSON.stringify(id);
    if (active.has(key)) { send(id, null, { code: -32600, message: "Request ID already active" }); return; }
    if (active.size >= 16) { send(id, null, { code: -32000, message: "Too many active requests" }); return; }
    const controller = new AbortController();
    active.set(key, controller);
    const timer = setTimeout(() => controller.abort(), 30000);
    try { send(id, await call(state, params.name, params.arguments ?? {}, controller.signal)); }
    catch (error) {
      send(id, publicFailure(error));
    } finally { clearTimeout(timer); active.delete(key); }
  };
  process.stdin.on("data", chunk => {
    if (stopped) return;
    buffered = Buffer.concat([buffered, chunk]);
    for (;;) {
      const newline = buffered.indexOf(10);
      if (newline < 0) break;
      if (newline > MAX) { stop(); return; }
      const line = buffered.subarray(0, newline);
      buffered = buffered.subarray(newline + 1);
      if (line.length) void dispatch(line);
    }
    if (buffered.length > MAX) stop();
  });
  process.stdin.on("end", stop);
  process.stdin.on("error", stop);
}

const invoked = process.argv[1] ? await fs.realpath(process.argv[1]).catch(() => null) : null;
if (invoked && import.meta.url === pathToFileURL(invoked).href) {
  main().catch(() => { process.stderr.write("Company MCP configuration could not be loaded. Check its private path, permissions, identity pins, and key handle.\n"); process.exitCode = 1; });
}
