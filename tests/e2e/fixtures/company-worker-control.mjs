// Exercise the operator transport in the deployment's Node.js runtime.
import fs from "node:fs/promises";
import { createWorkerControl } from "../../../deployment/company/worker-control.mjs";

try {
  const { request, ...settings } = JSON.parse(await fs.readFile(process.argv[2], "utf8"));
  const control = await createWorkerControl(settings);
  try { process.stdout.write(JSON.stringify(await control.call(request)) + "\n"); }
  finally { control.close(); }
} catch {
  process.stderr.write("Worker control fixture failed.\n");
  process.exitCode = 1;
}
