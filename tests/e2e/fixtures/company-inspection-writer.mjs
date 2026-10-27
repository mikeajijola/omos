import { createWorkerHttpControl, createArchiveHttpControl, createActivityHttpControl } from "../../../deployment/company/worker-http-control.mjs";
let input = "";
for await (const chunk of process.stdin) input += chunk;
const config = JSON.parse(input);
const workers = createWorkerHttpControl(config.transport), archive = createArchiveHttpControl(config.transport), activity = createActivityHttpControl(config.transport);
try {
  const signal = () => AbortSignal.timeout(10000);
  const jobs = await workers.call({ change: "inspect", view: config.view }, signal());
  const request = { version: "omos.company-actor-archive-write/v1", action: "inspect", view: config.view, execution: config.execution, source: config.source, offset: 0, content: "" };
  const retained = jobs.ok ? await archive.call(request, signal()) : null;
  const events = retained?.ok ? await activity.call({ version: "omos.company-activity-write/v1", action: "inspect", view: config.view, execution: config.execution }, signal()) : null;
  const fenced = events?.ok ? await archive.call({ ...request, execution: { ...config.execution, generation: config.execution.generation + 1 } }, signal()) : null;
  process.stdout.write(JSON.stringify({ jobs, retained, events, fenced }));
} finally { workers.close(); archive.close(); activity.close(); }
