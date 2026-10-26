// Runs operator-selected checks in a separate image over immutable input files.
// This module stays outside the actor and holds no durable task database.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";

const fail = code => { throw new Error(code); };
const hex = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const fields = (value, names) => value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).every(key => names.includes(key));
const safePath = value => typeof value === "string" && value.length <= 4096 && !/[\x00-\x1f\x7f\\]/.test(value) && value.split("/").every(part => part && part !== "." && part !== "..");
function boundedText(value) {
  const bytes = Buffer.from(value);
  let end = Math.min(bytes.length, 8192);
  while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
  return { text: bytes.subarray(0, end).toString("utf8"), complete: end === bytes.length };
}

async function sourceUnchanged(root, files) {
  for (const item of files) {
    let current = root;
    for (const part of item.path.split("/").slice(0, -1)) {
      current = path.join(current, part);
      const info = await fs.lstat(current);
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o022)) return false;
    }
    const file = await fs.open(path.join(root, item.path), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = await file.stat();
      if (!info.isFile() || info.uid !== 0 || info.size > 8 * 1024 * 1024 || (info.mode & 0o222) || !!(info.mode & 0o111) !== item.executable || createHash(item.artifact.length === 40 ? "sha1" : "sha3-256").update(await file.readFile()).digest("hex") !== item.artifact) return false;
    } finally { await file.close(); }
  }
  return true;
}

export function validateValidationConfiguration(value) {
  if (!fields(value, ["version", "handle", "entry", "checks"]) || value.version !== "omos.worker-validation/v1" || typeof value.handle !== "string" || !/^[A-Za-z0-9_.-]{1,128}$/.test(value.handle) || !fields(value.entry, ["path", "sha256"]) || value.entry.path !== "/bin/bash" || !hex(value.entry.sha256) || !Array.isArray(value.checks) || value.checks.length < 1 || value.checks.length > 16) fail("InvalidWorkerValidationConfiguration");
  const ids = new Set();
  for (const check of value.checks) {
    if (!fields(check, ["id", "arguments", "cwd", "timeout_ms"]) || typeof check.id !== "string" || !/^[A-Za-z0-9_.-]{1,128}$/.test(check.id) || ids.has(check.id) || !safePath(check.cwd) || !Number.isSafeInteger(check.timeout_ms) || check.timeout_ms < 1000 || check.timeout_ms > 120000 || !Array.isArray(check.arguments) || check.arguments.length < 1 || check.arguments.length > 64 || check.arguments.some(argument => typeof argument !== "string" || Buffer.byteLength(argument) > 8192 || argument.includes("\0")) || !/^\/(runtime\/bin|usr\/bin|bin)\//.test(check.arguments[0])) fail("InvalidWorkerValidationConfiguration");
    ids.add(check.id);
  }
  return structuredClone(value);
}

async function sourceFile(root, relative, data, executable) {
  const parts = relative.split("/"); let current = root;
  for (const part of parts.slice(0, -1)) {
    current = path.join(current, part);
    await fs.mkdir(current, { mode: 0o755 }).catch(error => { if (error.code !== "EEXIST") throw error; });
    const info = await fs.lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o022)) fail("UnsafeValidationSource");
    await fs.chmod(current, 0o755);
  }
  const filename = path.join(root, relative);
  const output = await fs.open(filename, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, executable ? 0o555 : 0o444);
  try { await output.writeFile(data); await output.chmod(executable ? 0o555 : 0o444); }
  finally { await output.close(); }
}

