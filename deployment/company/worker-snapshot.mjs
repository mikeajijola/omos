// Read immutable worker content through the native read-only workspace API.
// Transport, execution ownership and company publication belong to the host.
import { createHash } from "node:crypto";

// Portable task records contain a fingerprint, not a private session ID. Only
// the owning runtime may resolve it against its local native session catalog.
export function selectWorkerSession(sessions, fingerprint) {
  if (!Array.isArray(sessions) || sessions.length > 10000 || !/^[0-9a-f]{64}$/.test(fingerprint)) throw new Error("WorkerSessionAmbiguous");
  const selected = sessions.filter(session => typeof session?.id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(session.id) && createHash("sha256").update(session.id).digest("hex") === fingerprint);
  if (selected.length !== 1) throw new Error("WorkerSessionAmbiguous");
  return selected[0].id;
}

// A delegated task shares its root's private repository. Independent roots and
// malformed ancestry remain ambiguous; a child does not hide its parent's work.
export function selectWorkerRoot(tasks) {
  if (!Array.isArray(tasks) || tasks.length === 0) throw new Error("WorkerSnapshotAmbiguous");
  const byId = new Map();
  for (const task of tasks) {
    if (!task || !/^[0-9a-f]{64}$/.test(task.id) || byId.has(task.id)) throw new Error("WorkerSnapshotAmbiguous");
    byId.set(task.id, task);
  }
  const roots = tasks.filter(task => task.parent_task_id == null);
  if (roots.length !== 1) throw new Error("WorkerSnapshotAmbiguous");
  const root = roots[0];
  for (const task of tasks) {
    const visited = new Set();
    let current = task;
    while (current !== root) {
      if (visited.has(current.id)) throw new Error("WorkerSnapshotAmbiguous");
      visited.add(current.id);
      current = byId.get(current.parent_task_id);
      if (!current) throw new Error("WorkerSnapshotAmbiguous");
    }
  }
  return root;
}

const fail = code => { throw new Error(code); };
const hash = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const artifact = value => typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value);
const contentRoots = ["memory/", "skills/", "documents/", "artifacts/", "ui/"];
const safePath = (value, roots) => typeof value === "string" && value.length <= 4096 && roots.some(root => value.startsWith(root)) && !/[\x00-\x1f\x7f\\]/.test(value) && value.split("/").every(part => part && part !== "." && part !== "..");

