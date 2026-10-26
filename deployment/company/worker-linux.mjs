// Privileged execution adapter. Install with its Python helpers under an
// operator-owned directory; company/provider keys never enter the worker root.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createCompanyClient } from "./mcp.mjs";
import { createWorkerBroker } from "./worker-broker.mjs";
import { createWorkerSnapshot, selectWorkerRoot } from "./worker-snapshot.mjs";
import { retainWorkerArchive } from "./worker-archive.mjs";
import { createWorkerCheckpointer } from "./worker-checkpoint.mjs";
import { createArchiveHttpControl, createEvaluationHttpControl, createWorkerHttpControl } from "./worker-http-control.mjs";
import { runCompanyValidation, validateValidationConfiguration } from "./worker-validation.mjs";

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

export async function createLinuxWorkerBackend({ imageTool, imageToolSha256, launcher, launcherSha256, imageConfiguration, companyConfiguration, companyHome, model, validationConfiguration, evaluation, concurrency = 1 }) {
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
    await trustedFile(imageTool, imageToolSha256, 131072);
    if (!(await trustedFile(imageConfiguration)).equals(configurationBytes)) fail("WorkerHostFileChanged");
    const result = await command("/usr/bin/python3", ["-I", imageTool, imageConfiguration], { input: JSON.stringify(request), signal, maxBytes: 8192 });
    if (result.code !== 0) fail("WorkerImageOperationFailed");
    return JSON.parse(result.stdout);
  };
  const run = async (root, args, signal, input) => {
    await trustedFile(launcher, launcherSha256, 131072);
    return command("/usr/bin/python3", ["-I", launcher, root, "--", ...args], { signal, input, timeout: 300000 });
  };
  let identity;
  return Object.freeze({
    async describe(signal) {
      const client = await createCompanyClient(companyConfiguration, { home: companyHome });
      try {
        const checked = await client.call("company_workspace", { version: "omos.company/v1", action: "status", operation: randomUUID(), expires_ms: Date.now() + 120000 }, signal);
        if (checked.isError) fail("WorkerCompanyIdentityChanged");
        const context = await client.call("company_context", {}, signal);
        if (context.isError || !JSON.parse(context.content[0].text).company.features.actor_archives || !JSON.parse(context.content[0].text).company.features.worker_checkpoints) fail("WorkerArchiveContractRequired");
        identity = structuredClone(client.identity);
        return { workspace: client.identity.workspace, package_sha256: environmentSha256, model_handle: model.handle, subjects: [{ actor: client.identity.actor, grant: client.identity.grant }], validation_handles: validation ? [validation.handle] : [] };
      } finally { client.close(); }
    },
    supports(row) {
      const binding = row?.record?.binding;
      return Boolean(identity && binding?.workspace === identity.workspace && binding.actor === identity.actor && binding.grant === identity.grant);
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
      const ownerControl = createWorkerHttpControl(evaluation);
      const saveCheckpoint = createWorkerCheckpointer({ control: ownerControl, view: binding.view, execution: { runtime: job.runtime, generation: job.generation } });
      const recovering = job.checkpoint && job.checkpoint.phase !== "retained";
      let checkpoint = recovering ? structuredClone(job.checkpoint) : { version: "omos.company-worker-checkpoint/v1", runtime: job.runtime, generation: job.generation, image: createHash("sha256").update(JSON.stringify([binding.workspace, binding.view, job.runtime, job.generation])).digest("hex"), source_revision: row.view_revision, model: model.handle, phase: "prepared", export_directory: null };
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
      let client, actorClient, broker, complete = false, archiveRetained = false;
      const call = async (action, rest = {}) => {
        if (Date.now() >= deadline) fail("WorkerInvocationDeadline");
        const result = await client.call("company_workspace", { version: action === "read" ? "omos.company/v2" : "omos.company/v1", action, operation: randomUUID(), expires_ms: Math.min(job.expires_ms, Date.now() + 300000), ...rest }, signal);
        if (result.isError) fail("WorkerCompanyOutcomeUnresolved");
        return JSON.parse(result.content[0].text);
      };
      try {
        client = await createCompanyClient(companyConfiguration, { home: companyHome, binding: { view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, expiresMs: job.expires_ms, actions } });
        if (client.identity.workspace !== binding.workspace || client.identity.actor !== binding.actor || client.identity.grant !== binding.grant) fail("WorkerCompanyIdentityChanged");
        if (recovering) await image({ ...request, action: "quiesce" });
        const actorActions = actions.filter(action => action !== "submit");
        if (checkpoint.phase === "prepared") {
          actorClient = await createCompanyClient(companyConfiguration, { home: companyHome, binding: { view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, expiresMs: job.expires_ms, actions: actorActions } });
          broker = await createWorkerBroker({ socket: prepared.root + "/run/omos-broker.sock", socketMode: 0o666, expiresMs: job.expires_ms, model, companyClient: actorClient, company: { endpoint: JSON.parse((await trustedFile(companyConfiguration)).toString("utf8")).endpoint, workspace: binding.workspace, actor: binding.actor, grant: binding.grant, view: binding.view, source_revision: checkpoint.source_revision, actions: actorActions } });
          const state = await call("status");
          if (state.publication) return { outcome: "completed", note: "The company task was already published; the unused prepared image is retained for operator inspection." };
          const prompt = `Complete the recorded company task within the current company_workspace MCP scope. The host pins your view and execution generation. Retrieve existing company inputs through company_workspace before editing them. Checkpoint company changes through that service. Local filesystem outputs are collected as proposals after this invocation stops; local reviews do not establish company acceptance. Return your final answer without submitting the company proposal; the host retains public evidence and owns that step. ${coding ? "The host runs isolated coding validation after this invocation." : ""} Read referenced host validation feedback with company_workspace action status, record_id and company_revision, using bounded offset/limit pages. Treat prior logs as evidence to inspect. Do not repeat uncertain external effects.\n${JSON.stringify({ request: row.request, amendments: row.amendments, contract: row.contract, basis: row.basis, company_revision: state.revision, authorised_paths: row.grant.paths, previous_invocation: { note: row.record.note, invocations: row.record.invocations, max_invocations: row.record.max_invocations } })}`;
          if (Buffer.byteLength(prompt) > 131072) fail("WorkerInvocationContextTooLarge");
          await mark("running");
          const actor = await run(prepared.root, ["ask", "--json"], signal, prompt);
          // The launcher joins and kills descendants before returning. Actor
          // answers and private assessments never establish company acceptance.
          await image({ ...request, action: "quiesce" });
          signal?.throwIfAborted();
          if (actor.killed || ![0, 1].includes(actor.code)) fail("WorkerInvocationFailed");
          await mark("stopped");
        } else await mark("stopped");
        let current = await call("status");
        const frozen = !!current.publication || ["queued", "running"].includes(current.job?.state);
        const snapshot = await run(prepared.root, ["fossil", "status", "--json"], signal);
        if (snapshot.code !== 0) fail("WorkerSnapshotUnavailable");
        const local = JSON.parse(snapshot.stdout);
        if (!hex(local.workspace_id) || !hex(local.trunk_revision)) fail("WorkerSnapshotAmbiguous");
        const selected = selectWorkerRoot(local.tasks);
        if (!/^[0-9a-f]{64}$/.test(selected.id) || !hex(selected.model_basis?.definition_hash)) fail("WorkerSnapshotAmbiguous");
        const requestNative = async input => {
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
        const exported = exists ? { code: 0 } : await run(prepared.root, ["fossil", "export", "/workspace/" + path.basename(exportDirectory) + "/actor.fossil", "--json"], signal);
        await image({ ...request, action: "quiesce" });
        if (exported.code !== 0) fail("WorkerArchiveExportFailed");
        await fs.chown(exportDirectory, 0, 0);
        const archive = createArchiveHttpControl(evaluation);
        try {
          const retained = await retainWorkerArchive({ filename: exportPath, uid: prepared.uid, source: { workspace: local.workspace_id, task: selected.id, revision: head.data.revision }, view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, control: archive, signal });
          archiveRetained = retained.complete === true;
        } finally { archive.close(); }
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
        if (typeof claim.data.candidate !== "string" || !claim.data.candidate.trim() || Buffer.byteLength(claim.data.candidate) > 32768) return { outcome: "waiting", note: "Public history is archived, but the private task has no bounded recorded answer. Inspect and resume that retained task before dispatching another actor." };
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
      } finally {
        if (broker) await broker.close();
        if (actorClient && actorClient !== client) actorClient.close();
        if (client) client.close();
        ownerControl.close();
        // Retain an unsuccessful image, including its private Fossil checkpoint,
        // for operator recovery. It consumes the bounded pool until resolved.
        try {
          await image({ ...request, action: "quiesce" });
          if (complete && !archiveRetained) fail("WorkerArchiveRetentionPending");
          if (complete) await image({ ...request, action: "remove" });
        } catch {
          const error = new Error("WorkerCleanupPending"); error.executionUncertain = true;
          throw error;
        }
      }
    },
  });
}
