import { afterEach, expect, test } from "bun:test";
import http from "node:http";
import net from "node:net";
import { join } from "node:path";
import { existsSync, readFileSync, writeFileSync, statSync, mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { cleanupFixtures, fixture, model, writeMemory, startWorkspaceService } from "./fossil-workspace-helpers";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { createWorkerHttpControl } from "../../deployment/company/worker-http-control.mjs";
import { createWorkerCoordinator } from "../../deployment/company/worker-coordinator.mjs";
import { createWorkerSnapshot } from "../../deployment/company/worker-snapshot.mjs";
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
    expect(image("entry", "/bin/bash").status).toBe(0);
    const shellProbe = spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", launcher, root, "--", "--noprofile", "--norc", "-c", "printf 'verified-bash-runtime\\n'; /usr/bin/env"], { encoding: "utf8", timeout: 20000 });
    expect(shellProbe.status, shellProbe.stderr + shellProbe.stdout).toBe(0);
    expect(shellProbe.stdout).toContain("verified-bash-runtime\n"); expect(shellProbe.stdout).toContain("SHELL=/bin/bash");
    expect(shellProbe.stdout).not.toContain("OMOS_TEST_PRIVATE_TOKEN");
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
    if (support.private_namespaces) expect(completed.tool_calls.find((tool: any) => tool.name === "shell").status, JSON.stringify(completed.tool_calls)).toBe("success");
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
    const remoteControl = createWorkerHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    const remote = await remoteControl.call({ change: "inspect", view });
    expect(remote.ok, JSON.stringify(remote)).toBe(true); expect(remote.jobs[0].record.state).toBe("queued");
    const ownerEnvelope = { version: "omos.company-worker-api/v1", workspace: boot.workspace, request: { change: "inspect" } };
    const deniedOwnerRequest = (headers: Record<string, string>) => new Promise<number>((resolve, reject) => {
      const body = JSON.stringify(ownerEnvelope);
      const request = http.request(service.url + "/v1/company/workers", { method: "POST", agent: false, headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body), connection: "close", ...headers } }, response => {
        response.resume(); response.once("end", () => resolve(response.statusCode!)); response.once("error", reject);
      });
      request.once("error", reject); request.end(body);
    });
    expect(await deniedOwnerRequest({})).toBe(401);
    expect(await deniedOwnerRequest({ ...service.headers, origin: "https://untrusted.example" })).toBe(401);
    const wrongWorkspace = createWorkerHttpControl({ endpoint: service.url, workspaceId: "0".repeat(64), token: service.headers.authorization.slice(7) });
    expect(await wrongWorkspace.call({ change: "inspect" })).toMatchObject({ ok: false, error: "WorkspaceIdentityMismatch" });
    wrongWorkspace.close();
    let invoked = 0;
    const coordinator = createWorkerCoordinator({ control: remoteControl, runtime: "controller", backend: { async run(row, signal) {
      invoked++; expect(signal.aborted).toBe(false);
      expect(row.record.binding.view).toBe(view); expect(row.contract).toBeDefined(); expect(row.request).toBeDefined();
      expect(row.execution).toMatchObject({ runtime: "controller", generation: 1 });
      return { outcome: "waiting", note: "Stopped after inspecting the immutable native job context." };
    } } });
    expect((await coordinator.tick()).started).toBe(1);
    await coordinator.drain();
    const running = await control.call({ change: "inspect", view });
    expect(running.ok, JSON.stringify(running)).toBe(true); expect(running.jobs[0].record.generation).toBe(1);
    expect(running.jobs[0].record.state).toBe("waiting"); expect(running.jobs[0].execution.runtime).toBeNull();
    expect((await coordinator.tick()).started).toBe(0); expect(invoked).toBe(1);
    await coordinator.close(); remoteControl.close();
    const cancelled = await control.call({ change: "cancel", operation: crypto.randomUUID(), view, expected_sha256: running.jobs[0].sha256 });
    expect(cancelled.ok).toBe(true); expect(cancelled.jobs[0].record.state).toBe("cancelled");
    const readonly = await startWorkspaceService(f, false);
    const readonlyControl = createWorkerHttpControl({ endpoint: readonly.url, workspaceId: boot.workspace, token: readonly.headers.authorization.slice(7) });
    try {
      expect((await readonlyControl.call({ change: "inspect", view })).ok).toBe(true);
      expect(await readonlyControl.call({ change: "queue", operation: crypto.randomUUID(), view })).toMatchObject({ ok: false, error: "ServiceReadOnly" });
    } finally { readonlyControl.close(); readonly.child.kill(); await readonly.child.exited; }
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

