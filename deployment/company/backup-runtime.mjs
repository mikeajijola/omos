import fs from "node:fs/promises";
import { constants, createReadStream } from "node:fs";
import path from "node:path";
import {
  createHash,
  randomUUID,
  createPrivateKey,
  createPublicKey,
} from "node:crypto";
import { spawn } from "node:child_process";
import { StringDecoder } from "node:string_decoder";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const hex = (value) =>
  typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const inside = (parent, child) =>
  child === parent || child.startsWith(parent + path.sep);
function reject(code) {
  throw Object.assign(new Error(code), { code });
}

function snapshotStream(consume) {
  const decoder = new StringDecoder("utf8");
  let state = "start",
    depth = 0,
    quoted = false,
    escaped = false,
    record = "",
    mayEnd = true;
  function text(bytes) {
    for (const char of bytes) {
      if (depth) {
        record += char;
        if (record.length > 65536) reject("BackupMetadataRecordLimit");
        if (quoted) {
          if (escaped) escaped = false;
          else if (char === "\\") escaped = true;
          else if (char === '"') quoted = false;
        } else if (char === '"') quoted = true;
        else if (char === "{" || char === "[") depth++;
        else if (char === "}" || char === "]") depth--;
        if (!depth) {
          if (Buffer.byteLength(record) > 65536)
            reject("BackupMetadataRecordLimit");
          consume(JSON.parse(record));
          record = "";
          state = "separator";
        }
      } else if (/\s/.test(char)) continue;
      else if (state === "start" && char === "[") state = "value";
      else if (state === "value" && char === "{") {
        record = "{";
        depth = 1;
      } else if (state === "separator" && char === ",") {
        state = "value";
        mayEnd = false;
      } else if (
        (state === "separator" || (state === "value" && mayEnd)) &&
        char === "]"
      )
        state = "done";
      else reject("InvalidBackupMetadata");
    }
  }
  return {
    write: (bytes) => text(decoder.write(bytes)),
    end() {
      text(decoder.end());
      if (state !== "done" || depth) reject("InvalidBackupMetadata");
    },
  };
}

// Every ancestor is owned by the operator or root. Sticky temporary roots are
// permitted, but links and writable non-sticky ancestors are never followed.
async function checkedPath(
  value,
  { directory = false, privateLeaf = false, executable = false } = {},
) {
  if (
    process.platform === "win32" ||
    typeof value !== "string" ||
    !path.isAbsolute(value) ||
    path.normalize(value) !== value
  )
    reject("InvalidBackupPath");
  let current = path.parse(value).root;
  const parts = value.slice(current.length).split(path.sep);
  for (let index = 0; index < parts.length; index++) {
    current = path.join(current, parts[index]);
    const info = await fs.lstat(current);
    const leaf = index === parts.length - 1;
    if (info.isSymbolicLink() || ![0, process.getuid()].includes(info.uid))
      reject("UnsafeBackupPath");
    if (!leaf || directory) {
      if (
        !info.isDirectory() ||
        (info.mode & 0o022 && !(info.uid === 0 && info.mode & 0o1000))
      )
        reject("UnsafeBackupDirectory");
    } else if (!info.isFile() || info.nlink !== 1 || info.mode & 0o022)
      reject("UnsafeBackupFile");
    if (
      leaf &&
      privateLeaf &&
      (info.uid !== process.getuid() || info.mode & 0o077)
    )
      reject("BackupPermissionsUnsafe");
    if (leaf && executable && !(info.mode & 0o111))
      reject("BackupExecutableUnavailable");
  }
  return value;
}

async function privateBytes(file, limit) {
  await checkedPath(file, { privateLeaf: true });
  const opened = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await opened.stat();
    if (
      info.size > limit ||
      !info.isFile() ||
      info.nlink !== 1 ||
      info.mode & 0o077 ||
      info.uid !== process.getuid()
    )
      reject("BackupPermissionsUnsafe");
    return await opened.readFile();
  } finally {
    await opened.close();
  }
}

