// Privileged execution adapter. Install with its Python helpers under an
// operator-owned directory; company/provider keys never enter the worker root.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createCompanyClient } from "./mcp.mjs";
import { createWorkerBroker } from "./worker-broker.mjs";
import { createWorkerSnapshot, selectWorkerRoot, selectWorkerSession } from "./worker-snapshot.mjs";
import { retainWorkerArchive, prepareWorkerExport } from "./worker-archive.mjs";
import { createWorkerCheckpointer } from "./worker-checkpoint.mjs";
import { createArchiveHttpControl, createEvaluationHttpControl, createWorkerHttpControl, createActivityHttpControl, createInputHttpControl } from "./worker-http-control.mjs";
import { runCompanyValidation, validateValidationConfiguration } from "./worker-validation.mjs";
import { runWorkerNative } from "./worker-native.mjs";
import { recoverQueuedWorkerAdmission } from "./worker-recovery.mjs";

const fail = code => { throw new Error(code); };
const hex = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const fingerprint = info => [info.dev, info.ino, info.size, info.mode, info.uid, info.mtimeNs, info.ctimeNs].map(String).join(":");
async function trustedFile(filename, expected, limit = 65536) {
  if (!path.isAbsolute(filename) || await fs.realpath(filename) !== filename) fail("UnsafeWorkerHostFile");
  let parent = path.dirname(filename);
  for (;;) {
    const info = await fs.lstat(parent);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== 0 || ((info.mode & 0o022) && !(info.mode & 0o1000))) fail("UnsafeWorkerHostFile");
    if (parent === path.dirname(parent)) break;
    parent = path.dirname(parent);
  }
  const file = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const before = await file.stat({ bigint: true });
    if (!before.isFile() || before.nlink !== 1n || before.uid !== 0n || (before.mode & 0o6022n) || before.size > BigInt(limit)) fail("UnsafeWorkerHostFile");
    const bytes = await file.readFile();
    if (fingerprint(before) !== fingerprint(await file.stat({ bigint: true })) || (expected && createHash("sha256").update(bytes).digest("hex") !== expected)) fail("WorkerHostFileChanged");
    return bytes;
  } finally { await file.close(); }
}

async function command(program, args, { input, signal, timeout = 120000, maxBytes = 8 * 1024 * 1024 } = {}) {
  signal?.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" }, stdio: ["pipe", "pipe", "pipe"] });
    const output = [], errors = [];
    let size = 0, errorSize = 0, killed = false, force;
    const stop = () => {
      if (killed) return;
      killed = true; child.kill("SIGTERM");
      force = setTimeout(() => child.kill("SIGKILL"), 10000);
    };
    const timer = setTimeout(stop, timeout);
    signal?.addEventListener("abort", stop, { once: true });
    if (signal?.aborted) stop();
    child.stdout.on("data", chunk => { size += chunk.length; if (size <= maxBytes) output.push(chunk); else stop(); });
    child.stderr.on("data", chunk => { errorSize += chunk.length; if (errorSize <= 65536) errors.push(chunk); });
    child.stdin.on("error", () => {});
    child.once("error", reject);
    child.once("close", code => {
      clearTimeout(timer); clearTimeout(force); signal?.removeEventListener("abort", stop);
      if (size > maxBytes) reject(new Error("WorkerHostOutputBudgetExceeded"));
      else resolve({ code, killed, output_complete: !killed && errorSize <= 65536, stdout: Buffer.concat(output).toString("utf8"), stderr: Buffer.concat(errors).toString("utf8") });
    });
    child.stdin.end(input);
  });
}