test("local read-only workspace requests page immutable file identities and complete binary contents", async () => {
  const f = fixture();
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const tree = join(f.home, "snapshot-checkout"); mkdirSync(tree);
  const fossil = (...args: string[]) => {
    const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
  };
  fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
  const documents = join(tree, "documents/snapshot"); mkdirSync(documents, { recursive: true });
  for (let index = 0; index < 35; index++) writeFileSync(join(documents, `f${String(index).padStart(2, "0")}.txt`), `file ${index}`);
  writeFileSync(join(documents, "run.sh"), "#!/bin/sh\nprintf snapshot\n", { mode: 0o755 });
  writeFileSync(join(documents, "binary.dat"), Buffer.concat(Array.from({ length: 70 }, () => Buffer.from(Array.from({ length: 256 }, (_, index) => index)))));
  writeFileSync(join(documents, "text.txt"), "€".repeat(6000));
  mkdirSync(join(tree, "ui")); writeFileSync(join(tree, "ui/snapshot.css"), "body { color: green; }");
  const commit = () => {
    fossil("addremove");
    fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain immutable reader fixture");
  };
  commit();
  const state = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
  const declaration = JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data;
  const base = { version: "omos.workspace-api/v1", workspace: state.workspace_id, definition_hash: declaration.basis.definition_hash, revision: state.trunk_revision };
  const call = async (input: object, successful = true) => {
    const envelope = { ...base, ...input };
    if ((input as any).action === "head") delete (envelope as any).revision;
    const file = join(f.home, "workspace-read.json"); writeFileSync(file, JSON.stringify(envelope));
    const result = await f.run(["fossil", "request", file, "--json"]);
    if (!successful) { expect(result.code).not.toBe(0); return result; }
    expect(result.code, result.stderr + result.stdout).toBe(0);
    return JSON.parse(result.stdout);
  };
  const head = await call({ action: "head" });
  expect(head.data).toEqual({ revision: base.revision, task: null, definition_hash: base.definition_hash });
  const first = await call({ action: "inventory", path: "documents/snapshot/" });
  expect(first.data.files).toHaveLength(32); expect(first.data.total).toBe(38); expect(first.data.next_offset).toBe(32);
  const second = await call({ action: "inventory", path: "documents/snapshot/", offset: first.data.next_offset });
  expect(second.data.files).toHaveLength(6); expect(second.data.next_offset).toBeNull();
  const files = [...first.data.files, ...second.data.files];
  expect(new Set(files.map(item => item.path)).size).toBe(38);
  expect(files.find(item => item.path.endsWith("/run.sh")).executable).toBe(true);
  const ui = await call({ action: "inventory", path: "ui/" });
  expect(ui.data.files.map((item: any) => item.path)).toContain("ui/snapshot.css");
  for (const [name, expected] of [["binary.dat", Buffer.concat(Array.from({ length: 70 }, () => Buffer.from(Array.from({ length: 256 }, (_, index) => index))))], ["text.txt", Buffer.from("€".repeat(6000))]] as const) {
    const parts: Buffer[] = []; let offset = 0;
    do {
      const page = (await call({ action: "read", path: `documents/snapshot/${name}`, offset })).data;
      expect(page.offset).toBe(offset); expect(page.bytes).toBe(expected.length);
      expect(page.sha256).toBe(createHash("sha256").update(expected).digest("hex"));
      const bytes = Buffer.from(page.content, page.encoding);
      expect(bytes.length).toBeLessThanOrEqual(16384); parts.push(bytes);
      if (page.next_offset === null) break;
      expect(page.next_offset).toBe(offset + bytes.length); offset = page.next_offset;
    } while (offset < expected.length);
    expect(Buffer.concat(parts)).toEqual(expected);
    const file = files.find(item => item.path === `documents/snapshot/${name}`);
    expect(file.artifact).toBe(createHash(file.artifact.length === 40 ? "sha1" : "sha3-256").update(expected).digest("hex"));
  }
  const snapshot = createWorkerSnapshot({ request: input => call(input), workspace: base.workspace, definitionHash: base.definition_hash, revision: base.revision });
  const inventory = await snapshot.inventory();
  expect(inventory.filter(file => file.path.startsWith("documents/snapshot/"))).toHaveLength(38);
  const verifiedBinary = await snapshot.read("documents/snapshot/binary.dat");
  expect(verifiedBinary.bytes).toBe(17920);
  expect(verifiedBinary.content).toEqual(readFileSync(join(documents, "binary.dat")));
  expect(verifiedBinary.sha256).toBe(createHash("sha256").update(verifiedBinary.content).digest("hex"));
  await expect(snapshot.read("history/private.json")).rejects.toThrow("WorkerSnapshotPathDenied");
  const denied = await call({ action: "record", entity: "arbitrary", content: "{}" }, false);
  expect(denied.stderr).toContain("ServiceReadOnly");
  expect((await call({ action: "inventory", path: "documents/../" }, false)).stderr).toContain("WorkspacePathDenied");
  expect((await call({ action: "inventory", revision: "trunk" }, false)).stderr).toContain("InvalidFossilRevision");
  expect(JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).trunk_revision).toBe(base.revision);
  writeFileSync(join(documents, "f00.txt"), "changed");
  const { chmodSync } = await import("node:fs"); chmodSync(join(documents, "run.sh"), 0o600);
  commit();
  const latest = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).trunk_revision;
  expect(latest).not.toBe(base.revision);
  const retained = await call({ action: "inventory", path: "documents/snapshot/" });
  expect(retained.revision).toBe(base.revision); expect(retained.data.revision).toBe(base.revision); expect(retained.data.files).toEqual(first.data.files);
  const latestFiles = await call({ action: "inventory", path: "documents/snapshot/", revision: latest });
  expect(latestFiles.data.files.find((item: any) => item.path.endsWith("/f00.txt")).artifact).not.toBe(files.find(item => item.path.endsWith("/f00.txt")).artifact);
  expect((await call({ action: "read", path: "documents/snapshot/f00.txt" })).data.content).toBe("file 0");
  expect((await call({ action: "read", path: "documents/snapshot/f00.txt", revision: latest })).data.content).toBe("changed");
  expect((await call({ action: "inventory", path: "documents/snapshot/run.sh", revision: latest })).data.files[0].executable).toBe(false);
  model(f, (_body, count) => count === 1 ? writeMemory("An unpublished worker checkpoint.") : { content: "Retain the pending reader fixture." }, () => "blocked");
  const pending = await f.run(["ask", "Retain an unpublished reader checkpoint.", "--json"]);
  expect(pending.code).toBe(1);
  const task = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).tasks[0];
  const taskHead = await call({ action: "head", task: task.id });
  expect(taskHead.data.task).toBe(task.id); expect(taskHead.data.revision).not.toBe(latest);
  expect((await call({ action: "read", path: "memory/preference.md", task: task.id, revision: taskHead.data.revision })).data.content).toBe("An unpublished worker checkpoint.");
  expect(f.fossil("ls", "-r", "trunk")).not.toContain("memory/preference.md");

}, 240000);


