import fs from "node:fs/promises";
import { runWorkerServer } from "../../../deployment/company/worker-server.mjs";
import { createWorkerHttpControl, createDesiredHttpControl } from "../../../deployment/company/worker-http-control.mjs";
import { createCompanyClient } from "../../../deployment/company/mcp.mjs";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";

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
  let selected, desiredMetAt = 0, inputOffset = 0, inputAnswered = false, interrupted = false, cancelledForRetention = false, retiredHistory = false, amendedTask = false;
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
    if (!result.ok && result.error === "WorkerControlOutcomeUnknown" && Date.now() < deadline) {
      // Inspection has no effects. A dropped read cannot establish a worker
      // failure, and the original fixture deadline still bounds observation.
      await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
      continue;
    }
    if (!result.ok || result.jobs.length > 1) throw Object.assign(new Error("FixtureJobInspectionFailed"), { controlCode: result.error });
    if (settings.desiredPolicy && result.jobs.length === 0) {
      if (Date.now() >= deadline) throw new Error("FixtureDesiredTaskUnavailable");
      await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
      continue;
    }
    if (result.jobs.length !== 1) throw new Error("FixtureJobInspectionFailed");
    selected = result.jobs[0];
    if (settings.inputResponse && !inputAnswered && selected.record.state === "running") {
      actor ??= await createCompanyClient(settings.backend.companyConfiguration, { home: settings.backend.companyHome });
      const invoke = async input => {
        const result = await actor.call("company_workspace", { version: "omos.company/v1", operation: randomUUID(), expires_ms: Date.now() + 120000, ...input });
        if (result.isError) throw new Error("FixtureInputRequestFailed");
        return JSON.parse(result.content[0].text);
      };
      const page = await invoke({ action: "status", view: settings.view, entity: "omos_company_activity", record_id: String(selected.record.generation), offset: inputOffset, limit: 2 });
      inputOffset = page.resume_offset;
      const question = page.events.find(event => event.data.type === "input_required");
      if (question) {
        await invoke({ action: "execute_task", view: settings.view, revision: selected.view_revision, execution: { runtime: selected.record.runtime, generation: selected.record.generation }, content: JSON.stringify({ version: "omos.company-task-control/v1", mode: "input", event_offset: question.offset, request_id: question.data.request_id, answers: ["Brief"] }) });
        inputAnswered = true;
      }
    }
    if (settings.amendment && !amendedTask && selected.record.checkpoint?.phase === "running") {
      const ready = await (await fetch(settings.actorWaitUrl, { signal: AbortSignal.timeout(5000) })).json();
      if (ready.ready === true) {
        actor ??= await createCompanyClient(settings.backend.companyConfiguration, { home: settings.backend.companyHome });
        const result = await actor.call("company_workspace", { version: "omos.company/v1", action: "execute_task", view: settings.view, revision: selected.view_revision, execution: { runtime: selected.record.runtime, generation: selected.record.generation }, operation: randomUUID(), expires_ms: Date.now() + 120000, content: JSON.stringify({ version: "omos.company-task-amend/v1", text: "Replace the document with Amended by the authenticated user" }) });
        if (result.isError || JSON.parse(result.content[0].text).state !== "planning") throw new Error("FixtureAmendmentFailed");
        amendedTask = true;
      }
    }
    if (settings.partialRecovery && !interrupted && selected.record.checkpoint?.phase === "running") {
      const ready = await (await fetch(settings.actorWaitUrl, { signal: AbortSignal.timeout(5000) })).json();
      if (ready.ready === true) {
        const saved = selected.record.checkpoint;
        const request = { version: "omos.worker-image-request/v1", action: "quiesce", id: saved.image, workspace: selected.record.binding.workspace, view: settings.view, generation: saved.generation, max_runtime_ms: selected.record.max_runtime_ms, model: saved.model, source_revision: saved.source_revision };
        const killed = await new Promise((resolve, reject) => {
          const child = spawn("/usr/bin/python3", ["-I", settings.backend.imageTool, settings.backend.imageConfiguration], { stdio: ["pipe", "ignore", "ignore"] });
          child.once("error", reject); child.once("close", resolve); child.stdin.end(JSON.stringify(request));
        });
        if (killed !== 0) throw new Error("FixturePartialInterruptionFailed");
        interrupted = true;
      }
    }
    if (settings.retirement) {
      if (!cancelledForRetention && selected.record.checkpoint?.phase === "running") {
        const ready = await (await fetch(settings.actorWaitUrl, { signal: AbortSignal.timeout(5000) })).json();
        if (ready.ready === true) {
          const cancelled = await control.call({ change: "cancel", operation: randomUUID(), view: settings.view, expected_sha256: selected.sha256 });
          if (!cancelled.ok) throw new Error("FixtureRetentionCancelFailed");
          cancelledForRetention = true;
        }
      }
      if (selected.record.request.change === "retire") {
        const configuration = JSON.parse(await fs.readFile(settings.backend.imageConfiguration, "utf8"));
        let exists = true;
        try { await fs.lstat(configuration.root + "/" + selected.record.checkpoint.image.slice(0, 24)); }
        catch (error) { if (error.code === "ENOENT") exists = false; else throw error; }
        if (!exists) { retiredHistory = true; break; }
      }
      if (Date.now() >= deadline) throw new Error("FixtureRetainedHistoryUnavailable");
      await Promise.race([supervisor, new Promise(resolve => setTimeout(resolve, 250))]);
      continue;
    }
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
    if (settings.partialRecovery && !recoveredPartial && ["failed", "waiting"].includes(selected.record.state)) {
      const checkpoint = selected.record.checkpoint;
      if (!checkpoint || !["running", "stopped"].includes(checkpoint.phase) || checkpoint.generation !== 1 || checkpoint.continuation || (selected.record.state === "waiting" && !selected.record.note?.includes("no bounded recorded answer"))) throw new Error("FixturePartialCheckpointMissing");
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
  process.stdout.write(JSON.stringify({ ok: true, started, state: selected.record.state, invocations: selected.record.invocations, generation: selected.record.generation, published: !!selected.publication, note: selected.record.note, recovered_archive: recoveredArchive, recovered_coding: recoveredCoding, recovered_partial: recoveredPartial, view: selected.record.binding.view, desired_met: desiredMetAt !== 0, input_answered: inputAnswered, retired_history: retiredHistory, amended_task: amendedTask }));
} catch (error) {
  const code = error.nativeCode ?? error.controlCode;
  process.stdout.write(JSON.stringify({ ok: false, error: /^[A-Z][A-Za-z0-9]+$/.test(error.message) ? error.message : "FixtureWorkerFailed", ...(typeof code === "string" && /^[A-Z][A-Za-z0-9]+$/.test(code) ? { control_error: code } : {}) }));
  process.exitCode = 1;
} finally {
  stopping.abort();
  if (supervisor) await supervisor;
  if (control) control.close();
  if (desired) desired.close();
  if (actor) actor.close();
}