async function readResult(filename) {
  let file;
  try { file = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  try {
    const info = await file.stat();
    if (!info.isFile() || info.uid !== 0 || info.nlink !== 1 || (info.mode & 0o777) !== 0o600 || info.size > 256 * 1024) fail("UnsafeValidationResult");
    return JSON.parse(await file.readFile("utf8"));
  } finally { await file.close(); }
}

export async function runCompanyValidation({ configuration, configurationSha256, environmentSha256, control, client, row, revision, candidate, image, run, signal }) {
  const config = validateValidationConfiguration(configuration);
  const job = row.record, binding = job.binding;
  if (typeof candidate !== "string" || !candidate.trim() || Buffer.byteLength(candidate) > 32768) fail("InvalidWorkerValidationCandidate");
  const retained = await control.call({ version: "omos.company-evaluation/v1", action: "candidate", view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, revision, operation: randomUUID(), candidate }, signal);
  if (!retained.ok || retained.version !== "omos.company-candidate-outcome/v1" || retained.task !== binding.task || retained.authority !== "actor_claim" || retained.candidate_sha256 !== createHash("sha256").update(candidate).digest("hex")) fail("WorkerCandidateRetentionPending");
  revision = retained.revision;
  const base = { version: "omos.company-evaluation/v1", view: binding.view, execution: { runtime: job.runtime, generation: job.generation }, revision };
  const prepare = async offset => {
    const reply = await control.call({ ...base, action: "prepare", offset }, signal);
    if (!reply.ok || reply.workspace && reply.workspace !== binding.workspace || reply.task !== binding.task || reply.revision !== revision || !hex(reply.source_sha256) || reply.configuration_handle !== config.handle || !Array.isArray(reply.files) || reply.files.length > 32 || !Number.isSafeInteger(reply.total) || reply.total < 0 || reply.total > 10000) fail("WorkerValidationInputChanged");
    return reply;
  };
  const first = await prepare(0), files = [], seen = new Set();
  let page = first, offset = 0;
  for (;;) {
    for (const file of page.files) {
      if (!file || !safePath(file.path) || !/^(memory|skills|documents|artifacts|ui|records)\//.test(file.path) || file.path.startsWith("records/omos_") || seen.has(file.path) || typeof file.executable !== "boolean" || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(file.artifact) || !row.grant.paths.some(scope => scope.endsWith("/") ? file.path.startsWith(scope) : file.path === scope)) fail("InvalidWorkerValidationInput");
      seen.add(file.path); files.push(file);
    }
    if (page.next_offset === null) break;
    if (!Number.isSafeInteger(page.next_offset) || page.next_offset !== offset + page.files.length || !page.files.length || page.next_offset <= offset) fail("InvalidWorkerValidationCursor");
    offset = page.next_offset; page = await prepare(offset);
    if (page.source_sha256 !== first.source_sha256 || page.total !== first.total) fail("WorkerValidationInputChanged");
  }
  if (files.length !== first.total) fail("IncompleteWorkerValidationInput");
  const request = { version: "omos.worker-image-request/v1", action: "prepare", id: createHash("sha256").update(JSON.stringify(["validation", binding.workspace, binding.view, job.runtime, job.generation, first.source_sha256, configurationSha256, environmentSha256])).digest("hex"), workspace: binding.workspace, view: binding.view, generation: job.generation, max_runtime_ms: job.max_runtime_ms, model: "validation-disabled", entry: config.entry };
  const prepared = await image(request, signal);
  if (prepared.workspace !== binding.workspace || prepared.view !== binding.view || prepared.generation !== job.generation || prepared.executable !== config.entry.path || prepared.executable_sha256 !== config.entry.sha256) fail("WorkerValidationImageChanged");
  const marker = path.join(prepared.root, ".omos-validation-result.json");
  let result = await readResult(marker), receiptRetained = false;
  try {
    if (!result) {
      const root = path.join(prepared.root, "runtime/validation-source");
      await fs.mkdir(root, { mode: 0o755 });
      await fs.chmod(root, 0o755);
      let total = 0;
      for (const file of files) {
        const chunks = []; let position = 0, bytes, digest;
        for (;;) {
          signal?.throwIfAborted();
          const response = await client.call("company_workspace", { version: "omos.company/v2", action: "read", operation: randomUUID(), expires_ms: Math.min(job.expires_ms, Date.now() + 300000), revision, path: file.path, offset: position }, signal);
          if (response.isError) fail("WorkerValidationReadFailed");
          const value = JSON.parse(response.content[0].text);
          if (value.revision !== revision || value.path !== file.path || value.exists !== true || value.offset !== position || value.encoding !== "base64" || typeof value.content !== "string" || !hex(value.sha256) || !Number.isSafeInteger(value.bytes) || value.bytes < 0 || value.bytes > 8 * 1024 * 1024 || value.executable !== file.executable) fail("WorkerValidationInputChanged");
          if (bytes !== undefined && (bytes !== value.bytes || digest !== value.sha256)) fail("WorkerValidationInputChanged");
          bytes = value.bytes; digest = value.sha256;
          const chunk = Buffer.from(value.content, "base64");
          if (chunk.length > 16384 || chunk.toString("base64") !== value.content || position + chunk.length > bytes) fail("InvalidWorkerValidationPage");
          chunks.push(chunk); position += chunk.length;
          if (value.next_offset === null) { if (position !== bytes) fail("IncompleteWorkerValidationInput"); break; }
          if (value.next_offset !== position || !chunk.length) fail("InvalidWorkerValidationCursor");
        }
        if ((total += bytes) > 64 * 1024 * 1024) fail("WorkerValidationSourceBudget");
        const content = Buffer.concat(chunks, bytes);
        if (createHash("sha256").update(content).digest("hex") !== digest || createHash(file.artifact.length === 40 ? "sha1" : "sha3-256").update(content).digest("hex") !== file.artifact) fail("WorkerValidationInputCorrupt");
        await sourceFile(root, file.path, content, file.executable);
      }
      const checks = [];
      for (const check of config.checks) {
        const stop = new AbortController(), timer = setTimeout(() => stop.abort(new Error("WorkerValidationTimeout")), check.timeout_ms);
        let outcome;
        try { outcome = await run(prepared.root, ["--noprofile", "--norc", "-c", 'cd -- "$1" && shift && exec "$@"', "omos-validation", "/runtime/validation-source/" + check.cwd, ...check.arguments], signal ? AbortSignal.any([signal, stop.signal]) : stop.signal); }
        finally { clearTimeout(timer); }
        await image({ ...request, action: "quiesce" });
        const stdout = boundedText(outcome.stdout), stderr = boundedText(outcome.stderr);
        const unchanged = await sourceUnchanged(root, files);
        checks.push({ id: check.id, arguments: check.arguments, cwd: check.cwd, exit_code: Number.isInteger(outcome.code) ? outcome.code : 125, stdout: stdout.text, stderr: stderr.text, output_complete: !outcome.killed && outcome.output_complete !== false && stdout.complete && stderr.complete, source_unchanged: unchanged });
        if (!unchanged) break;
        if (outcome.killed) break;
      }
      signal?.throwIfAborted();
      result = { ...base, action: "record", operation: randomUUID(), source_sha256: first.source_sha256, configuration_handle: config.handle, configuration_sha256: configurationSha256, environment_sha256: environmentSha256, checks };
      const output = await fs.open(marker, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      try { await output.writeFile(JSON.stringify(result)); await output.sync(); }
      finally { await output.close(); }
    }
    if (result.source_sha256 !== first.source_sha256 || result.configuration_sha256 !== configurationSha256 || result.environment_sha256 !== environmentSha256 || result.view !== binding.view || result.execution?.runtime !== job.runtime || result.execution?.generation !== job.generation) fail("WorkerValidationResultChanged");
    const receipt = await control.call(result, signal);
    if (!receipt.ok) fail(receipt.uncertain ? "WorkerValidationOutcomeUnknown" : "WorkerValidationRejected");
    receiptRetained = true;
    return { ...receipt, feedback: { record_id: receipt.record_id, evidence: receipt.evidence, source: result.source_sha256, checks: result.checks.filter(check => check.exit_code !== 0 || !check.output_complete || !check.source_unchanged).map(check => ({ id: check.id, exit_code: check.exit_code, output_complete: check.output_complete, source_unchanged: check.source_unchanged, stdout: check.stdout.slice(0, 256), stderr: check.stderr.slice(0, 256) })) } };
  } finally {
    await image({ ...request, action: "quiesce" });
    if (receiptRetained) await image({ ...request, action: "remove" });
  }
}
