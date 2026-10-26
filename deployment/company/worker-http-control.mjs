// Private owner transport for a coordinator running separately from the native
// service account. The gateway authenticates this endpoint before dispatch.
import http from "node:http";

function createOwnerControl({ endpoint, workspaceId, token }, evaluation) {
  const url = new URL(endpoint);
  if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || !url.port || url.username || url.password || url.search || url.hash || url.pathname !== "/" || !/^[0-9a-f]{64}$/.test(workspaceId) || typeof token !== "string" || !/^[!-~]{32,1024}$/.test(token)) throw new Error("InvalidWorkerHttpControl");
  url.pathname = evaluation ? "/v1/company/evaluation" : "/v1/company/workers";
  const active = new Set();
  let closed = false;
  return Object.freeze({
    async call(request, signal) {
      if (closed) throw new Error("WorkerControlClosed");
      if (active.size >= 4) throw new Error("WorkerControlBusy");
      if (!request || typeof request !== "object" || Array.isArray(request)) throw new Error("InvalidWorkerControlRequest");
      const mutation = evaluation ? request.action === "record" : request.change !== "inspect";
      const body = JSON.stringify({ version: evaluation ? "omos.company-evaluation-api/v1" : "omos.company-worker-api/v1", workspace: workspaceId, request: structuredClone(request) });
      if (Buffer.byteLength(body) > (evaluation ? 256 * 1024 : 65536)) throw new Error("WorkerControlRequestTooLarge");
      const controller = new AbortController();
      active.add(controller);
      const timer = setTimeout(() => controller.abort(), 30000);
      try {
        const response = await new Promise((resolve, reject) => {
          // An owner mutation must never be replayed because an idle pooled
          // socket expired. Each operation gets one fresh connection.
          const request = http.request(url, { method: "POST", agent: false, headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "content-length": Buffer.byteLength(body), connection: "close" }, signal: signal ? AbortSignal.any([signal, controller.signal]) : controller.signal }, incoming => {
            const chunks = []; let total = 0;
            incoming.on("data", chunk => {
              total += chunk.length;
              if (total > 8 * 1024 * 1024) { request.destroy(new Error("WorkerControlResponseTooLarge")); return; }
              chunks.push(chunk);
            });
            incoming.once("error", reject);
            incoming.once("end", () => resolve({ status: incoming.statusCode, body: Buffer.concat(chunks, total).toString("utf8") }));
          });
          request.once("error", reject);
          request.end(body);
        });
        const parsed = JSON.parse(response.body);
        if (response.status !== 200) return { ok: false, error: typeof parsed.error === "string" && /^[A-Z][A-Za-z0-9]{0,95}$/.test(parsed.error) ? parsed.error : "WorkerControlRejected", uncertain: mutation, operation: request.operation ?? null };
        const value = parsed.data;
        if (parsed.workspace !== workspaceId || !value || (evaluation
          ? !["omos.company-validation-input/v1", "omos.company-evaluation-outcome/v1"].includes(value.version) || !/^[0-9a-f]{64}$/.test(value.task) || !/^[0-9a-f]{64}$/.test(value.revision)
          : !Array.isArray(value.jobs) || value.jobs.length > 32 || value.jobs.some(row => row.record?.binding?.workspace !== workspaceId))) throw new Error("WorkerControlBindingChanged");
        return { ...value, ok: true };
      } catch {
        return { ok: false, error: "WorkerControlOutcomeUnknown", uncertain: mutation, operation: request.operation ?? null };
      } finally { clearTimeout(timer); active.delete(controller); }
    },
    close() {
      closed = true;
      for (const controller of active) controller.abort();
    },
  });
}

export const createWorkerHttpControl = config => createOwnerControl(config, false);
export const createEvaluationHttpControl = config => createOwnerControl(config, true);