test("worker snapshot collection rejects incomplete inventories, corrupt pages and exhausted budgets", async () => {
  const workspace = "a".repeat(64), definitionHash = "b".repeat(64), revision = "c".repeat(64);
  const content = Buffer.alloc(17000, 255), sha256 = createHash("sha256").update(content).digest("hex");
  const file = { path: "documents/result.bin", artifact: createHash("sha3-256").update(content).digest("hex"), executable: false };
  const transport = async input => ({ workspace, definition_hash: definitionHash, revision, data: input.action === "inventory"
    ? { revision, files: input.path === "documents/" ? [file] : [], total: input.path === "documents/" ? 1 : 0, next_offset: null }
    : { path: file.path, offset: input.offset, bytes: content.length, sha256, encoding: "base64", content: content.subarray(input.offset, input.offset + 16384).toString("base64"), next_offset: input.offset + 16384 < content.length ? input.offset + 16384 : null } });
  const make = request => createWorkerSnapshot({ request, workspace, definitionHash, revision });
  const valid = make(transport);
  await expect(valid.read(file.path)).rejects.toThrow("WorkerSnapshotInventoryRequired");
  const files = await valid.inventory(); files[0].path = "documents/changed";
  expect((await valid.inventory())[0].path).toBe(file.path);
  expect((await valid.read(file.path)).content).toEqual(content);
  const corrupt = make(async input => { const result = await transport(input); if (input.action === "read") result.data.content = Buffer.alloc(Math.min(16384, content.length - input.offset)).toString("base64"); return result; });
  await corrupt.inventory(); await expect(corrupt.read(file.path)).rejects.toThrow("WorkerSnapshotHashMismatch");
  const wrongRevision = make(async input => ({ ...await transport(input), revision: "d".repeat(64), data: { ...((await transport(input)).data), revision: "d".repeat(64) } }));
  await expect(wrongRevision.inventory()).rejects.toThrow("WorkerSnapshotRevisionChanged");
  const short = make(async input => { const result = await transport(input); if (input.action === "inventory" && input.path === "documents/") result.data.total = 2; return result; });
  await expect(short.inventory()).rejects.toThrow("IncompleteWorkerSnapshotInventory");
  const cursor = make(async input => { const result = await transport(input); if (input.action === "read") result.data.next_offset = 0; return result; });
  await cursor.inventory(); await expect(cursor.read(file.path)).rejects.toThrow("InvalidWorkerSnapshotCursor");
  const budget = createWorkerSnapshot({ request: transport, workspace, definitionHash, revision, maxBytes: content.length - 1 });
  await budget.inventory(); await expect(budget.read(file.path)).rejects.toThrow("InvalidWorkerSnapshotPage");
  const stopped = new AbortController(); stopped.abort();
  await expect(make(transport).inventory(stopped.signal)).rejects.toThrow();
});

