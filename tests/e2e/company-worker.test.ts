import { afterEach, expect, test } from "bun:test";
import { companyWorkerScenarios, companyWorkerScenarioName } from "./company-worker-scenarios";
import http from "node:http";
import net from "node:net";
import { join } from "node:path";
import { existsSync, readFileSync, writeFileSync, statSync, mkdirSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { cleanupFixtures, fixture, model, writeMemory, startWorkspaceService } from "./fossil-workspace-helpers";
import { createHash, createPublicKey, generateKeyPairSync, sign, verify, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { createWorkerHttpControl, createEvaluationHttpControl, createRuntimeHttpControl, createArchiveHttpControl, createDesiredHttpControl, createActivityHttpControl, createInputHttpControl } from "../../deployment/company/worker-http-control.mjs";
import { createWorkerCoordinator } from "../../deployment/company/worker-coordinator.mjs";
import { createWorkerSnapshot, selectWorkerRoot, selectWorkerSession } from "../../deployment/company/worker-snapshot.mjs";
import { createWorkerControl } from "../../deployment/company/worker-control.mjs";
import { createCompanyClient } from "../../deployment/company/mcp.mjs";
import { createWorkerBroker } from "../../deployment/company/worker-broker.mjs";
import { validateValidationConfiguration } from "../../deployment/company/worker-validation.mjs";
import { createWorkerCheckpointer } from "../../deployment/company/worker-checkpoint.mjs";
import { retainWorkerArchive, prepareWorkerExport } from "../../deployment/company/worker-archive.mjs";
import { advertiseWorkerRuntime } from "../../deployment/company/worker-runtime.mjs";
import { runWorkerNative, publicWorkerEvents } from "../../deployment/company/worker-native.mjs";

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

test("worker continuation resolves only an exact private session fingerprint", () => {
  const id = "PrivateSession12", fingerprint = createHash("sha256").update(id).digest("hex");
  expect(selectWorkerSession([{ id: "unrelated" }, { id }], fingerprint)).toBe(id);
  for (const sessions of [[], [{ id: fingerprint }], [{ id }, { id }], [{ id: "../" + id }]]) expect(() => selectWorkerSession(sessions, fingerprint)).toThrow("WorkerSessionAmbiguous");
});

test("worker snapshots retain delegated children under exactly one root", () => {
  const root = { id: "a".repeat(64), parent_task_id: null }, child = { id: "b".repeat(64), parent_task_id: root.id }, grandchild = { id: "c".repeat(64), parent_task_id: child.id };
  expect(selectWorkerRoot([child, grandchild, root])).toBe(root);
  for (const tasks of [[], [root, { ...child, parent_task_id: null }], [root, { ...child, parent_task_id: "d".repeat(64) }], [root, { ...child, parent_task_id: grandchild.id }, grandchild], [root, root]]) expect(() => selectWorkerRoot(tasks)).toThrow("WorkerSnapshotAmbiguous");
});

test("worker checkpoint acknowledgements are reconciled before actor dispatch and reject stale owners", async () => {
  const execution = { runtime: "owner", generation: 2 }, checkpoint = { version: "omos.company-worker-checkpoint/v1", runtime: "owner", generation: 2, image: "a".repeat(64), source_revision: "b".repeat(64), model: "fixture-model", phase: "prepared", export_directory: null };
  for (const lost of ["reply", "exception"]) {
    let writes = 0, row: any = { sha256: "c".repeat(64), authority_live: true, record: { state: "running", ...execution } };
    const control = { async call(request: any) {
      if (request.change === "inspect") return { ok: true, jobs: [structuredClone(row)] };
      writes++; row.record = { ...row.record, operation: request.operation, checkpoint: structuredClone(request.checkpoint) };
      if (lost === "exception") throw new Error("AcknowledgementLost");
      return { ok: false, uncertain: true };
    } };
    expect(await createWorkerCheckpointer({ control, view: "view", execution })(checkpoint)).toEqual(checkpoint);
    expect(writes).toBe(1);
    row.record.generation = 3;
    await expect(createWorkerCheckpointer({ control, view: "view", execution })(checkpoint)).rejects.toThrow("WorkerCheckpointFenced"); expect(writes).toBe(1);
  }
  const unchanged = { async call() { return { ok: true, jobs: [{ sha256: "a".repeat(64), authority_live: true, record: { state: "running", ...execution, operation: "another-operation", checkpoint } }] }; } };
  await expect(createWorkerCheckpointer({ control: unchanged, view: "view", execution })(checkpoint)).rejects.toThrow("WorkerCheckpointOutcomeUnknown");
});

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

test("isolated validation configurations pin a template entry and bound operator-selected checks", () => {
  const config = { version: "omos.worker-validation/v1", handle: "company-default", entry: { path: "/bin/bash", sha256: "a".repeat(64) }, checks: [{ id: "behavior", arguments: ["/runtime/bin/python3", "-I", "-c", "assert 2 + 3 == 5"], cwd: "documents/team", timeout_ms: 10000 }] };
  const checked = validateValidationConfiguration(config);
  config.checks[0].arguments[3] = "changed";
  expect(checked.checks[0].arguments[3]).toBe("assert 2 + 3 == 5");
  for (const invalid of [
    { ...checked, entry: { ...checked.entry, path: "/workspace/actor.sh" } },
    { ...checked, entry: { ...checked.entry, sha256: "invalid" } },
    { ...checked, checks: [] },
    { ...checked, checks: [checked.checks[0], checked.checks[0]] },
    { ...checked, checks: [{ ...checked.checks[0], cwd: "../private" }] },
    { ...checked, checks: [{ ...checked.checks[0], timeout_ms: 0 }] },
    { ...checked, checks: [{ ...checked.checks[0], arguments: ["python3"] }] },
  ]) expect(() => validateValidationConfiguration(invalid)).toThrow("InvalidWorkerValidationConfiguration");
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

test("native worker continuation resolves the private session and preserves effects after a pre-answer interruption", async () => {
  const f = fixture();
  let ready: () => void = () => {};
  const waiting = new Promise<void>(resolve => { ready = resolve; });
  let resumedHistory = false, child: ReturnType<typeof spawn> | undefined;
  const inference = model(f, async (body, count, signal) => {
    if (count === 1) return writeMemory("Retained before interruption.");
    if (count === 2) {
      ready();
      await new Promise<void>(resolve => {
        const done = () => { clearTimeout(timer); signal?.removeEventListener("abort", done); resolve(); };
        const timer = setTimeout(done, 120000);
        signal?.addEventListener("abort", done, { once: true });
        if (signal?.aborted) done();
      });
    }
    if (count === 3) {
      expect(body.messages.some(message => message.role === "system" && JSON.stringify(message.content).includes("checkpointedEvidence") && JSON.stringify(message.content).includes("memory/preference.md"))).toBe(true);
      return { tool_calls: [{ index: 0, id: "inspect-retained-memory", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: "memory/preference.md" }) } }] };
    }
    if (count === 4) resumedHistory = body.messages.some(message => message.role === "tool" && JSON.stringify(message.content).includes("Retained before interruption."));
    return { content: "Preserved the completed memory write." };
  });
  const control = { async call(request) { return { ok: true, next_offset: request.action === "inspect" ? 0 : request.offset + request.events.length, ended: false }; } };
  const launch = () => child = spawn(join(import.meta.dir, "../../zig-out/bin/fx"), ["ui-host", "--stdio"], { cwd: f.cwd, env: { ...process.env, ...f.env }, stdio: ["pipe", "pipe", "pipe"] });
  try {
    expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
    const interrupted = runWorkerNative({ launch, control, view: "private-fixture", execution: { runtime: "fixture", generation: 1 }, prompt: "Store the checkpoint and finish.", timeout: 120000 }).catch(error => ({ error: error.message }));
    expect(await Promise.race([waiting.then(() => "waiting"), interrupted])).toBe("waiting");
    child!.kill("SIGKILL"); expect(await interrupted).toMatchObject({ error: "WorkerNativeInvocationStopped" });
    const before = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const sessions = JSON.parse((await f.run(["sessions", "--all", "--json"])).stdout);
    const session = selectWorkerSession(sessions.sessions, before.tasks[0].session);
    expect(session).not.toBe(before.tasks[0].session);
    const resumed = await runWorkerNative({ launch, control, view: "private-fixture", execution: { runtime: "fixture", generation: 2 }, prompt: "Continue from the recorded history. Preserve completed work and return the final answer.", session, timeout: 120000 });
    expect(resumed.code, resumed.stderr).toBe(0); expect(resumed.stderr).toBe(""); expect(resumedHistory).toBe(true); expect(inference.counts().actors).toBe(4);
    const after = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    expect(after.tasks).toHaveLength(1); expect(after.tasks[0].id).toBe(before.tasks[0].id);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Retained before interruption.");
    const recovered = [];
    const replayed = await runWorkerNative({ launch, control: { async call(request) {
      if (request.action === "inspect") return { ok: true, next_offset: 0, ended: false };
      recovered.push(...request.events.map(JSON.parse));
      return { ok: true, next_offset: request.offset + request.events.length };
    } }, view: "private-fixture", execution: { runtime: "collector", generation: 3 }, prompt: "", session, replayOnly: true, timeout: 120000 });
    expect(replayed.code, replayed.stderr).toBe(0); expect(replayed.stderr).toBe(""); expect(inference.counts().actors).toBe(4);
    expect(recovered.some(event => event.type === "tool_start")).toBe(true); expect(recovered.some(event => event.type === "text_delta" && event.text.includes("Preserved the completed memory write."))).toBe(true); expect(recovered.at(-1).type).toBe("turn_end");
    expect(f.fossil("timeline", "ancestors", "trunk", "--type", "ci", "--limit", "1", "--format", "%H").trim().split("\n")[0]).toBe(after.trunk_revision);
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { child?.kill("SIGKILL"); }
}, 300000);

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


test("worker projection reads pin identity and revision without exposing credentials or mutation routes", async () => {
  const f = fixture(), calls: any[] = [];
  const revision = "a".repeat(64), workspace = "b".repeat(64), view = "c".repeat(64), expiresMs = Date.now() + 60000;
  const companyClient = { identity: { workspace, actor: "worker", grant: "grant" }, scope: { view, expiresMs, execution: { runtime: "runtime", generation: 2 }, actions: ["read", "discover"] }, async call(name, input) {
    calls.push({ name, input }); return { content: [{ text: JSON.stringify({ revision, read_tracking: "recorded", files: [], total: 0, next_offset: null }) }] };
  } };
  const socket = join(f.home, "projection.sock");
  const broker = await createWorkerBroker({ socket, expiresMs, companyClient, maxRequests: 1, model: { endpoint: "http://127.0.0.1:1/model", handle: "fixture", model: "fixture" }, company: { endpoint: "http://127.0.0.1:1/company", workspace, actor: "worker", grant: "grant", view, source_revision: revision, actions: ["read", "discover"] } });
  try {
    const first = await local(socket, "/company/projection", { action: "inventory", offset: 0 });
    expect(first.status).toBe(200); expect(JSON.parse(first.text)).toMatchObject({ workspace, view, revision, generation: 2 });
    const second = await local(socket, "/company/projection", { action: "read", path: "documents/team/a.txt", offset: 16384 });
    expect(second.status).toBe(200); expect(calls[1].input).toMatchObject({ version: "omos.company/v2", action: "read", revision, path: "documents/team/a.txt", offset: 16384 });
    expect(calls[1].input.view).toBeUndefined(); expect(calls[1].input.execution).toBeUndefined();
    for (const input of [{ action: "checkpoint", path: "documents/a" }, { action: "read", path: "documents/a", revision: "d".repeat(64) }, { action: "inventory", view }, { action: "inventory", offset: -1 }]) expect((await local(socket, "/company/projection", input)).status).toBe(400);
    expect(calls).toHaveLength(2);
  } finally { await broker.close(); }
});

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
  const actions = ["create_view", "checkpoint", "read", "status", "reconcile", "execution", "submit", "discover"];
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
    bound = await createCompanyClient(config, { home: f.home, binding: { view: first.view, execution, expiresMs, actions: ["checkpoint", "read", "status", "reconcile", "submit", "discover"] } });
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
      const image = { root, uid: 1000000 + Number.parseInt(crypto.randomUUID().slice(0, 6), 16) % 14000000, owner: process.getuid!(), namespaces: support.private_namespaces, executable: join(import.meta.dir, "../../zig-out/bin/fx"), fossil: existsSync(packagedFossil) ? packagedFossil : Bun.which("fossil"), profile, source: { version: "omos.worker-source/v1", workspace: boot.workspace, view: first.view, revision: checkpoint.revision, generation: execution.generation } };
      const stage = (action?: string) => {
        writeFileSync(imageFile, JSON.stringify({ ...image, ...(action ? { action } : {}) }));
        return spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", rootFixture, imageFile], { encoding: "utf8", timeout: 120000 });
      };
      const staged = stage();
      expect(staged.status, staged.stderr).toBe(0);
      try {
        // Reuse the exact checkpoint request. The real service must recover its
        // receipt rather than apply the already committed mutation again.
        let inspectedSource = false;
        model(worker, (body, count) => {
          const context = body.messages.map(message => typeof message.content === "string" ? message.content : "").join("\n");
          const rootMatch = context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/);
          expect(rootMatch).not.toBeNull();
          const directory = JSON.parse(rootMatch![1]);
          if (count === 2) inspectedSource = body.messages.some(message => message.role === "tool" && typeof message.content === "string" && message.content.includes(operation.content));
          return count === 1 ? tool("read_file", { path: join(directory, "documents/team/worker.txt") }) : count === 2 ? tool("mcp_select_tool", { name: "mcp_company_company_workspace" }) : count === 3 ? tool("mcp_company_company_workspace", operation) : { content: "Recovered the same company checkpoint." };
        });
        // A fresh model sequence drives the isolated process through normal
        // discovery and the retained operation; no private seed is staged.
        const secondProfile = JSON.parse(readFileSync(join(worker.home, ".fx/settings.json"), "utf8"));
        const secondProvider = secondProfile.providers.local.base_url;
        broker = await createWorkerBroker({ socket: root + "/run/omos-broker.sock", socketMode: 0o666, companyClient: bound, expiresMs, model: { endpoint: secondProvider + "/chat/completions", handle: "fixture-model", model: "fixture-model", credential: "provider-only-host-secret" }, company: { endpoint: service.url + "/v1/company", workspace: boot.workspace, actor: "worker", grant: "hosted-worker", view: first.view, source_revision: checkpoint.revision, actions: bound.scope!.actions } });
        const child = Bun.spawn(["sudo", "-n", "/usr/bin/python3", "-I", launcher, root, "--", "ask", "Recover the same team document checkpoint through company_workspace.", "--json"], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
        const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
        expect(code, stderr + stdout).toBe(0);
        expect(JSON.parse(stdout).tool_calls.find((item: any) => item.name === "mcp_company_company_workspace").status).toBe("success");
        expect(JSON.parse(stdout).tool_calls.find((item: any) => item.name === "read_file").status, stdout).toBe("success");
        expect(inspectedSource).toBe(true);
        expect(existsSync(root + "/home/worker/.fx/company-keys")).toBe(false);
        const verified = Bun.spawn(["sudo", "-n", "/usr/bin/python3", "-I", launcher, root, "--", "fossil", "verify", "--json"], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
        const [verifiedCode, verifiedOutput, verifiedError] = await Promise.all([verified.exited, new Response(verified.stdout).text(), new Response(verified.stderr).text()]);
        expect(verifiedCode, verifiedError + verifiedOutput).toBe(0); expect(verifiedError).toBe("");
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

for (const scenario of ["general_task", "coding_task", "retry", "resume"]) test(`company host records ${scenario} planning before actor dispatch without holding its writer`, async () => {
  const capability = scenario === "retry" || scenario === "resume" ? "general_task" : scenario;
  const f = fixture();
  let release!: () => void, entered!: () => void, plans = 0;
  const pending = new Promise<void>(resolve => { release = resolve; });
  const started = new Promise<void>(resolve => { entered = resolve; });
  const inference = model(f, () => { throw Error("Read-only planning cannot execute actor tools"); }, undefined, { plan: async packet => {
    plans++;
    expect(packet.context.originalRequest).toContain("Preserve the original task");
    expect(packet.context.contract.obligations.some(item => item.id === "request_complete")).toBe(true);
    expect(packet.context.authority.paths).toEqual(["documents/team/"]);
    entered(); await pending;
    if (scenario === "retry" && plans === 1) return { capability, summary: "Reject attempted replacement of a host obligation", obligations: [{ id: "request_forbidden", description: "An invalid planner requirement" }], checks: [] };
    return { capability, summary: "Preserve the original task and record its acceptance criteria", obligations: [{ id: "retained_outcome", description: "Retain the requested result within the authorised company task." }], checks: capability === "coding_task" ? ["Run the applicable repository checks"] : [] };
  } });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => {
    const path = join(f.home, "planning-admin.json"); writeFileSync(path, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", path, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyResult = await f.run(["fossil", "company-key", "planning-worker", "--json"]); expect(keyResult.code, keyResult.stderr).toBe(0); const key = JSON.parse(keyResult.stdout);
  const actions = ["create_view", "execution", "read", "checkpoint", "submit", "status"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "planning-worker", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true, scenario === "resume" ? { FX_E2E_FOSSIL_FAULT: "company-plan-committed" } : {});
  let client, control;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const path = join(f.home, "planning-client.json"); writeFileSync(path, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "planning-worker", key_handle: "planning-worker", actions }), { mode: 0o600 });
    client = await createCompanyClient(path, { home: f.home });
    const response = await client.call("company_workspace", { version: "omos.company/v1", action: "create_view", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, revision: boot.revision, scope: ["documents/team/"], objective: "Preserve the original task and retain the requested result." });
    expect(response.isError, JSON.stringify(response)).not.toBe(true); const view = JSON.parse(response.content[0].text).view;
    const transport = createWorkerHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    let losePlanAcknowledgement = true;
    control = { ...transport, async call(input) {
      const result = await transport.call(input);
      if (input.change === "plan" && result.ok && losePlanAcknowledgement) { losePlanAcknowledgement = false; return { ok: false, uncertain: true, error: "WorkerControlOutcomeUnknown" }; }
      return result;
    } };
    const mutate = async (input: object) => { const result = await control.call(input); expect(result.ok, JSON.stringify(result)).toBe(true); return result.jobs[0]; };
    let current = await mutate({ change: "queue", operation: crypto.randomUUID(), view });
    const original = structuredClone(current.contract), previousContract = current.record.binding.contract_sha256;
    expect(current.planning_required).toBe(true); expect(current.record.invocations).toBe(0);
    let actors = 0;
    const coordinator = createWorkerCoordinator({ control, backend: { async run() { actors++; return { outcome: "waiting", note: "Retain the planned invocation for inspection." }; } }, runtime: "planned-worker" });
    try {
      expect((await coordinator.tick()).started).toBe(0);
      await Promise.race([started, Bun.sleep(15000).then(() => { throw Error("CompanyPlannerDidNotStart"); })]);
      const observedAt = Date.now(); current = await mutate({ change: "inspect", view });
      expect(Date.now() - observedAt).toBeLessThan(5000);
      expect(current.planning_state).toBe("running"); expect(current.record.invocations).toBe(0); expect(current.execution).toBeNull(); expect(actors).toBe(0);
      expect((await coordinator.tick()).started).toBe(0);
      release();
      if (scenario === "retry" || scenario === "resume") {
        const failureDeadline = Date.now() + 45000;
        do { current = await mutate({ change: "inspect", view }); if (current.planning_state === "failed") break; await Bun.sleep(50); } while (Date.now() < failureDeadline);
        expect(current.planning_state).toBe("failed"); expect(current.record.invocations).toBe(0);
        expect((await coordinator.tick()).started).toBe(0);
        current = await mutate({ change: "inspect", view }); expect(current.record.state).toBe("waiting"); expect(actors).toBe(0); expect(plans).toBe(1);
        await mutate({ change: "requeue", operation: crypto.randomUUID(), view, expected_sha256: current.sha256 });
        expect((await coordinator.tick()).started).toBe(0);
      }
      const deadline = Date.now() + 45000;
      do { current = await mutate({ change: "inspect", view }); if (current.planning_state === "planned") break; await Bun.sleep(50); } while (Date.now() < deadline);
      expect(current.planning_state, JSON.stringify(current)).toBe("planned");
      expect(current.basis.capability).toBe(capability); expect(current.contract.objective).toBe(original.objective);
      for (const obligation of original.obligations) expect(current.contract.obligations).toContainEqual(obligation);
      expect(current.contract.obligations.map(item => item.id)).toContain("retained_outcome");
      if (capability === "coding_task") expect(current.contract.obligations.map(item => item.id)).toEqual(expect.arrayContaining(["coding_validation", "coding_summary"]));
      expect(current.record.binding.contract_sha256).toBe(previousContract); expect(current.planning_required).toBe(true);
      expect((await coordinator.tick()).started).toBe(1); await coordinator.drain();
      current = await mutate({ change: "inspect", view });
      expect(current.record).toMatchObject({ state: "waiting", invocations: 1 }); expect(current.planning_required).toBe(false); expect(current.record.binding.contract_sha256).not.toBe(previousContract);
      expect(actors).toBe(1); expect(plans).toBe(scenario === "retry" ? 2 : 1); expect(current.publication).toBeNull(); expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
      const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
    } finally { release(); await coordinator.close(); }
  } finally { release(); control?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 180000);

test("server completion preserves a workspace's historical review job schema", async () => {
  const f = fixture();
  let permit = false;
  const inference = model(f, () => ({ content: "Retain the historical contract answer." }), packet => permit ? "met" : {
    name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: packet.contract.obligations.map(item => ({ id: item.id, status: "met", evidence: ["unseen-fixture-evidence"], note: "Retain the answer after verification rejects unseen evidence" })) },
  });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const declaration = JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data.declaration;
  const operation = declaration.spec.operations.find(item => item.id === "omos_record_review_job");
  for (const field of ["kind", "planning_definition", "planning_contract_sha256"]) delete operation.input.properties[field];
  operation.input.properties.state.enum = operation.input.properties.state.enum.filter(state => state !== "planned");
  const tree = join(f.home, "historical-review"); mkdirSync(tree);
  const fossil = (...args: string[]) => { const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" }); expect(result.status, result.stderr).toBe(0); };
  fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk"); writeFileSync(join(tree, "omniform/company.json"), JSON.stringify(declaration));
  fossil("commit", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain the historical review transport contract");
  const answer = await f.run(["ask", "Give a short informational answer under the historical contract", "--json"]); expect(answer.code, answer.stderr).toBe(1);
  expect(inference.counts().actors, answer.stderr + answer.stdout).toBe(1);
  const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
  permit = true;
  const service = await startWorkspaceService(f, true);
  try {
    const bootstrap = await (await fetch(service.url + "/v1/definition", { headers: service.headers })).json() as any;
    const basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: bootstrap.definition.basis.definition_hash, revision: bootstrap.revision };
    const head = await (await service.post({ ...basis, revision: undefined, action: "head", task: task.id })).json() as any;
    const response = await service.post({ ...basis, revision: head.data.revision, action: "queue_review", task: task.id }); expect(response.status, await response.clone().text()).toBe(200);
    const queued = (await response.json() as any).data;
    let current: any; const deadline = Date.now() + 45000;
    do { const reply = await service.post({ ...basis, action: "job", task: task.id, job: queued.id }); if (reply.status === 409) { await Bun.sleep(50); continue; } expect(reply.status, await reply.clone().text()).toBe(200); current = (await reply.json() as any).data; if (!["queued", "running"].includes(current.state)) break; await Bun.sleep(100); } while (Date.now() < deadline);
    expect(current).toMatchObject({ state: "published" });
    const retained = JSON.parse(f.fossil("cat", `jobs/${queued.id}.json`, "-r", "trunk")); expect(retained.kind).toBeUndefined(); expect(retained.planning_definition).toBeUndefined();
    const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0); expect(inference.counts().actors).toBe(1);
  } finally { service.child.kill(); await service.child.exited; }
}, 150000);

test("company implementation registration is portable while heartbeat ownership is disposable and fenced", async () => {
  const f = fixture();
  const initial = await f.run(["fossil", "init", "--json"]); expect(initial.code, initial.stderr + initial.stdout).toBe(0);
  const file = join(f.home, "runtime-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", action: "initialize" }));
  const initialized = await f.run(["fossil", "company", file, "--json"]); expect(initialized.code, initialized.stderr).toBe(0);
  let service = await startWorkspaceService(f, true), control;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const connect = () => createRuntimeHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    control = connect();
    const request = async value => { const result = await control.call({ version: "omos.company-runtime/v1", ...value }); expect(result.ok, JSON.stringify(result)).toBe(true); return result; };
    const empty = await request({ change: "inspect" }); expect(empty.runtimes).toEqual([]);
    const registration = { version: "omos.company-runtime-registration/v1", id: "a".repeat(64), workspace: boot.workspace, package_sha256: "b".repeat(64), model_handle: "fixture-model", isolation: "omos.linux-worker/v1", subjects: [{ actor: "actor", grant: "grant" }], validation_handles: ["company-default"] };
    const registered = await request({ change: "register", id: registration.id, revision: empty.revision, registration });
    const heartbeat = { change: "heartbeat", id: registration.id, registration_sha256: registered.sha256, instance: "c".repeat(64) };
    expect((await request(heartbeat)).live).toBe(true);
    const observed = await request({ change: "inspect", id: registration.id }); expect(observed.revision).toBe(registered.revision); expect(observed.runtimes[0].live).toBe(true);
    expect((await request(heartbeat)).revision).toBe(registered.revision);
    const different = await control.call({ version: "omos.company-runtime/v1", ...heartbeat, instance: "d".repeat(64) }); expect(different).toMatchObject({ ok: false, error: "CompanyRuntimeBusy" });
    const stale = await control.call({ version: "omos.company-runtime/v1", ...heartbeat, registration_sha256: "d".repeat(64) }); expect(stale).toMatchObject({ ok: false, error: "CompanyRuntimeChanged" });
    const fenced = await control.call({ version: "omos.company-runtime/v1", ...heartbeat, change: "stop", instance: "d".repeat(64) }); expect(fenced).toMatchObject({ ok: false, error: "CompanyRuntimeFenced" });
    expect((await request({ ...heartbeat, change: "stop" })).live).toBe(false);
    const same = await request({ change: "register", id: registration.id, revision: registered.revision, registration }); expect(same.revision).toBe(registered.revision);
    const delayed = await control.call({ version: "omos.company-runtime/v1", ...heartbeat }); expect(delayed).toMatchObject({ ok: false, error: "CompanyRuntimeFenced" });
    expect((await request({ ...heartbeat, instance: "e".repeat(64) })).live).toBe(true);
    const superseded = await control.call({ version: "omos.company-runtime/v1", ...heartbeat }); expect(superseded).toMatchObject({ ok: false, error: "CompanyRuntimeBusy" });
    control.close(); service.child.kill(); await service.child.exited;
    service = await startWorkspaceService(f, true); control = connect();
    const restored = await request({ change: "inspect", id: registration.id }); expect(restored.runtimes[0].registration).toEqual(registration); expect(restored.runtimes[0].live).toBe(false); expect(restored.revision).toBe(registered.revision);
    const description = { workspace: boot.workspace, package_sha256: "e".repeat(64), model_handle: "advertised-model", subjects: [{ actor: "actor", grant: "grant" }], validation_handles: [] };
    const advertised = await advertiseWorkerRuntime({ control, description });
    const live = await request({ change: "inspect", id: advertised.id }); expect(live.runtimes[0].live).toBe(true);
    await expect(advertiseWorkerRuntime({ control, description })).rejects.toThrow("WorkerRuntimeAlreadyActive");
    await advertised.close();
    expect((await request({ change: "inspect", id: advertised.id })).runtimes[0].live).toBe(false);
    const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
  } finally { control?.close(); service.child.kill(); await service.child.exited; }
}, 180000);

test("signed hosted execution requires compute authority and a live matching implementation while retaining jobs across gateway restarts", async () => {
  const f = fixture(); const inference = model(f, () => { throw Error("The gateway must never run actor tools"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => {
    const file = join(f.home, "hosted-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  let revision = (await admin({ action: "initialize" })).revision;
  const keyed = await f.run(["fossil", "company-key", "hosted", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "discover", "read", "checkpoint", "submit", "status", "reconcile", "execute_task"];
  for (const id of ["hosted", "manual"]) revision = (await admin({ action: "grant", revision, grant: { id, actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions: id === "manual" ? actions.filter(action => action !== "execute_task") : actions, expires_ms: Date.now() + 3600000 } })).revision;
  let service = await startWorkspaceService(f, true), client, manual, runtimeControl, advertised, control;
  const configFile = join(f.home, "hosted-client.json"), manualFile = join(f.home, "manual-client.json");
  const connect = async () => {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = { version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "hosted", key_handle: "hosted", actions };
    writeFileSync(configFile, JSON.stringify(config), { mode: 0o600 });
    // A client cannot give itself compute authority by advertising the action.
    writeFileSync(manualFile, JSON.stringify({ ...config, grant: "manual" }), { mode: 0o600 });
    client = await createCompanyClient(configFile, { home: f.home }); manual = await createCompanyClient(manualFile, { home: f.home });
    const owner = { endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) };
    runtimeControl = createRuntimeHttpControl(owner); control = createWorkerHttpControl(owner);
    return boot;
  };
  const args = (action, rest = {}) => ({ version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest });
  const send = async (input, selected = client) => { const result = await selected.call("company_workspace", input); expect(result.isError, JSON.stringify(result) + (result.isError && existsSync(f.env.FX_TRACE_LOG) ? "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-8000) : "")).not.toBe(true); return JSON.parse(result.content[0].text); };
  try {
    let boot = await connect(); expect(boot.features.hosted_execution).toBe(false);
    expect((await send(args("status"))).actions).toContain("execute_task");
    const view = await send(args("create_view", { revision: boot.revision, objective: "Answer the team with a short greeting" }));
    const manualView = await send(args("create_view", { revision: boot.revision, objective: "Keep an independently operated team view" }), manual);
    const unavailable = await client.call("company_workspace", args("execute_task", { view: view.view, revision: view.revision })); expect(unavailable.isError).toBe(true);
    expect((await send(args("status", { view: view.view }))).hosted_execution).toMatchObject({ available: false, job: null });
    const description = { workspace: boot.workspace, package_sha256: "e".repeat(64), model_handle: "company-model", subjects: [{ actor: "participant", grant: "hosted" }], validation_handles: ["company-default"] };
    advertised = await advertiseWorkerRuntime({ control: runtimeControl, description });
    boot = await (await fetch(service.url + "/v1/company")).json(); expect(boot.features.hosted_execution).toBe(true);
    const denied = await manual.call("company_workspace", args("execute_task", { view: manualView.view, revision: manualView.revision })); expect(denied.isError).toBe(true);
    expect((await client.call("company_workspace", args("execute_task", { view: view.view, revision: "a".repeat(64) }))).isError).toBe(true);
    const request = args("execute_task", { view: view.view, revision: view.revision });
    const queued = await send(request); expect(queued).toMatchObject({ available: true, job: { state: "queued", invocations: 0, max_invocations: 3 } });
    expect(await send(request)).toEqual(queued);
    expect((await send(args("execute_task", { view: view.view, revision: view.revision }))).job.id).toBe(queued.job.id);
    expect((await send(args("status", { view: view.view }))).hosted_execution.job).toEqual(queued.job);
    // A coordinator configured for another actor must not plan or claim this job.
    const skipped = createWorkerCoordinator({ control, backend: { supports: () => false, async run() { throw Error("Wrong actor dispatched"); } } });
    expect((await skipped.tick()).started).toBe(0); await skipped.close();
    expect((await control.call({ change: "inspect", view: view.view })).jobs[0].record.invocations).toBe(0);
    await advertised.close(); advertised = null;
    client.close(); manual.close(); control.close(); runtimeControl.close(); service.child.kill(); await service.child.exited;
    service = await startWorkspaceService(f, true); boot = await connect(); expect(boot.features.hosted_execution).toBe(false);
    expect((await send(args("status", { view: view.view }))).hosted_execution).toMatchObject({ available: false, job: { id: queued.job.id, invocations: 0 } });
    advertised = await advertiseWorkerRuntime({ control: runtimeControl, description });
    let invoked = 0; const coordinator = createWorkerCoordinator({ control, backend: { supports: row => row.record.binding.grant === "hosted", async run() { invoked++; return { outcome: "waiting", note: "Retained the isolated invocation for the next user instruction." }; } } });
    const deadline = Date.now() + 45000;
    while (!invoked && Date.now() < deadline) { await advertised.heartbeat(); await coordinator.tick(); await Bun.sleep(50); }
    await coordinator.drain(); await coordinator.close(); expect(invoked).toBe(1);
    const waiting = await send(args("status", { view: view.view })); expect(waiting.hosted_execution.job).toMatchObject({ state: "waiting", invocations: 1, max_invocations: 3 });
    const resumed = await send(args("execute_task", { view: view.view, revision: waiting.revision })); expect(resumed.job).toMatchObject({ id: queued.job.id, state: "queued", invocations: 1, max_invocations: 3, note: waiting.hosted_execution.job.note });
    expect(inference.counts().actors).toBe(0); const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
  } finally { if (advertised) await advertised.close(); client?.close(); manual?.close(); runtimeControl?.close(); control?.close(); service.child.kill(); await service.child.exited; }
}, 180000);

test("company coding publication requires current owner-observed validation and rejects stale checks", async () => {
  const f = fixture();
  const inference = model(f, () => { throw Error("Host evaluation must not run actor tools"); }, undefined, { plan: { capability: "coding_task", summary: "Implement and validate the requested addition function", obligations: [], checks: ["Check add(2, 3) == 5"] } });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => {
    const file = join(f.home, "evaluation-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initialized = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "evaluation-worker", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "execution", "read", "checkpoint", "submit", "status", "record"];
  await admin({ action: "grant", revision: initialized.revision, grant: { id: "evaluation-worker", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true);
  let client, control, evaluator;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const file = join(f.home, "evaluation-client.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "evaluation-worker", key_handle: "evaluation-worker", actions }), { mode: 0o600 });
    client = await createCompanyClient(file, { home: f.home });
    const send = async (action: string, rest: object = {}) => {
      const result = await client.call("company_workspace", { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest });
      expect(result.isError, JSON.stringify(result) + (result.isError && existsSync(f.env.FX_TRACE_LOG) ? "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-6000) : "")).not.toBe(true); return JSON.parse(result.content[0].text);
    };
    const created = await send("create_view", { revision: boot.revision, scope: ["documents/team/"], objective: "Implement add(a, b) in documents/team/calculator.py, validate that add(2, 3) is 5, and publish the verified result." }), view = created.view;
    const transport = { endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) };
    control = createWorkerHttpControl(transport); evaluator = createEvaluationHttpControl(transport);
    const owner = async input => { const reply = await control.call(input); expect(reply.ok, JSON.stringify(reply)).toBe(true); return reply.jobs[0]; };
    let row = await owner({ change: "queue", operation: crypto.randomUUID(), view });
    row = await owner({ change: "plan", operation: crypto.randomUUID(), view, expected_sha256: row.sha256 });
    const planDeadline = Date.now() + 45000;
    while (row.planning_required && Date.now() < planDeadline) {
      await Bun.sleep(100); row = await owner({ change: "inspect", view });
      if (row.planning_state === "planned") row = await owner({ change: "plan", operation: crypto.randomUUID(), view, expected_sha256: row.sha256 });
    }
    expect(row.planning_required, JSON.stringify(row)).toBe(false);
    row = await owner({ change: "claim", operation: crypto.randomUUID(), view, expected_sha256: row.sha256, execution: { runtime: "evaluation-owner", generation: 0 } });
    const execution = { runtime: row.record.runtime, generation: row.record.generation };
    const code = "def add(a, b):\n    return a + b\n";
    let checkpoint = await send("checkpoint", { view, execution, revision: row.view_revision, path: "documents/team/calculator.py", content: code });
    const prepare = async revision => {
      const reply = await evaluator.call({ version: "omos.company-evaluation/v1", action: "prepare", view, execution, revision }); expect(reply.ok, JSON.stringify(reply)).toBe(true); return reply;
    };
    const savedClaim = { version: "omos.company-evaluation/v1", action: "candidate", view, execution, revision: checkpoint.revision, operation: crypto.randomUUID(), candidate: "Implemented the company addition function; host checks are pending." };
    const saved = await evaluator.call(savedClaim); expect(saved.ok, JSON.stringify(saved)).toBe(true); expect(saved.authority).toBe("actor_claim");
    const savedReplay = await evaluator.call(savedClaim); expect(savedReplay.ok, JSON.stringify(savedReplay)).toBe(true); expect(savedReplay).toMatchObject({ replayed: true, candidate_sha256: saved.candidate_sha256, revision: saved.revision });
    const inspected = await service.post({ version: "omos.workspace-api/v1", workspace: boot.workspace, definition_hash: row.basis.definition_hash, revision: saved.revision, action: "candidate", task: row.record.binding.task });
    expect(inspected.status, await inspected.clone().text()).toBe(200); expect((await inspected.json() as any).data).toMatchObject({ authority: "actor_claim", candidate: savedClaim.candidate });
    const first = await prepare(saved.revision);
    expect(first.files.map(item => item.path)).toEqual(["documents/team/calculator.py"]);
    const forged = await client.call("company_workspace", { version: "omos.company/v1", action: "record", view, execution, revision: checkpoint.revision, entity: "omos_evidence", content: JSON.stringify({ id: "forged", data: { status: "passed" } }), operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 }); expect(forged.isError).toBe(true);
    const denied = headers => new Promise<number>((resolve, reject) => {
      const request = http.request(service.url + "/v1/company/evaluation", { method: "POST", agent: false, headers: { "content-type": "application/json", "content-length": 2, connection: "close", ...headers } }, response => {
        response.resume(); response.once("end", () => resolve(response.statusCode!)); response.once("error", reject);
      });
      request.once("error", reject); request.end("{}");
    });
    expect(await denied({})).toBe(401);
    expect(await denied({ ...service.headers, origin: "http://127.0.0.1" })).toBe(401);
    const checks = async (input: string) => {
      const arguments_ = ["/usr/bin/python3", "-I", "-c", input];
      const child = Bun.spawn(arguments_, { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      const [exit_code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      return [{ id: "addition", arguments: arguments_, cwd: "documents/team", exit_code, stdout, stderr, output_complete: true, source_unchanged: true }];
    };
    const record = async (snapshot, values) => ({ version: "omos.company-evaluation/v1", action: "record", view, execution, revision: snapshot.revision, source_sha256: snapshot.source_sha256, configuration_handle: snapshot.configuration_handle, configuration_sha256: "a".repeat(64), environment_sha256: "b".repeat(64), operation: crypto.randomUUID(), checks: values });
    const bad = await record(first, await checks("assert False, 'deliberate check failure'"));
    const crossAction = await evaluator.call({ ...bad, operation: savedClaim.operation }); expect(crossAction).toMatchObject({ ok: false, error: "CompanyOperationConflict" });
    const stale = await evaluator.call({ ...bad, operation: crypto.randomUUID(), source_sha256: "0".repeat(64) }); expect(stale.ok).toBe(false);
    const mismatched = await evaluator.call({ ...bad, operation: crypto.randomUUID(), configuration_handle: "another-configuration" }); expect(mismatched.ok).toBe(false);
    const failed = await evaluator.call(bad); expect(failed.ok, JSON.stringify(failed)).toBe(true); expect(failed.passed).toBe(false);
    expect(failed.record_id).toMatch(/^[0-9a-f]{64}$/);
    const feedback: Buffer[] = []; let feedbackOffset = 0, feedbackSha, feedbackBytes;
    do {
      const page = await send("status", { view, revision: failed.revision, record_id: failed.record_id, offset: feedbackOffset, limit: 97 });
      expect(page).toMatchObject({ version: "omos.company-validation-feedback/v1", record_id: failed.record_id, evidence: failed.evidence, offset: feedbackOffset });
      const content = Buffer.from(page.content, "base64"); expect(content.length).toBeLessThanOrEqual(97); feedback.push(content);
      feedbackSha ??= page.sha256; feedbackBytes ??= page.bytes; expect(page.sha256).toBe(feedbackSha); expect(page.bytes).toBe(feedbackBytes);
      if (page.next_offset === null) break; expect(page.next_offset).toBe(feedbackOffset + content.length); feedbackOffset = page.next_offset;
    } while (feedbackOffset < feedbackBytes);
    const receipt = Buffer.concat(feedback); expect(receipt.length).toBe(feedbackBytes); expect(createHash("sha256").update(receipt).digest("hex")).toBe(feedbackSha);
    expect(JSON.parse(receipt.toString())).toMatchObject({ authority: "company_host", status: "failed", checks: [{ exit_code: 1 }] });
    const other = await send("create_view", { revision: boot.revision, objective: "Keep another task isolated from validation feedback" });
    const deniedFeedback = await client.call("company_workspace", { version: "omos.company/v1", action: "status", view: other.view, revision: other.revision, record_id: failed.record_id, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 }); expect(deniedFeedback.isError).toBe(true);
    const replay = await evaluator.call(bad); expect(replay.ok, JSON.stringify(replay)).toBe(true); expect(replay).toMatchObject({ replayed: true, passed: false, evidence: failed.evidence, record_id: failed.record_id, revision: failed.revision });
    const different = await evaluator.call({ ...bad, environment_sha256: "c".repeat(64) }); expect(different).toMatchObject({ ok: false, error: "CompanyOperationConflict" });
    const passedInput = await prepare(failed.revision);
    const passed = await evaluator.call(await record(passedInput, await checks(`${code}\nassert add(2, 3) == 5\nprint('addition passed')`)));
    expect(passed.ok, JSON.stringify(passed)).toBe(true); expect(passed.passed).toBe(true);
    checkpoint = await send("checkpoint", { view, execution, revision: passed.revision, path: "documents/team/calculator.py", previous_hash: createHash("sha256").update(code).digest("hex"), content: "def add(a, b):\n    return a - b\n" });
    await send("submit", { view, execution, revision: checkpoint.revision, candidate: "Implemented the requested addition function." });
    const review = async () => {
      let status; const deadline = Date.now() + 60000;
      do { status = await send("status", { view }); if (!["queued", "running"].includes(status.job?.state)) break; await Bun.sleep(100); } while (Date.now() < deadline);
      return status;
    };
    const held = await review(); expect(held.publication).toBeNull(); expect(held.state).not.toBe("accepted"); expect(held.job.state).toBe("changes_required");
    checkpoint = await send("checkpoint", { view, execution, revision: held.revision, path: "documents/team/calculator.py", previous_hash: createHash("sha256").update("def add(a, b):\n    return a - b\n").digest("hex"), content: "def add(a, b):\n    return (a + b)\n" });
    const fresh = await prepare(checkpoint.revision); expect(fresh.source_sha256).not.toBe(passedInput.source_sha256);
    const verified = await evaluator.call(await record(fresh, await checks("def add(a, b): return (a + b)\nassert add(2, 3) == 5\nprint('fresh addition passed')")));
    expect(verified.ok, JSON.stringify(verified)).toBe(true); expect(verified.passed).toBe(true);
    await send("submit", { view, execution, revision: verified.revision, candidate: "Implemented add(a, b), ran the current addition check, and retained its host evidence." });
    const accepted = await review(); expect(accepted.state, JSON.stringify(accepted)).toBe("accepted"); expect(accepted.publication).not.toBeNull();
    expect(inference.packets.at(-1).evidence.some(item => item.id === verified.evidence)).toBe(true);
    expect(inference.counts().actors).toBe(0);
    const full = await f.run(["fossil", "verify", "--json"]); expect(full.code, full.stderr).toBe(0);
  } finally { evaluator?.close(); control?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 240000);

for (const scenario of ["normal", "interrupted", "reported usage"]) test(`external company coding proposals receive host obligations before completion (${scenario})`, async () => {
  const interrupted = scenario === "interrupted";
  const f = fixture(); let plans = 0;
  const inference = model(f, () => { throw Error("External proposal review must never dispatch an actor"); }, undefined, { plan: packet => {
    plans++; expect(packet.context.originalRequest).toContain("Implement add"); expect(packet.context.authority.paths).toEqual(["documents/team/"]);
    return { capability: "coding_task", summary: "Validate the externally prepared addition function", obligations: [], checks: ["Check add(2, 3) == 5 against the proposed source"] };
  }, ...(scenario === "reported usage" ? { usage: { prompt_tokens: 41, completion_tokens: 9, total_tokens: 50 } } : {}) });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const file = join(f.home, "external-admin.json");
  const admin = async input => { writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "external", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "execution", "status", "read", "checkpoint", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "external", actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true, interrupted ? { FX_E2E_FOSSIL_FAULT: "company-plan-committed" } : {});
  let client, evaluator;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const configuration = join(f.home, "external-client.json"); writeFileSync(configuration, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "external", key_handle: "external", actions }), { mode: 0o600 });
    client = await createCompanyClient(configuration, { home: f.home });
    const send = async (action, input = {}) => { const result = await client.call("company_workspace", { version: action === "read" ? "omos.company/v2" : "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...input }); expect(result.isError, JSON.stringify(result)).not.toBe(true); return JSON.parse(result.content[0].text); };
    const created = await send("create_view", { revision: boot.revision, objective: "Implement add(a, b) in documents/team/calculator.py and verify that add(2, 3) returns 5." });
    const view = created.view, execution = { runtime: "external-runtime", generation: 1 }, candidate = "Implemented add(a, b), with the proposed source retained for independent checks.";
    expect(created.basis.capability).toBeNull();
    await send("execution", { view, revision: created.revision, execution: { ...execution, generation: 0 }, execution_change: "claim", execution_lease_ms: 240000 });
    const code = "def add(a, b):\n    return a + b\n";
    const checkpoint = await send("checkpoint", { view, execution, revision: created.revision, path: "documents/team/calculator.py", content: code });
    const review = async () => { let state; const deadline = Date.now() + 60000; do { state = await send("status", { view }); if (state.job) expect(state.job.contract_version, JSON.stringify({ revision: state.revision, contract: state.contract.version, review: state.job.contract_version, state: state.job.state })).toBe(state.contract.version); if (!["queued", "running"].includes(state.job?.state)) return state; await Bun.sleep(50); } while (Date.now() < deadline); throw Error("ExternalProposalReviewDidNotFinish"); };
    await send("submit", { view, execution, revision: checkpoint.revision, candidate });
    let held = await review();
    expect(held.basis.capability, JSON.stringify(held)).toBe("coding_task");
    expect(held.contract.obligations.map(item => item.id)).toEqual(expect.arrayContaining(["request_complete", "coding_validation", "coding_summary"]));
    expect(held.publication).toBeNull(); expect(plans).toBe(1);
    if (interrupted) {
      expect(held.job.state).toBe("failed"); expect(held.job.reason).toBe("WorkspaceInjectedFailure");
      await send("submit", { view, execution, revision: held.revision, candidate }); held = await review(); expect(plans).toBe(1);
    }
    expect(held.job.state, JSON.stringify(held) + (existsSync(f.env.FX_TRACE_LOG) ? "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-10000) : "")).toBe("changes_required");
    if (scenario === "reported usage") { expect(held.job.reported_tokens).toBeGreaterThanOrEqual(100); expect(held.job.review_attempts).toBe(2); }
    evaluator = createEvaluationHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    const prepared = await evaluator.call({ version: "omos.company-evaluation/v1", action: "prepare", view, execution, revision: held.revision }); expect(prepared.ok, JSON.stringify(prepared)).toBe(true);
    const observed = await send("read", { view, execution, revision: prepared.revision, path: "documents/team/calculator.py" });
    const source = Buffer.from(observed.content, "base64").toString(); expect(source).toBe(code);
    const arguments_ = ["/usr/bin/python3", "-I", "-c", source + "\nassert add(2, 3) == 5\nprint('external addition passed')"];
    const checked = spawnSync(arguments_[0], arguments_.slice(1), { encoding: "utf8" }); expect(checked.status, checked.stderr).toBe(0);
    const receipt = await evaluator.call({ version: "omos.company-evaluation/v1", action: "record", view, execution, revision: prepared.revision, operation: crypto.randomUUID(), source_sha256: prepared.source_sha256, configuration_handle: prepared.configuration_handle, configuration_sha256: "a".repeat(64), environment_sha256: "b".repeat(64), checks: [{ id: "external-addition", arguments: arguments_, cwd: "documents/team", exit_code: checked.status, stdout: checked.stdout, stderr: checked.stderr, output_complete: true, source_unchanged: true }] });
    expect(receipt.ok, JSON.stringify(receipt)).toBe(true); expect(receipt.passed).toBe(true);
    await send("submit", { view, execution, revision: receipt.revision, candidate });
    const accepted = await review(); expect(accepted.state, JSON.stringify(accepted)).toBe("accepted"); expect(accepted.publication).not.toBeNull(); expect(plans).toBe(1);
    expect(inference.counts().actors).toBe(0); expect(inference.packets.at(-1).evidence.some(item => item.id === receipt.evidence)).toBe(true);
    expect(JSON.parse(f.fossil("cat", accepted.publication.receipt_path, "-r", accepted.publication.revision)).review.candidate).toBe(candidate);
    const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
  } finally { evaluator?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 240000);

test("external completion planning spends the existing review allowance and retains an unaccepted answer when it is exhausted", async () => {
  const f = fixture(); let plans = 0;
  const inference = model(f, () => { throw Error("Review allowance must never dispatch an actor"); }, undefined, { plan: () => {
    plans++; return { capability: "general_task", summary: "Evaluate the retained greeting", obligations: [], checks: [] };
  } });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const tree = join(f.home, "review-policy"); mkdirSync(tree);
  const fossil = (...args: string[]) => { const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" }); expect(result.status, result.stderr).toBe(0); };
  fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
  const policy = JSON.parse(readFileSync(join(tree, "execution/omos.json"), "utf8")); policy.review.max_attempts = 1;
  writeFileSync(join(tree, "execution/omos.json"), JSON.stringify(policy));
  fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain the one-attempt review policy fixture");
  const admin = async input => { const file = join(f.home, "review-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "review", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "submit", "status"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "review", actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "review-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "review", key_handle: "review", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const send = async (action, input = {}) => { const result = await client.call("company_workspace", { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...input }); expect(result.isError, JSON.stringify(result)).not.toBe(true); return JSON.parse(result.content[0].text); };
    const view = await send("create_view", { revision: boot.revision, objective: "Reply with Hello, team." });
    const candidate = "Hello, team.";
    await send("submit", { view: view.view, revision: view.revision, candidate });
    let status; const deadline = Date.now() + 60000;
    do { status = await send("status", { view: view.view }); if (!["queued", "running"].includes(status.job?.state)) break; await Bun.sleep(50); } while (Date.now() < deadline);
    expect(status.job).toMatchObject({ kind: "completion", state: "pending", review_attempts: 1, candidate_hash: createHash("sha256").update(candidate).digest("hex") });
    expect(status.basis.capability).toBe("general_task"); expect(status.state).toBe("paused"); expect(status.publication).toBeNull();
    for (let index = 0; index < 3; index++) {
      const retained = await send("status", { view: view.view });
      expect(retained).toMatchObject({ state: "paused", revision: status.revision, publication: null, job: { state: "pending", review_attempts: 1 } });
    }
    expect(plans).toBe(1); expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
    const response = await service.post({ version: "omos.workspace-api/v1", workspace: boot.workspace, definition_hash: status.basis.definition_hash, revision: status.revision, task: view.contract.id, action: "candidate" }); expect(response.status, await response.clone().text()).toBe(200);
    expect((await response.json() as any).data).toMatchObject({ candidate, authority: "actor_claim" });
    const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
  } finally { client?.close(); service.child.kill(); await service.child.exited; }
}, 120000);

test("company actor archives preserve exact private Fossil history under live scoped authority", async () => {
  const f = fixture(), privateWorker = fixture();
  const host = model(f, () => { throw Error("Archival must not run company actors"); });
  const noise = randomBytes(180 * 1024).toString("base64");
  const worker = model(privateWorker, (_body, step) => step === 1 ? { tool_calls: [{ index: 0, id: "retain-worker-source", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "documents/team/private.txt", content: noise }) } }] } : { content: "Retained the original public worker evidence." });
  expect((await privateWorker.run(["fossil", "init", "--json"])).code).toBe(0);
  const worked = await privateWorker.run(["ask", "Retain the supplied private worker file and its public evidence.", "--json"], {}, 180000); expect([0, 1]).toContain(worked.code);
  const privateState = JSON.parse((await privateWorker.run(["fossil", "status", "--json"])).stdout), sourceTask = privateState.tasks[0]; expect(privateState.tasks).toHaveLength(1);
  const sourceRevision = privateWorker.fossil("timeline", "ancestors", sourceTask.branch, "--type", "ci", "--limit", "1", "--format", "%H").trim().split(/\s+/)[0]; expect(sourceRevision).toMatch(/^[a-f0-9]{64}$/);
  const filename = join(privateWorker.home, "public-worker.fossil"); expect((await privateWorker.run(["fossil", "export", filename, "--json"])).code).toBe(0);
  const exported = readFileSync(filename); expect(exported.length).toBeGreaterThan(128 * 1024);
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => { const file = join(f.home, "archive-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  let revision = (await admin({ action: "initialize" })).revision;
  const key = await f.run(["fossil", "company-key", "archiver", "--json"]); expect(key.code, key.stderr).toBe(0);
  const publicKey = (JSON.parse(key.stdout).model_data ?? JSON.parse(key.stdout)).public_key;
  const actions = ["create_view", "status", "execution"];
  for (const actor of ["alice", "bob"]) revision = (await admin({ action: "grant", revision, grant: { id: actor, actor, public_key: publicKey, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } })).revision;
  const service = await startWorkspaceService(f, true); const clients: any[] = []; let control;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any; expect(boot.features.actor_archives).toBe(true);
    for (const actor of ["alice", "bob"]) { const file = join(f.home, actor + "-archive.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, actor, grant: actor, key_handle: "archiver", issuer: boot.issuer, epoch: boot.epoch, actions }), { mode: 0o600 }); clients.push(await createCompanyClient(file, { home: f.home })); }
    const call = async (index, input, success = true) => { const response = await clients[index].call("company_workspace", { version: "omos.company/v1", operation: crypto.randomUUID(), expires_ms: Date.now() + 300000, ...input }); if (success) expect(response.isError, JSON.stringify(response)).not.toBe(true); else expect(response.isError).toBe(true); return response.isError ? response : JSON.parse(response.content[0].text); };
    const view = await call(0, { action: "create_view", revision: boot.revision, objective: "Retain public worker history without claiming company completion" });
    const claim = await call(0, { action: "execution", view: view.view, revision: view.revision, execution_change: "claim", execution: { runtime: "archive-worker", generation: 0 }, execution_lease_ms: 300000 });
    const execution = { runtime: "archive-worker", generation: claim.generation }, source = { workspace: privateState.workspace_id, task: sourceTask.id, revision: sourceRevision };
    control = createArchiveHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    const data = { version: "omos.company-actor-archive-write/v1", view: view.view, execution, source: { ...source, sha256: createHash("sha256").update(exported).digest("hex"), bytes: exported.length }, offset: 0, content: exported.subarray(0, 128 * 1024).toString("base64") };
    expect((await control.call({ ...data, execution: { ...execution, generation: execution.generation + 1 } })).ok).toBe(false);
    expect((await control.call({ ...data, source: { ...data.source, bytes: Number.MAX_SAFE_INTEGER + 1 } })).ok).toBe(false);
    const unauthed = await fetch(service.url + "/v1/company/archives", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }); expect(unauthed.status).toBe(401);
    let loseAck = true;
    const droppedAck = { async call(request, signal) { const reply = await control.call(request, signal); if (loseAck && request.action !== "inspect" && reply.ok) { loseAck = false; throw Error("The committed archive acknowledgement was lost"); } return reply; } };
    await expect(retainWorkerArchive({ filename, uid: process.getuid!(), source, view: view.view, execution, control: droppedAck })).rejects.toThrow("WorkerArchiveRetentionPending");
    expect(existsSync(filename)).toBe(true);
    const position = await control.call({ ...data, action: "inspect", offset: 0, content: "" }); expect(position.ok).toBe(true); expect(position.resume_offset).toBe(128 * 1024); expect(position.complete).toBe(false);
    const retained = await retainWorkerArchive({ filename, uid: process.getuid!(), source, view: view.view, execution, control }); expect(retained.complete).toBe(true); expect(retained.sha256).toBe(data.source.sha256);
    const list = await call(0, { action: "status", entity: "omos_company_archive", view: view.view, limit: 32 }); expect(list.archives).toHaveLength(1); expect(list.archives[0]).toMatchObject({ id: retained.archive_id, authority: "actor_public_history_only", source: data.source });
    const pieces: Buffer[] = []; let offset = 0;
    do {
      const page = await call(0, { action: "status", entity: "omos_company_archive", view: view.view, record_id: retained.archive_id, revision: list.revision, offset, limit: 16384 });
      expect(page.offset).toBe(offset); expect(page.source.sha256).toBe(retained.sha256); const bytes = Buffer.from(page.content, "base64"); expect(bytes.length).toBeLessThanOrEqual(16384); pieces.push(bytes); offset = page.next_offset;
    } while (offset !== null);
    expect(Buffer.concat(pieces).equals(exported)).toBe(true);
    const end = Math.floor((exported.length - 1) / (128 * 1024)) * (128 * 1024);
    const before = (await admin({ action: "status" })).revision;
    expect((await control.call({ ...data, offset: end, content: exported.subarray(end).toString("base64") })).complete).toBe(true);
    expect((await admin({ action: "status" })).revision).toBe(before);
    const corrupt = { ...data, source: { ...data.source, sha256: "f".repeat(64), revision: "e".repeat(64) } };
    for (let position = 0; position < exported.length; position += 128 * 1024) {
      const result = await control.call({ ...corrupt, offset: position, content: exported.subarray(position, position + 128 * 1024).toString("base64") });
      expect(result.ok).toBe(position + 128 * 1024 < exported.length);
      if (!result.ok) expect(result.error).toBe("CompanyArchiveHashMismatch");
    }
    expect((await call(0, { action: "status", entity: "omos_company_archive", view: view.view })).archives).toHaveLength(1);
    const objects = () => f.fossil("ls", "-r", "omos-company").split("\n").filter(path => path.startsWith("company/archives/objects/")).sort();
    const originalObjects = objects(); expect(originalObjects.length).toBeGreaterThan(0);
    const reusedView = await call(0, { action: "create_view", revision: boot.revision, objective: "Reference the retained worker history from another isolated task" });
    const reusedClaim = await call(0, { action: "execution", view: reusedView.view, revision: reusedView.revision, execution_change: "claim", execution: { runtime: "archive-worker", generation: 0 }, execution_lease_ms: 300000 });
    const timedChunks = new Set(), timedRequests = [];
    const timedAck = { async call(request, signal) {
      timedRequests.push(request.action);
      const reply = await control.call(request, signal);
      if (request.action === "chunk" && reply.ok) {
        expect(timedChunks.has(request.offset)).toBe(false); timedChunks.add(request.offset);
        return { ok: false, error: "WorkerControlOutcomeUnknown", transport: "RequestDeadline" };
      }
      return reply;
    } };
    const reused = await retainWorkerArchive({ filename, uid: process.getuid!(), source, view: reusedView.view, execution: { runtime: "archive-worker", generation: reusedClaim.generation }, control: timedAck });
    expect(reused.complete).toBe(true); expect(objects()).toEqual(originalObjects);
    expect(timedChunks.size).toBeGreaterThan(0); expect(timedRequests.filter(action => action === "inspect")).toHaveLength(timedChunks.size + 1);
    expect((await call(0, { action: "status", entity: "omos_company_archive", view: reusedView.view })).archives[0].source.sha256).toBe(retained.sha256);
    await call(1, { action: "status", entity: "omos_company_archive", view: view.view }, false);
    const state = await call(0, { action: "status", view: view.view }); expect(state.publication).toBeNull(); expect(state.state).toBe("active"); expect(host.counts()).toEqual({ actors: 0, assessments: 0 }); expect(worker.counts().actors).toBe(2);
    revision = (await admin({ action: "status" })).revision; await admin({ action: "revoke", revision, id: "alice" }); await call(0, { action: "status", entity: "omos_company_archive", view: view.view, record_id: retained.archive_id }, false);
    const verified = await f.run(["fossil", "verify", "--json"], {}, 180000); expect(verified.code, verified.stderr).toBe(0);
  } finally { control?.close(); clients.forEach(client => client.close()); service.child.kill(); await service.child.exited; }
}, 300000);

test("company view discovery isolates actor and grant and pins membership while new chats arrive", async () => {
  const f = fixture(), inference = model(f, () => { throw Error("Task discovery must never invoke an actor"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => { const file = join(f.home, "views-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  let revision = (await admin({ action: "initialize" })).revision;
  const actions = ["create_view", "status", "checkpoint", "discover", "read", "export_scope"];
  const subjects = [{ actor: "alice", grant: "own", key: "own" }, { actor: "alice", grant: "other-grant", key: "own" }, { actor: "bob", grant: "other-actor", key: "bob" }];
  const keys = new Map();
  for (const handle of ["own", "bob"]) { const keyed = await f.run(["fossil", "company-key", handle, "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const parsed = JSON.parse(keyed.stdout); keys.set(handle, (parsed.model_data ?? parsed).public_key); }
  for (const subject of subjects) revision = (await admin({ action: "grant", revision, grant: { id: subject.grant, actor: subject.actor, public_key: keys.get(subject.key), paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } })).revision;
  const service = await startWorkspaceService(f, true), clients: any[] = []; let bound;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any; expect(boot.features.owned_views).toBe(true);
    const configs: string[] = [];
    for (const subject of subjects) {
      const config = join(f.home, `${subject.grant}-views.json`); configs.push(config);
      writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: subject.actor, grant: subject.grant, key_handle: subject.key, actions }), { mode: 0o600 }); clients.push(await createCompanyClient(config, { home: f.home }));
    }
    const call = async (index, input, success = true) => {
      const result = await clients[index].call("company_workspace", { version: "omos.company/v1", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...input });
      const detail = JSON.stringify(result) + (result.isError && success && existsSync(f.env.FX_TRACE_LOG) ? "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-8000) : "");
      if (success) expect(result.isError, detail).not.toBe(true); else expect(result.isError, detail).toBe(true);
      return success ? JSON.parse(result.content[0].text) : result;
    };
    const create = (index, objective) => call(index, { action: "create_view", revision: boot.revision, objective });
    const first = await create(0, "First own chat"), second = await create(0, "Second own chat"), otherGrant = await create(1, "A private task under another grant"), otherActor = await create(2, "An unrelated participant's confidential goal");
    const marker = join(f.home, "ambient-sql-startup-ran"); writeFileSync(join(f.home, ".sqliterc"), `.shell touch ${JSON.stringify(marker)}\n`);
    const request = { action: "status", entity: "omos_workspace_view", limit: 1 };
    const page = await call(0, request); expect(page.version).toBe("omos.company-views/v1"); expect(page.views.map(row => row.view)).toEqual([second.view]); expect(page.next_offset).toBe(1);
    expect(page.views[0]).toMatchObject({ task: second.contract.id, objective: "Second own chat", state: "active", published: false }); expect(page.views[0].created_at_ms).toBeGreaterThan(0);
    expect(JSON.stringify(page)).not.toContain("private task"); expect(JSON.stringify(page)).not.toContain("confidential goal"); expect(existsSync(marker)).toBe(false);
    const third = await create(0, "A new chat after the membership snapshot");
    const continuation = await call(0, { ...request, revision: page.index_revision, offset: page.next_offset }); expect(continuation.views.map(row => row.view)).toEqual([first.view]); expect(continuation.next_offset).toBeNull(); expect(continuation.index_revision).toBe(page.index_revision);
    expect((await call(0, { ...request, limit: 32 })).views.map(row => row.view)).toEqual([third.view, second.view, first.view]);
    const transcript = { action: "status", entity: "omos_company_conversation", view: first.view, limit: 32 };
    const opening = await call(0, transcript), chunks = [Buffer.from(opening.conversation.content, "base64")];
    const changed = await call(0, { action: "checkpoint", view: first.view, revision: first.revision, path: "documents/team/chat.txt", content: "A later checkpoint", previous_hash: null });
    expect(changed.revision).not.toBe(opening.revision);
    const selectedFiles = await call(0, { version: "omos.company/v2", action: "discover", view: first.view, revision: changed.revision, path: "documents/team/chat.txt" });
    expect(selectedFiles.files.map(file => file.path)).toEqual(["documents/team/chat.txt"]); expect(selectedFiles.total).toBe(1);
    const beforeInspection = (await admin({ action: "status" })).revision;
    const inspected = await call(0, { version: "omos.company/v2", action: "export_scope", view: first.view, revision: changed.revision, path: "documents/team/" });
    expect(inspected.files.map(file => file.path)).toEqual(["documents/team/chat.txt"]); expect(inspected.observation).toBeUndefined();
    expect((await admin({ action: "status" })).revision).toBe(beforeInspection);
    const emptyFiles = await call(0, { action: "discover", view: first.view, revision: changed.revision, path: "documents/team/empty/" }); expect(emptyFiles.files).toEqual([]); expect(emptyFiles.total).toBe(0);
    await call(0, { action: "discover", path: "documents/" }, false); await call(0, { action: "discover", path: "documents/team/../private/" }, false);

    let offset = opening.conversation.next_offset;
    while (offset !== null) {
      const page = await call(0, { ...transcript, revision: opening.revision, offset });
      expect(page.revision).toBe(opening.revision); expect(page.conversation.sha256).toBe(opening.conversation.sha256); expect(page.conversation.offset).toBe(offset);
      chunks.push(Buffer.from(page.conversation.content, "base64")); offset = page.conversation.next_offset;
    }
    const bytes = Buffer.concat(chunks); expect(createHash("sha256").update(bytes).digest("hex")).toBe(opening.conversation.sha256);
    expect(JSON.parse(bytes.toString("utf8"))).toMatchObject({ version: "omos.company-conversation/v1", original_request: "First own chat", candidate: null, candidate_authority: "actor_claim" });
    await call(0, { ...transcript, view: otherActor.view }, false); await call(0, { ...transcript, revision: otherActor.revision }, false);
    expect((await call(1, request)).views.map(row => row.view)).toEqual([otherGrant.view]); expect((await call(2, request)).views.map(row => row.view)).toEqual([otherActor.view]);
    await call(0, { ...request, limit: 33 }, false); await call(0, { ...request, entity: "omos_task" }, false); await call(0, { ...request, revision: otherActor.revision }, false);
    bound = await createCompanyClient(configs[0], { home: f.home, binding: { view: first.view, execution: { runtime: "bound", generation: 1 }, expiresMs: Date.now() + 120000, actions: ["status"] } });
    expect((await bound.call("company_workspace", { version: "omos.company/v1", ...request, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 })).isError).toBe(true);
    revision = (await admin({ action: "status" })).revision; await admin({ action: "revoke", revision, id: "own" }); await call(0, request, false);
    expect((await call(1, request)).views.map(row => row.view)).toEqual([otherGrant.view]); expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
    const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
  } finally { bound?.close(); clients.forEach(client => client.close()); service.child.kill(); await service.child.exited; }
}, 240000);

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
    const workerCheckpoint = { version: "omos.company-worker-checkpoint/v1", runtime: "job-first", generation: 1, image: createHash("sha256").update(JSON.stringify([boot.workspace, view.view, "job-first", 1])).digest("hex"), source_revision: current.view_revision, model: "fixture-model", phase: "prepared", export_directory: null };
    const savedRequest = { change: "checkpoint", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: { runtime: "job-first", generation: 1 }, checkpoint: workerCheckpoint };
    current = (await worker(savedRequest)).jobs[0];
    expect(current.record.checkpoint).toEqual(workerCheckpoint);
    expect((await worker(savedRequest)).replayed).toBe(true);
    for (const change of [{ image: "f".repeat(64) }, { export_directory: "../private" }]) {
      const invalid = await adminResult({ action: "workers", worker: { ...savedRequest, operation: crypto.randomUUID(), expected_sha256: current.sha256, checkpoint: { ...workerCheckpoint, ...change } } });
      expect(invalid.code).not.toBe(0); expect(invalid.stderr).toContain("InvalidCompanyWorkerCheckpoint");
    }
    for (const phase of ["running", "stopped"]) current = (await worker({ ...savedRequest, operation: crypto.randomUUID(), expected_sha256: current.sha256, checkpoint: { ...workerCheckpoint, phase } })).jobs[0];
    expect(current.record.checkpoint.phase).toBe("stopped");
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
    expect(current.record.checkpoint).toEqual({ ...workerCheckpoint, phase: "stopped" });
    expect(current.record.request).toMatchObject(secondClaim);
    const replay = await worker(secondClaim);
    expect(replay.replayed).toBe(true); expect(replay.jobs[0].record.invocations).toBe(2);
    const different = await adminResult({ action: "workers", worker: { ...secondClaim, execution: { runtime: "invented", generation: 1 } } });
    expect(different.code).not.toBe(0); expect(different.stderr).toContain("CompanyOperationConflict");
    const secondFence = { runtime: "job-second", generation: 2 };
    const missingArchive = await adminResult({ action: "workers", worker: { change: "checkpoint", operation: crypto.randomUUID(), view: view.view, expected_sha256: current.sha256, execution: secondFence, checkpoint: { ...workerCheckpoint, phase: "running", continuation: { invocation: 2, archive: "f".repeat(64), source: workerCheckpoint.source_revision } } } });
    expect(missingArchive.code).not.toBe(0);
    expect((await worker({ change: "inspect", view: view.view })).jobs[0].sha256).toBe(current.sha256);
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
    let dispatched = await coordinator.tick();
    expect(dispatched.started).toBe(0);
    const dispatchDeadline = Date.now() + 45000;
    while (!dispatched.started && Date.now() < dispatchDeadline) {
      await Bun.sleep(100);
      dispatched = await coordinator.tick();
    }
    expect(dispatched.started).toBe(1);
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
  const claim = await call({ action: "candidate", task: task.id, revision: taskHead.data.revision });
  expect(claim.data).toEqual({ task: task.id, candidate: "Retain the pending reader fixture.", authority: "actor_claim" });
  expect((await call({ action: "candidate", task: task.id, revision: latest }, false)).stderr).toContain("WorkspaceRevisionChanged");
  expect((await call({ action: "candidate" }, false)).stderr).toContain("TaskIdRequired");
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

test("worker recovery refreshes native state before dispatch and never replays an actor after submission", async () => {
  const view = "b".repeat(64);
  let current: any;
  const reset = () => { current = { sha256: "a".repeat(64), authority_live: true, contract: {}, request: "Retain the original task", basis: {}, grant: {}, execution: null, task_state: "active", review_job_id: null, review_state: null, pending_operation: "retained-operation", publication: null,
    record: { state: "queued", binding: { view }, generation: 0, max_runtime_ms: 10000, expires_ms: 0, operation: "queued" } }; };
  const control = { async call(input) {
    if (input.change === "claim") { current.record = { ...current.record, state: "running", runtime: input.execution.runtime, generation: 1, expires_ms: Date.now() + 120000, operation: input.operation }; current.execution = { runtime: input.execution.runtime, generation: 1 }; }
    if (input.change === "finish") current.record = { ...current.record, state: input.outcome, operation: input.operation };
    return { ok: true, jobs: [structuredClone(current)], next_offset: null };
  } };
  reset();
  const unavailable = createWorkerCoordinator({ control, backend: { async run() { throw Error("Actor must not start with unresolved input"); } } });
  expect((await unavailable.tick()).started).toBe(0); expect(current.record.state).toBe("queued"); await unavailable.close();
  for (const outcome of ["checkpoint", "submitted", "uncertain", "replacement"]) {
    reset(); let actors = 0, recovered = 0;
    const backend = {
      async recover(row) {
        recovered++; expect(row.pending_operation).toBe("retained-operation"); expect(row.record.state).toBe("running");
        if (outcome === "uncertain") { const error: any = new Error("WorkerRecoveryPending"); error.executionUncertain = true; throw error; }
        current.pending_operation = null; current.view_revision = "c".repeat(64);
        if (outcome === "submitted") { current.review_job_id = "review"; current.review_state = "queued"; }
        if (outcome === "replacement") current.execution.runtime = "replacement-owner";
      },
      async run(row) { actors++; expect(row.pending_operation).toBeNull(); expect(row.view_revision).toBe("c".repeat(64)); return { outcome: "waiting" }; },
    };
    const coordinator = createWorkerCoordinator({ control, backend });
    expect((await coordinator.tick()).started).toBe(1); await coordinator.drain();
    expect(recovered).toBe(1); expect(actors).toBe(outcome === "checkpoint" ? 1 : 0);
    expect(current.record.state).toBe(outcome === "checkpoint" ? "waiting" : outcome === "submitted" ? "submitted" : "running");
    await coordinator.close();
  }
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
    const deniedEntry = run({ base, action: "invoke", request: { ...request, entry: { path: "/workspace/check.sh", sha256: "d".repeat(64) } } });
    expect(deniedEntry.code).toBe(125); expect(deniedEntry.stderr).toContain("InvalidImageEntry");
    const missingEntry = run({ base, action: "invoke", request: { ...request, entry: { path: "/bin/unknown", sha256: "d".repeat(64) } } });
    expect(missingEntry.code).toBe(125); expect(missingEntry.stderr).toContain("ImageEntryNotInTemplate");
    const entry = run({ base, action: "template_entry", request });
    const validationRequest = { ...request, entry };
    const validationImage = run({ base, action: "invoke", request: validationRequest });
    expect(validationImage.code, validationImage.stderr).toBe(0); expect(JSON.parse(validationImage.stdout).executable).toBe("/bin/bash");
    expect(run({ base, action: "invoke", request: { ...validationRequest, action: "remove" } }).code).toBe(0);
    const corrupted = run({ base, action: "corrupt_template", request });
    expect(corrupted.code).toBe(125); expect(corrupted.stderr).toMatch(/UnsafeImageTemplateFile|ImageTemplateChanged/);
    expect(run({ base, action: "invoke", request: { ...request, action: "inspect" } }).stderr).toContain("ImageNotFound");
  } finally { run({ base, action: "cleanup" }); }
}, 240000);

for (const scenarioSpec of companyWorkerScenarios) test.skipIf(!support?.kernel_supported)(companyWorkerScenarioName(scenarioSpec), async () => {
  const scenario = scenarioSpec.id;
  const coding = scenario.startsWith("coding"), failingChecks = scenario === "coding_failure";
  const desiredTask = scenario === "desired", inputTask = scenario === "input";
  const partialRecovery = scenario === "partial_recovery" && support.private_namespaces;
  const retiring = scenario === "retirement" && support.private_namespaces;
  const amending = ["amendment", "amend_after_answer"].includes(scenario) && support.private_namespaces;
  const amendAfterAnswer = scenario === "amend_after_answer" && support.private_namespaces;
  let amendmentAfterAnswerSubmitted = false;
  let resumedNativeHistory = false, receivedAmendment = false, retainedSummaryRead = false;
  const codingRecovery = scenario === "coding_recovery";
  const answerOnly = scenario === "answer";
  const projected = scenario === "projection";
  const recovering = scenario === "recovery" && support.private_namespaces;
  const archiveRecovery = scenario === "archive_recovery" && support.private_namespaces;
  const answer = coding ? "Implemented add(a, b) in documents/team/calculator.py." : answerOnly ? "The requested company greeting is Hello, team." : "Retained the proposed document in the private Fossil workspace.";
  const f = fixture(), worker = fixture();
  const host = model(f, () => { throw Error("The company host must never execute the actor"); }, undefined, { plan: { capability: coding ? "coding_task" : "general_task", summary: "Retain the requested company outcome", obligations: [], checks: coding ? ["Run the operator-configured isolated behavior check"] : [] } });
  const inference = model(worker, async (body, count, signal) => {
    const tool = (name: string, args: object) => ({ tool_calls: [{ index: 0, id: crypto.randomUUID(), type: "function", function: { name, arguments: JSON.stringify(args) } }] });
    if (inputTask && count === 1) return tool("ask_user_question", { questions: [{ question: "Which presentation should the retained report use?", options: [{ label: "Brief" }, { label: "Detailed" }] }] });
    if (inputTask && count === 2) {
      expect(body.messages.some(message => message.role === "tool" && JSON.stringify(message.content).includes("Brief"))).toBe(true);
      return tool("fossil_workspace", { action: "write", path: "documents/team/production.txt", content: "Retained by the isolated native worker and collected by its host." });
    }
    // Hold a provider response after the first durable tool completed. The
    // host fixture can interrupt the process without relying on shell tools
    // or optional executables inside the deliberately sparse worker image.
    if ((partialRecovery || retiring || amending && !amendAfterAnswer) && count === 2) {
      await new Promise<void>(resolve => {
        const done = () => { clearTimeout(timer); signal?.removeEventListener("abort", done); resolve(); };
        const timer = setTimeout(done, 120000);
        signal?.addEventListener("abort", done, { once: true });
        if (signal?.aborted) done();
      });
      return { content: answer };
    }
    if (amending && count === 3) {
      receivedAmendment = body.messages.some(message => JSON.stringify(message.content).includes("Replace the document with Amended by the authenticated user"));
      if (amendAfterAnswer) return tool("fossil_workspace", { action: "read", path: "documents/team/summary.txt" });
      return tool("fossil_workspace", { action: "write", path: "documents/team/production.txt", content: "Amended by the authenticated user" });
    }
    if (amendAfterAnswer && count === 4) {
      retainedSummaryRead = body.messages.some(message => message.role === "tool" && JSON.stringify(message.content).includes("Preserve this unaffected summary."));
      return tool("fossil_workspace", { action: "write", path: "documents/team/production.txt", content: "Amended by the authenticated user" });
    }
    if (amendAfterAnswer && count === 1) {
      const document = tool("fossil_workspace", { action: "write", path: "documents/team/production.txt", content: "Retained by the isolated native worker and collected by its host." });
      document.tool_calls.push({ index: 1, id: crypto.randomUUID(), type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "documents/team/summary.txt", content: "Preserve this unaffected summary." }) } });
      return document;
    }
    if (partialRecovery && count === 3) return tool("fossil_workspace", { action: "read", path: "documents/team/production.txt" });
    if (partialRecovery && count === 4) resumedNativeHistory = body.messages.some(message => message.role === "tool" && JSON.stringify(message.content).includes("Retained by the isolated native worker"));
    if (coding && (count === 1 || codingRecovery && count === 3)) return tool("fossil_workspace", { action: "write", path: "documents/team/calculator.py", content: `def add(a, b):\n    return a ${failingChecks || codingRecovery && count === 1 ? "-" : "+"} b\n` });
    if (projected && count <= 3) {
      const context = body.messages.map(message => typeof message.content === "string" ? message.content : "").join("\n");
      const match = context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/); expect(match).not.toBeNull();
      const directory = JSON.parse(match![1]);
      if (count === 1) return tool("read_file", { path: join(directory, "documents/team/production.txt") });
      if (count === 2) {
        expect(body.messages.some(message => message.role === "tool" && typeof message.content === "string" && message.content.includes("Original projected company document"))).toBe(true);
        return tool("write_file", { path: join(directory, "documents/team/production.txt"), content: "Retained by the isolated native worker and collected by its host." });
      }
      return tool("shell", { request: { action: "run", command: `test ! -e '${directory}/documents/private/nope.txt' && rm '${directory}/documents/team/remove.txt'`, timeout_ms: 10000 } });
    }
    return !answerOnly && !projected && count === 1 ? tool("fossil_workspace", { action: "write", path: "documents/team/production.txt", content: "Retained by the isolated native worker and collected by its host." }) : { content: answer };
  });
  const provider = JSON.parse(readFileSync(join(worker.home, ".fx/settings.json"), "utf8")).providers.local.base_url;
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  if (projected || desiredTask) {
    const tree = join(f.home, "projection-source"); mkdirSync(tree);
    const binding = JSON.parse(readFileSync(join(f.home, ".fx/omos-workspace.json"), "utf8"));
    const helper = existsSync(join(import.meta.dir, "../../zig-out/libexec/fossil")) ? join(import.meta.dir, "../../zig-out/libexec/fossil") : Bun.which("fossil")!;
    const fossil = (...args: string[]) => { const result = spawnSync(helper, args, { cwd: tree, env: { ...process.env, ...f.env }, encoding: "utf8" }); expect(result.status, result.stderr).toBe(0); };
    fossil("open", "--nosync", binding.repository, "trunk");
    if (projected) {
    mkdirSync(join(tree, "documents/team"), { recursive: true }); mkdirSync(join(tree, "documents/private"));
    writeFileSync(join(tree, "documents/team/production.txt"), "Original projected company document\n" + "Unchanged source line.\n".repeat(1000));
    writeFileSync(join(tree, "documents/team/remove.txt"), "Delete only after this file is materialised.");
    writeFileSync(join(tree, "documents/team/keep.sh"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    writeFileSync(join(tree, "documents/private/nope.txt"), "Outside the worker grant.");
    }
    if (desiredTask) {
      mkdirSync(join(tree, "records/company_desired_capability"), { recursive: true });
      writeFileSync(join(tree, "records/company_desired_capability/production.json"), JSON.stringify({ entity: "company_desired_capability", id: "production", task: "operator-seed", data: { version: "omos.company-desired-capability/v1", capability: "general_task", objective: "Retain documents/team/production.txt with the requested worker checkpoint text.", criteria: ["The document contains Retained by the isolated native worker and collected by its host."], paths: ["documents/team/"], observations: [], enabled: true } }));
    }
    fossil("addremove"); fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "--user", "omos", "-m", "Retain scoped source projection fixture");
  }

  const admin = async (input: object) => {
    const file = join(f.home, "production-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]);
    expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "production-worker", "--json"]);
  expect(keyed.code, keyed.stderr).toBe(0);
  const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "execution", "execute_task", "status", "read", "checkpoint", "submit", "reconcile", "discover"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "production-worker", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: projected ? ["documents/"] : ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  let service = await startWorkspaceService(f, true, recovering ? { FX_E2E_FOSSIL_FAULT: "company-checkpoint-committed" } : {});
  const imageFixture = join(import.meta.dir, "fixtures/company-worker-image.py");
  const setup = spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", imageFixture], { input: JSON.stringify({ action: "setup", owner: 0, group: 0, validation: coding }), encoding: "utf8", timeout: 120000 });
  expect(setup.status, setup.stderr).toBe(0);
  const { base } = JSON.parse(setup.stdout);
  let client, ownerProxy;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const company = { version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "production-worker", key_handle: "production-worker", actions };
    const file = join(f.home, "production-client.json"); writeFileSync(file, JSON.stringify(company), { mode: 0o600 });
    client = await createCompanyClient(file, { home: f.home });
    const created = desiredTask ? null : await client.call("company_workspace", { version: "omos.company/v1", action: "create_view", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, revision: boot.revision, ...(projected ? { scope: ["documents/team/"] } : {}), objective: coding ? "Implement add(a, b) in documents/team/calculator.py so that adding 2 and 3 returns 5. Validate the requested behavior before publication." : answerOnly ? "Reply with the company greeting Hello, team. No file change is requested." : projected ? "Update documents/team/production.txt with the requested worker checkpoint text, delete documents/team/remove.txt and preserve all other files and executable modes." : "Retain documents/team/production.txt with the requested worker checkpoint text." });
    if (created) expect(created.isError, JSON.stringify(created)).not.toBe(true);
    const createdView = created ? JSON.parse(created.content[0].text) : null;
    let view = createdView?.view;
    if (desiredTask) await admin({ action: "desired", desired: { version: "omos.company-desired/v1", change: "register", policy: { version: "omos.company-reconciliation-policy/v1", workspace: boot.workspace, id: "production-target", target_path: "records/company_desired_capability/production.json", actor: "worker", grant: "production-worker", allowed_paths: ["documents/team/"], execution_capability: "general_task", enabled: true } } });
    if (!answerOnly && !desiredTask) await admin({ action: "workers", worker: { change: "queue", operation: crypto.randomUUID(), view } });
    let recoveredOperation: string | undefined;
    if (recovering) {
      let retained = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
      retained = (await admin({ action: "workers", worker: { change: "plan", operation: crypto.randomUUID(), view, expected_sha256: retained.sha256 } })).jobs[0];
      const planningDeadline = Date.now() + 45000;
      while (retained.planning_required && Date.now() < planningDeadline) {
        await Bun.sleep(50);
        retained = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
        if (retained.planning_state === "planned") retained = (await admin({ action: "workers", worker: { change: "plan", operation: crypto.randomUUID(), view, expected_sha256: retained.sha256 } })).jobs[0];
      }
      expect(retained.planning_required).toBe(false);
      retained = (await admin({ action: "workers", worker: { change: "claim", operation: crypto.randomUUID(), view, expected_sha256: retained.sha256, execution: { runtime: "interrupted-worker", generation: 0 } } })).jobs[0];
      recoveredOperation = crypto.randomUUID();
      const interrupted = await client.call("company_workspace", { version: "omos.company/v1", action: "checkpoint", operation: recoveredOperation, expires_ms: Date.now() + 120000, view, execution: { runtime: "interrupted-worker", generation: retained.record.generation }, revision: retained.view_revision, path: "documents/team/production.txt", content: "Retained by the isolated native worker and collected by its host." });
      expect(interrupted.isError).toBe(true);
      retained = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
      expect(retained.pending_operation).toBe(recoveredOperation);
      client.close(); service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, true); company.endpoint = service.url;
      writeFileSync(file, JSON.stringify(company), { mode: 0o600 }); client = await createCompanyClient(file, { home: f.home });
      retained = (await admin({ action: "workers", worker: { change: "finish", operation: crypto.randomUUID(), view, expected_sha256: retained.sha256, execution: { runtime: "interrupted-worker", generation: retained.record.generation }, outcome: "failed" } })).jobs[0];
      retained = (await admin({ action: "workers", worker: { change: "requeue", operation: crypto.randomUUID(), view, expected_sha256: retained.sha256 } })).jobs[0];
      expect(retained.pending_operation).toBe(recoveredOperation); expect(retained.record.invocations).toBe(1);
    }

    let archiveAcknowledgementLost = false;
    if (archiveRecovery || retiring || partialRecovery || amending) ownerProxy = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      const target = new URL(request.url).pathname;
      if (request.method === "GET" && target === "/fixture/actor-ready") return Response.json({ ready: inference.counts().actors >= 2 });
      const body = await request.text();
      const reply = await fetch(service.url + target, { method: request.method, headers: { authorization: request.headers.get("authorization")!, "content-type": "application/json" }, body });
      const content = await reply.text();
      if (amendAfterAnswer && !amendmentAfterAnswerSubmitted && target === "/v1/company/archives" && reply.status === 200 && JSON.parse(content).data?.complete === true) {
        const stateResult = await client.call("company_workspace", { version: "omos.company/v1", action: "status", view, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
        expect(stateResult.isError, JSON.stringify(stateResult)).not.toBe(true);
        const state = JSON.parse(stateResult.content[0].text);
        const updated = await client.call("company_workspace", { version: "omos.company/v1", action: "execute_task", view, revision: state.revision, execution: { runtime: state.execution.runtime, generation: state.execution.generation }, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, content: JSON.stringify({ version: "omos.company-task-amend/v1", text: "Replace the document with Amended by the authenticated user" }) });
        expect(updated.isError, JSON.stringify(updated)).not.toBe(true);
        expect(JSON.parse(updated.content[0].text).state).toBe("planning");
        amendmentAfterAnswerSubmitted = true;
      }
      if ((archiveRecovery || retiring) && target === "/v1/company/archives" && JSON.parse(body).request.action !== "inspect" && reply.status === 200 && !archiveAcknowledgementLost) { archiveAcknowledgementLost = true; return Response.json({ error: "FixtureArchiveAcknowledgementLost" }, { status: 503 }); }
      return new Response(content, { status: reply.status, headers: { "content-type": "application/json" } });
    } });
    const settings = { ...(desiredTask ? { desiredPolicy: "production-target", reconciliation: true } : {}), ...(answerOnly ? { hostedRequest: { view, revision: createdView.revision } } : {}), company, key_file: join(f.home, ".fx/company-keys/production-worker.seed"), archiveRecovery, codingRecovery, partialRecovery, invocationCount: archiveRecovery || codingRecovery || partialRecovery || amending ? 2 : 1, retirement: retiring, amendment: amending && !amendAfterAnswer, actorWaitUrl: ownerProxy ? `http://127.0.0.1:${ownerProxy.port}/fixture/actor-ready` : null, inputResponse: inputTask, control: { endpoint: ownerProxy ? `http://127.0.0.1:${ownerProxy.port}` : service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) }, view, model: { endpoint: provider + "/chat/completions", handle: "fixture-model", model: "fixture-model", credential: "fixture-provider-kept-outside-image" }, ...(coding ? { validation: [{ id: "addition-behavior", arguments: ["/runtime/bin/python3", "-I", "-B", "-c", "import runpy; code = runpy.run_path(\"calculator.py\"); assert code[\"add\"](2, 3) == 5; print(\"addition-behavior passed\")"], cwd: "documents/team", timeout_ms: 10000 }] } : {}) };
    const child = Bun.spawn(["sudo", "-n", "/usr/bin/python3", "-I", imageFixture], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    child.stdin.write(JSON.stringify({ base, action: "backend", settings, node: process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath })); child.stdin.end();
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    expect(code, stderr + stdout).toBe(0); expect(stderr).toBe("");
    const result = JSON.parse(stdout), outcome = JSON.parse(result.stdout);
    if (desiredTask) view = outcome.view;
    const current = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
    if (support.private_namespaces) {
      if ((outcome.state === "waiting" && !failingChecks) || outcome.state === "failed") {
        const activity = await client.call("company_workspace", { version: "omos.company/v1", action: "status", entity: "omos_company_activity", view, record_id: String(current.record.generation), offset: 0, limit: 32, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
        const page = activity.isError ? null : JSON.parse(activity.content[0].text);
        const operation = current.pending_operation ? await client.call("company_workspace", { version: "omos.company/v1", action: "status", view, outcome: current.pending_operation, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 }) : null;
        throw Error(JSON.stringify({ outcome, checkpoint: current.record.checkpoint, execution: current.execution, pending_operation: current.pending_operation, operation, actors: inference.counts().actors, activity: page?.events.map(event => ({ type: event.data.type, code: event.data.code, exit_code: event.data.exit_code })), activity_error: activity.isError === true }));
      }
      expect(result.code, result.stderr + result.stdout).toBe(0); expect(result.stderr).toBe("");
      const collectionRecovery = outcome.recovered_collection ? 1 : 0;
      if (collectionRecovery) { expect(archiveRecovery || codingRecovery || partialRecovery || amending).toBe(true); expect(current.record.max_invocations).toBe(3); }
      expect(outcome).toMatchObject({ ok: true, started: (archiveRecovery || codingRecovery || partialRecovery || amending ? 2 : 1) + collectionRecovery, state: retiring ? "cancelled" : failingChecks ? "waiting" : "completed", invocations: (recovering || archiveRecovery || codingRecovery || partialRecovery || amending ? 2 : 1) + collectionRecovery, generation: (recovering || archiveRecovery || codingRecovery || partialRecovery || amending ? 2 : 1) + collectionRecovery, published: !failingChecks && !retiring });
      expect(result.images, JSON.stringify({ images: result.image_details, checkpoint: current.record.checkpoint, state: current.record.state, note: current.record.note })).toBe(failingChecks ? 1 : 0);
      expect(current.record.checkpoint.phase).toBe(retiring ? "running" : "retained");
      if (archiveRecovery) { expect(archiveAcknowledgementLost).toBe(true); expect(current.record.checkpoint.generation).toBe(1); expect(outcome.recovered_archive).toBe(true); }
      if (desiredTask) expect(outcome.desired_met).toBe(true);
      if (inputTask) expect(outcome.input_answered).toBe(true);
      if (partialRecovery) {
        expect(outcome.recovered_partial).toBe(true); expect(resumedNativeHistory).toBe(true);
        expect(current.record.checkpoint.generation).toBe(1);
        expect(current.record.checkpoint.continuation.invocation).toBe(2);
      }
      if (amending) {
        expect(outcome.amended_task).toBe(!amendAfterAnswer); expect(receivedAmendment).toBe(true);
        if (amendAfterAnswer) { expect(amendmentAfterAnswerSubmitted).toBe(true); expect(retainedSummaryRead).toBe(true); expect(f.fossil("cat", "documents/team/summary.txt", "-r", "trunk")).toBe("Preserve this unaffected summary."); }
        expect(current.amendments).toEqual(["Replace the document with Amended by the authenticated user"]);
        expect(current.record.checkpoint.company_contract).toBe(current.record.binding.contract_sha256);
      }
      if (codingRecovery) { expect(outcome.recovered_coding).toBe(true); expect(current.record.checkpoint.generation).toBe(2); }
      const archives = await client.call("company_workspace", { version: "omos.company/v1", action: "status", entity: "omos_company_archive", view, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
      expect(archives.isError, JSON.stringify(archives)).not.toBe(true);
      const archived = JSON.parse(archives.content[0].text).archives; expect(archived).toHaveLength(codingRecovery || partialRecovery || amending ? 2 : 1); expect(archived[0].authority).toBe("actor_public_history_only"); expect(archived[0].source.bytes).toBeGreaterThan(0);
      if (partialRecovery) expect(new Set(archived.map(entry => entry.source.task)).size).toBe(1);

      // Public native progress survives worker cleanup and never establishes
      // company publication by itself. Read through the signed scoped API.
      if (!recovering && !archiveRecovery && !retiring) {
      let activityOffset = 0, activityRevision, activityEnded = false;
      const activityEvents = [];
      do {
        const activityResult = await client.call("company_workspace", { version: "omos.company/v1", action: "status", entity: "omos_company_activity", view, record_id: String(current.record.generation), offset: activityOffset, limit: 2, ...(activityRevision ? { revision: activityRevision } : {}), operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
        expect(activityResult.isError, JSON.stringify(activityResult)).not.toBe(true);
        const page = JSON.parse(activityResult.content[0].text);
        expect(page.authority).toBe("actor_public_activity_only");
        expect(page.events.length).toBeLessThanOrEqual(2);
        for (const event of page.events) { expect(event.offset).toBe(activityOffset++); activityEvents.push(event.data); }
        activityRevision = page.index_revision; activityEnded = page.ended;
        if (page.next_offset === null) break;
        expect(page.next_offset).toBe(activityOffset);
        expect(activityOffset).toBeLessThan(512);
      } while (true);
      expect(activityEnded).toBe(true);
      expect(activityEvents.some(event => event.type === "text_delta")).toBe(true);
      expect(activityEvents.at(-1)?.type).toBe("turn_end");
      if (!answerOnly && !partialRecovery) expect(activityEvents.some(event => event.type === "tool_start")).toBe(true);
      }

      if (retiring) {
        expect(outcome.retired_history).toBe(true); expect(current.publication).toBeNull(); expect(archiveAcknowledgementLost).toBe(true);
        const archived = JSON.parse(archives.content[0].text).archives[0];
        const directory = `company/archives/${current.record.binding.task}/${archived.id}`;
        const receipt = JSON.parse(f.fossil("cat", directory + "/receipt.json", "-r", "omos-company"));
        expect(receipt.retirement).toBe(current.sha256);
        const chunks: Buffer[] = [];
        for (let offset = 0; offset < archived.source.bytes; offset += 128 * 1024) {
          const part = JSON.parse(f.fossil("cat", `${directory}/${offset}.json`, "-r", "omos-company"));
          const object = JSON.parse(f.fossil("cat", `company/archives/objects/${part.chunk_sha256}.json`, "-r", "omos-company"));
          chunks.push(Buffer.from(object.content, "base64"));
        }
        const bytes = Buffer.concat(chunks); expect(createHash("sha256").update(bytes).digest("hex")).toBe(archived.source.sha256);
        const exported = join(f.home, "cancelled-worker.fossil"); writeFileSync(exported, bytes);
        const content = spawnSync("fossil", ["cat", "documents/team/production.txt", "-r", "task/" + archived.source.task, "-R", exported], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home } });
        expect(content.status, content.stderr).toBe(0); expect(content.stdout).toBe("Retained by the isolated native worker and collected by its host.");
        expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/production.txt");
        expect(host.counts()).toEqual({ actors: 0, assessments: 0 }); expect(inference.counts().actors).toBe(2);
        expect((await f.run(["fossil", "verify", "--json"], {}, 180000)).code).toBe(0);
        return;
      }
      if (failingChecks) {
        expect(current.publication).toBeNull(); expect(current.record.note).toContain("failed coding checks");
        expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/calculator.py");
        expect(host.counts().assessments).toBe(0); expect(inference.counts().actors).toBe(2);
        expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
        return;
      }
      if (recovering) {
        expect(current.pending_operation).toBeNull();
        const recovered = await client.call("company_workspace", { version: "omos.company/v1", action: "status", view, outcome: recoveredOperation, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
        expect(recovered.isError, JSON.stringify(recovered)).not.toBe(true); expect(JSON.parse(recovered.content[0].text).state).toBe("completed");
      }
      expect(current.record.state).toBe("completed"); expect(current.publication).not.toBeNull();
      const publication = JSON.parse(f.fossil("cat", current.publication.receipt_path, "-r", current.publication.revision));
      expect(publication.review.candidate).toBe(answer);
      if (coding) {
        expect(f.fossil("cat", "documents/team/calculator.py", "-r", "trunk")).toContain("return a + b");
        expect(host.packets.at(-1).evidence.some(item => item.id.startsWith("company-validation:"))).toBe(true);
      } else if (answerOnly) expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/production.txt");
      else expect(f.fossil("cat", "documents/team/production.txt", "-r", "trunk")).toBe(amending ? "Amended by the authenticated user" : "Retained by the isolated native worker and collected by its host.");
      if (projected) {
        expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/remove.txt");
        expect(f.fossil("cat", "documents/team/keep.sh", "-r", "trunk")).toBe("#!/bin/sh\nexit 0\n");
        expect(f.fossil("cat", "documents/private/nope.txt", "-r", "trunk")).toBe("Outside the worker grant.");
        const kept = await client.call("company_workspace", { version: "omos.company/v2", action: "read", revision: current.publication.revision, path: "documents/team/keep.sh", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
        expect(kept.isError, JSON.stringify(kept)).not.toBe(true); expect(JSON.parse(kept.content[0].text).executable).toBe(true);
      }
      expect(inference.counts().actors).toBe(answerOnly ? 1 : inputTask ? 3 : amendAfterAnswer ? 5 : projected || codingRecovery || amending || partialRecovery ? 4 : 2); expect(host.counts().assessments).toBeGreaterThan(0);
    } else {
      expect(result.code).toBe(1); expect(outcome).toEqual({ ok: false, error: "WorkerPrivateNamespacesRequired" });
      expect(result.images).toBe(0); if (answerOnly || desiredTask) expect(current).toBeUndefined(); else { expect(current.record.state).toBe("queued"); expect(current.record.invocations).toBe(0); }
      expect(inference.counts().actors).toBe(0); expect(host.counts().assessments).toBe(0);
    }
    expect(host.counts().actors).toBe(0);
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally {
    ownerProxy?.stop(true); client?.close(); service.child.kill(); await service.child.exited;
    const cleaned = spawnSync("sudo", ["-n", "/usr/bin/python3", "-I", imageFixture], { input: JSON.stringify({ base, action: "cleanup" }), encoding: "utf8", timeout: 30000 });
    expect(cleaned.status, cleaned.stderr).toBe(0);
  }
}, ["archive_recovery", "coding_recovery", "partial_recovery", "amendment", "amend_after_answer"].includes(scenarioSpec.id) ? 720000 : 480000);

test.skipIf(process.platform !== "linux")("company metadata pages keep file bodies bounded while inspecting a quarter-gigabyte inventory", async () => {
  const f = fixture();
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const tree = join(f.home, "capacity-source"); mkdirSync(tree);
  const fossil = (...args: string[]) => {
    const result = spawnSync(existsSync(join(import.meta.dir, "../../zig-out/libexec/fossil")) ? join(import.meta.dir, "../../zig-out/libexec/fossil") : Bun.which("fossil")!, args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
  };
  fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk"); mkdirSync(join(tree, "documents/capacity"), { recursive: true });
  const content = Buffer.alloc(8 * 1024 * 1024 - 64, 120), expected = createHash("sha256").update(content).digest("hex");
  for (let index = 0; index < 32; index++) writeFileSync(join(tree, "documents/capacity", `${index}.txt`), content);
  fossil("addremove"); fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain bounded metadata capacity fixture");
  const admin = async (input: object) => {
    const file = join(f.home, "capacity-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "capacity-reader", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  await admin({ action: "grant", revision: initial.revision, grant: { id: "capacity-reader", actor: "reader", public_key: (key.model_data ?? key).public_key, paths: ["documents/capacity/"], actions: ["discover", "read"], expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client;
  const resident = () => Number(readFileSync(`/proc/${service.child.pid}/status`, "utf8").match(/^VmRSS:\s+(\d+) kB$/m)![1]) * 1024;
  const before = resident(); let peak = before;
  const sample = setInterval(() => { try { peak = Math.max(peak, resident()); } catch {} }, 10);
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const file = join(f.home, "capacity-client.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "reader", grant: "capacity-reader", key_handle: "capacity-reader", actions: ["discover", "read"] }), { mode: 0o600 });
    client = await createCompanyClient(file, { home: f.home });
    const started = Date.now(), paths = new Set(); let offset = 0, pages = 0, maximumResponse = 0, maximumLatency = 0;
    for (;;) {
      const requestStarted = Date.now();
      const result = await client.call("company_workspace", { version: "omos.company/v2", action: "discover", revision: boot.revision, offset, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
      maximumLatency = Math.max(maximumLatency, Date.now() - requestStarted);
      expect(result.isError, JSON.stringify({ result, pages, elapsed_ms: Date.now() - started, peak_resident_growth_bytes: peak - before })).not.toBe(true);
      const data = JSON.parse(result.content[0].text); pages++;
      expect(data.total).toBe(32); expect(data.files.length).toBeGreaterThan(0); expect(data.files.length).toBeLessThanOrEqual(32);
      expect(data.files.every(file => file.sha256 === expected && file.bytes === content.length && file.executable === false)).toBe(true);
      for (const file of data.files) { expect(paths.has(file.path)).toBe(false); paths.add(file.path); }
      maximumResponse = Math.max(maximumResponse, Buffer.byteLength(result.content[0].text));
      offset += data.files.length;
      if (data.next_offset === null) break;
      expect(data.next_offset).toBe(offset);
    }
    expect(pages).toBeGreaterThan(1); expect(paths.size).toBe(32);
    expect(maximumResponse).toBeLessThan(16384);
    expect(peak - before).toBeLessThan(192 * 1024 * 1024);
    console.info(JSON.stringify({ measurement: "company_metadata_pages", files: 32, pages, referenced_bytes: 32 * content.length, maximum_response_bytes: maximumResponse, maximum_request_ms: maximumLatency, peak_resident_growth_bytes: peak - before, elapsed_ms: Date.now() - started }));
  } finally { clearInterval(sample); client?.close(); service.child.kill(); await service.child.exited; }
}, 180000);

test("portable scope verification accepts every signed short inventory page beyond the former fixed page count", async () => {
  const f = fixture(), offline = fixture();
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const keyed = await f.run(["fossil", "company-key", "short-reader", "--json"]); expect(keyed.code, keyed.stderr).toBe(0);
  const identity = JSON.parse(keyed.stdout), actorKey = (identity.model_data ?? identity).public_key;
  const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(actorKey, "hex")]), format: "der", type: "spki" });
  const signer = generateKeyPairSync("ed25519"), issuer = signer.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
  const workspace = "a".repeat(64), revision = "b".repeat(64), digest = createHash("sha256").update("x").digest("hex");
  let inventories = 0, reads = 0, rechecks = 0;
  const source = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    if (request.method === "GET") return Response.json({ version: "omos.company/v1", workspace, issuer, epoch: 1, features: { file_attributes: "omos.company/v2" } });
    const envelope = await request.json() as any, args = JSON.parse(envelope.payload);
    expect(verify(null, Buffer.from(envelope.payload), publicKey, Buffer.from(envelope.signature, "hex"))).toBe(true);
    expect(args).toMatchObject({ action: "export_scope", version: "omos.company/v2", workspace, revision, actor: "reader", grant: "short-pages" });
    let result;
    if (typeof args.path === "string") { reads++; expect(args.offset).toBe(0); result = { revision, path: args.path, exists: true, executable: false, offset: 0, bytes: 1, sha256: digest, content: "eA==", encoding: "base64", next_offset: null }; }
    else {
      if (inventories === 314) { expect(args.offset).toBe(0); rechecks++; }
      else { expect(args.offset).toBe(inventories); inventories++; }
      result = { version: "omos.scoped-export/v2", workspace, revision, actor: args.actor, grant: args.grant, total: 314, next_offset: args.offset === 313 ? null : args.offset + 1, files: [{ path: `documents/short/${args.offset}.txt`, sha256: digest, bytes: 1, executable: false }] };
    }
    const payload = JSON.stringify({ version: "omos.company-receipt/v1", workspace, actor: args.actor, grant: args.grant, operation: args.operation, request_hash: createHash("sha256").update(envelope.payload).digest("hex"), action: args.action, epoch: 1, result });
    return Response.json({ issuer, payload, signature: sign(null, Buffer.from(payload), signer.privateKey).toString("hex") });
  } });
  try {
    const config = { version: "omos.scope-export-request/v1", endpoint: `http://127.0.0.1:${source.port}`, workspace, revision, issuer, actor: "reader", grant: "short-pages", key_handle: "short-reader" };
    const input = join(f.home, "short-pages.json"), output = join(f.home, "short-pages.tar"); writeFileSync(input, JSON.stringify(config));
    const exported = await f.run(["fossil", "export-scope", input, output, "--json"], {}, 120000);
    expect(exported.code, exported.stderr).toBe(0); expect(inventories).toBe(314); expect(reads).toBe(1); expect(rechecks).toBe(1);
    const pins = join(offline.home, "pins.json"); writeFileSync(pins, JSON.stringify({ ...config, endpoint: "http://127.0.0.1:1" }));
    const checked = await offline.run(["fossil", "verify-scope", pins, output, "--json"], {}, 120000);
    expect(checked.code, checked.stderr).toBe(0); expect(JSON.parse(checked.stdout)).toMatchObject({ files: 314, bytes: 314, revision, file_attributes: "verified" });
    expect(existsSync(join(offline.home, ".fx/omos-workspace.json"))).toBe(false);
  } finally { source.stop(true); }
}, 180000);

test("company views keep a narrower immutable task scope through discovery, worker dispatch and publication", async () => {
  const f = fixture(); model(f, () => { throw Error("Task scope checks must never execute an actor"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => {
    const file = join(f.home, "scope-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "scope-reader", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "discover", "read", "checkpoint", "submit", "status", "reconcile", "execution", "query", "record", "export_scope", "delegate"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "scope-reader", actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/", "ui/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client, bound;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any; expect(boot.features.task_scopes).toBe(true);
    const config = join(f.home, "scope-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "scope-reader", key_handle: "scope-reader", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const args = (action: string, rest: object = {}) => ({ version: ["read", "discover", "export_scope"].includes(action) ? "omos.company/v2" : "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest });
    const send = async (input: object, success = true) => {
      const result = await client.call("company_workspace", input);
      if (success) expect(result.isError, JSON.stringify(result)).not.toBe(true);
      else expect(result.isError, JSON.stringify(result)).toBe(true);
      return success ? JSON.parse(result.content[0].text) : result;
    };
    for (const scope of [["skills/"], ["documents/team/", "documents/team/"]]) await send(args("create_view", { revision: boot.revision, objective: "Reject an invalid task scope", scope }), false);
    expect(JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).tasks).toHaveLength(0);
    const creation = args("create_view", { revision: boot.revision, objective: "Retain documents/team/input.txt within this task's selected scope", scope: ["documents/team/"] });
    const view = await send(creation); expect(view.paths).toEqual(["documents/team/"]); expect((await send(creation)).view).toBe(view.view);
    const child = { id: "outside-child", actor: "child", public_key: (key.model_data ?? key).public_key, parent: "scope-reader", paths: ["ui/"], actions: ["read"], expires_ms: Date.now() + 180000 };
    await send(args("delegate", { view: view.view, delegated_grant: child }), false);
    expect((await send(args("delegate", { view: view.view, delegated_grant: { ...child, id: "inside-child", paths: ["documents/team/input.txt"] } }))).state).toBe("delegated");
    const queued = (await admin({ action: "workers", worker: { change: "queue", operation: crypto.randomUUID(), view: view.view } })).jobs[0];
    expect(queued.grant.paths).toEqual(["documents/team/"]);
    await admin({ action: "workers", worker: { change: "cancel", operation: crypto.randomUUID(), view: view.view, expected_sha256: queued.sha256 } });
    const execution = { runtime: "scope-client", generation: 1 };
    await send(args("execution", { view: view.view, revision: view.revision, execution: { ...execution, generation: 0 }, execution_change: "claim", execution_lease_ms: 240000 }));
    bound = await createCompanyClient(config, { home: f.home, binding: { view: view.view, execution, expiresMs: Date.now() + 210000, actions: ["read", "status", "checkpoint"] } });
    expect(bound.tools()[1].inputSchema.properties.scope).toBeUndefined();
    expect(JSON.parse((await bound.call("company_workspace", args("read", { path: "documents/team/input.txt", scope: ["documents/"] }))).content[0].text).error).toBe("CompanyWorkerScopeDenied");
    const checkpoint = await send(args("checkpoint", { view: view.view, execution, revision: view.revision, path: "documents/team/input.txt", content: "Scoped input." }));
    for (const path of ["documents/other/input.txt", "ui/outside.css"]) {
      await send(args("read", { view: view.view, execution, revision: checkpoint.revision, path }), false);
      await send(args("checkpoint", { view: view.view, execution, revision: checkpoint.revision, path, content: "Do not retain this outside the task scope." }), false);
      expect((await send(args("read", { revision: boot.revision, path }))).exists).toBe(false);
    }
    const discovered = await send(args("discover", { view: view.view, execution, revision: checkpoint.revision }));
    expect(discovered.files.map(file => file.path)).toEqual(["documents/team/input.txt"]);
    await send(args("status", { view: view.view, scope: ["documents/"] }), false);
    expect((await send(args("status", { view: view.view }))).paths).toEqual(["documents/team/"]);
    const submitted = await send(args("submit", { view: view.view, execution, revision: checkpoint.revision, candidate: "Retained the scoped input document." }));
    expect(submitted.state).toBe("verification_pending");
    let accepted;
    const deadline = Date.now() + 60000;
    do { accepted = await send(args("status", { view: view.view })); if (!["queued", "running"].includes(accepted.job?.state)) break; await Bun.sleep(30); } while (Date.now() < deadline);
    expect(accepted.job.state, JSON.stringify(accepted)).toBe("published"); expect(accepted.paths).toEqual(["documents/team/"]);
    expect(f.fossil("cat", "documents/team/input.txt", "-r", "trunk")).toBe("Scoped input.");
    const rejected = await send(args("create_view", { revision: accepted.publication.revision, objective: "Keep mutations within documents/team only", scope: ["documents/team/"] }));
    const tree = join(f.home, "scope-adversarial"); mkdirSync(tree);
    const fossil = (...args: string[]) => { const result = spawnSync(existsSync(join(import.meta.dir, "../../zig-out/libexec/fossil")) ? join(import.meta.dir, "../../zig-out/libexec/fossil") : Bun.which("fossil")!, args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" }); expect(result.status, result.stderr).toBe(0); };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), `task/${rejected.contract.id}`); mkdirSync(join(tree, "ui"), { recursive: true });
    writeFileSync(join(tree, "ui/forged.css"), "body { color: red; }"); fossil("addremove"); fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Inject an out-of-scope proposal for publication rejection");
    const changed = await send(args("status", { view: rejected.view }));
    const refused = await client.call("company_workspace", args("submit", { view: rejected.view, revision: changed.revision, candidate: "Do not accept the forged out-of-scope file." }));
    if (!refused.isError) {
      let current; const deadline = Date.now() + 60000;
      do { current = await send(args("status", { view: rejected.view })); if (!["queued", "running"].includes(current.job?.state)) break; await Bun.sleep(30); } while (Date.now() < deadline);
      expect(current.publication).toBeNull(); expect(current.job.state).not.toBe("published");
    }
    expect(f.fossil("ls", "-r", "trunk")).not.toContain("ui/forged.css"); expect(f.fossil("ls", "-r", `task/${rejected.contract.id}`)).toContain("ui/forged.css");
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { bound?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 360000);

for (const explicit of [true, false]) test(`lost ${explicit ? "explicit" : "default"} scoped view creation acknowledgements preserve later reads, private edits and the original task`, async () => {
  const f = fixture(); expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => {
    const file = join(f.home, "scope-recovery-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "scope-recovery", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "read", "checkpoint", "status", "reconcile"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "scope-recovery", actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-view-scoped-committed" }); let client;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "scope-recovery-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "scope-recovery", key_handle: "scope-recovery", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const args = (action: string, rest: object = {}) => ({ version: action === "read" ? "omos.company/v2" : "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 240000, ...rest });
    const send = async (input: object) => { const result = await client.call("company_workspace", input); expect(result.isError, JSON.stringify(result)).not.toBe(true); return JSON.parse(result.content[0].text); };
    const creation = args("create_view", { revision: boot.revision, objective: "Retain the same private task and observations after its creation acknowledgement is lost", ...(explicit ? { scope: ["documents/team/"] } : {}) });
    const lost = await client.call("company_workspace", creation); expect(lost.isError).toBe(true);
    const matched = f.fossil("ls", "-r", "omos-company").match(/^company\/views\/([0-9a-f]+)\.json$/m); expect(matched).not.toBeNull();
    const id = matched![1], viewPath = `company/views/${id}.json`;
    const original = JSON.parse(f.fossil("cat", viewPath, "-r", "omos-company"));
    expect(original.scope).toBe(`authority/task-scopes/${original.task}.json`);
    const scopeBytes = f.fossil("cat", original.scope, "-r", "omos-company");
    const state = await send(args("status", { view: id }));
    expect((await send(args("read", { view: id, revision: state.revision, path: "documents/team/input.txt" }))).read_tracking).toBe("recorded");
    const changed = await send(args("checkpoint", { view: id, revision: state.revision, path: "documents/team/input.txt", content: "Retained before the creation outcome was reconciled." }));
    expect((await send(args("read", { view: id, revision: changed.revision, path: "documents/team/input.txt" }))).read_tracking).toBe("recorded");
    const before = f.fossil("cat", viewPath, "-r", "omos-company"), observed = JSON.parse(before);
    expect(observed.reads).toHaveLength(1); expect(observed.base).toBe(original.base);
    const recovered = await send(args("reconcile", { outcome: creation.operation }));
    expect(recovered.state).toBe("completed"); expect(recovered.result).toMatchObject({ view: id, revision: changed.revision, base: original.base, paths: [explicit ? "documents/team/" : "documents/"] });
    expect(f.fossil("cat", viewPath, "-r", "omos-company")).toBe(before);
    expect(f.fossil("cat", original.scope, "-r", "omos-company")).toBe(scopeBytes);
    expect(f.fossil("cat", "documents/team/input.txt", "-r", `task/${original.task}`)).toBe("Retained before the creation outcome was reconciled.");
    const repeated = await send(creation); expect(repeated.view).toBe(id); expect(repeated.contract.id).toBe(original.task);
    expect(JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).tasks).toHaveLength(1);
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { client?.close(); service.child.kill(); await service.child.exited; }
}, 240000);

test("personal tasks retain more than one hundred distinct read dependencies without discarding earlier observations", async () => {
  const f = fixture();
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const tree = join(f.home, "many-read-checkout"); mkdirSync(tree);
  const fossil = (...args: string[]) => {
    const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
  };
  fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
  mkdirSync(join(tree, "memory/many"), { recursive: true });
  for (let index = 0; index < 120; index++) writeFileSync(join(tree, "memory/many", `${index}.txt`), `Retained read fixture ${index}.`);
  fossil("addremove"); fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Seed individual read dependency fixtures");
  const inference = model(f, (_body, count) => count <= 3 ? { tool_calls: Array.from({ length: 40 }, (_, index) => {
    const selected = (count - 1) * 40 + index;
    return { index, id: `read-${selected}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: `memory/many/${selected}.txt` }) } };
  }) } : { content: "Retain all 120 distinct dependency observations for later verification." }, () => "blocked");
  const result = await f.run(["ask", "Read all 120 memory/many fixture documents and retain their individual read observations.", "--json"], {}, 240000);
  expect(result.code).toBe(1);
  const output = JSON.parse(result.stdout);
  expect(output.tool_calls.filter(call => call.name === "fossil_workspace")).toHaveLength(120);
  expect(output.tool_calls.filter(call => call.name === "fossil_workspace").every(call => call.status === "success"), result.stdout).toBe(true);
  expect(inference.counts().actors).toBe(4);
  const task = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).tasks[0];
  expect(task.dependencies).toHaveLength(120);
  expect(new Set(task.dependencies.map(item => item.path)).size).toBe(120);
  expect(task.dependencies.every(item => /^[0-9a-f]{64}$/.test(item.observed_hash))).toBe(true);
  expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
}, 300000);

test("company submissions freeze more than one hundred signed read selectors and retain every original observation", async () => {
  const f = fixture();
  model(f, () => { throw Error("A read-only company dependency fixture must not run actors"); }, () => "blocked");
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => {
    const file = join(f.home, "read-capacity-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]);
    expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "many-reads", "--json"]);
  expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "read", "status", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "many-reads", actor: "reader", public_key: (key.model_data ?? key).public_key, paths: ["documents/many/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true);
  let client;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "many-reads-client.json");
    writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "reader", grant: "many-reads", key_handle: "many-reads", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const call = async (action: string, rest: object = {}) => {
      const result = await client.call("company_workspace", { version: action === "read" ? "omos.company/v2" : "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest });
      expect(result.isError, JSON.stringify({ action, ...rest, result })).not.toBe(true); return JSON.parse(result.content[0].text);
    };
    const view = await call("create_view", { revision: boot.revision, objective: "Retain the complete signed set of absent scoped read dependencies for independent review." });
    for (let index = 0; index < 105; index++) {
      const read = await call("read", { view: view.view, revision: view.revision, path: `documents/many/${index}.txt` });
      expect(read.exists).toBe(false); expect(read.read_tracking).toBe("recorded");
    }
    const submitted = await call("submit", { view: view.view, revision: view.revision, candidate: "All 105 scoped input paths were observed absent; retain every observation for independent verification." });
    expect(submitted.state).toBe("verification_pending");
    const task = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).tasks.find(task => task.authority?.grant === "many-reads");
    expect(task.company_reads).toHaveLength(105);
    expect(new Set(task.company_reads.map(reference => reference.selector)).size).toBe(105);
    expect(task.company_reads.every(reference => reference.revision.length === 64)).toBe(true);
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { client?.close(); service.child.kill(); await service.child.exited; }
}, 360000);

test("company desired reconciliation pins operator authority, retains one task and detects relevant drift", async () => {
  const f = fixture();
  const inference = model(f, () => { throw Error("Reconciliation must not execute an actor directly"); }, undefined, { plan: { capability: "general_task", summary: "Produce the required company report", obligations: [], checks: [] } });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const tree = join(f.home, "desired-owner"); mkdirSync(tree);
  const helper = existsSync(join(import.meta.dir, "../../zig-out/libexec/fossil")) ? join(import.meta.dir, "../../zig-out/libexec/fossil") : Bun.which("fossil")!;
  const fossil = (...args: string[]) => { const result = spawnSync(helper, args, { cwd: tree, env: { PATH: process.env.PATH, ...f.env, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" }); expect(result.status, result.stderr).toBe(0); return result.stdout; };
  fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
  const targetPath = "records/company_desired_capability/report.json";
  const target = { version: "omos.company-desired-capability/v1", capability: "general_task", objective: "Retain documents/team/report.txt with the text desired report complete.", criteria: ["The report contains the requested text."], paths: ["documents/team/"], observations: [], enabled: true };
  const seed = (data: object, filename = targetPath) => {
    fossil("update", "trunk"); mkdirSync(join(tree, filename.substring(0, filename.lastIndexOf("/"))), { recursive: true });
    writeFileSync(join(tree, filename), filename === targetPath ? JSON.stringify({ entity: "company_desired_capability", id: "report", task: "operator-seed", data }) : JSON.stringify(data));
    fossil("addremove"); fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Record accepted operator fixture state");
  };
  seed(target);
  const admin = async (input: object) => {
    const file = join(f.home, "desired-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input }));
    const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
  };
  const initialized = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "desired-worker", "--json"]); expect(keyed.code, keyed.stderr).toBe(0);
  const key = JSON.parse(keyed.stdout), actions = ["create_view", "discover", "read", "status", "checkpoint", "submit", "execution", "execute_task"];
  await admin({ action: "grant", revision: initialized.revision, grant: { id: "desired-worker", actor: "reconciler", public_key: (key.model_data ?? key).public_key, paths: ["documents/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client, otherClient, desired;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any; expect(boot.features.desired_state).toBe(true);
    const config = join(f.home, "desired-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, actor: "reconciler", grant: "desired-worker", key_handle: "desired-worker", issuer: boot.issuer, epoch: boot.epoch, actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    desired = createDesiredHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    const policy = { version: "omos.company-reconciliation-policy/v1", workspace: boot.workspace, id: "daily-report", target_path: targetPath, actor: "reconciler", grant: "desired-worker", allowed_paths: ["documents/team/"], execution_capability: "general_task", enabled: true };
    const registered = await desired.call({ change: "register", policy }); expect(registered.ok, JSON.stringify(registered)).toBe(true);
    const denied = await fetch(service.url + "/v1/company/desired", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ version: "omos.company-desired-api/v1", workspace: boot.workspace, request: { version: "omos.company-desired/v1", change: "tick" } }) }); expect(denied.status).toBe(401);
    const tick = async () => { const reply = await desired.call({ change: "tick", actor: "reconciler", grant: "desired-worker", limit: 1 }); expect(reply.ok, JSON.stringify(reply)).toBe(true); return reply.policies[0]; };
    const first = await tick(); expect(first.failure, JSON.stringify(first)).toBeNull(); expect(first.state.phase).toBe("unavailable"); expect(first.state.task).toMatch(/^[a-f0-9]{64}$/);
    expect((await tick()).state.task).toBe(first.state.task);
    expect(inference.counts().actors).toBe(0);
    const readDesired = async (rest: object = {}) => {
      const result = await client.call("company_workspace", { version: "omos.company/v1", action: "status", entity: "omos_company_reconciliation", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, limit: 32, ...rest });
      expect(result.isError, JSON.stringify(result)).not.toBe(true); return JSON.parse(result.content[0].text);
    };
    const own = await readDesired(); expect(own.policies.map(policy => policy.policy)).toEqual(["daily-report"]); expect(own.policies[0].state).toBe("unavailable");
    const otherKeyed = await f.run(["fossil", "company-key", "desired-other", "--json"]); expect(otherKeyed.code, otherKeyed.stderr).toBe(0); const otherKey = JSON.parse(otherKeyed.stdout);
    await admin({ action: "grant", revision: (await admin({ action: "status" })).revision, grant: { id: "desired-other", actor: "other-participant", public_key: (otherKey.model_data ?? otherKey).public_key, paths: ["documents/"], actions: ["status"], expires_ms: Date.now() + 3600000 } });
    const otherPolicy = await desired.call({ change: "register", policy: { ...policy, id: "private-other-policy", actor: "other-participant", grant: "desired-other", enabled: false } }); expect(otherPolicy.ok, JSON.stringify(otherPolicy)).toBe(true);
    const otherConfig = join(f.home, "desired-other-client.json"); writeFileSync(otherConfig, JSON.stringify({ ...JSON.parse(readFileSync(config, "utf8")), actor: "other-participant", grant: "desired-other", key_handle: "desired-other", actions: ["status"] }), { mode: 0o600 });
    otherClient = await createCompanyClient(otherConfig, { home: f.home });
    const hidden = await otherClient.call("company_workspace", { version: "omos.company/v1", action: "status", entity: "omos_company_reconciliation", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, limit: 32 }); expect(hidden.isError, JSON.stringify(hidden)).not.toBe(true);
    expect(JSON.parse(hidden.content[0].text).policies.map(policy => policy.policy)).toEqual(["private-other-policy"]);
    expect((await readDesired({ revision: own.index_revision })).policies.map(policy => policy.policy)).toEqual(["daily-report"]);
    expect(JSON.stringify(await readDesired())).not.toContain("private-other-policy");
    let row = (await admin({ action: "workers", worker: { change: "inspect", view: first.state.view } })).jobs[0];
    expect(row.grant.paths).toEqual(target.paths); expect(row.record.state).toBe("queued"); expect(row.contract.objective).toContain("desired report complete");
    row = (await admin({ action: "workers", worker: { change: "plan", operation: crypto.randomUUID(), view: first.state.view, expected_sha256: row.sha256 } })).jobs[0];
    const planDeadline = Date.now() + 60000;
    while (row.planning_required && Date.now() < planDeadline) {
      await Bun.sleep(50); row = (await admin({ action: "workers", worker: { change: "inspect", view: first.state.view } })).jobs[0];
      if (row.planning_state === "planned") row = (await admin({ action: "workers", worker: { change: "plan", operation: crypto.randomUUID(), view: first.state.view, expected_sha256: row.sha256 } })).jobs[0];
    }
    expect(row.planning_required).toBe(false);
    row = (await admin({ action: "workers", worker: { change: "claim", operation: crypto.randomUUID(), view: first.state.view, expected_sha256: row.sha256, execution: { runtime: "desired-fixture", generation: 0 } } })).jobs[0];
    const execution = { runtime: row.record.runtime, generation: row.record.generation };
    const send = async (action: string, rest: object = {}, success = true) => { const result = await client.call("company_workspace", { version: action === "read" ? "omos.company/v2" : "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest }); if (success) expect(result.isError, JSON.stringify(result)).not.toBe(true); else expect(result.isError, JSON.stringify(result)).toBe(true); return success ? JSON.parse(result.content[0].text) : result; };
    const checkpoint = await send("checkpoint", { view: first.state.view, execution, revision: row.view_revision, path: "documents/team/report.txt", content: "desired report complete" });
    await send("submit", { view: first.state.view, execution, revision: checkpoint.revision, candidate: "Retained the requested company report." });
    const reviewDeadline = Date.now() + 120000; let status;
    do { status = await send("status", { view: first.state.view }); if (!["queued", "running"].includes(status.job?.state)) break; await Bun.sleep(50); } while (Date.now() < reviewDeadline);
    expect(status.publication, JSON.stringify(status)).not.toBeNull();
    const met = await tick(); expect(met.failure, JSON.stringify(met)).toBeNull(); expect(met.state.phase).toBe("met");
    expect((await readDesired()).policies[0].state).toBe("met");
    const stable = (await admin({ action: "status" })).revision;
    expect((await tick()).state.task).toBe(first.state.task); expect((await admin({ action: "status" })).revision).toBe(stable);
    seed({ unrelated: true }, "documents/unrelated/change.json");
    expect((await tick()).state.phase).toBe("met"); expect((await tick()).state.task).toBe(first.state.task);
    seed({ ...target, objective: "Update the report for the second requested outcome." });
    const second = await tick(); expect(second.failure, JSON.stringify(second)).toBeNull(); expect(second.state.task).not.toBe(first.state.task);
    seed({ input: "New accepted input supersedes the pending episode." }, "documents/team/input.json");
    expect((await admin({ action: "workers", worker: { change: "inspect", view: second.state.view } })).jobs[0].authority_live).toBe(false);
    const drifted = await tick(); expect(drifted.failure, JSON.stringify(drifted)).toBeNull(); expect(drifted.state.task).not.toBe(second.state.task);
    seed({ ...target, objective: "A newer desired outcome supersedes the pending task." });
    const stale = (await admin({ action: "workers", worker: { change: "inspect", view: second.state.view } })).jobs[0]; expect(stale.authority_live).toBe(false);
    const third = await tick(); expect(third.failure, JSON.stringify(third)).toBeNull(); expect(third.state.task).not.toBe(second.state.task);
    seed({ ...target, objective: "Update the report for the second requested outcome." });
    expect((await admin({ action: "workers", worker: { change: "inspect", view: second.state.view } })).jobs[0].authority_live).toBe(false);
    const restored = await tick(); expect(restored.failure, JSON.stringify(restored)).toBeNull(); expect(restored.state.task).not.toBe(second.state.task); expect(restored.state.task).not.toBe(third.state.task);
    seed({ ...target, paths: ["ui/"] }); expect((await tick()).failure).toBe("CompanyAccessDenied");
    expect(inference.counts().actors).toBe(0);
    const disabled = await desired.call({ change: "register", expected_sha256: registered.sha256, policy: { ...policy, enabled: false } }); expect(disabled.ok, JSON.stringify(disabled)).toBe(true);
    expect((await tick()).failure).toBe("CompanyDesiredStatePaused");
    const verified = await f.run(["fossil", "verify", "--json"], {}, 180000); expect(verified.code, verified.stderr).toBe(0);
  } finally { desired?.close(); otherClient?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 600000);


test("public worker activity filters private fields and preserves Unicode text chunks", () => {
  const text = "A portable workspace λ 漢字\n".repeat(700);
  const selected = publicWorkerEvents({ type: "text_delta", text, reasoning: "Do not copy", provider_state: { opaque: true } });
  expect(selected.map(event => event.text).join("")).toBe(text);
  expect(selected.every(event => Buffer.byteLength(event.text) <= 2048)).toBe(true);
  expect(selected.every(event => Object.keys(event).sort().join(",") === "text,type")).toBe(true);
  expect(publicWorkerEvents({ type: "reasoning", text: "private" })).toEqual([]);
  expect(publicWorkerEvents({ type: "result", data: { error: "SessionNotFound", provider_state: "private" } })).toEqual([{ type: "error", code: "SessionNotFound" }]);
  expect(publicWorkerEvents({ type: "result", data: { error: "private provider message" } })).toEqual([{ type: "error", code: "WorkerNativeInvocationFailed" }]);
  expect(publicWorkerEvents({ type: "tool_start", call_id: "tool", name: "read_file", path: "documents/team/a", arguments: { credential: "private" } })).toEqual([{ type: "tool_start", call_id: "tool", name: "read_file", path: "documents/team/a", action: null }]);
});

for (const interactive of [false, true]) test(`company public activity streams the native runtime without publishing its claims and resumes exact acknowledged pages${interactive ? " with authenticated human input" : ""}`, async () => {
  const f = fixture(), privateWorker = fixture();
  let answered = false;
  const inference = model(privateWorker, (body, count) => {
    if (interactive && count === 2) return { tool_calls: [{ index: 0, id: "public-question", type: "function", function: { name: "ask_user_question", arguments: JSON.stringify({ questions: [{ question: "Which presentation should the retained report use?", options: [{ label: "Brief" }, { label: "Detailed" }] }] }) } }] };
    if (interactive && count === 3) answered = body.messages.some(message => message.role === "tool" && JSON.stringify(message.content).includes("Brief"));
    return count === 1 ? { content: "Preparing the portable document.\n", tool_calls: [
    { index: 0, id: "write-visible", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "documents/team/progress.txt", content: "Retained privately before company review." }) } },
    { index: 1, id: "print-visible", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: "printf 'native-visible-output λ 漢字\\n'", timeout_ms: 10000 } }) } },
  ] } : { content: "Fixture complete.\n\n- Retained **portable** document. λ 漢字" };
  });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async (input: object) => { const file = join(f.home, "activity-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "activity-owner", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "read", "status", "execution", "execute_task", "checkpoint", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "activity-owner", actor: "activity-user", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client, otherClient, control, inputControl;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any; expect(boot.features.actor_activity).toBe(true);
    const config = join(f.home, "activity-owner.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "activity-user", grant: "activity-owner", key_handle: "activity-owner", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const send = async (action: string, rest: object = {}) => { const result = await client.call("company_workspace", { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest }); expect(result.isError, JSON.stringify({ request: { action, ...rest }, response: result })).not.toBe(true); return JSON.parse(result.content[0].text); };
    const view = await send("create_view", { revision: boot.revision, objective: "Retain a company proposal separately from its actor activity." });
    const notStarted = await send("status", { view: view.view, entity: "omos_company_activity", limit: 2 }); expect(notStarted.events).toEqual([]); expect(notStarted.ended).toBe(false);
    const claimed = await send("execution", { view: view.view, revision: view.revision, execution_change: "claim", execution: { runtime: "activity-runtime", generation: 0 }, execution_lease_ms: 300000 });
    const execution = { runtime: "activity-runtime", generation: claimed.generation };
    if (interactive) {
      const actor = await createCompanyClient(config, { home: f.home, binding: { view: view.view, execution, expiresMs: Date.now() + 120000, actions: ["status", "checkpoint"] } });
      try {
        expect(actor.tools()[1].inputSchema.properties.action.enum).not.toContain("execute_task");
        const selfDecision = await actor.call("company_workspace", { version: "omos.company/v1", action: "execute_task", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, content: "{}" });
        expect(selfDecision.isError).toBe(true); expect(JSON.parse(selfDecision.content[0].text).error).toBe("CompanyWorkerScopeDenied");
      } finally { actor.close(); }
    }
    control = createActivityHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) });
    inputControl = interactive ? createInputHttpControl({ endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) }) : null;
    let lost = false, appendCalls = 0, inputOffset, inputRequestId, emptyInputObserved = false;
    const inputTransport = inputControl;
    let claimLost = false, inputAckLost = false;
    if (inputControl) inputControl = { close: () => inputTransport.close(), async call(request, signal) {
      const reply = await inputTransport.call(request, signal);
      if (reply.ok && request.action === "inspect" && reply.commands.length === 0 && !emptyInputObserved) {
        emptyInputObserved = true;
        await send("execute_task", { view: view.view, revision: view.revision, execution, content: JSON.stringify({ version: "omos.company-task-control/v1", mode: "input", event_offset: inputOffset, request_id: inputRequestId, answers: ["Brief"] }) });
      }
      if (reply.ok && request.action === "claim" && !claimLost) { claimLost = true; return { ok: false, uncertain: true }; }
      if (reply.ok && request.action === "acknowledge" && !inputAckLost) { inputAckLost = true; return { ok: false, uncertain: true }; }
      return reply;
    } };
    const sink = { async call(request, signal) {
      const reply = await control.call(request, signal);
      if (request.action === "append") {
        appendCalls++;
        const index = request.events.findIndex(raw => JSON.parse(raw).type === "input_required");
        if (interactive && reply.ok && index !== -1 && inputOffset === undefined) {
          inputOffset = request.offset + index;
          inputRequestId = JSON.parse(request.events[index]).request_id;
        }
        if (!lost && reply.ok) { lost = true; return { ok: false, uncertain: true }; }
      }
      return reply;
    } };
    const result = await runWorkerNative({ launch: () => spawn(join(import.meta.dir, "../../zig-out/bin/fx"), ["ui-host", "--stdio"], { cwd: privateWorker.cwd, env: { PATH: process.env.PATH, ...privateWorker.env, USER: "fixture", LOGNAME: "fixture", LANG: "C", LC_ALL: "C" }, stdio: ["pipe", "pipe", "pipe"] }), control: sink, inputControl, view: view.view, execution, prompt: "Retain documents/team/progress.txt and print the requested visible output. Return the short Markdown response.", timeout: 240000 });
    expect(result.code, result.stderr).toBe(0); expect(result.killed).toBe(false); expect(inference.counts().actors).toBe(interactive ? 3 : 2); expect(lost).toBe(true); expect(appendCalls).toBeGreaterThan(1);
    if (interactive) {
      expect(answered).toBe(true);
      const delivered = await send("status", { view: view.view, entity: "omos_company_task_input", record_id: "1", offset: inputOffset });
      expect(delivered.state).toBe("applied");
      expect(emptyInputObserved).toBe(true); expect(claimLost).toBe(true); expect(inputAckLost).toBe(true);
      for (const rejected of [
        { execution: { ...execution, generation: execution.generation + 1 }, request_id: 1 },
        { execution, request_id: 999 },
      ]) {
        const result = await client.call("company_workspace", { version: "omos.company/v1", action: "execute_task", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, view: view.view, revision: view.revision, execution: rejected.execution, content: JSON.stringify({ version: "omos.company-task-control/v1", mode: "input", event_offset: inputOffset, request_id: rejected.request_id, answers: ["Brief"] }) });
        expect(result.isError).toBe(true);
      }

      const changedDelivery = await inputTransport.call({ action: "claim", view: view.view, execution, event_offset: inputOffset, delivery: crypto.randomUUID() });
      expect(changedDelivery.ok).toBe(false); expect(changedDelivery.error).toBe("CompanyInputOutcomeUncertain");
      const queuedView = await send("create_view", { revision: boot.revision, objective: "Cancel a queued company invocation before an actor starts." });
      await admin({ action: "workers", worker: { change: "queue", operation: crypto.randomUUID(), view: queuedView.view } });
      const cancelled = await send("execute_task", { view: queuedView.view, revision: queuedView.revision, content: JSON.stringify({ version: "omos.company-task-control/v1", mode: "cancel" }) });
      expect(cancelled.state).toBe("cancelled");
      const cancelledStatus = await send("status", { view: queuedView.view });
      expect(cancelledStatus.hosted_execution.job.state).toBe("cancelled"); expect(cancelledStatus.publication).toBeNull();
    }
    const collected: any[] = []; let offset = 0, revision, final;
    do { final = await send("status", { view: view.view, entity: "omos_company_activity", record_id: "1", limit: 2, offset, ...(revision ? { revision } : {}) }); revision ??= final.index_revision; expect(final.index_revision).toBe(revision); expect(final.events.length).toBeLessThanOrEqual(2); collected.push(...final.events); offset = final.resume_offset; } while (final.next_offset !== null);
    expect(collected.map(event => event.offset)).toEqual(Array.from({ length: collected.length }, (_, index) => index)); expect(final.ended).toBe(true); expect(final.authority).toBe("actor_public_activity_only");
    expect(collected.some(event => event.data.type === "text_delta" && event.data.text.includes("portable"))).toBe(true);
    expect(collected.some(event => event.data.type === "tool_start" && event.data.name === "fossil_workspace")).toBe(true);
    expect(collected.some(event => event.data.type === "tool_end")).toBe(true);
    expect(collected.some(event => event.data.type === "command_output" && event.data.text.includes("native-visible-output"))).toBe(true);
    const unchanged = await send("status", { view: view.view }); expect(unchanged.revision).toBe(view.revision); expect(unchanged.publication).toBeNull();
    const conflict = await control.call({ action: "append", view: view.view, execution, offset: 0, events: [JSON.stringify({ type: "text_delta", text: "Replace retained history" })] }); expect(conflict.ok).toBe(false); expect(conflict.error).toBe("CompanyActivityConflict");
    const stale = await control.call({ action: "inspect", view: view.view, execution: { ...execution, generation: execution.generation + 1 } }); expect(stale.ok).toBe(false);
    await admin({ action: "revoke", revision: (await admin({ action: "status" })).revision, id: "activity-owner" });
    const revoked = await client.call("company_workspace", { version: "omos.company/v1", action: "status", view: view.view, entity: "omos_company_activity", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, limit: 2 }); expect(revoked.isError).toBe(true);
    const verified = await f.run(["fossil", "verify", "--json"], {}, 180000); expect(verified.code, verified.stderr).toBe(0);
  } finally { inputControl?.close(); control?.close(); otherClient?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 600000);


test("company clients recover a closed bootstrap read without replaying a lost mutation acknowledgement", async () => {
  const f = fixture(), workspace = "a".repeat(64);
  const keys = generateKeyPairSync("ed25519");
  const issuer = keys.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
  mkdirSync(join(f.home, ".fx/company-keys"), { recursive: true });
  writeFileSync(join(f.home, ".fx/company-keys/bootstrap.seed"), randomBytes(32), { mode: 0o600 });
  let reads = 0, mutations = 0, epoch = 1;
  const server = http.createServer((request, response) => {
    if (request.method === "GET") {
      if (++reads === 1) { request.socket.destroy(); return; }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ version: "omos.company/v1", workspace, issuer, epoch: 1 }));
    } else {
      let body = ""; request.setEncoding("utf8"); request.on("data", chunk => { body += chunk; });
      request.on("end", () => {
        const input = JSON.parse(body), payload = JSON.parse(input.payload);
        if (payload.action !== "status") { mutations++; request.socket.destroy(); return; }
        const receipt = JSON.stringify({ version: "omos.company-receipt/v1", workspace, actor: "user", grant: "user", operation: payload.operation, request_hash: createHash("sha256").update(input.payload).digest("hex"), action: "status", epoch, result: { state: "ready" } });
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ issuer, payload: receipt, signature: sign(null, Buffer.from(receipt), keys.privateKey).toString("hex") }));
      });
    }
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const config = join(f.home, "bootstrap-client.json");
  writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: `http://127.0.0.1:${(server.address() as any).port}`, workspace, issuer, epoch: 1, actor: "user", grant: "user", key_handle: "bootstrap", actions: ["create_view", "status"] }), { mode: 0o600 });
  const client = await createCompanyClient(config, { home: f.home });
  try {
    const context = await client.call("company_context", {});
    expect(context.isError, JSON.stringify(context)).not.toBe(true); expect(reads).toBe(2);
    const inspect = () => client.call("company_workspace", { version: "omos.company/v1", action: "status", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
    const read = await inspect(); expect(read.isError, JSON.stringify(read)).not.toBe(true); expect(reads).toBe(2);
    epoch = 2; const drift = await inspect(); expect(drift.isError).toBe(true); expect(JSON.parse(drift.content[0].text).error).toBe("CompanyOutcomeUnverified"); expect(reads).toBe(2); epoch = 1;
    const changed = await client.call("company_workspace", { version: "omos.company/v1", action: "create_view", objective: "Retain an uncertain acknowledgement", revision: "b".repeat(64), operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
    expect(changed.isError).toBe(true);
    const failure = JSON.parse(changed.content[0].text);
    expect(failure.error).toBe("CompanyOutcomeUnknown"); expect(failure.failure_stage).toBe("signed_dispatch"); expect(failure.failure_code).toMatch(/^[A-Za-z0-9_]{1,48}$/);
    expect(changed.content[0].text).not.toContain(config);
    expect(mutations).toBe(1); expect(reads).toBe(3);
  } finally { client.close(); server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); }
});

test("worker native delivery stops and joins its process when activity retention fails", async () => {
  const source = String.raw`import readline from 'node:readline';
const input = readline.createInterface({input:process.stdin});
const send = value => process.stdout.write(JSON.stringify({version:'omos.ui-host/v1',...value})+'\n');
input.on('line',line=>{const request=JSON.parse(line);send({type:'response',id:request.id,result:{},err:null});if(request.method==='prompt'){send({type:'event',turn:request.id,cursor:1,data:{type:'turn_start'}});send({type:'event',turn:request.id,cursor:2,data:{type:'input_required',kind:'question',request_id:1,questions:[{question:'Retain this request?',options:[{label:'Yes'}]}]}});}});`;
  let child, appends = 0;
  const started = Date.now();
  await expect(runWorkerNative({
    launch: () => child = spawn(process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath, ["--input-type=module", "-e", source], { stdio: ["pipe", "pipe", "pipe"] }),
    control: { async call(request) { if (request.action === "inspect") return { ok: true, next_offset: 0, ended: false }; appends++; return { ok: false, uncertain: true, error: "WorkerControlOutcomeUnknown" }; } },
    view: "view", execution: { runtime: "runtime", generation: 1 }, prompt: "Retain the pending request", timeout: 2000,
  })).rejects.toMatchObject({ message: "WorkerActivityRetentionPending", retention: { kind: "activity", action: "append", offset: 0, error: "WorkerControlOutcomeUnknown" } });
  expect(appends).toBe(2); expect(Date.now() - started).toBeLessThan(5000);
  expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
}, 10000);

for (const corruption of ["none", "incomplete", "changed"]) test(`worker native recovery replays its saved public episode without prompting an actor (${corruption})`, async () => {
  const source = String.raw`import readline from 'node:readline';
const input=readline.createInterface({input:process.stdin});
const send=value=>process.stdout.write(JSON.stringify({version:'omos.ui-host/v1',type:'response',...value})+'\n');
const events=[{type:'turn_start'},{type:'session',session_id:'PrivateSession12'},{type:'input_required',kind:'question',request_id:7,questions:[{question:'Retain the saved choice?',options:[{label:'Yes'}]}]},{type:'assistant_started'},{type:'tool_start',call_id:'saved-file',name:'write_file',path:'documents/team/result.txt'},{type:'tool_end',call_id:'saved-file',outcome:'completed'},{type:'text_delta',text:'Saved **answer**.'},{type:'result',data:{final_output:'Saved **answer**.',provider_replay:'fixture-private-checkpoint'}},{type:'turn_end',exit_code:0}].map((data,index)=>({version:'omos.ui-host/v1',type:'event',turn:'saved-native-turn',cursor:index+1,data}));
if('${corruption}'==='incomplete')events.pop();if('${corruption}'==='changed')events[4].cursor=99;
input.on('line',line=>{const request=JSON.parse(line);if(request.method==='prompt')process.exit(77);if(request.method==='initialize')send({id:request.id,result:{},err:null});else if(request.method==='session.events')send({id:request.id,result:{events:request.params.offset===0?events:[],next_offset:request.params.offset===0?1024:request.params.offset,active:false},err:null});});`;
  let child, offset = 0;
  const retained = [];
  const invocation = runWorkerNative({
    launch: () => child = spawn(process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath, ["--input-type=module", "-e", source], { stdio: ["pipe", "pipe", "pipe"] }),
    control: { async call(request) { if (request.action === "inspect") return { ok: true, next_offset: 0, ended: false }; expect(request.offset).toBe(offset); retained.push(...request.events.map(JSON.parse)); offset += request.events.length; return { ok: true, next_offset: offset }; } },
    view: "view", execution: { runtime: "collector", generation: 3 }, prompt: "", session: "PrivateSession12", replayOnly: true, timeout: 3000,
  });
  if (corruption !== "none") {
    await expect(invocation).rejects.toThrow(corruption === "incomplete" ? "WorkerNativeHistoryIncomplete" : "WorkerNativeHistoryChanged");
    expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
    return;
  }
  const result = await invocation;
  expect(result.code).toBe(0); expect(result.killed).toBe(false); expect(child.exitCode).toBe(0);
  expect(retained.map(event => event.type)).toEqual(["turn_start", "notice", "assistant_started", "tool_start", "tool_end", "text_delta", "turn_end"]);
  expect(retained.find(event => event.type === "notice").text).toContain("Retain the saved choice?");
  expect(retained.find(event => event.type === "text_delta").text).toBe("Saved **answer**.");
  expect(JSON.stringify(retained)).not.toContain("PrivateSession12"); expect(JSON.stringify(retained)).not.toContain("fixture-private-checkpoint");
}, 10000);

for (const cancelled of [false, true]) test(`company retirement archives public history after revocation without restoring execution${cancelled ? " after live cancellation" : ""}`, async () => {
  const f = fixture(), sourceWorker = fixture();
  const host = model(f, () => { throw Error("Passive retention must not start company actors"); });
  model(sourceWorker, () => ({ content: "Retained public history for passive archival." }));
  expect((await sourceWorker.run(["fossil", "init", "--json"])).code).toBe(0);
  expect((await sourceWorker.run(["ask", "Retain this public history.", "--json"], {}, 180000)).code).toBe(0);
  const state = JSON.parse((await sourceWorker.run(["fossil", "status", "--json"])).stdout), sourceTask = state.tasks[0];
  const revision = sourceWorker.fossil("timeline", "ancestors", sourceTask.branch, "--type", "ci", "--limit", "1", "--format", "%H").trim().split(/\s+/)[0];
  const filename = join(sourceWorker.home, "retired-public.fossil");
  expect((await sourceWorker.run(["fossil", "export", filename, "--json"])).code).toBe(0);
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const adminResult = async input => { const file = join(f.home, "retirement-admin.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); return f.run(["fossil", "company", file, "--json"]); };
  const admin = async input => { const result = await adminResult(input); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const key = await f.run(["fossil", "company-key", "retired-worker", "--json"]); expect(key.code).toBe(0);
  const actions = ["create_view", "status", "read", "execution", "checkpoint", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "retired-worker", actor: "worker", public_key: (JSON.parse(key.stdout).model_data ?? JSON.parse(key.stdout)).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client, archive;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    expect(boot.features.retired_archives).toBe(true);
    const config = join(f.home, "retired-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "retired-worker", key_handle: "retired-worker", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const send = async input => { const result = await client.call("company_workspace", { version: "omos.company/v1", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...input }); expect(result.isError, JSON.stringify(result)).not.toBe(true); return JSON.parse(result.content[0].text); };
    const view = await send({ action: "create_view", revision: boot.revision, objective: "Preserve the revoked worker's history without publishing its claims." });
    const workers = async worker => (await admin({ action: "workers", worker })).jobs[0];
    let row = await workers({ change: "queue", operation: crypto.randomUUID(), view: view.view });
    row = await workers({ change: "claim", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256, execution: { runtime: "retired-runtime", generation: 0 } });
    const execution = { runtime: "retired-runtime", generation: 1 };
    const checkpoint = { version: "omos.company-worker-checkpoint/v1", runtime: execution.runtime, generation: 1, image: createHash("sha256").update(JSON.stringify([boot.workspace, view.view, execution.runtime, 1])).digest("hex"), source_revision: row.view_revision, model: "fixture-model", phase: "prepared", export_directory: null };
    row = await workers({ change: "checkpoint", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256, execution, checkpoint });
    row = await workers({ change: "checkpoint", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256, execution, checkpoint: { ...checkpoint, phase: "running" } });
    const active = await adminResult({ action: "workers", worker: { change: "retire", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256 } });
    expect(active.code).not.toBe(0); expect(active.stderr).toContain("CompanyWorkerStillResumable");
    if (cancelled) row = await workers({ change: "cancel", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256 });
    else await admin({ action: "revoke", revision: (await admin({ action: "status" })).revision, id: "retired-worker" });
    const request = { change: "retire", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256 };
    row = await workers(request);
    expect(row.record.state).toBe("cancelled"); expect(row.execution.runtime).toBeNull(); expect(row.record.checkpoint.image).toBe(checkpoint.image);
    expect((await workers(request)).sha256).toBe(row.sha256);
    if (cancelled) {
      const revival = await client.call("company_workspace", { version: "omos.company/v1", action: "execution", view: view.view, revision: row.view_revision, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, execution: { runtime: "resurrected", generation: 1 }, execution_change: "claim", execution_lease_ms: 300000 });
      expect(revival.isError).toBe(true); expect((await workers({ change: "inspect", view: view.view })).execution.runtime).toBeNull();
      const missing = await send({ action: "read", view: view.view, revision: row.view_revision, path: "documents/team/absent.txt" });
      expect(missing.exists).toBe(false);
      await admin({ action: "revoke", revision: (await admin({ action: "status" })).revision, id: "retired-worker" });
    }
    const requeue = await adminResult({ action: "workers", worker: { change: "requeue", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256 } });
    expect(requeue.code).not.toBe(0); expect(requeue.stderr).toContain("CompanyWorkerRetired");
    const owner = { endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) };
    archive = createArchiveHttpControl(owner);
    const source = { workspace: state.workspace_id, task: sourceTask.id, revision };
    await expect(retainWorkerArchive({ filename, uid: process.getuid!(), source, view: view.view, execution, control: archive })).rejects.toThrow("WorkerArchiveRetentionPending");
    const passive = { call: (request, signal) => archive.call({ ...request, version: "omos.company-retired-archive-write/v1" }, signal) };
    const retained = await retainWorkerArchive({ filename, uid: process.getuid!(), source, view: view.view, execution, control: passive });
    expect(retained.complete).toBe(true);
    const receipt = JSON.parse(f.fossil("cat", `company/archives/${row.record.binding.task}/${retained.archive_id}/receipt.json`, "-r", "omos-company"));
    expect(receipt.retirement).toBe(row.sha256); expect(receipt.authority).toBe("actor_public_history_only"); expect(receipt.source.sha256).toBe(createHash("sha256").update(readFileSync(filename)).digest("hex"));
    const denied = await client.call("company_workspace", { version: "omos.company/v1", action: "execution", view: view.view, revision: view.revision, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, execution: { runtime: "resurrected", generation: 1 }, execution_change: "claim", execution_lease_ms: 300000 });
    expect(denied.isError).toBe(true); expect(host.counts()).toEqual({ actors: 0, assessments: 0 });
    expect((await f.run(["fossil", "verify", "--json"], {}, 180000)).code).toBe(0);
  } finally { archive?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 600000);

test("worker coordinator retains inactive images without starving unrelated work or claiming compute", async () => {
  const common = { sha256: "a".repeat(64), authority_live: true, contract: {}, request: "Retain a document", basis: {}, grant: {}, execution: null, task_state: "active", review_job_id: null, pending_operation: null, publication: null };
  const absent: any = { ...structuredClone(common), record: { binding: { view: "absent" }, state: "completed", checkpoint: {}, generation: 1 } };
  const retained: any = { ...structuredClone(common), authority_live: false, record: { binding: { view: "retained" }, state: "cancelled", checkpoint: {}, generation: 1 } };
  const actor: any = { ...structuredClone(common), record: { binding: { view: "live" }, state: "queued", generation: 0, max_runtime_ms: 60000, expires_ms: 0 } };
  const calls: any[] = [], rows = [absent, retained, actor];
  let stopped = false, ran = 0, retirements = 0;
  const control = { async call(input) {
    calls.push(input);
    if (input.change === "inspect") return { ok: true, jobs: structuredClone(input.view ? rows.filter(row => row.record.binding.view === input.view) : rows), next_offset: null };
    expect(input.view).toBe("live");
    if (input.change === "claim") { actor.record = { ...actor.record, state: "running", runtime: input.execution.runtime, generation: 1, operation: input.operation, expires_ms: Date.now() + 120000 }; actor.execution = { runtime: input.execution.runtime, generation: 1 }; }
    else if (input.change === "finish") { actor.record.state = input.outcome; actor.record.operation = input.operation; }
    return { ok: true, jobs: [structuredClone(actor)], next_offset: null };
  } };
  const coordinator = createWorkerCoordinator({ control, concurrency: 2, backend: {
    async canRetire(row) { return row.record.binding.view === "retained"; },
    async retire(_row, signal) { retirements++; await new Promise<void>(resolve => signal.addEventListener("abort", () => { stopped = true; resolve(); }, { once: true })); },
    async run() { ran++; return { outcome: "waiting" }; },
  } });
  expect((await coordinator.tick()).started).toBe(1);
  await new Promise(resolve => setTimeout(resolve, 0));
  await coordinator.tick();
  expect(ran).toBe(1); expect(retirements).toBe(1); expect(stopped).toBe(false);
  expect(calls.filter(call => call.change === "claim").map(call => call.view)).toEqual(["live"]);
  await coordinator.close(); expect(stopped).toBe(true);
});

test("worker archive resumes an interrupted exclusive export link and preserves unrelated aliases", async () => {
  const fs = await import("node:fs/promises");
  const f = fixture(), filename = join(f.home, "actor.fossil");
  const pending = filename + ".pending-" + "a".repeat(32);
  await fs.mkdir(pending);
  const bytes = Buffer.alloc(512); bytes.write("SQLite format 3\0");
  await fs.writeFile(join(pending, "workspace.fossil"), bytes, { mode: 0o600 });
  await fs.link(join(pending, "workspace.fossil"), filename);
  let calls = 0;
  const control = { async call(request) {
    calls++;
    return { ok: true, view: request.view, sha256: request.source.sha256, bytes: request.source.bytes, archive_id: "d".repeat(64), revision: "e".repeat(64), offset: request.offset, resume_offset: request.action === "inspect" ? 0 : bytes.length, next_offset: request.action === "inspect" ? 0 : null, complete: request.action !== "inspect" };
  } };
  const parameters = { filename, uid: process.getuid!(), source: { workspace: "a".repeat(64), task: "b".repeat(64), revision: "c".repeat(64) }, view: "f".repeat(64), execution: { runtime: "fixture", generation: 1 }, control };
  const receipt = await retainWorkerArchive(parameters);
  expect(receipt.sha256).toBe(createHash("sha256").update(bytes).digest("hex")); expect(receipt.complete).toBe(true);
  expect((await fs.stat(filename)).nlink).toBe(1); expect(existsSync(pending)).toBe(false); expect(calls).toBe(2);
  const unrelated = join(f.home, "unrelated-copy");
  await fs.link(filename, unrelated);
  calls = 0;
  await expect(retainWorkerArchive(parameters)).rejects.toThrow("InvalidWorkerArchiveFile");
  expect(calls).toBe(0); expect(existsSync(unrelated)).toBe(true); expect((await fs.stat(filename)).nlink).toBe(2);
  await fs.mkdir(pending);
  await fs.writeFile(join(pending, "workspace.fossil"), bytes);
  await expect(retainWorkerArchive(parameters)).rejects.toThrow("InvalidWorkerArchiveFile");
  expect(existsSync(join(pending, "workspace.fossil"))).toBe(true); expect(existsSync(unrelated)).toBe(true); expect(calls).toBe(0);
});

test("worker heartbeat resolves one lost acknowledgement with its original process nonce", async () => {
  const description = { workspace: "a".repeat(64), package_sha256: "b".repeat(64), model_handle: "fixture-model", subjects: [{ actor: "user", grant: "user" }], validation_handles: [] };
  const id = createHash("sha256").update(JSON.stringify([description.workspace, description.model_handle, description.subjects])).digest("hex");
  const registration = { version: "omos.company-runtime-registration/v1", id, workspace: description.workspace, package_sha256: description.package_sha256, model_handle: description.model_handle, isolation: "omos.linux-worker/v1", subjects: description.subjects, validation_handles: [] };
  const sha256 = createHash("sha256").update(JSON.stringify(registration)).digest("hex");
  const calls: any[] = [];
  const runtime = await advertiseWorkerRuntime({ description, control: { async call(request) {
    calls.push(structuredClone(request));
    if (request.change === "inspect") return { ok: true, runtimes: [{ sha256 }] };
    if (request.change === "heartbeat" && calls.filter(call => call.change === "heartbeat").length === 1) return { ok: false, error: "WorkerControlOutcomeUnknown", uncertain: true };
    return { ok: true, live: request.change !== "stop", sha256 };
  } } });
  const heartbeat = calls.filter(call => call.change === "heartbeat");
  expect(heartbeat).toHaveLength(2); expect(heartbeat[0]).toEqual(heartbeat[1]); expect(heartbeat[0].instance).toMatch(/^[0-9a-f]{64}$/);
  await runtime.close();
  let busy = 0;
  await expect(advertiseWorkerRuntime({ description, control: { async call(request) {
    if (request.change === "inspect") return { ok: true, runtimes: [{ sha256 }] };
    busy++; return { ok: false, error: "CompanyRuntimeBusy" };
  } } })).rejects.toThrow("WorkerRuntimeAlreadyActive");
  expect(busy).toBe(1);
});

test("worker export discards only unpublished clone staging files before retrying", async () => {
  const fs = await import("node:fs/promises");
  const f = fixture(), filename = join(f.home, "actor.fossil"), pending = filename + ".pending-" + "a".repeat(32);
  await fs.mkdir(pending);
  await fs.writeFile(join(pending, "workspace.fossil"), "An interrupted clone.");
  await fs.writeFile(join(pending, "workspace.fossil-journal"), "Its temporary journal.");
  const original = join(f.home, "original.fossil"); await fs.writeFile(original, "Original canonical repository.");
  await prepareWorkerExport(filename, process.getuid!());
  expect(existsSync(pending)).toBe(false); expect(await fs.readFile(original, "utf8")).toBe("Original canonical repository.");
  await fs.mkdir(pending);
  await fs.writeFile(join(pending, "workspace.fossil"), "A clone.");
  await fs.writeFile(join(pending, "document.txt"), "An unrelated file.");
  await prepareWorkerExport(filename, process.getuid!());
  expect(existsSync(join(pending, "document.txt"))).toBe(true); expect(existsSync(join(pending, "workspace.fossil"))).toBe(true);
  await fs.unlink(join(pending, "document.txt"));
  await fs.link(original, join(pending, "workspace.fossil-wal"));
  await prepareWorkerExport(filename, process.getuid!());
  expect(existsSync(join(pending, "workspace.fossil"))).toBe(true); expect((await fs.stat(original)).nlink).toBe(2);
  await fs.writeFile(filename, "A published destination.");
  await fs.unlink(join(pending, "workspace.fossil-wal"));
  await prepareWorkerExport(filename, process.getuid!());
  expect(existsSync(join(pending, "workspace.fossil"))).toBe(true); expect(await fs.readFile(filename, "utf8")).toBe("A published destination.");
});

test("worker model broker checks current signed execution before dispatching provider requests", async () => {
  const f = fixture(), socket = join(f.home, "model-fence.sock"), expiresMs = Date.now() + 120000;
  let providerCalls = 0, allowed = true, generation = 1;
  const provider = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() { providerCalls++; return Response.json({ ok: true }); } });
  const company = { endpoint: "http://127.0.0.1:1/company", workspace: "a".repeat(64), actor: "worker", grant: "grant", view: "b".repeat(64), actions: ["status"] };
  const companyClient = { identity: { workspace: company.workspace, actor: company.actor, grant: company.grant }, scope: { view: company.view, expiresMs, execution: { runtime: "owner", generation: 1 }, actions: ["status"] }, async call(name, request) {
    expect(name).toBe("company_workspace"); expect(request.action).toBe("status"); expect(request.view).toBeUndefined();
    return allowed ? { content: [{ type: "text", text: JSON.stringify({ view: company.view, execution: { runtime: "owner", generation, expires_ms: expiresMs } }) }] } : { isError: true };
  } };
  const broker = await createWorkerBroker({ socket, company, companyClient, expiresMs, model: { endpoint: `http://127.0.0.1:${provider.port}/v1`, model: "provider-model", handle: "fixture-model", credential: "host-only-fixture-key" } });
  try {
    const request = { model: "fixture-model", messages: [{ role: "user", content: "Retain this public report." }] };
    expect((await local(socket, "/model/v1/chat/completions", request)).status).toBe(200); expect(providerCalls).toBe(1);
    generation = 2;
    const stale = await local(socket, "/model/v1/chat/completions", request);
    expect(stale.status).toBe(403); expect(stale.text).toContain("WorkerInvocationRevoked"); expect(providerCalls).toBe(1);
    generation = 1; allowed = false;
    expect((await local(socket, "/model/v1/chat/completions", request)).status).toBe(403); expect(providerCalls).toBe(1);
  } finally { await broker.close(); provider.stop(true); }
});

test("company task amendments survive interruption and revise only authenticated affected requirements", async () => {
  const f = fixture();
  const inference = model(f, () => { throw Error("Contract revision cannot execute actor tools"); }, undefined, {
    plan: { capability: "general_task", summary: "Produce the requested report", obligations: [{ id: "colour", description: "Use red for the report." }, { id: "summary", description: "Include the summary." }], checks: [] },
    revise: packet => {
      expect(packet.context.pendingAmendments).toEqual(["Use blue instead of red, and keep the summary."]);
      return { capability: "general_task", summary: "The authenticated user changed the report colour", obligations: [{ id: "colour", description: "Use blue for the report." }], checks: [], superseded: ["colour"] };
    },
  });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => { const file = join(f.home, "amendment-owner.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const key = await f.run(["fossil", "company-key", "amendment-user", "--json"]); expect(key.code, key.stderr).toBe(0);
  const actions = ["create_view", "read", "status", "checkpoint", "submit", "execute_task", "reconcile"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "amendment-user", actor: "participant", public_key: (JSON.parse(key.stdout).model_data ?? JSON.parse(key.stdout)).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-amendment-applied" }), client, bound;
  const connect = async () => {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "amendment-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "amendment-user", key_handle: "amendment-user", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    return { boot, config };
  };
  const call = async (action: string, rest: any = {}, success = true) => {
    const request = { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest };
    const result = await client.call("company_workspace", request);
    if (success && action === "create_view" && result.isError && JSON.parse(result.content[0].text).error === "CompanyOutcomeUnknown") {
      const status = await client.call("company_workspace", { version: "omos.company/v1", action: "status", outcome: request.operation, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
      expect(status.isError, JSON.stringify({ dispatch: result, inspection: status })).not.toBe(true);
      const retained = JSON.parse(status.content[0].text);
      if (retained.state === "completed") return retained.result;
      const recovered = await client.call("company_workspace", { version: "omos.company/v1", action: "reconcile", outcome: request.operation, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
      expect(recovered.isError, JSON.stringify({ dispatch: result, retained, reconciliation: recovered })).not.toBe(true);
      const outcome = JSON.parse(recovered.content[0].text);
      expect(outcome.state).toBe("completed");
      return outcome.result;
    }
    if (success && result.isError && action === "reconcile") {
      const diagnostic = await client.call("company_workspace", { version: "omos.company/v1", action: "status", view: rest.view, outcome: rest.outcome, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
      const retained = JSON.parse(diagnostic.content[0].text);
      throw Error(JSON.stringify({ recovery: result, retained_state: retained.state, retained_failure: retained.failure }));
    }
    expect(result.isError === true, JSON.stringify(result)).toBe(!success); return success ? JSON.parse(result.content[0].text) : result; };
  try {
    const { boot, config } = await connect(); expect(boot.features.task_amendments).toBe(true);
    const created = await call("create_view", { revision: boot.revision, objective: "Write a red report and include the summary." });
    const view = created.view;
    let row = (await admin({ action: "workers", worker: { change: "queue", view, operation: crypto.randomUUID() } })).jobs[0];
    const plan = async () => {
      const deadline = Date.now() + 120000;
      do {
        row = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
        if (["failed", "blocked", "changes_required", "pending"].includes(row.planning_state)) throw Error(JSON.stringify({ planning_state: row.planning_state, planning_job: row.planning_job }));
        if (!["queued", "running"].includes(row.planning_state)) row = (await admin({ action: "workers", worker: { change: "plan", view, operation: crypto.randomUUID(), expected_sha256: row.sha256 } })).jobs[0];
        if (!row.planning_required) return;
        await Bun.sleep(50);
      } while (Date.now() < deadline);
      throw Error("Amendment fixture planning did not finish");
    };
    await plan();
    const originalContract = structuredClone(row.contract);
    row = (await admin({ action: "workers", worker: { change: "claim", view, operation: crypto.randomUUID(), expected_sha256: row.sha256, execution: { runtime: "amendment-worker", generation: 0 } } })).jobs[0];
    const execution = { runtime: row.record.runtime, generation: row.record.generation };
    bound = await createCompanyClient(config, { home: f.home, binding: { view, execution, expiresMs: Date.now() + 180000, actions: ["read", "status", "checkpoint"] } });
    const amendment = { version: "omos.company-task-amend/v1", text: "Use blue instead of red, and keep the summary." };
    const denied = await bound.call("company_workspace", { version: "omos.company/v1", action: "execute_task", revision: row.view_revision, content: JSON.stringify(amendment), operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
    expect(denied.isError).toBe(true);
    const operation = crypto.randomUUID();
    await call("execute_task", { view, execution, revision: row.view_revision, operation, content: JSON.stringify(amendment) }, false);
    const retained = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
    expect(retained.record.state).toBe("queued"); expect(retained.record.invocations).toBe(1); expect(retained.execution.runtime).toBeNull(); expect(retained.pending_operation).toBe(operation);
    expect(retained.pending_amendment).toBe(true);
    const blockedFile = join(f.home, "amendment-claim.json");
    writeFileSync(blockedFile, JSON.stringify({ version: "omos.company-admin/v1", action: "workers", worker: { change: "claim", view, operation: crypto.randomUUID(), expected_sha256: retained.sha256, execution: { runtime: "must-not-spend-invocation", generation: 1 } } }));
    const blocked = await f.run(["fossil", "company", blockedFile, "--json"]);
    expect(blocked.code).not.toBe(0); expect(blocked.stderr).toContain("CompanyOperationRecoveryRequired");
    const old = await bound.call("company_workspace", { version: "omos.company/v1", action: "checkpoint", revision: retained.view_revision, path: "documents/team/stale.txt", content: "Old worker must stop", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 }); expect(old.isError).toBe(true);
    client.close(); client = null; bound.close(); bound = null; service.child.kill(); await service.child.exited;
    service = await startWorkspaceService(f, true); await connect();
    const recovered = await call("reconcile", { view, outcome: operation }); expect(recovered.state).toBe("completed"); expect(recovered.result.state).toBe("planning");
    expect((await call("reconcile", { view, outcome: operation })).result).toEqual(recovered.result);
    await plan();
    expect(row.amendments).toEqual([amendment.text]); expect(row.record.invocations).toBe(1); expect(row.record.max_invocations).toBe(3); expect(row.contract.version).toBeGreaterThan(originalContract.version);
    expect(row.contract.obligations.find(item => item.id === "colour").description).toBe("Use blue for the report.");
    expect(row.contract.obligations.find(item => item.id === "summary")).toEqual(originalContract.obligations.find(item => item.id === "summary"));
    expect(row.contract.obligations.find(item => item.id === "request_complete")).toEqual(originalContract.obligations.find(item => item.id === "request_complete"));
    const next = (await admin({ action: "workers", worker: { change: "claim", view, operation: crypto.randomUUID(), expected_sha256: row.sha256, execution: { runtime: "replacement-worker", generation: 1 } } })).jobs[0];
    expect(next.record.generation).toBe(2); expect(next.record.invocations).toBe(2); expect(next.record.max_invocations).toBe(3);
    expect(inference.counts().actors).toBe(0); expect(inference.revisionPackets).toHaveLength(1);
    expect(f.fossil("ls", "-r", "omos-company")).toContain("company/amendments/");
    const verified = await f.run(["fossil", "verify", "--json"]); expect(verified.code, verified.stderr).toBe(0);
  } finally { bound?.close(); client?.close(); service.child.kill(); await service.child.exited; }
}, 360000);


test("worker checkpoint acknowledgements compare typed values independently of JSON member order", async () => {
  const checkpoint = { version: "omos.company-worker-checkpoint/v1", image: "a".repeat(64), company_contract: "b".repeat(64), continuation: { invocation: 2, archive: "c".repeat(64), source: "d".repeat(64) } };
  let row: any = { authority_live: true, sha256: "e".repeat(64), record: { state: "running", runtime: "owner", generation: 2 } };
  const control = { async call(input) {
    if (input.change === "checkpoint") row.record = { ...row.record, operation: input.operation, checkpoint: Object.fromEntries(Object.entries(input.checkpoint).reverse()) };
    return { ok: true, jobs: [structuredClone(row)] };
  } };
  expect(await createWorkerCheckpointer({ control, view: "view", execution: { runtime: "owner", generation: 2 } })(checkpoint)).toEqual(checkpoint);
});

test("worker coordinator leaves pending user amendments to internal recovery without claiming actor budget", async () => {
  let claims = 0, runs = 0;
  const row = { authority_live: true, pending_operation: "update", pending_amendment: true, record: { state: "queued", binding: { view: "view" } } };
  const control = { async call(request) { if (request.change === "claim") claims++; return { ok: true, jobs: [row], next_offset: null }; } };
  const coordinator = createWorkerCoordinator({ control, backend: { async recover() {}, async run() { runs++; } } });
  try { expect((await coordinator.tick()).started).toBe(0); await coordinator.drain(); expect(claims).toBe(0); expect(runs).toBe(0); } finally { await coordinator.close(); }
});

test("company verification continuation survives interruption without another actor invocation", async () => {
  const f = fixture();
  let inspectable = false;
  const inference = model(f, () => { throw Error("Verification continuation must not dispatch actors"); }, packet => inspectable ? "met" : { name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: packet.contract.obligations.map(obligation => ({ id: obligation.id, status: "met", evidence: ["unseen-reference"], note: "This invented reference must be rejected" })) } });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => { const filename = join(f.home, "verification-owner.json"); writeFileSync(filename, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", filename, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "verification-user", "--json"]); expect(keyed.code, keyed.stderr).toBe(0);
  const key = JSON.parse(keyed.stdout), actions = ["create_view", "execution", "read", "status", "checkpoint", "submit", "execute_task", "reconcile"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "verification-user", actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-review-resume-intent" }), client;
  const connect = async () => {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "verification-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "verification-user", key_handle: "verification-user", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home }); return boot;
  };
  const send = async (action: string, input: any = {}) => { const reply = await client.call("company_workspace", { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...input }); expect(reply.isError, JSON.stringify(reply)).not.toBe(true); return JSON.parse(reply.content[0].text); };
  const settle = async view => { const deadline = Date.now() + 180000; do { const state = await send("status", { view }); if (!["queued", "running"].includes(state.job?.state)) return state; await Bun.sleep(100); } while (Date.now() < deadline); throw Error("Verification fixture did not settle"); };
  try {
    const boot = await connect(); expect(boot.features.verification_resume).toBe(true); expect(boot.features.hosted_execution).toBe(false);
    const created = await send("create_view", { revision: boot.revision, objective: "Retain the report and verify its contents." });
    const view = created.view, execution = { runtime: "external-fixture", generation: 1 };
    await send("execution", { view, revision: created.revision, execution: { ...execution, generation: 0 }, execution_change: "claim", execution_lease_ms: 300000 });
    const checkpoint = await send("checkpoint", { view, execution, revision: created.revision, path: "documents/team/report.txt", content: "Retained once before independent verification." });
    await send("submit", { view, execution, revision: checkpoint.revision, candidate: "Retained the report and its contents for independent verification." });
    const pending = await settle(view);
    expect(["pending", "failed"]).toContain(pending.job.state); expect(pending.publication).toBeNull();
    await send("execution", { view, revision: pending.revision, execution, execution_change: "release" });
    let worker = (await admin({ action: "workers", worker: { change: "queue", view, operation: crypto.randomUUID() } })).jobs[0];
    worker = (await admin({ action: "workers", worker: { change: "claim", view, operation: crypto.randomUUID(), expected_sha256: worker.sha256, execution: { runtime: "retained-worker", generation: 1 } } })).jobs[0];
    worker = (await admin({ action: "workers", worker: { change: "finish", view, operation: crypto.randomUUID(), expected_sha256: worker.sha256, execution: { runtime: worker.record.runtime, generation: worker.record.generation }, outcome: "submitted" } })).jobs[0];
    expect(worker.record.invocations).toBe(1); expect(worker.execution.runtime).toBeNull();
    const operation = crypto.randomUUID();
    const interrupted = await client.call("company_workspace", { version: "omos.company/v1", action: "execute_task", view, revision: worker.view_revision, operation, expires_ms: Date.now() + 300000 });
    expect(interrupted.isError).toBe(true);
    const retainedOutcome = await send("status", { view, outcome: operation });
    expect(retainedOutcome.failure, JSON.stringify({ interrupted, state: retainedOutcome.state, failure: retainedOutcome.failure })).toBe("WorkspaceInjectedFailure");
    const saved = await send("status", { view }); expect(saved.pending_verification).toBe(true); expect(saved.pending_operation).toBe(operation); expect(saved.publication).toBeNull();
    client.close(); client = null; service.child.kill(); await service.child.exited;
    inspectable = true; service = await startWorkspaceService(f, true); await connect();
    const recovered = await send("reconcile", { view, outcome: operation }); expect(recovered.state).toBe("completed"); expect(recovered.result.verification.id).toBe(pending.job.id);
    expect((await send("reconcile", { view, outcome: operation })).result).toEqual(recovered.result);
    const accepted = await settle(view); expect(accepted.state).toBe("accepted"); expect(accepted.publication).not.toBeNull();
    expect(accepted.job.budget_epoch).toBe(pending.job.generation + 1); expect(accepted.job.candidate_hash).toBe(pending.job.candidate_hash);
    const finalWorker = (await admin({ action: "workers", worker: { change: "inspect", view } })).jobs[0];
    expect(finalWorker.record.invocations).toBe(1); expect(finalWorker.record.max_invocations).toBe(worker.record.max_invocations); expect(finalWorker.record.generation).toBe(worker.record.generation);
    expect(inference.counts().actors).toBe(0); expect(f.fossil("cat", "documents/team/report.txt", "-r", "trunk")).toBe("Retained once before independent verification.");
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { client?.close(); service.child.kill(); await service.child.exited; }
}, 600000);


test("worker runtime release confirms a lost stop acknowledgement before replacement", async () => {
  const description = { workspace: "a".repeat(64), package_sha256: "b".repeat(64), model_handle: "fixture", subjects: [{ actor: "user", grant: "user" }], validation_handles: [] };
  for (const unresolved of [false, true]) {
    let digest, stops = [];
    const runtime = await advertiseWorkerRuntime({ description, control: { async call(request) {
      if (request.change === "inspect") return { ok: true, revision: "c".repeat(64), runtimes: [] };
      if (request.change === "register") { digest = createHash("sha256").update(JSON.stringify(request.registration)).digest("hex"); return { ok: true, sha256: digest }; }
      if (request.change === "heartbeat") return { ok: true, live: true, sha256: digest };
      stops.push(structuredClone(request));
      return unresolved || stops.length === 1 ? { ok: false, error: "WorkerControlOutcomeUnknown" } : { ok: true, live: false, sha256: digest };
    } } });
    if (unresolved) await expect(runtime.close()).rejects.toThrow("WorkerRuntimeReleasePending");
    else { await runtime.close(); await runtime.close(); }
    expect(stops).toHaveLength(2); expect(stops[0]).toEqual(stops[1]);
  }
});

test("company verification observation survives completion planning without allocating another review budget", async () => {
  const f = fixture();
  let planning = false, permit = false, releasePlan;
  const gate = new Promise<void>(resolve => { releasePlan = resolve; });
  const inference = model(f, () => { throw Error("Observing verification must not dispatch an actor"); }, packet => permit ? "met" : { name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: packet.contract.obligations.map(obligation => ({ id: obligation.id, status: "met", evidence: ["unseen-reference"], note: "This reference must be rejected" })) } }, { plan: async () => { planning = true; await gate; return { capability: "general_task", summary: "Verify the retained report", obligations: [], checks: [] }; } });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => { const filename = join(f.home, "observation-owner.json"); writeFileSync(filename, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", filename, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "observation-user", "--json"]); expect(keyed.code, keyed.stderr).toBe(0);
  const key = JSON.parse(keyed.stdout), actions = ["create_view", "execution", "read", "status", "checkpoint", "submit", "execute_task", "reconcile"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "observation-user", actor: "participant", public_key: (key.model_data ?? key).public_key, paths: ["documents/team/"], actions, expires_ms: Date.now() + 3600000 } });
  let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-review-resume-intent" }), client;
  const connect = async () => {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "observation-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "participant", grant: "observation-user", key_handle: "observation-user", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home }); return boot;
  };
  const send = async (action, input = {}) => { const reply = await client.call("company_workspace", { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...input }); expect(reply.isError, JSON.stringify(reply)).not.toBe(true); return JSON.parse(reply.content[0].text); };
  const settle = async view => { const deadline = Date.now() + 180000; do { const state = await send("status", { view }); if (!["queued", "running"].includes(state.job?.state)) return state; await Bun.sleep(100); } while (Date.now() < deadline); throw Error("Observed verification did not settle"); };
  try {
    const boot = await connect(); expect(boot.features.hosted_execution).toBe(false);
    const created = await send("create_view", { revision: boot.revision, objective: "Retain and independently verify the report." });
    expect(created.basis.capability).toBeNull();
    const view = created.view, execution = { runtime: "external-observer", generation: 1 };
    await send("execution", { view, revision: created.revision, execution: { ...execution, generation: 0 }, execution_change: "claim", execution_lease_ms: 300000 });
    const checkpoint = await send("checkpoint", { view, execution, revision: created.revision, path: "documents/team/report.txt", content: "A retained report observed while completion planning runs." });
    await send("submit", { view, execution, revision: checkpoint.revision, candidate: "Retained the report for independent verification." });
    const planningDeadline = Date.now() + 120000;
    while (!planning && Date.now() < planningDeadline) await Bun.sleep(50);
    expect(planning).toBe(true);
    const before = await send("status", { view }); expect(["queued", "running"]).toContain(before.job.state);
    const operation = crypto.randomUUID();
    const interrupted = await client.call("company_workspace", { version: "omos.company/v1", action: "execute_task", view, revision: before.revision, operation, expires_ms: Date.now() + 300000 });
    expect(interrupted.isError).toBe(true);
    const retained = await send("status", { view }); expect(retained.pending_verification).toBe(true);
    releasePlan();
    const planned = await settle(view); expect(planned.basis.capability).toBe("general_task"); expect(planned.basis).not.toEqual(before.basis); expect(["pending", "failed"]).toContain(planned.job.state);
    await send("execution", { view, revision: planned.revision, execution, execution_change: "release" });
    client.close(); client = null; service.child.kill(); await service.child.exited;
    service = await startWorkspaceService(f, true); await connect();
    const reply = await client.call("company_workspace", { version: "omos.company/v1", action: "reconcile", view, outcome: operation, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 });
    const diagnostic = reply.isError ? await send("status", { view, outcome: operation }) : null;
    expect(reply.isError, JSON.stringify({ reply, diagnostic })).not.toBe(true);
    const recovered = JSON.parse(reply.content[0].text); expect(recovered.state).toBe("completed");
    expect(recovered.result.verification.id).toBe(before.job.id); expect(recovered.result.verification.budget_epoch).toBe(before.job.budget_epoch);
    expect((await send("reconcile", { view, outcome: operation })).result).toEqual(recovered.result);
    const observed = await send("status", { view }); expect(observed.job.budget_epoch).toBe(before.job.budget_epoch); expect(observed.publication).toBeNull();
    permit = true;
    await send("execute_task", { view, revision: observed.revision });
    const accepted = await settle(view); expect(accepted.state).toBe("accepted"); expect(accepted.publication).not.toBeNull(); expect(accepted.job.candidate_hash).toBe(before.job.candidate_hash);
    expect(inference.counts().actors).toBe(0); expect(accepted.hosted_execution.job).toBeNull();
    expect(f.fossil("cat", "documents/team/report.txt", "-r", "trunk")).toBe("A retained report observed while completion planning runs.");
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  } finally { releasePlan(); client?.close(); service.child.kill(); await service.child.exited; }
}, 600000);


test("an unavailable checkpoint inspection preserves its transport cause without claiming revocation", async () => {
  let calls = 0;
  const control = { async call(request) { calls++; expect(request.change).toBe("inspect"); return { ok: false, error: "WorkerControlOutcomeUnknown", transport: "RequestDeadline" }; } };
  let error;
  try { await createWorkerCheckpointer({ control, view: "view", execution: { runtime: "owner", generation: 2 } })({ phase: "stopped" }); } catch (caught) { error = caught; }
  expect(error?.message).toBe("WorkerCheckpointInspectionPending");
  expect(error?.inspection).toEqual({ kind: "checkpoint", error: "WorkerControlOutcomeUnknown", transport: "RequestDeadline" }); expect(calls).toBe(1);
});

test("company status reads remain available while the company writer is occupied", async () => {
  const f = fixture();
  const inference = model(f, () => { throw Error("Status inspection must never dispatch an actor"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const file = join(f.home, "status-reader-admin.json");
  const admin = async input => { writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", file, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "reader", "--json"]); expect(keyed.code, keyed.stderr).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "status"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "reader", actor: "reader", public_key: (key.model_data ?? key).public_key, paths: ["documents/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true);
  let client, holder;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "status-reader.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "reader", grant: "reader", key_handle: "reader", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const send = (action, rest = {}, signal?) => client.call("company_workspace", { version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...rest }, signal);
    const created = await send("create_view", { revision: boot.revision, objective: "Inspect retained work without waiting for a company mutation" }); expect(created.isError, JSON.stringify(created)).not.toBe(true);
    const view = JSON.parse(created.content[0].text);
    holder = spawn("/usr/bin/python3", ["-I", "-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('held',flush=True); sys.stdin.read(1)", join(f.home, ".fx/authority", boot.workspace, "operation.lock")], { stdio: ["pipe", "pipe", "pipe"] });
    await new Promise<void>((resolve, reject) => { holder.stdout.once("data", () => resolve()); holder.once("error", reject); holder.once("exit", code => reject(Error("Writer lock exited: " + code))); });
    const inspected = await send("status", { view: view.view }, AbortSignal.timeout(10000));
    expect(inspected.isError, JSON.stringify(inspected)).not.toBe(true);
    const state = JSON.parse(inspected.content[0].text); expect(state.revision).toBe(view.revision); expect(state.contract.version).toBe(1); expect(state.job).toBeNull(); expect(state.publication).toBeNull(); expect(inference.counts().actors).toBe(0);
  } finally { if (holder) { holder.stdin.end(); await new Promise<void>(resolve => { if (holder.exitCode !== null) resolve(); else holder.once("exit", () => resolve()); }); } client?.close(); service.child.kill(); await service.child.exited; }
}, 120000);

test("owner worker and retention inspections do not wait for an unrelated company writer", async () => {
  const f = fixture(); const inference = model(f, () => { throw Error("Inspection must not dispatch an actor"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const admin = async input => { const filename = join(f.home, "inspection-admin.json"); writeFileSync(filename, JSON.stringify({ version: "omos.company-admin/v1", ...input })); const result = await f.run(["fossil", "company", filename, "--json"]); expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data; };
  const initial = await admin({ action: "initialize" });
  const keyed = await f.run(["fossil", "company-key", "inspection", "--json"]); expect(keyed.code).toBe(0); const key = JSON.parse(keyed.stdout);
  const actions = ["create_view", "execution", "status", "read", "checkpoint", "submit"];
  await admin({ action: "grant", revision: initial.revision, grant: { id: "inspection", actor: "worker", public_key: (key.model_data ?? key).public_key, paths: ["documents/"], actions, expires_ms: Date.now() + 3600000 } });
  const service = await startWorkspaceService(f, true); let client, holder;
  try {
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const config = join(f.home, "inspection-client.json"); writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: service.url, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "inspection", key_handle: "inspection", actions }), { mode: 0o600 });
    client = await createCompanyClient(config, { home: f.home });
    const created = await client.call("company_workspace", { version: "omos.company/v1", action: "create_view", revision: boot.revision, objective: "Inspect an owned worker without taking the company writer", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000 }); expect(created.isError, JSON.stringify(created)).not.toBe(true);
    const view = JSON.parse(created.content[0].text);
    let row = (await admin({ action: "workers", worker: { change: "queue", operation: crypto.randomUUID(), view: view.view } })).jobs[0];
    row = (await admin({ action: "workers", worker: { change: "claim", operation: crypto.randomUUID(), view: view.view, expected_sha256: row.sha256, execution: { runtime: "inspection-runtime", generation: 0 } } })).jobs[0];
    holder = Bun.spawn(["/usr/bin/python3", "-I", "-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('held',flush=True); sys.stdin.read(1)", join(f.home, ".fx/authority", boot.workspace, "operation.lock")], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    const reader = holder.stdout.getReader(); try { const ready = await reader.read(); expect(new TextDecoder().decode(ready.value)).toBe("held\n"); } finally { reader.releaseLock(); }
    const probe = Bun.spawn([process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath, join(import.meta.dir, "fixtures/company-inspection-writer.mjs")], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    probe.stdin.write(JSON.stringify({ transport: { endpoint: service.url, workspaceId: boot.workspace, token: service.headers.authorization.slice(7) }, view: view.view, execution: { runtime: row.record.runtime, generation: row.record.generation }, source: { workspace: boot.workspace, task: row.record.binding.task, revision: row.view_revision, sha256: "e".repeat(64), bytes: 512 } })); probe.stdin.end();
    const [code, stdout, stderr] = await Promise.all([probe.exited, new Response(probe.stdout).text(), new Response(probe.stderr).text()]); expect(code, stderr).toBe(0); expect(stderr).toBe("");
    const result = JSON.parse(stdout); expect(result.jobs.ok, stdout).toBe(true); expect(result.jobs.jobs[0].record).toEqual(row.record); expect(result.jobs.jobs[0].contract).toEqual(row.contract);
    expect(result.retained).toMatchObject({ ok: true, resume_offset: 0, complete: false }); expect(result.events).toMatchObject({ ok: true, next_offset: 0, ended: false }); expect(result.fenced).toMatchObject({ ok: false, error: "CompanyExecutionFenced" }); expect(inference.counts().actors).toBe(0);
  } finally { if (holder) { holder.stdin.end(); await holder.exited; } client?.close(); service.child.kill(); await service.child.exited; expect(await new Response(service.child.stderr).text()).toBe(""); }
}, 120000);

test("worker runtime heartbeat and stop do not wait for an unrelated company writer", async () => {
  const f = fixture(); model(f, () => { throw Error("A runtime heartbeat must never dispatch an actor"); });
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const filename = join(f.home, "heartbeat-owner.json"); writeFileSync(filename, JSON.stringify({ version: "omos.company-admin/v1", action: "initialize" }));
  const initialized = await f.run(["fossil", "company", filename, "--json"]); expect(initialized.code, initialized.stderr).toBe(0);
  const service = await startWorkspaceService(f, true); let holder;
  const control = createRuntimeHttpControl({ endpoint: service.url, workspaceId: service.ready.workspace, token: service.headers.authorization.slice(7) });
  try {
    const inspected = await control.call({ version: "omos.company-runtime/v1", change: "inspect" }); expect(inspected.ok, JSON.stringify(inspected)).toBe(true);
    const id = "a".repeat(64), registration = { version: "omos.company-runtime-registration/v1", id, workspace: service.ready.workspace, package_sha256: "b".repeat(64), model_handle: "fixture", isolation: "omos.linux-worker/v1", subjects: [{ actor: "worker", grant: "fixture" }], validation_handles: [] };
    const registered = await control.call({ version: "omos.company-runtime/v1", change: "register", id, revision: inspected.revision, registration }); expect(registered.ok, JSON.stringify(registered)).toBe(true);
    holder = Bun.spawn(["/usr/bin/python3", "-I", "-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('held',flush=True); sys.stdin.read(1)", join(f.home, ".fx/authority", service.ready.workspace, "operation.lock")], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    const reader = holder.stdout.getReader();
    try { const ready = await Promise.race([reader.read(), Bun.sleep(10000).then(() => { throw Error("Fixture writer did not acquire its lock"); })]); expect(new TextDecoder().decode(ready.value)).toBe("held\n"); } finally { reader.releaseLock(); }
    const probe = Bun.spawn([process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath, join(import.meta.dir, "fixtures/company-runtime-writer.mjs")], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    probe.stdin.write(JSON.stringify({ transport: { endpoint: service.url, workspaceId: service.ready.workspace, token: service.headers.authorization.slice(7) }, id, sha256: registered.sha256 })); probe.stdin.end();
    const [code, stdout, stderr] = await Promise.all([probe.exited, new Response(probe.stdout).text(), new Response(probe.stderr).text()]); expect(code, stderr).toBe(0); expect(stderr).toBe("");
    const result = JSON.parse(stdout); expect(result.heartbeat.ok, stdout).toBe(true); expect(result.heartbeat.live).toBe(true);
    expect(result.replacement).toMatchObject({ ok: false, error: "CompanyRuntimeBusy" });
    expect(result.stopped).toMatchObject({ ok: true, live: false });
    expect(result.delayed).toMatchObject({ ok: false, error: "CompanyRuntimeFenced" });
  } finally { if (holder) { holder.stdin.end(); await holder.exited; } control.close(); service.child.kill(); await service.child.exited; }
}, 120000);

test("owner control distinguishes a closed socket from cancellation without replaying mutations", async () => {
  const child = Bun.spawn([process.env.OMOS_E2E_MCP_RUNTIME ?? Bun.which("node") ?? process.execPath, join(import.meta.dir, "fixtures/company-owner-transport.mjs")], { stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  expect(code, stderr).toBe(0); expect(stderr).toBe("");
  expect(JSON.parse(stdout)).toEqual([{ transport: "ECONNRESET", requests: 1, uncertain: true }, { transport: "RequestCancelled", requests: 1, uncertain: true }]);
}, 15000);

test("worker failure notes retain bounded operation diagnostics without replaying requests", async () => {
  for (const unsafe of [false, true]) {
    let runs = 0, note;
    const row = { sha256: "a".repeat(64), authority_live: true, contract: {}, request: "Retain work", basis: {}, grant: {}, execution: null, record: { state: "queued", binding: { view: "view" }, generation: 0, max_runtime_ms: 10000, expires_ms: 0 } };
    const control = { async call(request) {
      if (request.change === "claim") { row.record = { ...row.record, state: "running", runtime: request.execution.runtime, generation: 1, expires_ms: Date.now() + 20000 }; row.execution = { runtime: request.execution.runtime, generation: 1 }; }
      if (request.change === "finish") { note = request.note; row.record.state = request.outcome; }
      return { ok: true, jobs: [structuredClone(row)], next_offset: null };
    } };
    const coordinator = createWorkerCoordinator({ control, backend: { async run() { runs++; throw Object.assign(Error("WorkerCompanyOutcomeUnresolved"), { companyOperation: { action: "submit", operation: "retained-operation", error: unsafe ? "private secret\n" : "CompanyOutcomeUnknown", transport: unsafe ? "/private/credential" : "CompanyHttp409" } }); } } });
    try { await coordinator.tick(); await coordinator.drain(); expect(runs).toBe(1); expect(note).toContain("action=submit; operation=retained-operation"); expect(note).toContain(unsafe ? "error=Unknown; transport=Unknown" : "error=CompanyOutcomeUnknown; transport=CompanyHttp409"); expect(note).not.toContain("private"); expect(note.length).toBeLessThanOrEqual(512); } finally { await coordinator.close(); }
  }
});

test("worker archive retention preserves an unresolved position without resending a chunk", async () => {
  const f = fixture(), filename = join(f.home, "retained-archive.fossil"), bytes = randomBytes(180 * 1024);
  writeFileSync(filename, bytes);
  const source = { workspace: "a".repeat(64), task: "b".repeat(64), revision: "c".repeat(64) };
  for (const action of ["inspect", "chunk"]) {
    const requests = [];
    const control = { async call(request) {
      requests.push(request.action);
      if (request.action === action) return { ok: false, error: "WorkerControlOutcomeUnknown" };
      return { ok: true, sha256: createHash("sha256").update(bytes).digest("hex"), bytes: bytes.length, resume_offset: 0, complete: false, archive_id: "d".repeat(64), revision: "e".repeat(64) };
    } };
    await expect(retainWorkerArchive({ filename, uid: process.getuid!(), source, view: "f".repeat(64), execution: { runtime: "worker", generation: 1 }, control })).rejects.toMatchObject({ message: "WorkerArchiveRetentionPending", retention: { kind: "archive", action, offset: 0, error: "WorkerControlOutcomeUnknown" } });
    expect(requests).toEqual(action === "inspect" ? ["inspect"] : ["inspect", "chunk"]);
    expect(readFileSync(filename).equals(bytes)).toBe(true);
  }
});

test("worker archive deadlines inspect the exact committed prefix without resending a chunk", async () => {
  const f = fixture(), filename = join(f.home, "deadline-archive.fossil"), bytes = randomBytes(180 * 1024);
  writeFileSync(filename, bytes);
  for (const verifiable of [true, false]) {
    const requests = [], chunks = []; let offset = 0;
    const control = { async call(request) {
      requests.push(request.action);
      const complete = offset === bytes.length;
      const outcome = { ok: true, view: request.view, sha256: request.source.sha256, bytes: bytes.length, archive_id: !verifiable && offset ? "f".repeat(64) : "d".repeat(64), revision: "e".repeat(64), offset: 0, resume_offset: offset, next_offset: complete ? null : offset, complete };
      if (request.action === "inspect") return outcome;
      expect(request.offset).toBe(offset);
      const chunk = Buffer.from(request.content, "base64"); chunks.push(chunk); offset += chunk.length;
      return { ok: false, error: "WorkerControlOutcomeUnknown", transport: "RequestDeadline" };
    } };
    const input = { filename, uid: process.getuid!(), source: { workspace: "a".repeat(64), task: "b".repeat(64), revision: "c".repeat(64) }, view: "1".repeat(64), execution: { runtime: "worker", generation: 1 }, control };
    if (verifiable) {
      const retained = await retainWorkerArchive(input); expect(retained.complete).toBe(true); expect(retained.sha256).toBe(createHash("sha256").update(bytes).digest("hex")); expect(Buffer.concat(chunks).equals(bytes)).toBe(true);
      expect(requests).toEqual(["inspect", "chunk", "inspect", "chunk", "inspect"]);
    } else {
      await expect(retainWorkerArchive(input)).rejects.toMatchObject({ message: "WorkerArchiveRetentionPending", retention: { kind: "archive", action: "chunk", offset: 0, transport: "RequestDeadline" } });
      expect(chunks).toHaveLength(1); expect(requests).toEqual(["inspect", "chunk", "inspect"]);
    }
    expect(readFileSync(filename).equals(bytes)).toBe(true);
  }
});

test("worker failure notes retain bounded activity and archive positions without replaying work", async () => {
  for (const kind of ["activity", "archive"]) for (const unsafe of [false, true]) {
    let runs = 0, note;
    const row = { sha256: "a".repeat(64), authority_live: true, contract: {}, request: "Retain work", basis: {}, grant: {}, execution: null, record: { state: "queued", binding: { view: "view" }, generation: 0, max_runtime_ms: 10000, expires_ms: 0 } };
    const control = { async call(request) {
      if (request.change === "claim") { row.record = { ...row.record, state: "running", runtime: request.execution.runtime, generation: 1, expires_ms: Date.now() + 20000 }; row.execution = { runtime: request.execution.runtime, generation: 1 }; }
      if (request.change === "finish") { note = request.note; row.record.state = request.outcome; }
      return { ok: true, jobs: [structuredClone(row)], next_offset: null };
    } };
    const action = kind === "activity" ? "append" : "chunk";
    const coordinator = createWorkerCoordinator({ control, backend: { async run() { runs++; throw Object.assign(Error(kind === "activity" ? "WorkerActivityRetentionPending" : "WorkerArchiveRetentionPending"), { retention: { kind, action, offset: 131072, error: unsafe ? "private credential\n" : "WorkerControlOutcomeUnknown", transport: unsafe ? "/private/transport" : "RequestDeadline" } }); } } });
    try { await coordinator.tick(); await coordinator.drain(); expect(runs).toBe(1); expect(note).toContain(`retention=${kind}; action=${action}; offset=131072`); expect(note).toContain(unsafe ? "error=Unknown" : "error=WorkerControlOutcomeUnknown"); expect(note).toContain(unsafe ? "transport=Unknown" : "transport=RequestDeadline"); expect(note).not.toContain("private"); expect(note.length).toBeLessThanOrEqual(512); } finally { await coordinator.close(); }
  }
});
