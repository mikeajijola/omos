// Sessions kept in files on this machine, through Workflow's local World.
// libfx bundles that World into this module when it is packaged, so an app
// installs nothing more.
import { hostname } from "node:os";
import { resolve } from "node:path";
import { createWorld } from "@workflow/world-local";
import { world } from "./world.mjs";

const host = hostname();
const starting = new Map();

function startLocalWorld(store, start) {
  // world-local writes its version file in place during initialization. Two
  // agents opening the same local store can otherwise observe the empty file
  // between creation and write. Serialize initialization in this process;
  // each agent still owns its own World and queue after startup.
  const pending = (starting.get(store) ?? Promise.resolve()).catch(() => {}).then(start);
  starting.set(store, pending);
  const release = () => { if (starting.get(store) === pending) starting.delete(store); };
  pending.then(release, release);
  return pending;
}

/**
 * `dir` is where the sessions live. Workers on this machine hold a session
 * while their process runs, so a crashed worker's session frees at once.
 * With `maxDurationMs`, each delivery runs as if its function stopped after
 * that long, stopping `reserveMs` before, as on Vercel.
 */
export function local({ dir, maxDurationMs, reserveMs } = {}) {
  if (dir !== undefined && (typeof dir !== "string" || dir.length === 0)) throw new TypeError("local() dir must be a path");
  const store = `local:${dir === undefined ? "" : resolve(dir)}`;
  return world(() => {
    const owned = createWorld({ ...(dir === undefined ? {} : { dataDir: dir }), recoverActiveRuns: false });
    const start = owned.start.bind(owned);
    owned.start = () => startLocalWorld(store, start);
    return owned;
  }, {
    name: "local",
    // Each folder is a store of its own.
    store,
    livenessKnown: true,
    // world-local keeps its queue in memory, so a message dies with the process.
    queueDurable: false,
    pollMs: 250,
    maxDurationMs,
    reserveMs,
    holderInfo: () => ({ pid: process.pid, host }),
    alive(lease) {
      if (lease.host !== host || !Number.isSafeInteger(lease.pid)) return null;
      try {
        process.kill(lease.pid, 0);
        return true;
      } catch (error) {
        return error?.code === "EPERM";
      }
    },
  });
}
