import fs from "node:fs/promises";
import { runWorkerServer } from "../../../deployment/company/worker-server.mjs";
import { createWorkerHttpControl, createDesiredHttpControl } from "../../../deployment/company/worker-http-control.mjs";
import { createCompanyClient } from "../../../deployment/company/mcp.mjs";
import { randomUUID } from "node:crypto";

let control, desired, supervisor, actor;
let stopping = new AbortController();
try {
  const settings = JSON.parse(await fs.readFile(process.argv[2], "utf8"));
  control = createWorkerHttpControl(settings.control);
  if (settings.desiredPolicy) desired = createDesiredHttpControl(settings.control);
  let serverError, started = 0, recoveredArchive = false, recoveredCoding = false, recoveredPartial = false;
  const start = () => runWorkerServer({ version: "omos.company-workers/v1", backend: settings.backend, control: settings.control, concurrency: 1, poll_ms: 250, reconciliation: settings.reconciliation === true }, stopping.signal, event => { started += event.started ?? 0; }).catch(error => { serverError = error; });
  supervisor = start();
  const deadline = Date.now() + 360000;
  let requested = !settings.hostedRequest;
  if (!requested) actor = await createCompanyClient(settings.backend.companyConfiguration, { home: settings.backend.companyHome });
  let selected, desiredMetAt = 0;
  for (;;) {
    if (serverError) throw serverError;
    if (!requested) {
      const context = await actor.call("company_context", {});
      if (context.isError) throw new Error("FixtureHostedContextFailed");
      if (!JSON.parse(context.content[0].text).company.features.hosted_execution) {
        await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 50))]);
        if (Date.now() >= deadline) throw new Error("FixtureHostedRuntimeUnavailable");
        continue;
      }
      const queued = await actor.call("company_workspace", { version: "omos.company/v1", action: "execute_task", ...settings.hostedRequest, operation: randomUUID(), expires_ms: Date.now() + 120000 });
      if (queued.isError) throw new Error("FixtureHostedRequestFailed");
      requested = true;
    }
    const result = await control.call({ change: "inspect", view: settings.view });
    if (!result.ok || result.jobs.length > 1) throw new Error("FixtureJobInspectionFailed");
    if (settings.desiredPolicy && result.jobs.length === 0) {
      if (Date.now() >= deadline) throw new Error("FixtureDesiredTaskUnavailable");
      await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
      continue;
    }
    if (result.jobs.length !== 1) throw new Error("FixtureJobInspectionFailed");
    selected = result.jobs[0];
    if (settings.desiredPolicy) {
      if (!settings.view) settings.view = selected.record.binding.view;
      if (selected.record.state === "completed") {
        const observed = await desired.call({ change: "inspect", id: settings.desiredPolicy });
        if (!observed.ok || observed.policies.length !== 1) throw new Error("FixtureDesiredInspectionFailed");
        if (observed.policies[0].state?.phase === "met") {
          if (observed.policies[0].state.task !== selected.record.binding.task) throw new Error("FixtureDesiredTaskChanged");
          if (!desiredMetAt) desiredMetAt = Date.now();
          if (Date.now() - desiredMetAt >= 5500) break;
        }
        if (Date.now() >= deadline) throw new Error("FixtureDesiredOutcomeUnavailable");
        await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
        continue;
      }
    }
    if (settings.archiveRecovery && !recoveredArchive && selected.record.state === "failed") {
      const checkpoint = selected.record.checkpoint;
      if (checkpoint?.phase !== "stopped" || !checkpoint.export_directory || checkpoint.generation !== 1) throw new Error("FixtureArchiveCheckpointMissing");
      stopping.abort(); await supervisor;
      const resumed = await control.call({ change: "requeue", operation: randomUUID(), view: settings.view, expected_sha256: selected.sha256 });
      if (!resumed.ok) throw new Error("FixtureArchiveRequeueFailed");
      recoveredArchive = true;
      stopping = new AbortController(); supervisor = start();
      continue;
    }
    if (settings.partialRecovery && !recoveredPartial && selected.record.state === "failed") {
      if (selected.record.checkpoint?.phase !== "running" || selected.record.checkpoint.generation !== 1) throw new Error("FixturePartialCheckpointMissing");
      stopping.abort(); await supervisor;
      const resumed = await control.call({ change: "requeue", operation: randomUUID(), view: settings.view, expected_sha256: selected.sha256 });
      if (!resumed.ok) throw new Error("FixturePartialRequeueFailed");
      recoveredPartial = true;
      stopping = new AbortController(); supervisor = start();
      continue;
    }
    if (settings.codingRecovery && !recoveredCoding && selected.record.state === "waiting") {
      if (selected.record.checkpoint?.phase !== "retained" || !selected.record.note.includes("failed coding checks")) throw new Error("FixtureCodingCheckpointMissing");
      stopping.abort(); await supervisor;
      const resumed = await control.call({ change: "requeue", operation: randomUUID(), view: settings.view, expected_sha256: selected.sha256 });
      if (!resumed.ok) throw new Error("FixtureCodingRequeueFailed");
      recoveredCoding = true;
      stopping = new AbortController(); supervisor = start();
      continue;
    }
    if (!["queued", "running", "submitted"].includes(selected.record.state) || selected.review_state === "failed" || Date.now() >= deadline) break;
    await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
  }
  if (serverError) throw serverError;
  process.stdout.write(JSON.stringify({ ok: true, started, state: selected.record.state, invocations: selected.record.invocations, generation: selected.record.generation, published: !!selected.publication, note: selected.record.note, recovered_archive: recoveredArchive, recovered_coding: recoveredCoding, recovered_partial: recoveredPartial, view: selected.record.binding.view, desired_met: desiredMetAt !== 0 }));
} catch (error) {
  process.stdout.write(JSON.stringify({ ok: false, error: /^[A-Z][A-Za-z0-9]+$/.test(error.message) ? error.message : "FixtureWorkerFailed" }));
  process.exitCode = 1;
} finally {
  stopping.abort();
  if (supervisor) await supervisor;
  if (control) control.close();
  if (desired) desired.close();
  if (actor) actor.close();
}
