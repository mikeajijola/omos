import { afterEach, expect, test } from "bun:test";
import http from "node:http";
import net from "node:net";
import { join } from "node:path";
import { existsSync, readFileSync, writeFileSync, statSync, mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { cleanupFixtures, fixture, model, writeMemory, startWorkspaceService } from "./fossil-workspace-helpers";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { createWorkerControl } from "../../deployment/company/worker-control.mjs";
import { createCompanyClient } from "../../deployment/company/mcp.mjs";
import { createWorkerBroker } from "../../deployment/company/worker-broker.mjs";

const launcher = join(import.meta.dir, "../../deployment/company/worker-launcher.py");
const rootFixture = join(import.meta.dir, "fixtures/company-worker-root.py");
const probeResult = process.platform === "linux" ? spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", launcher, "--probe"], { encoding: "utf8", timeout: 10000 }) : null;
const support = probeResult?.status === 0 ? JSON.parse(probeResult.stdout) : null;

afterEach(cleanupFixtures);

function local(socket: string, path: string, data?: object, headers: Record<string, string> = {}) {
  return new Promise<{ status: number; text: string }>((resolve, reject) => {
    const request = http.request({ socketPath: socket, path, method: data ? "POST" : "GET", headers: { "content-type": "application/json", ...headers } }, response => {
      let text = "";
      response.setEncoding("utf8"); response.on("data", chunk => { text += chunk; });
      response.on("end", () => resolve({ status: response.statusCode!, text }));
      response.on("error", reject);
    });
    request.on("error", reject);
    request.end(data ? JSON.stringify(data) : undefined);
  });
}

function absoluteTarget(socket: string) {
  return new Promise<number>((resolve, reject) => {
    const client = net.createConnection({ path: socket }, () => client.write("GET http://untrusted.example/model HTTP/1.1\r\nHost: untrusted.example\r\nConnection: close\r\n\r\n"));
    let response = "";
    client.on("data", chunk => {
      response += chunk.toString();
      if (response.includes("\r\n")) { client.destroy(); resolve(Number(response.split(" ")[1])); }
    });
    client.on("error", reject);
  });
}

test("worker broker pins destinations, models and company identity while retaining provider credentials outside the worker", async () => {
  const f = fixture(), socket = join(f.home, "broker.sock");
  const received: { path: string; authorization: string | null; cookie: string | null; body: any }[] = [];
  const upstream = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const body = request.method === "POST" ? await request.json() : null;
    received.push({ path: new URL(request.url).pathname, authorization: request.headers.get("authorization"), cookie: request.headers.get("cookie"), body });
    if ((body as any)?.messages?.[0]?.content === "reject") return new Response("Privileged request contained fixture-private", { status: 401 });
    return Response.json({ accepted: true });
  } });
  const config = {
    socket, expiresMs: Date.now() + 60000,
    model: { endpoint: `http://127.0.0.1:${upstream.port}/model`, handle: "worker-model", model: "provider-model", credential: "fixture-private" },
    company: { endpoint: `http://127.0.0.1:${upstream.port}/company`, workspace: "workspace", actor: "worker", grant: "grant", view: "view", actions: ["read", "status"] },
  };
  const broker = await createWorkerBroker(config);
  try {
    expect(statSync(socket).mode & 0o777).toBe(0o600);
    const request = { model: "worker-model", messages: [{ role: "user", content: "Inspect the report" }] };
    expect((await local(socket, "/model/v1/chat/completions", request, { authorization: "Bearer caller", cookie: "private-caller-cookie" })).status).toBe(200);
    expect(received[0]).toMatchObject({ path: "/model", authorization: "Bearer fixture-private", cookie: null, body: { model: "provider-model" } });
    const count = received.length;
    expect((await local(socket, "/model/v1/chat/completions", { ...request, model: "unapproved-model" })).status).toBe(403);
    expect((await local(socket, "/arbitrary-host/path", request)).status).toBe(403);
    expect(await absoluteTarget(socket)).toBe(403);
    const envelope = (params = {}) => ({ payload: JSON.stringify({ version: "omos.company/v1", workspace: "workspace", actor: "worker", grant: "grant", action: "read", view: "view", ...params }), signature: "fixture-signature" });
    expect((await local(socket, "/company/v1/company", envelope({ actor: "other-actor" }))).status).toBe(403);
    expect((await local(socket, "/company/v1/company", envelope({ view: "other-view" }))).status).toBe(403);
    expect((await local(socket, "/company/v1/company", envelope({ action: "delegate" }))).status).toBe(403);
    expect(received).toHaveLength(count);
    expect((await local(socket, "/company/v1/company", envelope(), { authorization: "Bearer caller" })).status).toBe(200);
    expect(received.at(-1)).toMatchObject({ path: "/company", authorization: null, cookie: null });
    const failure = await local(socket, "/model/v1/chat/completions", { ...request, messages: [{ role: "user", content: "reject" }] });
    expect(failure.status).toBe(401); expect(failure.text).not.toContain("fixture-private");
    expect(JSON.parse((await local(socket, "/model/v1/models")).text).data).toEqual([{ id: "worker-model" }]);
  } finally { await broker.close(); upstream.stop(true); }
});

