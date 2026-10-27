import http from "node:http";
import assert from "node:assert/strict";
import { createArchiveHttpControl } from "../../../deployment/company/worker-http-control.mjs";

const timer = setTimeout(() => { process.stderr.write("Owner transport fixture did not stop\n"); process.exit(1); }, 5000);
const outcomes = [];
try {
  for (const cancelled of [false, true]) {
    const controller = new AbortController(); let requests = 0;
    const server = http.createServer(request => {
      requests++;
      request.once("end", () => { if (cancelled) controller.abort(); else request.socket.destroy(); });
      request.resume();
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const control = createArchiveHttpControl({ endpoint: `http://127.0.0.1:${server.address().port}`, workspaceId: "a".repeat(64), token: "fixture-owner-control-token-no-secrets" });
    try {
      const result = await control.call({ action: "chunk", operation: "retained-operation" }, controller.signal);
      assert.deepEqual(result, { ok: false, error: "WorkerControlOutcomeUnknown", transport: cancelled ? "RequestCancelled" : "ECONNRESET", uncertain: true, operation: "retained-operation" });
      assert.equal(requests, 1);
      assert.equal(JSON.stringify(result).includes("fixture-owner-control-token"), false);
      outcomes.push({ transport: result.transport, requests, uncertain: result.uncertain });
    } finally { control.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  }
  process.stdout.write(JSON.stringify(outcomes));
} finally { clearTimeout(timer); }
