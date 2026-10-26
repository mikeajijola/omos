import fs from "node:fs/promises";
import { runWorkerServer } from "../../../deployment/company/worker-server.mjs";
import { createWorkerHttpControl } from "../../../deployment/company/worker-http-control.mjs";
import { createCompanyClient } from "../../../deployment/company/mcp.mjs";
import { randomUUID } from "node:crypto";

let control, supervisor, actor;
const stopping = new AbortController();
try {
  const settings = JSON.parse(await fs.readFile(process.argv[2], "utf8"));
  control = createWorkerHttpControl(settings.control);
  let serverError, started = 0;
  supervisor = runWorkerServer({ version: "omos.company-workers/v1", backend: settings.backend, control: settings.control, concurrency: 1, poll_ms: 250 }, stopping.signal, event => { started += event.started ?? 0; }).catch(error => { serverError = error; });
  const deadline = Date.now() + 360000;
  let requested = !settings.hostedRequest;
  if (!requested) actor = await createCompanyClient(settings.backend.companyConfiguration, { home: settings.backend.companyHome });
  let selected;
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
  if (actor) actor.close();
}
