// The company record is durable before an actor can start. Lost acknowledgements
// are resolved by operation identity, never by rerunning the actor.
import { randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";

export function createWorkerCheckpointer({ control, view, execution }) {
  return async checkpoint => {
    const inspected = await control.call({ change: "inspect", view });
    if (!inspected.ok) throw Object.assign(new Error("WorkerCheckpointInspectionPending"), { inspection: { kind: "checkpoint", error: inspected.error, transport: inspected.transport } });
    const row = inspected.ok && inspected.jobs?.length === 1 ? inspected.jobs[0] : null;
    if (!row?.authority_live || row.record.state !== "running" || row.record.runtime !== execution.runtime || row.record.generation !== execution.generation) throw new Error("WorkerCheckpointFenced");
    const operation = randomUUID();
    let reply;
    try { reply = await control.call({ change: "checkpoint", operation, view, execution, expected_sha256: row.sha256, checkpoint: structuredClone(checkpoint) }); }
    catch { reply = { ok: false }; }
    if (!reply.ok) reply = await control.call({ change: "inspect", view });
    const saved = reply.ok && reply.jobs?.length === 1 ? reply.jobs[0] : null;
    if (saved?.record.operation !== operation || !isDeepStrictEqual(saved.record.checkpoint, checkpoint)) throw new Error("WorkerCheckpointOutcomeUnknown");
    return saved.record.checkpoint;
  };
}