export async function createLinuxWorkerBackend({ imageTool, imageToolSha256, launcher, launcherSha256, imageConfiguration, companyConfiguration, companyHome, model, validationConfiguration, evaluation, concurrency = 1, report = () => {} }) {
  if (typeof report !== "function") fail("InvalidWorkerProgressReporter");
  const progress = event => { try { report(event); } catch {} };
  const cancellation = signal => signal?.aborted ? ["WorkerInvocationDeadline", "WorkerExecutionRevoked", "WorkerCoordinatorClosed"].includes(signal.reason?.message) ? signal.reason.message : "Cancelled" : null;
  const observedControl = (kind, control, view, generation) => ({ ...control, async call(request, signal) {
    const started = Date.now(), action = request.action ?? request.change;
    progress({ event: "worker_operation", kind, view, generation, action, phase: "start", offset: request.offset ?? null, bytes: request.source?.bytes ?? null });
    let result;
    try { result = await control.call(request, signal); return result; }
    finally { progress({ event: "worker_operation", kind, view, generation, action, phase: "end", duration_ms: Date.now() - started, ok: result?.ok === true, abort_reason: cancellation(signal) }); }
  } });
  if (process.platform !== "linux" || process.getuid?.() !== 0 || !hex(imageToolSha256) || !hex(launcherSha256) || !model || typeof model.handle !== "string") fail("WorkerOperatorPrivilegesRequired");
  model = structuredClone(model);
  await trustedFile(imageTool, imageToolSha256, 131072);
  await trustedFile(launcher, launcherSha256, 131072);
  const configurationBytes = await trustedFile(imageConfiguration);
  const configuration = JSON.parse(configurationBytes.toString("utf8"));
  const validationBytes = validationConfiguration ? await trustedFile(validationConfiguration) : null;
  const validation = validationBytes ? validateValidationConfiguration(JSON.parse(validationBytes.toString("utf8"))) : null;
  if (validation && (!Number.isSafeInteger(concurrency) || concurrency < 1 || concurrency > 4 || configuration.max_images < 2 * concurrency)) fail("WorkerValidationImageCapacity");
  const validationSha256 = validationBytes ? createHash("sha256").update(validationBytes).digest("hex") : null;
  const environmentSha256 = createHash("sha256").update(JSON.stringify({ template: configuration.template_manifest_sha256, executable: configuration.executable_sha256, launcher: launcherSha256, image: imageToolSha256 })).digest("hex");
  evaluation = evaluation ? structuredClone(evaluation) : null;
  if (configuration.service_uid !== 0 || configuration.service_gid !== 0) fail("WorkerRootBrokerRequired");
  const probe = await command("/usr/bin/python3", ["-I", launcher, "--probe"], { timeout: 10000, maxBytes: 8192 });
  const support = probe.code === 0 ? JSON.parse(probe.stdout) : null;
  if (!support?.kernel_supported || !support.private_namespaces) fail("WorkerPrivateNamespacesRequired");
  if (!evaluation) fail("WorkerArchiveControlRequired");
  const image = async (request, signal) => {
    const started = Date.now();
    progress({ event: "worker_image", action: request.action, image: request.id, phase: "start" });
    try {
      await trustedFile(imageTool, imageToolSha256, 131072);
      if (!(await trustedFile(imageConfiguration)).equals(configurationBytes)) fail("WorkerHostFileChanged");
      const result = await command("/usr/bin/python3", ["-I", imageTool, imageConfiguration], { input: JSON.stringify(request), signal, maxBytes: 8192 });
      if (result.code !== 0) fail("WorkerImageOperationFailed");
      return JSON.parse(result.stdout);
    } finally { progress({ event: "worker_image", action: request.action, image: request.id, phase: "end", duration_ms: Date.now() - started, abort_reason: cancellation(signal) }); }
  };
  const run = async (root, args, signal, input) => {
    const started = Date.now(), verb = args[0], operation = verb === "fossil" ? args[1] : null;
    progress({ event: "worker_command", image: path.basename(root), verb, operation, phase: "start" });
    try {
      await trustedFile(launcher, launcherSha256, 131072);
      return await command("/usr/bin/python3", ["-I", launcher, root, "--", ...args], { signal, input, timeout: 300000 });
    } finally { progress({ event: "worker_command", image: path.basename(root), verb, operation, phase: "end", duration_ms: Date.now() - started, abort_reason: cancellation(signal) }); }
  };
  const subjectBytes = await trustedFile(companyConfiguration);
  const subject = JSON.parse(subjectBytes.toString("utf8"));
  if (!hex(subject.workspace) || subject.workspace !== evaluation.workspaceId || !/^[A-Za-z0-9_-]{1,128}$/.test(subject.actor) || !/^[A-Za-z0-9_-]{1,128}$/.test(subject.grant)) fail("WorkerCompanyIdentityChanged");
  const removeBrokerSocket = async root => {
    const socket = path.join(root, "run", "omos-broker.sock");
    try {
      const info = await fs.lstat(socket);
      if (!info.isSocket() || info.uid !== 0) fail("UnsafeWorkerBrokerSocket");
      await fs.unlink(socket);
    } catch (error) { if (error.code !== "ENOENT") throw error; }
  };
  const retirementAttempts = new Map();
  let identity, continuationSupported = false, amendmentsSupported = false, activitySupported = false, inputSupported = false;
  const backend = {
    async canRetire(row) {
      const job = row?.record, binding = job?.binding, saved = job?.checkpoint;
      if (!saved || binding?.workspace !== subject.workspace || binding.actor !== subject.actor || binding.grant !== subject.grant || (row.authority_live && (!["cancelled", "completed", "exhausted"].includes(job.state) || (job.state === "exhausted" && row.review_job_id))) || !hex(saved.image)) return false;
      if ((retirementAttempts.get(saved.image)?.next ?? 0) > Date.now()) return false;
      try { return (await fs.lstat(path.join(configuration.root, saved.image.slice(0, 24)))).isDirectory(); }
      catch (error) { if (error.code === "ENOENT") { retirementAttempts.delete(saved.image); return false; } throw error; }
    },
    async retire(row, signal) {
      const job = row?.record, binding = job?.binding, saved = job?.checkpoint;
      if (!saved || binding?.workspace !== subject.workspace || binding.actor !== subject.actor || binding.grant !== subject.grant || (row.authority_live && (!["cancelled", "completed", "exhausted"].includes(job.state) || (job.state === "exhausted" && row.review_job_id)))) return false;
      if (!(await trustedFile(companyConfiguration)).equals(subjectBytes)) fail("WorkerHostFileChanged");
      if (!hex(saved.image) || !hex(binding.view)) fail("InvalidWorkerInvocation");
      try { await fs.lstat(path.join(configuration.root, saved.image.slice(0, 24))); }
      catch (error) { if (error.code === "ENOENT") return false; throw error; }
      const attempt = Math.min(10, (retirementAttempts.get(saved.image)?.attempt ?? 0) + 1);
      retirementAttempts.set(saved.image, { attempt, next: Date.now() + Math.min(300000, 1000 * 2 ** (attempt - 1)) });
      try {
        const owner = createWorkerHttpControl(evaluation);
        let retired;
        try {
          let result = await owner.call({ change: "retire", operation: randomUUID(), view: binding.view, expected_sha256: row.sha256 }, signal);
          if (!result.ok) result = await owner.call({ change: "inspect", view: binding.view }, signal);
          retired = result.ok && result.jobs.length === 1 ? result.jobs[0] : null;
          if (retired?.record?.request?.change !== "retire" || retired.record.binding.task !== binding.task || retired.record.checkpoint?.image !== saved.image) return false;
        } finally { owner.close(); }
        // Native retirement is irreversible: no replacement actor can enter this
        // image while passive commands retain its public repository. These calls
        // neither start a model broker nor restore a compute grant.
        const request = { version: "omos.worker-image-request/v1", action: "prepare", id: saved.image, workspace: binding.workspace, view: binding.view, generation: saved.generation, max_runtime_ms: job.max_runtime_ms, model: saved.model, source_revision: saved.source_revision };
        const prepared = await image(request, signal);
        if (prepared.workspace !== binding.workspace || prepared.view !== binding.view || prepared.generation !== saved.generation || prepared.executable_sha256 !== configuration.executable_sha256 || path.dirname(prepared.root) !== configuration.root) fail("WorkerImageIdentityChanged");
        await image({ ...request, action: "quiesce" });
        await removeBrokerSocket(prepared.root);
        let retained = saved.phase === "prepared";
        try {
          if (!retained) {
            const snapshot = await run(prepared.root, ["fossil", "status", "--json"], signal);
            if (snapshot.code !== 0) fail("WorkerSnapshotUnavailable");
            const local = JSON.parse(snapshot.stdout), selected = selectWorkerRoot(local.tasks);
            if (!hex(local.workspace_id) || !hex(selected.id) || !hex(selected.model_basis?.definition_hash)) fail("WorkerSnapshotAmbiguous");
            const name = ".omos-host-read-" + randomUUID() + ".json";
            const file = path.join(prepared.root, "workspace", name);
            let head;
            try {
              await fs.writeFile(file, JSON.stringify({ version: "omos.workspace-api/v1", workspace: local.workspace_id, definition_hash: selected.model_basis.definition_hash, action: "head", task: selected.id }), { flag: "wx", mode: 0o400 });
              await fs.chown(file, prepared.uid, prepared.uid);
              const result = await run(prepared.root, ["fossil", "request", "/workspace/" + name, "--json"], signal);
              if (result.code !== 0) fail("WorkerSnapshotUnavailable");
              head = JSON.parse(result.stdout);
            } finally { await fs.rm(file, { force: true }); }
            if (!hex(head.data?.revision)) fail("WorkerSnapshotAmbiguous");
            const directory = path.join(prepared.root, "workspace", saved.export_directory ?? ".omos-host-archive-retired-" + saved.image);
            if (!saved.export_directory) {
              try { await fs.mkdir(directory, { mode: 0o700 }); }
              catch (error) { if (error.code !== "EEXIST") throw error; }
            }
            const info = await fs.lstat(directory);
            if (!info.isDirectory() || info.isSymbolicLink() || ![0, prepared.uid].includes(info.uid)) fail("UnsafeWorkerArchiveDirectory");
            if (!saved.export_directory) {
              const marker = path.join(directory, ".omos-retirement.json");
              const expected = Buffer.from(JSON.stringify({ retirement: retired.sha256, image: saved.image }));
              if (info.uid === 0) {
                try { await fs.writeFile(marker, expected, { flag: "wx", mode: 0o600 }); }
                catch (error) { if (error.code !== "EEXIST") throw error; }
              }
              const file = await fs.open(marker, constants.O_RDONLY | constants.O_NOFOLLOW);
              try {
                const info = await file.stat();
                if (!info.isFile() || info.uid !== 0 || info.nlink !== 1 || (info.mode & 0o777) !== 0o600 || info.size !== expected.length || !(await file.readFile()).equals(expected)) fail("UnsafeWorkerArchiveDirectory");
              } finally { await file.close(); }
            }
            await fs.chown(directory, prepared.uid, prepared.uid);
            const filename = path.join(directory, "actor.fossil");
            let exists = false;
            try { await fs.lstat(filename); exists = true; } catch (error) { if (error.code !== "ENOENT") throw error; }
            if (!exists) {
              await prepareWorkerExport(filename, prepared.uid);
              const exported = await run(prepared.root, ["fossil", "export", "/workspace/" + path.basename(directory) + "/actor.fossil", "--json"], signal);
              if (exported.code !== 0) fail("WorkerArchiveExportFailed");
            }
            await fs.chown(directory, 0, 0);
            const archive = createArchiveHttpControl(evaluation);
            try {
              const receipt = await retainWorkerArchive({ filename, uid: prepared.uid, source: { workspace: local.workspace_id, task: selected.id, revision: head.data.revision }, view: binding.view, execution: { runtime: saved.runtime, generation: saved.generation }, control: { call: (request, signal) => archive.call({ ...request, version: "omos.company-retired-archive-write/v1" }, signal) }, signal });
              retained = receipt.complete === true;
            } finally { archive.close(); }
          }
        } finally {
          await image({ ...request, action: "quiesce" });
          if (retained) await image({ ...request, action: "remove" });
        }
        if (retained) retirementAttempts.delete(saved.image);
        return retained;
      } finally {
        const pending = retirementAttempts.get(saved.image);
        if (pending) pending.next = Date.now() + Math.min(300000, 1000 * 2 ** (attempt - 1));
      }
    },
    async describe(signal) {
      const client = await createCompanyClient(companyConfiguration, { home: companyHome });
      try {
        const checked = await client.call("company_workspace", { version: "omos.company/v1", action: "status", operation: randomUUID(), expires_ms: Date.now() + 120000 }, signal);
        if (checked.isError) fail("WorkerCompanyIdentityChanged");
        const context = await client.call("company_context", {}, signal);
        if (context.isError || !JSON.parse(context.content[0].text).company.features.actor_archives || !JSON.parse(context.content[0].text).company.features.worker_checkpoints) fail("WorkerArchiveContractRequired");
        identity = structuredClone(client.identity);
        continuationSupported = JSON.parse(context.content[0].text).company.features.worker_continuation === true;
        amendmentsSupported = JSON.parse(context.content[0].text).company.features.task_amendments === true;
        activitySupported = JSON.parse(context.content[0].text).company.features.actor_activity === true;
        inputSupported = JSON.parse(context.content[0].text).company.features.task_input === true;
        return { workspace: client.identity.workspace, package_sha256: environmentSha256, model_handle: model.handle, subjects: [{ actor: client.identity.actor, grant: client.identity.grant }], validation_handles: validation ? [validation.handle] : [], desired_state: Boolean(JSON.parse(context.content[0].text).company.features.desired_state) };
      } finally { client.close(); }
    },
    supports(row) {
      const binding = row?.record?.binding;
      return Boolean(identity && binding?.workspace === identity.workspace && binding.actor === identity.actor && binding.grant === identity.grant);
    },
    recoverQueued(row, signal) {
      return recoverQueuedWorkerAdmission(row, { configuration: companyConfiguration, home: companyHome }, signal);
    },
    async recover(row, signal) {
      const job = row.record, binding = job.binding;
      if (!row.authority_live || job.state !== "running" || !hex(binding.workspace) || !hex(binding.view) || !job.runtime || job.generation !== row.execution?.generation || row.execution?.runtime !== job.runtime || !/^[A-Za-z0-9_-]{1,128}$/.test(row.pending_operation) || !row.grant.actions.includes("reconcile")) fail("WorkerRecoveryRequired");
      // A new owner can reconcile a retained native operation, never replay
      // actor tools or provider effects. This client stays outside the image.
      const client = await createCompanyClient(companyConfiguration, { home: companyHome });
      try {
        if (client.identity.workspace !== binding.workspace || client.identity.actor !== binding.actor || client.identity.grant !== binding.grant) fail("WorkerCompanyIdentityChanged");
        const result = await client.call("company_workspace", { version: "omos.company/v1", action: "reconcile", view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, outcome: row.pending_operation, operation: randomUUID(), expires_ms: Math.min(job.expires_ms, Date.now() + 300000) }, signal);
        if (result.isError || JSON.parse(result.content[0].text).state !== "completed") {
          const error = new Error("WorkerRecoveryPending"); error.executionUncertain = true; throw error;
        }
      } finally { client.close(); }
    },
    async run(row, signal) {
      const job = row.record, binding = job.binding;
      if (!row.authority_live || job.state !== "running" || !hex(binding.workspace) || !hex(binding.view) || !hex(row.view_revision) || !job.runtime || job.generation !== row.execution?.generation || row.execution?.runtime !== job.runtime || row.pending_operation) fail("InvalidWorkerInvocation");
      const coding = row.basis?.capability === "coding_task";
      if (coding && (!validation || !evaluation)) return { outcome: "waiting", note: "Configure the operator's isolated coding checks before running this company task." };
      if (coding && validation.handle !== (row.basis.execution?.server?.validation_handle ?? "company-default")) return { outcome: "waiting", note: "The task requires another pinned validation configuration. Inspect the company execution policy before resuming." };
      if (coding && !(await trustedFile(validationConfiguration)).equals(validationBytes)) fail("WorkerHostFileChanged");
      const actions = ["discover", "read", "query", "checkpoint", "record", "submit", "status", "reconcile"].filter(action => row.grant.actions.includes(action));
      if (!["discover", "read", "checkpoint", "submit", "status"].every(action => actions.includes(action))) fail("WorkerGrantIncomplete");
      const deadline = Math.min(Date.now() + job.max_runtime_ms, job.expires_ms - 1000);
      const ownerControl = observedControl("worker", createWorkerHttpControl(evaluation), binding.view, job.generation);
      const saveCheckpoint = createWorkerCheckpointer({ control: ownerControl, view: binding.view, execution: { runtime: job.runtime, generation: job.generation } });
      const recovering = job.checkpoint && job.checkpoint.phase !== "retained";
      let checkpoint = recovering ? structuredClone(job.checkpoint) : { version: "omos.company-worker-checkpoint/v1", runtime: job.runtime, generation: job.generation, image: createHash("sha256").update(JSON.stringify([binding.workspace, binding.view, job.runtime, job.generation])).digest("hex"), source_revision: row.view_revision, model: model.handle, phase: "prepared", export_directory: null, ...(amendmentsSupported ? { company_contract: binding.contract_sha256 } : {}) };
      const request = { version: "omos.worker-image-request/v1", action: "prepare", id: checkpoint.image, workspace: binding.workspace, view: binding.view, generation: checkpoint.generation, max_runtime_ms: job.max_runtime_ms, model: checkpoint.model, source_revision: checkpoint.source_revision };
      const mark = async (phase, rest = {}) => { checkpoint = await saveCheckpoint({ ...checkpoint, ...rest, phase }); };
      if (!recovering && job.checkpoint) {
        const previous = job.checkpoint;
        let exists = false;
        try { await fs.lstat(path.join(configuration.root, previous.image.slice(0, 24))); exists = true; }
        catch (error) { if (error.code !== "ENOENT") throw error; }
        if (exists) {
          const retained = { ...request, id: previous.image, generation: previous.generation, source_revision: previous.source_revision, model: previous.model };
          await image({ ...retained, action: "quiesce" });
          await image({ ...retained, action: "remove" });
        }
      }
      if (!recovering) await mark("prepared");
      const prepared = await image(request, signal);
      if (prepared.workspace !== binding.workspace || prepared.view !== binding.view || prepared.generation !== checkpoint.generation || prepared.executable_sha256 !== configuration.executable_sha256 || path.dirname(prepared.root) !== configuration.root || !Number.isSafeInteger(prepared.uid)) fail("WorkerImageIdentityChanged");
      let client, actorClient, broker, complete = false, archiveRetained = false, unused = false, activityDelivered = false;
      const call = async (action, rest = {}) => {
        if (Date.now() >= deadline) fail("WorkerInvocationDeadline");
        const operation = randomUUID();
        const started = Date.now();
        progress({ event: "worker_company_operation", view: binding.view, generation: job.generation, action, operation, phase: "start" });
        try {
          const result = await client.call("company_workspace", { version: action === "read" ? "omos.company/v2" : "omos.company/v1", action, operation, expires_ms: Math.min(job.expires_ms, Date.now() + 300000), ...rest }, signal);
          if (result.isError) {
            let failure;
            try { failure = JSON.parse(result.content?.[0]?.text); } catch { failure = {}; }
            throw Object.assign(new Error("WorkerCompanyOutcomeUnresolved"), { companyOperation: { action, operation, error: failure?.error, transport: failure?.failure_code } });
          }
          return JSON.parse(result.content[0].text);
        } finally { progress({ event: "worker_company_operation", view: binding.view, generation: job.generation, action, operation, phase: "end", duration_ms: Date.now() - started, abort_reason: cancellation(signal) }); }
      };
      const invoke = async (text, session, replayOnly = false) => {
        const started = Date.now();
        progress({ event: "worker_native", view: binding.view, generation: job.generation, mode: replayOnly ? "history" : "actor", phase: "start" });
        if (!activitySupported) return run(prepared.root, ["ask", ...(session ? ["--resume-id", session] : []), "--json"], signal, text);
        if (Date.now() >= deadline) fail("WorkerInvocationDeadline");
        const control = observedControl("activity", createActivityHttpControl(evaluation), binding.view, job.generation);
        const inputControl = inputSupported ? createInputHttpControl(evaluation) : null;
        try {
          const result = await runWorkerNative({
            launch: async () => {
              await trustedFile(launcher, launcherSha256, 131072);
              if (!(await trustedFile(imageConfiguration)).equals(configurationBytes)) fail("WorkerHostFileChanged");
              return spawn("/usr/bin/python3", ["-I", launcher, prepared.root, "--", "ui-host", "--stdio"], { env: { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C" }, stdio: ["pipe", "pipe", "pipe"] });
            },
            control, inputControl, view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, prompt: text, session, replayOnly, signal, timeout: Math.max(1, Math.min(240000, deadline - Date.now())),
          });
          activityDelivered = true;
          return result;
        } finally { control.close(); inputControl?.close(); progress({ event: "worker_native", view: binding.view, generation: job.generation, mode: replayOnly ? "history" : "actor", phase: "end", duration_ms: Date.now() - started, abort_reason: cancellation(signal) }); }
      };
      const startBroker = async () => {
        if (broker) return;
        const actorActions = actions.filter(action => action !== "submit");
        actorClient = await createCompanyClient(companyConfiguration, { home: companyHome, binding: { view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, expiresMs: job.expires_ms, actions: actorActions } });
        broker = await createWorkerBroker({ socket: prepared.root + "/run/omos-broker.sock", socketMode: 0o666, expiresMs: job.expires_ms, model, companyClient: actorClient, company: { endpoint: JSON.parse((await trustedFile(companyConfiguration)).toString("utf8")).endpoint, workspace: binding.workspace, actor: binding.actor, grant: binding.grant, view: binding.view, source_revision: checkpoint.source_revision, source_generation: checkpoint.generation, actions: actorActions } });
      };
      try {
        client = await createCompanyClient(companyConfiguration, { home: companyHome, binding: { view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, expiresMs: job.expires_ms, actions } });
        if (client.identity.workspace !== binding.workspace || client.identity.actor !== binding.actor || client.identity.grant !== binding.grant) fail("WorkerCompanyIdentityChanged");
        if (recovering) await image({ ...request, action: "quiesce" });
        if (checkpoint.phase === "prepared") {
          await startBroker();
          const state = await call("status");
          if (state.publication) {
            unused = true;
            return { outcome: "completed", note: "The company task was already published before actor dispatch; the unused prepared image has no actor history." };
          }
          const prompt = `Complete the recorded company task within the current company_workspace MCP scope. The host pins your view and execution generation. Retrieve existing company inputs through company_workspace before editing them. Checkpoint company changes through that service. Local filesystem outputs are collected as proposals after this invocation stops; local reviews do not establish company acceptance. Return your final answer without submitting the company proposal; the host retains public evidence and owns that step. ${coding ? "The host runs isolated coding validation after this invocation." : ""} Read referenced host validation feedback with company_workspace action status, record_id and company_revision, using bounded offset/limit pages. Treat prior logs as evidence to inspect. Preserve completed effects and already satisfied criteria. Do not repeat uncertain external effects.\n${JSON.stringify({ request: row.request, amendments: row.amendments, contract: row.contract, basis: row.basis, company_revision: state.revision, authorised_paths: row.grant.paths, previous_invocation: { note: row.record.note, invocations: row.record.invocations, max_invocations: row.record.max_invocations } })}`;
          if (Buffer.byteLength(prompt) > 131072) fail("WorkerInvocationContextTooLarge");
          await mark("running", amendmentsSupported ? { company_contract: binding.contract_sha256 } : {});
          const actor = await invoke(prompt);
          // The launcher joins and kills descendants before returning. Actor
          // answers and private assessments never establish company acceptance.
          await image({ ...request, action: "quiesce" });
          signal?.throwIfAborted();
          if (actor.killed || ![0, 1].includes(actor.code)) fail("WorkerInvocationFailed");
          await mark("stopped");
        } else await mark("stopped");
        for (;;) {
          let current = await call("status");
          const frozen = !!current.publication || ["queued", "running"].includes(current.job?.state);
          const snapshot = await run(prepared.root, ["fossil", "status", "--json"], signal);
          if (snapshot.code !== 0) fail("WorkerSnapshotUnavailable");
          const local = JSON.parse(snapshot.stdout);
          if (!hex(local.workspace_id) || !hex(local.trunk_revision)) fail("WorkerSnapshotAmbiguous");
          const selected = selectWorkerRoot(local.tasks);
          if (!/^[0-9a-f]{64}$/.test(selected.id) || !hex(selected.model_basis?.definition_hash)) fail("WorkerSnapshotAmbiguous");
          const requestNative = async input => {
            progress({ event: "worker_private_request", view: binding.view, generation: job.generation, action: input.action });
            const filename = ".omos-host-read-" + randomUUID() + ".json";
            const output = path.join(prepared.root, "workspace", filename);
            const file = await fs.open(output, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
            try { await file.writeFile(JSON.stringify(input)); await file.chown(prepared.uid, prepared.uid); }
            finally { await file.close(); }
            try {
              const result = await run(prepared.root, ["fossil", "request", "/workspace/" + filename, "--json"], signal);
              if (result.code !== 0) fail("WorkerSnapshotUnavailable");
              return JSON.parse(result.stdout);
            } finally { await fs.unlink(output); }
          };
          const head = await requestNative({ version: "omos.workspace-api/v1", workspace: local.workspace_id, definition_hash: selected.model_basis.definition_hash, action: "head", task: selected.id });
          const claim = await requestNative({ version: "omos.workspace-api/v1", workspace: local.workspace_id, definition_hash: head.data.definition_hash, revision: head.data.revision, action: "candidate", task: selected.id });
          if (claim.revision !== head.data.revision || claim.data.task !== selected.id || claim.data.authority !== "actor_claim") fail("WorkerCandidateChanged");
          const exportDirectory = checkpoint.export_directory ? path.join(prepared.root, "workspace", checkpoint.export_directory) : await fs.mkdtemp(path.join(prepared.root, "workspace", ".omos-host-archive-"));
          if (!checkpoint.export_directory) await mark("stopped", { export_directory: path.basename(exportDirectory) });
          const directoryInfo = await fs.lstat(exportDirectory);
          if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink() || ![0, prepared.uid].includes(directoryInfo.uid)) fail("UnsafeWorkerArchiveDirectory");
          await fs.chown(exportDirectory, prepared.uid, prepared.uid);
          const exportPath = path.join(exportDirectory, "actor.fossil");
          let exists = false;
          try { await fs.lstat(exportPath); exists = true; } catch (error) { if (error.code !== "ENOENT") throw error; }
          if (!exists) await prepareWorkerExport(exportPath, prepared.uid);
          const exported = exists ? { code: 0 } : await run(prepared.root, ["fossil", "export", "/workspace/" + path.basename(exportDirectory) + "/actor.fossil", "--json"], signal);
          await image({ ...request, action: "quiesce" });
          if (exported.code !== 0) fail("WorkerArchiveExportFailed");
          await fs.chown(exportDirectory, 0, 0);
          const archive = observedControl("archive", createArchiveHttpControl(evaluation), binding.view, job.generation);
          let archiveReceipt;
          try {
            const retained = await retainWorkerArchive({ filename: exportPath, uid: prepared.uid, source: { workspace: local.workspace_id, task: selected.id, revision: head.data.revision }, view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, control: archive, signal });
            archiveRetained = retained.complete === true;
            archiveReceipt = retained;
          } finally { archive.close(); }
          const boundedAnswer = typeof claim.data.candidate === "string" && claim.data.candidate.trim() && Buffer.byteLength(claim.data.candidate) <= 32768;
          const priorInvocation = checkpoint.continuation?.invocation ?? 1;
          const amended = amendmentsSupported && checkpoint.company_contract !== binding.contract_sha256;
          const restartForAmendment = !frozen && amended && ["accepted", "publication_pending", "conflict"].includes(selected.state);
          if (restartForAmendment && !archiveRetained) fail("WorkerContinuationEvidenceRequired");
          if (!restartForAmendment && !frozen && (!boundedAnswer || amended) && continuationSupported && recovering && job.invocations > priorInvocation) {
            if (!archiveRetained || !hex(archiveReceipt?.archive_id) || !/^[A-Za-z0-9_-]{1,128}$/.test(selected.session)) fail("WorkerContinuationEvidenceRequired");
            if (checkpoint.model !== model.handle) fail("WorkerRecoveryModelChanged");
            const sessions = await run(prepared.root, ["sessions", "--all", "--json"], signal);
            if (sessions.code !== 0) fail("WorkerSessionUnavailable");
            const session = selectWorkerSession(JSON.parse(sessions.stdout).sessions, selected.session);
            await startBroker();
            await mark("running", { export_directory: null, continuation: { invocation: job.invocations, archive: archiveReceipt.archive_id, source: head.data.revision }, ...(amendmentsSupported ? { company_contract: binding.contract_sha256 } : {}) });
            archiveRetained = false;
            const continuationPrompt = "Continue the retained company task from its recorded history and checkpoint. Inspect prior effects and preserve completed work. Do not repeat uncertain external actions. Reconcile the retained work with the current company contract and scope below; return the retained task's final answer without submitting the company proposal.\n" + JSON.stringify({ request: row.request, amendments: row.amendments, contract: row.contract, basis: row.basis, company_revision: current.revision, authorised_paths: row.grant.paths, previous_invocation: { note: row.record.note, invocations: row.record.invocations, max_invocations: row.record.max_invocations } });
            if (Buffer.byteLength(continuationPrompt) > 131072) fail("WorkerInvocationContextTooLarge");
            const resumed = await invoke(continuationPrompt, session);
            await image({ ...request, action: "quiesce" });
            signal?.throwIfAborted();
            if (resumed.killed || ![0, 1].includes(resumed.code)) fail("WorkerInvocationFailed");
            await mark("stopped");
            continue;
          }
          if (activitySupported && recovering && !activityDelivered && boundedAnswer && !restartForAmendment) {
            const sessions = await run(prepared.root, ["sessions", "--all", "--json"], signal);
            if (sessions.code !== 0) fail("WorkerSessionUnavailable");
            const session = selectWorkerSession(JSON.parse(sessions.stdout).sessions, selected.session);
            await invoke("", session, true);
          }
          const reader = createWorkerSnapshot({ workspace: local.workspace_id, definitionHash: head.data.definition_hash, revision: head.data.revision, request: input => requestNative({ ...input, task: selected.id }), maxFileBytes: 8 * 1024 * 1024, maxBytes: 64 * 1024 * 1024 });
          const inventory = await reader.inventory(signal);
          const provenance = createWorkerSnapshot({ workspace: local.workspace_id, definitionHash: head.data.definition_hash, revision: head.data.revision, request: input => requestNative({ ...input, task: selected.id }), roots: ["records/omos_worker_projection/"], maxFiles: 1, maxFileBytes: 8 * 1024 * 1024, maxBytes: 8 * 1024 * 1024 });
          const provenanceFiles = await provenance.inventory(signal), baseline = new Map();
          if (provenanceFiles.length) {
            const name = `records/omos_worker_projection/${selected.id}.json`;
            if (provenanceFiles[0].path !== name) fail("WorkerProjectionIdentityChanged");
            const ledger = JSON.parse((await provenance.read(name, signal)).content.toString("utf8"));
            if (ledger.version !== "omos.worker-projection/v1" || ledger.task !== selected.id || ledger.source?.version !== "omos.worker-source/v1" || ledger.source.workspace !== binding.workspace || ledger.source.view !== binding.view || ledger.source.revision !== checkpoint.source_revision || ledger.source.generation !== checkpoint.generation || !Array.isArray(ledger.files) || ledger.files.length > 10000) fail("WorkerProjectionIdentityChanged");
            let total = 0;
            for (const file of ledger.files) {
              if (!file || typeof file.path !== "string" || !/^(memory|skills|documents|artifacts|ui)\//.test(file.path) || !file.path.split("/").every(part => part && part !== "." && part !== "..") || /[\x00-\x1f\x7f\\]/.test(file.path) || baseline.has(file.path) || !hex(file.sha256) || !Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > 8 * 1024 * 1024 || (total += file.bytes) > 64 * 1024 * 1024 || typeof file.executable !== "boolean" || !row.grant.paths.some(scope => scope.endsWith("/") ? file.path.startsWith(scope) : file.path === scope)) fail("InvalidWorkerProjectionLedger");
              baseline.set(file.path, file);
            }
          }
          const originalFile = async (filename, previous) => {
            const original = await call("read", { revision: checkpoint.source_revision, path: filename, offset: 0 });
            const observed = baseline.get(filename);
            if (observed && (original.exists === false || original.sha256 !== observed.sha256 || original.bytes !== observed.bytes || original.executable !== observed.executable)) fail("WorkerProjectionSourceChanged");
            if (previous.exists !== false && (original.exists === false || previous.sha256 !== original.sha256 || previous.executable !== original.executable)) fail("WorkerCompanyOutputConflict");
            return original;
          };
          for (const file of inventory) {
            if (!row.grant.paths.some(scope => scope.endsWith("/") ? file.path.startsWith(scope) : file.path === scope)) fail("WorkerOutputOutsideScope");
            const bytes = await reader.read(file.path, signal);
            const observed = baseline.get(file.path);
            if (observed?.sha256 === bytes.sha256 && observed.executable === file.executable) continue;
            const previous = await call("read", { revision: current.revision, path: file.path, offset: 0 });
            if (previous.exists !== false && previous.sha256 === bytes.sha256 && previous.executable === file.executable) continue;
            if (frozen) return { outcome: current.publication ? "completed" : "submitted", note: "Additional private files remain retained in the worker image after the company candidate was frozen." };
            const original = await originalFile(file.path, previous);
            const mutation = { revision: current.revision, path: file.path, encoding: "base64", content: bytes.content.toString("base64"), executable: file.executable };
            if (original.exists !== false) { mutation.previous_hash = original.sha256; mutation.previous_executable = original.executable; }
            let checkpoint;
            if (bytes.bytes <= 512 * 1024) checkpoint = await call("checkpoint", mutation);
            else {
              const upload = { sha256: bytes.sha256, bytes: bytes.bytes };
              const metadata = { ...mutation, upload }; delete metadata.content;
              for (let offset = 0; offset < bytes.bytes; offset += 128 * 1024) {
                const part = await call("checkpoint", { ...metadata, offset, content: bytes.content.subarray(offset, offset + 128 * 1024).toString("base64") });
                if (part.state !== "uploading" || part.revision !== current.revision || part.offset !== offset) fail("WorkerCompanyUploadChanged");
              }
              checkpoint = await call("checkpoint", metadata);
            }
            current = { ...current, revision: checkpoint.revision };
          }
          const remaining = new Set(inventory.map(file => file.path));
          for (const filename of baseline.keys()) {
            if (remaining.has(filename)) continue;
            const previous = await call("read", { revision: current.revision, path: filename, offset: 0 });
            if (previous.exists === false) continue;
            if (frozen) return { outcome: current.publication ? "completed" : "submitted", note: "A proposed deletion remains in the retained worker image after submission." };
            const original = await originalFile(filename, previous);
            const checkpoint = await call("checkpoint", { revision: current.revision, path: filename, remove: true, previous_hash: original.sha256, previous_executable: original.executable });
            current = { ...current, revision: checkpoint.revision };
          }
          if (frozen) { complete = true; return { outcome: current.publication ? "completed" : "submitted" }; }
          if (restartForAmendment) {
            // Retain every proposed file before the fresh image projects this
            // updated company revision. The old answer cannot be submitted.
            await mark("retained");
            return { restartForAmendment: true, checkpoint: structuredClone(checkpoint), revision: current.revision };
          }
          if (typeof claim.data.candidate !== "string" || !claim.data.candidate.trim() || Buffer.byteLength(claim.data.candidate) > 32768) return { outcome: "waiting", note: "Public history is archived, but the private task has no bounded recorded answer. Requeue to continue its retained native session within the remaining invocation budget; an older declaration requires the worker continuation contract." };
          if (coding) {
            const control = createEvaluationHttpControl(evaluation);
            let checked;
            try { checked = await runCompanyValidation({ configuration: validation, configurationSha256: validationSha256, environmentSha256, control, client, row, revision: current.revision, candidate: claim.data.candidate, image, run, signal }); }
            finally { control.close(); }
            if (!checked.passed) {
              await mark("retained");
              const failed = checked.feedback.checks[0];
              const reference = `record_id=${checked.record_id}; evidence=${checked.evidence};`;
              const details = failed ? ` check=${failed.id}; exit=${failed.exit_code}; ${failed.stderr || failed.stdout}` : " Inspect incomplete validation evidence.";
              return { outcome: "waiting", note: "The company host retained failed coding checks. " + reference + Buffer.from(details).subarray(0, 300).toString("utf8") };
            }
            current = { ...current, revision: checked.revision };
          }
          await call("submit", { revision: current.revision, candidate: claim.data.candidate });
          complete = true;
          return { outcome: "submitted", note: "Company changes are checkpointed and queued for independent host review." };
        }
      } finally {
        progress({ event: "worker_cleanup", view: binding.view, generation: job.generation, phase: "broker", abort_reason: cancellation(signal) });
        if (broker) await broker.close();
        if (actorClient && actorClient !== client) actorClient.close();
        if (client) client.close();
        // Publication can finish while the signed submit acknowledgement is
        // still being read. Cleanup may use the owner's canonical receipt,
        // but only after this exact image's public archive was acknowledged.
        if (!complete && archiveRetained) {
          try {
            const current = await ownerControl.call({ change: "inspect", view: binding.view });
            const row = current.ok && current.jobs.length === 1 ? current.jobs[0] : null;
            complete = row?.record?.binding?.task === binding.task && row.task_state === "accepted" && Boolean(row.publication);
          } catch {
            // An unavailable receipt retains the image. Quiescence still runs.
          }
        }
        ownerControl.close();
        // Retain an unsuccessful image, including its private Fossil checkpoint,
        // for operator recovery. It consumes the bounded pool until resolved.
        try {
          await image({ ...request, action: "quiesce" });
          if (complete && !archiveRetained) fail("WorkerArchiveRetentionPending");
          if (complete || unused) await image({ ...request, action: "remove" });
        } catch {
          const error = new Error("WorkerCleanupPending"); error.executionUncertain = true;
          throw error;
        }
        progress({ event: "worker_cleanup", view: binding.view, generation: job.generation, phase: "joined", abort_reason: cancellation(signal) });
      }
    },
  };
  return Object.freeze({ ...backend, async run(row, signal) {
    let current = row;
    for (let pass = 0; pass < 2; pass++) {
      const outcome = await backend.run(current, signal);
      if (!outcome?.restartForAmendment) return outcome;
      signal?.throwIfAborted();
      // The old public history was acknowledged before its checkpoint became
      // retained. The next image uses the same company claim and remaining
      // coordinator deadline, and starts one actor against the amended contract.
      current = { ...current, view_revision: outcome.revision, record: { ...current.record, checkpoint: outcome.checkpoint } };
    }
    fail("WorkerAmendmentRestartFailed");
  } });
}
