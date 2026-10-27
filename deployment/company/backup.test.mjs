import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { watch } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import {
  loadBackupConfiguration,
  createBackupController,
} from "./backup-runtime.mjs";

async function fixture(t) {
  const root = await fs.realpath(
    await fs.mkdtemp(path.join(os.tmpdir(), "omos-backup-test-")),
  );
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  for (const dir of ["profile/.fx", "repository", "staging"])
    await fs.mkdir(path.join(root, dir), { recursive: true, mode: 0o700 });
  const workspace = "1".repeat(64);
  const source = path.join(root, "source.fossil");
  await fs.writeFile(source, "fixture", { mode: 0o600 });
  await fs.writeFile(
    path.join(root, "profile/.fx/omos-workspace.json"),
    JSON.stringify({ workspace_id: workspace, repository: source }),
    { mode: 0o600 },
  );
  const password = path.join(root, "password");
  await fs.writeFile(password, "fixture-backup-password-for-real-repository", {
    mode: 0o600,
  });
  const config = {
    version: "omos.company-backup/v1",
    workspace,
    profile: path.join(root, "profile"),
    runtime: await fs.realpath(process.execPath),
    fossil: await fs.realpath("/usr/bin/true"),
    restic: "/usr/bin/restic",
    repository: path.join(root, "repository"),
    password_file: password,
    staging_root: path.join(root, "staging"),
    timeout_ms: 30000,
  };
  const file = path.join(root, "configuration.json");
  await fs.writeFile(file, JSON.stringify(config), { mode: 0o600 });
  return { root, file, config: await loadBackupConfiguration(file), password };
}

test("backup configuration rejects exposed credentials, symlinked inputs and another workspace", async (t) => {
  const f = await fixture(t);
  await fs.chmod(f.password, 0o644);
  await assert.rejects(loadBackupConfiguration(f.file), {
    code: "BackupPermissionsUnsafe",
  });
  await fs.chmod(f.password, 0o600);
  await fs.rename(f.password, f.password + ".saved");
  await fs.symlink(f.password + ".saved", f.password);
  await assert.rejects(loadBackupConfiguration(f.file), {
    code: "UnsafeBackupPath",
  });
  await fs.rm(f.password);
  await fs.rename(f.password + ".saved", f.password);
  const config = JSON.parse(await fs.readFile(f.file, "utf8"));
  config.workspace = "2".repeat(64);
  await fs.writeFile(f.file, JSON.stringify(config));
  await assert.rejects(loadBackupConfiguration(f.file), {
    code: "BackupWorkspaceMismatch",
  });
});

test("a real encrypted backup repository initializes idempotently with its own key domain", async (t) => {
  const f = await fixture(t);
  const controller = createBackupController(f.config);
  t.after(() => controller.close());
  const first = await controller.withLock(() => controller.initialize());
  const second = await controller.withLock(() => controller.initialize());
  assert.deepEqual(second, first);
  assert.match(first.key_domain, /^[a-f0-9]{64}$/);
  const bytes = await fs.readFile(path.join(f.config.repository, "config"));
  assert.equal(bytes.includes(Buffer.from(first.key_domain)), false);
  assert.equal(bytes.includes(Buffer.from("fixture-backup-password")), false);
  const wrong = createBackupController({
    ...f.config,
    password_file: path.join(f.root, "wrong-password"),
  });
  t.after(() => wrong.close());
  await fs.writeFile(path.join(f.root, "wrong-password"), "incorrect", {
    mode: 0o600,
  });
  await assert.rejects(wrong.inventory(), { code: "BackupCommandFailed" });
});

test("backup operations serialize through a kernel lock and release it after completion", async (t) => {
  const f = await fixture(t);
  const first = createBackupController(f.config);
  const otherProfile = path.join(f.root, "other-profile");
  await fs.mkdir(otherProfile, { mode: 0o700 });
  const second = createBackupController({ ...f.config, profile: otherProfile });
  t.after(() => {
    first.close();
    second.close();
  });
  let entered, release;
  const ready = new Promise((resolve) => {
    entered = resolve;
  });
  const held = first.withLock(async () => {
    entered();
    await new Promise((resolve) => {
      release = resolve;
    });
  });
  await ready;
  await assert.rejects(
    second.withLock(async () =>
      assert.fail("A contending backup must not execute"),
    ),
    { code: "BackupBusy" },
  );
  release();
  await held;
  const third = createBackupController(f.config);
  t.after(() => third.close());
  assert.equal(await third.withLock(async () => "released"), "released");
});

