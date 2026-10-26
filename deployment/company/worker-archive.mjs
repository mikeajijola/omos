// Retain the native export, never the worker profile, provider replay state or
// credentials. The caller joins the actor before creating this export.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

const chunkBytes = 128 * 1024;
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const fail = code => { throw Error(code); };

// Native export publishes a verified repository with an exclusive hard link,
// then removes its staging alias. A crash between those steps leaves two
// names for the verified inode. Repair only that exact staging relationship.
async function finishExportLink(filename, uid) {
  const before = await fs.lstat(filename);
  if (before.nlink !== 2 || !before.isFile() || before.uid !== uid) return;
  const parent = path.dirname(filename), prefix = path.basename(filename) + ".pending-";
  for (const name of await fs.readdir(parent)) {
    if (!name.startsWith(prefix) || !/^[0-9a-f]{32}$/.test(name.slice(prefix.length))) continue;
    const directory = path.join(parent, name), info = await fs.lstat(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || ![0, uid].includes(info.uid)) continue;
    const entries = await fs.readdir(directory);
    if (entries.length !== 1 || entries[0] !== "workspace.fossil") continue;
    const temporary = path.join(directory, "workspace.fossil");
    const file = await fs.open(temporary, constants.O_RDONLY | constants.O_NOFOLLOW);
    let matches;
    try {
      const info = await file.stat();
      matches = info.isFile() && info.uid === uid && info.dev === before.dev && info.ino === before.ino && info.size === before.size && info.nlink === 2;
    } finally { await file.close(); }
    if (!matches) continue;
    const current = await fs.lstat(filename);
    if (!current.isFile() || current.dev !== before.dev || current.ino !== before.ino || current.uid !== uid || current.nlink !== 2) fail("WorkerArchiveChanged");
    await fs.unlink(temporary);
    await fs.rmdir(directory);
    return;
  }
}

export async function prepareWorkerExport(filename, uid) {
  try { await fs.lstat(filename); return; }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  const parent = path.dirname(filename), prefix = path.basename(filename) + ".pending-";
  for (const name of await fs.readdir(parent)) {
    if (!name.startsWith(prefix) || !/^[0-9a-f]{32}$/.test(name.slice(prefix.length))) continue;
    const directory = path.join(parent, name), info = await fs.lstat(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== uid) continue;
    const names = await fs.readdir(directory);
    if (names.some(name => !["workspace.fossil", "workspace.fossil-journal", "workspace.fossil-wal", "workspace.fossil-shm"].includes(name))) continue;
    const files = await Promise.all(names.map(name => fs.lstat(path.join(directory, name))));
    if (files.some(info => !info.isFile() || info.uid !== uid || info.nlink !== 1)) continue;
    // No destination was published. These are disposable clone files, not the
    // original repository, and actor processes have already joined.
    for (const name of names) await fs.unlink(path.join(directory, name));
    await fs.rmdir(directory);
  }
}

export async function retainWorkerArchive({ filename, uid, source, view, execution, control, signal }) {
  if (!path.isAbsolute(filename) || !Number.isSafeInteger(uid) || uid < 0 || !hash(source?.workspace) || !hash(source?.task) || !hash(source?.revision) || !hash(view) || !control || typeof control.call !== "function") fail("InvalidWorkerArchive");
  await finishExportLink(filename, uid);
  const before = await fs.lstat(filename);
  const file = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await file.stat();
    if (!info.isFile() || info.nlink !== 1 || info.uid !== uid || info.ino !== before.ino || info.dev !== before.dev || info.size < 512 || !Number.isSafeInteger(info.size)) fail("InvalidWorkerArchiveFile");
    const buffer = Buffer.alloc(chunkBytes);
    const digest = createHash("sha256");
    const read = async offset => {
      signal?.throwIfAborted();
      const size = Math.min(chunkBytes, info.size - offset);
      let filled = 0;
      while (filled < size) {
        const { bytesRead } = await file.read(buffer, filled, size - filled, offset + filled);
        if (!bytesRead) fail("WorkerArchiveChanged");
        filled += bytesRead;
      }
      return buffer.subarray(0, filled);
    };
    try {
      for (let offset = 0; offset < info.size; offset += chunkBytes) digest.update(await read(offset));
      const selected = { ...source, sha256: digest.digest("hex"), bytes: info.size };
      let retained;
      const resume = await control.call({ version: "omos.company-actor-archive-write/v1", action: "inspect", view, execution, source: selected, offset: 0, content: "" }, signal);
      if (!resume.ok || resume.sha256 !== selected.sha256 || resume.bytes !== selected.bytes || !Number.isSafeInteger(resume.resume_offset) || resume.resume_offset < 0 || resume.resume_offset > info.size || (resume.resume_offset < info.size && resume.resume_offset % chunkBytes !== 0) || resume.complete !== (resume.resume_offset === info.size) || !hash(resume.archive_id) || !hash(resume.revision)) fail("WorkerArchiveRetentionPending");
      retained = resume;
      for (let offset = resume.resume_offset; offset < info.size; offset += chunkBytes) {
        const bytes = await read(offset);
        let result;
        try { result = await control.call({ version: "omos.company-actor-archive-write/v1", action: "chunk", view, execution, source: selected, offset, content: bytes.toString("base64") }, signal); }
        catch { fail("WorkerArchiveRetentionPending"); }
        const next = offset + bytes.length < info.size ? offset + bytes.length : null;
        if (!result.ok || result.view !== view || result.sha256 !== selected.sha256 || result.bytes !== selected.bytes || result.offset !== offset || result.next_offset !== next || result.complete !== (next === null) || !hash(result.archive_id) || !hash(result.revision) || (retained && retained.archive_id !== result.archive_id)) fail("WorkerArchiveRetentionPending");
        retained = result;
      }
      const after = await file.stat();
      if (after.size !== info.size || after.mtimeMs !== info.mtimeMs || after.ctimeMs !== info.ctimeMs) fail("WorkerArchiveChanged");
      return { archive_id: retained.archive_id, sha256: selected.sha256, bytes: selected.bytes, revision: retained.revision, source: selected, complete: true, authority: "actor_public_history_only" };
    } finally { buffer.fill(0); }
  } finally { await file.close(); }
}