test("worker broker stops accepting calls after its invocation request budget", async () => {
  const f = fixture(), socket = join(f.home, "broker.sock");
  const broker = await createWorkerBroker({ socket, expiresMs: Date.now() + 60000, maxRequests: 2, model: { endpoint: "http://127.0.0.1:1/model", handle: "worker", model: "provider" }, company: { endpoint: "http://127.0.0.1:1/company", workspace: "workspace", actor: "actor", grant: "grant", actions: ["status"] } });
  try {
    expect((await local(socket, "/model/v1/models")).status).toBe(200);
    expect((await local(socket, "/model/v1/models")).status).toBe(200);
    const exhausted = await local(socket, "/model/v1/models");
    expect(exhausted.status).toBe(429); expect(exhausted.text).toContain("WorkerBrokerBudgetExceeded");
  } finally { await broker.close(); }
});

test("worker invocation expiry closes an incomplete request body", async () => {
  const f = fixture();
  const socket = join(f.home, "expiring-broker.sock");
  const broker = await createWorkerBroker({ socket, expiresMs: Date.now() + 500, model: { endpoint: "http://127.0.0.1:1/model", handle: "worker", model: "provider" }, company: { endpoint: "http://127.0.0.1:1/company", workspace: "workspace", actor: "actor", grant: "grant", actions: ["status"] } });
  let client: net.Socket | undefined;
  try {
    const started = Date.now();
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { client?.destroy(); reject(Error("Expired request remained open")); }, 3000);
      client = net.createConnection({ path: socket }, () => client!.write('POST /model/v1/chat/completions HTTP/1.1\r\nHost: worker\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n{"model":'));
      client.on("data", () => {});
      client.once("error", reject);
      client.once("close", () => { clearTimeout(timer); resolve(); });
    });
    expect(Date.now() - started).toBeLessThan(2500);
  } finally { client?.destroy(); await broker.close(); }
});

test("a broker socket shared with an isolated UID requires a private host directory boundary", async () => {
  await expect(createWorkerBroker({ socket: "/tmp/omos-public-broker-" + crypto.randomUUID(), socketMode: 0o666, expiresMs: Date.now() + 60000, model: { endpoint: "http://127.0.0.1:1/model", handle: "worker", model: "provider" }, company: { endpoint: "http://127.0.0.1:1/company", workspace: "workspace", actor: "actor", grant: "grant", actions: ["status"] } })).rejects.toThrow("WorkerBrokerSocketBoundaryRequired");
});