test("backup subprocesses omit provider credentials and join an ignored cancellation", async (t) => {
  const f = await fixture(t);
  const cancellation = new AbortController();
  const controller = createBackupController(f.config, {
    signal: cancellation.signal,
  });
  t.after(() => controller.close());
  const original = process.env.ANTHROPIC_API_KEY;
  process.env.ANTHROPIC_API_KEY = "backup-fixture-secret";
  try {
    const result = await controller.run(process.execPath, [
      "-e",
      "console.log(process.env.ANTHROPIC_API_KEY ?? 'absent')",
    ]);
    assert.equal(result.stdout.toString().trim(), "absent");
  } finally {
    if (original === undefined) delete process.env.ANTHROPIC_API_KEY;
    else process.env.ANTHROPIC_API_KEY = original;
  }
  const started = new Promise((resolve, reject) => {
    const watcher = watch(f.root, (event, filename) => {
      if (filename === "started") {
        watcher.close();
        clearTimeout(timer);
        resolve();
      }
    });
    const timer = setTimeout(() => {
      watcher.close();
      reject(new Error("Child did not start"));
    }, 10000);
    t.after(() => {
      watcher.close();
      clearTimeout(timer);
    });
  });
  const running = controller.withLock(() =>
    controller.run(process.execPath, [
      "-e",
      "process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(process.argv[1],'ready');setInterval(()=>{},1000)",
      path.join(f.root, "started"),
    ]),
  );
  await started;
  cancellation.abort();
  const replacement = createBackupController(f.config);
  t.after(() => replacement.close());
  await assert.rejects(
    replacement.withLock(async () =>
      assert.fail("The terminating child still owns execution"),
    ),
    { code: "BackupBusy" },
  );
  await assert.rejects(running, { code: "BackupCancelled" });
  const resumed = createBackupController(f.config);
  t.after(() => resumed.close());
  assert.equal(await resumed.withLock(async () => "joined"), "joined");
});

test("the whole backup deadline releases a stalled operation's kernel lock", async (t) => {
  const f = await fixture(t);
  const controller = createBackupController({ ...f.config, timeout_ms: 1000 });
  t.after(() => controller.close());
  await assert.rejects(
    controller.withLock(() => new Promise(() => {})),
    { code: "BackupDeadline" },
  );
  const replacement = createBackupController(f.config);
  t.after(() => replacement.close());
  assert.equal(await replacement.withLock(async () => "resumed"), "resumed");
});

test(
  "recent backup metadata stays bounded across different candidate paths",
  { timeout: 60000 },
  async (t) => {
    const f = await fixture(t);
    const controller = createBackupController({
      ...f.config,
      timeout_ms: 60000,
    });
    t.after(() => controller.close());
    await controller.withLock(() => controller.initialize());
    for (const index of [0, 1]) {
      const directory = path.join(f.config.staging_root, "candidate-" + index);
      await fs.mkdir(directory, { mode: 0o700 });
      await fs.writeFile(path.join(directory, "data"), "metadata fixture", {
        mode: 0o600,
      });
      await controller.withLock(() =>
        controller.restic(
          [
            "backup",
            "--tag",
            "omos-company-backup",
            "--tag",
            "omos-workspace-" + f.config.workspace,
            "--tag",
            "omos-operation-page-" + index,
            directory,
          ],
          { discard: true },
        ),
      );
    }
    const recent = await controller.inventory({ limit: 1 });
    assert.equal(recent.length, 1);
    const first = await controller.inventory({ operation: "page-0", limit: 2 });
    assert.equal(first.length, 1);
    assert.equal(
      (await controller.inventory({ snapshot: first[0].id }))[0].id,
      first[0].id,
    );
  },
);

