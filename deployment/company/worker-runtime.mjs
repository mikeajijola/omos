// Canonical implementation descriptions live in Fossil. This object retains
// only the coordinator's disposable heartbeat and its current process nonce.
import { createHash, randomBytes } from "node:crypto";

const fail = code => { throw new Error(code); };
const hex = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);

export async function advertiseWorkerRuntime({ control, description, signal }) {
  if (typeof control?.call !== "function" || !description || !hex(description.workspace) || !hex(description.package_sha256) || typeof description.model_handle !== "string" || !Array.isArray(description.subjects) || !description.subjects.length || !Array.isArray(description.validation_handles)) fail("InvalidWorkerRuntimeDescription");
  const id = createHash("sha256").update(JSON.stringify([description.workspace, description.model_handle, description.subjects])).digest("hex");
  const registration = { version: "omos.company-runtime-registration/v1", id, workspace: description.workspace, package_sha256: description.package_sha256, model_handle: description.model_handle, isolation: "omos.linux-worker/v1", subjects: structuredClone(description.subjects), validation_handles: [...description.validation_handles] };
  const expected = createHash("sha256").update(JSON.stringify(registration)).digest("hex");
  const inspect = async () => {
    const result = await control.call({ version: "omos.company-runtime/v1", change: "inspect", id }, signal);
    if (!result.ok || !Array.isArray(result.runtimes) || result.runtimes.length > 1) fail("WorkerRuntimeInspectionFailed");
    return result;
  };
  let selected = await inspect();
  if (selected.runtimes[0]?.sha256 !== expected) {
    const result = await control.call({ version: "omos.company-runtime/v1", change: "register", id, revision: selected.revision, registration }, signal);
    // Inspect a lost acknowledgement; registration has no actor effects.
    if (!result.ok) {
      selected = await inspect();
      if (selected.runtimes[0]?.sha256 !== expected) fail("WorkerRuntimeRegistrationPending");
    } else if (result.sha256 !== expected) fail("WorkerRuntimeRegistrationChanged");
  }
  const instance = randomBytes(32).toString("hex");
  let stopped = false, released = false, last = 0;
  const heartbeat = async force => {
    if (stopped) fail("WorkerRuntimeClosed");
    if (!force && Date.now() - last < 10000) return;
    const request = { version: "omos.company-runtime/v1", change: "heartbeat", id, registration_sha256: expected, instance };
    let result = await control.call(request, signal);
    // This exact process nonce can renew only its own disposable lease. A lost
    // acknowledgement does not justify cancelling its already fenced actor.
    if (!result.ok && result.error === "WorkerControlOutcomeUnknown") result = await control.call(request, signal);
    if (!result.ok || !result.live || result.sha256 !== expected) throw Object.assign(new Error(result.error === "CompanyRuntimeBusy" ? "WorkerRuntimeAlreadyActive" : "WorkerRuntimeHeartbeatFailed"), { nativeCode: result.error });
    last = Date.now();
  };
  await heartbeat(true);
  return Object.freeze({
    id,
    async heartbeat() { await heartbeat(false); },
    async close() {
      if (released) return;
      stopped = true;
      const request = { version: "omos.company-runtime/v1", change: "stop", id, registration_sha256: expected, instance };
      let result = await control.call(request);
      // Stopping this exact nonce is idempotent. Confirm a lost stop response
      // before another coordinator tries to advertise the same implementation.
      if (!result.ok && result.error === "WorkerControlOutcomeUnknown") result = await control.call(request);
      if (!result.ok || result.live !== false || result.sha256 !== expected) throw Object.assign(new Error("WorkerRuntimeReleasePending"), { nativeCode: result.error });
      released = true;
    },
  });
}
