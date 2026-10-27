import { createRuntimeHttpControl } from "../../../deployment/company/worker-http-control.mjs";
let input = "";
for await (const chunk of process.stdin) input += chunk;
const config = JSON.parse(input), control = createRuntimeHttpControl(config.transport);
const timer = setTimeout(() => process.exit(1), 45000);
const call = request => control.call({ version: "omos.company-runtime/v1", ...request }, AbortSignal.timeout(10000));
try {
  const request = { id: config.id, registration_sha256: config.sha256, instance: "c".repeat(64) };
  const heartbeat = await call({ change: "heartbeat", ...request });
  const result = { heartbeat };
  if (heartbeat.ok) {
    result.replacement = await call({ change: "heartbeat", ...request, instance: "d".repeat(64) });
    result.stopped = await call({ change: "stop", ...request });
    result.delayed = await call({ change: "heartbeat", ...request });
  }
  process.stdout.write(JSON.stringify(result));
} finally { clearTimeout(timer); control.close(); }