async function companyFixture(t) {
  const f = await fixture(t);
  const runtime = await fs.realpath(
    process.env.OMOS_BACKUP_NATIVE_BINARY ??
      fileURLToPath(new URL("../../zig-out/bin/fx", import.meta.url)),
  );
  const fossil = await fs.realpath("/usr/bin/fossil");
  const profile = f.config.profile;
  await fs.rm(path.join(profile, ".fx/omos-workspace.json"));
  const env = {
    PATH: "/usr/bin:/bin",
    LANG: "C.UTF-8",
    HOME: profile,
    FOSSIL_HOME: profile,
    OMOS_FOSSIL_BIN: fossil,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_CONTRACT_REVIEW: "1",
  };
  const invoke = async (args) =>
    JSON.parse(
      (
        await promisify(execFile)(runtime, args, {
          cwd: f.root,
          env,
          timeout: 60000,
          maxBuffer: 2 * 1024 * 1024,
        })
      ).stdout,
    );
  const ensured = await invoke(["fossil", "ensure", "--json"]);
  const admin = async (request) => {
    const file = path.join(f.root, "admin.json");
    await fs.writeFile(
      file,
      JSON.stringify({ version: "omos.company-admin/v1", ...request }),
      { mode: 0o600 },
    );
    return (await invoke(["fossil", "company", file, "--json"])).model_data;
  };
  const initialized = await admin({ action: "initialize" });
  const key = await invoke([
    "fossil",
    "company-key",
    "backup-reader",
    "--json",
  ]);
  await admin({
    action: "grant",
    revision: initialized.revision,
    grant: {
      id: "backup-reader",
      actor: "reader",
      public_key: (key.model_data ?? key).public_key,
      paths: ["documents/"],
      actions: ["discover"],
      expires_ms: Date.now() + 3600000,
    },
  });
  const raw = {
    ...JSON.parse(await fs.readFile(f.file, "utf8")),
    workspace: ensured.workspace_id,
    runtime,
    fossil,
    client_key_handles: ["backup-reader"],
    timeout_ms: 150000,
  };
  await fs.writeFile(f.file, JSON.stringify(raw));
  const config = await loadBackupConfiguration(f.file);
  return { ...f, profile, config };
}

test(
  "a company backup encrypts selected authority, replays one operation and restores a verified private candidate",
  { timeout: 180000 },
  async (t) => {
    const f = await companyFixture(t);
    const { config, profile } = f;
    const controller = createBackupController(config);
    t.after(() => controller.close());
    try {
      const command = async (args) => {
        const result = await promisify(execFile)(
          process.execPath,
          [
            fileURLToPath(new URL("./backup.mjs", import.meta.url)),
            ...args,
            "--config",
            f.file,
          ],
          { env: { PATH: "/usr/bin:/bin", HOME: profile }, timeout: 150000 },
        );
        assert.equal(result.stderr, "");
        return JSON.parse(result.stdout);
      };
      await command(["initialize"]);
      const created = await command(["create", "--operation", "native-backup"]);
      assert.equal(
        (await command(["inspect", "--snapshot", created.snapshot])).verified,
        true,
      );
      assert.equal(created.verified, true);
      assert.equal(created.files, 4);
      assert.equal(created.replayed, false);
      const replayed = await controller.withLock(() =>
        controller.create({ operation: "native-backup" }),
      );
      assert.equal(replayed.snapshot, created.snapshot);
      assert.equal(replayed.replayed, true);
      assert.equal((await controller.inventory()).length, 1);
      const recoveryProfile = path.join(f.root, "recovery-profile");
      await fs.mkdir(recoveryProfile, { mode: 0o700 });
      const recoveryFile = path.join(f.root, "recovery.json");
      const recoveryConfiguration = {
        ...JSON.parse(await fs.readFile(f.file, "utf8")),
        profile: recoveryProfile,
      };
      await fs.writeFile(recoveryFile, JSON.stringify(recoveryConfiguration), {
        mode: 0o600,
      });
      await fs.rename(profile, profile + ".offline");
      let restored;
      try {
        const recovery = createBackupController(
          await loadBackupConfiguration(recoveryFile, { requireSource: false }),
        );
        t.after(() => recovery.close());
        await assert.rejects(recovery.create({ operation: "no-source" }), {
          code: "BackupSourceUnavailable",
        });
        restored = await recovery.withLock(() =>
          recovery.restore({
            snapshot: created.snapshot,
            directory: path.join(config.staging_root, "restored"),
          }),
        );
        await assert.rejects(
          fs.access(path.join(recoveryProfile, ".fx/omos-workspace.json")),
        );
        // No old server runs in this fixture and its entire profile is offline.
        // Activation is a separate operator action on another repository copy.
        const activated = path.join(recoveryProfile, "activated.fossil");
        await fs.copyFile(restored.repository, activated);
        await recovery.native(["fossil", "use", activated, "--json"], {
          discard: true,
        });
        const administer = async (request) => {
          const file = path.join(recoveryProfile, "operator.json");
          await fs.writeFile(
            file,
            JSON.stringify({ version: "omos.company-admin/v1", ...request }),
            { mode: 0o600 },
          );
          return JSON.parse(
            (await recovery.native(["fossil", "company", file, "--json"]))
              .stdout,
          ).model_data;
        };
        const before = await administer({ action: "status" });
        const after = await administer({
          action: "rotate",
          revision: before.revision,
        });
        assert.equal(after.authority.epoch, before.authority.epoch + 1);
        assert.notEqual(after.authority.issuer, before.authority.issuer);
        assert.ok(after.authority.grants.every((grant) => grant.revoked));
      } finally {
        await fs.rename(profile + ".offline", profile);
      }
      assert.equal(restored.restoration_verified, true);
      assert.equal(restored.old_host_fencing_required, true);
      assert.equal(restored.authority_rotation_required, true);
      const row = (await controller.inventory())[0];
      const manifest = JSON.parse(
        (
          await controller.restic([
            "dump",
            row.id,
            path.join(row.paths[0], "manifest.json"),
          ])
        ).stdout,
      );
      assert.equal(
        createHash("sha256")
          .update(await fs.readFile(restored.repository))
          .digest("hex"),
        manifest.files.find((file) => file.path === "repository.fossil").sha256,
      );
      const bound = JSON.parse(
        await fs.readFile(
          path.join(profile, ".fx/omos-workspace.json"),
          "utf8",
        ),
      );
      assert.equal(bound.repository, config.source_repository);
      const issuer = JSON.parse(
        await fs.readFile(
          path.join(restored.directory, "authority/issuer.json"),
          "utf8",
        ),
      );
      const seed = await fs.readFile(
        path.join(profile, ".fx/authority", config.workspace, issuer.seed_file),
      );
      assert.deepEqual(
        await fs.readFile(
          path.join(restored.directory, "authority", issuer.seed_file),
        ),
        seed,
      );
      assert.deepEqual(
        await fs.readFile(
          path.join(restored.directory, "client-keys/backup-reader.seed"),
        ),
        await fs.readFile(
          path.join(profile, ".fx/company-keys/backup-reader.seed"),
        ),
      );
      const domain = createBackupController({
        ...config,
        workspace: "2".repeat(64),
      });
      t.after(() => domain.close());
      await assert.rejects(domain.inventory(), {
        code: "BackupDomainMismatch",
      });
      await assert.rejects(
        controller.withLock(() =>
          controller.restore({ snapshot: created.snapshot, directory: f.root }),
        ),
        { code: "InvalidBackupRestoreDestination" },
      );
    } catch (error) {
      if (error.diagnostic) error.message += "\n" + error.diagnostic;
      throw error;
    }
  },
);