test("worker coordinator resolves lost claim acknowledgements and fences revoked or replacement owners", async () => {
  let current: any = { sha256: "a".repeat(64), authority_live: true, contract: {}, request: "Retain a document", basis: {}, grant: {}, execution: null, task_state: "active", review_job_id: null, pending_operation: null, publication: null,
    record: { binding: { view: "view" }, state: "queued", generation: 0, max_runtime_ms: 60000, expires_ms: 0 } };
  const calls: any[] = []; let loseAck = true;
  const control = { async call(input) {
    calls.push(input);
    if (input.change === "inspect") return { ok: true, jobs: [structuredClone(current)], next_offset: null };
    if (input.change === "claim") {
      current.record = { ...current.record, state: "running", runtime: input.execution.runtime, generation: 1, expires_ms: Date.now() + 120000, operation: input.operation };
      current.execution = { runtime: input.execution.runtime, generation: 1 };
      if (loseAck) { loseAck = false; return { ok: false, uncertain: true }; }
    } else if (input.change === "finish") {
      current.record = { ...current.record, state: input.outcome, operation: input.operation };
      current.execution = { ...current.execution, runtime: null };
    }
    return { ok: true, jobs: [structuredClone(current)], next_offset: null };
  } };
  let invoked = 0;
  const coordinator = createWorkerCoordinator({ control, runtime: "coordinator", backend: { async run() { invoked++; return { outcome: "completed" }; } } });
  expect((await coordinator.tick()).started).toBe(1);
  await coordinator.drain();
  expect(invoked).toBe(1); expect(current.record.state).toBe("waiting");
  expect(calls.filter(call => call.change === "claim")).toHaveLength(1);
  expect(calls.filter(call => call.change === "finish")[0].outcome).toBe("waiting");
  expect((await coordinator.tick()).started).toBe(0);
  await coordinator.close();
  current.record.state = "queued"; current.execution = null;
  let observedAbort = false;
  const revoked = createWorkerCoordinator({ control, runtime: "revoked", backend: { async run(_row, signal) {
    await new Promise<void>(resolve => signal.addEventListener("abort", () => { observedAbort = true; resolve(); }, { once: true }));
    return { outcome: "waiting" };
  } } });
  expect((await revoked.tick()).started).toBe(1);
  current.authority_live = false;
  const finishCount = calls.filter(call => call.change === "finish").length;
  await revoked.tick(); await revoked.drain();
  expect(observedAbort).toBe(true);
  expect(calls.filter(call => call.change === "finish")).toHaveLength(finishCount);
  await revoked.close();
  current.authority_live = true; current.record.state = "queued"; current.execution = null;
  let called = false;
  const changed = createWorkerCoordinator({ runtime: "old-owner", backend: { async run() { called = true; } }, control: { async call(input) {
    const response = await control.call(input);
    if (input.change === "claim") response.jobs[0].execution.runtime = "new-owner";
    return response;
  } } });
  await expect(changed.tick()).rejects.toThrow("WorkerCoordinatorClaimChanged");
  expect(called).toBe(false);
  await changed.close();
  current.record.state = "queued"; current.execution = null;
  const releaseCount = calls.filter(call => call.change === "finish").length;
  const uncertain = createWorkerCoordinator({ control, runtime: "cleanup-pending", backend: { async run() {
    const error: any = new Error("WorkerCleanupPending"); error.executionUncertain = true; throw error;
  } } });
  expect((await uncertain.tick()).started).toBe(1); await uncertain.drain();
  expect(current.record.state).toBe("running");
  expect(current.execution.runtime).toBe("cleanup-pending");
  expect(calls.filter(call => call.change === "finish")).toHaveLength(releaseCount);
  expect((await uncertain.tick()).started).toBe(0);
  await uncertain.close();
});