export function createWorkerSnapshot({ request, workspace, definitionHash, revision, maxFiles = 10000, maxFileBytes = 32 * 1024 * 1024, maxBytes = 256 * 1024 * 1024, roots = contentRoots }) {
  if (typeof request !== "function" || !hash(workspace) || !hash(definitionHash) || !hash(revision)) fail("InvalidWorkerSnapshot");
  if (![maxFiles, maxFileBytes, maxBytes].every(value => Number.isSafeInteger(value) && value > 0) || maxFiles > 10000 || maxFileBytes > 32 * 1024 * 1024 || maxBytes > 256 * 1024 * 1024) fail("InvalidWorkerSnapshotBudget");
  if (!Array.isArray(roots) || !roots.length || new Set(roots).size !== roots.length || roots.some(root => ![...contentRoots, "records/omos_worker_projection/"].includes(root))) fail("InvalidWorkerSnapshotRoots");
  roots = Object.freeze([...roots]);
  const envelope = { version: "omos.workspace-api/v1", workspace, definition_hash: definitionHash, revision };
  const selected = new Map();
  let inventory;
  let consumed = 0;
  let reading = false;
  const call = async (input, signal) => {
    signal?.throwIfAborted();
    const reply = await request({ ...envelope, ...input }, signal);
    signal?.throwIfAborted();
    if (!reply || reply.workspace !== workspace || reply.definition_hash !== definitionHash || !reply.data) fail("WorkerSnapshotIdentityChanged");
    // Inventory carries its immutable identity in data; older hosts expose the
    // live accepted revision in the outer envelope for this action.
    if (input.action === "inventory" ? reply.data.revision !== revision : reply.revision !== revision) fail("WorkerSnapshotRevisionChanged");
    return reply.data;
  };
  return Object.freeze({
    revision,
    async inventory(signal) {
      if (inventory) return structuredClone(inventory);
      if (reading) fail("WorkerSnapshotBusy");
      reading = true;
      try {
        const files = [];
        const seen = new Set();
        for (const root of roots) {
        let offset = 0, total;
        for (;;) {
          const page = await call({ action: "inventory", path: root, offset }, signal);
          if (!Number.isSafeInteger(page.total) || page.total < 0 || page.total > maxFiles || (total !== undefined && total !== page.total) || !Array.isArray(page.files) || page.files.length > 32 || page.files.length > page.total - offset) fail("InvalidWorkerSnapshotInventory");
          total = page.total;
          for (const file of page.files) {
            if (!file || !safePath(file.path, roots) || !file.path.startsWith(root) || !artifact(file.artifact) || typeof file.executable !== "boolean" || seen.has(file.path)) fail("InvalidWorkerSnapshotInventory");
            seen.add(file.path);
            if (files.length >= maxFiles) fail("WorkerSnapshotFileBudgetExceeded");
            files.push({ path: file.path, artifact: file.artifact, executable: file.executable });
          }
          offset += page.files.length;
          if (page.next_offset === null) {
            if (offset !== total) fail("IncompleteWorkerSnapshotInventory");
            break;
          }
          if (!page.files.length || page.next_offset !== offset || offset >= total) fail("InvalidWorkerSnapshotCursor");
        }
        }
        for (const file of files) selected.set(file.path, Object.freeze(file));
        inventory = files;
        return structuredClone(files);
      } finally { reading = false; }
    },
    async read(filename, signal) {
      if (!inventory) fail("WorkerSnapshotInventoryRequired");
      const file = selected.get(filename);
      if (!file) fail("WorkerSnapshotPathDenied");
      if (reading) fail("WorkerSnapshotBusy");
      reading = true;
      try {
        const pieces = [];
        const contentHash = createHash("sha256");
        const fossilHash = createHash(file.artifact.length === 40 ? "sha1" : "sha3-256");
        let offset = 0, total, expectedHash;
        for (;;) {
          const page = await call({ action: "read", path: filename, offset, limit: 16384 }, signal);
          if (page.path !== filename || page.offset !== offset || !Number.isSafeInteger(page.bytes) || page.bytes < 0 || page.bytes > maxFileBytes || page.bytes > maxBytes - consumed || !hash(page.sha256) || typeof page.content !== "string" || !["utf8", "base64"].includes(page.encoding)) fail("InvalidWorkerSnapshotPage");
          if (total !== undefined && (total !== page.bytes || expectedHash !== page.sha256)) fail("WorkerSnapshotContentChanged");
          total = page.bytes; expectedHash = page.sha256;
          const bytes = Buffer.from(page.content, page.encoding);
          if (page.encoding === "base64" && bytes.toString("base64") !== page.content) fail("InvalidWorkerSnapshotEncoding");
          if (page.encoding === "utf8" && bytes.toString("utf8") !== page.content) fail("InvalidWorkerSnapshotEncoding");
          if (bytes.length > 16384 || bytes.length > total - offset) fail("InvalidWorkerSnapshotPage");
          pieces.push(bytes); contentHash.update(bytes); fossilHash.update(bytes); offset += bytes.length;
          if (page.next_offset === null) {
            if (offset !== total) fail("IncompleteWorkerSnapshotContent");
            break;
          }
          if (!bytes.length || page.next_offset !== offset || offset >= total) fail("InvalidWorkerSnapshotCursor");
        }
        if (contentHash.digest("hex") !== expectedHash || fossilHash.digest("hex") !== file.artifact) fail("WorkerSnapshotHashMismatch");
        consumed += total;
        return Object.freeze({ ...file, sha256: expectedHash, bytes: total, content: Buffer.concat(pieces, total) });
      } finally { reading = false; }
    },
  });
}
