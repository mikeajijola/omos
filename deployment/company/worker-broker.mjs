// Fixed destinations for an isolated worker. The broker owns provider
// credentials; the company gateway still authenticates every signed operation.
import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { once } from "node:events";
import { randomUUID } from "node:crypto";

const failure = code => { throw new Error(code); };
function endpoint(raw) {
  const url = new URL(raw);
  if (url.username || url.password || url.search || url.hash || (url.protocol !== "https:" && !(url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)))) failure("InvalidBrokerEndpoint");
  return url;
}
async function body(request, maximum, signal) {
  const chunks = []; let bytes = 0;
  const aborted = () => request.destroy();
  signal.throwIfAborted();
  signal.addEventListener("abort", aborted, { once: true });
  try {
    for await (const chunk of request) {
      signal.throwIfAborted();
      bytes += chunk.length;
      if (bytes > maximum) failure("BrokerRequestTooLarge");
      chunks.push(chunk);
    }
  } finally { signal.removeEventListener("abort", aborted); }
  return Buffer.concat(chunks);
}
function parsed(bytes) {
  const value = JSON.parse(bytes.toString("utf8"));
  const pending = [[value, 0]]; let count = 0;
  while (pending.length) {
    const [item, depth] = pending.pop();
    if (++count > 100000 || depth > 64) failure("BrokerRequestTooComplex");
    if (item && typeof item === "object") for (const key of Object.keys(item)) {
      if (["__proto__", "prototype", "constructor"].includes(key)) failure("InvalidBrokerRequest");
      pending.push([item[key], depth + 1]);
      if (pending.length > 100000) failure("BrokerRequestTooComplex");
    }
  }
  return value;
}

async function isolatedSocketParent(socket) {
  const owner = process.getuid?.();
  if (owner === undefined) failure("WorkerBrokerSocketBoundaryRequired");
  let selected = path.dirname(socket), first = true, privateBoundary = false;
  for (;;) {
    const info = await fs.lstat(selected);
    if (!info.isDirectory() || info.isSymbolicLink() || ![0, owner].includes(info.uid)) failure("WorkerBrokerSocketBoundaryRequired");
    if (first && (info.uid !== owner || !(info.mode & 0o200))) failure("WorkerBrokerSocketBoundaryRequired");
    if ((info.mode & 0o022) && !(info.mode & 0o1000)) failure("WorkerBrokerSocketBoundaryRequired");
    if (info.uid === owner && (info.mode & 0o077) === 0) privateBoundary = true;
    if (selected === path.dirname(selected)) break;
    selected = path.dirname(selected); first = false;
  }
  if (!privateBoundary) failure("WorkerBrokerSocketBoundaryRequired");
}