async function resticBoundary(f, mode) {
  const marker = path.join(f.root, "backup-boundary.json");
  const wrapper = path.join(f.root, "restic-wrapper");
  await fs.writeFile(
    wrapper,
    `#!${process.execPath}
import fs from "node:fs";
import { spawn } from "node:child_process";
const args = process.argv.slice(2);
const boundary = args.includes("backup") && args.includes("omos-company-backup");
const marker = ${JSON.stringify(marker)};
if (boundary && ${JSON.stringify(mode)} === "before") {
  fs.writeFileSync(marker, JSON.stringify({ dataset: args.at(-1) }), { mode: 0o600 });
  setInterval(() => {}, 1000);
} else {
  const child = spawn("/usr/bin/restic", args, { stdio: "inherit" });
  child.once("error", () => process.exit(99));
  child.once("close", code => {
    if (boundary && code === 0 && !fs.existsSync(marker)) {
      fs.writeFileSync(marker, JSON.stringify({ dataset: args.at(-1) }), { mode: 0o600 });
      if (${JSON.stringify(mode)} === "lost-ack") process.exit(1);
    }
    process.exit(code ?? 98);
  });
}
`,
    { mode: 0o700 },
  );
  return { wrapper, marker };
}

async function waitForFile(t, root, file) {
  return new Promise((resolve, reject) => {
    const watcher = watch(root, async (_event, name) => {
      if (name !== path.basename(file)) return;
      try {
        const data = JSON.parse(await fs.readFile(file, "utf8"));
        finish();
        resolve(data);
      } catch {}
    });
    const timer = setTimeout(() => {
      finish();
      reject(new Error("Backup boundary was not reached"));
    }, 120000);
    function finish() {
      watcher.close();
      clearTimeout(timer);
    }
    t.after(finish);
    fs.readFile(file, "utf8")
      .then((data) => {
        finish();
        resolve(JSON.parse(data));
      })
      .catch(() => {});
  });
}