test("native managed turns use the Unix worker broker for planning, tools and independent publication", async () => {
  const f = fixture();
  const inference = model(f, (_body, count) => count === 1 ? writeMemory("Retain the worker checkpoint.") : { content: "Saved the worker checkpoint." });
  const settingsFile = join(f.home, ".fx/settings.json"), settings = JSON.parse(readFileSync(settingsFile, "utf8"));
  const provider = settings.providers.local.base_url;
  settings.providers.local.base_url = "http://127.0.0.1/model/v1";
  writeFileSync(settingsFile, JSON.stringify(settings));
  const socket = join(f.home, "broker.sock");
  const broker = await createWorkerBroker({ socket, expiresMs: Date.now() + 120000, model: { endpoint: provider + "/chat/completions", handle: "fixture-model", model: "fixture-model" }, company: { endpoint: "http://127.0.0.1:1/company", workspace: "workspace", actor: "actor", grant: "grant", actions: ["status"] } });
  try {
    expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
    const result = await f.run(["ask", "Save the worker checkpoint in memory.", "--json"], { OMOS_WORKER_BROKER: socket });
    expect(result.code, result.stderr + result.stdout).toBe(0);
    expect(result.stderr).not.toMatch(/panic:|error:|request failed/);
    expect(inference.counts().actors).toBe(2); expect(inference.counts().assessments).toBeGreaterThan(0);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Retain the worker checkpoint.");
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { await broker.close(); }
}, 180000);

test("the Linux worker launcher reports required kernel and namespace availability explicitly", () => {
  if (process.platform === "linux" && process.env.OMOS_E2E_REQUIRE_WORKER_NAMESPACES === "1") {
    expect(probeResult?.status, probeResult?.stderr).toBe(0);
    expect(support).toMatchObject({ kernel_supported: true, private_namespaces: true });
  } else if (support) expect(typeof support.private_namespaces).toBe("boolean");
});

test.skipIf(!support?.kernel_supported)("Linux workers isolate host content, credentials, networking and descendants while preserving native Fossil publication", async () => {
  const f = fixture();
  const inference = model(f, (_body, count) => {
    if (support.private_namespaces && count === 1) return { tool_calls: [{ index: 0, id: "worker-shell", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", profile: "clean", command: "printf 'isolated-shell-output\\n'", timeout_ms: 10000 } }) } }] };
    if (count === (support.private_namespaces ? 2 : 1)) return writeMemory("Retained inside the isolated worker.");
    return { content: "Saved the isolated worker checkpoint." };
  });
  const settingsFile = join(f.home, ".fx/settings.json"), settings = JSON.parse(readFileSync(settingsFile, "utf8"));
  const provider = settings.providers.local.base_url;
  settings.providers.local.base_url = "http://127.0.0.1/model/v1";
  writeFileSync(settingsFile, JSON.stringify(settings));
  const root = join(f.home, "worker-root"), configuration = join(f.home, "worker-image.json");
  const packagedFossil = join(import.meta.dir, "../../zig-out/libexec/fossil");
  const spec = { root, uid: 1000000 + Number.parseInt(crypto.randomUUID().slice(0, 6), 16) % 14000000, owner: process.getuid!(), entry: "/runtime/bin/python3", namespaces: support.private_namespaces, executable: join(import.meta.dir, "../../zig-out/bin/fx"), fossil: existsSync(packagedFossil) ? packagedFossil : Bun.which("fossil"), profile: join(f.home, ".fx") };
  const image = (action?: string, entry?: string, namespaces?: boolean) => {
    writeFileSync(configuration, JSON.stringify({ ...spec, ...(action ? { action } : {}), ...(entry ? { entry } : {}), ...(namespaces !== undefined ? { namespaces } : {}) }));
    return spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", rootFixture, configuration], { encoding: "utf8", timeout: 120000 });
  };
  const staged = image();
  expect(staged.status, staged.stderr).toBe(0);
  let broker;
  try {
    const checked = image("probe");
    expect(checked.status, checked.stderr).toBe(0);
    const report = JSON.parse(checked.stdout);
    expect(report.code, report.stderr).toBe(0); expect(report.abstract_connected).toBe(false);
    const observed = JSON.parse(report.stdout);
    expect(observed).toMatchObject({ uid: spec.uid, cwd: "/workspace", authorized: "authorized input", private_environment: false, inherited_host_file: false, capabilities_cleared: true });
    expect(observed.host_read).not.toBe("unexpected-success"); expect(observed.abstract).not.toBe("unexpected-success");
    expect(observed.tcp).toBe(1); expect(observed.root_restore).toBe(1);
    const selected = image("entry", "/runtime/bin/omos");
    expect(selected.status, selected.stderr).toBe(0);
    broker = await createWorkerBroker({ socket: root + "/run/omos-broker.sock", socketMode: 0o666, expiresMs: Date.now() + 120000, model: { endpoint: provider + "/chat/completions", handle: "fixture-model", model: "fixture-model", credential: "fixture-host-provider" }, company: { endpoint: "http://127.0.0.1:1/company", workspace: "workspace", actor: "actor", grant: "grant", actions: ["status"] } });
    const run = async (args: string[]) => {
      const child = Bun.spawn(["sudo", "-n", "/usr/bin/python3", "-I", launcher, root, "--", ...args], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      return { code, stdout, stderr };
    };
    const result = await run(["ask", "Save the isolated worker checkpoint in memory.", "--json"]);
    expect(result.code, result.stderr + result.stdout).toBe(0);
    expect(result.stderr).not.toMatch(/panic:|Isolated worker.*failed/);
    const completed = JSON.parse(result.stdout);
    expect(completed.tool_calls.find((tool: any) => tool.name === "fossil_workspace").status).toBe("success");
    if (support.private_namespaces) expect(completed.tool_calls.find((tool: any) => tool.name === "shell").status).toBe("success");
    expect(inference.counts().assessments).toBeGreaterThan(0);
    if (!support.private_namespaces) {
      expect(image("namespaces", undefined, true).status).toBe(0);
      const before = inference.counts();
      const unavailable = await run(["ask", "Do not run without private namespaces.", "--json"]);
      expect(unavailable.code).toBe(125); expect(unavailable.stdout).toBe("");
      expect(unavailable.stderr).toContain("private namespaces unavailable");
      expect(inference.counts()).toEqual(before);
      expect(image("namespaces", undefined, false).status).toBe(0);
    }
    const verified = await run(["fossil", "verify", "--json"]);
    expect(verified.code, verified.stderr).toBe(0);
    expect(JSON.parse(verified.stdout).files).toContain("memory/preference.md");
    const exported = await run(["fossil", "export", "/workspace/portable-worker.fossil", "--json"]);
    expect(exported.code, exported.stderr).toBe(0);
  } finally {
    if (broker) await broker.close();
    const removed = image("remove");
    expect(removed.status, removed.stderr).toBe(0);
  }
}, 240000);


test("host-held company keys bind native worker MCP calls to one view and execution generation", async () => {
  const f = fixture();
  const hostInference = model(f, () => { throw Error("The company host must not run actor tools"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (body: object) => {
    const file = join(f.home, "operator.json");
    writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
    const result = await f.run(["fossil", "company", file, "--json"]);
    expect(result.code, result.stderr).toBe(0);
    return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "broker-worker", "--json"]);
  expect(keyed.code, keyed.stderr).toBe(0);
  const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "checkpoint", "read", "status", "reconcile", "execution", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "hosted-worker", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true);
  let owner, bound, broker;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "company-client.json");
    writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "hosted-worker", key_handle: "broker-worker", actions }), { mode: 0o600 });
    owner = await createCompanyClient(config, { home: f.home });
    const args = (action: string, rest: object = {}) => ({ version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest });
    const value = async (client: any, input: object) => {
      const result = await client.call("company_workspace", input);
      expect(result.isError, JSON.stringify(result)).not.toBe(true);
      return JSON.parse(result.content[0].text);
    };
    const first = await value(owner, args("create_view", { revision: boot.revision, objective: "Save the team worker document" }));
    const otherOperation = args("create_view", { revision: boot.revision, objective: "Keep another private team view" });
    const other = await value(owner, otherOperation);
    const scopedMismatch = await owner.call("company_workspace", args("status", { view: first.view, outcome: otherOperation.operation }));
    expect(scopedMismatch.isError).toBe(true);
    const recoveredMismatch = await owner.call("company_workspace", args("reconcile", { view: first.view, outcome: otherOperation.operation }));
    expect(recoveredMismatch.isError).toBe(true);
    expect((await value(owner, args("status", { view: other.view, outcome: otherOperation.operation }))).state).toBe("completed");
    const execution = { runtime: "hosted-test", generation: 1 };
    await value(owner, args("execution", { view: first.view, revision: first.revision, execution: { ...execution, generation: 0 }, execution_change: "claim", execution_lease_ms: 240000 }));
    const expiresMs = Date.now() + 210000;
    bound = await createCompanyClient(config, { home: f.home, binding: { view: first.view, execution, expiresMs, actions: ["checkpoint", "read", "status", "reconcile", "submit"] } });
    expect(Object.keys(bound)).not.toContain("key");
    const advertised = bound.tools();
    expect(advertised[1].inputSchema.properties.view).toBeUndefined();
    expect(advertised[1].inputSchema.properties.execution).toBeUndefined();
    expect(advertised[1].inputSchema.properties.action.enum).not.toContain("execution");
    advertised[1].inputSchema.properties.action.enum.push("create_view");
    expect(bound.tools()[1].inputSchema.properties.action.enum).not.toContain("create_view");
    for (const input of [args("status", { view: other.view }), args("status", { execution }), args("status", { outcome: "another-runtime-operation" }), args("create_view", { revision: boot.revision })]) {
      const denied = await bound.call("company_workspace", input);
      expect(JSON.parse(denied.content[0].text).error).toBe("CompanyWorkerScopeDenied");
    }
    const worker = fixture();
    const operation = args("checkpoint", { revision: first.revision, path: "documents/team/worker.txt", content: "Saved through the host-owned scoped MCP client." });
    const tool = (name: string, input: object) => ({ tool_calls: [{ index: 0, id: crypto.randomUUID(), type: "function", function: { name, arguments: JSON.stringify(input) } }] });
    const inference = model(worker, (_body, count) => count === 1 ? tool("mcp_select_tool", { name: "mcp_company_company_workspace" }) : count === 2 ? tool("mcp_company_company_workspace", operation) : { content: "Checkpointed the team document." });
    const settingsFile = join(worker.home, ".fx/settings.json"), settings = JSON.parse(readFileSync(settingsFile, "utf8"));
    const provider = settings.providers.local.base_url;
    settings.providers.local.base_url = "http://127.0.0.1/model/v1";
    writeFileSync(settingsFile, JSON.stringify(settings));
    writeFileSync(join(worker.home, ".fx/mcp.json"), JSON.stringify({ mcp: { company: { type: "http", url: "http://127.0.0.1:1/company/mcp", required: true, startup_timeout_ms: 5000, operation_timeout_ms: 30000 } } }));
    const socket = join(worker.home, "scoped-broker.sock");
    broker = await createWorkerBroker({ socket, companyClient: bound, expiresMs, model: { endpoint: provider + "/chat/completions", handle: "fixture-model", model: "fixture-model", credential: "provider-only-host-secret" }, company: { endpoint: service.url + "/v1/company", workspace: boot.workspace, actor: "worker", grant: "hosted-worker", view: first.view, actions: bound.scope!.actions } });
    const seen: object[] = [];
    broker.server.on("request", (request: any) => {
      const item = { method: request.method, url: request.url, body: "" }; seen.push(item);
      request.on("data", (chunk: Buffer) => { if (item.body.length < 65536) item.body += chunk.toString(); });
    });
    const initialized = await local(socket, "/company/mcp", { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25" } });
    expect(JSON.parse(initialized.text).result.serverInfo.name).toBe("omos-company-worker");
    const modern = await local(socket, "/company/mcp", { jsonrpc: "2.0", id: 2, method: "server/discover", params: { _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } });
    expect(modern.status).toBe(400);
    expect(JSON.parse(modern.text).error.data).toEqual({ supported: ["2025-11-25", "2025-06-18"], requested: "2026-07-28" });
    const result = await worker.run(["ask", "Checkpoint the team document through company_workspace.", "--json"], { OMOS_WORKER_BROKER: socket });
    expect(result.code, result.stderr + result.stdout + JSON.stringify(seen)).toBe(0);
    expect(result.stderr).not.toMatch(/panic:|request failed/);
    const completed = JSON.parse(result.stdout);
    expect(completed.tool_calls.find((item: any) => item.name === "mcp_company_company_workspace").status).toBe("success");
    expect(inference.counts().actors).toBe(3);
    expect(existsSync(join(worker.home, ".fx/company-keys"))).toBe(false);
    expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/worker.txt");
    const checkpoint = await value(bound, args("status"));
    const read = await value(bound, args("read", { revision: checkpoint.revision, path: "documents/team/worker.txt" }));
    expect(Buffer.from(read.content, "base64").toString()).toBe(operation.content);
    const replay = await value(bound, operation);
    expect(replay.revision).toBe(checkpoint.revision);
    const scopedOutcome = await value(bound, args("status", { outcome: operation.operation }));
    expect(scopedOutcome.state).toBe("completed");
    const untouched = await value(owner, args("status", { view: other.view }));
    expect(untouched.revision).toBe(other.revision);
    if (support?.kernel_supported) {
      await broker.close(); broker = null;
      const profile = join(worker.home, "isolated-profile"); mkdirSync(profile);
      for (const file of ["settings.json", "mcp.json"]) writeFileSync(join(profile, file), readFileSync(join(worker.home, ".fx", file)));
      const root = join(worker.home, "worker-root"), imageFile = join(worker.home, "scoped-image.json");
      const packagedFossil = join(import.meta.dir, "../../zig-out/libexec/fossil");
      const image = { root, uid: 1000000 + Number.parseInt(crypto.randomUUID().slice(0, 6), 16) % 14000000, owner: process.getuid!(), namespaces: support.private_namespaces, executable: join(import.meta.dir, "../../zig-out/bin/fx"), fossil: existsSync(packagedFossil) ? packagedFossil : Bun.which("fossil"), profile };
      const stage = (action?: string) => {
        writeFileSync(imageFile, JSON.stringify({ ...image, ...(action ? { action } : {}) }));
        return spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", rootFixture, imageFile], { encoding: "utf8", timeout: 120000 });
      };
      const staged = stage();
      expect(staged.status, staged.stderr).toBe(0);
      try {
        // Reuse the exact checkpoint request. The real service must recover its
        // receipt rather than apply the already committed mutation again.
        model(worker, (_body, count) => count === 1 ? tool("mcp_select_tool", { name: "mcp_company_company_workspace" }) : count === 2 ? tool("mcp_company_company_workspace", operation) : { content: "Recovered the same company checkpoint." });
        // A fresh model sequence drives the isolated process through normal
        // discovery and the retained operation; no private seed is staged.
        const secondProfile = JSON.parse(readFileSync(join(worker.home, ".fx/settings.json"), "utf8"));
        const secondProvider = secondProfile.providers.local.base_url;
        broker = await createWorkerBroker({ socket: root + "/run/omos-broker.sock", socketMode: 0o666, companyClient: bound, expiresMs, model: { endpoint: secondProvider + "/chat/completions", handle: "fixture-model", model: "fixture-model", credential: "provider-only-host-secret" }, company: { endpoint: service.url + "/v1/company", workspace: boot.workspace, actor: "worker", grant: "hosted-worker", view: first.view, actions: bound.scope!.actions } });
        const child = Bun.spawn(["sudo", "-n", "/usr/bin/python3", "-I", launcher, root, "--", "ask", "Recover the same team document checkpoint through company_workspace.", "--json"], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
        const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
        expect(code, stderr + stdout).toBe(0);
        expect(JSON.parse(stdout).tool_calls.find((item: any) => item.name === "mcp_company_company_workspace").status).toBe("success");
        expect(existsSync(root + "/home/worker/.fx/company-keys")).toBe(false);
        expect((await value(bound, args("status"))).revision).toBe(checkpoint.revision);
      } finally {
        await broker?.close(); broker = null;
        const removed = stage("remove"); expect(removed.status, removed.stderr).toBe(0);
      }
    }
    const proposal = await value(bound, args("submit", { revision: checkpoint.revision, candidate: "Saved documents/team/worker.txt through the scoped company service." }));
    let accepted: any;
    const deadline = Date.now() + 60000;
    do {
      accepted = await value(bound, args("status"));
      if (!["queued", "running"].includes(accepted.job?.state)) break;
      await Bun.sleep(30);
    } while (Date.now() < deadline);
    expect(accepted.job.id).toBe(proposal.job);
    expect(accepted.job.state, JSON.stringify(accepted)).toBe("published");
    expect(accepted.publication.issuer_proof.signature).toMatch(/^[0-9a-f]{128}$/);
    expect(f.fossil("cat", "documents/team/worker.txt", "-r", "trunk")).toBe(operation.content);
    expect(hostInference.counts().actors).toBe(0);
    expect(hostInference.counts().assessments).toBeGreaterThan(0);
    bound.close();
    const closed = await bound.call("company_workspace", args("status"));
    expect(JSON.parse(closed.content[0].text).error).toBe("CompanyClientClosed");
  } finally {
    await broker?.close(); bound?.close(); owner?.close();
    service.child.kill(); await service.child.exited;
  }
}, 360000);

test("company worker jobs checkpoint dispatch, fence replacement owners and survive portable recovery", async () => {
  const f = fixture();
  let reviews = 0;
  const inference = model(f, () => { throw Error("Job control must not run actor tools"); }, () => ++reviews === 1 ? "blocked" : "met");
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  let owner, service;
  const adminResult = async (body: object, extra: Record<string, string> = {}) => {
    const file = join(f.home, "operator-job.json");
    writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
    return f.run(["fossil", "company", file, "--json"], extra);
  };
  const admin = async (body: object) => {
    const result = await adminResult(body);
    expect(result.code, JSON.stringify(body) + "\n" + result.stderr).toBe(0);
    return JSON.parse(result.stdout).model_data;
  };
  const worker = async (request: object) => admin({ action: "workers", worker: request });
  try {
    const initial = await admin({ action: "initialize" });
    const keyed = await f.run(["fossil", "company-key", "job-worker", "--json"]);
    expect(keyed.code, keyed.stderr).toBe(0);
    const key = JSON.parse(keyed.stdout);
    const actions = ["create_view", "checkpoint", "read", "status", "reconcile", "execution", "submit"];
    await admin({ action: "grant", revision: initial.revision, grant: { id: "job-worker", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
    service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "job-client.json");
    writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "job-worker", key_handle: "job-worker", actions }), { mode: 0o600 });
    owner = await createCompanyClient(config, { home: f.home });
    const args = (action: string, rest: object = {}) => ({ version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest });
    const send = async (input: object) => {
      const response = await owner.call("company_workspace", input);
      expect(response.isError, JSON.stringify(response)).not.toBe(true);
      return JSON.parse(response.content[0].text);
    };
    const view = await send(args("create_view", { revision: boot.revision, objective: "Retain documents/team/job.txt through a recoverable worker job" }));
    expect((await worker({ change: "inspect" })).jobs).toHaveLength(0);
    const queuedRequest = { change: "queue", operation: crypto.randomUUID(), view: view.view, max_invocations: 3, max_runtime_ms: 10000 };
    let current = (await worker(queuedRequest)).jobs[0];
    expect(current.record.state).toBe("queued");
    expect(current.record.binding.contract_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(current.contract.objective).toContain("documents/team/job.txt");
    expect((await worker(queuedRequest)).replayed).toBe(true);
    const first = { runtime: "job-first", generation: 0 };
    current = (await worker({ change: "claim", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: first })).jobs[0];
    expect(current.record).toMatchObject({ state: "running", invocations: 1, runtime: "job-first", generation: 1 });
    expect(current.execution.generation).toBe(1);
    const falseCompletion = await adminResult({ action: "workers", worker: { change: "complete", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256 } });
    expect(falseCompletion.code).not.toBe(0); expect(falseCompletion.stderr).toContain("WorkspaceVerificationFailed");
    expect((await worker({ change: "inspect", view: view.view })).jobs[0].sha256).toBe(current.sha256);
    const oldFence = { runtime: "job-first", generation: 1 };
    const checkpoint = await send(args("checkpoint", { view: view.view, revision: view.revision, execution: oldFence, path: "documents/team/job.txt", content: "The first retained worker checkpoint." }));
    current = (await worker({ change: "finish", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: oldFence, outcome: "waiting", note: "Waiting for a new invocation." })).jobs[0];
    expect(current.record.state).toBe("waiting");
    expect(current.execution.runtime).toBeNull();
    const stale = await owner.call("company_workspace", args("checkpoint", { view: view.view, revision: checkpoint.revision, execution: oldFence, path: "documents/team/job.txt", content: "A stale worker must not write this." }));
    expect(stale.isError).toBe(true);
    current = (await worker({ change: "requeue", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256 })).jobs[0];
    const secondClaim = { change: "claim", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: { runtime: "job-second", generation: 1 } };
    const interrupted = await adminResult({ action: "workers", worker: secondClaim }, { FX_E2E_FOSSIL_FAULT: "company-execution-committed" });
    expect(interrupted.code).not.toBe(0);
    current = (await worker({ change: "inspect", view: view.view })).jobs[0];
    expect(current.record).toMatchObject({ state: "running", invocations: 2, runtime: "job-second", generation: 2 });
    expect(current.execution).toMatchObject({ runtime: "job-second", generation: 2 });
    expect(current.record.request).toMatchObject(secondClaim);
    const replay = await worker(secondClaim);
    expect(replay.replayed).toBe(true); expect(replay.jobs[0].record.invocations).toBe(2);
    const different = await adminResult({ action: "workers", worker: { ...secondClaim, execution: { runtime: "invented", generation: 1 } } });
    expect(different.code).not.toBe(0); expect(different.stderr).toContain("CompanyOperationConflict");
    const secondFence = { runtime: "job-second", generation: 2 };
    const waitReview = async () => {
      const deadline = Date.now() + 60000;
      let result: any;
      do {
        result = await send(args("status", { view: view.view }));
        if (!["queued", "running"].includes(result.job?.state)) break;
        await Bun.sleep(30);
      } while (Date.now() < deadline);
      return result;
    };
    const held = await send(args("submit", { view: view.view, revision: checkpoint.revision, execution: secondFence, candidate: "Retained documents/team/job.txt from the worker checkpoint." }));
    const needsRevision = await waitReview();
    expect(needsRevision.job.id).toBe(held.job); expect(needsRevision.job.state).not.toBe("published");
    expect(needsRevision.state).not.toBe("accepted"); expect(needsRevision.publication).toBeNull();
    current = (await worker({ change: "finish", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: secondFence, outcome: "submitted" })).jobs[0];
    expect(current.record.state).toBe("submitted"); expect(current.execution.runtime).toBeNull();
    current = (await worker({ change: "requeue", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256 })).jobs[0];
    current = (await worker({ change: "claim", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: { runtime: "job-third", generation: 2 } })).jobs[0];
    expect(current.record).toMatchObject({ state: "running", invocations: 3, generation: 3 });
    const delayed = await worker(secondClaim);
    expect(delayed.replayed).toBe(true); expect(delayed.jobs[0].record.generation).toBe(2);
    expect(delayed.jobs[0].execution.generation).toBe(3);
    expect((await worker({ change: "inspect", view: view.view })).jobs[0].record.generation).toBe(3);
    const earlyExpiry = await adminResult({ action: "workers", worker: { change: "expire", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256 } });
    expect(earlyExpiry.code).not.toBe(0); expect(earlyExpiry.stderr).toContain("CompanyWorkerNotExpired");
    const submitted = await send(args("submit", { view: view.view, revision: needsRevision.revision, execution: { runtime: "job-third", generation: 3 }, candidate: "Retained the document and resolved its pending verification in a new invocation." }));
    const accepted = await waitReview();
    expect(accepted.job.id).toBe(submitted.job); expect(accepted.job.state).toBe("published");
    expect(accepted.state).toBe("accepted");
    expect(accepted.publication.issuer_proof.signature).toMatch(/^[0-9a-f]{128}$/);
    current = (await worker({ change: "complete", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256 })).jobs[0];
    expect(current.record.state).toBe("completed"); expect(current.execution.runtime).toBeNull();
    expect(current.publication.issuer_proof.signature).toMatch(/^[0-9a-f]{128}$/);
    expect(f.fossil("cat", "documents/team/job.txt", "-r", "trunk")).toBe("The first retained worker checkpoint.");
    expect(inference.counts().actors).toBe(0); expect(inference.counts().assessments).toBeGreaterThan(0);
    const latest = await (await fetch(service.url + "/v1/company")).json() as any;
    const cancellable = await send(args("create_view", { revision: latest.revision, objective: "Retain a cancelled worker job without further actor execution" }));
    let cancellation = (await worker({ change: "queue", operation: crypto.randomUUID(), view: cancellable.view, max_invocations: 1, max_runtime_ms: 1000 })).jobs[0];
    cancellation = (await worker({ change: "claim", operation: crypto.randomUUID(), view: cancellable.view, expected_sha256: cancellation.sha256, execution: { runtime: "cancelled-worker", generation: 0 } })).jobs[0];
    const beforeRevocation = await admin({ action: "status" });
    await admin({ action: "revoke", revision: beforeRevocation.revision, id: "job-worker" });
    cancellation = (await worker({ change: "cancel", operation: crypto.randomUUID(), view: cancellable.view, expected_sha256: cancellation.sha256, note: "Cancelled after actor authority was revoked." })).jobs[0];
    expect(cancellation.record.state).toBe("cancelled");
    expect(cancellation.execution.runtime).toBeNull(); expect(cancellation.authority_live).toBe(false);
    const verified = await f.run(["fossil", "verify", "--json"]);
    expect(verified.code, verified.stderr).toBe(0);
    const portable = join(f.home, "company-jobs.fossil");
    const exported = await f.run(["fossil", "export", portable, "--json"]);
    expect(exported.code, exported.stderr).toBe(0);
    service.child.kill(); await service.child.exited; service = null;
    const restored = fixture();
    expect((await restored.run(["fossil", "use", portable, "--json"])).code).toBe(0);
    const control = await admin({ action: "status" });
    const rotate = join(restored.home, "rotate.json");
    writeFileSync(rotate, JSON.stringify({ version: "omos.company-admin/v1", action: "rotate", revision: control.revision }));
    const rotated = await restored.run(["fossil", "company", rotate, "--json"]);
    expect(rotated.code, rotated.stderr).toBe(0);
    const inspect = join(restored.home, "inspect-jobs.json");
    writeFileSync(inspect, JSON.stringify({ version: "omos.company-admin/v1", action: "workers", worker: { change: "inspect" } }));
    const recovered = await restored.run(["fossil", "company", inspect, "--json"]);
    expect(recovered.code, recovered.stderr).toBe(0);
    const restoredJobs = JSON.parse(recovered.stdout).model_data.jobs;
    expect(restoredJobs).toHaveLength(2);
    const retained = restoredJobs.find((item: any) => item.record.id === current.record.id);
    expect(restoredJobs.find((item: any) => item.record.id === cancellation.record.id).record).toEqual(cancellation.record);
    expect(retained.record).toEqual(current.record);
    expect(retained.contract).toBeNull(); expect(retained.request).toBeNull(); expect(retained.amendments).toEqual([]);
    expect(retained.authority_live).toBe(false);
    expect(retained.publication).toEqual(current.publication);
    expect((await restored.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally {
    owner?.close(); if (service) { service.child.kill(); await service.child.exited; }
  }
}, 360000);


test("the private worker controller uses verified native job operations and disposable transport files", async () => {
  const f = fixture();
  model(f, () => { throw Error("The control transport must not run actors"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (body: object) => {
    const file = join(f.home, "control-operator.json");
    writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
    const result = await f.run(["fossil", "company", file, "--json"]);
    expect(result.code, result.stderr).toBe(0);
    return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyResult = await f.run(["fossil", "company-key", "controller", "--json"]);
  expect(keyResult.code, keyResult.stderr).toBe(0);
  const key = JSON.parse(keyResult.stdout);
  const actions = ["create_view", "execution", "status", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "controller", actor: "controller", public_key: (key.model_data ?? key).public_key, paths: ["documents/"], actions, human_approval: true, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true);
  let signer, control;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "control-client.json");
    writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "controller", grant: "controller", key_handle: "controller", actions }), { mode: 0o600 });
    signer = await createCompanyClient(config, { home: f.home });
    const created = await signer.call("company_workspace", { version: "omos.company/v1", action: "create_view", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, revision: boot.revision, objective: "Retain the native controller invocation." });
    expect(created.isError, JSON.stringify(created)).not.toBe(true);
    const view = JSON.parse(created.content[0].text).view;
    const binary = join(import.meta.dir, "../../zig-out/bin/fx");
    const digest = createHash("sha256");
    for await (const chunk of createReadStream(binary)) digest.update(chunk);
    const settings = { binary, executableSha256: digest.digest("hex"), home: f.home, workspace: f.cwd, workspaceId: boot.workspace };
    await expect(createWorkerControl({ ...settings, executableSha256: "0".repeat(64) })).rejects.toThrow("WorkerControlExecutableChanged");
    control = await createWorkerControl(settings);
    const empty = await control.call({ change: "inspect" });
    expect(empty.ok).toBe(true); expect(empty.jobs).toEqual([]);
    const nodeInput = join(f.home, "node-control.json");
    writeFileSync(nodeInput, JSON.stringify({ ...settings, request: { change: "queue", operation: crypto.randomUUID(), view, max_runtime_ms: 1000 } }), { mode: 0o600 });
    const child = Bun.spawn([process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath, join(import.meta.dir, "fixtures/company-worker-control.mjs"), nodeInput], { env: { HOME: f.home, PATH: process.env.PATH }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    expect(code, stderr + stdout).toBe(0); expect(stderr).toBe("");
    const queue = JSON.parse(stdout);
    expect(queue.ok, JSON.stringify(queue)).toBe(true);
    expect(queue.jobs[0].record.state).toBe("queued");
    const conflict = await control.call({ change: "claim", operation: crypto.randomUUID(), view, expected_sha256: "0".repeat(64), execution: { runtime: "controller", generation: 0 } });
    expect(conflict).toMatchObject({ ok: false, error: "CompanyWorkerJobChanged", uncertain: true });
    const running = await control.call({ change: "claim", operation: crypto.randomUUID(), view, expected_sha256: queue.jobs[0].sha256, execution: { runtime: "controller", generation: 0 } });
    expect(running.ok, JSON.stringify(running)).toBe(true); expect(running.jobs[0].record.generation).toBe(1);
    const cancelled = await control.call({ change: "cancel", operation: crypto.randomUUID(), view, expected_sha256: running.jobs[0].sha256 });
    expect(cancelled.ok).toBe(true); expect(cancelled.jobs[0].record.state).toBe("cancelled");
    const bindingPath = join(f.home, ".fx/omos-workspace.json"), binding = readFileSync(bindingPath);
    try {
      const changed = JSON.parse(binding.toString()); changed.workspace_id = "0".repeat(64);
      writeFileSync(bindingPath, JSON.stringify(changed));
      await expect(control.call({ change: "inspect" })).rejects.toThrow("WorkerControlBindingChanged");
      changed.workspace_id = boot.workspace; changed.repository = join(f.home, "another-company.fossil");
      writeFileSync(bindingPath, JSON.stringify(changed));
      await expect(control.call({ change: "inspect" })).rejects.toThrow("WorkerControlBindingChanged");
    } finally { writeFileSync(bindingPath, binding); }
    const requestRoot = join(f.home, ".fx/worker-control");
    const { readdir } = await import("node:fs/promises");
    expect(await readdir(requestRoot)).toEqual([]);
    expect(statSync(requestRoot).mode & 0o777).toBe(0o700);
    control.close();
    await expect(control.call({ change: "inspect" })).rejects.toThrow("WorkerControlClosed");
    const verified = await f.run(["fossil", "verify", "--json"]);
    expect(verified.code, verified.stderr).toBe(0);
  } finally { control?.close(); signer?.close(); service.child.kill(); await service.child.exited; }
}, 180000);
