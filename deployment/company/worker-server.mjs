// Optional privileged company worker supervisor. Native Fossil jobs own state;
// this process owns only live executions, brokers and disposable image handles.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createLinuxWorkerBackend } from "./worker-linux.mjs";
import { createWorkerCoordinator } from "./worker-coordinator.mjs";
import { createWorkerHttpControl, createRuntimeHttpControl, createDesiredHttpControl } from "./worker-http-control.mjs";
import { advertiseWorkerRuntime } from "./worker-runtime.mjs";

const fields = (value, expected) => value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).every(key => expected.includes(key));
function validate(config) {
  if (config.reconciliation !== undefined && typeof config.reconciliation !== "boolean") throw new Error("InvalidCompanyWorkersConfiguration");
  if (!fields(config, ["version", "control", "backend", "concurrency", "poll_ms", "reconciliation"]) || config.version !== "omos.company-workers/v1" || !fields(config.control, ["endpoint", "workspaceId", "token"]) || !fields(config.backend, ["imageTool", "imageToolSha256", "launcher", "launcherSha256", "imageConfiguration", "companyConfiguration", "companyHome", "model", "validationConfiguration"]) || !fields(config.backend.model, ["endpoint", "handle", "model", "credential"]) || !Number.isSafeInteger(config.concurrency) || config.concurrency < 1 || config.concurrency > 4 || !Number.isSafeInteger(config.poll_ms) || config.poll_ms < 250 || config.poll_ms > 5000) throw new Error("InvalidCompanyWorkersConfiguration");
  return config;
}

export async function runWorkerServer(config, signal, report = () => {}) {
  validate(config);
  signal?.throwIfAborted();
  const backend = await createLinuxWorkerBackend({ ...structuredClone(config.backend), evaluation: structuredClone(config.control), concurrency: config.concurrency });
  const control = createWorkerHttpControl(structuredClone(config.control));
  const runtimeControl = createRuntimeHttpControl(structuredClone(config.control));
  const desiredControl = config.reconciliation ? createDesiredHttpControl(structuredClone(config.control)) : null;
  const coordinator = createWorkerCoordinator({ control, backend, concurrency: config.concurrency });
  let runtime, heartbeat, heartbeatPending = Promise.resolve(), heartbeatError;
  let previous, desiredCursor = 0, lastDesired = 0;
  const stop = () => { void coordinator.close().catch(() => {}); };
  signal?.addEventListener("abort", stop, { once: true });
  if (signal?.aborted) stop();
  try {
    // Owner-only passive retention also works after this actor's grant expires.
    // supports() remains false until describe(), so this pass cannot dispatch.
    await coordinator.tick();
    await coordinator.drain();
    const description = await backend.describe(signal);
    if (desiredControl && !description.desired_state) throw new Error("CompanyDesiredDefinitionRequired");
    runtime = await advertiseWorkerRuntime({ control: runtimeControl, description, signal });
    heartbeat = setInterval(() => {
      heartbeatPending = heartbeatPending.then(() => runtime.heartbeat()).catch(error => {
        heartbeatError = error;
        clearInterval(heartbeat);
        void coordinator.close().catch(() => {});
      });
    }, 10000);
    report({ event: "worker_server_started", workspace: config.control.workspaceId, concurrency: config.concurrency });
    while (!signal?.aborted) {
      if (heartbeatError) throw heartbeatError;
      if (desiredControl && Date.now() - lastDesired >= 5000) {
        lastDesired = Date.now();
        const subject = description.subjects[0];
        const reconciled = await desiredControl.call({ change: "tick", actor: subject.actor, grant: subject.grant, offset: desiredCursor, limit: 1 }, signal);
        if (reconciled.ok) {
          if (reconciled.next_offset !== null && (!Number.isSafeInteger(reconciled.next_offset) || reconciled.next_offset <= desiredCursor)) throw new Error("CompanyDesiredCursorInvalid");
          desiredCursor = reconciled.next_offset ?? 0;
          for (const row of reconciled.policies) report({ event: "company_reconciliation", policy: row.policy, phase: row.state?.phase ?? "paused", failure: row.failure });
        } else report({ event: "company_reconciliation_pending", error: reconciled.error });
      }
      let observation;
      try { observation = { event: "worker_server_progress", ...await coordinator.tick() }; }
      catch (error) { observation = { event: "worker_server_inspection_failed", error: /^[A-Z][A-Za-z0-9]{0,95}$/.test(error.message) ? error.message : "WorkerControlUnavailable" }; }
      const encoded = JSON.stringify(observation);
      if (encoded !== previous) { report(observation); previous = encoded; }
      if (signal?.aborted) break;
      await new Promise(resolve => {
        const done = () => { clearTimeout(timer); signal?.removeEventListener("abort", done); resolve(); };
        const timer = setTimeout(done, config.poll_ms);
        signal?.addEventListener("abort", done, { once: true });
        if (signal?.aborted) done();
      });
    }
  } finally {
    clearInterval(heartbeat);
    await heartbeatPending;
    signal?.removeEventListener("abort", stop);
    try {
      await coordinator.close();
      if (runtime) await runtime.close();
    } finally {
      desiredControl?.close();
      runtimeControl.close();
      control.close();
      report({ event: "worker_server_stopped" });
    }
  }
}

async function main() {
  if (process.argv.length !== 3 || process.getuid?.() !== 0) throw new Error("WorkerOperatorConfigurationRequired");
  const filename = path.resolve(process.argv[2]);
  if (await fs.realpath(filename) !== filename) throw new Error("UnsafeCompanyWorkersConfiguration");
  const file = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  let config;
  try {
    const info = await file.stat();
    if (!info.isFile() || info.uid !== 0 || info.nlink !== 1 || (info.mode & 0o777) !== 0o600 || info.size > 65536) throw new Error("UnsafeCompanyWorkersConfiguration");
    config = JSON.parse((await file.readFile()).toString("utf8"));
  } finally { await file.close(); }
  const stopping = new AbortController();
  const stop = () => stopping.abort();
  process.once("SIGTERM", stop); process.once("SIGINT", stop);
  try { await runWorkerServer(config, stopping.signal, event => process.stderr.write(JSON.stringify(event) + "\n")); }
  finally { process.removeListener("SIGTERM", stop); process.removeListener("SIGINT", stop); }
}

if (process.argv[1] && (await fs.realpath(path.resolve(process.argv[1]))) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(JSON.stringify({ event: "worker_server_failed", error: /^[A-Z][A-Za-z0-9]{0,95}$/.test(error.message) ? error.message : "WorkerServerFailed", ...(typeof error.transportCode === "string" && /^[A-Z][A-Za-z0-9_]{0,95}$/.test(error.transportCode) ? { transport: error.transportCode } : {}) }) + "\n"); process.exitCode = 1; });
}