test(
  "an interrupted backup retains its exact candidate, rejects extra files and resumes without live authority keys",
  { timeout: 180000 },
  async (t) => {
    const f = await companyFixture(t);
    const boundary = await resticBoundary(f, "before");
    const cancellation = new AbortController();
    const controller = createBackupController(
      { ...f.config, restic: boundary.wrapper },
      { signal: cancellation.signal },
    );
    t.after(() => controller.close());
    await controller.withLock(() => controller.initialize());
    const ready = waitForFile(t, f.root, boundary.marker);
    const running = controller.withLock(() =>
      controller.create({ operation: "interrupted" }),
    );
    const failed = assert.rejects(
      running,
      (error) =>
        error.code === "BackupCancelled" && error.outcome === "uncertain",
    );
    const { dataset } = await ready;
    cancellation.abort();
    await failed;
    const manifestPath = path.join(dataset, "manifest.json");
    const bytes = await fs.readFile(manifestPath);
    const resumed = createBackupController(f.config);
    t.after(() => resumed.close());
    assert.equal((await resumed.inventory()).length, 0);
    const invalid = JSON.parse(bytes);
    invalid.files[0].path = "../escape";
    await fs.writeFile(manifestPath, JSON.stringify(invalid));
    await assert.rejects(
      resumed.withLock(() => resumed.create({ operation: "interrupted" })),
      { code: "InvalidBackupManifest" },
    );
    await fs.writeFile(manifestPath, bytes);
    await fs.writeFile(
      path.join(dataset, "provider-secret"),
      "must never be uploaded",
      { mode: 0o600 },
    );
    await assert.rejects(
      resumed.withLock(() => resumed.create({ operation: "interrupted" })),
      { code: "InvalidBackupTree" },
    );
    assert.equal((await resumed.inventory()).length, 0);
    await fs.rm(path.join(dataset, "provider-secret"));
    const authority = path.join(f.profile, ".fx/authority", f.config.workspace);
    await fs.rename(authority, authority + ".offline");
    let receipt;
    try {
      receipt = await resumed.withLock(() =>
        resumed.create({ operation: "interrupted" }),
      );
    } finally {
      await fs.rename(authority + ".offline", authority);
    }
    assert.equal(receipt.verified, true);
    assert.equal(
      receipt.manifest_sha256,
      createHash("sha256").update(bytes).digest("hex"),
    );
    assert.equal((await resumed.inventory()).length, 1);
    await assert.rejects(fs.access(dataset), { code: "ENOENT" });
  },
);

test(
  "a lost backup acknowledgement reconciles one encrypted snapshot and clears only the retained candidate",
  { timeout: 180000 },
  async (t) => {
    const f = await companyFixture(t);
    const boundary = await resticBoundary(f, "lost-ack");
    const controller = createBackupController({
      ...f.config,
      restic: boundary.wrapper,
    });
    t.after(() => controller.close());
    await controller.withLock(() => controller.initialize());
    await assert.rejects(
      controller.withLock(() => controller.create({ operation: "lost-ack" })),
      (error) =>
        error.code === "BackupOutcomeUncertain" &&
        error.outcome === "uncertain",
    );
    const { dataset } = JSON.parse(await fs.readFile(boundary.marker, "utf8"));
    const bytes = await fs.readFile(path.join(dataset, "manifest.json"));
    const rows = await controller.inventory({ operation: "lost-ack" });
    assert.equal(rows.length, 1);
    const receipt = await controller.withLock(() =>
      controller.create({ operation: "lost-ack" }),
    );
    assert.equal(receipt.replayed, true);
    assert.equal(receipt.snapshot, rows[0].id);
    assert.equal(
      receipt.manifest_sha256,
      createHash("sha256").update(bytes).digest("hex"),
    );
    assert.equal(
      (await controller.inventory({ operation: "lost-ack" })).length,
      1,
    );
    await assert.rejects(fs.access(dataset), { code: "ENOENT" });
    assert.equal((await fs.stat(f.config.source_repository)).isFile(), true);
    assert.equal(
      (
        await fs.stat(path.join(f.profile, ".fx/authority", f.config.workspace))
      ).isDirectory(),
      true,
    );
  },
);
