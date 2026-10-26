// Optional privileged company worker supervisor. Native Fossil jobs own state;
// this process owns only live executions, brokers and disposable image handles.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createLinuxWorkerBackend } from "./worker-linux.mjs";
import { createWorkerCoordinator } from "./worker-coordinator.mjs";
import { createWorkerHttpControl } from "./worker-http-control.mjs";

const fields = (value, expected) => value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).every(key => expected.includes(key));
function validate(config) {
  if (!fields(config, ["version", "control", "backend", "concurrency", "poll_ms"]) || config.version !== "omos.company-workers/v1" || !fields(config.control, ["endpoint", "workspaceId", "token"]) || !fields(config.backend, ["imageTool", "imageToolSha256", "launcher", "launcherSha256", "imageConfiguration", "companyConfiguration", "companyHome", "model", "validationConfiguration"]) || !fields(config.backend.model, ["endpoint", "handle", "model", "credential"]) || !Number.isSafeInteger(config.concurrency) || config.concurrency < 1 || config.concurrency > 4 || !Number.isSafeInteger(config.poll_ms) || config.poll_ms < 250 || config.poll_ms > 5000) throw new Error("InvalidCompanyWorkersConfiguration");
  return config;
}

export async function runWorkerServer(config, signal, report = () => {}) {
  validate(config);
  signal?.throwIfAborted();
  const backend = await createLinuxWorkerBackend({ ...structuredClone(config.backend), evaluation: structuredClone(config.control), concurrency: config.concurrency });
  const control = createWorkerHttpControl(structuredClone(config.control));
  const coordinator = createWorkerCoordinator({ control, backend, concurrency: config.concurrency });
  let previous;
  const stop = () => { void coordinator.close().catch(() => {}); };
  signal?.addEventListener("abort", stop, { once: true });
  if (signal?.aborted) stop();
  try {
    report({ event: "worker_server_started", workspace: config.control.workspaceId, concurrency: config.concurrency });
    while (!signal?.aborted) {
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
    signal?.removeEventListener("abort", stop);
    await coordinator.close();
    control.close();
    report({ event: "worker_server_stopped" });
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
  main().catch(error => { process.stderr.write(JSON.stringify({ event: "worker_server_failed", error: /^[A-Z][A-Za-z0-9]{0,95}$/.test(error.message) ? error.message : "WorkerServerFailed" }) + "\n"); process.exitCode = 1; });
}