export async function createWorkerBroker({ socket, model, company, companyClient, expiresMs, maxRequests = 256, maxConcurrent = 4, socketMode = 0o600 }) {
  if (typeof socket !== "string" || !socket.startsWith("/") || socket.length > 100 || socket.includes("\0") || !Number.isSafeInteger(expiresMs) || expiresMs <= Date.now() || !Number.isInteger(maxRequests) || maxRequests < 1 || maxRequests > 10000 || !Number.isInteger(maxConcurrent) || maxConcurrent < 1 || maxConcurrent > 16 || ![0o600, 0o666].includes(socketMode)) failure("InvalidWorkerBroker");
  const modelUrl = endpoint(model.endpoint), companyUrl = endpoint(company.endpoint);
  if (socketMode === 0o666) await isolatedSocketParent(socket);
  if (typeof model.model !== "string" || !model.model || typeof model.handle !== "string" || !model.handle || !Array.isArray(company.actions) || !company.actions.length) failure("InvalidWorkerBroker");
  for (const field of ["workspace", "actor", "grant"]) if (typeof company[field] !== "string" || !company[field]) failure("InvalidWorkerBroker");
  if (companyClient && (!companyClient.scope || companyClient.scope.view !== company.view || companyClient.scope.expiresMs < expiresMs || !["workspace", "actor", "grant"].every(field => companyClient.identity[field] === company[field]) || companyClient.scope.actions.some(action => !company.actions.includes(action)))) failure("InvalidWorkerCompanyClient");
  if (company.source_revision !== undefined && (!companyClient || !/^[0-9a-f]{64}$/.test(company.source_revision) || !company.actions.includes("read") || !company.actions.includes("discover"))) failure("InvalidWorkerProjection");
  let active = 0, requests = 0, projectionRequests = 0;
  const controllers = new Set();
  const server = http.createServer(async (request, response) => {
    let claimed = false, controller;
    const error = (status, code) => {
      if (!response.headersSent) response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
      response.end(JSON.stringify({ error: { message: code, type: "worker_broker_error" } }));
    };
    try {
      if (Date.now() >= expiresMs) return error(403, "WorkerBrokerExpired");
      if (active >= maxConcurrent) return error(429, "WorkerBrokerBusy");
      const projection = request.url === "/company/projection" && company.source_revision !== undefined;
      if (projection ? ++projectionRequests > 20000 : ++requests > maxRequests) return error(429, "WorkerBrokerBudgetExceeded");
      active++; claimed = true;
      controller = new AbortController(); controllers.add(controller);
      const timer = setTimeout(() => controller.abort(), Math.min(120000, expiresMs - Date.now()));
      response.once("close", () => { clearTimeout(timer); controller.abort(); });
      if (projection) {
        if (request.method !== "POST") return error(405, "WorkerProjectionMethodDenied");
        const input = parsed(await body(request, 8192, controller.signal));
        if (!input || Array.isArray(input) || Object.keys(input).some(key => !["action", "path", "offset"].includes(key)) || !["inventory", "read"].includes(input.action) || !Number.isSafeInteger(input.offset ?? 0) || (input.offset ?? 0) < 0 || (input.action === "read" && typeof input.path !== "string") || (input.action === "inventory" && input.path !== undefined)) return error(400, "InvalidWorkerProjectionRequest");
        const result = await companyClient.call("company_workspace", { version: "omos.company/v2", action: input.action === "inventory" ? "discover" : "read", operation: randomUUID(), expires_ms: Math.min(expiresMs, Date.now() + 300000), revision: company.source_revision, offset: input.offset ?? 0, ...(input.action === "read" ? { path: input.path } : {}) }, controller.signal);
        if (result.isError) return error(403, "WorkerProjectionReadDenied");
        const data = JSON.parse(result.content[0].text);
        if (data.revision !== company.source_revision || data.read_tracking !== "recorded") return error(409, "WorkerProjectionChanged");
        response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        return response.end(JSON.stringify({ workspace: company.workspace, view: company.view, revision: company.source_revision, generation: companyClient.scope.execution.generation, data }));
      }
      if (request.url === "/company/mcp" && companyClient) {
        if (request.method !== "POST") { response.setHeader("allow", "POST"); return error(405, "WorkerMcpMethodDenied"); }
        const rpc = parsed(await body(request, 1024 * 1024, controller.signal));
        if (!rpc || Array.isArray(rpc) || rpc.jsonrpc !== "2.0" || typeof rpc.method !== "string" || (rpc.params !== undefined && (!rpc.params || typeof rpc.params !== "object" || Array.isArray(rpc.params))) || (rpc.id !== undefined && !(typeof rpc.id === "string" && rpc.id.length <= 128) && !Number.isSafeInteger(rpc.id))) return error(400, "InvalidWorkerMcpRequest");
        if (rpc.id === undefined) { response.writeHead(202); return response.end(); }
        let result, rpcError, status = 200;
        const supported = ["2025-11-25", "2025-06-18"];
        if (rpc.method === "server/discover") {
          status = 400;
          rpcError = { code: -32022, message: "Unsupported protocol version", data: { supported, requested: rpc.params?._meta?.["io.modelcontextprotocol/protocolVersion"] ?? "2026-07-28" } };
        }
        else if (rpc.method === "initialize") {
          if (!supported.includes(rpc.params?.protocolVersion)) { status = 400; rpcError = { code: -32022, message: "Unsupported protocol version", data: { supported, requested: rpc.params?.protocolVersion } }; }
          else result = { protocolVersion: rpc.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "omos-company-worker", version: "1" } };
        } else if (rpc.method === "ping") result = {};
        else if (rpc.method === "tools/list") result = { tools: companyClient.tools() };
        else if (rpc.method === "tools/call" && typeof rpc.params?.name === "string") result = await companyClient.call(rpc.params.name, rpc.params.arguments ?? {}, controller.signal);
        else rpcError = { code: -32601, message: "Method not found" };
        response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
        return response.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, ...(rpcError ? { error: rpcError } : { result }) }));
      }
      let target, payload;
      const headers = { "content-type": "application/json" };
      if (request.method === "POST" && request.url === "/model/v1/chat/completions") {
        const input = parsed(await body(request, 8 * 1024 * 1024, controller.signal));
        if (!input || input.model !== model.handle || !Array.isArray(input.messages)) return error(403, "WorkerModelDenied");
        target = modelUrl;
        payload = JSON.stringify({ ...input, model: model.model });
        if (model.credential) headers.authorization = `Bearer ${model.credential}`;
      } else if (request.method === "GET" && request.url === "/model/v1/models") {
        response.writeHead(200, { "content-type": "application/json" });
        return response.end(JSON.stringify({ data: [{ id: model.handle }] }));
      } else if (request.method === "POST" && request.url === "/company/v1/company") {
        const input = parsed(await body(request, 1024 * 1024, controller.signal));
        if (!input || typeof input.payload !== "string" || typeof input.signature !== "string") return error(403, "WorkerCompanyDenied");
        const operation = parsed(Buffer.from(input.payload));
        if (!operation || !["workspace", "actor", "grant"].every(field => operation[field] === company[field]) || !company.actions.includes(operation.action) || (company.view && operation.view && operation.view !== company.view)) return error(403, "WorkerCompanyDenied");
        target = companyUrl; payload = JSON.stringify(input);
      } else if (request.method === "GET" && request.url === "/company/v1/company") {
        target = companyUrl;
      } else return error(403, "WorkerBrokerRouteDenied");
      const upstream = await fetch(target, { method: request.method, headers, body: payload, signal: controller.signal, redirect: "error", credentials: "omit" });
      if (!upstream.ok) {
        // Provider errors can echo privileged request headers. Expose status
        // without forwarding their bodies or server-owned credentials.
        await upstream.body?.cancel();
        return error(upstream.status, "WorkerUpstreamRejected");
      }
      response.writeHead(upstream.status, { "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "no-store" });
      let received = 0;
      for await (const chunk of upstream.body ?? []) {
        received += chunk.byteLength;
        if (received > 16 * 1024 * 1024) failure("WorkerBrokerResponseTooLarge");
        if (!response.write(chunk)) await once(response, "drain", { signal: controller.signal });
      }
      response.end();
    } catch {
      if (!response.destroyed) error(502, "WorkerBrokerRequestFailed");
    } finally {
      if (claimed) active--;
      if (controller) { controllers.delete(controller); controller.abort(); }
    }
  });
  server.keepAliveTimeout = 0;
  server.headersTimeout = 5000;
  server.requestTimeout = 30000;
  server.listen(socket);
  await once(server, "listening");
  try { await fs.chmod(socket, socketMode); }
  catch (error) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); throw error; }
  return {
    server,
    async close() {
      for (const controller of controllers) controller.abort();
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
