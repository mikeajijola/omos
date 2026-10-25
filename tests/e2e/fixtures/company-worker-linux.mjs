import fs from "node:fs/promises";
import { runWorkerServer } from "../../../deployment/company/worker-server.mjs";
import { createWorkerHttpControl } from "../../../deployment/company/worker-http-control.mjs";

let control, supervisor;
const stopping = new AbortController();
try {
  const settings = JSON.parse(await fs.readFile(process.argv[2], "utf8"));
  control = createWorkerHttpControl(settings.control);
  let serverError, started = 0;
  supervisor = runWorkerServer({ version: "omos.company-workers/v1", backend: settings.backend, control: settings.control, concurrency: 1, poll_ms: 250 }, stopping.signal, event => { started += event.started ?? 0; }).catch(error => { serverError = error; });
  const deadline = Date.now() + 360000;
  let selected;
  for (;;) {
    if (serverError) throw serverError;
    const result = await control.call({ change: "inspect", view: settings.view });
    if (!result.ok || result.jobs.length !== 1) throw new Error("FixtureJobInspectionFailed");
    selected = result.jobs[0];
    if (!["queued", "running", "submitted"].includes(selected.record.state) || selected.review_state === "failed" || Date.now() >= deadline) break;
    await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
  }
  if (serverError) throw serverError;
  process.stdout.write(JSON.stringify({ ok: true, started, state: selected.record.state, invocations: selected.record.invocations, generation: selected.record.generation, published: !!selected.publication, note: selected.record.note }));
} catch (error) {
  process.stdout.write(JSON.stringify({ ok: false, error: /^[A-Z][A-Za-z0-9]+$/.test(error.message) ? error.message : "FixtureWorkerFailed" }));
  process.exitCode = 1;
} finally {
  stopping.abort();
  if (supervisor) await supervisor;
  if (control) control.close();
}
