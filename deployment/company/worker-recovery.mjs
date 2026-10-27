import { randomUUID } from "node:crypto";
import { createCompanyClient } from "./mcp.mjs";

export const initialWorkerAdmission = row => Boolean(row?.authority_live && row.record?.state === "queued" && row.record.invocations === 0 && row.record.generation === 0 && row.record.runtime === null && row.record.checkpoint == null && row.execution === null && !row.pending_amendment && typeof row.pending_operation === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(row.pending_operation));

export async function recoverQueuedWorkerAdmission(row, { configuration, home }, signal) {
  const binding = row.record?.binding;
  if (!initialWorkerAdmission(row) || !binding || !row.grant?.actions?.includes("reconcile") || !Number.isSafeInteger(row.grant.expires_ms) || row.grant.expires_ms <= Date.now()) throw new Error("WorkerRecoveryRequired");
  // No actor has owned this job. Native reconciliation verifies that there is
  // still no execution record; a concurrent claim fences this unfenced request.
  const client = await createCompanyClient(configuration, { home });
  try {
    if (client.identity.workspace !== binding.workspace || client.identity.actor !== binding.actor || client.identity.grant !== binding.grant) throw new Error("WorkerCompanyIdentityChanged");
    const result = await client.call("company_workspace", { version: "omos.company/v1", action: "reconcile", view: binding.view, outcome: row.pending_operation, operation: randomUUID(), expires_ms: Math.min(row.grant.expires_ms, Date.now() + 300000) }, signal);
    if (result.isError || JSON.parse(result.content[0].text).state !== "completed") throw new Error("WorkerRecoveryPending");
  } finally { client.close(); }
}