test.skipIf(!support?.kernel_supported)("production worker images pin trusted runtime bytes and reject active deletion or changed identities", async () => {
  const helper = join(import.meta.dir, "fixtures/company-worker-image.py");
  const run = (value: object) => {
    const result = spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", helper], { input: JSON.stringify(value), encoding: "utf8", timeout: 180000 });
    expect(result.status, result.stderr + result.stdout).toBe(0);
    return result.stdout ? JSON.parse(result.stdout) : null;
  };
  const { base } = run({ action: "setup", owner: process.getuid!(), group: process.getgid!() });
  const request = { version: "omos.worker-image-request/v1", action: "prepare", id: createHash("sha256").update(crypto.randomUUID()).digest("hex"), workspace: "a".repeat(64), view: "b".repeat(64), generation: 1, max_runtime_ms: 60000, model: "worker-model" };
  try {
    const prepared = run({ base, action: "invoke", request });
    expect(prepared.code, prepared.stderr).toBe(0);
    const marker = JSON.parse(prepared.stdout);
    expect(marker).toMatchObject({ workspace: request.workspace, view: request.view, generation: 1, executable: "/runtime/bin/omos" });
    expect(marker.root.length + "/run/omos-broker.sock".length).toBeLessThanOrEqual(100);
    const profile = run({ base, action: "profile", request });
    expect(profile.keys).toBe(2);
    expect(profile.settings.providers.worker.auth).toEqual({ type: "none" });
    expect(profile.settings.providers.worker.base_url).toBe("http://127.0.0.1/model/v1");
    expect(profile.mcp.mcp.company.url).toBe("http://127.0.0.1:1/company/mcp");
    expect(profile.marker.namespaces).toBeUndefined();
    expect(profile.directories).toMatchObject({ runtime: 0o755, "runtime/bin": 0o755, home: 0o755, "home/worker": 0o700, "home/worker/.fx": 0o700, run: 0o711, dev: 0o755 });
    expect(run({ base, action: "invoke", request }).stdout).toBe(prepared.stdout);
    const changed = run({ base, action: "invoke", request: { ...request, generation: 2 } });
    expect(changed.code).toBe(125); expect(changed.stderr).toContain("ImageIdentityChanged");
    const model = run({ base, action: "invoke", request: { ...request, model: "other-model" } });
    expect(model.code).toBe(125); expect(model.stderr).toContain("ImageIdentityChanged");
    const crowded = run({ base, action: "invoke", request: { ...request, id: "c".repeat(64) } });
    expect(crowded.code).toBe(125); expect(crowded.stderr).toContain("ImagePoolBudgetExceeded");
    const active = run({ base, action: "active_remove", request });
    expect(active.code).toBe(125); expect(active.stderr).toContain("ImageExecutionActive");
    const stopped = run({ base, action: "quiesce", request });
    expect(stopped.code, stopped.stderr).toBe(0); expect(JSON.parse(stopped.stdout).quiescent).toBe(true); expect(stopped.child_code).toBe(-9);
    const launched = run({ base, action: "launch", request });
    if (support.private_namespaces) {
      expect(launched.code, launched.stderr).toBe(0);
      expect(JSON.parse(launched.stdout).workspace_id).toMatch(/^[0-9a-f]{64}$/);
    } else {
      expect(launched.code).toBe(125); expect(launched.stdout).toBe("");
      expect(launched.stderr).toContain("private namespaces unavailable");
    }
    expect(run({ base, action: "invoke", request: { ...request, action: "remove" } }).code).toBe(0);
    const corrupted = run({ base, action: "corrupt_template", request });
    expect(corrupted.code).toBe(125); expect(corrupted.stderr).toMatch(/UnsafeImageTemplateFile|ImageTemplateChanged/);
    expect(run({ base, action: "invoke", request: { ...request, action: "inspect" } }).stderr).toContain("ImageNotFound");
  } finally { run({ base, action: "cleanup" }); }
}, 240000);

