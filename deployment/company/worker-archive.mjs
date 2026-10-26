// Retain the native export, never the worker profile, provider replay state or
// credentials. The caller joins the actor before creating this export.
import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

const chunkBytes = 128 * 1024;
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const fail = code => { throw Error(code); };

export async function retainWorkerArchive({ filename, uid, source, view, execution, control, signal }) {
  if (!path.isAbsolute(filename) || !Number.isSafeInteger(uid) || uid < 0 || !hash(source?.workspace) || !hash(source?.task) || !hash(source?.revision) || !hash(view) || !control || typeof control.call !== "function") fail("InvalidWorkerArchive");
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
