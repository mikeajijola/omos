// Private operator transport. Durable state and authority remain in the native
// company service; temporary request files are disposable transport buffers.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";

const fail = code => { throw new Error(code); };
const hex = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const fingerprint = info => [info.dev, info.ino, info.size, info.mode, info.uid, info.mtimeNs, info.ctimeNs].map(String).join(":");
async function privateDirectory(directory) {
  const actual = await fs.realpath(directory);
  if (actual !== directory) fail("UnsafeWorkerControlDirectory");
  const info = await fs.lstat(directory);
  if (!info.isDirectory() || info.uid !== process.getuid?.() || (info.mode & 0o077)) fail("UnsafeWorkerControlDirectory");
}
async function executable(binary, expected) {
  if (!path.isAbsolute(binary) || !hex(expected)) fail("InvalidWorkerControlExecutable");
  const selected = await fs.realpath(binary);
  const file = await fs.open(selected, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const before = await file.stat({ bigint: true });
    if (!before.isFile() || ![0n, BigInt(process.getuid?.() ?? -1)].includes(before.uid) || (before.mode & 0o6022n) || !(before.mode & 0o111n) || before.size > 512n * 1024n * 1024n) fail("UnsafeWorkerControlExecutable");
    const hash = createHash("sha256");
    const chunk = Buffer.alloc(65536);
    for (;;) {
      const { bytesRead } = await file.read(chunk, 0, chunk.length, null);
      if (!bytesRead) break;
      hash.update(chunk.subarray(0, bytesRead));
    }
    const after = await file.stat({ bigint: true });
    if (fingerprint(before) !== fingerprint(after) || hash.digest("hex") !== expected) fail("WorkerControlExecutableChanged");
    return { path: selected, fingerprint: fingerprint(after) };
  } finally { await file.close(); }
}

export async function createWorkerControl({ binary, executableSha256, home, workspace, workspaceId }) {
  if (!hex(workspaceId) || typeof home !== "string" || !path.isAbsolute(home) || typeof workspace !== "string" || !path.isAbsolute(workspace)) fail("InvalidWorkerControl");
  await privateDirectory(home);
  const program = await executable(binary, executableSha256);
  const root = path.join(home, ".fx", "worker-control");
  await fs.mkdir(root, { recursive: true, mode: 0o700 });
  await privateDirectory(root);
  const bindingPath = path.join(home, ".fx", "omos-workspace.json");
  const pinned = JSON.parse(await fs.readFile(bindingPath, "utf8"));
  if (pinned.workspace_id !== workspaceId || typeof pinned.repository !== "string" || !path.isAbsolute(pinned.repository)) fail("WorkerControlBindingChanged");
  const repository = await fs.realpath(pinned.repository);
  const repositoryInfo = await fs.lstat(repository, { bigint: true });
  if (!repositoryInfo.isFile()) fail("WorkerControlBindingChanged");
  const active = new Set();
  let closed = false;
  return Object.freeze({
    async call(request, signal) {
      if (closed) fail("WorkerControlClosed");
      if (active.size >= 4) fail("WorkerControlBusy");
      if (!request || typeof request !== "object" || Array.isArray(request)) fail("InvalidWorkerControlRequest");
      const bytes = JSON.stringify({ version: "omos.company-admin/v1", action: "workers", worker: structuredClone(request) });
      if (Buffer.byteLength(bytes) > 65536) fail("WorkerControlRequestTooLarge");
      const controller = new AbortController();
      active.add(controller);
      let directory;
      try {
        await privateDirectory(root);
        const binding = JSON.parse(await fs.readFile(bindingPath, "utf8"));
        if (binding.workspace_id !== workspaceId || binding.repository !== pinned.repository || await fs.realpath(binding.repository) !== repository) fail("WorkerControlBindingChanged");
        const currentRepository = await fs.lstat(repository, { bigint: true });
        if (!currentRepository.isFile() || currentRepository.dev !== repositoryInfo.dev || currentRepository.ino !== repositoryInfo.ino) fail("WorkerControlBindingChanged");
        if (fingerprint(await fs.stat(program.path, { bigint: true })) !== program.fingerprint) fail("WorkerControlExecutableChanged");
        directory = await fs.mkdtemp(path.join(root, "request-"));
        const input = path.join(directory, "request.json");
        await fs.writeFile(input, bytes, { mode: 0o600, flag: "wx" });
        const env = { HOME: home, PATH: process.env.PATH ?? "/usr/bin:/bin", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_CONTRACT_REVIEW: "1" };
        const bounded = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
        const result = await new Promise(resolve => {
          execFile(program.path, ["fossil", "company", input, "--json"], { cwd: workspace, env, timeout: 30000, maxBuffer: 8 * 1024 * 1024, signal: bounded }, (error, stdout, stderr) => resolve({ error, stdout, stderr }));
        });
        if (result.error) {
          const code = result.stderr?.match(/^fx: ([A-Z][A-Za-z0-9]{0,95})\s*$/m)?.[1] ?? "WorkerControlOutcomeUnknown";
          // Even an interrupted commit may already be durable. The coordinator
          // must inspect its operation before dispatching an actor or retrying.
          return { ok: false, error: code, uncertain: request.change !== "inspect", operation: request.operation ?? null };
        }
        let value;
        try { value = JSON.parse(result.stdout).model_data; }
        catch { return { ok: false, error: "WorkerControlOutcomeUnknown", uncertain: request.change !== "inspect", operation: request.operation ?? null }; }
        if (!value || !Array.isArray(value.jobs) || value.jobs.length > 32 || value.jobs.some(row => row.record?.binding?.workspace !== workspaceId)) fail("WorkerControlBindingChanged");
        return { ok: true, ...value };
      } finally {
        active.delete(controller);
        if (directory) await fs.rm(directory, { recursive: true, force: true });
      }
    },
    close() {
      closed = true;
      for (const controller of active) controller.abort();
    },
  });
}
