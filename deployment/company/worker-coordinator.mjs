// Dispatch policy over native durable jobs. The execution backend must stop all
// actor processes before resolving run(); actor output never proves acceptance.
import { randomUUID } from "node:crypto";

const fail = code => { throw new Error(code); };
const sameOwner = (row, owned) => row?.record?.state === "running" && row.record.runtime === owned.runtime && row.record.generation === owned.generation && row.execution?.runtime === owned.runtime && row.execution.generation === owned.generation;

export function createWorkerCoordinator({ control, backend, concurrency = 1, runtime = randomUUID() }) {
  if (typeof control?.call !== "function" || typeof backend?.run !== "function" || !Number.isSafeInteger(concurrency) || concurrency < 1 || concurrency > 4 || typeof runtime !== "string" || !/^[A-Za-z0-9_.-]{1,128}$/.test(runtime)) fail("InvalidWorkerCoordinator");
  const active = new Map();
  let closed = false, scanning = false, cursor = 0;
  const inspect = async view => {
    const result = await control.call({ change: "inspect", view });
    if (!result.ok || result.jobs.length !== 1) fail("WorkerCoordinatorInspectionFailed");
    return result.jobs[0];
  };
  const update = async request => {
    const reply = await control.call(request);
    if (reply.ok) return reply.jobs[0];
    // Native mutations are atomic, but their acknowledgement may be lost.
    // Inspect before allowing actor work. Never repeat an uncertain action.
    const current = await inspect(request.view);
    if (current.record.operation === request.operation) return current;
    fail(reply.uncertain ? "WorkerCoordinatorOutcomeUnknown" : "WorkerCoordinatorUpdateFailed");
  };
  const dispatch = (row, controller) => {
    const owned = { runtime: row.record.runtime, generation: row.record.generation };
    const view = row.record.binding.view;
    const timer = setTimeout(() => controller.abort(new Error("WorkerInvocationDeadline")), Math.max(1, Math.min(row.record.max_runtime_ms, row.record.expires_ms - Date.now() - 1000)));
    const entry = { owned, controller, promise: null };
    active.set(view, entry);
    entry.promise = (async () => {
      let result;
      try {
        let invocation = row;
        if (invocation.pending_operation) {
          if (typeof backend.recover !== "function") fail("WorkerRecoveryRequired");
          await backend.recover(structuredClone(invocation), controller.signal);
          invocation = await inspect(view);
          if (!sameOwner(invocation, owned) || !invocation.authority_live || invocation.record.expires_ms <= Date.now()) fail("WorkerExecutionRevoked");
          if (invocation.pending_operation) fail("WorkerRecoveryRequired");
        }
        if (invocation.publication || ["queued", "running"].includes(invocation.review_state)) result = { outcome: "submitted" };
        else if (invocation.planning_required) result = { outcome: "waiting", note: "The retained internal operation was reconciled. Requeue for host planning before starting actor work." };
        else result = await backend.run(structuredClone(invocation), controller.signal);
      }
      catch (error) { if (error?.executionUncertain) return; const cause = /^[A-Z][A-Za-z0-9]{0,95}$/.test(error?.message) ? error.message : "IsolatedInvocationFailed"; result = { outcome: "failed", note: `${cause}. Inspect the retained isolated checkpoint before resuming.` }; }
      finally { clearTimeout(timer); }
      // run() must have joined cleanup here. A revoked/cancelled/fenced worker
      // cannot release a newer execution owner or overwrite its job outcome.
      const current = await inspect(view);
      if (!sameOwner(current, owned)) return;
      if (!current.authority_live || current.record.expires_ms <= Date.now()) return;
      const outcome = current.task_state === "accepted" && current.publication ? "completed"
        : current.review_job_id ? "submitted"
        : ["waiting", "failed"].includes(result?.outcome) ? result.outcome : "waiting";
      await update({ change: "finish", operation: randomUUID(), view, expected_sha256: current.sha256, execution: owned, outcome,
        note: typeof result?.note === "string" ? result.note.slice(0, 512) : "Invocation stopped; canonical company evidence determines publication." });
    })().catch(() => {
      // Leave an uncertain result retained and fenced until inspection/expiry.
      // Restarting the coordinator must not repeat the actor automatically.
    }).finally(() => active.delete(view));
  };
  return Object.freeze({
    async tick() {
      if (closed) fail("WorkerCoordinatorClosed");
      if (scanning) fail("WorkerCoordinatorBusy");
      scanning = true;
      let offset = cursor, inspected = 0, started = 0;
      try {
        // Bound each pass; further jobs are considered on the next pass.
        for (let pageNumber = 0; pageNumber < 32; pageNumber++) {
          const page = await control.call({ change: "inspect", offset, limit: 32 });
          if (!page.ok || !Array.isArray(page.jobs) || page.jobs.length > 32) fail("WorkerCoordinatorInspectionFailed");
          for (const row of page.jobs) {
            inspected++;
            const view = row.record.binding.view;
            const running = active.get(view);
            if (running) {
              if (!sameOwner(row, running.owned) || !row.authority_live || row.record.expires_ms <= Date.now()) running.controller.abort(new Error("WorkerExecutionRevoked"));
              continue;
            }
            if (row.task_state === "accepted" && row.publication && !["completed", "cancelled"].includes(row.record.state)) {
              await update({ change: "complete", operation: randomUUID(), view, expected_sha256: row.sha256 });
            } else if (row.record.state === "running" && row.record.expires_ms <= Date.now()) {
              await update({ change: "expire", operation: randomUUID(), view, expected_sha256: row.sha256 });
            } else if (!closed && row.record.state === "queued" && row.authority_live && active.size < concurrency && (!row.pending_operation || typeof backend.recover === "function")) {
              if (["queued", "running"].includes(row.review_state)) continue;
              let prepared = row;
              if (row.planning_required && !row.pending_operation) {
                if (["queued", "running"].includes(row.planning_state)) continue;
                prepared = await update({ change: "plan", operation: randomUUID(), view, expected_sha256: row.sha256 });
                if (closed || prepared.record.state !== "queued" || prepared.planning_required) continue;
              }
              const claimed = await update({ change: "claim", operation: randomUUID(), view, expected_sha256: prepared.sha256, execution: { runtime, generation: prepared.execution?.generation ?? 0 } });
              const owned = { runtime, generation: claimed.record.generation };
              if (!sameOwner(claimed, owned) || !claimed.authority_live || claimed.record.expires_ms - Date.now() < 1000 || (claimed.pending_operation && typeof backend.recover !== "function") || !claimed.contract || !claimed.request || !claimed.basis || !claimed.grant) fail("WorkerCoordinatorClaimChanged");
              if (closed) {
                await update({ change: "finish", operation: randomUUID(), view, expected_sha256: claimed.sha256, execution: owned, outcome: "waiting", note: "Coordinator stopped before actor dispatch." });
              } else { dispatch(claimed, new AbortController()); started++; }
            }
          }
          if (page.next_offset === null) { cursor = 0; break; }
          if (!Number.isSafeInteger(page.next_offset) || page.next_offset <= offset || !page.jobs.length) fail("WorkerCoordinatorInvalidCursor");
          offset = page.next_offset; cursor = offset;
        }
        return { inspected, started, active: active.size };
      } finally { scanning = false; }
    },
    async drain() { await Promise.all([...active.values()].map(entry => entry.promise)); },
    async close() {
      closed = true;
      for (const entry of active.values()) entry.controller.abort(new Error("WorkerCoordinatorClosed"));
      await Promise.all([...active.values()].map(entry => entry.promise));
    },
  });
}