test.skipIf(!support?.kernel_supported)("the production company coordinator runs isolated native work and publishes only independently verified file proposals", async () => {
  const f = fixture(), worker = fixture();
  const host = model(f, () => { throw Error("The company host must never execute the actor"); });
  const inference = model(worker, (_body, count) => count === 1 ? { tool_calls: [{ index: 0, id: "private-output", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "documents/team/production.txt", content: "Retained by the isolated native worker and collected by its host." }) } }] } : { content: "Retained the proposed document in the private Fossil workspace." });
  const provider = JSON.parse(readFileSync(join(worker.home, ".fx/settings.json"), "utf8")).providers.local.base_url;
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => {
    const file = join(f.home, "production-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]);
    expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "production-worker", "--json"]);
  expect(keyed.code, keyed.stderr).toBe(0);
  const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "execution", "status", "read", "checkpoint", "submit", "reconcile", "discover"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "production-worker", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true);
  const imageFixture = join(import.meta.dir, "fixtures/company-worker-image.py");
  const setup = spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", imageFixture], { input: JSON.stringify({ action: "setup", owner: 0, group: 0 }), encoding: "utf8", timeout: 120000 });
  expect(setup.status, setup.stderr).toBe(0);
  const { base } = JSON.parse(setup.stdout);
  let client;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const company = { version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "production-worker", key_handle: "production-worker", actions };
    const file = join(f.home, "production-client.json"); writeFileSync(file, JSON.stringify(company), { mode: 0o600 });
    client = await createCompanyClient(file, { home: f.home });
    const created = await client.call("company_workspace", { version: "omos.company/v1", action: "create_view", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, revision: boot.revision, objective: "Retain documents/team/production.txt with the requested worker checkpoint text." });
    expect(created.isError, JSON.stringify(created)).not.toBe(true);
    const view = JSON.parse(created.content[0].text).view;
    await admin({ action: "workers", worker: { change: "queue", operation: crypto.randomUUID(), view } });
    const settings = { company, key_file: join(f.home, ".fx/company-keys/production-worker.seed"), control: { endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) }, view, model: { endpoint: provider + "/chat/completions", handle: "fixture-model", model: "fixture-model", credential: "fixture-provider-kept-outside-image" } };
    const child = Bun.spawn(["sudo", "-n", "/usr/bin/python3", "-I", imageFixture], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    child.stdin.write(JSON.stringify({ base, action: "backend", settings, node: process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath })); child.stdin.end();
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    expect(code, stderr + stdout).toBe(0); expect(stderr).toBe("");
    const result = JSON.parse(stdout), outcome = JSON.parse(result.stdout);
    const current = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
    if (support.private_namespaces) {
      expect(result.code, result.stderr + result.stdout).toBe(0); expect(result.stderr).toBe("");
      expect(outcome).toMatchObject({ ok: true, started: 1, state: "completed", invocations: 1, generation: 1, published: true });
      expect(result.images).toBe(0);
      expect(current.record.state).toBe("completed"); expect(current.publication).not.toBeNull();
      expect(f.fossil("cat", "documents/team/production.txt", "-r", "trunk")).toBe("Retained by the isolated native worker and collected by its host.");
      expect(inference.counts().actors).toBe(2); expect(host.counts().assessments).toBeGreaterThan(0);
    } else {
      expect(result.code).toBe(1); expect(outcome).toEqual({ ok: false, error: "WorkerPrivateNamespacesRequired" });
      expect(result.images).toBe(0); expect(current.record.state).toBe("queued"); expect(current.record.invocations).toBe(0);
      expect(inference.counts().actors).toBe(0); expect(host.counts().assessments).toBe(0);
    }
    expect(host.counts().actors).toBe(0);
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally {
    client?.close(); service.child.kill(); await service.child.exited;
    const cleaned = spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", imageFixture], { input: JSON.stringify({ base, action: "cleanup" }), encoding: "utf8", timeout: 30000 });
    expect(cleaned.status, cleaned.stderr).toBe(0);
  }
}, 480000);