async function durableJson(
  file,
  value,
  temporaryDirectory = path.dirname(file),
  guard = () => {},
) {
  guard();
  const temporary = path.join(temporaryDirectory, ".write-" + randomUUID());
  const opened = await fs.open(temporary, "wx", 0o600);
  try {
    await opened.writeFile(JSON.stringify(value) + "\n");
    await opened.sync();
  } finally {
    await opened.close();
  }
  try {
    guard();
    await fs.rename(temporary, file);
    const parent = await fs.open(
      path.dirname(file),
      constants.O_RDONLY | constants.O_DIRECTORY,
    );
    try {
      await parent.sync();
    } finally {
      await parent.close();
    }
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

export async function loadBackupConfiguration(
  file,
  { requireSource = true } = {},
) {
  const value = JSON.parse(await privateBytes(file, 16384));
  const fields = [
    "version",
    "workspace",
    "profile",
    "runtime",
    "fossil",
    "restic",
    "repository",
    "password_file",
    "staging_root",
    "client_key_handles",
    "timeout_ms",
    "lock_program",
  ];
  if (
    !object(value) ||
    value.version !== "omos.company-backup/v1" ||
    !hex(value.workspace) ||
    Object.keys(value).some((key) => !fields.includes(key)) ||
    [
      "profile",
      "runtime",
      "fossil",
      "restic",
      "repository",
      "password_file",
      "staging_root",
    ].some((key) => typeof value[key] !== "string")
  )
    reject("InvalidBackupConfiguration");
  for (const field of ["runtime", "fossil", "restic"])
    await checkedPath(value[field], { executable: true });
  const lockProgram = value.lock_program ?? "/usr/bin/flock";
  await checkedPath(lockProgram, { executable: true });
  await checkedPath(value.profile, { directory: true });
  await checkedPath(value.staging_root, { directory: true, privateLeaf: true });
  await checkedPath(value.repository, { directory: true, privateLeaf: true });
  if (
    inside(value.repository, value.staging_root) ||
    inside(value.staging_root, value.repository) ||
    inside(value.repository, value.password_file) ||
    inside(value.staging_root, value.password_file)
  )
    reject("BackupPathsOverlap");
  const password = await privateBytes(value.password_file, 4096);
  try {
    if (!password.some((byte) => ![9, 10, 13, 32].includes(byte)))
      reject("BackupPasswordUnavailable");
  } finally {
    password.fill(0);
  }
  const handles = value.client_key_handles ?? [];
  if (
    !Array.isArray(handles) ||
    handles.length > 64 ||
    new Set(handles).size !== handles.length ||
    handles.some(
      (handle) =>
        typeof handle !== "string" || !/^[a-zA-Z0-9_-]{1,128}$/.test(handle),
    )
  )
    reject("InvalidBackupKeySelection");
  const timeout = value.timeout_ms ?? 600000;
  if (!Number.isSafeInteger(timeout) || timeout < 1000 || timeout > 3600000)
    reject("InvalidBackupDeadline");
  let source = null;
  if (requireSource) {
    const binding = JSON.parse(
      await privateBytes(
        path.join(value.profile, ".fx/omos-workspace.json"),
        16384,
      ),
    );
    if (
      binding.workspace_id !== value.workspace ||
      typeof binding.repository !== "string"
    )
      reject("BackupWorkspaceMismatch");
    await checkedPath(binding.repository, { privateLeaf: true });
    source = binding.repository;
  }
  return Object.freeze({
    ...value,
    lock_program: lockProgram,
    source_repository: source,
    client_key_handles: Object.freeze([...handles]),
    timeout_ms: timeout,
  });
}

async function fileIdentity(file) {
  const digest = createHash("sha256");
  let bytes = 0;
  for await (const chunk of createReadStream(file)) {
    bytes += chunk.length;
    digest.update(chunk);
  }
  return { sha256: digest.digest("hex"), bytes };
}

// A backup controller has one absolute deadline, including lock acquisition,
// subprocesses, verification and recovery. Secret values never enter argv.
export function createBackupController(
  config,
  { signal: externalSignal } = {},
) {
  const cancellation = new AbortController();
  const signal = cancellation.signal;
  const forwardCancel = () => cancellation.abort("BackupCancelled");
  externalSignal?.addEventListener("abort", forwardCancel, { once: true });
  if (externalSignal?.aborted) forwardCancel();
  const deadline = Date.now() + config.timeout_ms;
  const active = new Set();
  const environment = {
    PATH: "/usr/bin:/bin",
    LANG: "C.UTF-8",
    HOME: config.profile,
    FOSSIL_HOME: config.profile,
    XDG_CONFIG_HOME: path.join(config.profile, ".config"),
    OMOS_FOSSIL_BIN: config.fossil,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_CONTRACT_REVIEW: "1",
  };
  function remaining() {
    if (signal.aborted) reject(signal.reason ?? "BackupCancelled");
    const result = deadline - Date.now();
    if (result <= 0) reject("BackupDeadline");
    return result;
  }
  async function run(
    executable,
    args,
    {
      cwd = config.staging_root,
      backup = false,
      maxBytes = 1024 * 1024,
      digest = null,
      sink = null,
      discard = false,
      profile = config.profile,
    } = {},
  ) {
    const duration = remaining();
    if (profile !== config.profile && !inside(config.staging_root, profile))
      reject("InvalidBackupProfile");
    const local = {
      ...environment,
      HOME: profile,
      FOSSIL_HOME: profile,
      XDG_CONFIG_HOME: path.join(profile, ".config"),
    };
    const env = backup
      ? {
          ...local,
          RESTIC_REPOSITORY: config.repository,
          RESTIC_PASSWORD_FILE: config.password_file,
          RESTIC_CACHE_DIR: path.join(config.staging_root, "cache"),
        }
      : local;
    return new Promise((resolve, rejectPromise) => {
      const child = spawn(executable, args, {
        cwd,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      const joined = new Promise((resolve) => child.once("close", resolve));
      active.add(joined);
      joined.then(() => active.delete(joined));
      let bytes = 0,
        stderrBytes = 0,
        failure,
        force,
        stdout = [],
        stderr = [];
      const stop = (code) => {
        failure ??= code;
        child.kill("SIGTERM");
        force ??= setTimeout(() => child.kill("SIGKILL"), 5000);
      };
      const cancel = () => stop(signal.reason ?? "BackupCancelled");
      const timer = setTimeout(() => stop("BackupDeadline"), duration);
      signal?.addEventListener("abort", cancel, { once: true });
      if (signal?.aborted) cancel();
      child.stdout.on("data", (chunk) => {
        bytes += chunk.length;
        if (bytes > maxBytes) {
          stop("BackupOutputLimit");
          return;
        }
        try {
          if (sink) sink.write(chunk);
          else if (digest) digest.update(chunk);
          else if (!discard) stdout.push(chunk);
        } catch (error) {
          stop(error.code ?? "InvalidBackupMetadata");
        }
      });
      child.stderr.on("data", (chunk) => {
        stderrBytes += chunk.length;
        if (stderrBytes > 16384) stop("BackupOutputLimit");
        else stderr.push(chunk);
      });
      child.once("error", () => {
        failure ??= "BackupProcessUnavailable";
      });
      child.once("close", (code) => {
        clearTimeout(timer);
        clearTimeout(force);
        signal?.removeEventListener("abort", cancel);
        if (!failure && code === 0 && sink)
          try {
            sink.end();
          } catch (error) {
            failure = error.code ?? "InvalidBackupMetadata";
          }
        if (failure || code !== 0) {
          const stage =
            path.basename(executable) +
            ":" +
            (args.find((arg) =>
              [
                "fossil",
                "init",
                "backup",
                "dump",
                "snapshots",
                "cat",
                "whatis",
                "restore",
                "list",
              ].includes(arg),
            ) ?? "operation");
          const error = Object.assign(
            new Error((failure ?? "BackupCommandFailed") + " (" + stage + ")"),
            {
              code: failure ?? "BackupCommandFailed",
              exit_code: code,
              stage,
              diagnostic: Buffer.concat(stderr).toString("utf8").slice(-4096),
            },
          );
          rejectPromise(error);
        } else
          resolve({
            bytes,
            stdout: Buffer.concat(stdout),
            stderr: Buffer.concat(stderr).toString("utf8"),
          });
      });
    });
  }
  const writeJson = (file, value, temporaryDirectory) =>
    durableJson(file, value, temporaryDirectory, remaining);
  const restic = async (args, options) =>
    run(config.restic, args, { ...options, backup: true });
  const native = async (args, options) => run(config.runtime, args, options);
  const json = async (args) =>
    JSON.parse((await restic(["--json", ...args])).stdout);
  async function snapshots({ id, tags, limit = 2 } = {}) {
    const args = ["snapshots"];
    if (id) args.push(id);
    if (tags) args.push("--tag", tags.join(","));
    if (!id) args.push("--latest", String(limit));
    const rows = [];
    let count = 0;
    const sink = snapshotStream((row) => {
      if (
        !object(row) ||
        !hex(row.id) ||
        typeof row.time !== "string" ||
        !Number.isFinite(Date.parse(row.time)) ||
        (id && (row.id !== id || ++count > 1))
      )
        reject("InvalidBackupSnapshot");
      rows.push(row);
      rows.sort(
        (left, right) =>
          Date.parse(right.time) - Date.parse(left.time) ||
          right.id.localeCompare(left.id),
      );
      if (rows.length > limit) rows.length = limit;
    });
    // --latest is per path in restic. Stream those records and retain only
    // the global recent page, rather than applying an aggregate history cap.
    await restic(["--json", ...args], {
      sink,
      maxBytes: Number.MAX_SAFE_INTEGER,
    });
    return rows;
  }
  let boundDomain,
    backupEffectPending = false;
  async function domain() {
    if (boundDomain) return boundDomain;
    const configValue = await json(["cat", "config"]);
    if (!hex(configValue.id) || configValue.version !== 2)
      reject("BackupRepositoryUnsupported");
    const rows = await snapshots({ tags: ["omos-company-domain"] });
    if (!rows.length) reject("BackupDomainUnavailable");
    if (rows.length !== 1) reject("BackupDomainConflict");
    const value = JSON.parse(
      (
        await restic([
          "dump",
          rows[0].id,
          path.join(snapshotRoot(rows[0]), "domain.json"),
        ])
      ).stdout,
    );
    if (
      value.version !== "omos.company-backup-domain/v1" ||
      value.workspace !== config.workspace ||
      value.key_domain !== configValue.id
    )
      reject("BackupDomainMismatch");
    boundDomain = Object.freeze({ id: configValue.id, snapshot: rows[0].id });
    return boundDomain;
  }
  async function withLock(action) {
    remaining();
    // The repository sidecar serializes callers even when their profiles or
    // staging roots differ. It is outside the restic repository itself.
    const lock = config.repository + ".omos-backup.lock";
    try {
      const file = await fs.open(lock, "wx", 0o600);
      await file.close();
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    await checkedPath(lock, { privateLeaf: true });
    const duration = remaining();
    const child = spawn(
      config.lock_program,
      [
        "--nonblock",
        "--conflict-exit-code",
        "75",
        lock,
        "/bin/sh",
        "-c",
        "printf 'locked\\n'; cat >/dev/null",
      ],
      { env: environment, stdio: ["pipe", "pipe", "pipe"] },
    );
    const closed = new Promise((resolve) => child.once("close", resolve));
    let expectedClose = false,
      lost = false,
      force,
      actionStarted = false;
    child.once("close", () => {
      if (!expectedClose) {
        lost = true;
        cancellation.abort("BackupLockLost");
      }
    });
    const release = () => {
      child.stdin.end();
      child.kill("SIGTERM");
      force ??= setTimeout(() => child.kill("SIGKILL"), 5000);
    };
    const abortLease = () => {
      if (!actionStarted) release();
    };
    signal?.addEventListener("abort", abortLease, { once: true });
    const timer = setTimeout(
      () => cancellation.abort("BackupDeadline"),
      duration,
    );
    if (signal.aborted) release();
    let stopAction;
    try {
      await new Promise((resolve, rejectPromise) => {
        child.once("error", () =>
          rejectPromise(
            Object.assign(new Error("BackupLockUnavailable"), {
              code: "BackupLockUnavailable",
            }),
          ),
        );
        child.stdout.once("data", (bytes) =>
          bytes.toString() === "locked\n"
            ? resolve()
            : rejectPromise(new Error("BackupLockUnavailable")),
        );
        child.once("close", () =>
          rejectPromise(
            Object.assign(new Error("BackupBusy"), { code: "BackupBusy" }),
          ),
        );
      });
      remaining();
      actionStarted = true;
      const interrupted = new Promise((resolve, rejectPromise) => {
        stopAction = () =>
          rejectPromise(
            Object.assign(new Error(signal.reason), { code: signal.reason }),
          );
        signal.addEventListener("abort", stopAction, { once: true });
      });
      const result = await Promise.race([
        Promise.resolve().then(action),
        interrupted,
      ]);
      if (lost) reject("BackupLockLost");
      return result;
    } catch (error) {
      if (backupEffectPending) error.outcome = "uncertain";
      throw error;
    } finally {
      expectedClose = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abortLease);
      if (stopAction) signal.removeEventListener("abort", stopAction);
      if (active.size) cancellation.abort("BackupCancelled");
      await Promise.allSettled([...active]);
      release();
      await closed;
      clearTimeout(force);
    }
  }
  async function inventory({ operation, snapshot, limit = 32 } = {}) {
    await domain();
    if (
      operation &&
      (typeof operation !== "string" ||
        !/^[a-zA-Z0-9_-]{1,64}$/.test(operation))
    )
      reject("InvalidBackupOperation");
    if (snapshot && !hex(snapshot)) reject("InvalidBackupSnapshot");
    if (!Number.isInteger(limit) || limit < 1 || limit > 32)
      reject("InvalidBackupPage");
    const tags = ["omos-company-backup", "omos-workspace-" + config.workspace];
    if (operation) tags.push("omos-operation-" + operation);
    const rows = await snapshots({
      id: snapshot,
      tags: snapshot ? null : tags,
      limit,
    });
    if (rows.some((row) => !tags.every((tag) => row.tags?.includes(tag))))
      reject("BackupDomainMismatch");
    return rows;
  }
  async function initialize() {
    const entries = await fs.readdir(config.repository);
    if (entries.length === 0)
      await restic(["init", "--repository-version", "2"]);
    const repository = await json(["cat", "config"]);
    if (!hex(repository.id) || repository.version !== 2)
      reject("BackupRepositoryUnsupported");
    try {
      await domain();
    } catch (error) {
      if (error.code !== "BackupDomainUnavailable") throw error;
      if ((await snapshots({ limit: 1 })).length)
        reject("BackupDomainMismatch");
      const directory = path.join(
        config.staging_root,
        "domains",
        repository.id,
      );
      await fs.mkdir(directory, { recursive: true, mode: 0o700 });
      await checkedPath(directory, { directory: true, privateLeaf: true });
      await writeJson(path.join(directory, "domain.json"), {
        version: "omos.company-backup-domain/v1",
        workspace: config.workspace,
        key_domain: repository.id,
      });
      await restic(["backup", "--tag", "omos-company-domain", directory], {
        discard: true,
        maxBytes: Number.MAX_SAFE_INTEGER,
      });
      await domain();
    }
    return {
      version: "omos.company-backup-receipt/v1",
      action: "initialize",
      workspace: config.workspace,
      key_domain: repository.id,
    };
  }
  function publicKey(seed) {
    if (seed.length !== 32) reject("InvalidBackupKey");
    const der = Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"),
      seed,
    ]);
    try {
      return createPublicKey(
        createPrivateKey({ key: der, format: "der", type: "pkcs8" }),
      )
        .export({ type: "spki", format: "der" })
        .subarray(-32)
        .toString("hex");
    } finally {
      der.fill(0);
    }
  }
  async function sourceRevision(repository, selected) {
    const result = await run(config.fossil, [
      "whatis",
      "--type",
      "ci",
      selected,
      "-R",
      repository,
    ]);
    const rows = result.stdout
      .toString("utf8")
      .split("\n")
      .filter((line) => line.startsWith("artifact:"));
    const revision = rows[0]?.slice(9).trim();
    if (rows.length !== 1 || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(revision))
      reject("InvalidBackupRevision");
    return revision;
  }
  function snapshotRoot(snapshot) {
    if (
      !Array.isArray(snapshot.paths) ||
      snapshot.paths.length !== 1 ||
      !path.isAbsolute(snapshot.paths[0]) ||
      path.normalize(snapshot.paths[0]) !== snapshot.paths[0]
    )
      reject("InvalidBackupSnapshot");
    return snapshot.paths[0];
  }
  function validateManifest(manifest) {
    if (
      !object(manifest) ||
      manifest.version !== "omos.company-backup-manifest/v1" ||
      manifest.workspace !== config.workspace ||
      !hex(manifest.request_sha256) ||
      !hex(manifest.key_domain) ||
      !Array.isArray(manifest.files) ||
      manifest.files.length > 67 ||
      !hex(manifest.authority?.issuer) ||
      !Number.isSafeInteger(manifest.authority?.epoch) ||
      manifest.authority.epoch < 1 ||
      typeof manifest.operation !== "string" ||
      !/^[a-zA-Z0-9_-]{1,64}$/.test(manifest.operation)
    )
      reject("InvalidBackupManifest");
    const handles = manifest.client_key_handles;
    if (
      !Array.isArray(handles) ||
      handles.length > 64 ||
      handles.some(
        (handle) =>
          typeof handle !== "string" || !/^[a-zA-Z0-9_-]{1,128}$/.test(handle),
      ) ||
      new Set(handles).size !== handles.length
    )
      reject("InvalidBackupManifest");
    const expected = new Set([
      "repository.fossil",
      "authority/issuer.json",
      `authority/issuer-${manifest.authority.issuer}.seed`,
      ...handles.map((handle) => "client-keys/" + handle + ".seed"),
    ]);
    for (const file of manifest.files) {
      if (
        !object(file) ||
        !expected.delete(file.path) ||
        !hex(file.sha256) ||
        !Number.isSafeInteger(file.bytes) ||
        file.bytes < 0 ||
        (file.path.endsWith(".seed") && file.bytes !== 32)
      )
        reject("InvalidBackupManifest");
    }
    if (expected.size) reject("IncompleteBackupManifest");
    for (const revision of [
      manifest.source?.accepted_revision,
      manifest.source?.control_revision,
    ])
      if (
        typeof revision !== "string" ||
        !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(revision)
      )
        reject("InvalidBackupRevision");
    return manifest;
  }
  async function manifestFor(snapshot) {
    const raw = (
      await restic([
        "dump",
        snapshot.id,
        path.join(snapshotRoot(snapshot), "manifest.json"),
      ])
    ).stdout;
    const manifest = validateManifest(JSON.parse(raw));
    return { manifest, sha256: hash(raw) };
  }
  async function verifyDataset(dataset, manifest) {
    const expected = new Set([
      "manifest.json",
      ...manifest.files.map((file) => file.path),
    ]);
    const directories = new Set(["."]);
    for (const file of expected) {
      let parent = path.dirname(file);
      while (parent !== ".") {
        directories.add(parent);
        parent = path.dirname(parent);
      }
    }
    async function visit(relative) {
      const directory = path.join(dataset, relative);
      await checkedPath(directory, { directory: true, privateLeaf: true });
      for (const entry of await fs.readdir(directory, {
        withFileTypes: true,
      })) {
        remaining();
        const name = path.join(relative, entry.name);
        if (entry.isDirectory() && directories.has(name)) await visit(name);
        else if (!entry.isFile() || !expected.delete(name))
          reject("InvalidBackupTree");
      }
    }
    await visit(".");
    if (expected.size) reject("IncompleteBackupTree");
  }
  async function verifyTree(row, manifest) {
    // The encrypted tree must contain exactly the declared files. Restic's
    // authenticated metadata is still checked against our narrower contract.
    const tree = (await restic(["ls", "--json", row.id])).stdout
      .toString("utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    const expected = new Set([
      "manifest.json",
      ...manifest.files.map((file) => file.path),
    ]);
    const root = snapshotRoot(row);
    const directories = new Set();
    for (const file of expected) {
      let directory = path.dirname(path.join(root, file));
      while (true) {
        directories.add(directory);
        const parent = path.dirname(directory);
        if (parent === directory) break;
        directory = parent;
      }
    }
    for (const node of tree.filter((value) => value.struct_type === "node")) {
      if (
        typeof node.path !== "string" ||
        path.normalize(node.path) !== node.path
      )
        reject("InvalidBackupTree");
      if (node.type === "dir" && directories.has(node.path)) continue;
      if (
        node.type !== "file" ||
        !inside(root, node.path) ||
        !expected.delete(path.relative(root, node.path))
      )
        reject("InvalidBackupTree");
    }
    if (expected.size) reject("IncompleteBackupTree");
  }
  async function verifySnapshot(snapshot, expectedRequest = null) {
    const { manifest, sha256 } = await manifestFor(snapshot);
    if (expectedRequest !== null && manifest.request_sha256 !== expectedRequest)
      reject("BackupOperationConflict");
    const currentDomain = await domain();
    if (manifest.key_domain !== currentDomain.id)
      reject("BackupDomainMismatch");
    await verifyTree(snapshot, manifest);
    for (const file of manifest.files) {
      const digest = createHash("sha256");
      const result = await restic(
        ["dump", snapshot.id, path.join(snapshotRoot(snapshot), file.path)],
        { digest, maxBytes: file.bytes },
      );
      if (result.bytes !== file.bytes || digest.digest("hex") !== file.sha256)
        reject("BackupContentChanged");
    }
    return {
      version: "omos.company-backup-receipt/v1",
      action: "verify",
      workspace: config.workspace,
      operation: manifest.operation,
      snapshot: snapshot.id,
      key_domain: currentDomain.id,
      manifest_sha256: sha256,
      source: manifest.source,
      verified: true,
      files: manifest.files.length,
    };
  }
  async function create({ operation = randomUUID() } = {}) {
    if (!config.source_repository) reject("BackupSourceUnavailable");
    if (
      typeof operation !== "string" ||
      !/^[a-zA-Z0-9_-]{1,64}$/.test(operation)
    )
      reject("InvalidBackupOperation");
    const currentDomain = await domain();
    const request = hash(
      JSON.stringify({
        workspace: config.workspace,
        key_domain: currentDomain.id,
        client_key_handles: [...config.client_key_handles].sort(),
      }),
    );
    const tag = "omos-operation-" + operation;
    const previous = await inventory({ operation, limit: 2 });
    if (previous.length > 1) reject("BackupOperationConflict");
    const operationRoot = path.join(
      config.staging_root,
      "companies",
      config.workspace,
      currentDomain.id,
      "operations",
      operation,
    );
    const dataset = path.join(operationRoot, "dataset");
    const finish = async (receipt) => {
      await fs.mkdir(operationRoot, { recursive: true, mode: 0o700 });
      await checkedPath(operationRoot, { directory: true, privateLeaf: true });
      await writeJson(path.join(operationRoot, "receipt.json"), receipt);
      remaining();
      await fs.rm(dataset, { recursive: true, force: true });
      await fs.rm(path.join(operationRoot, "export.fossil"), { force: true });
      await fs.rm(path.join(operationRoot, "verification-profile"), {
        recursive: true,
        force: true,
      });
      for (const entry of await fs.readdir(operationRoot, {
        withFileTypes: true,
      })) {
        if (
          entry.isFile() &&
          /^\.(?:key|write|repository)-[a-f0-9-]{36}$/.test(entry.name)
        )
          await fs.rm(path.join(operationRoot, entry.name));
      }
      backupEffectPending = false;
      return receipt;
    };
    if (previous.length === 1)
      return finish({
        ...(await verifySnapshot(previous[0], request)),
        action: "create",
        replayed: true,
      });
    // Interrupted restic writers must finish or be reconciled before another
    // snapshot is attempted. No stale lock is removed automatically.
    const locks = (await restic(["list", "locks"])).stdout
      .toString("utf8")
      .trim();
    if (locks) reject("BackupRepositoryBusy");
    await fs.mkdir(dataset, { recursive: true, mode: 0o700 });
    await checkedPath(dataset, { directory: true, privateLeaf: true });
    const manifestPath = path.join(dataset, "manifest.json");
    let prepared;
    try {
      prepared = JSON.parse(await privateBytes(manifestPath, 1024 * 1024));
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (prepared) {
      validateManifest(prepared);
      if (
        prepared.request_sha256 !== request ||
        prepared.operation !== operation
      )
        reject("BackupOperationConflict");
    }
    if (!prepared) {
      const authorityPath = path.join(
        config.profile,
        ".fx",
        "authority",
        config.workspace,
      );
      const contextPath = path.join(operationRoot, "source.json");
      let context;
      try {
        context = JSON.parse(await privateBytes(contextPath, 32768));
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      if (
        context &&
        (context.request_sha256 !== request ||
          typeof context.issuer_base64 !== "string")
      )
        reject("BackupOperationConflict");
      const descriptorBytes = context
        ? Buffer.from(context.issuer_base64, "base64")
        : await privateBytes(path.join(authorityPath, "issuer.json"), 16384);
      if (
        context &&
        descriptorBytes.toString("base64") !== context.issuer_base64
      )
        reject("InvalidBackupAuthority");
      const descriptor = JSON.parse(descriptorBytes);
      if (
        descriptor.version !== "omos.company-issuer/v1" ||
        descriptor.workspace !== config.workspace ||
        descriptor.repository !== config.source_repository ||
        !hex(descriptor.public_key) ||
        descriptor.seed_file !== `issuer-${descriptor.public_key}.seed`
      )
        reject("InvalidBackupAuthority");
      if (!context)
        await writeJson(contextPath, {
          request_sha256: request,
          issuer_base64: descriptorBytes.toString("base64"),
        });
      const repository = path.join(operationRoot, "export.fossil");
      let retained = false;
      try {
        await fs.access(repository);
        retained = true;
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      if (retained) {
        await checkedPath(repository, { privateLeaf: true });
        const profile = path.join(operationRoot, "verification-profile");
        await fs.mkdir(profile, { recursive: true, mode: 0o700 });
        await checkedPath(profile, { directory: true, privateLeaf: true });
        const verification = path.join(profile, "repository.fossil");
        await fs.copyFile(repository, verification);
        await native(["fossil", "use", verification, "--json"], {
          profile,
          discard: true,
          maxBytes: Number.MAX_SAFE_INTEGER,
        });
        await native(["fossil", "verify", "--json"], {
          profile,
          discard: true,
          maxBytes: Number.MAX_SAFE_INTEGER,
        });
      } else
        await native(["fossil", "export", repository, "--json"], {
          discard: true,
          maxBytes: Number.MAX_SAFE_INTEGER,
        });
      const state = JSON.parse(
        (
          await run(config.fossil, [
            "cat",
            "authority/state.json",
            "-r",
            "omos-company",
            "-R",
            repository,
            "--case-sensitive",
            "on",
          ])
        ).stdout,
      );
      if (
        state.workspace !== config.workspace ||
        state.issuer !== descriptor.public_key ||
        state.epoch !== descriptor.epoch
      )
        reject("BackupSourceChanged");
      const payloadRepository = path.join(dataset, "repository.fossil");
      const temporaryRepository = path.join(
        operationRoot,
        ".repository-" + randomUUID(),
      );
      try {
        await fs.copyFile(
          repository,
          temporaryRepository,
          constants.COPYFILE_EXCL,
        );
        await fs.chmod(temporaryRepository, 0o600);
        const handle = await fs.open(temporaryRepository, constants.O_RDONLY);
        try {
          await handle.sync();
        } finally {
          await handle.close();
        }
        remaining();
        await fs.rename(temporaryRepository, payloadRepository);
      } finally {
        await fs.rm(temporaryRepository, { force: true });
      }
      const files = [
        {
          path: "repository.fossil",
          ...(await fileIdentity(payloadRepository)),
        },
      ];
      const save = async (relative, bytes) => {
        remaining();
        const target = path.join(dataset, relative);
        await fs.mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
        let previous;
        try {
          previous = await privateBytes(target, bytes.length);
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
        }
        if (previous) {
          try {
            if (
              previous.length !== bytes.length ||
              hash(previous) !== hash(bytes)
            )
              reject("BackupCandidateChanged");
          } finally {
            previous.fill(0);
          }
        } else {
          const temporary = path.join(operationRoot, ".key-" + randomUUID());
          const opened = await fs.open(temporary, "wx", 0o600);
          try {
            await opened.writeFile(bytes);
            await opened.sync();
          } finally {
            await opened.close();
          }
          try {
            remaining();
            await fs.rename(temporary, target);
          } finally {
            await fs.rm(temporary, { force: true });
          }
        }
        files.push({
          path: relative,
          sha256: hash(bytes),
          bytes: bytes.length,
        });
      };
      await save("authority/issuer.json", descriptorBytes);
      let seed;
      try {
        seed = await privateBytes(
          path.join(dataset, "authority", descriptor.seed_file),
          32,
        );
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
        seed = await privateBytes(
          path.join(authorityPath, descriptor.seed_file),
          32,
        );
      }
      try {
        if (publicKey(seed) !== descriptor.public_key)
          reject("InvalidBackupAuthority");
        await save("authority/" + descriptor.seed_file, seed);
      } finally {
        seed.fill(0);
      }
      for (const handle of config.client_key_handles) {
        let seed;
        try {
          seed = await privateBytes(
            path.join(dataset, "client-keys", handle + ".seed"),
            32,
          );
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
          seed = await privateBytes(
            path.join(config.profile, ".fx/company-keys", handle + ".seed"),
            32,
          );
        }
        try {
          const key = publicKey(seed);
          if (!state.grants?.some((grant) => grant.public_key === key))
            reject("BackupKeyOutsideCompany");
          await save("client-keys/" + handle + ".seed", seed);
        } finally {
          seed.fill(0);
        }
      }
      prepared = {
        version: "omos.company-backup-manifest/v1",
        workspace: config.workspace,
        operation,
        request_sha256: request,
        key_domain: currentDomain.id,
        created_ms: Date.now(),
        authority: { issuer: state.issuer, epoch: state.epoch },
        source: {
          accepted_revision: await sourceRevision(repository, "trunk"),
          control_revision: await sourceRevision(repository, "omos-company"),
        },
        tools: {
          runtime: await fileIdentity(config.runtime),
          fossil: await fileIdentity(config.fossil),
        },
        client_key_handles: [...config.client_key_handles],
        files,
        access_requirements: [
          "restic repository password",
          "compatible native runtime",
          "old host fencing before authority activation",
        ],
        excludes: [
          "provider credentials",
          "opaque provider replay",
          "unselected actor keys",
        ],
      };
      validateManifest(prepared);
      await writeJson(manifestPath, prepared, operationRoot);
    }
    await verifyDataset(dataset, prepared);
    for (const file of prepared.files) {
      await checkedPath(path.join(dataset, file.path), { privateLeaf: true });
      const actual = await fileIdentity(path.join(dataset, file.path));
      if (actual.sha256 !== file.sha256 || actual.bytes !== file.bytes)
        reject("BackupCandidateChanged");
    }
    backupEffectPending = true;
    try {
      await restic(
        [
          "backup",
          "--json",
          "--tag",
          "omos-company-backup",
          "--tag",
          "omos-workspace-" + config.workspace,
          "--tag",
          tag,
          dataset,
        ],
        { cwd: dataset, discard: true, maxBytes: Number.MAX_SAFE_INTEGER },
      );
    } catch (error) {
      error.outcome = "uncertain";
      if (error.code === "BackupCommandFailed") {
        error.code = "BackupOutcomeUncertain";
        error.message = "BackupOutcomeUncertain";
      }
      throw error;
    }
    const completed = await inventory({ operation, limit: 2 });
    if (completed.length !== 1) reject("BackupOutcomeUncertain");
    const receipt = {
      ...(await verifySnapshot(completed[0], request)),
      action: "create",
      replayed: false,
    };
    return finish(receipt);
  }
  async function inspect(snapshot) {
    if (!hex(snapshot)) reject("InvalidBackupSnapshot");
    const row = (await inventory({ snapshot }))[0];
    if (!row) reject("BackupSnapshotUnavailable");
    return verifySnapshot(row);
  }
  async function restore({ snapshot, directory }) {
    if (
      !hex(snapshot) ||
      typeof directory !== "string" ||
      !path.isAbsolute(directory) ||
      path.normalize(directory) !== directory ||
      directory === config.staging_root ||
      !inside(config.staging_root, directory)
    )
      reject("InvalidBackupRestoreDestination");
    await checkedPath(path.dirname(directory), {
      directory: true,
      privateLeaf: true,
    });
    const row = (await inventory({ snapshot }))[0];
    if (!row) reject("BackupSnapshotUnavailable");
    const receipt = await verifySnapshot(row);
    const { manifest } = await manifestFor(row);
    let retained = false;
    try {
      await fs.mkdir(directory, { mode: 0o700 });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      retained = true;
    }
    await checkedPath(directory, { directory: true, privateLeaf: true });
    const marker = path.join(directory, "restore.json");
    const intent = {
      version: "omos.company-restore/v1",
      workspace: config.workspace,
      snapshot,
      manifest_sha256: receipt.manifest_sha256,
    };
    if (retained) {
      let previous;
      try {
        previous = JSON.parse(await privateBytes(marker, 16384));
      } catch {
        reject("BackupRestoreDestinationExists");
      }
      if (JSON.stringify(previous) !== JSON.stringify(intent))
        reject("BackupOperationConflict");
    } else await writeJson(marker, intent);
    const root = snapshotRoot(row);
    const target = path.join(directory, "files");
    await fs.mkdir(target, { recursive: true, mode: 0o700 });
    await checkedPath(target, { directory: true, privateLeaf: true });
    await restic(["restore", snapshot, "--target", target]);
    const restored = path.join(
      target,
      root.slice(path.parse(root).root.length),
    );
    // Restic reproduces ancestors such as /tmp below its target. Their
    // original public modes do not belong in a private recovery candidate.
    let prefix = target;
    for (const part of [
      "",
      ...path.relative(target, restored).split(path.sep),
    ]) {
      prefix = path.join(prefix, part);
      const info = await fs.lstat(prefix);
      if (
        !info.isDirectory() ||
        info.isSymbolicLink() ||
        info.uid !== process.getuid()
      )
        reject("UnsafeBackupRestoreDirectory");
      await fs.chmod(prefix, 0o700);
    }
    await checkedPath(restored, { directory: true, privateLeaf: true });
    for (const file of manifest.files) {
      const location = path.join(restored, file.path);
      await checkedPath(location, { privateLeaf: true });
      const actual = await fileIdentity(location);
      if (actual.sha256 !== file.sha256 || actual.bytes !== file.bytes)
        reject("BackupContentChanged");
    }
    const profile = path.join(directory, "verification-profile");
    await fs.mkdir(profile, { recursive: true, mode: 0o700 });
    await checkedPath(profile, { directory: true, privateLeaf: true });
    const repository = path.join(restored, "repository.fossil");
    const verification = path.join(profile, "verification.fossil");
    remaining();
    await fs.copyFile(repository, verification);
    await native(["fossil", "use", verification, "--json"], {
      profile,
      discard: true,
      maxBytes: Number.MAX_SAFE_INTEGER,
    });
    const binding = JSON.parse(
      await privateBytes(path.join(profile, ".fx/omos-workspace.json"), 16384),
    );
    if (binding.workspace_id !== config.workspace)
      reject("BackupWorkspaceMismatch");
    await native(["fossil", "verify", "--json"], {
      profile,
      discard: true,
      maxBytes: Number.MAX_SAFE_INTEGER,
    });
    const result = {
      ...receipt,
      action: "restore",
      directory: restored,
      repository,
      restoration_verified: true,
      activation_required: true,
      old_host_fencing_required: true,
      authority_rotation_required: true,
    };
    await writeJson(path.join(directory, "receipt.json"), result);
    return result;
  }
  const close = () =>
    externalSignal?.removeEventListener("abort", forwardCancel);
  return {
    remaining,
    run,
    restic,
    native,
    inventory,
    initialize,
    create,
    inspect,
    restore,
    withLock,
    close,
  };
}
