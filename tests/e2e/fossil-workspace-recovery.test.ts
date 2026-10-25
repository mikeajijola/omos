import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, readdirSync, symlinkSync, writeFileSync, appendFileSync, statSync, realpathSync, rmSync, copyFileSync, chmodSync, renameSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash, generateKeyPairSync, sign, verify, createPublicKey, createPrivateKey } from "node:crypto";
import { spawnSync } from "node:child_process";
import { cleanupFixtures, fixture, model, writeMemory } from "./fossil-workspace-helpers";
import { NativeClient } from "./workspace-ui-client.mjs";
import { TmuxSession, tmuxAvailable, terminalFixtureShell } from "./tmux-helpers";

afterEach(cleanupFixtures);

async function progressStream(url: string, envelope: object, controller = new AbortController()) {
  // Bun's keepalive option controls socket reuse during deliberate aborts.
  const response = await fetch(url + "/v1/company", { method: "POST", keepalive: false, headers: { "content-type": "application/json", accept: "text/event-stream", connection: "close" }, body: JSON.stringify(envelope), signal: controller.signal });
  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  return { response, close: async () => { controller.abort(); await reader.cancel().catch(() => {}); }, next: async (timeoutMs = 15000) => {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const end = buffered.indexOf("\n\n");
      if (end >= 0) {
        const text = buffered.slice(0, end); buffered = buffered.slice(end + 2);
        if (text.startsWith(":")) continue;
        const lines = text.split("\n");
        return { event: lines.find(line => line.startsWith("event: "))?.slice(7), id: lines.find(line => line.startsWith("id: "))?.slice(4), data: JSON.parse(lines.find(line => line.startsWith("data: "))!.slice(6)) };
      }
      let timer: ReturnType<typeof setTimeout> | undefined;
      const chunk = await Promise.race([reader.read(), new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => { controller.abort(); reject(Error("Progress stream did not produce its next event")); }, Math.max(1, deadline - Date.now()));
      })]).finally(() => clearTimeout(timer));
      if (chunk.done) throw Error("Progress stream closed before the expected event");
      buffered += decoder.decode(chunk.value, { stream: true });
      expect(buffered.length).toBeLessThanOrEqual(1024 * 1024);
    }
  } };
}

async function startWorkspaceService(f: ReturnType<typeof fixture>, writable = false, extra: Record<string, string | undefined> = {}) {
  const token = "isolated-workspace-service-token-for-fixtures";
  const child = Bun.spawn([join(import.meta.dir, "../../zig-out/bin/fx"), "fossil", "serve", "0", "--json", ...(writable ? ["--write"] : [])], {
    cwd: f.cwd, env: { ...process.env, ...f.env, ...extra, OMOS_WORKSPACE_TOKEN: token }, stdout: "pipe", stderr: "pipe",
  });
  const reader = child.stdout.getReader();
  let output = "";
  try {
    const deadline = Date.now() + 15000;
    while (!output.includes("\n")) {
      const chunk = await Promise.race([reader.read(), Bun.sleep(Math.max(1, deadline - Date.now())).then(() => { throw new Error("Workspace service did not become ready"); })]);
      if (chunk.done) throw new Error(`Service exited: ${await new Response(child.stderr).text()}`);
      output += new TextDecoder().decode(chunk.value);
    }
    const ready = JSON.parse(output.trim().split("\n")[0]);
    const url = `http://127.0.0.1:${ready.port}`;
    const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
    return { child, ready, url, headers, post: async (body: object) => {
      try {
        return await fetch(`${url}/v1/workspace`, { method: "POST", headers, body: JSON.stringify(body) });
      } catch (error) {
        const exitCode = child.exitCode;
        child.kill();
        await child.exited;
        throw new Error(`${error instanceof Error ? error.stack : error}\nService exit before cleanup: ${exitCode}\n${await new Response(child.stderr).text()}\n${existsSync(f.env.FX_TRACE_LOG) ? readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-16000) : ""}`);
      }
    } };
  } catch (error) {
    child.kill();
    await child.exited;
    throw error;
  } finally {
    reader.releaseLock();
  }
}

function commitFixtureAmendment(f: ReturnType<typeof fixture>, taskId: string, clarification: string) {
  const branch = `task/${taskId}`;
  const current = JSON.parse(f.fossil("cat", `tasks/${taskId}.json`, "-r", branch));
  const prior = structuredClone(current.definition);
  current.definition.version++;
  current.amendments.push(clarification);
  current.revision_pending = true;
  current.review_job = null;
  const tree = join(f.home, "committed-amendment"); mkdirSync(tree);
  const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
  const command = (...args: string[]) => {
    const result = spawnSync(existsSync(helper) ? helper : "fossil", ["--user", "omos", ...args], { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" }, encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
  };
  command("open", "--nosync", join(f.cwd, "omos.fossil"), branch);
  writeFileSync(join(tree, `tasks/${taskId}.json`), JSON.stringify(current));
  const amendment = JSON.stringify({ kind: "contract_amendment", task: taskId, contract_version: current.definition.version, value: { origin: "user", text: clarification, previous_contract: prior, revision_pending: true } });
  const history = join(tree, "history", taskId); mkdirSync(history, { recursive: true });
  writeFileSync(join(history, `${createHash("sha256").update(amendment).digest("hex")}.json`), amendment);
  command("addremove");
  command("commit", "--nosign", "--nosync", "-m", "Retain an authenticated amendment before its cache update");
  command("close");
}

async function companyMcp(config: string, home: string, script = join(import.meta.dir, "../../deployment/company/mcp.mjs")) {
  const child = Bun.spawn([process.env.OMOS_E2E_MCP_RUNTIME ?? process.execPath, script, config], {
    env: { ...process.env, HOME: home, OMOS_WORKSPACE_TOKEN: "owner-token-must-never-be-forwarded" }, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  });
  let next = 0;
  const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  const stderr = new Response(child.stderr).text();
  const pump = (async () => {
    const reader = child.stdout.getReader();
    let buffered = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffered += new TextDecoder().decode(value);
        while (buffered.includes("\n")) {
          const end = buffered.indexOf("\n"), line = JSON.parse(buffered.slice(0, end));
          buffered = buffered.slice(end + 1);
          const waiter = pending.get(line.id);
          pending.delete(line.id);
          waiter?.resolve(line);
        }
      }
    } finally {
      reader.releaseLock();
      for (const waiter of pending.values()) waiter.reject(new Error("Company MCP process closed"));
      pending.clear();
    }
  })();
  const rpc = async (method: string, params: object = {}) => {
    const id = ++next;
    let timer: ReturnType<typeof setTimeout>;
    const response = new Promise<any>((resolve, reject) => {
      timer = setTimeout(() => { pending.delete(id); reject(new Error(`Company MCP ${method} timed out`)); }, 45000);
      pending.set(id, { resolve, reject });
    });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    await child.stdin.flush();
    try { return await response; } finally { clearTimeout(timer!); }
  };
  return { child, rpc, stderr, lastId: () => next, notify: async (method: string, params: object) => { child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n"); await child.stdin.flush(); }, close: async () => { child.kill(); await child.exited; await pump; } };
}

// These fault, boundary, migration, and authority cases qualify the candidate without training it.
describe("portable Fossil workspace recovery", () => {
  test("passes a filesystem lifetime pin through captured commands and releases every descriptor after completion", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const sentinel = join(f.home, "inherited-pin-confirmed");
    let pin = "";
    const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
    const inspect = "import os,sys,pathlib\ntarget=os.stat(sys.argv[1])\nfound=False\nfor value in os.listdir('/dev/fd'):\n try: stat=os.fstat(int(value))\n except OSError: continue\n if (stat.st_dev,stat.st_ino)==(target.st_dev,target.st_ino): found=True\nif not found: sys.exit(7)\npathlib.Path(sys.argv[2]).write_text('confirmed')";
    const python = spawnSync("python3", ["-c", "import sys; print(sys.executable)"], { encoding: "utf8" }).stdout.trim();
    expect(existsSync(python)).toBe(true);
    model(f, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const view = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      pin = join(view, "..", ".pins", createHash("sha256").update(view).digest("hex") + ".lock");
      if (count === 1) return { tool_calls: [{ index: 0, id: "inherited-captured-pin", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", profile: "clean", command: `${quote(python)} -c ${quote(inspect)} ${quote(pin)} ${quote(sentinel)}`, timeout_ms: 10000 } }) } }] };
      expect(readFileSync(sentinel, "utf8")).toBe("confirmed");
      return { content: "The captured command inherited the workspace lifetime pin." };
    });
    const result = await f.run(["ask", "Inspect the workspace lifetime descriptor in a captured child", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    const probe = spawnSync(python, ["-c", "import fcntl,sys\nf=open(sys.argv[1],'r+')\nfcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)", pin], { encoding: "utf8" });
    expect(probe.status, probe.stderr).toBe(0);
  }, 90000);

  test.skipIf(!tmuxAvailable())("retains a completed task view while its terminal remains live and releases it after exit", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let view = "";
    const ready = join(f.home, "terminal-ready"), release = join(f.home, "terminal-release");
    const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
    const inspect = "import os,sys,pathlib\ntarget=os.stat(sys.argv[1])\nfound=False\nfor value in os.listdir('/dev/fd'):\n try: stat=os.fstat(int(value))\n except OSError: continue\n if (stat.st_dev,stat.st_ino)==(target.st_dev,target.st_ino): found=True\nif not found: sys.exit(7)\npathlib.Path(sys.argv[2]).write_text('ready')";
    const python = spawnSync("python3", ["-c", "import sys; print(sys.executable)"], { encoding: "utf8" }).stdout.trim();
    model(f, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      view = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      const inherited = join(view, "..", ".pins", createHash("sha256").update(view).digest("hex") + ".lock");
      if (count === 1) return { tool_calls: [{ index: 0, id: "retained-terminal", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", tty: true, profile: "clean", yield_time_ms: 100, command: `${quote(python)} -c ${quote(inspect)} ${quote(inherited)} ${quote(ready)} && while [ ! -f '${release}' ]; do sleep 0.05; done` } }) } }] };
      return { content: "Resource pin terminal started." };
    });
    const binary = join(import.meta.dir, "../../zig-out/bin/fx");
    const session = await TmuxSession.create({ isolated: true, cmd: binary, cwd: f.cwd, env: { ...f.env, SHELL: terminalFixtureShell() }, width: 120, height: 32 });
    const managerRoot = join(f.home, ".fx/fossil", createHash("sha256").update(join(f.cwd, "omos.fossil")).digest("hex"));
    const available = (path: string) => spawnSync("python3", ["-c", "import fcntl,sys\nf=open(sys.argv[1],'r+')\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(3)", path], { encoding: "utf8", timeout: 3000 }).status === 0;
    const until = async (predicate: () => boolean, message: string) => {
      const deadline = Date.now() + 15000;
      while (!predicate()) { if (Date.now() >= deadline) throw Error(message); await Bun.sleep(25); }
    };
    try {
      await session.waitForComposer(15000);
      await session.sendText("Start a terminal and leave it running while idle.");
      await session.waitForText("Resource pin terminal started.", 30000);
      await until(() => existsSync(ready), "Terminal did not execute its command");
      let task: any;
      const deadline = Date.now() + 20000;
      while (!task) {
        const result = await f.run(["fossil", "tasks", "--json"]);
        expect(result.code, result.stderr).toBe(0);
        task = JSON.parse(result.stdout).tasks.find((row: any) => row.state === "accepted");
        if (!task && Date.now() >= deadline) throw Error("Terminal task did not publish");
        if (!task) await Bun.sleep(100);
      }
      await until(() => available(join(managerRoot, `task-actor-${task.id}.lock`)), "Completed turn retained its execution lease");
      const pin = join(view, "..", ".pins", createHash("sha256").update(view).digest("hex") + ".lock");
      expect(existsSync(pin)).toBe(true);
      expect(available(pin)).toBe(false);
      writeFileSync(release, "finish");
      await until(() => available(pin), "Exited terminal retained its filesystem pin");
    } finally { writeFileSync(release, "finish"); await session.kill(); }
  }, 120000);

  test("resumes an owned legacy filesystem view without discarding its uncommitted draft", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let root = "", resumedRoot = "";
    model(f, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const current = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      if (count === 1) {
        root = current;
        return { tool_calls: [{ index: 0, id: "legacy-draft", type: "function", function: { name: "write_file", arguments: JSON.stringify({ path: join(root, "documents/draft.txt"), content: "Checkpointed original" }) } }] };
      }
      resumedRoot = current;
      expect(readFileSync(join(current, "documents/draft.txt"), "utf8")).toBe("Uncommitted legacy draft");
      return { content: "Retained the legacy draft and published it." };
    });
    const first = await f.run(["ask", "Retain a portable draft", "--json"], { FX_MAX_AGENT_STEPS: "1" });
    expect(first.code).toBe(1);
    expect(existsSync(join(root, "documents/draft.txt"))).toBe(true);
    const status = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
    const task = status.tasks[0];
    const legacy = join(root, "..", task.id);
    const manager = join(f.home, ".fx/fossil", createHash("sha256").update(status.repository).digest("hex"));
    const baseline = (view: string) => join(manager, "projections", createHash("sha256").update(view).digest("hex") + ".json");
    renameSync(root, legacy);
    renameSync(baseline(root), baseline(legacy));
    rmSync(join(root, "..", ".pins", createHash("sha256").update(root).digest("hex") + ".lock"));
    writeFileSync(join(legacy, "documents/draft.txt"), "Uncommitted legacy draft");
    const result = await f.run(["ask", "--resume-id", JSON.parse(first.stdout).session_id, "continue", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(resumedRoot).toBe(legacy);
    expect(f.fossil("cat", "documents/draft.txt", "-r", "trunk")).toBe("Uncommitted legacy draft");
  }, 120000);

  test("prunes only clean accepted views and preserves drafts, execution caches, and live resources", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const roots: string[] = [];
    model(f, (body, count) => {
      const text = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(text.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      if (count % 2 === 1) {
        const index = roots.push(root) - 1;
        return { tool_calls: [{ index: 0, id: `cache-view-${index}`, type: "function", function: { name: "write_file", arguments: JSON.stringify({ path: join(root, `documents/item-${index}.txt`), content: `Canonical content ${index}` }) } }] };
      }
      return { content: "The document is checkpointed." };
    });
    for (let index = 0; index < 3; index++) {
      const result = await f.run(["ask", `Save document ${index}`, "--json"]);
      expect(result.code, result.stderr).toBe(0);
    }
    writeFileSync(join(roots[1], "documents/item-1.txt"), "Uncommitted private draft");
    mkdirSync(join(roots[2], "node_modules"));
    writeFileSync(join(roots[2], "node_modules/private.txt"), "Do not silently evict this");
    const pin = join(roots[0], "..", ".pins", createHash("sha256").update(roots[0]).digest("hex") + ".lock");
    const holder = Bun.spawn(["python3", "-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_SH); print('ready',flush=True); sys.stdin.read()", pin], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    try {
      const reader = holder.stdout.getReader();
      expect(new TextDecoder().decode((await reader.read()).value)).toContain("ready");
      reader.releaseLock();
      const held = await f.run(["fossil", "cache", "prune", "--json"]);
      expect(held.code, held.stderr).toBe(0);
      const report = JSON.parse(held.stdout).model_data;
      expect(report.removed).toBe(0);
      expect(report.entries.find((entry: any) => entry.path === roots[0]).state).toBe("live_resource");
      expect(roots.every(existsSync)).toBe(true);
    } finally { holder.stdin.end(); await holder.exited; }
    const pruned = await f.run(["fossil", "cache", "prune", "--json"]);
    expect(pruned.code, pruned.stderr).toBe(0);
    const report = JSON.parse(pruned.stdout).model_data;
    expect(report.removed).toBe(1);
    expect(report.reclaimed_bytes).toBe("Canonical content 0".length);
    expect(existsSync(roots[0])).toBe(false);
    expect(readFileSync(join(roots[1], "documents/item-1.txt"), "utf8")).toBe("Uncommitted private draft");
    expect(readFileSync(join(roots[2], "node_modules/private.txt"), "utf8")).toBe("Do not silently evict this");
    expect(f.fossil("cat", "documents/item-0.txt", "-r", "trunk")).toBe("Canonical content 0");
    expect(existsSync(pin)).toBe(true);
    const declaration = join(f.home, "cache-definition.json"), policy = join(f.home, "cache-policy.json");
    writeFileSync(declaration, f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    const execution = JSON.parse(f.fossil("cat", "execution/omos.json", "-r", "trunk"));
    execution.projections = { max_clean_views: 1, max_clean_bytes: 268435456 };
    writeFileSync(policy, JSON.stringify(execution));
    const proposed = await f.run(["fossil", "definition", "propose", declaration, "--execution", policy, "--json"]);
    expect(proposed.code, proposed.stderr).toBe(0);
    const fresh = await f.run(["ask", "Save a document for automatic cleanup", "--json"]);
    expect(fresh.code, fresh.stderr).toBe(0);
    const newest = await f.run(["ask", "Save the newest clean cached document", "--json"]);
    expect(newest.code, newest.stderr).toBe(0);
    expect(roots).toHaveLength(5);
    const service = await startWorkspaceService(f, true);
    try {
      const deadline = Date.now() + 20000;
      while (existsSync(roots[3])) {
        if (Date.now() > deadline) throw Error("Background policy did not collect the clean view");
        await Bun.sleep(50);
      }
      expect(readFileSync(join(roots[1], "documents/item-1.txt"), "utf8")).toBe("Uncommitted private draft");
      expect(existsSync(roots[2])).toBe(true);
      expect(existsSync(roots[4])).toBe(true);
    } finally { service.child.kill(); await service.child.exited; }
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
  }, 180000);

  test("reuses verified canonical objects across sparse views and rebuilds after corruption or cache loss", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const roots: string[] = [];
    const content = "Shared immutable projection content";
    model(f, (body, count) => {
      const text = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(text.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      if (count === 1) return { tool_calls: [{ index: 0, id: "seed-shared-content", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "documents/shared.txt", content }) } }] };
      if (count % 2 === 0) {
        roots.push(root);
        return { tool_calls: [{ index: 0, id: `shared-read-${count}`, type: "function", function: { name: "read_file", arguments: JSON.stringify({ path: join(root, "documents/shared.txt") }) } }] };
      }
      expect(readFileSync(join(root, "documents/shared.txt"), "utf8")).toBe(content);
      return { content: "Read verified portable content." };
    });
    const read = async () => {
      const result = await f.run(["ask", "Read the shared portable document", "--json"]);
      expect(result.code, result.stderr).toBe(0);
    };
    await read();
    const cache = join(f.home, ".fx/cache/company-objects");
    const objects = () => readdirSync(cache).filter(name => name.length === 129);
    const first = objects();
    expect(first).toHaveLength(1);
    const initialHits = readFileSync(f.env.FX_TRACE_LOG, "utf8").split("projection object cache hit").length;
    await read();
    expect(objects()).toEqual(first);
    expect(readFileSync(f.env.FX_TRACE_LOG, "utf8").split("projection object cache hit").length).toBeGreaterThan(initialHits);
    expect(roots[0]).not.toBe(roots[1]);
    expect(statSync(join(roots[0], "documents/shared.txt")).ino).not.toBe(statSync(join(roots[1], "documents/shared.txt")).ino);
    expect(statSync(join(cache, first[0])).ino).not.toBe(statSync(join(roots[0], "documents/shared.txt")).ino);
    writeFileSync(join(cache, first[0]), "Corrupt shared cache content");
    await read();
    expect(readFileSync(join(cache, first[0]), "utf8")).toBe(content);
    rmSync(cache, { recursive: true });
    await read();
    expect(objects()).toHaveLength(1);
    expect(roots).toHaveLength(4);
    expect(f.fossil("cat", "documents/shared.txt", "-r", "trunk")).toBe(content);
  }, 180000);

  test("plans declared capability packages with transitive requirements, missing files, and explicit runtime handles", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = JSON.parse(f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    declaration.spec.capabilities.push({ id: "cv_builder", name: "Versioned CV builder", requires: [{ id: "cv_package", primitiveFamily: "skills" }], realisations: ["cv_builder_skill"] });
    declaration.spec.resources.skills.push({ id: "versioned_cv_package", name: "Portable CV package", offers: ["cv_package"], spec: { implementation: "fossil_skill", portability: { version: "omos.resource-portability/v1", paths: ["skills/cv-builder/"], dependencies: [{ kind: "runtime", handle: "node", constraint: ">=22" }] } } });
    declaration.spec.realisations.push({ id: "cv_builder_skill", name: "Versioned CV skill", capability: "cv_builder", participants: [{ resource: "versioned_cv_package", supplies: ["cv_package"] }] });
    declaration.spec.semantic.capabilityHierarchy = [{ capability: "cv_builder", dependsOn: ["general_task"] }];
    const definition = join(f.home, "package-definition.json");
    writeFileSync(definition, JSON.stringify(declaration));
    const proposed = await f.run(["fossil", "definition", "propose", definition, "--json"]);
    expect(proposed.code, proposed.stderr).toBe(0);
    const missing = await f.run(["fossil", "package", "plan", "cv_builder", "--json"]);
    expect(missing.code, missing.stderr).toBe(0);
    const initial = JSON.parse(missing.stdout).model_data;
    expect(initial.plan.declaration_complete).toBe(false);
    expect(initial.plan.problems.some((problem: any) => problem.reason === "required_path_missing:skills/cv-builder/")).toBe(true);
    model(f, (_body, count) => {
      if (count === 1) return { tool_calls: [
        { path: "skills/cv-builder/SKILL.md", content: "# Portable CV builder\nUse node career.mjs.\n" },
        { path: "skills/cv-builder/career.mjs", content: "console.log('Portable fixture');\n" },
      ].map((args, index) => ({ index, id: `package-file-${index}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", ...args }) } })) };
      return { content: "Retained the complete declared fixture package." };
    });
    const saved = await f.run(["ask", "Save the portable skill fixture", "--json"]);
    expect(saved.code, saved.stderr).toBe(0);
    const result = await f.run(["fossil", "package", "plan", "cv_builder", "--realisation", "cv_builder_skill", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    const snapshot = JSON.parse(result.stdout).model_data;
    expect(snapshot.revision).not.toBe(initial.revision);
    expect(snapshot.plan.declaration_complete).toBe(true);
    expect(snapshot.plan.runtime_verification).toBe("required");
    expect(snapshot.plan.capabilities.map((row: any) => row.id).sort()).toEqual(["cv_builder", "general_task"]);
    expect(snapshot.plan.files.map((row: any) => row.path).sort()).toEqual(["skills/cv-builder/SKILL.md", "skills/cv-builder/career.mjs"]);
    expect(snapshot.plan.external_dependencies.some((row: any) => row.dependency.kind === "runtime" && row.dependency.handle === "node" && row.dependency.constraint === ">=22")).toBe(true);
    for (const file of snapshot.plan.files) {
      const bytes = Buffer.from(f.fossil("cat", file.path, "-r", snapshot.revision));
      expect(createHash(file.artifact.length === 40 ? "sha1" : "sha3-256").update(bytes).digest("hex")).toBe(file.artifact);
    }
  }, 180000);

  test("exports selected capability closure with signed metadata, explicit dependency choices, and offline integrity", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = JSON.parse(f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    declaration.spec.capabilities.push(
      { id: "portable_cv", name: "Portable CV", requires: [{ id: "cv", primitiveFamily: "skills" }], realisations: ["portable_cv_skill"] },
      { id: "package_support", name: "Package support", requires: [{ id: "retained_workspace", primitiveFamily: "memory" }], realisations: ["support_primary", "support_alternative"] },
    );
    declaration.spec.resources.skills.push({ id: "cv_package", name: "CV package", offers: ["cv"], spec: { documentation: "Declared portable input. ".repeat(900), implementation: "fossil_skill", portability: { version: "omos.resource-portability/v1", paths: ["skills/cv-builder/"], dependencies: [{ kind: "runtime", handle: "node", constraint: ">=22" }] } } });
    declaration.spec.realisations.push(
      { id: "portable_cv_skill", name: "Portable CV skill", capability: "portable_cv", participants: [{ resource: "cv_package", supplies: ["cv"] }] },
      ...["support_primary", "support_alternative"].map(id => ({ id, name: id, capability: "package_support", participants: [{ resource: "fossil_workspace", supplies: ["retained_workspace"] }] })),
    );
    declaration.spec.semantic.capabilityHierarchy = [{ capability: "portable_cv", dependsOn: ["general_task", "package_support"] }];
    const definition = join(f.home, "definition.json"); writeFileSync(definition, JSON.stringify(declaration));
    const proposed = await f.run(["fossil", "definition", "propose", definition, "--json"]);
    expect(proposed.code, proposed.stderr).toBe(0);
    const skill = "# Portable CV fixture\n" + "Use versioned career inputs.\n".repeat(900);
    model(f, (_body, count) => count === 1 ? { tool_calls: [
      { path: "skills/cv-builder/SKILL.md", content: skill },
      { path: "skills/cv-builder/career.mjs", content: "console.log('portable fixture');\n" },
      { path: "documents/unrelated.txt", content: "Outside the selected capability" },
    ].map((args, index) => ({ index, id: `closure-${index}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", ...args }) } })) } : { content: "Saved the portable fixture and unrelated document." });
    const saved = await f.run(["ask", "Save the declared package inputs", "--json"]);
    expect(saved.code, saved.stderr).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0); return JSON.parse(result.stdout).model_data;
    };
    const identity = JSON.parse((await f.run(["fossil", "company-key", "reader", "--json"])).stdout);
    let state = await admin({ action: "initialize" });
    for (const [id, paths] of [["full-package", ["skills/", "documents/"]], ["partial-package", ["skills/cv-builder/SKILL.md"]]] as const) state = await admin({ action: "grant", revision: state.revision, grant: { id, actor: "reader", public_key: identity.public_key, paths, actions: ["discover", "export_scope"], expires_ms: Date.now() + 3600000 } });
    state = await admin({ action: "grant_capabilities", revision: state.revision, id: "full-package", capabilities: ["portable_cv", "general_task"] });
    const service = await startWorkspaceService(f, false);
    try {
      const boot = await (await fetch(service.url + "/v1/company", { keepalive: false })).json() as any;
      expect(boot.features.capability_packages).toBe(true);
      const config = { version: "omos.scope-export-request/v2", endpoint: service.url, workspace: boot.workspace, actor: "reader", grant: "full-package", key_handle: "reader", issuer: boot.issuer, revision: boot.revision, selections: [{ capability: "portable_cv" }, { capability: "package_support", realisation: "support_alternative" }] };
      const input = join(f.home, "package-pins.json"), output = join(f.home, "capability.tar");
      writeFileSync(input, JSON.stringify(config));
      expect((await f.run(["fossil", "export-scope", input, output, "--json"])).code).toBe(1);
      expect(existsSync(output)).toBe(false);
      state = await admin({ action: "grant_capabilities", revision: state.revision, id: "full-package", capabilities: ["portable_cv", "general_task", "package_support"] });
      state = await admin({ action: "grant_capabilities", revision: state.revision, id: "partial-package", capabilities: ["portable_cv", "general_task", "package_support"] });
      writeFileSync(input, JSON.stringify({ ...config, selections: [{ capability: "portable_cv" }] }));
      const ambiguous = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(ambiguous.code).toBe(1); expect(existsSync(output)).toBe(false);
      writeFileSync(input, JSON.stringify({ ...config, grant: "partial-package" }));
      expect((await f.run(["fossil", "export-scope", input, output, "--json"])).code).toBe(1);
      expect(existsSync(output)).toBe(false);
      writeFileSync(input, JSON.stringify(config));
      const exported = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(exported.code, exported.stderr + exported.stdout).toBe(0);
      expect(JSON.parse(exported.stdout)).toMatchObject({ version: "omos.scope-package/v3", files: 2, scope: "selected_capabilities", dependency_closure: "declared_complete" });
      const archive = readFileSync(output), objects = new Map<string, Buffer>();
      for (let at = 0; at + 512 <= archive.length && archive[at] !== 0;) {
        const header = archive.subarray(at, at + 512), name = header.subarray(0, 100).toString().split("\0")[0];
        const size = parseInt(header.subarray(124, 136).toString().replace(/\0/g, "").trim(), 8);
        objects.set(name, archive.subarray(at + 512, at + 512 + size)); at += 512 + Math.ceil(size / 512) * 512;
      }
      const manifest = JSON.parse(objects.get("manifest.json")!.toString()), plan = JSON.parse(manifest.capability_plan);
      expect(manifest.capability_receipts.length).toBeGreaterThan(1);
      expect(plan.capabilities.map((row: any) => row.id).sort()).toEqual(["general_task", "package_support", "portable_cv"]);
      expect(plan.realisations.map((row: any) => row.id)).toContain("support_alternative");
      expect(plan.realisations.map((row: any) => row.id)).not.toContain("support_primary");
      expect(plan.runtime_verification).toBe("required");
      expect(manifest.files.map((row: any) => row.path).sort()).toEqual(["skills/cv-builder/SKILL.md", "skills/cv-builder/career.mjs"]);
      expect(objects.get(`objects/${manifest.files.find((row: any) => row.path.endsWith("SKILL.md")).sha256}`)!.toString()).toBe(skill);
      const offline = fixture(), pins = join(offline.home, "pins.json"), copy = join(offline.home, "package.tar");
      writeFileSync(pins, JSON.stringify({ ...config, endpoint: "http://127.0.0.1:1" })); writeFileSync(copy, archive);
      const verified = await offline.run(["fossil", "verify-scope", pins, copy, "--json"]);
      expect(verified.code, verified.stderr).toBe(0);
      expect(JSON.parse(verified.stdout)).toMatchObject({ version: "omos.scope-package/v3", files: 2, dependency_closure: "declared_complete" });
      expect(existsSync(join(offline.home, ".fx/omos-workspace.json"))).toBe(false);
      expect((await offline.run(["fossil", "init", "--json"])).code).toBe(0);
      const beforeImport = JSON.parse((await offline.run(["fossil", "status", "--json"])).stdout).trunk_revision;
      const imported = await offline.run(["fossil", "package", "import", pins, copy, "--json"]);
      expect(imported.code, imported.stderr + imported.stdout).toBe(0);
      const staged = JSON.parse(imported.stdout).model_data;
      expect(staged).toMatchObject({ version: "omos.capability-import/v1", source_workspace: config.workspace, source_revision: config.revision, state: "paused", publication: "pending", runtime_verification: "required", files: 2 });
      expect(offline.fossil("cat", "skills/cv-builder/SKILL.md", "-r", `task/${staged.task}`)).toBe(skill);
      const candidate = JSON.parse(offline.fossil("cat", staged.declaration, "-r", `task/${staged.task}`));
      expect(candidate.spec.capabilities.find((row: any) => row.id === "package_support").realisations).toEqual(["support_alternative"]);
      expect(candidate.spec.semantic.capabilityHierarchy.find((row: any) => row.capability === "portable_cv").dependsOn).toEqual(["general_task", "package_support"]);
      expect(JSON.parse(offline.fossil("cat", "omniform/company.json", "-r", "trunk")).spec.capabilities.some((row: any) => row.id === "portable_cv")).toBe(false);
      const retainedTask = JSON.parse(offline.fossil("cat", `tasks/${staged.task}.json`, "-r", `task/${staged.task}`));
      expect(retainedTask.definition.obligations.map((row: any) => row.id)).toContain("package_runtime");
      const replay = await offline.run(["fossil", "package", "import", pins, copy, "--json"]);
      expect(replay.code, replay.stderr).toBe(0);
      expect(JSON.parse(replay.stdout).model_data.task).toBe(staged.task);
      expect(JSON.parse(replay.stdout).model_data.revision).toBe(staged.revision);
      expect(JSON.parse((await offline.run(["fossil", "status", "--json"])).stdout).trunk_revision).toBe(beforeImport);
      const verifiedCopy = join(offline.home, "retained-import.fossil");
      const portable = await offline.run(["fossil", "export", verifiedCopy, "--json"]);
      expect(portable.code, portable.stderr).toBe(0);
      expect((await offline.run(["fossil", "verify", "--json"])).code).toBe(0);
      const restored = fixture();
      copyFileSync(verifiedCopy, join(restored.cwd, "omos.fossil"));
      expect((await restored.run(["fossil", "use", join(restored.cwd, "omos.fossil"), "--json"])).code).toBe(0);
      const restoredImport = await restored.run(["fossil", "package", "import", pins, copy, "--json"]);
      expect(restoredImport.code, restoredImport.stderr).toBe(0);
      expect(JSON.parse(restoredImport.stdout).model_data.task).toBe(staged.task);
      expect(JSON.parse(restoredImport.stdout).model_data.revision).toBe(staged.revision);
      for (const point of ["capability-import-files", "capability-import-retained"]) {
        const interrupted = fixture();
        expect((await interrupted.run(["fossil", "init", "--json"])).code).toBe(0);
        const stopped = await interrupted.run(["fossil", "package", "import", pins, copy, "--json"], { FX_E2E_FOSSIL_FAULT: point });
        expect(stopped.code).toBe(1); expect(stopped.stderr).toContain("WorkspaceInjectedFailure");
        const pending = JSON.parse((await interrupted.run(["fossil", "tasks", "--json"])).stdout).tasks;
        expect(pending).toHaveLength(1);
        const resumed = await interrupted.run(["fossil", "package", "import", pins, copy, "--json"]);
        expect(resumed.code, resumed.stderr).toBe(0);
        expect(JSON.parse(resumed.stdout).model_data.task).toBe(pending[0].id);
        const canonical = JSON.parse(interrupted.fossil("cat", `tasks/${pending[0].id}.json`, "-r", `task/${pending[0].id}`));
        expect(canonical.state).toBe("paused");
      }
      const conflicting = fixture();
      expect((await conflicting.run(["fossil", "init", "--json"])).code).toBe(0);
      model(conflicting, (_body, count) => count === 1 ? { tool_calls: [{ index: 0, id: "local-skill", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "skills/cv-builder/SKILL.md", content: "Existing local skill" }) } }] } : { content: "Preserved the local skill." });
      expect((await conflicting.run(["ask", "Retain the existing local skill", "--json"])).code).toBe(0);
      const conflictBase = JSON.parse((await conflicting.run(["fossil", "status", "--json"])).stdout).trunk_revision;
      const conflict = await conflicting.run(["fossil", "package", "import", pins, copy, "--json"]);
      expect(conflict.code).toBe(1); expect(conflict.stderr).toContain("CapabilityImportCollision");
      expect(JSON.parse((await conflicting.run(["fossil", "status", "--json"])).stdout).trunk_revision).toBe(conflictBase);
      expect(conflicting.fossil("cat", "skills/cv-builder/SKILL.md", "-r", "trunk")).toBe("Existing local skill");
      const repack = (changed: any) => {
        const entries = [...objects].map(([name, bytes]) => [name, (name === "manifest.json" ? Buffer.from(JSON.stringify(changed)) : bytes).toString("base64")]);
        const result = spawnSync("python3", ["-c", "import base64,io,json,sys,tarfile\nv=json.load(sys.stdin); out=io.BytesIO(); expected=1024\nwith tarfile.open(fileobj=out,mode='w',format=tarfile.USTAR_FORMAT) as a:\n for n,b in v:\n  d=base64.b64decode(b); i=tarfile.TarInfo(n); i.size=len(d); a.addfile(i,io.BytesIO(d)); expected+=512+((len(d)+511)//512)*512\nsys.stdout.buffer.write(out.getvalue()[:expected])\n"], { input: JSON.stringify(entries), maxBuffer: archive.length * 2 });
        expect(result.status, result.stderr.toString()).toBe(0); writeFileSync(copy, result.stdout);
      };
      for (const mutate of [
        (value: any) => { value.capability_receipts.pop(); },
        (value: any) => { const altered = JSON.parse(value.capability_plan); altered.external_dependencies = []; value.capability_plan = JSON.stringify(altered); },
        (value: any) => { value.files.pop(); },
        (value: any) => { value.inventory_receipts[0].receipt.signature = "00".repeat(64); },
      ]) {
        const changed = structuredClone(manifest); mutate(changed); repack(changed);
        expect((await offline.run(["fossil", "verify-scope", pins, copy, "--json"])).code).toBe(1);
      }
      writeFileSync(copy, archive); writeFileSync(pins, JSON.stringify({ ...config, selections: [{ capability: "portable_cv" }, { capability: "package_support", realisation: "support_primary" }] }));
      expect((await offline.run(["fossil", "verify-scope", pins, copy, "--json"])).code).toBe(1);
      const missingRuntime = await offline.run(["fossil", "package", "verify", staged.task, "--json"]);
      expect(missingRuntime.code, missingRuntime.stderr).toBe(0);
      expect(JSON.parse(missingRuntime.stdout).model_data.verified).toBe(false);
      const beforeRuntime = JSON.parse((await offline.run(["fossil", "status", "--json"])).stdout).trunk_revision;
      const installedNode = realpathSync(Bun.which("node")!);
      const node = join(offline.home, "verified-node"); copyFileSync(installedNode, node); chmodSync(node, 0o700);
      const bindings = join(offline.home, "runtime-bindings.json");
      writeFileSync(bindings, JSON.stringify({ version: "omos.runtime-handles/v1", handles: [{ handle: "node", kind: "node", executable: node }] }));
      const checked = await offline.run(["fossil", "package", "verify", staged.task, "--bindings", bindings, "--json"], { NODE_OPTIONS: "--this-must-not-reach-the-probe" });
      expect(checked.code, checked.stderr).toBe(0);
      const verifiedRuntime = JSON.parse(checked.stdout).model_data;
      expect(verifiedRuntime.verified, JSON.stringify(verifiedRuntime.requirements)).toBe(true);
      const observed = verifiedRuntime.requirements.find((row: any) => row.kind === "runtime");
      expect(observed).toMatchObject({ handle: "node", constraint: ">=22", verified: true });
      expect(observed.probe.executable_sha256).toBe(createHash("sha256").update(readFileSync(node)).digest("hex"));
      const proof = JSON.parse(offline.fossil("cat", verifiedRuntime.receipt, "-r", `task/${staged.task}`));
      expect(JSON.stringify(proof)).not.toContain(node);
      const proofKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(proof.host, "hex")]), type: "spki", format: "der" });
      expect(verify(null, Buffer.from(proof.payload), proofKey, Buffer.from(proof.signature, "hex"))).toBe(true);
      expect(statSync(join(offline.home, ".fx/runtimes/handles.json")).mode & 0o777).toBe(0o600);
      const checkedAgain = await offline.run(["fossil", "package", "verify", staged.task, "--json"]);
      expect(checkedAgain.code, checkedAgain.stderr).toBe(0);
      expect(JSON.parse(checkedAgain.stdout).model_data.revision).toBe(verifiedRuntime.revision);
      expect(JSON.parse((await offline.run(["fossil", "status", "--json"])).stdout).trunk_revision).toBe(beforeRuntime);
      let phase = "start", searched = false, verifiedInTurn = false;
      const availability: string[] = [];
      model(offline, (body) => {
        if (phase === "publish" && !verifiedInTurn) { verifiedInTurn = true; return { tool_calls: [{ index: 0, id: "verify-current-runtime", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "verify_runtime" }) } }] }; }
        if (phase === "search" && !searched) { searched = true; return { tool_calls: [{ index: 0, id: "imported-capability", type: "function", function: { name: "capability_search", arguments: JSON.stringify({ query: "portable_cv" }) } }] }; }
        if (phase === "publish" && verifiedInTurn) {
          const last = body.messages.filter((message: any) => message.role === "tool").at(-1);
          expect(last && /"verified"\s*:\s*true/.test(typeof last.content === "string" ? last.content : JSON.stringify(last.content)), JSON.stringify(last)).toBe(true);
        }
        if (phase === "search") for (const message of body.messages) if (message.role === "tool" && typeof message.content === "string" && message.content.includes("workspace_capabilities")) availability.push(message.content);
        return { content: "Retained the capability package and its verified runtime evidence." };
      });
      const session = await offline.run(["ask", "Start the package verification session", "--json"]);
      expect(session.code, session.stderr).toBe(0);
      const sessionId = JSON.parse(session.stdout).session_id;
      const native = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: offline.cwd, env: { ...process.env, ...offline.env } });
      const runtimeEvents: any[] = []; native.on("event", (event: any) => runtimeEvents.push(event));
      try {
        await native.request("initialize");
        await native.request("task.resume", { revision: verifiedRuntime.revision, task: staged.task, session: sessionId });
        const turn = crypto.randomUUID();
        const ended = new Promise<any>((resolve, reject) => {
          const timer = setTimeout(() => reject(Error("Imported capability publication did not finish")), 90000);
          native.on("event", (event: any) => { if (event.turn === turn && event.data.type === "turn_end") { clearTimeout(timer); resolve(event); } });
        });
        phase = "publish";
        await native.request("prompt", { session: sessionId, text: "Finish the retained package import using the verified host receipt and publish its additive declaration." }, { id: turn });
        const result = await ended;
        expect(result.data.exit_code, JSON.stringify(runtimeEvents).slice(-12000) + native.stderr).toBe(0);
        const accepted = JSON.parse(offline.fossil("cat", "omniform/company.json", "-r", "trunk"));
        expect(accepted.spec.capabilities.some((row: any) => row.id === "portable_cv")).toBe(true);
        expect(accepted.spec.capabilities.find((row: any) => row.id === "package_support").realisations).toEqual(["support_alternative"]);
        expect((await offline.run(["fossil", "verify", "--json"])).code).toBe(0);
        expect(native.stderr).toBe("");
      } finally { await native.close(); }
      phase = "search";
      const found = await offline.run(["ask", "Inspect the portable_cv capability implementation", "--json"]);
      expect(found.code, found.stderr).toBe(0);
      expect(availability.some(value => value.includes("verified_workspace_implementation") && value.includes("available_subject_to_host_permissions"))).toBe(true);
      const drive = async (target: ReturnType<typeof fixture>, taskId: string, revision: string, publicSession: string, rebind = false, extraEnv: Record<string, string> = {}) => {
        const client = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: target.cwd, env: { ...process.env, ...target.env, ...extraEnv } });
        const events: any[] = []; client.on("event", (event: any) => events.push(event));
        try {
          await client.request("initialize");
          await client.request("task.resume", { revision, task: taskId, session: publicSession, rebind_project: rebind });
          const turn = crypto.randomUUID();
          const ended = new Promise<any>((resolve, reject) => {
            const timer = setTimeout(() => reject(Error("Capability verification turn did not finish")), 90000);
            client.on("event", (event: any) => { if (event.turn === turn && event.data.type === "turn_end") { clearTimeout(timer); resolve(event); } });
          });
          await client.request("prompt", { session: publicSession, text: "continue" }, { id: turn });
          return { ended: await ended, events };
        } finally { await client.close(); }
      };
      const unverifiedModel = model(restored, () => ({ content: "The package is ready." }));
      const unverifiedSession = await restored.run(["ask", "Prepare a separate verification conversation", "--json"]);
      expect(unverifiedSession.code, unverifiedSession.stderr).toBe(0);
      const denied = await drive(restored, staged.task, staged.revision, JSON.parse(unverifiedSession.stdout).session_id, true);
      expect(denied.ended.data.exit_code).toBe(1);
      expect(JSON.stringify(denied.events)).toContain("CapabilityRuntimeVerificationRequired");
      expect(unverifiedModel.counts().assessments).toBeGreaterThan(1);
      expect(JSON.parse(restored.fossil("cat", "omniform/company.json", "-r", "trunk")).spec.capabilities.some((row: any) => row.id === "portable_cv")).toBe(false);
      const restoredBindings = join(restored.home, "runtime-bindings.json");
      writeFileSync(restoredBindings, JSON.stringify({ version: "omos.runtime-handles/v1", handles: [{ handle: "node", kind: "node", executable: installedNode }] }));
      const recoveryProof = await restored.run(["fossil", "package", "verify", staged.task, "--bindings", restoredBindings, "--json"]);
      expect(recoveryProof.code, recoveryProof.stderr).toBe(0);
      const interrupted = await drive(restored, staged.task, JSON.parse(recoveryProof.stdout).model_data.revision, JSON.parse(unverifiedSession.stdout).session_id, false, { FX_E2E_FOSSIL_FAULT: "publication-committed" });
      expect(interrupted.ended.data.exit_code, JSON.stringify(interrupted.events).slice(-12000)).toBe(1);
      expect(JSON.stringify(interrupted.events)).toContain("WorkspaceInjectedFailure");
      expect(JSON.parse(restored.fossil("cat", "omniform/company.json", "-r", "trunk")).spec.capabilities.some((row: any) => row.id === "portable_cv")).toBe(true);
      const beforeRecovery = unverifiedModel.counts();
      rmSync(join(restored.home, ".fx/runtimes"), { recursive: true });
      const recovered = await restored.run(["fossil", "recover", "--json"]);
      expect(recovered.code, recovered.stderr).toBe(0);
      expect(unverifiedModel.counts()).toEqual(beforeRecovery);
      expect(JSON.parse((await restored.run(["fossil", "tasks", "--json"])).stdout).tasks.find((row: any) => row.id === staged.task).state).toBe("accepted");
      const privateBindings = join(offline.home, ".fx/runtimes/handles.json"), originalBindings = readFileSync(privateBindings);
      writeFileSync(privateBindings, JSON.stringify({ version: "omos.runtime-handles/v1", handles: [{ handle: "node", kind: "python", executable: node }] }));
      searched = false; availability.length = 0;
      expect((await offline.run(["ask", "Inspect portable_cv after runtime configuration changed", "--json"])).code).toBe(0);
      expect(availability.some(value => value.includes("declared_only"))).toBe(true);
      writeFileSync(privateBindings, originalBindings);
      searched = false; availability.length = 0;
      expect((await offline.run(["ask", "Inspect portable_cv after restoring its runtime binding", "--json"])).code).toBe(0);
      expect(availability.some(value => value.includes("verified_workspace_implementation"))).toBe(true);
      const acceptedArchive = join(offline.home, "accepted-capability.fossil");
      const acceptedExport = await offline.run(["fossil", "export", acceptedArchive, "--json"]);
      expect(acceptedExport.code, acceptedExport.stderr).toBe(0);
      const destination = fixture(); copyFileSync(acceptedArchive, join(destination.cwd, "omos.fossil"));
      expect((await destination.run(["fossil", "use", join(destination.cwd, "omos.fossil"), "--json"])).code).toBe(0);
      let destinationMode = "search", destinationSearched = false;
      const destinationCapabilities: string[] = [];
      model(destination, (body) => {
        if (destinationMode === "search" && !destinationSearched) { destinationSearched = true; return { tool_calls: [{ index: 0, id: "destination-search", type: "function", function: { name: "capability_search", arguments: JSON.stringify({ query: "portable_cv" }) } }] }; }
        if (destinationMode === "search") for (const message of body.messages) if (message.role === "tool" && typeof message.content === "string" && message.content.includes("workspace_capabilities")) destinationCapabilities.push(message.content);
        if (destinationMode === "change") { destinationMode = "changed"; return { tool_calls: [{ index: 0, id: "change-input", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "skills/cv-builder/SKILL.md", content: skill + "\nUpdated local instructions.\n" }) } }] }; }
        return { content: "Retained the capability checks and reported its current implementation availability." };
      });
      const freshSearch = await destination.run(["ask", "Inspect the portable_cv capability on this new host", "--json"]);
      expect(freshSearch.code, freshSearch.stderr).toBe(0);
      expect(destinationCapabilities.some(value => value.includes("declared_only"))).toBe(true);
      const destinationBindings = join(destination.home, "runtime-bindings.json");
      writeFileSync(destinationBindings, JSON.stringify({ version: "omos.runtime-handles/v1", handles: [{ handle: "node", kind: "node", executable: installedNode }] }));
      const rechecked = await destination.run(["fossil", "package", "verify", staged.task, "--bindings", destinationBindings, "--json"]);
      expect(rechecked.code, rechecked.stderr).toBe(0);
      const destinationTask = JSON.parse(rechecked.stdout).model_data;
      expect(destinationTask.verified).toBe(true); expect(destinationTask.task).not.toBe(staged.task);
      destinationMode = "publish";
      const acceptedDestination = await drive(destination, destinationTask.task, destinationTask.revision, JSON.parse(freshSearch.stdout).session_id);
      expect(acceptedDestination.ended.data.exit_code, JSON.stringify(acceptedDestination.events).slice(-12000)).toBe(0);
      destinationMode = "search"; destinationSearched = false; destinationCapabilities.length = 0;
      expect((await destination.run(["ask", "Inspect portable_cv after destination verification", "--json"])).code).toBe(0);
      expect(destinationCapabilities.some(value => value.includes("verified_workspace_implementation"))).toBe(true);
      const immutableOriginal = JSON.parse(destination.fossil("cat", `tasks/${staged.task}.json`, "-r", `task/${staged.task}`));
      expect(immutableOriginal.capability_runtime_receipt).toBe(verifiedRuntime.receipt);
      chmodSync(node, 0o600);
      searched = false; availability.length = 0;
      expect((await offline.run(["ask", "Inspect portable_cv after the runtime executable changed", "--json"])).code).toBe(0);
      expect(availability.some(value => value.includes("declared_only"))).toBe(true);
      destinationMode = "change";
      expect((await destination.run(["ask", "Update the local skill instructions", "--json"])).code).toBe(0);
      destinationMode = "search"; destinationSearched = false; destinationCapabilities.length = 0;
      expect((await destination.run(["ask", "Inspect portable_cv after its input changed", "--json"])).code).toBe(0);
      expect(destinationCapabilities.some(value => value.includes("declared_only"))).toBe(true);
      const destinationIntegrity = await destination.run(["fossil", "verify", "--json"]);
      expect(destinationIntegrity.code, destinationIntegrity.stderr).toBe(0);
    } finally { service.child.kill(); await service.child.exited; }
  }, 420000);

  test("versions explicit company capability metadata scopes without expanding file grants", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const file = join(f.home, "capability-authority-request.json");
    const command = async (value: object) => {
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...value }));
      return f.run(["fossil", "company", file, "--json"]);
    };
    const admin = async (value: object) => {
      const result = await command(value);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const absent = await command({ action: "inspect_capabilities" });
    expect(absent.code).toBe(1);
    expect(absent.stderr).toContain("CompanyNotInitialized");
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    const grant = { id: "metadata-reader", actor: "reader", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["skills/cv/"], actions: ["discover", "read"], expires_ms: Date.now() + 3600000 };
    const granted = await admin({ action: "grant", revision: initialized.revision, grant });
    const empty = await admin({ action: "inspect_capabilities" });
    expect(empty.policy.entries).toEqual([]);
    const scoped = await admin({ action: "grant_capabilities", revision: granted.revision, id: grant.id, capabilities: ["general_task"] });
    expect(scoped.policy.entries[0].capabilities).toEqual(["general_task"]);
    expect(scoped.policy.entries[0].grant_hash).toMatch(/^[a-f0-9]{64}$/);
    const stale = await command({ action: "grant_capabilities", revision: granted.revision, id: grant.id, capabilities: ["coding_task"] });
    expect(stale.code).toBe(1);
    expect(stale.stderr).toContain("WorkspaceRevisionChanged");
    const unchanged = await admin({ action: "inspect_capabilities" });
    expect(unchanged.revision).toBe(scoped.revision);
    expect(unchanged.policy.entries[0].capabilities).toEqual(["general_task"]);
    const removed = await admin({ action: "grant_capabilities", revision: scoped.revision, id: grant.id, capabilities: [] });
    expect(removed.policy.entries[0].capabilities).toEqual([]);
    const authority = JSON.parse(f.fossil("cat", "authority/state.json", "-r", "omos-company"));
    expect(authority.grants[0].paths).toEqual(grant.paths);
    const archived = JSON.parse(f.fossil("cat", "authority/capabilities.json", "-r", "omos-company"));
    expect(archived).toEqual(removed.policy);
    expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
    expect((await f.run(["fossil", "export", join(f.home, "scoped-company.fossil"), "--json"])).code).toBe(0);
  }, 120000);

  test("discovers scoped capability declarations with signed pages, pinned task models, and live metadata revocation", async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("Capability inspection must not execute an actor"); });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const operator = join(f.home, "capability-operator.json");
    const admin = async (body: object) => {
      writeFileSync(operator, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", operator, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    let control = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    control = await admin({ action: "grant", revision: control.revision, grant: { id: "capability-reader", actor: "reader", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["skills/cv/"], actions: ["discover", "read", "create_view", "status", "delegate"], expires_ms: Date.now() + 3600000 } });
    const service = await startWorkspaceService(f, true);
    try {
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      expect(boot.features.capability_discovery).toBe(true);
      const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
      const post = async (action: string, params: object = {}, principal = { actor: "reader", grant: "capability-reader", key }) => {
        const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: principal.actor, grant: principal.grant, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
        let response: Response;
        try {
          response = await fetch(service.url + "/v1/company", { method: "POST", keepalive: false, headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), principal.key.privateKey).toString("hex") }) });
        } catch (error) {
          const before = service.child.exitCode;
          service.child.kill(); await service.child.exited;
          throw Error(`${String(error)}; service exit before cleanup: ${before}; action=${action}; params=${JSON.stringify(params)}\n${await new Response(service.child.stderr).text()}\n${readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-16000)}`);
        }
        const envelope = await response.json() as any;
        if (response.status !== 200) return { status: response.status, error: envelope.error, result: null, operation: JSON.parse(payload).operation };
        expect(envelope.issuer).toBe(boot.issuer);
        expect(verify(null, Buffer.from(envelope.payload), issuer, Buffer.from(envelope.signature, "hex"))).toBe(true);
        const receipt = JSON.parse(envelope.payload);
        expect(receipt.request_hash).toBe(createHash("sha256").update(payload).digest("hex"));
        expect(receipt.actor).toBe(principal.actor);
        expect(receipt.grant).toBe(principal.grant);
        return { status: response.status, error: null, result: receipt.result };
      };
      const send = async (action: string, params: object = {}) => {
        const result = await post(action, params);
        expect(result.status, result.error ?? "").toBe(200);
        return result.result;
      };
      expect((await send("discover", { capability: "*" })).capabilities).toEqual([]);
      expect((await post("discover", { capability: "general_task" })).status).toBe(403);
      control = await admin({ action: "grant_capabilities", revision: control.revision, id: "capability-reader", capabilities: ["general_task"] });
      const visible = await send("discover", { capability: "*", limit: 1 });
      expect(visible.capabilities).toEqual(["general_task"]);
      expect(visible.total).toBe(1);
      expect(visible.next_offset).toBeNull();
      for (const capability of ["coding_task", "unknown_task"]) expect((await post("discover", { capability })).status).toBe(403);
      expect(boot.features.capability_delegation).toBe(true);
      const childKey = generateKeyPairSync("ed25519");
      const child = { id: "capability-child", actor: "child", public_key: childKey.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), parent: "capability-reader", paths: ["skills/cv/"], actions: ["discover", "read"], expires_ms: Date.now() + 1800000 };
      const denied = await post("delegate", { revision: boot.revision, delegated_grant: { ...child, id: "denied-capability-child", actor: "denied-child" }, delegated_capabilities: ["coding_task"] });
      expect(denied.status).toBe(403);
      expect((await send("status", { outcome: denied.operation })).state).toBe("failed");
      const delegated = await send("delegate", { revision: boot.revision, delegated_grant: child, delegated_capabilities: ["general_task"] });
      expect(delegated.grant).toBe(child.id);
      const childPrincipal = { actor: child.actor, grant: child.id, key: childKey };
      const childCatalog = await post("discover", { capability: "*" }, childPrincipal);
      expect(childCatalog.status).toBe(200);
      expect(childCatalog.result.capabilities).toEqual(["general_task"]);
      const currentAuthority = await admin({ action: "status" });
      expect(currentAuthority.authority.grants.some((row: any) => row.id === "denied-capability-child")).toBe(false);
      await admin({ action: "grant_capabilities", revision: currentAuthority.revision, id: child.id, capabilities: [] });
      const retry = await post("delegate", { revision: boot.revision, delegated_grant: child, delegated_capabilities: ["general_task"] });
      expect(retry.error).toBe("CompanyGrantAlreadyExists");
      expect((await send("status", { outcome: retry.operation })).state).toBe("failed");
      control = await admin({ action: "status" });
      await admin({ action: "grant_capabilities", revision: control.revision, id: child.id, capabilities: ["general_task"] });
      const view = await send("create_view", { revision: boot.revision, objective: "Inspect the pinned capability declaration" });
      const first = await send("discover", { capability: "general_task", view: view.view, limit: 128 });
      expect(first.read_tracking).toBe("model_basis");
      expect(first.definition_hash).toBe(view.basis.definition_hash);
      expect(first.package.next_offset).toBe(128);
      const parts = [Buffer.from(first.package.content, "base64")];
      let offset = first.package.next_offset;
      while (offset !== null) {
        const page = await send("discover", { capability: "general_task", view: view.view, revision: first.revision, offset, limit: 128 });
        expect(page.package.sha256).toBe(first.package.sha256);
        expect(page.definition_hash).toBe(first.definition_hash);
        const bytes = Buffer.from(page.package.content, "base64");
        expect(bytes.length).toBeLessThanOrEqual(128);
        parts.push(bytes); offset = page.package.next_offset;
      }
      const bytes = Buffer.concat(parts);
      expect(bytes.length).toBe(first.package.bytes);
      expect(createHash("sha256").update(bytes).digest("hex")).toBe(first.package.sha256);
      const plan = JSON.parse(bytes.toString());
      expect(plan.capabilities.map((row: any) => row.id)).toEqual(["general_task"]);
      expect(plan.file_verification).toBe("required");
      expect(plan.runtime_verification).toBe("required");
      expect(plan.files).toEqual([]);
      expect((await post("discover", { capability: "general_task", entity: "*" })).status).toBe(400);
      expect((await post("read", { path: "documents/private.txt" })).status).toBe(403);
      control = await admin({ action: "status" });
      await admin({ action: "grant_capabilities", revision: control.revision, id: "capability-reader", capabilities: [] });
      expect((await post("discover", { capability: "general_task", view: view.view, revision: first.revision, offset: 128, limit: 128 })).status).toBe(403);
      expect((await send("discover", { capability: "*" })).total).toBe(0);
      expect((await post("discover", { capability: "general_task" }, childPrincipal)).status).toBe(403);
      expect((await send("read", { path: "skills/cv/not-present.txt" })).exists).toBe(false);
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
    } finally { service.child.kill(); await service.child.exited; }
  }, 180000);

  test("closes idle keep-alive and partial-header connections without aborting the workspace service", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const operator = join(f.home, "idle-service-operator.json");
    writeFileSync(operator, JSON.stringify({ version: "omos.company-admin/v1", action: "initialize" }));
    expect((await f.run(["fossil", "company", operator, "--json"])).code).toBe(0);
    const service = await startWorkspaceService(f, false);
    const { createConnection } = await import("node:net");
    const sockets: ReturnType<typeof createConnection>[] = [];
    const open = async () => {
      const socket = createConnection({ host: "127.0.0.1", port: service.ready.port });
      sockets.push(socket);
      await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
      return socket;
    };
    try {
      const idle = await open(), partial = await open();
      const closed = (socket: typeof idle) => new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => reject(Error("Timed-out connection remained open")), 15000);
        socket.once("close", () => { clearTimeout(timeout); resolve(); });
      });
      const idleClosed = closed(idle), partialClosed = closed(partial);
      let response = "";
      const received = new Promise<void>((resolve, reject) => {
        idle.on("data", bytes => { response += bytes.toString(); if (response.includes('"issuer"')) resolve(); });
        idle.once("error", reject);
      });
      idle.write("GET /v1/company HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n");
      partial.write("GET /v1/company HTTP/1.1\r\nHost: localhost\r\n");
      partial.resume();
      await received;
      expect(response).toContain("200 OK");
      const start = Date.now();
      await Promise.all([idleClosed, partialClosed]);
      expect(Date.now() - start).toBeGreaterThan(8000);
      expect(service.child.exitCode).toBeNull();
      const fresh = await fetch(service.url + "/v1/company", { keepalive: false, headers: { connection: "close" } });
      expect(fresh.status).toBe(200);
      expect((await fresh.json() as any).workspace).toBe(service.ready.workspace);
    } finally {
      for (const socket of sockets) socket.destroy();
      service.child.kill(); await service.child.exited;
      const stderr = await new Response(service.child.stderr).text();
      expect(stderr).not.toContain("panic:");
    }
  }, 60000);

  test("discovers scoped record schemas from pinned OmniForm definitions without exposing other types", async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("Schema discovery must not run an actor"); });
    expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
    const declaration = JSON.parse(f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    const largeFields = Object.fromEntries(Array.from({ length: 700 }, (_, index) => [`schema_field_${index.toString().padStart(4, "0")}`, "string"]));
    declaration.spec.semantic.entityTypes.push({ id: "team_note", fields: { text: "string" }, required: ["text"] }, { id: "large_note", fields: largeFields }, { id: "hidden_note", fields: { text: "string" } });
    for (let index = 0; index < 32; index++) declaration.spec.semantic.entityTypes.push({ id: `extra_${index}`, fields: { text: "string" } });
    const proposal = join(f.home, "definition.json");
    const propose = async () => {
      writeFileSync(proposal, JSON.stringify(declaration));
      const result = await f.run(["fossil", "definition", "propose", proposal, "--json"]);
      expect(result.code, result.stderr).toBe(0);
    };
    await propose();
    const admin = async (body: object) => {
      const path = join(f.home, "operator.json");
      writeFileSync(path, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", path, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    let authority = await admin({ action: "initialize" });
    const keys = { scoped: generateKeyPairSync("ed25519"), broad: generateKeyPairSync("ed25519"), outside: generateKeyPairSync("ed25519") };
    for (const [id, paths] of [
      ["scoped", ["records/team_note/one.json", "records/large_note/", "records/later_note/"]],
      ["broad", ["records/"]],
      ["outside", ["documents/"]],
    ] as const) authority = await admin({ action: "grant", revision: authority.revision, grant: { id, actor: id, public_key: keys[id].publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths, actions: ["discover", "create_view", "record", "status"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company", { keepalive: false })).json() as any;
    const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
    const post = async (actor: keyof typeof keys, action: string, params: object) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor, grant: actor, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      const response = await fetch(service.url + "/v1/company", { method: "POST", keepalive: false, headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), keys[actor].privateKey).toString("hex") }) });
      const envelope = await response.json() as any;
      if (response.status !== 200) return { status: response.status, error: envelope.error, result: null };
      expect(envelope.issuer).toBe(boot.issuer);
      expect(verify(null, Buffer.from(envelope.payload), issuer, Buffer.from(envelope.signature, "hex"))).toBe(true);
      const receipt = JSON.parse(envelope.payload);
      expect(receipt.request_hash).toBe(createHash("sha256").update(payload).digest("hex"));
      expect(receipt.actor).toBe(actor);
      expect(receipt.grant).toBe(actor);
      expect(receipt.action).toBe(action);
      return { status: 200, error: null, result: receipt.result };
    };
    const send = async (actor: keyof typeof keys, action: string, params: object = {}) => {
      const response = await post(actor, action, params);
      expect(response.status, JSON.stringify(response)).toBe(200);
      return response.result;
    };
    try {
      expect(boot.features.schema_discovery).toBe(true);
      const view = await send("scoped", "create_view", { revision: boot.revision, objective: "Create a note against the pinned record contract" });
      const before = (await admin({ action: "status" })).revision;
      const first = await send("scoped", "discover", { entity: "*", limit: 1 });
      expect(first.scope_filtered).toBe(true);
      expect(first.total).toBe(2);
      expect(first.entities).toEqual(["team_note"]);
      expect(first.next_offset).toBe(1);
      const second = await send("scoped", "discover", { entity: "*", revision: first.revision, offset: 1, limit: 1 });
      expect(second.entities).toEqual(["large_note"]);
      expect(second.next_offset).toBeNull();
      const broad = await send("broad", "discover", { entity: "*" });
      expect(broad.total).toBe(35);
      expect(broad.entities).toHaveLength(32);
      expect(broad.entities.some((id: string) => id.startsWith("omos_"))).toBe(false);
      expect(broad.next_offset).toBe(32);
      expect((await send("broad", "discover", { entity: "*", revision: broad.revision, offset: 32 })).entities).toHaveLength(3);
      expect((await send("outside", "discover", { entity: "*" })).total).toBe(0);
      for (const entity of ["team_note", "missing_note", "omos_assessment"]) expect((await post("outside", "discover", { entity })).status).toBe(403);
      expect((await post("scoped", "discover", { entity: "hidden_note" })).status).toBe(403);
      expect((await post("broad", "discover", { entity: "missing_note" })).error).toBe("UnknownEntityType");
      const initial = await send("scoped", "discover", { entity: "large_note", limit: 4096 });
      expect(initial.schema.bytes).toBeGreaterThan(16384);
      expect(initial.schema.next_offset).toBe(4096);
      const parts = [Buffer.from(initial.schema.content, "base64")];
      expect((await admin({ action: "status" })).revision).toBe(before);
      declaration.spec.semantic.entityTypes.push({ id: "later_note", fields: { text: "string" } });
      await propose();
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, false);
      let offset = initial.schema.next_offset;
      while (offset !== null) {
        const page = await send("scoped", "discover", { entity: "large_note", revision: initial.revision, offset, limit: 4096 });
        expect(page.definition_hash).toBe(initial.definition_hash);
        expect(page.schema.sha256).toBe(initial.schema.sha256);
        expect(page.schema.offset).toBe(offset);
        const bytes = Buffer.from(page.schema.content, "base64");
        expect(bytes.length).toBeLessThanOrEqual(4096);
        parts.push(bytes); offset = page.schema.next_offset;
      }
      const bytes = Buffer.concat(parts);
      expect(bytes.length).toBe(initial.schema.bytes);
      expect(createHash("sha256").update(bytes).digest("hex")).toBe(initial.schema.sha256);
      expect(Object.keys(JSON.parse(bytes.toString()).fields)).toHaveLength(700);
      const current = await send("scoped", "discover", { entity: "*" });
      expect(current.entities).toEqual(["team_note", "large_note", "later_note"]);
      expect(current.definition_hash).not.toBe(view.basis.definition_hash);
      const pinned = await send("scoped", "discover", { view: view.view, entity: "*" });
      expect(pinned.definition_hash).toBe(view.basis.definition_hash);
      expect(pinned.entities).toEqual(["team_note", "large_note"]);
      expect(pinned.read_tracking).toBe("model_basis");
      expect((await post("scoped", "discover", { view: view.view, entity: "later_note" })).error).toBe("UnknownEntityType");
      expect((await post("scoped", "discover", { entity: "large_note", offset: initial.schema.bytes + 1 })).error).toBe("InvalidEvidenceOffset");
      expect((await post("scoped", "discover", { entity: "team_note", limit: 0 })).status).toBe(400);
      const schema = await send("scoped", "discover", { view: view.view, entity: "team_note" });
      expect(JSON.parse(Buffer.from(schema.schema.content, "base64").toString()).required).toEqual(["text"]);
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, true);
      const written = await send("scoped", "record", { view: view.view, revision: view.revision, entity: "team_note", record_id: "one", content: JSON.stringify({ text: "Created using the pinned schema" }) });
      expect(JSON.parse(f.fossil("cat", "records/team_note/one.json", "-r", written.revision)).data.text).toBe("Created using the pinned schema");
      const state = await admin({ action: "status" });
      await admin({ action: "revoke", revision: state.revision, id: "scoped" });
      expect((await post("scoped", "discover", { view: view.view, entity: "team_note" })).error).toBe("CompanyAccessRevoked");
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
    } finally { service.child.kill(); await service.child.exited; }
  }, 240000);

  test("streams signed company progress with bounded admission, cancellation, restart and live revocation", async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("Progress transport must not execute an actor"); });
    expect((await f.run(["fossil", "ensure", "--json"])).code).toBe(0);
    const admin = async (body: object) => {
      const path = join(f.home, "operator.json");
      writeFileSync(path, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", path, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "progress-reader", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "status"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const streams: Awaited<ReturnType<typeof progressStream>>[] = [];
    const boot = await (await fetch(service.url + "/v1/company", { keepalive: false })).json() as any;
    const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
    const seal = (action: string, params: object) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "progress-reader", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const send = async (action: string, params: object) => {
      const response = await fetch(service.url + "/v1/company", { method: "POST", keepalive: false, headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(seal(action, params)) });
      const receipt = await response.json() as any;
      expect(response.status, JSON.stringify(receipt)).toBe(200);
      return JSON.parse(receipt.payload).result;
    };
    const subscribe = async (envelope: object) => {
      const stream = await progressStream(service.url, envelope).catch(error => {
        throw Error(`${error}; native exit: ${service.child.exitCode}\n${readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-8000)}`);
      }); streams.push(stream); return stream;
    };
    const subscribeAvailable = async (envelope: object) => {
      const deadline = Date.now() + 10000;
      for (;;) {
        const stream = await subscribe(envelope);
        if (stream.response.status !== 429) return stream;
        await stream.close();
        if (Date.now() >= deadline) throw Error("Cancelled streams did not release admission");
        await Bun.sleep(20);
      }
    };
    const inspect = (event: Awaited<ReturnType<Awaited<ReturnType<typeof progressStream>>["next"]>>, envelope: { payload: string }) => {
      expect(event.event).toBe("workspace");
      expect(event.data.issuer).toBe(boot.issuer);
      expect(verify(null, Buffer.from(event.data.payload), issuer, Buffer.from(event.data.signature, "hex"))).toBe(true);
      const receipt = JSON.parse(event.data.payload);
      expect(receipt.request_hash).toBe(createHash("sha256").update(envelope.payload).digest("hex"));
      expect(receipt.actor).toBe("worker");
      expect(receipt.grant).toBe("progress-reader");
      expect(receipt.action).toBe("status");
      const progress = receipt.result.progress;
      expect(event.id).toBe(progress.next_cursor ?? progress.resume_cursor);
      return progress;
    };
    try {
      expect(boot.features.progress_stream).toBe("omos.company-progress/v1");
      expect(boot.features.max_progress_streams).toBe(4);
      expect(boot.features.max_progress_seconds).toBe(30);
      const view = await send("create_view", { revision: boot.revision, objective: "Retain and stream only this worker's document revisions" });
      const operationLock = join(f.home, ".fx/authority", boot.workspace, "operation.lock");
      const blocker = Bun.spawn(["python3", "-u", "-c", "import fcntl, sys\nwith open(sys.argv[1], 'r+') as lock:\n fcntl.flock(lock, fcntl.LOCK_EX)\n print('locked', flush=True)\n sys.stdin.read()\n", operationLock], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
      const blockedControllers = Array.from({ length: 5 }, () => new AbortController());
      const pending: Promise<unknown>[] = [];
      try {
        const ready = await blocker.stdout.getReader().read();
        expect(new TextDecoder().decode(ready.value)).toContain("locked");
        let headersReturned = 0;
        const admission: string[] = [];
        for (const controller of blockedControllers) pending.push(progressStream(service.url, seal("status", { view: view.view, progress_cursor: "" }), controller).then(stream => { headersReturned++; admission.push(`HTTP ${stream.response.status}`); streams.push(stream); }, error => { admission.push(String(error)); }));
        const probe = async () => {
          const response = await subscribe(seal("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/not-written.txt", content: "Rejected before effects" }));
          const status = response.response.status;
          await response.close();
          return status;
        };
        let deadline = Date.now() + 10000;
        // A probing request can take the fourth slot itself. Start five readers
        // and wait for the rejected fifth before probing the four held slots.
        while (admission.length === 0) {
          if (Date.now() >= deadline) throw Error(`Pending subscriptions did not occupy admission slots: ${JSON.stringify(admission)}\n${readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-5000)}`);
          await Bun.sleep(20);
        }
        expect(admission).toEqual(["HTTP 429"]);
        expect(headersReturned).toBe(1);
        expect(await probe()).toBe(429);
        for (const controller of blockedControllers) controller.abort();
        await Promise.all(pending);
        deadline = Date.now() + 10000;
        for (;;) {
          const status = await probe();
          if (status === 400) break;
          expect(status).toBe(429);
          if (Date.now() >= deadline) throw Error("Cancellation did not release subscriptions waiting for the operation lock");
          await Bun.sleep(20);
        }
      } finally {
        for (const controller of blockedControllers) controller.abort();
        blocker.stdin.end();
        await blocker.exited;
        await Promise.all(pending);
      }
      const occupied = await Promise.all(Array.from({ length: 4 }, () => subscribeAvailable(seal("status", { view: view.view, progress_cursor: "" }))));
      for (const stream of occupied) {
        expect(stream.response.status).toBe(200);
        expect(stream.response.headers.get("content-type")).toBe("text/event-stream");
        expect(stream.response.headers.get("cache-control")).toBe("no-store");
      }
      const busy = await subscribe(seal("status", { view: view.view, progress_cursor: "" }));
      expect(busy.response.status).toBe(429);
      await busy.close();
      await occupied[0].close();
      const admissionDeadline = Date.now() + 10000;
      let replacement: Awaited<ReturnType<typeof progressStream>>;
      for (;;) {
        replacement = await subscribe(seal("status", { view: view.view, progress_cursor: "" }));
        if (replacement.response.status === 200) break;
        expect(replacement.response.status).toBe(429);
        await replacement.close();
        if (Date.now() >= admissionDeadline) throw Error("Cancelled subscription did not release admission");
        await Bun.sleep(20);
      }
      await Promise.all([...occupied.slice(1), replacement].map(stream => stream.close()));
      let head = view.revision;
      const expected = [head];
      for (let index = 0; index < 3; index++) {
        head = (await send("checkpoint", { view: view.view, revision: head, path: `documents/team/${index}.txt`, content: "Scoped progress" })).revision;
        expected.push(head);
      }
      let request = seal("status", { view: view.view, progress_cursor: "", limit: 1 });
      let live = await subscribeAvailable(request);
      expect(live.response.status).toBe(200);
      let event = await live.next();
      let page = inspect(event, request);
      expect(page.events).toHaveLength(1);
      expect(page.next_cursor).not.toBeNull();
      const pinned = page.revision;
      const seen = page.events.map((row: any) => row.revision);
      let lastCursor = event.id!;
      head = (await send("checkpoint", { view: view.view, revision: head, path: "documents/team/arrived.txt", content: "Arrived while the stream was open" })).revision;
      expected.push(head);
      const pagingDeadline = Date.now() + 90000;
      while (!seen.includes(head) || page.next_cursor !== null) {
        if (Date.now() >= pagingDeadline) throw Error("Progress did not resume through the pinned revisions");
        const next = await live.next(35000).catch(error => {
          if (error.message === "Progress stream closed before the expected event" || error.code === "ECONNRESET") return { event: "end", id: undefined, data: null };
          throw error;
        });
        if (next.event === "end") {
          await live.close();
          request = seal("status", { view: view.view, progress_cursor: lastCursor, limit: 1 });
          live = await subscribe(request);
          expect(live.response.status).toBe(200);
          continue;
        }
        event = next; page = inspect(event, request);
        lastCursor = event.id!;
        seen.push(...page.events.map((row: any) => row.revision));
        expect(seen.length).toBeLessThan(100);
      }
      expect(pinned).not.toBe(head);
      expect(page.revision).toBe(head);
      expect(new Set(seen).size).toBe(seen.length);
      for (const revision of expected) expect(seen).toContain(revision);
      const resume = event.id!;
      await live.close();
      const rejected = await subscribe(seal("checkpoint", { view: view.view, revision: head, path: "documents/team/not-written.txt", content: "This must not execute through the stream transport" }));
      expect(rejected.response.status).toBe(400);
      await rejected.close();
      expect((await send("status", { view: view.view })).revision).toBe(head);
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, false);
      const resumedRequest = seal("status", { view: view.view, progress_cursor: resume });
      const deadlineStarted = Date.now();
      const resumed = await subscribe(resumedRequest);
      expect(resumed.response.status).toBe(200);
      const continued = inspect(await resumed.next(), resumedRequest);
      expect(continued.events).toEqual([]);
      const ended = await resumed.next(40000).then(event => ({ event, error: null }), error => ({ event: null, error }));
      if (ended.event !== null) expect(ended.event.event).toBe("end");
      expect(Date.now() - deadlineStarted).toBeGreaterThan(25000);
      expect(Date.now() - deadlineStarted).toBeLessThan(37000);
      await resumed.close();
      const expiringRequest = seal("status", { view: view.view, progress_cursor: resume, expires_ms: Date.now() + 5000 });
      const expiring = await subscribe(expiringRequest);
      expect(expiring.response.status).toBe(200);
      inspect(await expiring.next(), expiringRequest);
      const expired = await expiring.next();
      expect(expired.event).toBe("error");
      expect(expired.data.error).toBe("CompanyRequestExpired");
      await expiring.close();
      const revocableRequest = seal("status", { view: view.view, progress_cursor: resume });
      const revocable = await subscribe(revocableRequest);
      expect(revocable.response.status).toBe(200);
      inspect(await revocable.next(), revocableRequest);
      const current = await admin({ action: "status" });
      await admin({ action: "revoke", revision: current.revision, id: "progress-reader" });
      for (;;) {
        const next = await revocable.next();
        if (next.event === "error") { expect(next.data.error).toBe("CompanyAccessRevoked"); break; }
        expect(inspect(next, revocableRequest).events).toEqual([]);
      }
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
    } finally {
      await Promise.all(streams.map(stream => stream.close()));
      service.child.kill(); await service.child.exited;
    }
  }, 240000);

  test("resumes signed company progress pages without losing concurrent revisions or crossing view authority", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "ensure", "--json"])).code).toBe(0);
    const repository = JSON.parse(readFileSync(join(f.home, ".fx/omos-workspace.json"), "utf8")).repository;
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    let authority = await admin({ action: "initialize" });
    const keys = { alice: generateKeyPairSync("ed25519"), bob: generateKeyPairSync("ed25519") };
    for (const actor of ["alice", "bob"] as const) authority = await admin({ action: "grant", revision: authority.revision, grant: { id: actor + "-grant", actor, public_key: keys[actor].publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "status"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const envelope = (actor: keyof typeof keys, action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor, grant: actor + "-grant", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), keys[actor].privateKey).toString("hex") };
    };
    const post = (actor: keyof typeof keys, action: string, params: object = {}) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(envelope(actor, action, params)) });
    const send = async (actor: keyof typeof keys, action: string, params: object = {}) => {
      const response = await post(actor, action, params), receipt = await response.json() as any;
      expect(response.status, JSON.stringify(receipt)).toBe(200);
      return JSON.parse(receipt.payload).result;
    };
    const revisions = (head: string, after: string) => {
      const result: { revision: string; parent: string; committed_at: string; kind: string }[] = [];
      while (head !== after) {
        const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
        const inspected = spawnSync(existsSync(helper) ? helper : "fossil", ["--user", "omos", "artifact", head, "-R", repository], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, LC_ALL: "C" } });
        expect(inspected.status, inspected.stderr).toBe(0);
        const raw = inspected.stdout;
        expect(createHash("sha3-256").update(raw).digest("hex")).toBe(head);
        const parent = raw.match(/^P ([a-f0-9]+)/m)?.[1];
        expect(parent).toBeDefined();
        result.push({ revision: head, parent: parent!, committed_at: raw.match(/^D (.+)$/m)![1], kind: "view_revision" });
        head = parent!;
        expect(result.length).toBeLessThan(100);
      }
      return result;
    };
    try {
      expect(boot.features.progress_history).toBe(true);
      const alice = await send("alice", "create_view", { revision: boot.revision, objective: "Retain team documents and their complete progress" });
      const bob = await send("bob", "create_view", { revision: boot.revision, objective: "Retain a separate private progress stream" });
      let head = alice.revision;
      for (let index = 0; index < 3; index++) head = (await send("alice", "checkpoint", { view: alice.view, revision: head, path: "documents/team/" + index + ".txt", content: "Versioned content" })).revision;
      const first = (await send("alice", "status", { view: alice.view, progress_cursor: "", limit: 1 })).progress;
      expect(first.version).toBe("omos.company-progress/v1");
      expect(first.revision).toBe(head);
      expect(first.events).toHaveLength(1);
      expect(typeof first.next_cursor).toBe("string");
      const expected = revisions(head, boot.revision);
      const advanced = await send("alice", "checkpoint", { view: alice.view, revision: head, path: "documents/team/later.txt", content: "Arrived while paging" });
      const events = [...first.events];
      let page = first;
      while (page.next_cursor !== null) {
        page = (await send("alice", "status", { view: alice.view, progress_cursor: page.next_cursor, limit: 2 })).progress;
        expect(page.revision).toBe(head);
        expect(page.events.length).toBeLessThanOrEqual(2);
        events.push(...page.events);
        expect(events.length).toBeLessThan(100);
      }
      expect(events).toEqual(expected);
      expect(new Set(events.map(event => event.revision)).size).toBe(events.length);
      const cursor = page.resume_cursor;
      const tampered = JSON.parse(cursor), claims = JSON.parse(tampered.payload);
      claims.after = boot.revision;
      tampered.payload = JSON.stringify(claims);
      expect((await post("alice", "status", { view: alice.view, progress_cursor: JSON.stringify(tampered) })).status).toBe(400);
      expect((await post("bob", "status", { view: bob.view, progress_cursor: cursor })).status).toBe(400);
      expect((await post("bob", "status", { view: alice.view, progress_cursor: cursor })).status).toBe(403);
      const sibling = await send("alice", "create_view", { revision: boot.revision, objective: "A distinct view for the same actor" });
      expect((await post("alice", "status", { view: sibling.view, progress_cursor: cursor })).status).toBe(400);
      expect((await post("alice", "status", { view: alice.view, progress_cursor: "{}" })).status).toBe(400);
      expect((await post("alice", "checkpoint", { view: alice.view, revision: advanced.revision, path: "documents/team/invalid.txt", content: "Must not be written", progress_cursor: "" })).status).toBe(400);
      expect((await post("alice", "status", { view: alice.view, revision: advanced.revision, progress_cursor: cursor })).status).toBe(400);
      service.child.kill(); await service.child.exited;
      const cache = join(f.home, ".fx/fossil", createHash("sha256").update(repository).digest("hex"));
      rmSync(join(cache, "tasks"), { recursive: true });
      rmSync(join(cache, "checkouts"), { recursive: true });
      service = await startWorkspaceService(f, false);
      const resumed = (await send("alice", "status", { view: alice.view, progress_cursor: cursor })).progress;
      expect(resumed.events).toEqual(revisions(advanced.revision, head));
      expect(resumed.revision).toBe(advanced.revision);
      expect(resumed.next_cursor).toBeNull();
      const idle = (await send("alice", "status", { view: alice.view, progress_cursor: resumed.resume_cursor })).progress;
      expect(idle.events).toEqual([]);
      expect(idle.next_cursor).toBeNull();
      const authorityRoot = join(f.home, ".fx/authority", boot.workspace);
      const locks = Bun.spawn(["python3", "-u", "-c", "import fcntl, sys\nwith open(sys.argv[1], 'r+') as operation, open(sys.argv[2], 'r+') as issuer:\n fcntl.flock(operation, fcntl.LOCK_EX)\n fcntl.flock(issuer, fcntl.LOCK_EX)\n print('locked', flush=True)\n sys.stdin.readline()\n fcntl.flock(operation, fcntl.LOCK_UN)\n print('operation-released', flush=True)\n sys.stdin.read()\n", join(authorityRoot, "operation.lock"), join(authorityRoot, "issuer.lock")], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
      const lockReader = locks.stdout.getReader();
      const lockErrors = new Response(locks.stderr).text();
      const lockLine = async () => {
        let line = "";
        while (!line.includes("\n")) { const chunk = await lockReader.read(); if (chunk.done) throw new Error("Progress lock fixture exited"); line += new TextDecoder().decode(chunk.value); }
        return line.trim();
      };
      try {
        expect(await lockLine()).toBe("locked");
        const started = Date.now();
        const pending = post("alice", "status", { view: alice.view, progress_cursor: idle.resume_cursor });
        // Deliberately spend part of one request's allowance at admission,
        // then hold the issuer lock to prove collection cannot renew it.
        await Bun.sleep(10000);
        locks.stdin.write("release\n"); await locks.stdin.flush();
        expect(await lockLine()).toBe("operation-released");
        const timedOut = await pending;
        expect(timedOut.status).toBe(400);
        expect((await timedOut.json() as any).error).toBe("Timeout");
        expect(Date.now() - started).toBeGreaterThanOrEqual(29000);
        expect(Date.now() - started).toBeLessThan(37000);
      } finally { locks.stdin.end(); await locks.exited; lockReader.releaseLock(); }
      expect(await lockErrors).toBe("");
      expect((await send("alice", "status", { view: alice.view, progress_cursor: idle.resume_cursor })).progress.events).toEqual([]);
      const current = await admin({ action: "status" });
      await admin({ action: "revoke", revision: current.revision, id: "alice-grant" });
      expect((await post("alice", "status", { view: alice.view, progress_cursor: idle.resume_cursor })).status).toBe(403);
    } finally { service.child.kill(); await service.child.exited; }
  }, 150000);
  test("connects native MCP clients to signed company operations without owner credentials or unsafe retries", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "ensure", "--json"])).code).toBe(0);
    const installed = spawnSync("sh", [join(import.meta.dir, "../../scripts/install-omos.sh")], { cwd: f.cwd, env: { ...process.env, ...f.env, XDG_BIN_HOME: join(f.home, "commands") }, encoding: "utf8", timeout: 60000 });
    expect(installed.status, installed.stderr).toBe(0);
    const installation = JSON.parse(readFileSync(join(f.home, ".fx/libexec/company-mcp.json"), "utf8"));
    const companionEntry = join(f.home, ".fx", installation.file);
    const admin = async (body: object) => {
      const filename = join(f.home, "operator.json");
      writeFileSync(filename, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", filename, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initial = await admin({ action: "initialize" });
    const keyResult = await f.run(["fossil", "company-key", "mcp-worker", "--json"]);
    expect(keyResult.code, keyResult.stderr).toBe(0);
    const identity = JSON.parse(keyResult.stdout);
    const key = identity.model_data ?? identity;
    await admin({ action: "grant", revision: initial.revision, grant: { id: "mcp-editor", actor: "worker", public_key: key.public_key, paths: ["documents/team/"], actions: ["discover", "read", "create_view", "checkpoint", "status", "reconcile"], expires_ms: Date.now() + 3600000 } });
    const service = await startWorkspaceService(f, true);
    let mode = "normal", posts = 0, redirects = 0;
    let committed: (() => void) | undefined, releaseResponse: (() => void) | undefined;
    let heldResponse: Promise<void> | undefined;
    const authorityHeaders: string[] = [];
    const redirect = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() { redirects++; return Response.json({}); } });
    const proxy = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      authorityHeaders.push(request.headers.get("authorization") ?? "", request.headers.get("cookie") ?? "");
      if (mode === "redirect") return Response.redirect(`http://127.0.0.1:${redirect.port}/v1/company`, 307);
      if (mode === "oversized") return new Response("x".repeat(1024 * 1024 + 1));
      if (request.method === "POST") posts++;
      const response = await fetch(service.url + "/v1/company", { method: request.method, headers: { "content-type": "application/json" }, body: request.method === "POST" ? await request.text() : undefined });
      if (mode === "identity" && request.method === "GET") {
        const value = await response.json() as any;
        value.epoch++;
        return Response.json(value);
      }
      if (mode === "hold" && request.method === "POST") { committed?.(); await heldResponse; }
      if (mode === "tamper" && request.method === "POST" && response.status === 200) {
        const value = await response.json() as any;
        value.payload += " ";
        return Response.json(value);
      }
      return response;
    } });
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const filename = join(f.home, "company-mcp.json");
    const config = { version: "omos.company-mcp/v1", endpoint: `http://127.0.0.1:${proxy.port}`, workspace: boot.workspace, issuer: boot.issuer, epoch: boot.epoch, actor: "worker", grant: "mcp-editor", key_handle: "mcp-worker", actions: ["discover", "read", "create_view", "checkpoint", "status", "reconcile"] };
    writeFileSync(filename, JSON.stringify(config), { mode: 0o600 });
    const client = await companyMcp(filename, f.home, companionEntry);
    const call = async (name: string, args: object = {}) => {
      const response = await client.rpc("tools/call", { name, arguments: args });
      expect(response.error).toBeUndefined();
      return { ...response.result, value: JSON.parse(response.result.content[0].text) };
    };
    const args = (action: string, params: object = {}) => ({ version: "omos.company/v1", action, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, ...params });
    try {
      const modern = await client.rpc("initialize", { protocolVersion: "2026-07-28" });
      expect(modern.error.code).toBe(-32022);
      expect(modern.error.data.supported).toContain("2025-11-25");
      expect((await client.rpc("initialize", { protocolVersion: "2025-11-25" })).result.protocolVersion).toBe("2025-11-25");
      const tools = (await client.rpc("tools/list")).result.tools;
      expect(tools.map((tool: any) => tool.name)).toEqual(["company_context", "company_workspace"]);
      expect(tools[1].inputSchema.properties.actor).toBeUndefined();
      expect(tools[1].inputSchema.properties.action.enum).not.toContain("delegate");
      const context = await call("company_context");
      expect(context.value.company.workspace).toBe(boot.workspace);
      expect(context.value.public_key).toBe(key.public_key);
      expect((await client.rpc("tools/list", null as any)).error.code).toBe(-32602);
      const before = posts;
      expect((await call("invented_alias")).value.error).toBe("UnknownTool");
      expect((await call("company_workspace", args("read", { actor: "other" }))).value.error).toBe("InvalidArguments");
      expect((await call("company_workspace", args("delegate"))).value.error).toBe("InvalidArguments");
      expect(posts).toBe(before);
      const createdRequest = args("create_view", { revision: boot.revision, objective: "Save a team document through MCP" });
      const created = await call("company_workspace", createdRequest);
      expect(created.isError).not.toBe(true);
      const receipt = created.structuredContent.receipt;
      const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
      expect(verify(null, Buffer.from(receipt.payload), publicKey, Buffer.from(receipt.signature, "hex"))).toBe(true);
      const claim = JSON.parse(receipt.payload);
      expect(claim.operation).toBe(createdRequest.operation);
      const saved = await call("company_workspace", args("checkpoint", { view: created.value.view, revision: created.value.revision, path: "documents/team/mcp.txt", content: "A native Fossil checkpoint from MCP" }));
      expect(saved.isError).not.toBe(true);
      const read = await call("company_workspace", args("read", { view: created.value.view, revision: saved.value.revision, path: "documents/team/mcp.txt" }));
      expect(Buffer.from(read.value.content, "base64").toString()).toBe("A native Fossil checkpoint from MCP");
      const progress = await call("company_workspace", args("status", { view: created.value.view, progress_cursor: "", limit: 1 }));
      expect(progress.isError).not.toBe(true);
      expect(progress.value.progress.version).toBe("omos.company-progress/v1");
      expect(progress.value.progress.events).toHaveLength(1);
      expect((await call("company_workspace", args("read", { view: created.value.view, revision: saved.value.revision, path: "documents/private.txt" }))).isError).toBe(true);
      mode = "tamper";
      const uncertainRequest = args("create_view", { revision: boot.revision, objective: "Retain a view despite a corrupted response" });
      const postCount = posts;
      const uncertain = await call("company_workspace", uncertainRequest);
      expect(uncertain.value.error).toBe("CompanyOutcomeUnverified");
      expect(posts).toBe(postCount + 1);
      mode = "normal";
      const outcome = await call("company_workspace", args("status", { outcome: uncertainRequest.operation }));
      expect(outcome.value.state).toBe("completed");
      const committedResponse = new Promise<void>(resolve => { committed = resolve; });
      heldResponse = new Promise<void>(resolve => { releaseResponse = resolve; });
      mode = "hold";
      const cancelledRequest = args("create_view", { revision: boot.revision, objective: "Retain the operation when its MCP caller cancels" });
      const beforeCancel = posts;
      const cancelled = call("company_workspace", cancelledRequest);
      const cancelId = client.lastId();
      await committedResponse;
      await client.notify("notifications/cancelled", { requestId: cancelId, reason: "The caller cancelled after commit" });
      expect((await cancelled).value.error).toBe("CompanyOutcomeUnknown");
      releaseResponse?.();
      mode = "normal";
      expect(posts).toBe(beforeCancel + 1);
      expect((await call("company_workspace", args("status", { outcome: cancelledRequest.operation }))).value.state).toBe("completed");
      const noPost = posts;
      for (mode of ["redirect", "oversized"]) expect((await call("company_context")).isError).toBe(true);
      mode = "identity";
      expect((await call("company_workspace", args("create_view", { revision: boot.revision, objective: "Reject a changed issuer epoch" }))).value.error).toBe("CompanyIdentityChanged");
      expect(posts).toBe(noPost);
      expect(redirects).toBe(0);
      mode = "normal";
      expect(authorityHeaders.every(value => value === "")).toBe(true);
      const added = await f.run(["mcp", "add", "company", "--", process.execPath, companionEntry, filename], { FX_MCP_ENGINE: "v2" });
      expect(added.code, added.stderr).toBe(0);
      const shown = await f.run(["mcp", "show", "company", "--json"], { FX_MCP_ENGINE: "v2" });
      expect(shown.code, shown.stderr + shown.stdout).toBe(0);
      expect(JSON.parse(shown.stdout)).toMatchObject({ status: "ready", version: "2025-11-25" });
      expect(JSON.parse(shown.stdout).tools.map((tool: any) => tool.name)).toEqual(["company_context", "company_workspace"]);
      const selectedName = `mcp_company_${JSON.parse(shown.stdout).tools.find((tool: any) => tool.name === "company_workspace").name}`;
      const nativeRead = args("read", { view: created.value.view, revision: saved.value.revision, path: "documents/team/mcp.txt" });
      const inference = model(f, (body, count) => {
        if (count === 1) return { tool_calls: [{ index: 0, id: "select-company", type: "function", function: { name: "mcp_select_tool", arguments: JSON.stringify({ name: selectedName }) } }] };
        if (count === 2) {
          expect(body.tools.some((tool: any) => tool.function.name === selectedName)).toBe(true);
          return { tool_calls: [{ index: 0, id: "read-company", type: "function", function: { name: selectedName, arguments: JSON.stringify(nativeRead) } }] };
        }
        expect(JSON.stringify(body.messages)).toContain(Buffer.from("A native Fossil checkpoint from MCP").toString("base64"));
        return { content: "The native agent inspected the exact company document through MCP." };
      });
      const native = await f.run(["ask", "--no-save", "--json", "Read the scoped company document using its advertised MCP tool"], { FX_MCP_ENGINE: "v2" });
      expect(native.code, native.stderr + native.stdout).toBe(0);
      expect(inference.counts().actors).toBe(3);
      const current = await admin({ action: "status" });
      await admin({ action: "revoke", revision: current.revision, id: "mcp-editor" });
      expect((await call("company_workspace", args("read", { view: created.value.view, revision: saved.value.revision, path: "documents/team/mcp.txt" }))).isError).toBe(true);
      const rejectedConfiguration = async (configuration: string) => {
        const child = Bun.spawn([process.env.OMOS_E2E_MCP_RUNTIME ?? process.execPath, companionEntry, configuration], { env: { HOME: f.home, PATH: process.env.PATH }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
        const stdout = new Response(child.stdout).text(), stderr = new Response(child.stderr).text();
        expect(await child.exited).toBe(1);
        expect(await stdout).toBe("");
        expect(await stderr).toBe("Company MCP configuration could not be loaded. Check its private path, permissions, identity pins, and key handle.\n");
      };
      const beforeConfigFailures = posts;
      chmodSync(filename, 0o644);
      await rejectedConfiguration(filename);
      chmodSync(filename, 0o600);
      const alias = join(f.home, "company-config-link.json");
      symlinkSync(filename, alias);
      await rejectedConfiguration(alias);
      const keyFile = join(f.home, ".fx/company-keys/mcp-worker.seed");
      chmodSync(keyFile, 0o644);
      await rejectedConfiguration(filename);
      chmodSync(keyFile, 0o600);
      writeFileSync(filename, JSON.stringify({ ...config, endpoint: "http://company.example" }));
      await rejectedConfiguration(filename);
      expect(posts).toBe(beforeConfigFailures);
    } finally { releaseResponse?.(); await client.close(); proxy.stop(true); redirect.stop(true); service.child.kill(); await service.child.exited; }
    expect(await client.stderr).toBe("");
  }, 150000);
  test("reports executable flag changes from immutable manifests when Fossil's brief diff is empty", async () => {
    const f = fixture();
    let phase = "seed", seeded = false;
    const content = "#!/bin/sh\nprintf portable\\n\n";
    model(f, () => phase === "seed" && !seeded ? (seeded = true, { tool_calls: [{ index: 0, id: "seed-script", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "skills/run.sh", content }) } }] }) : { content: "The portable script is retained." }, () => phase === "seed" ? "met" : "blocked");
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    expect((await f.run(["ask", "Save the portable script", "--json"])).code).toBe(0);
    phase = "mode";
    expect((await f.run(["ask", "Retain a pending executable flag change", "--json"])).code).toBe(1);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((task: any) => task.state !== "accepted");
    const tree = join(f.home, "mode-checkout");
    mkdirSync(tree);
    const command = (...args: string[]) => {
      const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
      const result = spawnSync(existsSync(helper) ? helper : "fossil", ["--user", "omos", ...args], { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
      return result.stdout;
    };
    command("open", join(f.cwd, "omos.fossil"), task.branch, "--nosync");
    chmodSync(join(tree, "skills/run.sh"), 0o700);
    expect(command("changes", "--hash", "--differ")).toContain("EXECUTABLE");
    command("commit", "--nosign", "--nosync", "-m", "Record executable flag in the fixture");
    expect(command("diff", "--internal", "--brief", "--from", task.base_revision, "--to", "current")).not.toContain("skills/run.sh");
    const diff = await f.run(["fossil", "diff", task.id, "--json"]);
    expect(diff.code, diff.stderr).toBe(0);
    expect(JSON.parse(diff.stdout).detail).toContain("Mode skills/run.sh: regular -> executable");
    expect(f.fossil("cat", "skills/run.sh", "-r", task.branch)).toBe(content);
    // Historical hosts saved the 40-character SHA-3 display abbreviation.
    const taskPath = join(tree, "tasks", `${task.id}.json`);
    const legacy = JSON.parse(readFileSync(taskPath, "utf8"));
    legacy.base_revision = legacy.base_revision.slice(0, 40);
    writeFileSync(taskPath, JSON.stringify(legacy));
    command("commit", "--nosign", "--nosync", "-m", "Retain a historical abbreviated task base in the fixture");
    const cache = join(f.home, ".fx/fossil", createHash("sha256").update(join(f.cwd, "omos.fossil")).digest("hex"));
    rmSync(join(cache, "tasks"), { recursive: true });
    const legacyDiff = await f.run(["fossil", "diff", task.id, "--json"]);
    expect(legacyDiff.code, legacyDiff.stderr).toBe(0);
    expect(JSON.parse(legacyDiff.stdout).detail).toContain("Mode skills/run.sh: regular -> executable");
  }, 90000);

  for (const interrupted of [false, true]) test(`explicitly relocates copied personal work and requires validation in the new project${interrupted ? " after interruption" : ""}`, async () => {
    const original = fixture();
    const producer = model(original, (_body, count) => count <= 2 ? { tool_calls: [{ index: 0, id: `original-check-${count}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: "printf 'Original source checked'", timeout_ms: 1000 } }) } }] } : { content: "The original source check passed; the task remains paused." }, () => "blocked", {
      plan: { capability: "coding_task", summary: "Verify the source before accepting the requested change", obligations: [], checks: ["Check the current source"] },
    });
    expect((await original.run(["fossil", "init"])).code).toBe(0);
    expect((await original.run(["ask", "Verify this source change and retain its coding checks", "--json"])).code).toBe(1);
    const before = JSON.parse((await original.run(["fossil", "status", "--json"])).stdout);
    const task = before.tasks[0];
    const history = original.fossil("ls", "-r", task.branch).split("\n").filter(path => path.startsWith(`history/${task.id}/`));
    expect(history.some(path => JSON.parse(original.fossil("cat", path, "-r", task.branch)).kind === "source_validation")).toBe(true);

    const restored = fixture();
    let phase = "setup";
    let freshChecks = 0;
    const consumer = model(restored, () => {
      if (phase === "validate" && freshChecks < 2) {
        freshChecks++;
        return { tool_calls: [{ index: 0, id: `relocated-check-${freshChecks}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: "printf 'Relocated source checked'", timeout_ms: 1000 } }) } }] };
      }
      return { content: "The retained source task and its requirements are preserved." };
    }, () => phase === "setup" ? "blocked" : "met");
    const repository = join(restored.cwd, "omos.fossil");
    expect((await original.run(["fossil", "export", repository, "--json"])).code).toBe(0);
    expect((await restored.run(["fossil", "use", repository, "--json"])).code).toBe(0);
    const sessionResult = await restored.run(["ask", "Open a fresh local session", "--json"]);
    expect(sessionResult.code).toBe(1);
    const session = JSON.parse(sessionResult.stdout).session_id;
    const localCache = join(restored.home, ".fx/fossil", createHash("sha256").update(repository).digest("hex"));
    const checkpoints = join(localCache, "checkpoints");
    mkdirSync(checkpoints, { recursive: true });
    writeFileSync(join(checkpoints, task.id), "Private provider checkpoint retained for the old project");
    let native = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: restored.cwd, env: { ...process.env, ...restored.env, ...(interrupted ? { FX_E2E_FOSSIL_FAULT: "project-rebind-committed" } : {}) } });
    let selected: any;
    try {
      let revision = restored.fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
      await expect(native.request("task.resume", { session, task: task.id, revision })).rejects.toThrow("TaskProjectMismatch");
      if (interrupted) {
        await expect(native.request("task.resume", { session, task: task.id, revision, rebind_project: true })).rejects.toThrow("WorkspaceInjectedFailure");
        await native.close();
        native = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: restored.cwd, env: { ...process.env, ...restored.env } });
        revision = restored.fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
      }
      selected = await native.request("task.resume", { session, task: task.id, revision, rebind_project: true });
      expect(selected.id).toBe(task.id);
      expect(selected.branch).toBe(task.branch);
      expect(selected.project_root).toBe(restored.cwd);
      expect(selected.definition).toEqual({ ...task.definition, version: task.definition.version + 1 });
      expect(selected.model_basis).toEqual(task.model_basis);
      expect(selected.amendments).toEqual(task.amendments);
      expect(selected.source_validation_version).toBe(selected.definition.version);
      if (!interrupted) await expect(native.request("task.resume", { session, task: task.id, revision, rebind_project: true })).rejects.toThrow("WorkspaceRevisionChanged");
    } finally { await native.close(); }
    const relocatedHistory = restored.fossil("ls", "-r", task.branch).split("\n").filter(path => path.startsWith(`history/${task.id}/`));
    for (const path of history) expect(relocatedHistory).toContain(path);
    const relocations = relocatedHistory.map(path => JSON.parse(restored.fossil("cat", path, "-r", task.branch))).filter(row => row.kind === "project_rebind");
    expect(relocations.length).toBe(1);
    const relocation = relocations[0];
    expect(relocation.value.previous_project).toBe(original.cwd);
    expect(relocation.value.project).toBe(restored.cwd);
    expect(relocation.value.previous_contract).toEqual(task.definition);
    expect(existsSync(join(checkpoints, task.id))).toBe(false);
    expect(readFileSync(join(checkpoints, `${task.id}.project-${selected.definition.version}.invalidated`), "utf8")).toBe("Private provider checkpoint retained for the old project");
    rmSync(join(localCache, "tasks"), { recursive: true });
    rmSync(join(localCache, "sessions"), { recursive: true });
    const rebuilt = JSON.parse((await restored.run(["fossil", "status", "--json"])).stdout).tasks.find((item: any) => item.id === task.id);
    expect(rebuilt.project_root).toBe(restored.cwd);
    expect(rebuilt.source_validation_version).toBe(selected.definition.version);

    phase = "stale-check";
    const priorAssessments = consumer.counts().assessments;
    const stale = await restored.run(["ask", "--resume-id", session, "continue", "--json"], { FX_MAX_AGENT_STEPS: "1" });
    expect(stale.code, stale.stdout + stale.stderr).toBe(1);
    expect(consumer.counts().assessments).toBeGreaterThan(priorAssessments);
    expect(JSON.parse((await restored.run(["fossil", "tasks", "--json"])).stdout).tasks.find((item: any) => item.id === task.id).state).not.toBe("accepted");
    phase = "validate";
    const accepted = await restored.run(["ask", "--resume-id", session, "Run fresh validation in this project and finish the retained task", "--json"]);
    expect(accepted.code, accepted.stdout + accepted.stderr).toBe(0);
    expect(freshChecks).toBe(2);
    expect(consumer.counts().actors).toBeGreaterThan(1);
    expect(producer.counts().actors).toBe(3);
    expect(JSON.parse((await original.run(["fossil", "tasks", "--json"])).stdout).tasks[0]).toEqual(task);
  }, 240000);

  test("fences the old project after a relocation commits before its cache update", async () => {
    const f = fixture();
    const inference = model(f, () => ({ content: "The retained answer remains blocked." }), () => "blocked");
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const initial = await f.run(["ask", "Retain this task for explicit relocation", "--json"]);
    expect(initial.code).toBe(1);
    const session = JSON.parse(initial.stdout).session_id;
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const project = join(f.home, "relocated-project");
    mkdirSync(project);
    const native = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project, env: { ...process.env, ...f.env, FX_E2E_FOSSIL_FAULT: "project-rebind-committed" } });
    try {
      const revision = f.fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
      await expect(native.request("task.resume", { session, task: task.id, revision, rebind_project: true })).rejects.toThrow("WorkspaceInjectedFailure");
    } finally { await native.close(); }
    const calls = inference.counts();
    const oldProject = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(oldProject.code, oldProject.stdout + oldProject.stderr).toBe(1);
    expect(oldProject.stdout + oldProject.stderr).toContain("TaskProjectMismatch");
    expect(inference.counts()).toEqual(calls);
    const refreshed = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(refreshed.project_root).toBe(project);
    expect(refreshed.definition.version).toBe(task.definition.version + 1);
  }, 90000);

  for (const staleBase of [false, true]) test(`restores canonical task context from a same-version cache${staleBase ? " after its base drifts" : " without losing buffered reads"}`, async () => {
    const f = fixture();
    let permit = false;
    const content = "Retained recovery information";
    const inference = model(f, (_body, count) => count === 1 ? writeMemory(content) : { content: "The retained information is saved." }, packet => permit ? "met" : {
      name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["unseen-fixture"], note: "Retain the candidate for the cache fixture" }] },
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const initial = await f.run(["ask", "Retain the recovery information", "--json"]);
    expect(initial.code).toBe(1);
    const session = JSON.parse(initial.stdout).session_id;
    const status = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const task = status.tasks[0];
    const cache = join(f.home, ".fx/fossil", createHash("sha256").update(status.repository).digest("hex"));
    const localTask = join(cache, "tasks", `${task.id}.json`);
    const changed = structuredClone(task);
    changed.definition.objective = "An incorrect cached objective";
    changed.model_basis.capability = "unbound-cache-capability";
    changed.authority = { actor: "cache-only", grant: "cache-only" };
    changed.project_root = f.home;
    changed.parent = `task/${"0".repeat(64)}`;
    const buffered = { path: "memory/preference.md", base_hash: null, observed_hash: createHash("sha256").update(content).digest("hex") };
    changed.dependencies = [buffered];
    if (staleBase) changed.base_revision = f.fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
    writeFileSync(localTask, JSON.stringify(changed));
    permit = true;
    const calls = inference.counts().actors;
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
    expect(inference.counts().actors).toBe(calls);
    const restored = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(restored.definition).toEqual(task.definition);
    expect(restored.model_basis).toEqual(task.model_basis);
    expect(restored.authority).toBeNull();
    expect(restored.project_root).toBe(task.project_root);
    expect(restored.parent).toBe(task.parent);
    expect(restored.base_revision).toBe(task.base_revision);
    expect(restored.dependencies).toEqual(staleBase ? task.dependencies : [buffered]);
    expect(restored.state).toBe("accepted");
  }, 120000);

  test("requires successful integrity reports and preserves private branches in a portable export", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const realFossil = spawnSync("which", ["fossil"], { encoding: "utf8" }).stdout.trim();
    const helper = join(f.home, "unsuccessful-integrity.py");
    writeFileSync(helper, `#!/usr/bin/env python3
import subprocess, sys
if "test-integrity" in sys.argv[1:]:
    print("1 non-phantom blobs (out of 1 total) checked:  1 errors")
    print("low-level database integrity-check: ok")
    sys.exit(0)
result = subprocess.run([${JSON.stringify(realFossil)}, *sys.argv[1:]])
sys.exit(result.returncode)
`, { mode: 0o700 });
    const refused = await f.run(["fossil", "verify", "--json"], { OMOS_FOSSIL_BIN: helper });
    expect(refused.code).toBe(1);
    expect(refused.stdout + refused.stderr).toContain("WorkspaceVerificationFailed");
    const branch = `task/${"1".repeat(64)}`;
    f.fossil("--user", "omos", "branch", "new", branch, "trunk", "--private", "--nosign");
    const tree = join(f.home, "private-checkout");
    mkdirSync(tree);
    const env = { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" };
    const command = (...args: string[]) => {
      const result = spawnSync(realFossil, ["--user", "omos", ...args], { cwd: tree, env, encoding: "utf8", timeout: 30000 });
      expect(result.status, result.stderr).toBe(0);
      return result.stdout;
    };
    command("open", join(f.cwd, "omos.fossil"), branch);
    mkdirSync(join(tree, "memory"));
    writeFileSync(join(tree, "memory/private-note.md"), "Retained private proposal content.");
    command("addremove");
    command("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain a private fixture proposal");
    const destination = join(f.home, "complete-private-export.fossil");
    const exported = await f.run(["fossil", "export", destination, "--json"]);
    expect(exported.code, exported.stderr + exported.stdout).toBe(0);
    expect(command("cat", "memory/private-note.md", "-r", branch, "-R", destination)).toBe("Retained private proposal content.");
    const restored = fixture();
    const opened = await restored.run(["fossil", "use", destination, "--json"]);
    expect(opened.code, opened.stderr + opened.stdout).toBe(0);
    expect((await restored.run(["fossil", "verify", "--json"])).code).toBe(0);
  }, 120000);

  test("verifies large shared history through bounded batches without trusting a changed copy of a record", async () => {
    const f = fixture();
    const inference = model(f, () => ({ content: "The informational answer is retained." }));
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const initial = await f.run(["ask", "Give the fixture information", "--json"]);
    expect(initial.code, initial.stderr).toBe(0);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const tree = join(f.home, "history-checkout");
    mkdirSync(tree);
    const realFossil = spawnSync("which", ["fossil"], { encoding: "utf8" }).stdout.trim();
    const environment = { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" };
    const command = (...args: string[]) => {
      const result = spawnSync(realFossil, ["--user", "omos", ...args], { cwd: tree, env: environment, encoding: "utf8", timeout: 30000 });
      expect(result.status, result.stderr).toBe(0);
      return result.stdout;
    };
    command("open", join(f.cwd, "omos.fossil"), task.branch);
    const directory = join(tree, "history", task.id);
    mkdirSync(directory, { recursive: true });
    let firstPath = "";
    let total = 0;
    for (let index = 0; index < 32; index++) {
      const bytes = JSON.stringify({ kind: "fixture_evidence", task: task.id, contract_version: task.definition.version, value: { index, content: "x".repeat(384 * 1024) } });
      const path = `history/${task.id}/${createHash("sha256").update(bytes).digest("hex")}.json`;
      if (index === 0) firstPath = path;
      writeFileSync(join(tree, path), bytes);
      total += Buffer.byteLength(bytes);
    }
    expect(total).toBeGreaterThan(8 * 1024 * 1024);
    mkdirSync(join(tree, "memory"), { recursive: true });
    writeFileSync(join(tree, "memory", "with space .md"), "A literal filename with spaces.");
    command("addremove");
    command("commit", "--hash", "--delta", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain fixture evidence");
    const artifact = f.fossil("artifact", task.branch);
    expect(artifact).toContain("B ");
    for (let index = 1; index <= 12; index++) command("branch", "new", `task/${index.toString(16).padStart(64, "0")}`, task.branch, "--nosign");
    const countFile = join(f.home, "verification-commands.jsonl");
    const helper = join(f.home, "counting-fossil.py");
    writeFileSync(helper, `#!/usr/bin/env python3
import json, pathlib, subprocess, sys
with pathlib.Path(${JSON.stringify(countFile)}).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
result = subprocess.run([${JSON.stringify(realFossil)}, *sys.argv[1:]])
sys.exit(result.returncode)
`, { mode: 0o700 });
    const verified = await f.run(["fossil", "verify", "--json"], { OMOS_FOSSIL_BIN: helper }, 90000);
    expect(verified.code, verified.stderr + verified.stdout).toBe(0);
    const commands = readFileSync(countFile, "utf8").trim().split("\n").map(line => JSON.parse(line));
    const historyReads = commands.filter(args => args.includes("cat") && args.some((arg: string) => arg.startsWith(`history/${task.id}/`)));
    expect(historyReads.length).toBeLessThan(20);
    expect(historyReads.some(args => args.filter((arg: string) => arg.startsWith("history/")).length > 1)).toBe(true);
    // A different artifact under an already verified pathname must be read
    // and rejected. A filename cache would silently accept this corruption.
    const badBranch = `task/${"f".repeat(64)}`;
    command("branch", "new", badBranch, task.branch, "--nosign");
    command("update", "--nosync", badBranch);
    writeFileSync(join(tree, firstPath), JSON.stringify({ kind: "altered_fixture_record", value: "Different bytes under the old identity" }));
    command("commit", "--hash", "--delta", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Alter a fixture record");
    const refused = await f.run(["fossil", "verify", "--json"], {}, 90000);
    expect(refused.code).toBe(1);
    expect(refused.stdout + refused.stderr).toContain("InvalidWorkspaceJournal");
    expect(inference.counts().actors).toBe(1);
  }, 180000);

  test("fences shared task execution across sessions and releases ownership after a crashed runtime", async () => {
    const f = fixture();
    let phase = "setup";
    let taskId = "";
    let held = false;
    let entered!: () => void;
    let release!: () => void;
    const reviewing = new Promise<void>(resolve => { entered = resolve; });
    const gate = new Promise<void>(resolve => { release = resolve; });
    const inference = model(f, () => ({ content: "The informational answer is retained." }), async packet => {
      if (phase === "setup") return { name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["unseen-fixture"], note: "Retain the candidate for this fixture" }] } };
      if (!held && phase === "hold" && packet.contract.id === taskId) { held = true; entered(); await gate; }
      return "met";
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const first = await f.run(["ask", "Give a first retained answer", "--json"]);
    const second = await f.run(["ask", "Give a second retained answer", "--json"]);
    expect(first.code).toBe(1);
    expect(second.code).toBe(1);
    const firstSession = JSON.parse(first.stdout).session_id;
    const secondSession = JSON.parse(second.stdout).session_id;
    const tasks = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks;
    const task = tasks.find((item: any) => item.session === createHash("sha256").update(firstSession).digest("hex"));
    taskId = task.id;
    const native = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: f.cwd, env: { ...process.env, ...f.env } });
    let child: ReturnType<typeof Bun.spawn> | undefined;
    try {
      const fullRevision = () => f.fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
      expect((await native.request("task.resume", { session: secondSession, task: task.id, revision: fullRevision() })).id).toBe(task.id);
      phase = "hold";
      child = Bun.spawn([join(import.meta.dir, "../../zig-out/bin/fx"), "ask", "--resume-id", firstSession, "continue", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
      await Promise.race([reviewing, Bun.sleep(30000).then(() => { throw Error("The owning runtime never reached assessment"); })]);
      const calls = inference.counts();
      const contested = await f.run(["ask", "--resume-id", secondSession, "continue", "--json"]);
      expect(contested.code).toBe(1);
      expect(contested.stdout + contested.stderr).toContain("WorkspaceExecutionBusy");
      expect(inference.counts()).toEqual(calls);
      await expect(native.request("task.resume", { session: "another-session", task: task.id, revision: fullRevision() })).rejects.toThrow("WorkspaceExecutionBusy");
      const independent = await f.run(["ask", "Answer an independent informational request", "--json"]);
      expect(independent.code, independent.stderr).toBe(0);
      expect(child.exitCode).toBeNull();
      child.kill("SIGKILL");
      await child.exited;
      release();
      phase = "resume";
      const actors = inference.counts().actors;
      const resumed = await f.run(["ask", "--resume-id", secondSession, "continue", "--json"]);
      expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
      expect(inference.counts().actors).toBe(actors);
      expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((item: any) => item.id === task.id).state).toBe("accepted");
    } finally { if (child) { child.kill(); await child.exited; } release(); await native.close(); }
  }, 180000);

  test("resumes verification after an abrupt assessment stop and index loss without repeating completed work", async () => {
    const f = fixture();
    let markReviewing!: () => void;
    let release!: () => void;
    let initial = true;
    const reviewing = new Promise<void>(resolve => { markReviewing = resolve; });
    const gate = new Promise<void>(resolve => { release = resolve; });
    const inference = model(f, (_body, count) => count === 1 ? writeMemory("One completed effect before assessment.") : { content: "The preference was saved exactly once." }, async () => {
      if (initial) { initial = false; markReviewing(); await gate; }
      return "met";
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const child = Bun.spawn([join(import.meta.dir, "../../zig-out/bin/fx"), "ask", "Remember the preference and verify it", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    try {
      await Promise.race([reviewing, Bun.sleep(30000).then(() => { throw Error("The original assessment never started"); })]);
      child.kill("SIGKILL");
      await child.exited;
      release();
      const state = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
      const task = state.tasks[0];
      const history = f.fossil("ls", "-r", task.branch).trim().split("\n").filter((path: string) => path.startsWith(`history/${task.id}/`)).map((path: string) => JSON.parse(f.fossil("cat", path, "-r", task.branch)));
      expect(history.some((row: any) => row.kind === "review_candidate")).toBe(true);
      expect(history.some((row: any) => row.kind === "review_failure")).toBe(false);
      const sessions = JSON.parse((await f.run(["sessions", "--all", "--json"])).stdout).sessions;
      const session = sessions.find((item: any) => createHash("sha256").update(item.id).digest("hex") === task.session).id;
      const cache = join(f.home, ".fx/fossil", createHash("sha256").update(state.repository).digest("hex"));
      rmSync(join(cache, "tasks"), { recursive: true });
      rmSync(join(cache, "sessions"), { recursive: true });
      const calls = inference.counts().actors;
      const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
      expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
      expect(inference.counts().actors).toBe(calls);
      expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("One completed effect before assessment.");
      expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0].state).toBe("accepted");
    } finally { child.kill(); await child.exited; release(); }
  }, 120000);

  test("rebuilds interrupted task indexes and restores a newer selected task beyond the last export", async () => {
    const f = fixture();
    let permit = true;
    const inference = model(f, () => ({ content: "The informational answer is retained." }), packet => permit ? "met" : {
      name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["unseen-fixture"], note: "Rejected fixture assessment" }] },
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const first = await f.run(["ask", "Give the first informational answer", "--json"]);
    expect(first.code, first.stderr).toBe(0);
    const session = JSON.parse(first.stdout).session_id;
    expect((await f.run(["fossil", "export", join(f.home, "older-export.fossil")])).code).toBe(0);
    permit = false;
    const second = await f.run(["ask", "--resume-id", session, "Give a second distinct informational answer", "--json"]);
    expect(second.code).toBe(1);
    const before = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const pending = before.tasks.find((task: any) => task.state !== "accepted");
    expect(pending).toBeDefined();
    const cache = join(f.home, ".fx/fossil", createHash("sha256").update(before.repository).digest("hex"));
    rmSync(join(cache, "tasks"), { recursive: true });
    rmSync(join(cache, "sessions"), { recursive: true });
    const interrupted = await f.run(["fossil", "status", "--json"], { FX_E2E_FOSSIL_FAULT: "registry-task-restored" });
    expect(interrupted.code).toBe(1);
    expect(existsSync(join(cache, "restore.pending"))).toBe(true);
    const restored = await f.run(["fossil", "tasks", "--json"]);
    expect(restored.code, restored.stderr).toBe(0);
    expect(JSON.parse(restored.stdout).tasks.map((task: any) => task.id).sort()).toEqual(before.tasks.map((task: any) => task.id).sort());
    expect(existsSync(join(cache, "restore.pending"))).toBe(false);
    const selectedSession = createHash("sha256").update(session).digest("hex");
    expect(readFileSync(join(cache, "sessions", selectedSession), "utf8")).toBe(pending.id);
    const events = JSON.parse((await f.run(["fossil", "query", "omos_event", "--json"])).stdout).model_data;
    expect(events.records.some((row: any) => row.data.kind === "session_binding" && row.data.payload.session === selectedSession && row.data.task === pending.id)).toBe(true);
    const calls = inference.counts().actors;
    permit = true;
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(inference.counts().actors).toBe(calls);
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.every((task: any) => task.state === "accepted")).toBe(true);
  }, 120000);

  test("restores an explicit selection of older work without changing accepted company state", async () => {
    const f = fixture();
    let permit = false;
    const inference = model(f, () => ({ content: "The candidate answer remains retained." }), packet => permit ? "met" : {
      name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["unseen-fixture"], note: "Rejected fixture assessment" }] },
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const first = await f.run(["ask", "Give a first retained answer", "--json"]);
    const second = await f.run(["ask", "Give a later retained answer", "--json"]);
    expect(first.code).toBe(1);
    expect(second.code).toBe(1);
    const secondSession = JSON.parse(second.stdout).session_id;
    const before = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const task = before.tasks.find((task: any) => task.session === createHash("sha256").update(JSON.parse(first.stdout).session_id).digest("hex"));
    const native = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: f.cwd, env: { ...process.env, ...f.env } });
    try {
      const revision = f.fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
      expect((await native.request("task.resume", { session: secondSession, task: task.id, revision })).id).toBe(task.id);
      expect((await native.request("snapshot", { action: "fossil.status" })).trunk_revision).toBe(before.trunk_revision);
    } finally { await native.close(); }
    const cache = join(f.home, ".fx/fossil", createHash("sha256").update(before.repository).digest("hex"));
    rmSync(join(cache, "tasks"), { recursive: true });
    rmSync(join(cache, "sessions"), { recursive: true });
    const restored = await f.run(["fossil", "status", "--json"]);
    expect(restored.code, restored.stderr).toBe(0);
    expect(readFileSync(join(cache, "sessions", createHash("sha256").update(secondSession).digest("hex")), "utf8")).toBe(task.id);
    permit = true;
    const calls = inference.counts().actors;
    const resumed = await f.run(["ask", "--resume-id", secondSession, "continue", "--json"]);
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(inference.counts().actors).toBe(calls);
    const after = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks;
    expect(after.find((item: any) => item.id === task.id).state).toBe("accepted");
    expect(after.find((item: any) => item.id !== task.id).state).not.toBe("accepted");
  }, 120000);

  test("authenticates scoped company views, fences concurrent checkpoints, retains outcomes and revokes access", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (request: object) => {
      const file = join(f.home, "company-admin.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...request }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    const publicKey = key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
    let control = await admin({ action: "grant", revision: initialized.revision, grant: {
      id: "alice-team", actor: "alice", public_key: publicKey, paths: ["documents/team/"],
      actions: ["discover", "read", "create_view", "checkpoint", "submit", "status", "export_scope"], expires_ms: Date.now() + 3600000,
    } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const envelope = (action: string, params: object = {}, operation = crypto.randomUUID()) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "alice", grant: "alice-team", operation, expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const post = async (body: object, headers = {}) => {
      try { return await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close", ...headers }, body: JSON.stringify(body) }); }
      catch (error) {
        service.child.kill(); await service.child.exited;
        throw Error(`${error}\n${await new Response(service.child.stderr).text()}\n${existsSync(f.env.FX_TRACE_LOG) ? readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-12000) : ""}`);
      }
    };
    const unpack = async (response: Response) => {
      const result = await response.json() as any;
      expect(response.status, JSON.stringify(result)).toBe(200);
      const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(result.issuer, "hex")]), format: "der", type: "spki" });
      expect(result.issuer).toBe(boot.issuer);
      expect(verify(null, Buffer.from(result.payload), issuer, Buffer.from(result.signature, "hex"))).toBe(true);
      return JSON.parse(result.payload).result;
    };
    try {
      const invalid = envelope("discover");
      invalid.signature = "00".repeat(64);
      expect((await post(invalid)).status).toBe(403);
      expect((await post(envelope("discover"), { origin: "https://untrusted.invalid" })).status).toBe(401);
      const create = envelope("create_view", { objective: "Prepare a portable team report", revision: boot.revision });
      const signedFile = join(f.home, "signed-company-request.json");
      writeFileSync(signedFile, JSON.stringify(create));
      const remote = await f.run(["fossil", "remote", service.url, signedFile, "--json"], { OMOS_WORKSPACE_TOKEN: "private-owner-token-must-not-be-forwarded" });
      expect(remote.code, remote.stderr).toBe(0);
      const remotePacket = JSON.parse(remote.stdout);
      expect(remotePacket.workspace_id).toBe(boot.workspace);
      const view = await unpack(Response.json(remotePacket.model_data));
      expect((await unpack(await post(create))).view).toBe(view.view);
      // A rebuildable cache must never erase canonical company authority,
      // including when its contract version still matches the source branch.
      const snapshot = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
      const companyTask = snapshot.tasks.find((task: any) => task.authority?.actor === "alice");
      expect(companyTask).toBeDefined();
      const taskCache = join(f.home, ".fx/fossil", createHash("sha256").update(snapshot.repository).digest("hex"), "tasks", `${companyTask.id}.json`);
      writeFileSync(taskCache, JSON.stringify({ ...companyTask, authority: null }));
      const local = new NativeClient({ binary: join(import.meta.dir, "../../zig-out/bin/fx"), project: f.cwd, env: { ...process.env, ...f.env } });
      try {
        await expect(local.request("task.resume", { session: "company-cache-probe", task: companyTask.id, revision: view.revision, rebind_project: true })).rejects.toThrow("CompanyExecutionIsolationRequired");
      } finally { await local.close(); }
      expect(JSON.parse(readFileSync(taskCache, "utf8")).authority).toEqual(companyTask.authority);
      const a = envelope("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "Team report", previous_hash: null });
      const b = envelope("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/other.md", content: "Other report", previous_hash: null });
      const replies = await Promise.all([post(a), post(b)]);
      expect(replies.map(reply => reply.status).sort()).toEqual([200, 409]);
      const firstIndex = replies[0].status === 200 ? 0 : 1;
      const successful = await unpack(replies[firstIndex]);
      const acceptedRequest = firstIndex === 0 ? a : b;
      expect(await unpack(await post(acceptedRequest))).toEqual(successful);
      expect(await unpack(await post({ signature: acceptedRequest.signature.toUpperCase(), payload: acceptedRequest.payload }))).toEqual(successful);
      const changed = JSON.parse(acceptedRequest.payload);
      const changedRequest = envelope("checkpoint", { ...changed, content: "Changed operation" }, changed.operation);
      expect((await post(changedRequest)).status).toBe(409);
      const denied = envelope("checkpoint", { view: view.view, revision: successful.revision, path: "documents/private/report.md", content: "leak" });
      expect((await post(denied)).status).toBe(403);
      const inventory = await unpack(await post(envelope("export_scope", { view: view.view, revision: successful.revision })));
      expect(inventory.files).toHaveLength(1);
      expect(inventory.files[0].path.startsWith("documents/team/")).toBe(true);
      expect(inventory.authority).toBe("content_only");
      expect(inventory.files[0].executable).toBeUndefined();
      const attributes = await unpack(await post(envelope("export_scope", { version: "omos.company/v2", view: view.view, revision: successful.revision })));
      expect(attributes.version).toBe("omos.scoped-export/v2");
      expect(attributes.files[0].executable).toBe(false);
      const modeRead = await unpack(await post(envelope("read", { version: "omos.company/v2", view: view.view, revision: successful.revision, path: inventory.files[0].path, limit: 4 })));
      expect(modeRead.executable).toBe(false);
      expect(boot.features.checkpoint_attributes).toBe(true);
      const file = inventory.files[0], originalContent = JSON.parse(acceptedRequest.payload).content;
      const missingMode = envelope("checkpoint", { view: view.view, revision: successful.revision, path: file.path, content: originalContent, previous_hash: file.sha256, executable: true });
      const invalidMode = await post(missingMode);
      expect(invalidMode.status).toBe(400);
      expect((await invalidMode.json() as any).error).toBe("InvalidCompanyFileAttributes");
      expect((await unpack(await post(envelope("status", { outcome: JSON.parse(missingMode.payload).operation })))).state).toBe("failed");
      const modeRequest = envelope("checkpoint", { view: view.view, revision: successful.revision, path: file.path, content: originalContent, previous_hash: file.sha256, executable: true, previous_executable: false });
      const modeSaved = await unpack(await post(modeRequest));
      expect(await unpack(await post(modeRequest))).toEqual(modeSaved);
      expect((await unpack(await post(envelope("read", { version: "omos.company/v2", view: view.view, revision: modeSaved.revision, path: file.path })))).executable).toBe(true);
      const mismatchedMode = await post(envelope("checkpoint", { view: view.view, revision: modeSaved.revision, path: file.path, content: originalContent, previous_hash: file.sha256, executable: false, previous_executable: false }));
      expect(mismatchedMode.status).toBe(409);
      expect((await mismatchedMode.json() as any).error).toBe("WorkspaceProjectionConflict");
      const editedContent = originalContent + " updated";
      const legacyEdit = await unpack(await post(envelope("checkpoint", { view: view.view, revision: modeSaved.revision, path: file.path, content: editedContent, previous_hash: file.sha256 })));
      expect((await unpack(await post(envelope("read", { version: "omos.company/v2", view: view.view, revision: legacyEdit.revision, path: file.path })))).executable).toBe(true);
      const modeRemoved = await unpack(await post(envelope("checkpoint", { view: view.view, revision: legacyEdit.revision, path: file.path, content: editedContent, previous_hash: createHash("sha256").update(editedContent).digest("hex"), executable: false, previous_executable: true })));
      expect((await unpack(await post(envelope("read", { version: "omos.company/v2", view: view.view, revision: modeRemoved.revision, path: file.path })))).executable).toBe(false);
      expect((await post(envelope("checkpoint", { version: "omos.company/v2", view: view.view, revision: successful.revision, path: "documents/team/forbidden-v2.md", content: "Unsupported mutation representation" }))).status).toBe(403);
      const read = await unpack(await post(envelope("read", { view: view.view, revision: successful.revision, path: inventory.files[0].path, limit: 4 })));
      expect(read.next_offset).toBe(4);
      expect(Buffer.from(read.content, "base64").length).toBe(4);
      const otherKey = generateKeyPairSync("ed25519");
      control = await admin({ action: "status" });
      control = await admin({ action: "grant", revision: control.revision, grant: {
        id: "bob-team", actor: "bob", public_key: otherKey.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["read"], expires_ms: Date.now() + 3600000,
      } });
      const stolenPayload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "bob", grant: "bob-team", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action: "read", path: inventory.files[0].path, revision: successful.revision });
      expect((await post({ payload: stolenPayload, signature: sign(null, Buffer.from(stolenPayload), otherKey.privateKey).toString("hex") })).status).toBe(403);
      service.child.kill();
      await service.child.exited;
      service = await startWorkspaceService(f, true);
      expect(await unpack(await post(acceptedRequest))).toEqual(successful);
      // Administrative revisions include operations as well as grants.
      control = await admin({ action: "status" });
      await admin({ action: "revoke", revision: control.revision, id: "alice-team" });
      expect((await post(acceptedRequest)).status).toBe(403);
      expect((await post(envelope("read", { view: view.view, revision: successful.revision, path: inventory.files[0].path }))).status).toBe(403);
    } finally {
      service.child.kill();
      await service.child.exited;
    }
  }, 120000);

  test("queries and updates declared company records with scoped counts, stable identities and protected host state", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = JSON.parse(f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    declaration.spec.semantic.entityTypes.push({ id: "company_note", fields: { text: "string", authorization: "string", detail: "json" }, required: ["text"] });
    const definitionFile = join(f.home, "company-definition.json");
    writeFileSync(definitionFile, JSON.stringify(declaration));
    const proposed = await f.run(["fossil", "definition", "propose", definitionFile, "--json"]);
    expect(proposed.code, proposed.stderr + proposed.stdout).toBe(0);
    const inference = model(f, (_body, count) => count === 1 ? { tool_calls: [{ index: 0, id: "private-record", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "record", entity: "company_note", content: JSON.stringify({ text: "Outside the scoped actor's records" }) }) } }] } : { content: "The private company record is retained." });
    const seeded = await f.run(["ask", "Retain the private company note", "--json"]);
    expect(seeded.code, seeded.stderr).toBe(0);
    const privatePath = f.fossil("ls", "-r", "trunk").trim().split("\n").find((path: string) => path.startsWith("records/company_note/"))!;
    const privateAlias = privatePath.replace(/[^/]+$/, (name: string) => name.toUpperCase());
    f.fossil("settings", "case-sensitive", "off");
    expect(f.fossil("cat", privateAlias, "-r", "trunk")).toContain("Outside the scoped actor's records");
    const actorCalls = inference.counts().actors;
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const company = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: company.revision, grant: { id: "record-editor", actor: "editor", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: [...["alpha", "beta", "large", "ALPHA"].map(id => `records/company_note/${id}.json`), privateAlias], actions: ["create_view", "record", "checkpoint", "query", "read", "submit", "status", "reconcile"], expires_ms: Date.now() + 3600000 } });
    const service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const envelope = (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "editor", grant: "record-editor", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const post = (body: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(body) });
    const unpack = async (response: Response, action = "retry") => {
      const result = await response.json() as any;
      expect(response.status, JSON.stringify({ action, result })).toBe(200);
      return JSON.parse(result.payload).result;
    };
    const send = async (action: string, params: object = {}) => unpack(await post(envelope(action, params)), JSON.stringify({ action, revision: (params as any).revision, entity: (params as any).entity, record_id: (params as any).record_id, offset: (params as any).offset }));
    try {
      expect(boot.features.typed_records).toBe("custom_entities");
      expect(boot.revision).toHaveLength(64);
      const aliasRead = await post(envelope("read", { revision: boot.revision, path: privateAlias }));
      expect(aliasRead.status).toBe(200);
      const missingAlias = await unpack(aliasRead);
      expect(missingAlias.exists).toBe(false);
      expect(missingAlias.sha256).toBeNull();
      expect(missingAlias.content).toBe("");
      expect((await post(envelope("read", { revision: boot.revision, path: privatePath }))).status).toBe(403);
      const view = await send("create_view", { revision: boot.revision, objective: "Save the updated alpha note and the complete large note" });
      const first = await send("record", { view: view.view, revision: view.revision, entity: "company_note", record_id: "alpha", content: JSON.stringify({ text: "First alpha" }) });
      expect(first.revision).toHaveLength(64);
      const bad = envelope("record", { view: view.view, revision: first.revision, entity: "company_note", record_id: "beta", content: JSON.stringify({ text: 42 }) });
      expect((await post(bad)).status).toBe(400);
      expect((await send("status", { outcome: JSON.parse(bad.payload).operation })).state).toBe("failed");
      const unportable = envelope("record", { view: view.view, revision: first.revision, entity: "company_note", record_id: "beta", content: JSON.stringify({ text: "Preserve every requested field", authorization: "fixture-value" }) });
      const refused = await post(unportable);
      expect(refused.status).toBe(400);
      expect((await refused.json() as any).error).toBe("CompanyRecordNotPortable");
      expect((await send("status", { outcome: JSON.parse(unportable.payload).operation })).state).toBe("failed");
      for (const detail of ["[".repeat(512) + "0" + "]".repeat(512), JSON.stringify(Array(20001).fill(0)), '{"__proto__":{}}']) {
        const excessive = envelope("record", { view: view.view, revision: first.revision, entity: "company_note", record_id: "beta", content: '{"text":"Bound decoded JSON fields","detail":' + detail + '}' });
        const response = await post(excessive);
        expect(response.status).toBe(400);
        expect(["DeclarationTooComplex", "InvalidDeclarationKey"]).toContain((await response.json() as any).error);
        expect((await send("status", { outcome: JSON.parse(excessive.payload).operation })).state).toBe("failed");
        expect((await send("status", { view: view.view })).revision).toBe(first.revision);
      }
      expect((await post(envelope("record", { view: view.view, revision: first.revision, entity: "omos_assessment", record_id: "forged", content: "{}" }))).status).toBe(403);
      expect((await post(envelope("checkpoint", { view: view.view, revision: first.revision, path: first.path, content: "{}" }))).status).toBe(403);
      expect((await post(envelope("record", { view: view.view, revision: first.revision, entity: "company_note", record_id: "ALPHA", content: JSON.stringify({ text: "Conflicting filename case" }) }))).status).toBe(409);
      expect((await send("status", { view: view.view })).revision).toBe(first.revision);
      const beta = await send("record", { view: view.view, revision: first.revision, entity: "company_note", record_id: "beta", content: JSON.stringify({ text: "Second note" }) });
      const page = await send("query", { view: view.view, revision: beta.revision, entity: "company_note", limit: 1 });
      expect(page.total).toBe(2);
      expect(page.records).toHaveLength(1);
      expect(page.next_offset).toBe(1);
      const next = await send("query", { view: view.view, revision: beta.revision, entity: "company_note", offset: page.next_offset, limit: 1 });
      expect(next.records[0].id).not.toBe(page.records[0].id);
      expect(next.next_offset).toBeNull();
      const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((task: any) => task.authority?.grant === "record-editor");
      expect(f.fossil("ls", "-r", task.branch).trim().split("\n").filter((path: string) => path.startsWith("records/company_note/"))).toHaveLength(3);
      const alpha = page.records[0].id === "alpha" ? page.records[0] : next.records[0];
      expect((await post(envelope("record", { view: view.view, revision: beta.revision, entity: "company_note", record_id: "alpha", previous_hash: "00".repeat(32), content: JSON.stringify({ text: "Stale write" }) }))).status).toBe(409);
      const updateEnvelope = envelope("record", { view: view.view, revision: beta.revision, entity: "company_note", record_id: "alpha", previous_hash: alpha.sha256, content: JSON.stringify({ text: "Updated alpha" }) });
      const updated = await unpack(await post(updateEnvelope));
      expect(await unpack(await post(updateEnvelope))).toEqual(updated);
      const largeText = "café ".repeat(2500);
      const large = await send("record", { view: view.view, revision: updated.revision, entity: "company_note", record_id: "large", content: JSON.stringify({ text: largeText }) });
      const rows = await send("query", { view: view.view, revision: large.revision, entity: "company_note" });
      expect(rows.total).toBe(3);
      const largeRow = rows.records.find((row: any) => row.id === "large");
      expect(largeRow.complete).toBe(false);
      expect(largeRow.data).toBeUndefined();
      const segments: Buffer[] = [];
      let offset = 0;
      do {
        const range = await send("read", { view: view.view, revision: large.revision, path: largeRow.source_path, offset, limit: 4096 });
        segments.push(Buffer.from(range.content, "base64"));
        if (range.next_offset === null) break;
        offset = range.next_offset;
      } while (true);
      const original = Buffer.concat(segments);
      expect(createHash("sha256").update(original).digest("hex")).toBe(largeRow.sha256);
      expect(JSON.parse(original.toString("utf8")).data.text).toBe(largeText);
      const betaRow = rows.records.find((row: any) => row.id === "beta");
      const removed = await send("record", { view: view.view, revision: large.revision, entity: "company_note", record_id: "beta", previous_hash: betaRow.sha256, remove: true });
      expect((await send("query", { view: view.view, revision: removed.revision })).total).toBe(2);
      const historical = await send("query", { view: view.view, revision: first.revision, entity: "company_note" });
      expect(historical.total).toBe(1);
      expect(historical.records[0].data.text).toBe("First alpha");
      const legacyReference = await send("query", { view: view.view, revision: first.revision.slice(0, 40), entity: "company_note" });
      expect(legacyReference.revision).toBe(first.revision);
      expect(legacyReference.records).toEqual(historical.records);
      expect(f.fossil("ls", "-r", "trunk")).not.toContain(first.path);
      const submitted = await send("submit", { view: view.view, revision: removed.revision, candidate: "Saved the updated alpha note and complete large note; removed beta." });
      let status: any;
      const deadline = Date.now() + 60000;
      while (Date.now() < deadline) {
        status = await send("status", { view: view.view });
        if (!["queued", "running"].includes(status.job?.state)) break;
        await Bun.sleep(30);
      }
      expect(status.job.id).toBe(submitted.job);
      expect(status.job.state, JSON.stringify(status)).toBe("published");
      expect(JSON.parse(f.fossil("cat", first.path, "-r", "trunk")).data.text).toBe("Updated alpha");
      expect(f.fossil("ls", "-r", "trunk")).not.toContain("records/company_note/beta.json");
      expect(inference.counts().actors).toBe(actorCalls);
    } finally { service.child.kill(); await service.child.exited; }
  }, 180000);

  test("keeps a corrupted checkpoint uncertain instead of trusting its receipt or replaying its commit", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const company = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: company.revision, grant: { id: "checkpoint-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "read", "status", "reconcile", "submit"], expires_ms: Date.now() + 3600000 } });
    const realFossil = spawnSync("which", ["fossil"], { encoding: "utf8" }).stdout.trim();
    const counter = join(f.home, "checkpoint-commits.txt");
    const helper = join(f.home, "corrupt-checkpoint-fossil.py");
    writeFileSync(helper, `#!/usr/bin/env python3
import pathlib, subprocess, sys
if "commit" in sys.argv[1:] and "Checkpoint workspace filesystem changes" in sys.argv[1:]:
    counter = pathlib.Path(${JSON.stringify(counter)})
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    if count == 0:
        pathlib.Path("documents/team/report.md").write_text("Mutated after preparation")
result = subprocess.run([${JSON.stringify(realFossil)}, *sys.argv[1:]])
sys.exit(result.returncode)
`, { mode: 0o700 });
    const service = await startWorkspaceService(f, true, { OMOS_FOSSIL_BIN: helper });
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const envelope = (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "checkpoint-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const post = (body: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(body) });
    const send = async (action: string, params: object = {}) => {
      const response = await post(envelope(action, params));
      const result = await response.json() as any;
      expect(response.status, JSON.stringify({ action, result })).toBe(200);
      return JSON.parse(result.payload).result;
    };
    try {
      const view = await send("create_view", { revision: boot.revision, objective: "Save the prepared team report" });
      const checkpoint = envelope("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "Prepared report" });
      const operation = JSON.parse(checkpoint.payload).operation;
      const failed = await post(checkpoint);
      expect(failed.status).toBe(400);
      expect((await failed.json() as any).error).toBe("WorkspaceVerificationFailed");
      expect((await send("status", { outcome: operation })).state).toBe("uncertain");
      const selected = await send("status", { view: view.view });
      const observed = await send("read", { view: view.view, revision: selected.revision, path: "documents/team/report.md" });
      expect(Buffer.from(observed.content, "base64").toString()).toBe("Mutated after preparation");
      const reconciled = await post(envelope("reconcile", { outcome: operation }));
      expect(reconciled.status).toBe(400);
      expect((await reconciled.json() as any).error).toBe("WorkspaceVerificationFailed");
      expect((await send("status", { outcome: operation })).state).toBe("uncertain");
      expect(readFileSync(counter, "utf8")).toBe("1");
      expect((await post(envelope("submit", { view: view.view, revision: selected.revision, candidate: "The report was saved." }))).status).toBe(400);
      expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/report.md");
    } finally { service.child.kill(); await service.child.exited; }
  }, 120000);

  test("requires an exact unexpired operator approval and still independently verifies company publication", async () => {
    const f = fixture();
    const inference = model(f, () => ({ content: "The original actor must not run during approval or verification." }));
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const adminResult = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      return f.run(["fossil", "company", file, "--json"]);
    };
    const admin = async (body: object) => {
      const result = await adminResult(body);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "approval-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "submit", "status"], expires_ms: Date.now() + 3600000, human_approval: true } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const send = async (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "approval-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
      const body = await response.json() as any;
      expect(response.status, JSON.stringify({ action, body })).toBe(200);
      return JSON.parse(body.payload).result;
    };
    const stop = async () => { service.child.kill(); await service.child.exited; };
    const inspect = async (view: string) => admin({ action: "inspect_proposal", revision: (await admin({ action: "status" })).revision, view });
    const decide = async (action: string, view: string, candidate_hash: string, expires_ms = Date.now() + 300000) => admin({ action, revision: (await admin({ action: "status" })).revision, view, candidate_hash, expires_ms });
    const waitJob = async (view: string, state: string, reason?: string) => {
      const deadline = Date.now() + 60000;
      let observed: any;
      while (Date.now() < deadline) {
        observed = await send("status", { view });
        if (observed.job?.state === state && (reason === undefined || observed.job.reason === reason)) return observed;
        await Bun.sleep(30);
      }
      throw Error(`Company review did not reach ${state}/${reason}: ${JSON.stringify(observed)}`);
    };
    try {
      const view = await send("create_view", { revision: boot.revision, objective: "Save the team report with local operator approval" });
      let saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "First company report" });
      await send("submit", { view: view.view, revision: saved.revision, candidate: "Saved the first team report." });
      await waitJob(view.view, "blocked", "CompanyApprovalRequired");
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
      expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/report.md");
      await stop();
      let inspected = await inspect(view.view);
      expect(inspected.candidate.proposal_revision).toBe(saved.revision);
      expect(inspected.candidate.integration_revision).toBe(saved.revision);
      expect(inspected.approval_required).toBe(true);
      const stale = await adminResult({ action: "approve", revision: inspected.revision, view: view.view, candidate_hash: "0".repeat(64), expires_ms: Date.now() + 300000 });
      expect(stale.code).toBe(1);
      expect(stale.stderr + stale.stdout).toContain("CompanyApprovalStale");
      const invalidExpiry = await adminResult({ action: "approve", revision: inspected.revision, view: view.view, candidate_hash: inspected.candidate_hash, expires_ms: Date.now() + 25 * 3600000 });
      expect(invalidExpiry.code).toBe(1);
      expect(invalidExpiry.stderr + invalidExpiry.stdout).toContain("InvalidCompanyApprovalExpiry");
      await decide("approve", view.view, inspected.candidate_hash);
      // The later operator decision fences even an already queued review.
      await decide("deny", view.view, inspected.candidate_hash);
      service = await startWorkspaceService(f, true);
      await waitJob(view.view, "blocked", "CompanyApprovalDenied");
      expect(inference.counts().assessments).toBe(0);
      await stop();
      const expiryRevision = (await admin({ action: "status" })).revision;
      const expiry = Date.now() + 10000;
      await admin({ action: "approve", revision: expiryRevision, view: view.view, candidate_hash: inspected.candidate_hash, expires_ms: expiry });
      if (Date.now() <= expiry) await Bun.sleep(expiry - Date.now() + 1);
      service = await startWorkspaceService(f, true);
      await waitJob(view.view, "blocked", "CompanyApprovalExpired");
      expect(inference.counts().assessments).toBe(0);
      const current = await send("status", { view: view.view });
      saved = await send("checkpoint", { view: view.view, revision: current.revision, path: "documents/team/report.md", content: "Revised company report", previous_hash: createHash("sha256").update("First company report").digest("hex") });
      await send("submit", { view: view.view, revision: saved.revision, candidate: "Saved the revised team report." });
      // Even renewing the old approval cannot authorize changed proposal bytes.
      await stop();
      const changed = await adminResult({ action: "approve", revision: (await admin({ action: "status" })).revision, view: view.view, candidate_hash: inspected.candidate_hash, expires_ms: Date.now() + 300000 });
      expect(changed.code).toBe(1);
      expect(changed.stderr + changed.stdout).toContain("CompanyApprovalStale");
      inspected = await inspect(view.view);
      const approved = await decide("approve", view.view, inspected.candidate_hash);
      const decision = JSON.parse(approved.decision.payload);
      expect(decision.candidate).toEqual(inspected.candidate);
      expect(decision.approved).toBe(true);
      const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
      expect(verify(null, Buffer.from(approved.decision.payload), issuer, Buffer.from(approved.decision.signature, "hex"))).toBe(true);
      service = await startWorkspaceService(f, true);
      const published = await waitJob(view.view, "published");
      expect(published.state).toBe("accepted");
      expect(inference.counts().actors).toBe(0);
      expect(inference.counts().assessments).toBeGreaterThan(0);
      expect(f.fossil("cat", "documents/team/report.md", "-r", "trunk")).toBe("Revised company report");
      const claims = JSON.parse(published.publication.issuer_proof.payload);
      const approvalBytes = f.fossil("cat", `company/approvals/${view.contract.id}.json`, "-r", claims.authority_revision);
      expect(claims.approval_sha256).toBe(createHash("sha256").update(approvalBytes).digest("hex"));
      await stop();
      const control = await admin({ action: "status" });
      await admin({ action: "revoke", revision: control.revision, id: "approval-worker" });
      const exported = join(f.home, "approved-company.fossil");
      const exportResult = await f.run(["fossil", "export", exported, "--json"]);
      expect(exportResult.code, exportResult.stderr).toBe(0);
      const restored = fixture();
      expect((await restored.run(["fossil", "use", exported, "--json"])).code).toBe(0);
      const verified = await restored.run(["fossil", "verify", "--json"]);
      expect(verified.code, verified.stderr).toBe(0);
      expect(existsSync(join(restored.home, ".fx/authority", boot.workspace))).toBe(false);
    } finally { await stop(); }
  }, 180000);

  test("requires a new operator decision after reconciling an approved proposal onto a newer accepted base", async () => {
    for (const interrupted of [false, true]) {
      const f = fixture();
      const inference = model(f, (_body, count) => count === 1 ? writeMemory("Independent accepted company change") : { content: "Saved the independent memory change." });
      expect((await f.run(["fossil", "init"])).code).toBe(0);
      const admin = async (body: object, failure?: string) => {
        const file = join(f.home, "operator.json");
        writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
        const result = await f.run(["fossil", "company", file, "--json"]);
        if (failure) {
          expect(result.code).toBe(1);
          expect(result.stdout + result.stderr).toContain(failure);
          return null;
        }
        expect(result.code, result.stderr).toBe(0);
        return JSON.parse(result.stdout).model_data;
      };
      const initialized = await admin({ action: "initialize" });
      const key = generateKeyPairSync("ed25519");
      await admin({ action: "grant", revision: initialized.revision, grant: { id: "approval-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "submit", "status"], expires_ms: Date.now() + 3600000, human_approval: true } });
      let service = await startWorkspaceService(f, true);
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      const send = async (action: string, params: object = {}) => {
        const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "approval-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
        const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
        const body = await response.json() as any;
        expect(response.status, JSON.stringify({ action, body })).toBe(200);
        return JSON.parse(body.payload).result;
      };
      const stop = async () => { service.child.kill(); await service.child.exited; };
      const waitJob = async (view: string, state: string, reason?: string) => {
        const deadline = Date.now() + 60000;
        let observed: any;
        while (Date.now() < deadline) {
          observed = await send("status", { view });
          if (observed.job?.state === state && (reason === undefined || observed.job.reason === reason)) return observed;
          await Bun.sleep(30);
        }
        throw Error(`Company review did not reach ${state}/${reason}: ${JSON.stringify(observed)}`);
      };
      const inspect = async (view: string) => admin({ action: "inspect_proposal", revision: (await admin({ action: "status" })).revision, view });
      const approve = async (view: string, candidate_hash: string, failure?: string) => admin({ action: "approve", revision: (await admin({ action: "status" })).revision, view, candidate_hash, expires_ms: Date.now() + 300000 }, failure);
      try {
        const view = await send("create_view", { revision: boot.revision, objective: "Save the approved company report" });
        const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "Approved team report" });
        const candidate = "Saved the approved team report.";
        await send("submit", { view: view.view, revision: saved.revision, candidate });
        await waitJob(view.view, "blocked", "CompanyApprovalRequired");
        await stop();
        const original = await inspect(view.view);
        await approve(view.view, original.candidate_hash);
        const independent = await f.run(["ask", "Save an independent company memory note", "--json"]);
        expect(independent.code, independent.stderr).toBe(0);
        const actorCount = inference.counts().actors;
        expect(actorCount).toBe(2);
        service = await startWorkspaceService(f, true, interrupted ? { FX_E2E_FOSSIL_FAULT: "company-submission-refreshed" } : {});
        // The coordinator now refreshes compatible unpublished proposals itself.
        // That refresh invalidates the exact human decision and cannot publish.
        await waitJob(view.view, interrupted ? "failed" : "blocked", interrupted ? "WorkspaceInjectedFailure" : "CompanyApprovalStale");
        await stop();
        await approve(view.view, original.candidate_hash, "CompanyApprovalStale");
        const integrated = await inspect(view.view);
        expect(integrated.candidate_hash).not.toBe(original.candidate_hash);
        expect(integrated.candidate.base_revision).not.toBe(original.candidate.base_revision);
        expect(integrated.candidate.changes_sha256).toBe(original.candidate.changes_sha256);
        expect(integrated.candidate.proposal_revision).toBe(original.candidate.proposal_revision);
        expect(integrated.candidate.proposal_operation).toBe(original.candidate.proposal_operation);
        expect(integrated.candidate.candidate_sha256).toBe(original.candidate.candidate_sha256);
        if (interrupted) expect(integrated.candidate.integration_revision).toBe(original.candidate.integration_revision);
        else expect(integrated.candidate.integration_revision).not.toBe(original.candidate.integration_revision);
        await approve(view.view, integrated.candidate_hash);
        service = await startWorkspaceService(f, true);
        const published = await waitJob(view.view, "published");
        expect(published.state).toBe("accepted");
        expect(inference.counts().actors).toBe(actorCount);
        expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Independent accepted company change");
        expect(f.fossil("cat", "documents/team/report.md", "-r", "trunk")).toBe("Approved team report");
      } finally { await stop(); }
    }
  }, 240000);

  test("recovers submission preparation, frozen reads and refreshed integration without replaying actors or changing its inputs", async () => {
    for (const stage of ["company-submission-prepared", "company-reads-frozen", "company-submission-refreshed"]) {
      const f = fixture();
      const inference = model(f, (_body, count) => count === 1 ? writeMemory("Independent accepted state") : { content: "Retained the independent company note." });
      expect((await f.run(["fossil", "init"])).code).toBe(0);
      const admin = async (body: object) => {
        const file = join(f.home, "operator.json");
        writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
        const result = await f.run(["fossil", "company", file, "--json"]);
        expect(result.code, result.stderr).toBe(0);
        return JSON.parse(result.stdout).model_data;
      };
      const initialized = await admin({ action: "initialize" });
      const key = generateKeyPairSync("ed25519");
      await admin({ action: "grant", revision: initialized.revision, grant: { id: "worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "read", "submit", "status", "reconcile"], expires_ms: Date.now() + 3600000 } });
      let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: stage });
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      const request = (action: string, params: object = {}) => {
        const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
        return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
      };
      const post = (body: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(body) });
      const send = async (action: string, params: object = {}) => {
        const response = await post(request(action, params));
        const body = await response.json() as any;
        expect(response.status, JSON.stringify({ stage, action, body })).toBe(200);
        return JSON.parse(body.payload).result;
      };
      try {
        const view = await send("create_view", { revision: boot.revision, objective: "Save and review the retained report" });
        const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "Retained report" });
        await send("read", { view: view.view, path: "documents/team/report.md" });
        // Advance accepted state outside the observed scope so refresh has a
        // real integration commit while the original inputs remain valid.
        const independent = await f.run(["ask", "Save an independent company note", "--json"]);
        expect(independent.code, independent.stderr).toBe(0);
        const actorCount = inference.counts().actors;
        const original = request("submit", { view: view.view, revision: saved.revision, candidate: "Saved the retained team report." });
        const rejected = await post(original);
        expect(rejected.status).toBe(400);
        expect((await rejected.json() as any).error).toBe("WorkspaceInjectedFailure");
        const operation = JSON.parse(original.payload).operation;
        expect((await send("status", { outcome: operation })).state).toBe("uncertain");
        const requestHash = createHash("sha256").update(original.payload).digest("hex");
        const intent = JSON.parse(f.fossil("cat", `company/submissions/${view.contract.id}/${requestHash}.json`, "-r", "omos-company"));
        expect(intent.revision).toBe(saved.revision);
        expect(intent.reads).toHaveLength(1);
        // Later inspection must not replace the interrupted proposal's inputs.
        await send("read", { view: view.view, path: "documents/team/report.md" });
        service.child.kill(); await service.child.exited;
        service = await startWorkspaceService(f, true);
        const recovered = await send("reconcile", { outcome: operation });
        expect(recovered.state).toBe("completed");
        const deadline = Date.now() + 60000;
        let observed: any;
        while (Date.now() < deadline) {
          observed = await send("status", { view: view.view });
          if (observed.job?.state === "published") break;
          if (["failed", "blocked", "changes_required"].includes(observed.job?.state)) throw Error(JSON.stringify({ stage, observed }));
          await Bun.sleep(30);
        }
        expect(observed.job?.state, JSON.stringify(observed)).toBe("published");
        const claims = JSON.parse(observed.publication.issuer_proof.payload);
        expect(claims.reads_sha256).toBe(createHash("sha256").update(JSON.stringify(intent.reads)).digest("hex"));
        expect(inference.counts().actors).toBe(actorCount);
        expect(f.fossil("cat", "documents/team/report.md", "-r", "trunk")).toBe("Retained report");
        expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Independent accepted state");
      } finally { service.child.kill(); await service.child.exited; }
    }
  }, 240000);

  test("preserves legacy company views and requires a declared input model before recording new reads or submissions", async () => {
    const f = fixture();
    const inference = model(f, () => ({ content: "Only independent company verification should run." }));
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    // Reconstruct the earlier persisted declaration, including its view shape,
    // to exercise an upgrade rather than only initializing the newest seed.
    const legacy = JSON.parse(f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    legacy.spec.semantic.entityTypes = legacy.spec.semantic.entityTypes.filter((entity: any) => !["omos_company_read", "omos_company_submission", "omos_company_upload"].includes(entity.id));
    delete legacy.spec.semantic.entityTypes.find((entity: any) => entity.id === "omos_workspace_view").fields.reads;
    legacy.spec.operations = legacy.spec.operations.filter((operation: any) => !["omos_company_subscription", "omos_company_schema"].includes(operation.id));
    const legacyInput = legacy.spec.operations.find((operation: any) => operation.id === "omos_company_operation").input.properties;
    legacyInput.version = { const: "omos.company/v1" };
    delete legacyInput.executable;
    delete legacyInput.previous_executable;
    delete legacyInput.progress_cursor;
    delete legacyInput.upload;
    const tree = join(f.home, "legacy-declaration");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", ["--user", "omos", ...args], { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    fossil("open", join(f.cwd, "omos.fossil"));
    writeFileSync(join(tree, "omniform/company.json"), JSON.stringify(legacy, null, 2) + "\n");
    fossil("commit", "--nosign", "-m", "Retain the prior company input contracts");
    fossil("close");
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["discover", "create_view", "checkpoint", "read", "submit", "status"], expires_ms: Date.now() + 3600000 } });
    const service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const request = (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const post = (body: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(body) });
    const send = async (action: string, params: object = {}) => {
      const response = await post(request(action, params));
      const body = await response.json() as any;
      expect(response.status, JSON.stringify({ action, body })).toBe(200);
      return JSON.parse(body.payload).result;
    };
    try {
      expect(boot.features.read_dependencies).toBe(false);
      expect(boot.features.schema_discovery).toBe(false);
      expect(boot.features.file_attributes).toBeNull();
      expect(boot.features.checkpoint_attributes).toBe(false);
      expect(boot.features.chunked_upload).toBe(false);
      expect(boot.features.progress_history).toBe(false);
      expect(boot.features.progress_stream).toBeNull();
      const view = await send("create_view", { revision: boot.revision, objective: "Retain the company report while upgrading its input model" });
      const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "Retained legacy report" });
      expect(JSON.parse(f.fossil("cat", `company/views/${view.view}.json`, "-r", "omos-company")).reads).toBeUndefined();
      const unavailableStream = await progressStream(service.url, request("status", { view: view.view, progress_cursor: "" }));
      expect(unavailableStream.response.status).toBe(400);
      await unavailableStream.close();
      const oldSchema = await post(request("discover", { view: view.view, entity: "*" }));
      expect(oldSchema.status).toBe(400);
      expect((await oldSchema.json() as any).error).toBe("CompanyDefinitionUpdateRequired");
      const beforeRead = (await admin({ action: "status" })).revision;
      const refused = await post(request("read", { view: view.view, path: "documents/team/report.md" }));
      expect(refused.status).toBe(400);
      expect((await refused.json() as any).error).toBe("CompanyDefinitionUpdateRequired");
      expect((await admin({ action: "status" })).revision).toBe(beforeRead);
      const original = request("submit", { view: view.view, revision: saved.revision, candidate: "Saved the retained legacy report." });
      const pending = await post(original);
      expect(pending.status).toBe(400);
      expect((await pending.json() as any).error).toBe("CompanyDefinitionUpdateRequired");
      expect((await send("status", { outcome: JSON.parse(original.payload).operation })).state).toBe("failed");
      const migration = await f.run(["fossil", "migrate", "--contracts", "--json"]);
      expect(migration.code, migration.stderr).toBe(0);
      expect((await (await fetch(service.url + "/v1/company")).json() as any).features.read_dependencies).toBe(true);
      const upgraded = await (await fetch(service.url + "/v1/company")).json() as any;
      expect(upgraded.features.file_attributes).toBe("omos.company/v2");
      expect(upgraded.features.schema_discovery).toBe(true);
      expect(upgraded.features.checkpoint_attributes).toBe(true);
      expect(upgraded.features.chunked_upload).toBe(true);
      expect(upgraded.features.progress_history).toBe(true);
      expect(upgraded.features.progress_stream).toBe("omos.company-progress/v1");
      const availableStream = await progressStream(service.url, request("status", { view: view.view, progress_cursor: "" }));
      try {
        expect(availableStream.response.status).toBe(200);
        expect((await availableStream.next()).event).toBe("workspace");
      } finally { await availableStream.close(); }
      const schema = await send("discover", { view: view.view, entity: "*" });
      expect(schema.total).toBe(0);
      expect(schema.definition_hash).toBe(view.basis.definition_hash);
      const read = await send("read", { view: view.view, path: "documents/team/report.md" });
      expect(read.read_tracking).toBe("recorded");
      expect(Buffer.from(read.content, "base64").toString()).toBe("Retained legacy report");
      await send("submit", { view: view.view, revision: saved.revision, candidate: "Saved the retained legacy report." });
      const deadline = Date.now() + 60000;
      let state: any;
      while (Date.now() < deadline) {
        state = await send("status", { view: view.view });
        if (state.job?.state === "published") break;
        if (["failed", "blocked", "changes_required"].includes(state.job?.state)) throw Error(JSON.stringify(state));
        await Bun.sleep(30);
      }
      expect(state.job?.state, JSON.stringify(state)).toBe("published");
      expect(inference.counts().actors).toBe(0);
      const verified = await f.run(["fossil", "verify", "--json"]);
      expect(verified.code, verified.stderr).toBe(0);
    } finally { service.child.kill(); await service.child.exited; }
  }, 180000);

  test("retains file, absence and query dependencies without changing view revisions or leaking unrelated membership", async () => {
    const f = fixture();
    const inference = model(f, () => ({ content: "Company input verification must not rerun an actor." }));
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = JSON.parse(f.fossil("cat", "omniform/company.json", "-r", "trunk"));
    for (const id of ["company_note", "company_todo", "company_stable"]) declaration.spec.semantic.entityTypes.push({ id, fields: { text: "string" }, required: ["text"] });
    const definition = join(f.home, "company-definition.json");
    writeFileSync(definition, JSON.stringify(declaration));
    const proposed = await f.run(["fossil", "definition", "propose", definition, "--json"]);
    expect(proposed.code, proposed.stderr).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    let control = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    const public_key = key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
    for (const [id, paths] of [
      ["publisher", ["documents/", "records/"]],
      ["reader", ["documents/team/", "records/company_note/", "records/company_todo/"]],
      ["scoped", ["records/company_stable/a.json"]],
    ] as const) control = await admin({ action: "grant", revision: control.revision, grant: { id, actor: id, public_key, paths, actions: ["create_view", "checkpoint", "record", "query", "read", "submit", "status"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const request = (actor: string, action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor, grant: actor, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const post = (body: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(body) });
    const send = async (actor: string, action: string, params: object = {}) => {
      const response = await post(request(actor, action, params));
      const body = await response.json() as any;
      expect(response.status, JSON.stringify({ action, body })).toBe(200);
      return JSON.parse(body.payload).result;
    };
    const accepted = async (actor: string, view: string) => {
      const deadline = Date.now() + 60000;
      let observed: any;
      while (Date.now() < deadline) {
        observed = await send(actor, "status", { view });
        if (observed.job?.state === "published") return observed;
        if (["failed", "blocked", "changes_required"].includes(observed.job?.state)) throw Error(`Unexpected review result: ${JSON.stringify(observed)}`);
        await Bun.sleep(30);
      }
      throw Error(`Company publication did not finish: ${JSON.stringify(observed)}`);
    };
    const currentBase = async () => (await (await fetch(service.url + "/v1/company")).json() as any).revision;
    const create = async (actor: string, objective: string) => send(actor, "create_view", { revision: await currentBase(), objective });
    try {
      let writer = await create("publisher", "Save the initial company inputs");
      let saved = await send("publisher", "checkpoint", { view: writer.view, revision: writer.revision, path: "documents/team/input.md", content: "First input" });
      for (const [entity, text] of [["company_note", "First note"], ["company_stable", "Stable note"]]) saved = await send("publisher", "record", { view: writer.view, revision: saved.revision, entity, record_id: "a", content: JSON.stringify({ text }) });
      await send("publisher", "submit", { view: writer.view, revision: saved.revision, candidate: "Saved the original document and company records." });
      await accepted("publisher", writer.view);
      const fileView = await create("reader", "Report the observed document input");
      const absentView = await create("reader", "Report whether the additional document exists");
      const emptyView = await create("reader", "Report company todo records");
      const queryView = await create("reader", "Report company note records");
      const scopedView = await create("scoped", "Report the authorized stable note");
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, false);
      const readOnlyBase = (await admin({ action: "status" })).revision;
      const untracked = await post(request("reader", "read", { view: fileView.view, path: "documents/team/input.md" }));
      expect(untracked.status).toBe(400);
      expect((await untracked.json() as any).error).toBe("CompanyReadTrackingRequired");
      const unbound = await send("reader", "read", { path: "documents/team/input.md" });
      expect(Buffer.from(unbound.content, "base64").toString()).toBe("First input");
      expect((await admin({ action: "status" })).revision).toBe(readOnlyBase);
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, true);
      const first = await send("reader", "read", { view: fileView.view, path: "documents/team/input.md" });
      expect(first.read_tracking).toBe("recorded");
      expect(first.observation.revision).toHaveLength(64);
      expect((await send("reader", "status", { view: fileView.view })).revision).toBe(fileView.revision);
      const absent = await send("reader", "read", { view: absentView.view, path: "documents/team/additional.md" });
      expect(absent.exists).toBe(false);
      expect(absent.sha256).toBeNull();
      expect((await send("reader", "query", { view: emptyView.view, entity: "company_todo" })).total).toBe(0);
      expect((await send("reader", "query", { view: queryView.view, entity: "company_note" })).total).toBe(1);
      expect((await send("scoped", "query", { view: scopedView.view, entity: "company_stable" })).total).toBe(1);
      writer = await create("publisher", "Update the shared inputs and add company records");
      saved = await send("publisher", "checkpoint", { view: writer.view, revision: writer.revision, path: "documents/team/input.md", content: "Second input", previous_hash: createHash("sha256").update("First input").digest("hex") });
      saved = await send("publisher", "checkpoint", { view: writer.view, revision: saved.revision, path: "documents/team/additional.md", content: "Additional input" });
      for (const entity of ["company_note", "company_todo", "company_stable"]) saved = await send("publisher", "record", { view: writer.view, revision: saved.revision, entity, record_id: "b", content: JSON.stringify({ text: "New record" }) });
      await send("publisher", "submit", { view: writer.view, revision: saved.revision, candidate: "Updated the shared inputs and added the requested company records." });
      await accepted("publisher", writer.view);
      for (const view of [fileView, absentView, emptyView, queryView]) {
        const rejectedRequest = request("reader", "submit", { view: view.view, revision: view.revision, candidate: "The original observed inputs are still current." });
        const response = await post(rejectedRequest);
        expect(response.status).toBe(400);
        expect((await response.json() as any).error).toBe("WorkspaceReadDependencyChanged");
        const outcome = await send("reader", "status", { outcome: JSON.parse(rejectedRequest.payload).operation });
        expect(outcome.state).toBe("failed");
      }
      await send("scoped", "submit", { view: scopedView.view, revision: scopedView.revision, candidate: "The authorized stable note still contains Stable note." });
      const scopedPublished = await accepted("scoped", scopedView.view);
      expect(JSON.parse(scopedPublished.publication.issuer_proof.payload).reads_sha256).toHaveLength(64);
      const beforeInspection = (await admin({ action: "status" })).revision;
      const inspection = await send("scoped", "query", { view: scopedView.view, entity: "company_stable" });
      expect(inspection.total).toBe(1);
      expect(inspection.read_tracking).toBe("frozen_inspection");
      expect((await admin({ action: "status" })).revision).toBe(beforeInspection);
      const observedAgain = await send("reader", "read", { view: fileView.view, revision: await currentBase(), path: "documents/team/input.md" });
      expect(Buffer.from(observedAgain.content, "base64").toString()).toBe("Second input");
      await send("reader", "submit", { view: fileView.view, revision: fileView.revision, candidate: "The observed document now contains Second input." });
      await accepted("reader", fileView.view);
      const newQuery = await send("reader", "query", { view: emptyView.view, revision: await currentBase(), entity: "company_todo" });
      expect(newQuery.total).toBe(1);
      await send("reader", "submit", { view: emptyView.view, revision: emptyView.revision, candidate: "The company todo query now contains the new record." });
      await accepted("reader", emptyView.view);
      expect(inference.counts().actors).toBe(0);
      const modeView = await create("reader", "Report the observed executable flag");
      const modeInput = await send("reader", "read", { version: "omos.company/v2", view: modeView.view, path: "documents/team/input.md" });
      expect(modeInput.executable).toBe(false);
      const owner = model(f, (body, count) => {
        if (count > 1) return { content: "The owner changed only the saved executable flag." };
        const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
        const root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
        return { tool_calls: [{ index: 0, id: "owner-mode-change", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `chmod 700 '${root}/documents/team/input.md'`, timeout_ms: 10000 } }) } }] };
      });
      const changedMode = await f.run(["ask", "Change only the saved document executable flag", "--json"]);
      expect(changedMode.code, changedMode.stderr).toBe(0);
      expect(owner.counts().actors).toBe(2);
      // A subsequent byte-only inspection must not erase the earlier observed
      // flag. No body bytes changed, so hash-only dependencies would pass.
      await send("reader", "read", { view: modeView.view, revision: await currentBase(), path: "documents/team/input.md" });
      const modeProposal = await post(request("reader", "submit", { view: modeView.view, revision: modeView.revision, candidate: "The old executable flag remains current." }));
      expect(modeProposal.status).toBe(400);
      expect((await modeProposal.json() as any).error).toBe("WorkspaceReadDependencyChanged");
      service.child.kill(); await service.child.exited;
      const exported = join(f.home, "observed-inputs.fossil");
      const result = await f.run(["fossil", "export", exported, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      const restored = fixture();
      const used = await restored.run(["fossil", "use", exported, "--json"]);
      expect(used.code, used.stderr).toBe(0);
      const verified = await restored.run(["fossil", "verify", "--json"]);
      expect(verified.code, verified.stderr).toBe(0);
    } finally { service.child.kill(); await service.child.exited; }
  }, 240000);

  test("reuses bounded host checkouts across personal publications while retaining isolated task views", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const shared = "Unchanged portable document.\n".repeat(2400);
    let phase = -1, wrote = false;
    const views = new Map<number, string>();
    model(f, body => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      views.set(phase, root);
      if (!wrote) {
        wrote = true;
        return phase < 0 ? { tool_calls: [{ index: 0, id: "shared-document", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "documents/shared.txt", content: shared }) } }] } : writeMemory(`Personal value ${phase}`);
      }
      return { content: phase < 0 ? "The shared document is saved." : `Personal value ${phase} is saved.` };
    });
    const seed = await f.run(["ask", "Save the unchanged shared document", "--json"]);
    expect(seed.code, seed.stderr).toBe(0);
    const repository = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).repository;
    const checkouts = join(f.home, ".fx/fossil", createHash("sha256").update(repository).digest("hex"), "checkouts");
    const copies = () => readdirSync(checkouts, { withFileTypes: true }).filter(entry => entry.isDirectory() && existsSync(join(checkouts, entry.name, "documents/shared.txt"))).length;
    const before = copies();
    const retained = [];
    for (phase = 0; phase < 4; phase++) {
      wrote = false;
      const result = await f.run(["ask", `Save personal value ${phase}`, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      const session = createHash("sha256").update(JSON.parse(result.stdout).session_id).digest("hex");
      const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((task: any) => task.session === session);
      expect(task.state).toBe("accepted");
      retained.push({ branch: task.branch, phase });
      expect(copies()).toBeLessThanOrEqual(before);
    }
    expect(new Set([...views.values()]).size).toBe(5);
    for (const task of retained) {
      expect(f.fossil("cat", "memory/preference.md", "-r", task.branch)).toBe(`Personal value ${task.phase}`);
      expect(existsSync(join(views.get(task.phase)!, "memory/preference.md"))).toBe(false);
      expect(existsSync(join(views.get(task.phase)!, "documents/shared.txt"))).toBe(false);
      expect(f.fossil("cat", "documents/shared.txt", "-r", task.branch)).toBe(shared);
    }
  }, 240000);

  test("preserves dirty same-revision host scratch before rebuilding it without replaying actor work", async () => {
    const f = fixture();
    let permit = false;
    const inference = model(f, (_body, count) => count === 1 ? writeMemory("Canonical retained information") : { content: "The canonical information is saved." }, packet => permit ? "met" : {
      name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["unseen-fixture"], note: "Retain this candidate" }] },
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const initial = await f.run(["ask", "Save the canonical information", "--json"]);
    expect(initial.code).toBe(1);
    const session = JSON.parse(initial.stdout).session_id;
    const snapshot = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const checkouts = join(f.home, ".fx/fossil", createHash("sha256").update(snapshot.repository).digest("hex"), "checkouts");
    const key = createHash("sha256").update("task-content").digest("hex");
    const tree = join(checkouts, key);
    mkdirSync(join(tree, "documents"), { recursive: true });
    writeFileSync(join(tree, "documents/uncommitted.txt"), "Retain these interrupted bytes");
    writeFileSync(join(tree, "memory/preference.md"), "An uncommitted host scratch change");
    const calls = inference.counts().actors;
    permit = true;
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(inference.counts().actors).toBe(calls);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Canonical retained information");
    expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/uncommitted.txt");
    const recoveries = readdirSync(checkouts).filter(name => name.startsWith(`${key}.recovery-`));
    expect(recoveries).toHaveLength(1);
    expect(readFileSync(join(checkouts, recoveries[0], "documents/uncommitted.txt"), "utf8")).toBe("Retain these interrupted bytes");
    expect(readFileSync(join(checkouts, recoveries[0], "memory/preference.md"), "utf8")).toBe("An uncommitted host scratch change");
  }, 120000);

  for (const committed of [false, true]) test(`initializes company authority atomically across a sparse ${committed ? "commit" : "staging"} interruption`, async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const file = join(f.home, "initialize-sparse.json");
    writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", action: "initialize" }));
    const first = await f.run(["fossil", "company", file, "--json"], { FX_E2E_FOSSIL_FAULT: committed ? "company-sparse-commit-verified" : "company-sparse-written" });
    expect(first.code, first.stderr).toBe(1);
    expect(first.stderr).toContain("WorkspaceInjectedFailure");
    const snapshot = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const issuerPath = join(f.home, ".fx/authority", snapshot.workspace_id, "issuer.json");
    const prepared = JSON.parse(readFileSync(issuerPath, "utf8"));
    if (committed) {
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", action: "status" }));
    } else {
      expect(f.fossil("branch", "list", "--all")).not.toContain("omos-company");
    }
    const recovered = await f.run(["fossil", "company", file, "--json"]);
    expect(recovered.code, recovered.stderr).toBe(0);
    const result = JSON.parse(recovered.stdout).model_data;
    expect(result.authority).toMatchObject({ issuer: prepared.public_key, epoch: 1, grants: [] });
    expect(f.fossil("branch", "list", "--all")).toContain("omos-company");
    const actor = generateKeyPairSync("ed25519");
    writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", action: "grant", revision: result.revision, grant: { id: "recovered-reader", actor: "reader", public_key: actor.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["read"], expires_ms: Date.now() + 3600000 } }));
    const granted = await f.run(["fossil", "company", file, "--json"]);
    expect(granted.code, granted.stderr).toBe(0);
    const active = JSON.parse(granted.stdout).model_data;
    expect(active.authority.issuer).toBe(prepared.public_key);
    const updated = JSON.parse(readFileSync(issuerPath, "utf8"));
    expect(updated.control_revision).toBe(active.revision);
    const verified = await f.run(["fossil", "verify", "--json"]);
    expect(verified.code, verified.stderr).toBe(0);
  }, 90000);

  for (const interrupted of ["company-sparse-written", "company-sparse-commit-verified"]) test(`keeps company control writes sparse and recovers ${interrupted} without discarding local files`, async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("A sparse control write cannot dispatch an actor"); });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const data = "Shared company baseline.\n".repeat(32768);
    const tree = join(f.home, "baseline-source"); mkdirSync(tree);
    const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
    const seed = (...args: string[]) => {
      const result = spawnSync(existsSync(helper) ? helper : "fossil", ["--user", "omos", ...args], { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    seed("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
    mkdirSync(join(tree, "documents/team"), { recursive: true });
    writeFileSync(join(tree, "documents/team/shared.txt"), data);
    seed("add", "documents/team/shared.txt"); seed("commit", "--nosync", "--nosign", "-m", "Retain an existing company baseline"); seed("close");
    const admin = async (body: object) => {
      const file = join(f.home, "sparse-operator.json"); writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "sparse-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "status"], expires_ms: Date.now() + 3600000 } });
    const snapshot = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const cache = join(f.home, ".fx/fossil", createHash("sha256").update(snapshot.repository).digest("hex"));
    const scratch = join(cache, "company-scratch");
    expect(existsSync(scratch)).toBe(false);
    mkdirSync(scratch); writeFileSync(join(scratch, "retain-local-note.txt"), "This independently edited note must survive");
    let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: interrupted });
    try {
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      const operation = crypto.randomUUID();
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "sparse-worker", operation, expires_ms: Date.now() + 120000, action: "create_view", revision: boot.revision, objective: "Retain a lightweight isolated company view" });
      const raw = JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") });
      const post = () => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json" }, body: raw });
      const failed = await post(); expect(failed.status).toBe(400);
      expect(await failed.text()).toContain("WorkspaceInjectedFailure");
      expect(existsSync(join(scratch, "documents"))).toBe(false);
      expect(existsSync(join(scratch, "omniform"))).toBe(false);
      const staged = readdirSync(join(scratch, "company/operations"));
      expect(staged).toHaveLength(1);
      expect(JSON.parse(readFileSync(join(scratch, "company/operations", staged[0]), "utf8")).request).toBe(raw);
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, true);
      const retry = await post();
      const envelope = await retry.json() as any;
      expect(retry.status, JSON.stringify(envelope)).toBe(200);
      expect(JSON.parse(envelope.payload).result).toHaveProperty("view");
      expect(existsSync(scratch)).toBe(false);
      const recoveries = readdirSync(cache).filter((name: string) => name.startsWith("company-scratch.recovery-")).map((name: string) => join(cache, name));
      expect(recoveries).toHaveLength(2);
      expect(recoveries.some((path: string) => existsSync(join(path, "retain-local-note.txt")) && readFileSync(join(path, "retain-local-note.txt"), "utf8") === "This independently edited note must survive")).toBe(true);
      expect(recoveries.some((path: string) => existsSync(join(path, "company/operations", staged[0])) && JSON.parse(readFileSync(join(path, "company/operations", staged[0]), "utf8")).request === raw)).toBe(true);
      expect(createHash("sha256").update(f.fossil("cat", "documents/team/shared.txt", "-r", "trunk")).digest("hex")).toBe(createHash("sha256").update(data).digest("hex"));
      expect(createHash("sha256").update(f.fossil("cat", "documents/team/shared.txt", "-r", "omos-company")).digest("hex")).toBe(createHash("sha256").update(data).digest("hex"));
      expect(f.fossil("ls", "-r", "omos-company")).not.toContain("retain-local-note.txt");
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
      const verified = await f.run(["fossil", "verify", "--json"]);
      expect(verified.code, verified.stderr).toBe(0);
    } finally { service.child.kill(); await service.child.exited; }
  }, 120000);

  test("keeps company drafts isolated without copying the company files for every view", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const document = "shared company document\n".repeat(3000);
    const documentPath = "documents/team/shared.txt";
    const documentHash = createHash("sha256").update(document).digest("hex");
    model(f, (_body, count) => {
      if (count === 1) return { tool_calls: [
        { path: documentPath, content: document },
        { path: "memory/company-seed.json", content: JSON.stringify({ files: [{ path: documentPath, sha256: documentHash, bytes: Buffer.byteLength(document) }] }) },
      ].map((value, index) => ({ index, id: `company-seed-${index}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", ...value }) } })) };
      if (count === 2) return { tool_calls: [{ index: 0, id: "verify-company-seed", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "verify_manifest", path: "memory/company-seed.json" }) } }] };
      return { content: "The shared document and its complete host manifest verification are saved." };
    });
    const seeded = await f.run(["ask", "Save the shared company document and verify its exact bytes", "--json"]);
    expect(seeded.code, seeded.stderr).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const company = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: company.revision, grant: { id: "draft-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "read"], expires_ms: Date.now() + 3600000 } });
    const repository = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).repository;
    const checkouts = join(f.home, ".fx/fossil", createHash("sha256").update(repository).digest("hex"), "checkouts");
    const copies = () => readdirSync(checkouts, { withFileTypes: true }).filter(entry => entry.isDirectory() && existsSync(join(checkouts, entry.name, documentPath))).length;
    const before = copies();
    const service = await startWorkspaceService(f, true);
    try {
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      const send = async (action: string, params: object) => {
        const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "draft-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
        const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
        const result = await response.json() as any;
        expect(response.status, JSON.stringify(result)).toBe(200);
        return JSON.parse(result.payload).result;
      };
      const views = [];
      for (let index = 0; index < 8; index++) views.push(await send("create_view", { revision: boot.revision, objective: `Prepare private company draft ${index}` }));
      expect(copies() - before).toBeLessThanOrEqual(1);
      await send("checkpoint", { view: views[0].view, revision: views[0].revision, path: documentPath, previous_hash: documentHash, content: "First private draft" });
      await send("checkpoint", { view: views[1].view, revision: views[1].revision, path: documentPath, previous_hash: documentHash, content: "Second private draft" });
      for (const [view, expected] of [[views[0], "First private draft"], [views[1], "Second private draft"], [views[7], document]] as const) {
        const read = await send("read", { view: view.view, path: documentPath, limit: 16 });
        expect(read.sha256).toBe(createHash("sha256").update(expected).digest("hex"));
      }
      expect(copies() - before).toBeLessThanOrEqual(1);
    } finally {
      service.child.kill(); await service.child.exited;
    }
  }, 180000);

  test("fences an in-place authority rollback and an accepted-branch rewind using protected observed heads", async () => {
    const f = fixture();
    const inference = model(f, () => ({ content: "No actor execution is needed for this server review." }));
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    const publicKey = key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
    let control = await admin({ action: "grant", revision: initialized.revision, grant: { id: "reader", actor: "reader", public_key: publicKey, paths: ["memory/"], actions: ["discover"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const descriptorFile = join(f.home, ".fx/authority", boot.workspace, "issuer.json");
    const descriptor = () => JSON.parse(readFileSync(descriptorFile, "utf8"));
    const post = (action: string, params: object = {}, grant = "reader") => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "reader", grant, operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
    };
    const send = async (action: string, params: object = {}) => {
      const response = await post(action, params, "reader-v2");
      const body = await response.json() as any;
      expect(response.status, JSON.stringify(body)).toBe(200);
      return JSON.parse(body.payload).result;
    };
    try {
      expect(descriptor().control_revision).toBe(control.revision);
      expect(descriptor().accepted_revision).toBe(boot.revision);
      const snapshot = join(f.home, "before-revocation.fossil");
      const cloned = spawnSync("fossil", ["clone", "--private", join(f.cwd, "omos.fossil"), snapshot], { env: { ...process.env, ...f.env, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home }, encoding: "utf8" });
      expect(cloned.status, cloned.stderr).toBe(0);
      control = await admin({ action: "revoke", revision: control.revision, id: "reader" });
      expect((await post("discover")).status).toBe(403);
      const remembered = descriptor().control_revision;
      expect(remembered).toBe(control.revision);
      service.child.kill(); await service.child.exited;
      copyFileSync(snapshot, join(f.cwd, "omos.fossil"));
      service = await startWorkspaceService(f, true);
      const rejected = await post("discover");
      expect(rejected.status).toBe(409);
      expect((await rejected.json() as any).error).toBe("CompanyAuthorityRollbackDetected");
      expect(descriptor().control_revision).toBe(remembered);
      expect((await fetch(service.url + "/v1/company")).status).toBe(409);
      control = await admin({ action: "status" });
      expect(control.authority.grants[0].revoked).toBe(false);
      control = await admin({ action: "rotate", revision: control.revision });
      expect(control.authority.epoch).toBeGreaterThan(boot.epoch);
      expect(control.authority.issuer).not.toBe(boot.issuer);
      expect(control.authority.grants.every((grant: any) => grant.revoked)).toBe(true);
      expect((await fetch(service.url + "/v1/company")).status).toBe(200);
      expect((await post("discover")).status).toBe(403);
      await admin({ action: "grant", revision: control.revision, grant: { id: "reader-v2", actor: "reader", public_key: publicKey, paths: ["memory/"], actions: ["create_view", "checkpoint", "submit", "status"], expires_ms: Date.now() + 3600000 } });
      const active = await (await fetch(service.url + "/v1/company")).json() as any;
      const view = await send("create_view", { revision: active.revision, objective: "Retain memory/report.md with the reviewed company note" });
      const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "memory/report.md", content: "Reviewed company note" });
      await send("submit", { view: view.view, revision: saved.revision, candidate: "Saved memory/report.md with the reviewed company note." });
      // Inspect the public local snapshot rather than a signed read: the
      // publication itself must durably advance its protected watermark.
      let accepted = false;
      const deadline = Date.now() + 60000;
      while (Date.now() < deadline) {
        const state = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
        if (state.tasks.some((task: any) => task.id === view.contract.id && task.state === "accepted")) { accepted = true; break; }
        await Bun.sleep(30);
      }
      if (!accepted) {
        const jobs = await f.run(["fossil", "query", "omos_review_job", "--json"]);
        throw Error(`Company publication did not finish: ${jobs.stdout} ${jobs.stderr}`);
      }
      const publishedHead = descriptor().accepted_revision;
      expect(publishedHead).not.toBe(active.revision);
      expect(f.fossil("whatis", "--type", "ci", "trunk")).toContain(publishedHead);
      // Change only the accepted branch's tags, leaving live grants and the
      // company control head untouched. This must also fence the server.
      f.fossil("--user", "omos", "tag", "cancel", "--raw", "sym-trunk", publishedHead);
      f.fossil("--user", "omos", "tag", "cancel", "--raw", "branch", publishedHead);
      expect(f.fossil("whatis", "--type", "ci", "trunk")).not.toContain(publishedHead);
      const rewound = await fetch(service.url + "/v1/company");
      expect(rewound.status).toBe(409);
      expect((await rewound.json() as any).error).toBe("CompanyAuthorityRollbackDetected");
      expect(descriptor().accepted_revision).toBe(publishedHead);
      expect(inference.counts().actors).toBe(0);
    } finally { service.child.kill(); await service.child.exited; }
  }, 180000);

  test("publishes issuer keys atomically and recovers interrupted company initialization", async () => {
    for (const stage of ["issuer-key-prepared", "issuer-binding-published"]) {
      const f = fixture();
      const initial = await f.run(["fossil", "init", "--json"]);
      expect(initial.code, initial.stderr).toBe(0);
      const identity = JSON.parse(initial.stdout).workspace_id;
      const request = join(f.home, "initialize-company.json");
      writeFileSync(request, JSON.stringify({ version: "omos.company-admin/v1", action: "initialize" }));
      const interrupted = await f.run(["fossil", "company", request, "--json"], { FX_E2E_FOSSIL_FAULT: stage });
      expect(interrupted.code).toBe(1);
      expect(interrupted.stderr).toContain("WorkspaceInjectedFailure");
      expect(f.fossil("branch", "list", "--all")).not.toContain("omos-company");
      const directory = join(f.home, ".fx/authority", identity);
      const descriptorFile = join(directory, "issuer.json");
      const prepared = existsSync(descriptorFile) ? JSON.parse(readFileSync(descriptorFile, "utf8")) : null;
      expect(Boolean(prepared)).toBe(stage === "issuer-binding-published");
      const recovered = await f.run(["fossil", "company", request, "--json"]);
      expect(recovered.code, recovered.stderr).toBe(0);
      const company = JSON.parse(recovered.stdout).model_data.authority;
      const descriptor = JSON.parse(readFileSync(descriptorFile, "utf8"));
      expect(descriptor.public_key).toBe(company.issuer);
      expect(descriptor.repository).toBe(join(f.cwd, "omos.fossil"));
      if (prepared) expect(company.issuer).toBe(prepared.public_key);
      const seed = readFileSync(join(directory, descriptor.seed_file));
      expect(seed.length).toBe(32);
      expect(statSync(join(directory, descriptor.seed_file)).mode & 0o777).toBe(0o600);
      const secret = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
      expect(createPublicKey(secret).export({ format: "der", type: "spki" }).subarray(-32).toString("hex")).toBe(company.issuer);
      expect(f.fossil("cat", "authority/state.json", "-r", "omos-company").includes(seed.toString("hex"))).toBe(false);
    }
  }, 90000);

  test("requires explicit authority recovery for a copied repository and fences the previous server", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (request: object) => {
      const file = join(f.home, "operator-request.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...request }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "reader", actor: "reader", public_key: key.publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex"), paths: ["documents/"], actions: ["discover", "create_view"], expires_ms: Date.now() + 3600000 } });
    const oldService = await startWorkspaceService(f, true);
    let restoredService: Awaited<ReturnType<typeof startWorkspaceService>> | undefined;
    try {
      const original = await (await fetch(oldService.url + "/v1/company")).json() as any;
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: original.workspace, actor: "reader", grant: "reader", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action: "discover" });
      const body = JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") });
      const read = (url: string) => fetch(url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body });
      expect((await read(oldService.url)).status).toBe(200);
      const copy = join(f.home, "restored.fossil");
      const exported = await f.run(["fossil", "export", copy]);
      expect(exported.code, exported.stderr).toBe(0);
      expect((await f.run(["fossil", "use", copy])).code).toBe(0);
      restoredService = await startWorkspaceService(f, true);
      const inactive = await read(restoredService.url);
      expect(inactive.status).toBe(409);
      expect((await inactive.json() as any).error).toBe("CompanyIssuerBoundElsewhere");
      const live = await (await fetch(oldService.url + "/v1/company")).json() as any;
      const mutation = JSON.stringify({ version: "omos.company/v1", workspace: original.workspace, actor: "reader", grant: "reader", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action: "create_view", revision: live.revision, objective: "Retain work created after the export" });
      const advanced = await fetch(oldService.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ payload: mutation, signature: sign(null, Buffer.from(mutation), key.privateKey).toString("hex") }) });
      expect(advanced.status, JSON.stringify(await advanced.json())).toBe(200);
      const stale = await admin({ action: "status" });
      const request = join(f.home, "stale-recovery.json");
      writeFileSync(request, JSON.stringify({ version: "omos.company-admin/v1", action: "rotate", revision: stale.revision }));
      const refused = await f.run(["fossil", "company", request, "--json"]);
      expect(refused.code).toBe(1);
      expect(refused.stderr).toContain("CompanyRecoverySourceAdvanced");
      expect((await read(oldService.url)).status).toBe(200);
      restoredService.child.kill(); await restoredService.child.exited; restoredService = undefined;
      expect((await f.run(["fossil", "use", join(f.cwd, "omos.fossil")])).code).toBe(0);
      const freshCopy = join(f.home, "fresh-restored.fossil");
      expect((await f.run(["fossil", "export", freshCopy])).code).toBe(0);
      expect((await f.run(["fossil", "use", freshCopy])).code).toBe(0);
      restoredService = await startWorkspaceService(f, true);
      const current = await admin({ action: "status" });
      const rotated = await admin({ action: "rotate", revision: current.revision });
      expect(rotated.authority.epoch).toBeGreaterThan(original.epoch);
      expect(rotated.authority.issuer).not.toBe(original.issuer);
      expect(rotated.authority.grants.every((grant: any) => grant.revoked)).toBe(true);
      const active = await fetch(restoredService.url + "/v1/company");
      expect(active.status).toBe(200);
      expect((await active.json() as any).issuer).toBe(rotated.authority.issuer);
      const fenced = await read(oldService.url);
      expect(fenced.status).toBe(409);
      expect((await fenced.json() as any).error).toBe("CompanyIssuerBoundElsewhere");
      expect((await fetch(oldService.url + "/v1/definition", { headers: oldService.headers })).status).toBe(409);
      expect((await read(restoredService.url)).status).toBe(403);
    } finally {
      oldService.child.kill(); await oldService.child.exited;
      if (restoredService) { restoredService.child.kill(); await restoredService.child.exited; }
    }
  }, 90000);

  test("reviews independent company proposals concurrently and reassesses an advanced accepted base within the same allowance", async () => {
    const f = fixture();
    let inspecting = 0;
    let release: () => void = () => {};
    const gate = new Promise<void>(resolve => { release = resolve; });
    const gateway = model(f, () => { throw Error("Company review must not execute actors"); }, async () => {
      if (++inspecting <= 2) await gate;
      return "met";
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    expect(JSON.parse(f.fossil("cat", "execution/omos.json", "-r", "trunk")).server.review_workers).toBe(2);
    const admin = async (body: object) => {
      const path = join(f.home, "operator.json");
      writeFileSync(path, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", path, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: {
      id: "parallel-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"),
      paths: ["documents/"], actions: ["create_view", "checkpoint", "submit", "status"], expires_ms: Date.now() + 3600000,
    } });
    const service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const send = async (action: string, params: object) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "parallel-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
      const result = await response.json() as any;
      expect(response.status, JSON.stringify(result)).toBe(200);
      return JSON.parse(result.payload).result;
    };
    try {
      const views = [];
      for (const name of ["alpha", "beta"]) {
        const view = await send("create_view", { revision: boot.revision, objective: `Save documents/${name}.md containing ${name}` });
        const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: `documents/${name}.md`, content: name, previous_hash: null });
        views.push({ ...view, revision: saved.revision, name, job: "" });
      }
      for (const view of views) {
        const submitted = await send("submit", { view: view.view, revision: view.revision, candidate: `Saved documents/${view.name}.md containing ${view.name}.` });
        view.job = submitted.job;
      }
      const startDeadline = Date.now() + 30000;
      while (inspecting < 2 && Date.now() < startDeadline) await Bun.sleep(20);
      // Neither model response can finish until both workers are inspecting.
      expect(inspecting, readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-5000)).toBe(2);
      release();
      const statuses = [];
      for (const view of views) {
        let status: any;
        const deadline = Date.now() + 90000;
        do {
          status = await send("status", { view: view.view });
          if (!["queued", "running"].includes(status.job?.state)) break;
          await Bun.sleep(30);
        } while (Date.now() < deadline);
        expect(status.job?.id).toBe(view.job);
        expect(status.job?.state, JSON.stringify(status) + "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-8000)).toBe("published");
        expect(status.job.generation, JSON.stringify({ job: status.job, counts: gateway.counts() }) + "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-16000)).toBe(1);
        expect(status.job.budget_epoch).toBe(1);
        statuses.push(status);
      }
      expect(f.fossil("cat", "documents/alpha.md", "-r", "trunk")).toBe("alpha");
      expect(f.fossil("cat", "documents/beta.md", "-r", "trunk")).toBe("beta");
      expect(statuses.map(status => status.job.review_attempts).sort()).toEqual([1, 2]);
      expect(gateway.counts()).toEqual({ actors: 0, assessments: 3 });
      const bases = statuses.map(status => JSON.parse(status.publication.issuer_proof.payload).target_base);
      // The later publication must evaluate a base containing the earlier
      // accepted change, regardless of which worker wins the writer lease.
      expect(bases.some((base, index) => f.fossil("ls", "-r", base).includes(`documents/${views[1 - index].name}.md`)), JSON.stringify({ bases, jobs: statuses.map(status => status.job) })).toBe(true);
      expect((await f.run(["fossil", "verify", "--json"])).code).toBe(0);
    } finally {
      release(); service.child.kill(); await service.child.exited;
    }
  }, 180000);

  test("publishes independently reviewed company proposals and fences revocation during assessment", async () => {
    for (const revoked of [false, true]) {
      const f = fixture();
      let release: (() => void) | undefined;
      let reviewing = false;
      const wait = new Promise<void>(resolve => { release = resolve; });
      const modelServer = model(f, () => { throw Error("Company verification must never run actor tools"); }, async () => {
        reviewing = true;
        if (revoked) await wait;
        return "met";
      });
      const initialized = await f.run(["fossil", "init"]);
      expect(initialized.code, initialized.stderr).toBe(0);
      const admin = async (body: object) => {
        const file = join(f.home, "operator.json");
        writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
        const result = await f.run(["fossil", "company", file, "--json"]);
        expect(result.code, result.stderr).toBe(0);
        return JSON.parse(result.stdout).model_data;
      };
      const company = await admin({ action: "initialize" });
      const key = generateKeyPairSync("ed25519");
      await admin({ action: "grant", revision: company.revision, grant: { id: "reviewed-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/"], actions: ["create_view", "checkpoint", "submit", "status"], expires_ms: Date.now() + 3600000 } });
      const service = await startWorkspaceService(f, true);
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      const send = async (action: string, params: object = {}) => {
        const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "reviewed-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
        const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
        const result = await response.json() as any;
        expect(response.status, JSON.stringify(result)).toBe(200);
        return JSON.parse(result.payload).result;
      };
      try {
        const view = await send("create_view", { revision: boot.revision, objective: "Save documents/report.md containing Reviewed report" });
        const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/report.md", content: "Reviewed report", previous_hash: null });
        const submitted = await send("submit", { view: view.view, revision: saved.revision, candidate: "Saved documents/report.md containing Reviewed report." });
        const deadline = Date.now() + 60000;
        while (!reviewing && Date.now() < deadline) await Bun.sleep(20);
        expect(reviewing).toBe(true);
        if (revoked) {
          const current = await admin({ action: "status" });
          await admin({ action: "revoke", revision: current.revision, id: "reviewed-worker" });
          release!();
        }
        let job: any;
        while (Date.now() < deadline) {
          const tasks = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks;
          const task = tasks.find((task: any) => task.review_job === submitted.job);
          job = JSON.parse(f.fossil("cat", `jobs/${submitted.job}.json`, "-r", task.state === "accepted" ? task.parent : task.branch));
          if (!["queued", "running"].includes(job.state)) break;
          await Bun.sleep(20);
        }
        expect(job.state, JSON.stringify({ job, model: modelServer.counts() }) + "\n" + readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-6000)).toBe(revoked ? "failed" : "published");
        if (revoked) expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/report.md");
        else {
          expect(f.fossil("cat", "documents/report.md", "-r", "trunk")).toBe("Reviewed report");
          const status = await send("status", { view: view.view });
          const publication = status.publication;
          expect(publication.revision).toBe(f.fossil("timeline", "ancestors", "trunk", "--path", publication.receipt_path, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim());
          const proof = publication.issuer_proof;
          const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
          expect(verify(null, Buffer.from(proof.payload), issuer, Buffer.from(proof.signature, "hex"))).toBe(true);
          const claims = JSON.parse(proof.payload);
          expect(claims.actor).toBe("worker");
          expect(claims.grant).toBe("reviewed-worker");
          expect(claims.task).toBe(job.task);
          expect(claims.candidate_sha256).toBe(createHash("sha256").update("Saved documents/report.md containing Reviewed report.").digest("hex"));
          const receiptBytes = f.fossil("cat", publication.receipt_path, "-r", publication.revision);
          expect(createHash("sha256").update(receiptBytes).digest("hex")).toBe(publication.receipt_sha256);
          const retained = JSON.parse(receiptBytes);
          expect(claims.contract_sha256).toBe(createHash("sha256").update(JSON.stringify(retained.task.definition)).digest("hex"));
          expect(claims.source).toBe(retained.review.revision);
          expect(claims.target_base).toBe(retained.task.base_revision);
          expect(verify(null, Buffer.from(proof.payload.replace(claims.candidate_sha256, "00".repeat(32))), issuer, Buffer.from(proof.signature, "hex"))).toBe(false);
          // Advance accepted state with unrelated work. The first receipt must
          // keep reporting its own resulting revision, including after restore.
          const accepted = await (await fetch(service.url + "/v1/company")).json() as any;
          const later = await send("create_view", { revision: accepted.revision, objective: "Save a second company document" });
          const savedLater = await send("checkpoint", { view: later.view, revision: later.revision, path: "documents/later.md", content: "Second report", previous_hash: null });
          const submittedLater = await send("submit", { view: later.view, revision: savedLater.revision, candidate: "Saved the second company document." });
          let laterStatus: any;
          const laterDeadline = Date.now() + 60000;
          while (Date.now() < laterDeadline) {
            laterStatus = await send("status", { view: later.view });
            if (!["queued", "running"].includes(laterStatus.job?.state)) break;
            await Bun.sleep(30);
          }
          expect(laterStatus.job.id).toBe(submittedLater.job);
          expect(laterStatus.job.state).toBe("published");
          expect(laterStatus.publication.revision).not.toBe(publication.revision);
          expect((await send("status", { view: view.view })).publication).toEqual(publication);
          const exported = join(f.home, "company-with-publication-proofs.fossil");
          const exportedResult = await f.run(["fossil", "export", exported, "--json"]);
          expect(exportedResult.code, exportedResult.stderr).toBe(0);
          const restored = fixture();
          expect((await restored.run(["fossil", "use", exported, "--json"])).code).toBe(0);
          const checked = await restored.run(["fossil", "verify", "--json"]);
          expect(checked.code, checked.stderr).toBe(0);
        }
        expect(modelServer.counts().actors).toBe(0);
      } finally {
        release!(); service.child.kill(); await service.child.exited;
      }
    }
  }, 180000);

  test("reconciles a committed company checkpoint after losing its acknowledgement", async () => {
    const f = fixture();
    const initialized = await f.run(["fossil", "init"]);
    expect(initialized.code, initialized.stderr).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "admin.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const company = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: company.revision, grant: { id: "worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/"], actions: ["create_view", "checkpoint", "status", "discover"], expires_ms: Date.now() + 3600000 } });
    const service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-checkpoint-committed" });
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const seal = (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const send = (request: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(request) });
    const data = async (response: Response) => {
      const result = await response.json() as any;
      expect(response.status, JSON.stringify(result)).toBe(200);
      return JSON.parse(result.payload).result;
    };
    try {
      const view = await data(await send(seal("create_view", { revision: boot.revision, objective: "Save an interrupted report" })));
      const content = "#!/bin/sh\nprintf 'saved once\\n'\n";
      const original = seal("checkpoint", { view: view.view, revision: view.revision, path: "documents/run.sh", content, previous_hash: null, executable: true });
      const failure = await send(original);
      expect(failure.status).toBe(400);
      expect((await failure.json() as any).error).toBe("WorkspaceInjectedFailure");
      const operation = JSON.parse(original.payload).operation;
      const pending = await data(await send(seal("status", { outcome: operation })));
      expect(pending.state).toBe("uncertain");
      const blocked = await send(seal("checkpoint", { view: view.view, revision: view.revision, path: "documents/other.md", content: "Must wait" }));
      expect((await blocked.json() as any).error).toBe("CompanyOperationRecoveryRequired");
      const resumed = await data(await send(original));
      expect(resumed.state).toBe("checkpointed");
      expect(await data(await send(original))).toEqual(resumed);
      const completed = await data(await send(seal("status", { outcome: operation })));
      expect(completed.state).toBe("completed");
      const snapshot = await data(await send(seal("discover", { version: "omos.company/v2", view: view.view, revision: resumed.revision })));
      expect(snapshot.files).toHaveLength(1);
      expect(snapshot.files[0].sha256).toBe(createHash("sha256").update(content).digest("hex"));
      expect(snapshot.files[0].executable).toBe(true);
      const checkpoints = f.fossil("ls", "-r", resumed.revision).split("\n").filter(path => path.startsWith("company/checkpoints/"));
      expect(checkpoints).toHaveLength(1);
      expect(JSON.parse(f.fossil("cat", checkpoints[0], "-r", resumed.revision)).files[0].executable).toBe(true);
    } finally {
      service.child.kill(); await service.child.exited;
    }
  }, 90000);

  test("reconciles a lost submission response after independent publication without rerunning the actor", async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("Submission recovery cannot invoke an actor"); });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const company = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: company.revision, grant: { id: "recover-worker", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/"], actions: ["create_view", "checkpoint", "submit", "status", "reconcile"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-review-queued" });
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const envelope = (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "recover-worker", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const post = (body: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(body) });
    const send = async (action: string, params: object = {}) => {
      const response = await post(envelope(action, params));
      const reply = await response.json() as any;
      expect(response.status, JSON.stringify(reply)).toBe(200);
      return JSON.parse(reply.payload).result;
    };
    try {
      const view = await send("create_view", { revision: boot.revision, objective: "Save a report exactly once" });
      const checkpoint = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/recovered.md", content: "One reviewed report", previous_hash: null });
      const original = envelope("submit", { view: view.view, revision: checkpoint.revision, candidate: "Saved documents/recovered.md containing One reviewed report.", expires_ms: Date.now() + 2000 });
      expect((await post(original)).status).toBe(400);
      const operation = JSON.parse(original.payload).operation;
      let status: any;
      const deadline = Date.now() + 60000;
      while (Date.now() < deadline) {
        status = await send("status", { view: view.view });
        if (!["queued", "running"].includes(status.job?.state)) break;
        await Bun.sleep(20);
      }
      expect(status.job.state, JSON.stringify(status)).toBe("published");
      const pending = await send("status", { outcome: operation });
      expect(pending.state).toBe("uncertain");
      expect(JSON.parse(pending.receipt.payload).result.failure).toBe("WorkspaceInjectedFailure");
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, true);
      while (Date.now() <= JSON.parse(original.payload).expires_ms) await Bun.sleep(20);
      expect((await post(original)).status).toBe(403);
      const before = inference.counts();
      const recovered = await send("reconcile", { outcome: operation });
      expect(recovered.result.state).toBe("published");
      expect(recovered.result.publication).toEqual(status.publication);
      expect(inference.counts()).toEqual(before);
      expect(before.actors).toBe(0);
      const outcome = await send("status", { outcome: operation });
      expect(outcome.state).toBe("completed");
      expect(outcome.reconciled_by).toBeTruthy();
      expect(f.fossil("cat", "documents/recovered.md", "-r", status.publication.revision)).toBe("One reviewed report");
    } finally {
      service.child.kill(); await service.child.exited;
    }
  }, 120000);

  test("creates stable private actor key handles without a repository and returns only their public identity", async () => {
    const f = fixture();
    const results = await Promise.all(Array.from({ length: 3 }, () => f.run(["fossil", "company-key", "team-reader", "--json"])));
    for (const result of results) expect(result.code, result.stderr).toBe(0);
    const identities = results.map(result => JSON.parse(result.stdout));
    expect(identities.every(identity => identity.version === "omos.company-key/v1" && identity.key_handle === "team-reader")).toBe(true);
    expect(new Set(identities.map(identity => identity.public_key)).size).toBe(1);
    expect(identities.filter(identity => identity.created)).toHaveLength(1);
    const directory = join(f.home, ".fx/company-keys");
    const file = join(directory, "team-reader.seed");
    const seed = readFileSync(file);
    expect(seed.length).toBe(32);
    expect(statSync(file).mode & 0o777).toBe(0o600);
    expect(statSync(directory).mode & 0o777).toBe(0o700);
    const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), type: "pkcs8", format: "der" });
    const publicKey = createPublicKey(privateKey).export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
    expect(identities[0].public_key).toBe(publicKey);
    expect(results.every(result => !(result.stdout + result.stderr).includes(seed.toString("hex")))).toBe(true);
    expect(existsSync(join(f.home, ".fx/omos-workspace.json"))).toBe(false);
    expect(existsSync(join(f.cwd, "omos.fossil"))).toBe(false);
    const existing = await f.run(["fossil", "company-key", "team-reader"]);
    expect(existing.code, existing.stderr).toBe(0);
    expect(existing.stdout).toContain("Using existing local company actor key: team-reader");
    expect(existing.stdout).toContain(publicKey);
    expect(readFileSync(file).equals(seed)).toBe(true);
    const escaped = await f.run(["fossil", "company-key", "../escape", "--json"]);
    expect(escaped.code).toBe(1);
    expect(escaped.stdout + escaped.stderr).toContain("InvalidCompanyKeyHandle");
    expect(existsSync(join(f.home, ".fx/escape.seed"))).toBe(false);
    chmodSync(file, 0o644);
    const exposed = await f.run(["fossil", "company-key", "team-reader", "--json"]);
    expect(exposed.code).toBe(1);
    expect(exposed.stdout + exposed.stderr).toContain("CompanyKeyPermissionsUnsafe");
    expect(readFileSync(file).equals(seed)).toBe(true);
    chmodSync(file, 0o600);
    const outside = join(f.home, "outside.seed");
    writeFileSync(outside, seed, { mode: 0o600 });
    symlinkSync(outside, join(directory, "linked.seed"));
    const linked = await f.run(["fossil", "company-key", "linked", "--json"]);
    expect(linked.code).toBe(1);
    expect(readFileSync(outside).equals(seed)).toBe(true);
    expect(readdirSync(directory).filter(name => name.startsWith("key.pending-"))).toHaveLength(0);
  }, 30000);

  test("verifies signed company client receipts without forwarding the owner token or replaying mismatched replies", async () => {
    const f = fixture();
    const requests: Array<{ path: string; authorization: string | null; body: any }> = [];
    const issuer = generateKeyPairSync("ed25519");
    const actor = generateKeyPairSync("ed25519");
    const other = generateKeyPairSync("ed25519");
    const public_key = issuer.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
    let mode = "valid";
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      const body = request.method === "POST" ? await request.json() as any : null;
      requests.push({ path: new URL(request.url).pathname, authorization: request.headers.get("authorization"), body });
      if (request.method === "GET") {
        if (mode === "redirect") return new Response(null, { status: 302, headers: { location: "http://127.0.0.1:1/other-company" } });
        return Response.json({ version: "omos.company/v1", workspace: mode === "other-workspace" ? "other-company" : "company-fixture", issuer: public_key, epoch: 7 });
      }
      if (mode === "http-rejection") return Response.json({ error: "WorkspaceInjectedFailure" }, { status: 400 });
      if (mode === "bad-json") return new Response("{incomplete", { headers: { "content-type": "application/json" } });
      const original = JSON.parse(body.payload);
      const payload = JSON.stringify({ version: "omos.company-receipt/v1", workspace: "company-fixture", actor: original.actor, grant: original.grant, operation: mode === "other-operation" ? "replayed-operation" : original.operation, request_hash: createHash("sha256").update(mode === "changed-request" ? JSON.stringify(original) : body.payload).digest("hex"), action: original.action, epoch: mode === "other-epoch" ? 8 : 7, result: { workspace: "company-fixture", revision: "fixture-revision" } });
      const key = mode === "other-issuer" ? other : issuer;
      return Response.json({ payload, signature: mode === "bad-signature" ? "00".repeat(64) : sign(null, Buffer.from(payload), key.privateKey).toString("hex"), issuer: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex") });
    } });
    try {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: "company-fixture", actor: "reader", grant: "scoped-reader", operation: "inspect-once", expires_ms: Date.now() + 120000, action: "discover" }) + " ";
      const request = { payload, signature: sign(null, Buffer.from(payload), actor.privateKey).toString("hex") };
      const file = join(f.home, "signed-request.json");
      writeFileSync(file, JSON.stringify(request));
      const invoke = () => f.run(["fossil", "remote", `http://127.0.0.1:${server.port}`, file, "--json"], { OMOS_WORKSPACE_TOKEN: "private-owner-token-must-not-be-forwarded" });
      const result = await invoke();
      expect(result.code, result.stderr).toBe(0);
      expect(requests).toEqual([{ path: "/v1/company", authorization: null, body: null }, { path: "/v1/company", authorization: null, body: request }]);
      expect(result.stdout).not.toContain("private-owner-token");
      for (const [failure, error] of [["bad-signature", "CompanySignatureRejected"], ["other-operation", "CompanyReceiptMismatch"], ["changed-request", "CompanyReceiptMismatch"], ["other-epoch", "CompanyReceiptMismatch"], ["other-issuer", "CompanySignatureRejected"], ["other-workspace", "WorkspaceIdentityMismatch"], ["redirect", "WorkspaceServiceRejected"]]) {
        mode = failure;
        const before = requests.length;
        const rejected = await invoke();
        expect(rejected.code).toBe(1);
        expect(rejected.stderr + rejected.stdout).toContain(error);
        expect(requests.slice(before).filter(request => request.body !== null)).toHaveLength(["other-workspace", "redirect"].includes(mode) ? 0 : 1);
        expect(rejected.stdout + rejected.stderr).not.toContain("private-owner-token");
      }
      for (const [failure, error] of [["bad-signature", "WorkspaceServiceOutcomeUnverified"], ["http-rejection", "WorkspaceServiceOutcomeUnknown"], ["bad-json", "WorkspaceServiceOutcomeUnknown"]]) {
        mode = failure;
        const payload = JSON.stringify({ version: "omos.company/v1", workspace: "company-fixture", actor: "reader", grant: "scoped-reader", operation: `uncertain-${failure}`, expires_ms: Date.now() + 120000, action: "create_view", objective: "Prepare the isolated company view", revision: "fixture-revision" });
        writeFileSync(file, JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), actor.privateKey).toString("hex") }));
        const before = requests.length;
        const uncertain = await invoke();
        expect(uncertain.code).toBe(1);
        expect(uncertain.stdout + uncertain.stderr).toContain(error);
        expect(requests.slice(before).filter(request => request.body !== null)).toHaveLength(1);
      }
      expect(requests.every(request => request.path === "/v1/company" && request.authorization === null)).toBe(true);
    } finally { server.stop(true); }
  }, 30000);

  test("packages only authorised pinned company files with signed inventory and bounded content pages", async () => {
    const f = fixture();
    const content = "#!/bin/sh\n" + "# A portable, permission-scoped company script.\n".repeat(900) + "printf 'scoped-script\\n'\n";
    const path = "skills/portable/run.sh";
    const gateway = model(f, (body, count) => {
      if (count === 1) return { tool_calls: [{ index: 0, id: "save-script", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path, content }) } }] };
      if (count === 2) {
        const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
        const root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
        return { tool_calls: [{ index: 0, id: "mark-executable", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `chmod 700 '${root}/${path}'`, timeout_ms: 10000 } }) } }] };
      }
      return { content: "Saved the portable executable script." };
    });
    const prepared = await f.run(["ask", "--json", "Save the company document"]);
    expect(prepared.code, prepared.stderr).toBe(0);
    expect(gateway.counts().actors).toBe(3);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const created = await f.run(["fossil", "company-key", "reader", "--json"]);
    expect(created.code, created.stderr).toBe(0);
    const identity = JSON.parse(created.stdout);
    const initialized = await admin({ action: "initialize" });
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "file-export", actor: "reader", public_key: identity.public_key, paths: ["skills/"], actions: ["export_scope"], expires_ms: Date.now() + 3600000 } });
    const service = await startWorkspaceService(f, false);
    try {
      const boot = await (await fetch(service.url + "/v1/company")).json() as any;
      const config = { version: "omos.scope-export-request/v1", endpoint: service.url, workspace: boot.workspace, actor: "reader", grant: "file-export", key_handle: "reader", issuer: boot.issuer, revision: boot.revision };
      const input = join(f.home, "export.json"), output = join(f.home, "company-files.tar");
      writeFileSync(input, JSON.stringify(config));
      const exported = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(exported.code, exported.stderr + exported.stdout).toBe(0);
      const result = JSON.parse(exported.stdout);
      expect(result).toMatchObject({ version: "omos.scope-package/v2", file_attributes: "verified", path: output, workspace: boot.workspace, revision: boot.revision, files: 1, bytes: Buffer.byteLength(content), dependency_closure: "not_evaluated" });
      expect(statSync(output).mode & 0o777).toBe(0o600);
      const archive = readFileSync(output), objects = new Map<string, Buffer>();
      for (let at = 0; at + 512 <= archive.length && archive[at] !== 0;) {
        const header = archive.subarray(at, at + 512);
        const name = header.subarray(0, 100).toString().split("\0")[0];
        const size = parseInt(header.subarray(124, 136).toString().replace(/\0/g, "").trim(), 8);
        objects.set(name, archive.subarray(at + 512, at + 512 + size));
        at += 512 + Math.ceil(size / 512) * 512;
      }
      const manifest = JSON.parse(objects.get("manifest.json")!.toString());
      expect(manifest).toMatchObject({ scope: "grant_file_snapshot", dependency_closure: "not_evaluated", revision: boot.revision, actor: "reader", grant: "file-export", issuer: boot.issuer });
      expect(manifest.files).toEqual([{ path, executable: true, sha256: createHash("sha256").update(content).digest("hex"), bytes: Buffer.byteLength(content) }]);
      const document = objects.get(`objects/${manifest.files[0].sha256}`)!;
      expect(document.toString()).toBe(content);
      expect(objects.size).toBe(2);
      expect(manifest.inventory_receipts).toHaveLength(1);
      for (const proof of manifest.inventory_receipts) {
        const claims = JSON.parse(proof.receipt.payload), request = JSON.parse(proof.request);
        const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), type: "spki", format: "der" });
        expect(verify(null, Buffer.from(proof.receipt.payload), publicKey, Buffer.from(proof.receipt.signature, "hex"))).toBe(true);
        expect(claims.request_hash).toBe(createHash("sha256").update(request.payload).digest("hex"));
        expect(claims.result.files).toEqual(manifest.files);
        expect(JSON.parse(request.payload).action).toBe("export_scope");
        expect(JSON.parse(request.payload).version).toBe("omos.company/v2");
      }
      const seed = readFileSync(join(f.home, ".fx", "company-keys", "reader.seed"));
      expect(archive.includes(seed)).toBe(false);
      const offline = fixture();
      const offlineConfig = join(offline.home, "pins.json"), offlineArchive = join(offline.home, "files.tar");
      writeFileSync(offlineConfig, JSON.stringify({ ...config, endpoint: "http://127.0.0.1:1" }));
      writeFileSync(offlineArchive, archive);
      const verified = await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"]);
      expect(verified.code, verified.stderr).toBe(0);
      expect(JSON.parse(verified.stdout)).toMatchObject({ file_attributes: "verified", files: 1, bytes: Buffer.byteLength(content), revision: boot.revision });
      expect(existsSync(join(offline.home, ".fx", "omos-workspace.json"))).toBe(false);
      expect(existsSync(join(offline.home, ".fx", "company-keys"))).toBe(false);
      const corrupt = Buffer.from(archive); corrupt[512] ^= 1;
      writeFileSync(offlineArchive, corrupt);
      const damaged = await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"]);
      expect(damaged.code).toBe(1);
      expect(damaged.stdout + damaged.stderr).toContain("ScopeExportHashMismatch");
      const invented = Buffer.from(archive);
      const pathIndex = invented.indexOf(Buffer.from('"path":' + JSON.stringify(path)));
      expect(pathIndex).toBeGreaterThan(0);
      invented[pathIndex + Buffer.byteLength('"path":"skills/')] = "P".charCodeAt(0);
      writeFileSync(offlineArchive, invented);
      const forged = await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"]);
      expect(forged.code).toBe(1);
      expect(forged.stdout + forged.stderr).toContain("InvalidScopePackage");
      const missingFlag = Buffer.from(archive);
      const flagIndex = missingFlag.indexOf(Buffer.from('"executable":true'));
      expect(flagIndex).toBeGreaterThan(0);
      missingFlag.write("null", flagIndex + Buffer.byteLength('"executable":'));
      writeFileSync(offlineArchive, missingFlag);
      expect((await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"])).code).toBe(1);
      const downgrade = Buffer.from(archive);
      const versionIndex = downgrade.indexOf(Buffer.from('"version":"omos.scope-package/v2"'));
      expect(versionIndex).toBeGreaterThan(0);
      downgrade[versionIndex + Buffer.byteLength('"version":"omos.scope-package/v')] = "1".charCodeAt(0);
      writeFileSync(offlineArchive, downgrade);
      const downgraded = await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"]);
      expect(downgraded.code).toBe(1);
      expect(downgraded.stdout + downgraded.stderr).toContain("InvalidScopePackage");

      // An actual legacy v1 receipt still verifies as bytes-only. Its missing
      // mode information must not be reported as verified file attributes.
      const actorKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
      const legacyPayload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "reader", grant: "file-export", operation: "legacy-inventory", expires_ms: Date.now() + 120000, action: "export_scope", revision: boot.revision, offset: 0 });
      const legacyRequest = { payload: legacyPayload, signature: sign(null, Buffer.from(legacyPayload), actorKey).toString("hex") };
      const legacyResponse = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(legacyRequest) });
      expect(legacyResponse.status).toBe(200);
      const legacyReceipt = await legacyResponse.json() as any;
      const legacyManifest = { ...manifest, version: "omos.scope-package/v1", files: JSON.parse(legacyReceipt.payload).result.files, inventory_receipts: [{ request: JSON.stringify(legacyRequest), receipt: legacyReceipt }] };
      const repacked = spawnSync("python3", ["-c", "import base64,io,json,sys,tarfile\nv=json.load(sys.stdin); out=io.BytesIO(); expected=1024\nwith tarfile.open(fileobj=out,mode='w',format=tarfile.USTAR_FORMAT) as archive:\n for name,encoded in v:\n  data=base64.b64decode(encoded); info=tarfile.TarInfo(name); info.size=len(data); info.mode=0o600; archive.addfile(info,io.BytesIO(data)); expected+=512+((len(data)+511)//512)*512\nsys.stdout.buffer.write(out.getvalue()[:expected])\n"], { input: JSON.stringify([[`objects/${manifest.files[0].sha256}`, document.toString("base64")], ["manifest.json", Buffer.from(JSON.stringify(legacyManifest)).toString("base64")]]), maxBuffer: archive.length * 2 });
      expect(repacked.status, repacked.stderr.toString()).toBe(0);
      writeFileSync(offlineArchive, repacked.stdout);
      const legacyVerified = await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"]);
      expect(legacyVerified.code, legacyVerified.stderr).toBe(0);
      expect(JSON.parse(legacyVerified.stdout)).toMatchObject({ version: "omos.scope-package/v1", file_attributes: "unavailable", files: 1 });
      writeFileSync(offlineArchive, archive);
      writeFileSync(offlineConfig, JSON.stringify({ ...config, issuer: "00".repeat(32) }));
      const untrusted = await offline.run(["fossil", "verify-scope", offlineConfig, offlineArchive, "--json"]);
      expect(untrusted.code).toBe(1);
      expect(untrusted.stdout + untrusted.stderr).toContain("InvalidScopePackage");
      const original = createHash("sha256").update(archive).digest("hex");
      const duplicate = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(duplicate.code).toBe(1);
      expect(createHash("sha256").update(readFileSync(output)).digest("hex")).toBe(original);
      const staging = output + ".partial-" + createHash("sha256").update(JSON.stringify(config)).digest("hex");
      expect(readFileSync(join(staging, manifest.files[0].sha256)).toString()).toBe(content);
      rmSync(output);
      const revoked = await admin({ action: "status" });
      await admin({ action: "revoke", revision: revoked.revision, id: "file-export" });
      const denied = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(denied.code).toBe(1);
      expect(denied.stderr + denied.stdout).toContain("WorkspaceServiceDenied");
      expect(existsSync(output)).toBe(false);
    } finally { service.child.kill(); await service.child.exited; }
  }, 120000);

  test("rejects corrupt scoped export pages and enforces the network deadline without publishing partial archives", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "company-key", "reader", "--json"])).code).toBe(0);
    const issuer = generateKeyPairSync("ed25519");
    const public_key = issuer.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
    const revision = "a".repeat(64), content = Buffer.alloc(20000, 42), hash = createHash("sha256").update(content).digest("hex");
    let mode = "hash", posts = 0, contentCalls = 0, inventoryCalls = 0;
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      if (mode === "stall") return new Promise<Response>(() => {});
      if (request.method === "GET") return Response.json({ version: "omos.company/v1", workspace: "company", issuer: public_key, epoch: 1, features: mode === "legacy-server" ? undefined : { file_attributes: "omos.company/v2" } });
      posts++;
      expect(request.headers.get("authorization")).toBe(null);
      const envelope = await request.json() as any, query = JSON.parse(envelope.payload);
      expect(query.executable).toBeUndefined();
      expect(query.previous_executable).toBeUndefined();
      let result: any;
      if (!query.path) {
        inventoryCalls++;
        if (mode === "deny-final" && inventoryCalls > 1) return Response.json({ error: "CompanyAccessDenied" }, { status: 403 });
        result = { version: "omos.scoped-export/v2", workspace: "company", revision, actor: "reader", grant: "exporter", files: [{ path: "documents/report.md", sha256: hash, bytes: content.length, executable: false }], total: 1, next_offset: null };
      }
      else {
        contentCalls++;
        const end = Math.min(query.offset + 16384, content.length);
        const bytes = Buffer.from(content.subarray(query.offset, end));
        if (mode === "hash") bytes[0] ^= 1;
        result = { executable: false, revision, path: query.path, exists: true, offset: mode === "offset" ? query.offset + 1 : query.offset, bytes: content.length, sha256: hash, encoding: "base64", content: bytes.toString("base64"), next_offset: end < content.length ? end : null };
      }
      const payload = JSON.stringify({ version: "omos.company-receipt/v1", workspace: "company", actor: "reader", grant: "exporter", operation: query.operation, request_hash: createHash("sha256").update(envelope.payload).digest("hex"), action: "export_scope", epoch: 1, result });
      return Response.json({ payload, signature: sign(null, Buffer.from(payload), issuer.privateKey).toString("hex"), issuer: public_key });
    } });
    try {
      const config = { version: "omos.scope-export-request/v1", endpoint: `http://127.0.0.1:${server.port}`, workspace: "company", actor: "reader", grant: "exporter", key_handle: "reader", issuer: public_key, revision };
      const input = join(f.home, "export.json"), output = join(f.home, "bounded.tar");
      writeFileSync(input, JSON.stringify(config));
      for (const [failure, expected] of [["hash", "ScopeExportHashMismatch"], ["offset", "InvalidScopeExportSegment"]]) {
        mode = failure;
        const rejected = await f.run(["fossil", "export-scope", input, output, "--json"]);
        expect(rejected.code).toBe(1);
        expect(rejected.stdout + rejected.stderr).toContain(expected);
        expect(existsSync(output)).toBe(false);
      }
      mode = "legacy-server";
      const beforeLegacy = posts;
      const unsupported = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(unsupported.code).toBe(1);
      expect(unsupported.stderr + unsupported.stdout).toContain("CompanyDefinitionUpdateRequired");
      expect(posts).toBe(beforeLegacy);
      expect(existsSync(output)).toBe(false);
      mode = "valid";
      writeFileSync(input, JSON.stringify({ ...config, max_bytes: content.length - 1 }));
      const before = posts;
      const over = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(over.code).toBe(1);
      expect(over.stdout + over.stderr).toContain("ScopeExportByteLimit");
      expect(posts - before).toBe(1);
      expect(existsSync(output)).toBe(false);
      writeFileSync(input, JSON.stringify(config));
      const valid = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(valid.code, valid.stderr).toBe(0);
      expect(JSON.parse(valid.stdout).shared_cache.stored_bytes).toBe(content.length);
      const sharedDirectory = join(f.home, ".fx/cache/company-objects");
      const sharedObjects = readdirSync(sharedDirectory).filter(name => name.endsWith(`-${hash}`));
      expect(sharedObjects).toHaveLength(1);
      const sharedObject = join(sharedDirectory, sharedObjects[0]);
      expect(statSync(sharedDirectory).mode & 0o777).toBe(0o700);
      expect(statSync(sharedObject).mode & 0o777).toBe(0o600);
      const stage = output + ".partial-" + createHash("sha256").update(JSON.stringify(config)).digest("hex");
      expect(readFileSync(join(stage, hash)).equals(content)).toBe(true);
      const otherOutput = join(f.home, "other-export.tar");
      const sharedBefore = contentCalls;
      const shared = await f.run(["fossil", "export-scope", input, otherOutput, "--json"]);
      expect(shared.code, shared.stderr).toBe(0);
      expect(JSON.parse(shared.stdout).shared_cache.hits).toBe(1);
      expect(contentCalls).toBe(sharedBefore);
      expect((await f.run(["fossil", "verify-scope", input, otherOutput, "--json"])).code).toBe(0);
      rmSync(output);
      const warmBefore = contentCalls;
      const warm = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(warm.code, warm.stderr).toBe(0);
      expect(contentCalls).toBe(warmBefore);
      rmSync(output);
      writeFileSync(join(stage, hash), Buffer.alloc(content.length, 0));
      const sharedRepairBefore = contentCalls;
      const sharedRepair = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(sharedRepair.code, sharedRepair.stderr).toBe(0);
      expect(JSON.parse(sharedRepair.stdout).shared_cache.hits).toBe(1);
      expect(contentCalls).toBe(sharedRepairBefore);
      rmSync(output);
      writeFileSync(sharedObject, Buffer.alloc(content.length, 0));
      const damagedBefore = contentCalls;
      const repaired = await f.run(["fossil", "export-scope", input, output, "--json"]);
      expect(repaired.code, repaired.stderr).toBe(0);
      expect(contentCalls - damagedBefore).toBe(2);
      expect(readFileSync(join(stage, hash)).equals(content)).toBe(true);
      expect(readFileSync(sharedObject).equals(content)).toBe(true);
      rmSync(output);
      mode = "deny-final";
      inventoryCalls = 0;
      const revokedContentCalls = contentCalls;
      const revokedOutput = join(f.home, "revoked-export.tar");
      const revoked = await f.run(["fossil", "export-scope", input, revokedOutput, "--json"]);
      expect(revoked.code).toBe(1);
      expect(revoked.stdout + revoked.stderr).toContain("WorkspaceServiceDenied");
      expect(inventoryCalls).toBe(2);
      expect(contentCalls).toBe(revokedContentCalls);
      expect(existsSync(revokedOutput)).toBe(false);
      mode = "stall";
      writeFileSync(input, JSON.stringify({ ...config, deadline_ms: 100 }));
      const started = performance.now();
      const timed = await f.run(["fossil", "export-scope", input, output, "--json"], {}, 5000);
      expect(timed.code).toBe(1);
      expect(timed.stdout + timed.stderr).toContain("Timeout");
      expect(performance.now() - started).toBeLessThan(4000);
      expect(existsSync(output)).toBe(false);
    } finally { server.stop(true); }
  }, 60000);

  test("retains signed requests and reconciles an expired checkpoint without replaying its commit", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "recoverable", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/"], actions: ["create_view", "checkpoint", "status", "reconcile"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "company-checkpoint-committed" });
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const seal = (action: string, params: object, operation = crypto.randomUUID(), expires = Date.now() + 120000) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "recoverable", operation, expires_ms: expires, action, ...params });
      return { payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") };
    };
    const send = (request: object) => fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json", connection: "close" }, body: JSON.stringify(request) });
    const data = async (response: Response) => {
      const value = await response.json() as any;
      expect(response.status, JSON.stringify(value)).toBe(200);
      return JSON.parse(value.payload).result;
    };
    try {
      const view = await data(await send(seal("create_view", { revision: boot.revision, objective: "Retain this document checkpoint" })));
      const operation = crypto.randomUUID();
      const expires = Date.now() + 2000;
      const content = "Durable original content café\n".repeat(2000);
      const original = seal("checkpoint", { view: view.view, revision: view.revision, path: "documents/retained.txt", previous_hash: null, content }, operation, expires);
      const raw = JSON.stringify(original);
      expect((await send(original)).status).toBe(400);
      service.child.kill(); await service.child.exited;
      service = await startWorkspaceService(f, true);
      if (Date.now() <= expires) await Bun.sleep(expires - Date.now() + 1);
      expect((await send(original)).status).toBe(403);
      const chunks: Buffer[] = [];
      let offset = 0;
      for (;;) {
        const outcome = await data(await send(seal("status", { outcome: operation, offset })));
        expect(outcome.state).toBe("uncertain");
        expect(outcome.request_hash).toBe(createHash("sha256").update(original.payload).digest("hex"));
        expect(outcome.request.sha256).toBe(createHash("sha256").update(raw).digest("hex"));
        const page = Buffer.from(outcome.request.content, "base64");
        expect(page.length).toBeLessThanOrEqual(16384);
        chunks.push(page);
        if (outcome.request.next_offset === null) break;
        offset = outcome.request.next_offset;
      }
      expect(Buffer.concat(chunks).toString()).toBe(raw);
      const before = f.fossil("info", `task/${view.contract.id}`);
      const recoveryId = crypto.randomUUID();
      const recovered = await data(await send(seal("reconcile", { outcome: operation }, recoveryId)));
      expect(recovered.state).toBe("completed");
      expect(f.fossil("info", `task/${view.contract.id}`)).toBe(before);
      const outcome = await data(await send(seal("status", { outcome: operation })));
      expect(outcome.reconciled_by).toBe(recoveryId);
      const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
      expect(verify(null, Buffer.from(outcome.receipt.payload), issuer, Buffer.from(outcome.receipt.signature, "hex"))).toBe(true);
      expect(JSON.parse(outcome.receipt.payload).operation).toBe(operation);
      expect(f.fossil("cat", "documents/retained.txt", "-r", `task/${view.contract.id}`)).toBe(content);
      const current = await admin({ action: "status" });
      await admin({ action: "revoke", revision: current.revision, id: "recoverable" });
      expect((await send(seal("reconcile", { outcome: operation }))).status).toBe(403);
    } finally {
      service.child.kill(); await service.child.exited;
    }
  }, 120000);

  test("commits action intent to Fossil before a shell effect can start", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const program = join(f.home, "verify-intent.py");
    const effect = join(f.home, "effect-receipt.txt");
    writeFileSync(program, `import json, pathlib, subprocess\nrepo = ${JSON.stringify(join(f.cwd, "omos.fossil"))}\nbranches = subprocess.check_output(['fossil', 'branch', 'list', '--all', '-R', repo], text=True).splitlines()\nbranch = next(b.strip(' *\\t') for b in branches if b.strip(' *\\t').startswith('task/'))\nfiles = subprocess.check_output(['fossil', 'ls', '-r', branch, '-R', repo], text=True).splitlines()\nrows = [json.loads(subprocess.check_output(['fossil', 'cat', p, '-r', branch, '-R', repo], text=True)) for p in files if p.startswith('history/') and p.endswith('.json')]\nassert any(row.get('kind') == 'action_intent' and any(call.get('name') == 'shell' for call in row['value']['calls']) for row in rows), 'The effect started without a committed intent'\npathlib.Path(${JSON.stringify(effect)}).write_text('Committed intent observed before this effect')\nprint('Committed intent observed before this effect')\n`);
    const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
    model(f, (_body, count) => count === 1 ? { tool_calls: [{ index: 0, id: "durable-effect", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `python3 ${quote(program)}`, timeout_ms: 10000 } }) } }] } : { content: "The effect observed its committed Fossil intent." });
    const result = await f.run(["ask", "Run the local fixture and report its durable receipt", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(readFileSync(effect, "utf8")).toBe("Committed intent observed before this effect");
  }, 90000);

  test("does not initialize personal persistence for an unsaved turn", async () => {
    const f = fixture();
    model(f, () => ({ content: "Hello." }));
    const result = await f.run(["ask", "Say hello", "--no-save", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(existsSync(join(f.home, ".fx/omos-workspace.json"))).toBe(false);
    expect(existsSync(join(f.home, ".fx/instances/personal.fossil"))).toBe(false);
  }, 60000);

  test("rejects the upstream updater before contacting it in a managed workspace", async () => {
    const f = fixture();
    let requests = 0;
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() { requests++; return new Response("99.0.0"); } });
    try {
      const before = createHash("sha256").update(readFileSync(join(import.meta.dir, "../../zig-out/bin/fx"))).digest("hex");
      const result = await f.run(["upgrade", "--json"], { FX_E2E_UPGRADE_BASE_URL: `http://127.0.0.1:${server.port}` }, 15000);
      expect(result.code).toBe(1);
      expect(result.stdout).toContain("WorkspaceRuntimeUpgradeUnsupported");
      expect(result.stdout).toContain("verified omos bundle");
      expect(requests).toBe(0);
      expect(createHash("sha256").update(readFileSync(join(import.meta.dir, "../../zig-out/bin/fx"))).digest("hex")).toBe(before);
      for (const name of ["omos", "omo"]) {
        const alias = join(f.home, name);
        symlinkSync(join(import.meta.dir, "../../zig-out/bin/fx"), alias);
        const result = spawnSync(alias, ["upgrade", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env, FX_CONTRACT_REVIEW: undefined, FX_E2E_UPGRADE_BASE_URL: `http://127.0.0.1:${server.port}` }, encoding: "utf8", timeout: 5000 });
        expect(result.status, result.stderr).toBe(1);
        expect(result.stdout).toContain("WorkspaceRuntimeUpgradeUnsupported");
      }
      expect(requests).toBe(0);
      expect(existsSync(join(f.home, ".fx/omos-workspace.json"))).toBe(false);
    } finally { server.stop(true); }
  }, 30000);

  test("installs a verified Fossil helper and rejects changes before executing it", async () => {
    const f = fixture();
    const script = join(import.meta.dir, "../../scripts/install-omos.sh");
    const installed = spawnSync("sh", [script], { cwd: f.cwd, env: { ...process.env, ...f.env, XDG_BIN_HOME: join(f.home, ".local/bin") }, encoding: "utf8", timeout: 60000 });
    expect(installed.status, installed.stderr).toBe(0);
    const manifest = JSON.parse(readFileSync(join(f.home, ".fx/libexec/fossil.json"), "utf8"));
    const helper = join(f.home, ".fx/libexec", manifest.file);
    expect(createHash("sha256").update(readFileSync(helper)).digest("hex")).toBe(manifest.sha256);
    const status = await f.run(["fossil", "status", "--json"], { PATH: "/nonexistent" });
    expect(status.code, status.stderr).toBe(0);
    expect(JSON.parse(status.stdout).tasks).toEqual([]);
    for (const command of ["omos", "omo"]) {
      const alias = spawnSync(join(f.home, ".local/bin", command), ["fossil", "status", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env }, encoding: "utf8" });
      expect(alias.status, alias.stderr).toBe(0);
      expect(JSON.parse(alias.stdout).workspace_id).toBe(JSON.parse(status.stdout).workspace_id);
    }
    const companion = JSON.parse(readFileSync(join(f.home, ".fx/libexec/company-mcp.json"), "utf8"));
    expect(companion.version).toBe("omos.company-mcp-installation/v1");
    expect(companion.files).toHaveLength(2);
    for (const file of companion.files) {
      const path = join(f.home, ".fx", file.path);
      expect(statSync(path).mode & 0o777).toBe(0o600);
      expect(createHash("sha256").update(readFileSync(path)).digest("hex")).toBe(file.sha256);
    }
    // Reproduce interruption after one immutable file was installed but before
    // its pair and locator were acknowledged. Keep the first file intact.
    const schemaFile = companion.files.find((file: any) => file.path.endsWith("/omos.json"));
    rmSync(join(f.home, ".fx", schemaFile.path));
    rmSync(join(f.home, ".fx/libexec/company-mcp.json"));
    const again = spawnSync("sh", [script], { cwd: f.cwd, env: { ...process.env, ...f.env, XDG_BIN_HOME: join(f.home, ".local/bin") }, encoding: "utf8", timeout: 60000 });
    expect(again.status, again.stderr).toBe(0);
    expect(JSON.parse(readFileSync(join(f.home, ".fx/libexec/company-mcp.json"), "utf8"))).toEqual(companion);
    expect(createHash("sha256").update(readFileSync(join(f.home, ".fx", schemaFile.path))).digest("hex")).toBe(schemaFile.sha256);
    const entry = join(f.home, ".fx", companion.file);
    appendFileSync(entry, "\n// Retain this changed installation component.\n");
    const refused = spawnSync("sh", [script], { cwd: f.cwd, env: { ...process.env, ...f.env, XDG_BIN_HOME: join(f.home, ".local/bin") }, encoding: "utf8", timeout: 60000 });
    expect(refused.status).not.toBe(0);
    expect(refused.stderr).toContain("Refusing to replace a changed installation component");
    expect(readFileSync(entry, "utf8")).toContain("Retain this changed installation component");
    appendFileSync(helper, "changed");
    const changed = await f.run(["fossil", "status", "--json"]);
    expect(changed.code).toBe(1);
    expect(changed.stderr).toContain("FossilExecutableChanged");
  }, 180000);

  test.skipIf(!existsSync(join(import.meta.dir, "../../zig-out/libexec/fossil")))("installs a portable bundle without system Fossil and survives removal of the download", async () => {
    const f = fixture();
    const root = join(import.meta.dir, "../..");
    const platform = `${process.platform === "darwin" ? "macos" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}`;
    const archive = join(f.home, "omos-preview.tar.gz");
    const packaged = spawnSync("python3", [join(root, "scripts/package-omos.py"), "--platform", platform, "--output", archive, "--compression-level", "1"], { encoding: "utf8", timeout: 90000 });
    expect(packaged.status, packaged.stderr).toBe(0);
    const unpacked = join(f.home, "download");
    mkdirSync(unpacked);
    const extracted = spawnSync("tar", ["-xzf", archive, "-C", unpacked], { encoding: "utf8" });
    expect(extracted.status, extracted.stderr).toBe(0);
    const bin = join(f.home, "commands");
    const installed = spawnSync("sh", [join(unpacked, "omos/install.sh")], { env: { ...process.env, ...f.env, XDG_BIN_HOME: bin }, encoding: "utf8", timeout: 60000 });
    expect(installed.status, `${installed.error ?? ""}\n${installed.stdout}\n${installed.stderr}`).toBe(0);
    const binding = JSON.parse(readFileSync(join(f.home, ".fx/omos-workspace.json"), "utf8"));
    rmSync(unpacked, { recursive: true });
    const emptyPath = join(f.home, "empty-path");
    mkdirSync(emptyPath);
    for (const command of ["omos", "omo"]) {
      const result = spawnSync(join(bin, command), ["fossil", "ensure", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env, PATH: emptyPath }, encoding: "utf8", timeout: 30000 });
      expect(result.status, result.stderr).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.workspace_id).toBe(binding.workspace_id);
      expect(status.tasks).toEqual([]);
      expect(status.repository).toBe(binding.repository);
    }
    const keyResult = spawnSync(join(bin, "omos"), ["fossil", "company-key", "packaged-worker", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env, PATH: emptyPath }, encoding: "utf8", timeout: 30000 });
    expect(keyResult.status, keyResult.stderr).toBe(0);
    const key = JSON.parse(keyResult.stdout);
    const companion = JSON.parse(readFileSync(join(f.home, ".fx/libexec/company-mcp.json"), "utf8"));
    const entry = join(f.home, ".fx", companion.file);
    expect(existsSync(entry)).toBe(true);
    const config = join(f.home, "packaged-mcp.json");
    writeFileSync(config, JSON.stringify({ version: "omos.company-mcp/v1", endpoint: "http://127.0.0.1:9", workspace: binding.workspace_id, issuer: key.public_key, epoch: 1, actor: "worker", grant: "packaged-grant", key_handle: "packaged-worker", actions: ["status"] }), { mode: 0o600 });
    const client = await companyMcp(config, f.home, entry);
    try {
      expect((await client.rpc("initialize", { protocolVersion: "2025-11-25" })).result.protocolVersion).toBe("2025-11-25");
      const tools = (await client.rpc("tools/list")).result.tools;
      expect(tools.map((tool: any) => tool.name)).toEqual(["company_context", "company_workspace"]);
      expect(tools[1].inputSchema.properties.action.enum).toEqual(["status"]);
      expect(tools[1].inputSchema.properties.progress_cursor.maxLength).toBe(4096);
    } finally { await client.close(); }
    expect(await client.stderr).toBe("");
  }, 180000);

  test("creates one empty personal instance automatically without importing existing sessions", async () => {
    const f = fixture();
    mkdirSync(join(f.home, ".fx", "sessions", "legacy"), { recursive: true });
    writeFileSync(join(f.home, ".fx", "sessions", "legacy", "session.json"), JSON.stringify({ private: "legacy-session-must-not-be-imported" }));
    const attempts = await Promise.all([f.run(["fossil", "ensure", "--json"]), f.run(["fossil", "ensure", "--json"])]);
    for (const attempt of attempts) expect(attempt.code, attempt.stderr).toBe(0);
    const first = JSON.parse(attempts[0].stdout);
    const second = JSON.parse(attempts[1].stdout);
    expect(first.workspace_id).toBe(second.workspace_id);
    expect(first.repository).toBe(join(f.home, ".fx", "instances", "personal.fossil"));
    expect(first.tasks).toEqual([]);
    expect(first.files).toContain("omniform/company.json");
    expect(first.files).toContain("execution/omos.json");
    expect(first.files.some((path: string) => /^(imports|history|skills|memory)\//.test(path))).toBe(false);
    expect(readFileSync(join(f.home, ".fx", "sessions", "legacy", "session.json"), "utf8")).toContain("legacy-session");
    const other = fixture();
    const otherInstance = JSON.parse((await other.run(["fossil", "ensure", "--json"])).stdout);
    expect(otherInstance.workspace_id).not.toBe(first.workspace_id);
  }, 60000);

  test("keeps the explicitly bound repository when ensuring a personal instance", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const result = await f.run(["fossil", "ensure", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout).repository).toBe(join(f.cwd, "omos.fossil"));
    expect(existsSync(join(f.home, ".fx", "instances", "personal.fossil"))).toBe(false);
  }, 60000);

  test("preserves executable scripts through automatic checkpoints, text edits, restoration, and mode-only changes", async () => {
    const f = fixture();
    const path = "skills/portable/run.sh";
    const original = "#!/bin/sh\nprintf 'first-version\\n'\n";
    const updated = "#!/bin/sh\nprintf 'restored-executable\\n'\n";
    const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
    const rootFrom = (body: any) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const match = context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/);
      expect(match).not.toBeNull();
      return JSON.parse(match![1]);
    };
    const call = (name: string, args: object) => ({ tool_calls: [{ index: 0, id: "script-operation", type: "function", function: { name, arguments: JSON.stringify(args) } }] });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    model(f, (body, count) => {
      const root = rootFrom(body);
      if (count === 1) return call("shell", { request: { action: "run", command: `mkdir -p ${quote(join(root, "skills/portable"))}; printf '%s' ${quote(original)} > ${quote(join(root, path))}; chmod 700 ${quote(join(root, path))}`, timeout_ms: 10000 } });
      if (count === 2) return call("fossil_workspace", { action: "write", path, content: updated });
      if (count === 3) {
        expect(statSync(join(root, path)).mode & 0o777).toBe(0o700);
        expect(readFileSync(join(root, path), "utf8")).toBe(updated);
        return call("fossil_workspace", { action: "write", path: "skills/portable/manifest.json", content: JSON.stringify({ files: [{ path, sha256: createHash("sha256").update(updated).digest("hex"), bytes: Buffer.byteLength(updated), executable: true }] }) });
      }
      if (count === 4) return call("fossil_workspace", { action: "verify_manifest", path: "skills/portable/manifest.json" });
      expect(body.messages.some((message: any) => message.role === "tool" && typeof message.content === "string" && message.content.includes('"executable_flags":1'))).toBe(true);
      return { content: "The script text and executable flag are verified in the portable workspace." };
    });
    const saved = await f.run(["ask", "Save and update a portable executable script", "--json"]);
    expect(saved.code, saved.stderr).toBe(0);
    const firstRevision = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).trunk_revision;
    expect(f.fossil("artifact", firstRevision)).toMatch(/^F skills\/portable\/run.sh [a-f0-9]+ x$/m);
    const exported = join(f.home, "executable-package.fossil");
    expect((await f.run(["fossil", "export", exported])).code).toBe(0);
    const clean = fixture();
    expect((await clean.run(["fossil", "use", exported])).code).toBe(0);
    model(clean, (body, count) => {
      const root = rootFrom(body);
      if (count === 1) {
        expect(existsSync(join(root, path))).toBe(false);
        return call("shell", { request: { action: "run", command: `test -x ${quote(join(root, path))} && ${quote(join(root, path))}`, timeout_ms: 10000 } });
      }
      if (count === 2) {
        expect(body.messages.some((message: any) => message.role === "tool" && typeof message.content === "string" && message.content.includes("restored-executable"))).toBe(true);
        return call("shell", { request: { action: "run", command: `chmod 600 ${quote(join(root, path))}`, timeout_ms: 10000 } });
      }
      if (count === 3) return call("fossil_workspace", { action: "write", path: "skills/portable/manifest.json", content: JSON.stringify({ files: [{ path, sha256: createHash("sha256").update(updated).digest("hex"), bytes: Buffer.byteLength(updated), executable: false }] }) });
      if (count === 4) return call("fossil_workspace", { action: "verify_manifest", path: "skills/portable/manifest.json" });
      expect(statSync(join(root, path)).mode & 0o777).toBe(0o600);
      return { content: "The restored executable ran, and its subsequent mode-only change was verified." };
    });
    const restored = await clean.run(["ask", "Run the restored script, then remove and verify its executable flag", "--json"]);
    expect(restored.code, restored.stderr).toBe(0);
    const status = JSON.parse((await clean.run(["fossil", "status", "--json"])).stdout);
    const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
    const command = spawnSync(existsSync(helper) ? helper : "fossil", ["artifact", status.trunk_revision, "-R", exported], { encoding: "utf8" });
    expect(command.status, command.stderr).toBe(0);
    expect(command.stdout).toMatch(/^F skills\/portable\/run.sh [a-f0-9]+$/m);
  }, 180000);

  test("restores a complete versioned skill package and prefers it over a legacy copy", async () => {
    const f = fixture();
    const instructions = "---\nname: portable-skill\ndescription: Read the fixture dataset using the included script\n---\nCanonical portable skill.\n" + "Retained package instructions. ".repeat(180);
    const program = 'import fs from "node:fs"; console.log(JSON.parse(fs.readFileSync(new URL("./data/input.json", import.meta.url))).name);';
    const makeLegacy = (home: string) => {
      mkdirSync(join(home, "project/.fx/skills/portable-skill"), { recursive: true });
      writeFileSync(join(home, "project/.fx/skills/portable-skill/SKILL.md"), "---\nname: portable-skill\ndescription: A stale compatibility copy\n---\nLegacy instructions must not shadow the versioned package.");
    };
    makeLegacy(f.home);
    model(f, (body, count) => {
      const text = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const match = text.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/);
      expect(match).not.toBeNull();
      const root = JSON.parse(match![1]);
      if (count === 1) return { tool_calls: [
        { path: "skills/portable-skill/SKILL.md", content: instructions },
        { path: "skills/portable-skill/run.mjs", content: program },
        { path: "skills/portable-skill/data/input.json", content: JSON.stringify({ name: "fixture-package-data" }) },
      ].map((file, index) => ({ index, id: `package-${index}`, type: "function", function: { name: "write_file", arguments: JSON.stringify({ ...file, path: join(root, file.path) }) } })) };
      if (count === 2) return { tool_calls: [{ index: 0, id: "load-package", type: "function", function: { name: "skill", arguments: JSON.stringify({ name: "portable-skill" }) } }] };
      if (count === 3) {
        expect(body.messages.some((message: any) => message.role === "tool" && typeof message.content === "string" && message.content.includes("Canonical portable skill."))).toBe(true);
        return { tool_calls: [{ index: 0, id: "run-package", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `node '${root}/skills/portable-skill/run.mjs'`, timeout_ms: 10000 } }) } }] };
      }
      expect(body.messages.some((message: any) => message.role === "tool" && typeof message.content === "string" && message.content.includes("fixture-package-data"))).toBe(true);
      return { content: "The complete portable skill package loaded and its executable read the included dataset." };
    });
    const initial = await f.run(["ask", "Save and exercise a complete portable skill package", "--json"]);
    expect(initial.code, initial.stderr).toBe(0);
    const exported = join(f.home, "skill-package.fossil");
    expect((await f.run(["fossil", "export", exported])).code).toBe(0);
    const clean = fixture();
    makeLegacy(clean.home);
    expect((await clean.run(["fossil", "use", exported])).code).toBe(0);
    model(clean, (body, count) => {
      const text = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(text.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      if (count >= 2) expect(readFileSync(join(root, "skills/portable-skill/SKILL.md"), "utf8")).toBe(instructions);
      if (count <= 2) expect(existsSync(join(root, "skills/portable-skill/run.mjs"))).toBe(false);
      else expect(readFileSync(join(root, "skills/portable-skill/run.mjs"), "utf8")).toBe(program);
      if (count === 1) return { tool_calls: [{ index: 0, id: "find-restored", type: "function", function: { name: "capability_search", arguments: JSON.stringify({ query: "portable skill" }) } }] };
      if (count === 2) return { tool_calls: [{ index: 0, id: "load-restored", type: "function", function: { name: "skill", arguments: JSON.stringify({ name: "portable-skill" }) } }] };
      if (count === 3) {
        expect(body.messages.some((message: any) => message.role === "tool" && typeof message.content === "string" && message.content.includes("Canonical portable skill."))).toBe(true);
        return { tool_calls: [{ index: 0, id: "execute-restored", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `node '${root}/skills/portable-skill/run.mjs'`, timeout_ms: 10000 } }) } }] };
      }
      expect(body.messages.some((message: any) => message.role === "tool" && typeof message.content === "string" && message.content.includes("fixture-package-data"))).toBe(true);
      return { content: "The restored skill and dataset work without the previous profile." };
    });
    const restored = await clean.run(["ask", "Discover and run the restored skill", "--json"]);
    expect(restored.code, restored.stderr).toBe(0);
  }, 120000);

  test("checkpoints ordinary file and shell changes and rebuilds the view from an exported repository", async () => {
    const f = fixture();
    let workingDirectory = "";
    model(f, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const match = context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/);
      expect(match).not.toBeNull();
      workingDirectory = JSON.parse(match![1]);
      if (count <= 2) return { tool_calls: [{ index: 0, id: `ordinary-${count}`, type: "function", function: {
        name: count === 1 ? "write_file" : "shell",
        arguments: JSON.stringify(count === 1 ? { path: join(workingDirectory, "memory", "portable.md"), content: "Portable memory from the ordinary file tool." } : { request: { action: "run", command: `mkdir -p '${workingDirectory}/documents'; printf 'Report from shell' > '${workingDirectory}/documents/report.txt'`, timeout_ms: 10000 } }),
      } }] };
      return { content: "Saved the memory and report in the workspace." };
    });
    const result = await f.run(["ask", "Save a memory and a report using ordinary file and shell tools", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    const saved = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const fossil = (...args: string[]) => {
      const command = spawnSync("fossil", [...args, "-R", saved.repository], { env: { ...process.env, HOME: f.home }, encoding: "utf8" });
      expect(command.status, command.stderr).toBe(0);
      return command.stdout;
    };
    expect(fossil("cat", "memory/portable.md", "-r", "trunk")).toContain("ordinary file tool");
    expect(fossil("cat", "documents/report.txt", "-r", "trunk")).toBe("Report from shell");
    const exported = join(f.home, "portable.fossil");
    expect((await f.run(["fossil", "export", exported])).code).toBe(0);
    const clean = fixture();
    expect((await clean.run(["fossil", "use", exported])).code).toBe(0);
    model(clean, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const match = context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/);
      expect(match).not.toBeNull();
      const rebuilt = JSON.parse(match![1]);
      expect(rebuilt).not.toBe(workingDirectory);
      if (count === 1) {
        expect(existsSync(join(rebuilt, "memory", "portable.md"))).toBe(false);
        expect(existsSync(join(rebuilt, "documents", "report.txt"))).toBe(false);
      } else {
        expect(existsSync(join(rebuilt, "memory", "portable.md"))).toBe(false);
        expect(readFileSync(join(rebuilt, "documents", "report.txt"), "utf8")).toBe("Report from shell");
      }
      if (count === 1) return { tool_calls: [{ index: 0, id: "inspect-portable", type: "function", function: { name: "read_file", arguments: JSON.stringify({ path: join(rebuilt, "documents", "report.txt") }) } }] };
      return { content: "The report was restored from the portable workspace." };
    });
    const restored = await clean.run(["ask", "Read the portable report", "--json"]);
    expect(restored.code, restored.stderr).toBe(0);
  }, 120000);

  test("materialises requested paths without deleting unfetched content and hydrates opaque shell reads", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let root = "";
    model(f, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      const call = (name: string, args: object) => ({ tool_calls: [{ index: 0, id: `sparse-${count}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] });
      if (count === 1) return call("fossil_workspace", { action: "write", path: "documents/one.txt", content: "Pinned first document" });
      if (count === 2) return call("fossil_workspace", { action: "write", path: "documents/unfetched.txt", content: "Keep this unread file" });
      if (count === 3) {
        expect(existsSync(join(root, "documents/one.txt"))).toBe(false);
        expect(existsSync(join(root, "documents/unfetched.txt"))).toBe(false);
        return call("read_file", { path: join(root, "documents/one.txt") });
      }
      if (count === 4) {
        expect(readFileSync(join(root, "documents/one.txt"), "utf8")).toBe("Pinned first document");
        expect(existsSync(join(root, "documents/unfetched.txt"))).toBe(false);
        return call("edit_file", { path: join(root, "documents/unfetched.txt"), old_string: "Keep", new_string: "Retain" });
      }
      if (count === 5) {
        expect(readFileSync(join(root, "documents/unfetched.txt"), "utf8")).toBe("Retain this unread file");
        return call("fossil_workspace", { action: "write", path: "memory/shell-only.txt", content: "Available to opaque commands" });
      }
      if (count === 6) {
        expect(existsSync(join(root, "memory/shell-only.txt"))).toBe(false);
        return call("shell", { request: { action: "run", command: `cat '${root}/memory/shell-only.txt'`, timeout_ms: 10000 } });
      }
      expect(readFileSync(join(root, "memory/shell-only.txt"), "utf8")).toBe("Available to opaque commands");
      return { content: "Read and edited the requested records while preserving all workspace content." };
    });
    const result = await f.run(["ask", "Read and edit workspace documents using their pinned files", "--json"], {}, 120000);
    expect(result.code, result.stderr).toBe(0);
    expect(f.fossil("cat", "documents/one.txt", "-r", "trunk")).toBe("Pinned first document");
    expect(f.fossil("cat", "documents/unfetched.txt", "-r", "trunk")).toBe("Retain this unread file");
    expect(f.fossil("cat", "memory/shell-only.txt", "-r", "trunk")).toBe("Available to opaque commands");
  }, 150000);

  test("searches sparse managed directories using absolute globs and scoped text queries", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    model(f, (body, count) => {
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      const call = (name: string, args: object) => ({ tool_calls: [{ index: 0, id: `sparse-search-${count}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] });
      if (count === 1) return { tool_calls: [
        { path: "documents/narrow/one.txt", content: "Narrow retained input" },
        { path: "documents/wide/two.txt", content: "Wide retained input" },
      ].map((file, index) => ({ index, id: `search-seed-${index}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", ...file }) } })) };
      if (count === 2) {
        expect(existsSync(join(root, "documents/narrow/one.txt"))).toBe(false);
        expect(existsSync(join(root, "documents/wide/two.txt"))).toBe(false);
        return call("glob_files", { pattern: join(root, "documents/narrow/*.txt") });
      }
      if (count === 3) {
        expect(readFileSync(join(root, "documents/narrow/one.txt"), "utf8")).toBe("Narrow retained input");
        expect(existsSync(join(root, "documents/wide/two.txt"))).toBe(false);
        expect(body.messages.some((message: any) => message.role === "tool" && message.content?.includes("one.txt"))).toBe(true);
        return call("grep_files", { pattern: "Wide retained", path: join(root, "documents/wide") });
      }
      expect(readFileSync(join(root, "documents/wide/two.txt"), "utf8")).toBe("Wide retained input");
      expect(body.messages.some((message: any) => message.role === "tool" && message.content?.includes("Wide retained input"))).toBe(true);
      return { content: "The requested file and text searches found their pinned content." };
    });
    const result = await f.run(["ask", "Find retained documents with file and text search", "--json"]);
    expect(result.code, result.stderr).toBe(0);
  }, 90000);

  test("recovers interrupted hydration without deleting unwritten files or replaying a shell", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let calls = 0;
    model(f, (body, count) => {
      calls = count;
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      const call = (name: string, args: object) => ({ tool_calls: [{ index: 0, id: `hydrate-recovery-${count}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] });
      if (count === 1 || count === 2) return call("fossil_workspace", { action: "write", path: `documents/${count}.txt`, content: `Retained document ${count}` });
      if (count === 3) return call("shell", { request: { action: "run", command: `touch '${root}/documents/must-not-run'`, timeout_ms: 10000 } });
      expect(existsSync(join(root, "documents/must-not-run"))).toBe(false);
      expect(readFileSync(join(root, "documents/1.txt"), "utf8")).toBe("Retained document 1");
      expect(existsSync(join(root, "documents/2.txt"))).toBe(false);
      if (count === 4) {
        expect(body.messages.some((message: any) => message.role === "tool" && message.content?.includes("WorkspaceInjectedFailure"))).toBe(true);
        return call("read_file", { path: join(root, "documents/1.txt") });
      }
      return { content: "The requested document is readable and both canonical files remain retained. The interrupted shell did not run." };
    });
    const result = await f.run(["ask", "Retain both documents and inspect the first after a hydration failure", "--json"], { FX_E2E_FOSSIL_FAULT: "projection_after_file" }, 90000);
    expect(result.code, result.stderr).toBe(0);
    expect(calls).toBe(5);
    expect(f.fossil("cat", "documents/1.txt", "-r", "trunk")).toBe("Retained document 1");
    expect(f.fossil("cat", "documents/2.txt", "-r", "trunk")).toBe("Retained document 2");
    expect(f.fossil("ls", "-r", "trunk")).not.toContain("must-not-run");
  }, 120000);

  test("accepts current coding validation through a compact host receipt and preserves its proof chain", async () => {
    const f = fixture();
    writeFileSync(join(f.cwd, ".gitignore"), "omos.fossil\n");
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => count <= 2 ? {
      tool_calls: [{ index: 0, id: `coding-${count}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: count === 1 ? "touch answer.txt" : "test -f answer.txt", timeout_ms: 10000 } }) } }],
    } : { content: "Created answer.txt and checked that it exists." }, packet => {
      const receipts = packet.evidence.filter((e: any) => e.id.startsWith("command-receipt:") && e.complete);
      const receipt = receipts.find((e: any) => JSON.parse(e.content).arguments?.includes("test -f answer.txt"));
      expect(receipt).toBeDefined();
      return { name: "omos_contract_assessment", args: {
        contractId: packet.contract.id, version: packet.contract.version,
        obligations: packet.contract.obligations.map((o: any) => ({ id: o.id, status: "met", evidence: [receipt.id, packet.evidence.find((e: any) => e.kind === "candidate").id], note: "The host receipt records the check and resolves to validation of the current source." })),
      } };
    }, { plan: { capability: "coding_task", summary: "Create and check answer.txt", obligations: [], checks: ["test -f answer.txt"] } });
    const result = await f.run(["ask", "Create answer.txt and verify it exists", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(m.counts().actors).toBe(3);
    const results = await f.run(["fossil", "query", "omos_result", "--json"]);
    expect(results.code, results.stderr).toBe(0);
    const data = JSON.parse(results.stdout).model_data;
    expect(data.records.some((row: any) => row.data.status === "published" && row.data.assessment)).toBe(true);
    expect(data.relationships.some((edge: any) => edge.relationship === "omos_assessment_result" && edge.authority === "host_observed")).toBe(true);
  }, 90000);

  test("rejects a failed compact receipt as success evidence for a general task", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => count === 1 ? {
      tool_calls: [{ index: 0, id: "failed-check", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: "test -f missing.txt", timeout_ms: 10000 } }) } }],
    } : { content: "The file exists." }, packet => {
      const receipt = packet.evidence.find((record: any) => record.id.startsWith("command-receipt:") && record.status === "failure");
      expect(receipt).toBeDefined();
      if (!receipt.complete && !packet.currentInspections.some((page: any) => page.id === receipt.id)) {
        return { name: "omos_review_evidence", args: { action: "read", id: receipt.id } };
      }
      return { name: "omos_contract_assessment", args: {
        contractId: packet.contract.id, version: packet.contract.version,
        obligations: packet.contract.obligations.map((obligation: any) => ({ id: obligation.id, status: "met", evidence: [receipt.id], note: "This failed receipt must not establish success." })),
      } };
    });
    const result = await f.run(["ask", "Confirm missing.txt exists", "--json"]);
    expect(result.code, result.stderr).toBe(1);
    expect(m.counts().actors).toBe(2);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(task.state).not.toBe("accepted");
    expect(f.fossil("ls", "-r", "trunk")).not.toContain(`acceptances/${task.id}/`);
  }, 60000);

  test("bounds typed query payloads and retrieves complete original evidence at a pinned revision", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const content = "retained evidence ".repeat(3000);
    model(f, (_body, count) => count === 1 ? writeMemory(content) : { content: "The preference was retained." }, () => "blocked");
    const first = await f.run(["ask", "Save this preference and keep the task open", "--json"]);
    expect(first.code).toBe(1);
    const session = JSON.parse(first.stdout).session_id;
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const service = await startWorkspaceService(f);
    try {
      const bootstrap = await (await fetch(`${service.url}/v1/definition`, { headers: service.headers })).json() as any;
      const basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: bootstrap.definition.basis.definition_hash, revision: bootstrap.revision };
      const directory = await (await service.post({ ...basis, action: "query", entity: "omos_task" })).json() as any;
      const revision = directory.data.records.find((row: any) => row.id === task.id).revision;
      const response = await service.post({ ...basis, revision, task: task.id, action: "query", entity: "omos_evidence" });
      const raw = await response.text();
      expect(response.status, raw).toBe(200);
      expect(Buffer.byteLength(raw)).toBeLessThan(65536);
      const reference = JSON.parse(raw).data.records.find((row: any) => row.complete === false);
      expect(reference.source_path).toStartWith(`history/${task.id}/`);
      expect((await f.run(["ask", "--resume-id", session, "Keep the preference and add this authenticated detail", "--json"])).code).toBe(1);
      let original = "";
      let offset = 0;
      for (;;) {
        const page = await service.post({ ...basis, revision, task: task.id, action: "read", path: reference.source_path, offset, limit: 4096 });
        expect(page.status, await page.clone().text()).toBe(200);
        const data = (await page.json() as any).data;
        expect(data.encoding).toBe("utf8");
        expect(Buffer.byteLength(data.content)).toBeLessThanOrEqual(4096);
        original += data.content;
        if (data.next_offset === null) break;
        expect(data.next_offset).toBeGreaterThan(offset);
        offset = data.next_offset;
      }
      expect(createHash("sha256").update(original).digest("hex")).toBe(reference.sha256);
      expect(JSON.parse(original).value[0].arguments).toContain(content);
    } finally {
      service.child.kill();
      await service.child.exited;
    }
  }, 90000);

  test("pages typed history beyond one Fossil packet and retains provenance without unselected payloads", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    model(f, () => ({ content: "Retain this candidate for inspection." }), () => "blocked");
    expect((await f.run(["ask", "Retain a candidate for a typed history query", "--json"])).code).toBe(1);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const tree = join(f.home, "typed-history-fixture");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
      return result.stdout;
    };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), task.branch);
    const history = join(tree, "history", task.id);
    mkdirSync(history, { recursive: true });
    const originals = new Map<string, { path: string; bytes: number; sha256: string }>();
    const save = (kind: string, value: any) => {
      const raw = JSON.stringify({ kind, task: task.id, contract_version: task.definition.version, value });
      const sha256 = createHash("sha256").update(raw).digest("hex");
      const path = `history/${task.id}/${sha256}.json`;
      writeFileSync(join(tree, path), raw);
      return { path, bytes: Buffer.byteLength(raw), sha256 };
    };
    for (let i = 0; i < 60; i++) {
      save("action_intent", { calls: [{ id: `call-${i}`, execution_id: `call-${i}`, name: "fixture_receipt", arguments: "{}" }] });
      const id = `tool:query:${i}`;
      originals.set(id, save("tool_evidence", [{ id, action_id: `call-${i}`, kind: "tool", tool: "fixture_receipt", status: "success", content: "x".repeat(220 * 1024) }]));
    }
    expect([...originals.values()].reduce((sum, record) => sum + record.bytes, 0)).toBeGreaterThan(8 * 1024 * 1024);
    fossil("add", "history"); fossil("commit", "--nosync", "--no-warnings", "-m", "Retain canonical query fixtures");
    const revision = fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
    const service = await startWorkspaceService(f);
    try {
      const boot = await (await fetch(service.url + "/v1/definition", { headers: service.headers })).json() as any;
      const basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: boot.definition.basis.definition_hash, revision, task: task.id, action: "query", entity: "omos_evidence" };
      const seen = new Set<string>();
      let offset = 0;
      for (;;) {
        const response = await service.post({ ...basis, offset });
        const raw = await response.text();
        expect(response.status, raw).toBe(200);
        expect(Buffer.byteLength(raw)).toBeLessThan(128 * 1024);
        const page = JSON.parse(raw).data;
        expect(page.total).toBe(60);
        expect(page.records.length).toBeLessThanOrEqual(32);
        for (const record of page.records) {
          expect(seen.has(record.id)).toBe(false);
          seen.add(record.id);
          expect(record.complete).toBe(false);
          expect({ path: record.source_path, bytes: record.bytes, sha256: record.sha256 }).toEqual(originals.get(record.id));
        }
        if (page.next_offset === null) break;
        expect(page.next_offset).toBeGreaterThan(offset);
        offset = page.next_offset;
      }
      expect(seen.size).toBe(60);
      const later = await service.post({ ...basis, offset: 60 });
      const provenance = (await later.json() as any).data;
      expect(provenance.records).toEqual([]);
      expect(provenance.relationships.some((edge: any) => edge.relationship === "omos_plan_actions")).toBe(true);
      expect(provenance.relationships.every((edge: any) => edge.task === task.id && edge.from && edge.to)).toBe(true);
      // Even an unselected record must retain its canonical identity check.
      const changed = [...originals.values()][0];
      appendFileSync(join(tree, changed.path), " ");
      fossil("commit", "--nosync", "--no-warnings", "-m", "Corrupt an unselected fixture hash");
      const fresh = fossil("timeline", "ancestors", task.branch, "--limit", "1", "--format", "%H", "--quiet").split("\n")[0].trim();
      const rejected = await service.post({ ...basis, revision: fresh, offset: 10000 });
      expect(rejected.status).toBe(400);
      expect(await rejected.text()).toContain("InvalidWorkspaceJournal");
    } finally { service.child.kill(); await service.child.exited; }
  }, 180000);

  test("recovers an expired server review lease and retains evidence inspection without actor replay", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let phase: "initial" | "interrupt" | "resume" = "initial";
    let held = false;
    let release: (() => void) | undefined;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const m = model(f, () => ({ content: "An answer with retained inspection progress." }), async packet => {
      if (phase === "initial") return { name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["invented"], note: "Fixture retains candidate" }] } };
      if (phase === "interrupt") {
        const candidate = packet.evidence.find((record: any) => record.kind === "candidate");
        if (!packet.currentInspections.some((page: any) => page.id === candidate.id)) return { name: "omos_review_evidence", args: { action: "read", id: candidate.id } };
        held = true;
        await gate;
      }
      return "met";
    });
    expect((await f.run(["ask", "Give a short informational answer", "--json"])).code).toBe(1);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const actors = m.counts().actors;
    phase = "interrupt";
    let service = await startWorkspaceService(f, true);
    let jobId = "";
    let basis: any;
    try {
      const bootstrap = await (await fetch(`${service.url}/v1/definition`, { headers: service.headers })).json() as any;
      basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: bootstrap.definition.basis.definition_hash, revision: bootstrap.revision };
      const directory = await (await service.post({ ...basis, action: "query", entity: "omos_task" })).json() as any;
      const queued = await (await service.post({ ...basis, revision: directory.data.records.find((row: any) => row.id === task.id).revision, action: "queue_review", task: task.id })).json() as any;
      jobId = queued.data.id;
      const deadline = Date.now() + 15000;
      while (!held && Date.now() < deadline) await Bun.sleep(50);
      expect(held).toBe(true);
      service.child.kill("SIGKILL");
      await service.child.exited;
      const tree = join(f.home, "expired-review-lease");
      mkdirSync(tree);
      const fossil = (...args: string[]) => {
        const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
        expect(result.status, result.stderr).toBe(0);
      };
      fossil("open", "--nosync", join(f.cwd, "omos.fossil"), task.branch);
      const path = join(tree, "jobs", `${jobId}.json`);
      const job = JSON.parse(readFileSync(path, "utf8"));
      expect(job.generation).toBe(1);
      // Advance only the fixture's lease clock; no original effects are replayed.
      job.lease_expires_ms = 0;
      writeFileSync(path, JSON.stringify(job));
      fossil("commit", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Expire fixture worker lease");
      phase = "resume";
      release!();
      service = await startWorkspaceService(f, true);
      let result: any;
      const resumedDeadline = Date.now() + 30000;
      while (Date.now() < resumedDeadline) {
        const response = await service.post({ ...basis, action: "job", task: task.id, job: jobId });
        if (response.status === 409) continue;
        expect(response.status, await response.clone().text()).toBe(200);
        result = (await response.json() as any).data;
        if (["published", "failed", "pending", "changes_required"].includes(result.state)) break;
        await Bun.sleep(100);
      }
      expect(result).toMatchObject({ state: "published", generation: 2, review_attempts: 2 });
      expect(m.packets.at(-1).previousInspections.length).toBeGreaterThan(0);
      expect(m.counts().actors).toBe(actors);
    } finally {
      release!();
      service.child.kill();
      await service.child.exited;
    }
  }, 90000);

  test("retains completed command evidence under its original contract when an amendment commits during execution", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const target = join(f.cwd, "completed-effect.txt");
    const clarification = "Retain the completed effect and wait for the additional requested outcome.";
    let taskId = "";
    let amendments = 0;
    const updates = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() {
      amendments++;
      commitFixtureAmendment(f, taskId, clarification);
      return new Response("Amendment saved");
    } });
    const inference = model(f, (_body, count) => {
      if (count !== 1) return { content: "The existing effect is retained while the amended work remains pending." };
      const binding = JSON.parse(readFileSync(join(f.home, ".fx/omos-workspace.json"), "utf8"));
      const cache = join(f.home, ".fx/fossil", createHash("sha256").update(binding.repository).digest("hex"), "tasks");
      taskId = readdirSync(cache).find((name: string) => name.endsWith(".json"))!.slice(0, -5);
      return { tool_calls: [{ index: 0, id: "completed-shell", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `printf x >> '${target}' && curl --fail --silent http://127.0.0.1:${updates.port}/amend`, timeout_ms: 15000 } }) } }] };
    }, () => "blocked");
    try {
      const result = await f.run(["ask", "Record the local command outcome and keep the task open", "--json"]);
      expect(result.code, result.stderr).toBe(1);
      expect(amendments).toBe(1);
      expect(readFileSync(target, "utf8")).toBe("x");
      const retained = JSON.parse(f.fossil("cat", `tasks/${taskId}.json`, "-r", `task/${taskId}`));
      expect(retained.definition.version).toBe(2);
      expect(retained.amendments).toContain(clarification);
      const history = f.fossil("ls", "-r", `task/${taskId}`).split("\n").filter((path: string) => path.startsWith(`history/${taskId}/`));
      const records = history.map((path: string) => JSON.parse(f.fossil("cat", path.trim(), "-r", `task/${taskId}`)));
      const executed = records.filter((row: any) => row.kind === "tool_evidence");
      expect(executed.some((row: any) => row.contract_version === 1 && row.value.some((item: any) => item.tool === "shell" && item.status === "success"))).toBe(true);
      expect(records.some((row: any) => row.kind === "command_receipt" && row.contract_version === 1)).toBe(true);
      expect(executed.filter((row: any) => row.contract_version === 2)).toHaveLength(0);
      expect(f.fossil("ls", "-r", "trunk")).not.toContain(`tasks/${taskId}.json`);
      expect(inference.counts().actors).toBeLessThanOrEqual(2);
    } finally { updates.stop(true); }
  }, 90000);

  test("rejects an outgoing actor action after a user amendment commits before its cache update", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const target = join(f.cwd, "must-not-execute.txt");
    const clarification = "Pause this task until the amended request is planned.";
    let taskId = "";
    model(f, () => {
      const binding = JSON.parse(readFileSync(join(f.home, ".fx/omos-workspace.json"), "utf8"));
      const cache = join(f.home, ".fx/fossil", createHash("sha256").update(binding.repository).digest("hex"), "tasks");
      taskId = readdirSync(cache).find((name: string) => name.endsWith(".json"))!.slice(0, -5);
      commitFixtureAmendment(f, taskId, clarification);
      return { tool_calls: [{ index: 0, id: "stale-shell", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `printf 'unexpected effect' > '${target}'`, timeout_ms: 1000 } }) } }] };
    });
    const result = await f.run(["ask", "Wait for my next instruction", "--json"]);
    expect(result.code, result.stderr).toBe(1);
    expect(result.stderr + result.stdout).toContain("StaleWorkContract");
    expect(existsSync(target)).toBe(false);
    const retained = JSON.parse(f.fossil("cat", `tasks/${taskId}.json`, "-r", `task/${taskId}`));
    expect(retained.definition.version).toBe(2);
    expect(retained.amendments).toContain(clarification);
    const history = f.fossil("ls", "-r", `task/${taskId}`).split("\n").filter((path: string) => path.startsWith(`history/${taskId}/`));
    for (const path of history) {
      const row = JSON.parse(f.fossil("cat", path.trim(), "-r", `task/${taskId}`));
      expect(row.kind).not.toBe("action_intent");
    }
  }, 90000);

  test("retains a committed user amendment when assessment finishes against an older cached contract", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let amended = false;
    let taskId = "";
    const clarification = "Also include the additional requested outcome.";
    model(f, () => ({ content: "The initial informational answer is retained." }), packet => {
      if (amended) return "blocked";
      amended = true;
      taskId = packet.contract.id;
      commitFixtureAmendment(f, taskId, clarification);
      // Return the assessment for the older packet while leaving its cache
      // untouched, as if the other runtime died after committing the amendment.
      return "met";
    });
    const result = await f.run(["ask", "Give the initial informational answer", "--json"]);
    expect(result.code, result.stderr).toBe(1);
    expect(amended).toBe(true);
    const retained = JSON.parse(f.fossil("cat", `tasks/${taskId}.json`, "-r", `task/${taskId}`));
    expect(retained.definition.version).toBe(2);
    expect(retained.amendments).toContain(clarification);
    expect(f.fossil("ls", "-r", "trunk")).not.toContain(`tasks/${taskId}.json`);
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((task: any) => task.id === taskId).state).not.toBe("accepted");
  }, 120000);

  test("discovers a durably queued review after its local index update is interrupted", async () => {
    const f = fixture();
    let permit = false;
    const inference = model(f, () => ({ content: "The retained answer is available for server verification." }), packet => permit ? "met" : {
      name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["unseen-fixture"], note: "Retain this informational candidate" }] },
    });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    expect((await f.run(["ask", "Give the informational answer", "--json"])).code).toBe(1);
    const snapshot = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const task = snapshot.tasks[0];
    const actors = inference.counts().actors;
    permit = true;
    const service = await startWorkspaceService(f, true, { FX_E2E_FOSSIL_FAULT: "review-job-committed" });
    try {
      const bootstrap = await (await fetch(service.url + "/v1/definition", { headers: service.headers })).json() as any;
      const basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: bootstrap.definition.basis.definition_hash, revision: bootstrap.revision };
      const directory = (await (await service.post({ ...basis, action: "query", entity: "omos_task" })).json() as any).data;
      const queued = await service.post({ ...basis, action: "queue_review", task: task.id, revision: directory.records.find((row: any) => row.id === task.id).revision });
      expect(queued.status).toBe(400);
      expect(await queued.text()).toContain("WorkspaceInjectedFailure");
      const canonical = JSON.parse(f.fossil("cat", `tasks/${task.id}.json`, "-r", task.branch));
      expect(canonical.review_job).toHaveLength(64);
      let result: any;
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const response = await service.post({ ...basis, action: "job", task: task.id, job: canonical.review_job });
        if (response.status === 409) { await Bun.sleep(25); continue; }
        expect(response.status, await response.clone().text()).toBe(200);
        result = (await response.json() as any).data;
        if (["published", "failed", "changes_required", "blocked", "pending"].includes(result.state)) break;
        await Bun.sleep(50);
      }
      expect(result, JSON.stringify(result)).toMatchObject({ state: "published", generation: 1 });
      expect(inference.counts().actors).toBe(actors);
      const marker = join(f.home, ".fx/fossil", createHash("sha256").update(snapshot.repository).digest("hex"), "review-selections", `${task.id}.json`);
      expect(existsSync(marker)).toBe(false);
    } finally { service.child.kill(); await service.child.exited; }
  }, 90000);

  test("resumes signed bounded uploads from Fossil and checkpoints only a complete verified file", async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("Upload verification cannot replay actor work"); });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "upload-operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "upload-team", actor: "uploader", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "submit", "status", "read"], expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    expect(boot.features).toMatchObject({ chunked_upload: true, max_upload_chunk_bytes: 131072, max_request_bytes: 1048576, max_object_bytes: 8388608 });
    const issuer = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(boot.issuer, "hex")]), format: "der", type: "spki" });
    let useNativeClient = false;
    const send = async (action: string, params: object = {}, status = 200, operation = crypto.randomUUID()) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "uploader", grant: "upload-team", operation, expires_ms: Date.now() + 120000, action, ...params });
      const raw = JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") });
      expect(Buffer.byteLength(raw)).toBeLessThan(1048576);
      let envelope: any;
      if (useNativeClient) {
        useNativeClient = false;
        const file = join(f.home, "signed-upload-part.json"); writeFileSync(file, raw);
        const result = await f.run(["fossil", "remote", service.url, file, "--json"]);
        expect(result.code, result.stderr).toBe(0);
        envelope = JSON.parse(result.stdout).model_data;
      } else {
        const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json" }, body: raw });
        envelope = await response.json();
        expect(response.status, JSON.stringify(envelope)).toBe(status);
      }
      if (status !== 200) return envelope;
      expect(verify(null, Buffer.from(envelope.payload), issuer, Buffer.from(envelope.signature, "hex"))).toBe(true);
      const claims = JSON.parse(envelope.payload);
      expect(claims).toMatchObject({ actor: "uploader", grant: "upload-team", operation, action, request_hash: createHash("sha256").update(payload).digest("hex") });
      return claims.result;
    };
    try {
      const view = await send("create_view", { revision: boot.revision, objective: "Save the complete portable binary document" });
      const bytes = Buffer.alloc(1048576 + 57);
      for (let index = 0; index < bytes.length; index++) bytes[index] = index % 251;
      const upload = { sha256: createHash("sha256").update(bytes).digest("hex"), bytes: bytes.length };
      const basis = { view: view.view, revision: view.revision, path: "documents/team/portable.bin", encoding: "base64", upload, executable: false };
      const chunk = (offset: number) => ({ ...basis, offset, content: bytes.subarray(offset, offset + 131072).toString("base64") });
      expect(await send("checkpoint", basis, 400)).toMatchObject({ error: "CompanyUploadIncomplete" });
      useNativeClient = true;
      const first = await send("checkpoint", chunk(0));
      expect(first).toMatchObject({ state: "uploading", revision: view.revision, offset: 0, bytes: 131072 });
      expect(await send("checkpoint", chunk(0))).toEqual(first);
      await send("checkpoint", chunk(131072));
      const pendingTask = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
      expect(f.fossil("ls", "-r", pendingTask.branch)).not.toContain(basis.path);
      // Discard the host's replaceable task indexes and scratch checkouts.
      // The signed pieces, identity and journals remain in Fossil.
      service.child.kill(); await service.child.exited;
      const snapshot = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
      const cache = join(f.home, ".fx/fossil", createHash("sha256").update(snapshot.repository).digest("hex"));
      rmSync(join(cache, "tasks"), { recursive: true });
      rmSync(join(cache, "checkouts"), { recursive: true });
      service = await startWorkspaceService(f, true);
      expect(await send("checkpoint", chunk(0))).toEqual(first);
      const corrupt = Buffer.from(bytes.subarray(0, 131072)); corrupt[0] ^= 255;
      expect(await send("checkpoint", { ...chunk(0), content: corrupt.toString("base64") }, 400)).toMatchObject({ error: "CompanyUploadConflict" });
      expect(await send("checkpoint", { ...chunk(0), path: "documents/private/escape.bin" }, 403)).toMatchObject({ error: "CompanyAccessDenied" });
      expect(await send("checkpoint", { ...chunk(0), offset: 1 }, 400)).toMatchObject({ error: "InvalidCompanyUpload" });
      expect(await send("checkpoint", { ...basis, upload: { ...upload, bytes: 8388609 } }, 400)).toHaveProperty("error");
      for (let offset = 262144; offset < bytes.length; offset += 131072) await send("checkpoint", chunk(offset));
      const retainedTask = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
      expect(f.fossil("ls", "-r", retainedTask.branch)).not.toContain(basis.path);
      // Parts cannot be reused by another view, even with the same grant.
      const other = await send("create_view", { revision: boot.revision, objective: "Keep a separate isolated view" });
      expect(await send("checkpoint", { ...basis, view: other.view, revision: other.revision }, 400)).toMatchObject({ error: "CompanyUploadIncomplete" });
      const finished = await send("checkpoint", basis);
      expect(finished).toMatchObject({ state: "checkpointed", view: view.view });
      expect(finished.revision).not.toBe(view.revision);
      const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
      const original = spawnSync(existsSync(helper) ? helper : "fossil", ["cat", basis.path, "-r", finished.revision, "-R", join(f.cwd, "omos.fossil")], { encoding: "buffer" });
      expect(original.status).toBe(0);
      expect(original.stdout.equals(bytes)).toBe(true);
      expect(f.fossil("ls", "-r", "trunk")).not.toContain(basis.path);
      const submitted = await send("submit", { view: view.view, revision: finished.revision, candidate: "Saved the complete hash-verified portable binary document." });
      let result: any;
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const response = await send("status", { view: view.view });
        result = response;
        if (["published", "failed", "changes_required", "blocked", "pending"].includes(response.job?.state)) break;
        await Bun.sleep(100);
      }
      expect(result.job, JSON.stringify(result)).toMatchObject({ id: submitted.job, state: "published" });
      expect(f.fossil("ls", "-r", "trunk")).toContain(basis.path);
      expect(inference.counts().actors).toBe(0);
      const readonlyOperation = crypto.randomUUID();
      expect(await send("checkpoint", { ...chunk(0), revision: result.revision }, 400, readonlyOperation)).toMatchObject({ error: "TaskIsReadOnly" });
      expect(await send("status", { outcome: readonlyOperation })).toMatchObject({ state: "failed", failure: "TaskIsReadOnly" });
      const small = Buffer.from("A separately pinned file");
      const wrong = { view: other.view, revision: other.revision, path: "documents/team/wrong.bin", encoding: "base64", upload: { sha256: "0".repeat(64), bytes: small.length } };
      await send("checkpoint", { ...wrong, content: small.toString("base64") });
      expect(await send("checkpoint", wrong, 400)).toMatchObject({ error: "CompanyUploadHashMismatch" });
      const stale = { ...wrong, path: "documents/team/stale.bin", upload: { sha256: createHash("sha256").update(small).digest("hex"), bytes: small.length } };
      await send("checkpoint", { ...stale, content: small.toString("base64") });
      await send("checkpoint", { view: other.view, revision: other.revision, path: "documents/team/advanced.md", content: "A later checkpoint advances this candidate" });
      expect(await send("checkpoint", stale, 409)).toMatchObject({ error: "WorkspaceRevisionChanged" });
      const authority = await admin({ action: "status" });
      await admin({ action: "revoke", revision: authority.revision, id: "upload-team" });
      expect(await send("checkpoint", chunk(0), 403)).toMatchObject({ error: "CompanyAccessRevoked" });
    } finally { service.child.kill(); await service.child.exited; }
  }, 180000);

  test("restores canonical company authority before claiming review after cache corruption and revocation", async () => {
    const f = fixture();
    const inference = model(f, () => { throw Error("Company verification cannot replay an actor"); });
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const admin = async (body: object) => {
      const file = join(f.home, "operator.json");
      writeFileSync(file, JSON.stringify({ version: "omos.company-admin/v1", ...body }));
      const result = await f.run(["fossil", "company", file, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      return JSON.parse(result.stdout).model_data;
    };
    const initialized = await admin({ action: "initialize" });
    const key = generateKeyPairSync("ed25519");
    await admin({ action: "grant", revision: initialized.revision, grant: { id: "approval", actor: "worker", public_key: key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("hex"), paths: ["documents/team/"], actions: ["create_view", "checkpoint", "submit", "status"], human_approval: true, expires_ms: Date.now() + 3600000 } });
    let service = await startWorkspaceService(f, true);
    const boot = await (await fetch(service.url + "/v1/company")).json() as any;
    const send = async (action: string, params: object = {}) => {
      const payload = JSON.stringify({ version: "omos.company/v1", workspace: boot.workspace, actor: "worker", grant: "approval", operation: crypto.randomUUID(), expires_ms: Date.now() + 120000, action, ...params });
      const response = await fetch(service.url + "/v1/company", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key.privateKey).toString("hex") }) });
      const body = await response.json() as any;
      expect(response.status, JSON.stringify(body)).toBe(200);
      return JSON.parse(body.payload).result;
    };
    try {
      const view = await send("create_view", { revision: boot.revision, objective: "Retain the company report pending an authorized decision" });
      const saved = await send("checkpoint", { view: view.view, revision: view.revision, path: "documents/team/report.md", content: "Retained report" });
      const submitted = await send("submit", { view: view.view, revision: saved.revision, candidate: "Saved the retained company report." });
      let status: any;
      const blockedDeadline = Date.now() + 30000;
      while (Date.now() < blockedDeadline) {
        status = await send("status", { view: view.view });
        if (status.job?.state === "blocked") break;
        await Bun.sleep(50);
      }
      expect(status.job?.state).toBe("blocked");
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
      service.child.kill(); await service.child.exited;
      const repository = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).repository;
      const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((task: any) => task.id === view.contract.id);
      // A trusted fixture emulates a durable queued retry left by an old worker.
      // The task's canonical binding remains intact throughout this setup.
      const tree = join(f.home, "review-retry"); mkdirSync(tree);
      const helper = join(import.meta.dir, "../../zig-out/libexec/fossil");
      const command = (...args: string[]) => {
        const result = spawnSync(existsSync(helper) ? helper : "fossil", ["--user", "omos", ...args], { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, XDG_CONFIG_HOME: f.home, USER: "fixture", LC_ALL: "C" }, encoding: "utf8" });
        expect(result.status, result.stderr).toBe(0);
      };
      command("open", "--nosync", repository, task.branch);
      const jobPath = join(tree, "jobs", `${submitted.job}.json`);
      const retry = JSON.parse(readFileSync(jobPath, "utf8"));
      retry.state = "queued"; retry.lease_expires_ms = 0;
      writeFileSync(jobPath, JSON.stringify(retry));
      command("commit", "--nosign", "--nosync", "-m", "Retain a queued review retry in the fixture");
      command("close");
      const cache = join(f.home, ".fx/fossil", createHash("sha256").update(repository).digest("hex"), "tasks", `${task.id}.json`);
      writeFileSync(cache, JSON.stringify({ ...task, authority: null }));
      const authority = await admin({ action: "status" });
      await admin({ action: "revoke", revision: authority.revision, id: "approval" });
      service = await startWorkspaceService(f, true);
      const definition = await (await fetch(service.url + "/v1/definition", { headers: service.headers })).json() as any;
      const basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: definition.definition.basis.definition_hash, revision: definition.revision };
      let result: any;
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const response = await service.post({ ...basis, action: "job", task: task.id, job: submitted.job });
        if (response.status === 409) { await Bun.sleep(25); continue; }
        expect(response.status, await response.clone().text()).toBe(200);
        result = (await response.json() as any).data;
        if (["failed", "published", "blocked", "changes_required"].includes(result.state)) break;
        await Bun.sleep(50);
      }
      expect(result, JSON.stringify(result)).toMatchObject({ state: "failed", reason: "CompanyAccessRevoked" });
      expect(inference.counts()).toEqual({ actors: 0, assessments: 0 });
      expect(JSON.parse(f.fossil("cat", `tasks/${task.id}.json`, "-r", task.branch)).authority).toEqual(task.authority);
      expect(f.fossil("ls", "-r", "trunk")).not.toContain("documents/team/report.md");
    } finally { service.child.kill(); await service.child.exited; }
  }, 120000);

  test("upgrades future contracts with a verified backup while preserving active task bases", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data.declaration;
    declaration.spec.operations = declaration.spec.operations.filter((o: any) => !o.id.startsWith("omos_"));
    declaration.spec.semantic.entityTypes = declaration.spec.semantic.entityTypes.filter((e: any) => !["omos_event", "omos_review_job"].includes(e.id));
    const tree = join(f.home, "legacy-contracts");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
    writeFileSync(join(tree, "omniform/company.json"), JSON.stringify(declaration));
    writeFileSync(join(tree, "execution/omos.json"), JSON.stringify({ version: "omos.execution/v1", defaults: { progress_interval: 4, stalled_checks: 3, max_actor_steps: 100 } }));
    fossil("commit", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain legacy contract fixture");
    model(f, () => ({ content: "Retained legacy task." }), () => "blocked");
    expect((await f.run(["ask", "Keep this task open", "--json"])).code).toBe(1);
    const before = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(before.model_basis.execution.review.attempt_timeout_ms).toBe(60000);
    const upgraded = await f.run(["fossil", "migrate", "--contracts", "--json"], {}, 90000);
    expect(upgraded.code, upgraded.stderr).toBe(0);
    const after = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(after.model_basis).toEqual(before.model_basis);
    expect(after.definition).toEqual(before.definition);
    const future = JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data;
    expect(future.declaration.spec.operations.some((o: any) => o.id === "omos_record_evidence")).toBe(true);
    expect(future.basis.execution.review.attempt_timeout_ms).toBe(300000);
    const backups = readdirSync(f.cwd).filter(path => path.includes(".pre-contracts-"));
    expect(backups).toHaveLength(1);
    expect((await f.run(["fossil", "migrate", "--contracts", "--json"])).code).toBe(0);
    expect(readdirSync(f.cwd).filter(path => path.includes(".pre-contracts-"))).toEqual(backups);
  }, 120000);

  test("verifies a retained answer on the server without replaying actor work", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let permit = false;
    const m = model(f, () => ({ content: "The retained answer can be reviewed independently." }), packet => permit ? "met" : {
      name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["invented"], note: "Fixture forces retained review failure" }] },
    });
    const first = await f.run(["ask", "Give a short informational answer", "--json"]);
    expect(first.code).toBe(1);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const actorCount = m.counts().actors;
    const repository = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout).repository;
    const cachedTask = join(f.home, ".fx/fossil", createHash("sha256").update(repository).digest("hex"), "tasks", `${task.id}.json`);
    const stale = structuredClone(task);
    stale.definition.objective = "A cached objective must not replace the canonical request";
    stale.model_basis.capability = "unavailable-cache-capability";
    stale.authority = { actor: "cache-only", grant: "cache-only" };
    writeFileSync(cachedTask, JSON.stringify(stale));
    permit = true;
    const service = await startWorkspaceService(f, true);
    try {
      const bootstrap = await (await fetch(`${service.url}/v1/definition`, { headers: service.headers })).json() as any;
      const basis = { version: "omos.workspace-api/v1", workspace: service.ready.workspace, definition_hash: bootstrap.definition.basis.definition_hash, revision: bootstrap.revision };
      const directoryResponse = await service.post({ ...basis, action: "query", entity: "omos_task" });
      expect(directoryResponse.status, await directoryResponse.clone().text()).toBe(200);
      const directory = await directoryResponse.json() as any;
      const selected = directory.data.records.find((row: any) => row.id === task.id);
      const queuedResponse = await service.post({ ...basis, revision: selected.revision, action: "queue_review", task: task.id });
      expect(queuedResponse.status, await queuedResponse.clone().text()).toBe(200);
      const queued = await queuedResponse.json() as any;
      expect(queued.data.state).toBe("queued");
      let completed: any;
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const result = await service.post({ ...basis, action: "job", task: task.id, job: queued.data.id });
        if (result.status === 409) continue;
        expect(result.status, await result.clone().text()).toBe(200);
        completed = (await result.json() as any).data;
        if (["published", "failed", "changes_required", "blocked", "pending"].includes(completed.state)) break;
        await Bun.sleep(100);
      }
      expect(completed, existsSync(f.env.FX_TRACE_LOG) ? readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-4000) : "").toMatchObject({ state: "published", generation: 1 });
      expect(m.counts().actors).toBe(actorCount);
      expect(m.packets.at(-1).contract.objective).toBe(task.definition.objective);
      const repaired = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
      expect(repaired.state).toBe("accepted");
      expect(repaired.authority).toBeNull();
      expect(repaired.definition).toEqual(task.definition);
      expect(f.fossil("ls", "-r", "trunk")).toContain(`jobs/${queued.data.id}.json`);
      permit = false;
      expect((await f.run(["ask", "Give another short informational answer", "--json"])).code).toBe(1);
      const secondTask = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks.find((item: any) => item.id !== task.id);
      permit = true;
      const nextBootstrap = await (await fetch(`${service.url}/v1/definition`, { headers: service.headers })).json() as any;
      const nextBasis = { ...basis, revision: nextBootstrap.revision };
      const nextDirectory = await (await service.post({ ...nextBasis, action: "query", entity: "omos_task" })).json() as any;
      const nextQueued = await (await service.post({ ...nextBasis, revision: nextDirectory.data.records.find((row: any) => row.id === secondTask.id).revision, action: "queue_review", task: secondTask.id })).json() as any;
      let nextResult: any;
      const nextDeadline = Date.now() + 30000;
      while (Date.now() < nextDeadline) {
        const response = await service.post({ ...nextBasis, action: "job", task: secondTask.id, job: nextQueued.data.id });
        if (response.status === 409) continue;
        expect(response.status, await response.clone().text()).toBe(200);
        nextResult = (await response.json() as any).data;
        if (["published", "failed", "pending", "changes_required"].includes(nextResult.state)) break;
        await Bun.sleep(100);
      }
      expect(nextResult).toMatchObject({ state: "published", generation: 1 });
      expect(m.counts().actors).toBe(actorCount + 1);
    } finally {
      service.child.kill();
      await service.child.exited;
    }
  }, 60000);

  test("pauses exhausted verification without replaying the actor and resumes the retained answer", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let permit = false;
    const m = model(f, () => ({ content: "Retained answer awaiting verification." }), () => permit ? "met" : {
      name: "omos_review_evidence", args: { action: "query", kind: "candidate" },
    });
    const first = await f.run(["ask", "Give a short informational answer", "--json"]);
    expect(first.code).toBe(1);
    expect(first.stderr, first.stdout).toContain("Verification is pending");
    expect(first.stderr).not.toContain("request failed: ContractReviewPending");
    const session = JSON.parse(first.stdout).session_id;
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(task.state).toBe("paused");
    expect(m.counts().actors).toBe(1);
    expect(m.counts().assessments).toBeLessThanOrEqual(16);
    permit = true;
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(resumed.stdout).toContain("Retained answer awaiting verification.");
    expect(m.counts().actors).toBe(1);
  }, 60000);

  test("queries evidence by producing action and audits its pinned contracts", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => count === 1 ? writeMemory("Contract-linked evidence") : { content: "Saved the preference." }, packet => {
      if (!packet.currentInspections.some((page: any) => page.scope === "pinned_review_manifest")) return {
        name: "omos_review_evidence", args: { action: "query", tool: "fossil_workspace", status: "success" },
      };
      const records = packet.currentInspections.flatMap((page: any) => page.evidence ?? []);
      const record = records.find((item: any) => item.raw_call_id === "save-memory");
      expect(record).toBeDefined();
      return { name: "omos_contract_assessment", args: {
        contractId: packet.contract.id, version: packet.contract.version,
        obligations: packet.contract.obligations.map((o: any) => ({ id: o.id, status: "met", evidence: [record.id], note: "The host recorded the requested write and its producing action." })),
      } };
    });
    const result = await f.run(["ask", "Save the preference", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(m.counts().actors).toBe(2);
    const audit = await f.run(["fossil", "audit", "--json"]);
    expect(audit.code, audit.stderr).toBe(0);
    expect(JSON.parse(audit.stdout).model_data).toMatchObject({ valid: true, legacy_tasks: 0 });
    expect(JSON.parse(audit.stdout).model_data.checked_records).toBeGreaterThan(0);
    const status = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
    const branch = status.tasks[0].branch;
    const history = f.fossil("ls", "-r", branch).split("\n").filter(path => path.startsWith(`history/${status.tasks[0].id}/`));
    const action = history.map(path => JSON.parse(f.fossil("cat", path, "-r", branch))).find(row => row.kind === "action_intent");
    expect(action.definition_hash).toBe(status.tasks[0].model_basis.definition_hash);
  }, 60000);

  test("serves authenticated workspace queries and rejects cross-workspace and stale contracts", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const token = "isolated-workspace-service-token-for-fixtures";
    const child = Bun.spawn([join(import.meta.dir, "../../zig-out/bin/fx"), "fossil", "serve", "0", "--json"], {
      cwd: f.cwd, env: { ...process.env, ...f.env, OMOS_WORKSPACE_TOKEN: token }, stdout: "pipe", stderr: "pipe",
    });
    try {
      const reader = child.stdout.getReader();
      let output = "";
      const deadline = Date.now() + 15000;
      while (!output.includes("\n")) {
        const chunk = await Promise.race([reader.read(), Bun.sleep(Math.max(1, deadline - Date.now())).then(() => { throw new Error("Workspace service did not become ready"); })]);
        if (chunk.done) throw new Error(`Service exited: ${await new Response(child.stderr).text()}`);
        output += new TextDecoder().decode(chunk.value);
      }
      reader.releaseLock();
      const ready = JSON.parse(output.trim().split("\n")[0]);
      const url = `http://127.0.0.1:${ready.port}`;
      expect((await fetch(`${url}/v1/definition`)).status).toBe(401);
      const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
      const bootstrap = await (await fetch(`${url}/v1/definition`, { headers })).json() as any;
      const request = { version: "omos.workspace-api/v1", workspace: ready.workspace, definition_hash: bootstrap.definition.basis.definition_hash, revision: bootstrap.revision, action: "query" };
      const post = (body: object) => fetch(`${url}/v1/workspace`, { method: "POST", headers, body: JSON.stringify(body) });
      const queried = await post(request);
      expect(queried.status, await queried.clone().text()).toBe(200);
      expect((await queried.json() as any).workspace).toBe(ready.workspace);
      expect((await post({ ...request, workspace: "another-workspace" })).status).toBe(403);
      expect((await post({ ...request, definition_hash: "stale" })).status).toBe(409);
      expect((await post({ ...request, revision: "stale" })).status).toBe(409);
      expect((await post({ ...request, action: "record" })).status).toBe(403);
      expect((await fetch(`${url}/v1/definition`, { headers: { ...headers, origin: "https://example.com" } })).status).toBe(401);
      const client = fixture();
      const remote = await client.run(["fossil", "remote", url, "--json"], { OMOS_WORKSPACE_TOKEN: token });
      expect(remote.code, remote.stderr).toBe(0);
      expect(JSON.parse(remote.stdout).model_data.workspace).toBe(ready.workspace);
      expect(existsSync(join(client.cwd, "omos.fossil"))).toBe(false);
    } catch (error) {
      child.kill();
      await child.exited;
      throw new Error(`${error instanceof Error ? error.stack : error}\n${await new Response(child.stderr).text()}\n${existsSync(f.env.FX_TRACE_LOG) ? readFileSync(f.env.FX_TRACE_LOG, "utf8").slice(-8000) : ""}`);
    } finally {
      child.kill();
      await child.exited;
    }
  }, 30000);

  test("shares pinned OmniForm validation with the vendored validator and rejects unsupported profile policy", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const standard = join(import.meta.dir, "../../src/core/workspace/standard");
    const seed = JSON.parse(readFileSync(join(standard, "omos.json"), "utf8"));
    const validatorSource = readFileSync(join(standard, "validate.js"), "utf8")
      .replace(/import schema from .*?;/, `const schema = ${readFileSync(join(standard, "omniform.schema.json"), "utf8")};`)
      .replace('"ajv/dist/2020.js"', JSON.stringify(pathToFileURL(Bun.resolveSync("ajv/dist/2020.js", import.meta.dir)).href));
    const validatorPath = join(f.home, "omniform-validator.mjs");
    writeFileSync(validatorPath, validatorSource);
    const upstream = await import(pathToFileURL(validatorPath).href);
    const semanticSource = new Bun.Transpiler({ loader: "ts" }).transformSync(readFileSync(join(standard, "semantic.ts"), "utf8"))
      .replace('"zod"', JSON.stringify(pathToFileURL(Bun.resolveSync("zod", import.meta.dir)).href));
    const semanticPath = join(f.home, "omniform-semantic.mjs");
    writeFileSync(semanticPath, semanticSource);
    const sharedSemantic = await import(pathToFileURL(semanticPath).href);
    const variants: Array<{ change: (v: any) => void; valid: boolean; upstreamValid?: boolean }> = [
      { change() {}, valid: true },
      { change(v) { v.spec.operations[0].input.properties.request = { type: ["string", "null"] }; }, valid: true },
      { change(v) { v.apiVersion = "wrong/v1"; }, valid: false },
      { change(v) { v.spec.unknown = true; }, valid: false },
      { change(v) { v.metadata.id = "9_invalid"; }, valid: false },
      { change(v) { v.spec.capabilities.push(v.spec.capabilities[0]); }, valid: false },
      { change(v) { v.spec.realisations[0].participants[0].resource = "missing"; }, valid: false },
      { change(v) { v.spec.operations[0].input.format = "executable"; }, valid: false, upstreamValid: true },
      { change(v) { v.spec.operations[0].approval = "required"; }, valid: false, upstreamValid: true },
      { change(v) { delete v.spec.semantic.version; }, valid: false },
      { change(v) { v.spec.semantic.search = { version: 1, ranking: { relevance: 1, precedent: 1, evidence: 1, recency: 1 } }; }, valid: false },
      { change(v) { v.spec.semantic.relationships = [{ id: "self", from: "omos_task", to: "omos_task", kind: "containment" }]; }, valid: false },
      { change(v) { v.spec.semantic.migration = { version: "omniseedos.data-migration/v1", defaults: { omos_task: { objective: "default" } } }; }, valid: false, upstreamValid: true },
    ];
    for (const [index, variant] of variants.entries()) {
      const value = structuredClone(seed);
      variant.change(value);
      const base = structuredClone(value);
      delete base.spec.semantic;
      const structural = upstream.validateStructure(base);
      const semantic = structural.valid ? upstream.validateSemantics(base) : { valid: false };
      const semanticValid = sharedSemantic.validateSemantics(value.spec.semantic, value.spec.capabilities.map((c: any) => c.id)).length === 0;
      expect(structural.valid && semantic.valid && semanticValid, `upstream fixture ${index}`).toBe(variant.upstreamValid ?? variant.valid);
      const path = join(f.home, `declaration-${index}.json`);
      writeFileSync(path, JSON.stringify(value));
      const result = await f.run(["fossil", "definition", "validate", path, "--json"]);
      expect(result.code, result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).model_data.valid, `native fixture ${index}`).toBe(variant.valid);
    }
  }, 90000);

  test("activates additive proposals for future tasks and retains incompatible proposals inactive", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    model(f, () => ({ content: "Retained task" }), () => "blocked");
    expect((await f.run(["ask", "Keep this task open", "--json"])).code).toBe(1);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const before = JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data;
    const value = structuredClone(before.declaration);
    value.spec.semantic.entityTypes.push({ id: "company_note", fields: { text: "string" }, required: ["text"] });
    const path = join(f.home, "proposal.json");
    writeFileSync(path, JSON.stringify(value));
    const added = await f.run(["fossil", "definition", "propose", path, "--json"]);
    expect(added.code, added.stderr).toBe(0);
    expect(JSON.parse(added.stdout).model_data.state).toBe("activated");
    const pinned = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(pinned.model_basis).toEqual(task.model_basis);
    const after = JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data;
    expect(after.basis.definition_hash).not.toBe(before.basis.definition_hash);
    value.spec.semantic.entityTypes[0].fields.objective = "boolean";
    writeFileSync(path, JSON.stringify(value));
    const incompatible = await f.run(["fossil", "definition", "propose", path, "--json"]);
    expect(incompatible.code, incompatible.stderr).toBe(0);
    expect(JSON.parse(incompatible.stdout).model_data.state).toBe("inactive");
    expect(JSON.parse((await f.run(["fossil", "definition", "show", "--json"])).stdout).model_data.basis.definition_hash).toBe(after.basis.definition_hash);
    expect(f.fossil("ls", "-r", "trunk").split("\n").filter(path => path.startsWith("proposals/"))).toHaveLength(2);
    expect((await f.run(["fossil", "migrate"])).code).toBe(0);
  }, 120000);

  test("does not let a progress checkpoint cite a cached large preview as fully inspected evidence", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let checks = 0;
    const m = model(f, (_body, count) => count === 1 ? writeMemory("A long policy statement.\n".repeat(2000)) : {
      tool_calls: [{ index: 0, id: `inspect-${count}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: "workspace.json" }) } }],
    }, undefined, { progress: packet => {
      checks++;
      const large = packet.evidence.find((entry: any) => entry.kind === "tool" && entry.bytes > 2048);
      expect(large).toBeDefined();
      expect(large.complete).toBe(false);
      expect(large.arguments.length).toBeLessThanOrEqual(512);
      return { outcome: "continue_work", meaningful: true, evidence: [large.id], remaining: packet.context.contract.obligations.map((obligation: any) => obligation.id), note: "A preview alone cannot establish inspected progress." };
    } });
    const result = await f.run(["ask", "Save the policy and inspect the workspace for useful follow-up information", "--json"], {}, 90000);
    expect(result.code).toBe(1);
    expect(checks).toBe(1);
    expect(m.counts().actors).toBe(4);
    expect(m.counts().assessments).toBe(0);
    expect(f.fossil("ls", "-r", "trunk")).not.toContain("memory/preference.md");
  }, 120000);

  test("stops a repeated successful search after three stalled progress checks", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (body, count) => !body.tools?.length ? { content: "The search is unfinished. The repeated results are retained." } : {
      tool_calls: [{ index: 0, id: `search-${count}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: "workspace.json" }) } }],
    });
    const result = await f.run(["ask", "Inspect the workspace repeatedly until useful information is found", "--json"], {}, 180000);
    expect(result.code, result.stderr).toBe(1);
    expect(result.stderr).toContain("Task paused");
    expect(m.counts().actors).toBe(13);
    expect(m.counts().assessments).toBe(0);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(task.state).toBe("paused");
    expect(f.fossil("ls", "-r", "trunk")).not.toContain(`tasks/${task.id}`);
  }, 180000);

  test("reserves the last actor slot for a summary and resets the invocation budget on continue", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const seed = JSON.parse(readFileSync(join(import.meta.dir, "../../src/core/workspace/standard/omos.json"), "utf8"));
    const declaration = join(f.home, "same-definition.json");
    const execution = join(f.home, "execution.json");
    writeFileSync(declaration, JSON.stringify(seed));
    writeFileSync(execution, JSON.stringify({ defaults: { max_actor_steps: 3 } }));
    expect((await f.run(["fossil", "definition", "propose", declaration, "--execution", execution, "--json"])).code).toBe(0);
    const m = model(f, (body, count) => !body.tools?.length ? { content: "Two workspace inspections completed; further work remains." } : {
      tool_calls: [{ index: 0, id: `inspect-${count}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: "workspace.json" }) } }],
    });
    const first = await f.run(["ask", "Inspect this workspace until a useful result is found", "--json"], {}, 120000);
    expect(first.code, first.stderr).toBe(1);
    expect(first.stderr).toContain("actor-step budget");
    expect(m.counts().actors).toBe(3);
    const session = JSON.parse(first.stdout).session_id;
    const second = await f.run(["ask", "--resume-id", session, "continue", "--json"], {}, 120000);
    expect(second.code, second.stderr).toBe(1);
    expect(m.counts().actors).toBe(6);
    expect(m.counts().assessments).toBe(0);
  }, 180000);

  test("migrates a legacy workspace with a backup while retaining its task contract", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const tree = join(f.home, "legacy-checkout");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
    const manifest = JSON.parse(readFileSync(join(tree, "workspace.json"), "utf8"));
    manifest.format = 1;
    writeFileSync(join(tree, "workspace.json"), JSON.stringify(manifest));
    fossil("rm", "omniform/company.json", "execution/omos.json");
    fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Construct legacy fixture");
    model(f, () => ({ content: "Retain the original task" }), () => "blocked");
    expect((await f.run(["ask", "Retain the original task", "--json"])).code).toBe(1);
    const old = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(old.model_basis).toBeNull();
    const migrated = await f.run(["fossil", "migrate", "--json"], {}, 120000);
    expect(migrated.code, migrated.stderr).toBe(0);
    expect(readdirSync(f.cwd).filter(path => path.includes(".pre-omniform-") && path.endsWith(".fossil"))).toHaveLength(1);
    const saved = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(saved.definition).toEqual(old.definition);
    expect(saved.model_basis).toBeNull();
    expect((await f.run(["fossil", "migrate"])).code).toBe(0);
    expect(readdirSync(f.cwd).filter(path => path.includes(".pre-omniform-") && path.endsWith(".fossil"))).toHaveLength(1);
    expect((await f.run(["ask", "Start another task", "--json"])).code).toBe(1);
    const tasks = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks;
    expect(tasks.find((t: any) => t.id !== old.id).model_basis.definition_hash).toHaveLength(64);
  }, 150000);

  test("rejects coding validation after source changes during review and requires a current check", async () => {
    const f = fixture();
    writeFileSync(join(f.cwd, ".gitignore"), "omos.fossil\n");
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let changed = false;
    const m = model(f, (_body, count) => count === 1 || count === 2 || count === 4 ? {
      tool_calls: [{ index: 0, id: `code-${count}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: count === 1 ? "touch answer.txt" : "test -f answer.txt", timeout_ms: 10000 } }) } }],
    } : { content: "Created answer.txt and checked that it exists." }, () => {
      if (!changed) { writeFileSync(join(f.cwd, "answer.txt"), "A concurrent source edit"); changed = true; }
      return "met";
    }, { plan: { capability: "coding_task", summary: "Create and test a file", obligations: [], checks: ["test -f answer.txt"] } });
    const result = await f.run(["ask", "Implement answer.txt and test that it exists", "--json"], {}, 150000);
    expect(result.code, result.stderr + result.stdout).toBe(0);
    expect(m.counts()).toEqual({ actors: 5, assessments: 2 });
  }, 150000);

  test("does not execute a repeated invalid tool proposal", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => ({ tool_calls: [{ index: 0, id: `invalid-${count}`, type: "function", function: { name: "mcp_nonexistent_tool", arguments: "{}" } }] }));
    const result = await f.run(["ask", "Use the configured tools", "--json"]);
    expect(result.code).toBe(1);
    expect(m.counts().actors).toBe(2);
    expect(m.counts().assessments).toBe(0);
  }, 60000);

  test("verifies file manifests and rejects a byte mismatch", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const manifest = JSON.stringify({ files: [{ path: "memory/preference.md", bytes: 5, sha256: createHash("sha256").update("hello").digest("hex") }] });
    const m = model(f, (_body, count) => count === 1 ? writeMemory("hello") : count === 2 ? {
      tool_calls: [{ index: 0, id: "save-manifest", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "memory/manifest.json", content: manifest }) } }],
    } : count === 3 ? { tool_calls: [{ index: 0, id: "verify-files", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "verify_manifest", path: "memory/manifest.json" }) } }] }
      : { content: "The file matches the manifest." });
    const result = await f.run(["ask", "Save hello and verify it against the file manifest", "--json"], {}, 120000);
    expect(result.code, result.stderr).toBe(0);
    expect(m.packets.at(-1).evidence.find((e: any) => e.tool === "fossil_workspace" && e.arguments?.includes("verify_manifest")).content).toContain("verified");
    const bad = model(f, (_body, count) => count === 1 ? writeMemory("other") : count === 2 ? {
      tool_calls: [{ index: 0, id: "verify-mismatch", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "verify_manifest", path: "memory/manifest.json" }) } }],
    } : { content: "The changed bytes do not match." }, () => "blocked");
    expect((await f.run(["ask", "Replace hello with other and check the old manifest", "--json"])).code).toBe(1);
    expect(bad.packets.at(-1).evidence.find((e: any) => e.arguments?.includes("verify_manifest")).status).toBe("failure");
  }, 150000);

  test("discovers declared capabilities and validates custom records without granting host authority", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = JSON.parse(readFileSync(join(import.meta.dir, "../../src/core/workspace/standard/omos.json"), "utf8"));
    declaration.spec.semantic.entityTypes.push({ id: "company_note", fields: { text: "string" }, required: ["text"] });
    declaration.spec.capabilities.push({ ...structuredClone(declaration.spec.capabilities[0]), id: "cv_builder", name: "Custom CV builder", realisations: ["cv_builder_native"] });
    declaration.spec.realisations.push({ ...structuredClone(declaration.spec.realisations[0]), id: "cv_builder_native", capability: "cv_builder" });
    declaration.spec.operations.push({ ...structuredClone(declaration.spec.operations[0]), id: "build_cv", capability: "cv_builder" });
    const path = join(f.home, "declaration.json");
    writeFileSync(path, JSON.stringify(declaration));
    expect((await f.run(["fossil", "definition", "propose", path, "--json"])).code).toBe(0);
    const inputs = [
      { name: "capability_search", args: { query: "cv_builder" } },
      { name: "fossil_workspace", args: { action: "record", entity: "company_note", content: JSON.stringify({ text: "Retained company fact" }) } },
      { name: "fossil_workspace", args: { action: "query", entity: "company_note" } },
      { name: "fossil_workspace", args: { action: "record", entity: "omos_evidence", content: JSON.stringify({ task: "forged", records: [] }) } },
    ];
    const m = model(f, (_body, count) => count <= inputs.length ? {
      tool_calls: [{ index: 0, id: `record-${count}`, type: "function", function: { name: inputs[count - 1].name, arguments: JSON.stringify(inputs[count - 1].args) } }],
    } : { content: "The typed note was saved; host evidence remains protected." });
    const result = await f.run(["ask", "Discover the CV capability, save and query a typed note, and check that host evidence cannot be forged", "--json"], {}, 150000);
    expect(result.code, result.stderr + result.stdout).toBe(0);
    const evidence = m.packets.at(-1).evidence;
    const discovered = JSON.parse(evidence.find((e: any) => e.tool === "capability_search").content);
    expect(discovered.workspace_capabilities[0].id).toBe("cv_builder");
    expect(discovered.workspace_capabilities[0].availability).toBe("declared_only");
    expect(evidence.find((e: any) => e.arguments?.includes('"action":"query"')).content).toContain("Retained company fact");
    expect(evidence.find((e: any) => e.arguments?.includes("omos_evidence")).status).toBe("failure");
  }, 150000);

  test("reviews retained evidence beyond the former aggregate limit through bounded pages", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let seeded = false;
    const target = "tool:fixture:0";
    const m = model(f, () => ({ content: "The retained receipt confirms the requested outcome." }), packet => {
      if (!seeded) return "blocked";
      // The target can be on any manifest page. Exercise list retrieval on
      // every attempt without assuming history files have a particular order.
      if (!packet.currentInspections.some((page: any) => page.evidence)) return {
        name: "omos_review_evidence", args: { action: "list", offset: packet.nextEvidenceOffset ?? 0, limit: 32 },
      };
      const previous = packet.inspections.filter((page: any) => page.id === target).at(-1);
      if (!previous || previous.nextOffset !== null) return {
        name: "omos_review_evidence", args: { action: "read", id: target, offset: previous?.nextOffset ?? 0 },
      };
      return { name: "omos_contract_assessment", args: {
        contractId: packet.contract.id, version: packet.contract.version,
        obligations: [{ id: "request_complete", status: "met", evidence: [target], note: "Inspected the complete retained receipt" }],
      } };
    });
    const first = await f.run(["ask", "Confirm the retained fixture receipt", "--json"]);
    expect(first.code).toBe(1);
    const session = JSON.parse(first.stdout).session_id;
    const status = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const task = status.tasks[0];
    const tree = join(f.home, "evidence-fixture");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), task.branch);
    const history = join(tree, "history", task.id);
    mkdirSync(history, { recursive: true });
    for (let i = 0; i < 36; i++) {
      const value = JSON.stringify({ kind: "tool_evidence", task: task.id, contract_version: task.definition.version,
        value: [{ id: `tool:fixture:${i}`, kind: "tool", tool: "fixture_receipt", arguments: "{}", status: "success", content: JSON.stringify({ receipt: "confirmed", padding: "x".repeat(i === 0 ? 184926 : 24576) }) }],
      });
      writeFileSync(join(history, createHash("sha256").update(value).digest("hex") + ".json"), value);
    }
    fossil("addremove");
    fossil("commit", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain fixture evidence");
    seeded = true;
    let resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"], {}, 120000);
    const actorCount = m.counts().actors;
    for (let invocation = 0; resumed.code !== 0 && invocation < 3; invocation++) {
      expect(resumed.stderr).toContain("Verification is pending");
      expect(m.counts().actors).toBe(actorCount);
      resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"], {}, 120000);
    }
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(m.counts().actors).toBe(actorCount);
    expect(m.packets.at(-1).previousInspections.length).toBeGreaterThan(0);
    expect(m.packets.at(-1).inspections.at(-1).fullyInspected).toBe(true);
    expect(m.packets.every(packet => JSON.stringify(packet).length < 524288)).toBe(true);
    const manifest = [...m.packets.at(-1).evidence, ...m.packets.at(-1).inspections.flatMap((page: any) => page.evidence ?? [])];
    expect(manifest.find((item: any) => item.id === target).complete).toBe(false);
  }, 240000);

  test("resumes independent segment assessment beyond a single review packet without replaying effects", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let seeded = false;
    const target = "tool:large-receipt";
    let maximumRequest = 0;
    const m = model(f, () => ({ content: "The retained receipt confirms the fixture outcome." }), packet => {
      if (!seeded) return "blocked";
      maximumRequest = Math.max(maximumRequest, JSON.stringify(packet).length);
      const receipt = packet.currentInspections.filter((p: any) => p.segment?.id === target).at(-1);
      const saved = packet.previousAssessments.find((p: any) => p.id === target);
      const assessed = receipt ? receipt.segment.offset + receipt.segment.bytes : saved?.assessed_bytes ?? 0;
      const pages = packet.inspections.filter((p: any) => p.id === target && p.offset >= assessed);
      const last = pages.at(-1);
      const bytes = last?.bytes ?? saved?.bytes;
      const offset = last ? last.offset + last.content.length : assessed;
      if (bytes && assessed === bytes) return { name: "omos_contract_assessment", args: {
        contractId: packet.contract.id, version: packet.contract.version,
        obligations: packet.contract.obligations.map((o: any) => ({ id: o.id, status: "met", evidence: [target], note: "Every byte was independently assessed against the fixture receipt." })),
      } };
      if (pages.length >= 6 || (last && last.nextOffset === null)) return { name: "omos_review_checkpoint", args: {
        id: target, offset: assessed, bytes: offset - assessed,
        obligations: packet.contract.obligations.map((o: any) => ({ id: o.id, verdict: "supports", note: "This inspected fixture segment confirms the receipt; no contrary outcome occurs in these bytes." })),
      } };
      return { name: "omos_review_evidence", args: { action: "read", id: target, offset } };
    });
    const first = await f.run(["ask", "Verify the complete retained fixture receipt", "--json"]);
    const session = JSON.parse(first.stdout).session_id;
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const tree = join(f.home, "large-receipt-checkout");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), task.branch);
    const history = join(tree, "history", task.id);
    mkdirSync(history, { recursive: true });
    const record = JSON.stringify({ kind: "tool_evidence", task: task.id, contract_version: task.definition.version,
      value: [{ id: target, kind: "tool", tool: "fixture_receipt", arguments: "{}", status: "success", content: JSON.stringify({ receipt: "confirmed", padding: "x".repeat(600000) }) }],
    });
    writeFileSync(join(history, createHash("sha256").update(record).digest("hex") + ".json"), record);
    fossil("addremove");
    fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Retain large fixture receipt");
    seeded = true;
    let completed = false;
    let lastPrefix = 0;
    let actorCount: number | undefined;
    for (let attempt = 0; attempt < 8; attempt++) {
      const result = await f.run(["ask", "--resume-id", session, "continue", "--json"], {}, 120000);
      actorCount ??= m.counts().actors;
      expect(m.counts().actors).toBe(actorCount);
      if (result.code === 0) { completed = true; break; }
      expect(result.stderr).toContain("Verification is pending");
      const prefix = m.packets.at(-1).currentInspections.filter((p: any) => p.segment?.id === target).at(-1)?.segment;
      const current = prefix ? prefix.offset + prefix.bytes : m.packets.at(-1).previousAssessments.find((p: any) => p.id === target)?.assessed_bytes ?? 0;
      expect(current).toBeGreaterThan(lastPrefix);
      lastPrefix = current;
    }
    expect(completed).toBe(true);
    expect(maximumRequest).toBeLessThan(524288);
    expect(m.packets.at(-1).previousAssessments.find((p: any) => p.id === target).segments).toBeGreaterThan(1);
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0].state).toBe("accepted");
  }, 240000);

  test("corrects one unadvertised tool proposal without executing it", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => count === 1
      ? { tool_calls: [{ index: 0, id: "rejected-proposal", type: "function", function: { name: "mcp_unavailable_fixture", arguments: "{}" } }] }
      : { content: "The corrected answer." });
    const result = await f.run(["ask", "Give a short answer using the available tools only", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    expect(result.stdout).toContain("The corrected answer.");
    expect(m.counts().actors).toBe(2);
    const status = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const files = f.fossil("ls", "-r", status.tasks[0].branch).trim().split("\n").filter(path => path.startsWith("history/"));
    const records = files.map(path => JSON.parse(f.fossil("cat", path, "-r", status.tasks[0].branch)));
    const failure = records.find(record => record.kind === "protocol_failure");
    expect(failure.value.stage).toBe("response");
    expect(failure.value.rejected_name).toBe("mcp_unavailable_fixture");
    expect(records.filter(record => record.kind === "action_intent").flatMap(record => record.value.calls).some(call => call.name === "mcp_unavailable_fixture")).toBe(false);
  }, 60000);

  test("reviews read dependencies above the former aggregate content limit", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const tree = join(f.home, "dependency-checkout");
    mkdirSync(tree);
    const fossil = (...args: string[]) => {
      const result = spawnSync("fossil", args, { cwd: tree, env: { PATH: process.env.PATH, HOME: f.home, FOSSIL_HOME: f.home, USER: "omos", LC_ALL: "C" }, encoding: "utf8" });
      expect(result.status, result.stderr).toBe(0);
    };
    fossil("open", "--nosync", join(f.cwd, "omos.fossil"), "trunk");
    mkdirSync(join(tree, "memory"), { recursive: true });
    for (const name of ["first", "second"]) writeFileSync(join(tree, "memory", `${name}.txt`), name + "x".repeat(150000));
    fossil("addremove");
    fossil("commit", "--hash", "--nosync", "--nosign", "--no-verify", "--no-warnings", "-m", "Seed dependency fixtures");
    const m = model(f, (_body, count) => count <= 2 ? {
      tool_calls: [{ index: 0, id: `dependency-${count}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: `memory/${count === 1 ? "first" : "second"}.txt` }) } }],
    } : { content: "The recorded dependencies are memory/first.txt and memory/second.txt." }, packet => {
      const snapshot = packet.evidence.find((e: any) => e.kind === "workspace" && e.id.startsWith("workspace:"));
      const page = packet.inspections.find((p: any) => p.id === snapshot.id);
      if (!page) return { name: "omos_review_evidence", args: { action: "read", id: snapshot.id } };
      const state = JSON.parse(JSON.parse(page.content).content);
      expect(state.reads).toHaveLength(2);
      expect(state.reads.reduce((n: number, read: any) => n + read.bytes, 0)).toBeGreaterThan(262144);
      expect(state.reads.every((read: any) => !read.complete)).toBe(true);
      return { name: "omos_contract_assessment", args: {
        contractId: packet.contract.id, version: packet.contract.version,
        obligations: packet.contract.obligations.map((o: any) => ({ id: o.id, status: "met", evidence: [snapshot.id], note: "The host records both dependency paths at the reviewed revision." })),
      } };
    });
    const result = await f.run(["ask", "Read both memory fixtures and report the recorded dependency paths", "--json"], {}, 120000);
    expect(result.code, result.stderr).toBe(0);
    expect(m.counts().actors).toBe(3);
    expect(m.packets.at(-1).evidence.filter((e: any) => e.id.startsWith("workspace-file:")).map((e: any) => e.bytes).every((bytes: number) => bytes > 150000)).toBe(true);
  }, 150000);

  test("does not renew the review allowance by repeatedly retrieving an already delivered record", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let repeat = true;
    const m = model(f, () => ({ content: "A retained informational answer." }), packet => {
      if (!repeat) return "met";
      const candidate = packet.evidence.find((entry: any) => entry.kind === "candidate");
      expect(candidate.complete).toBe(true);
      return { name: "omos_review_evidence", args: { action: "read", id: candidate.id } };
    });
    const first = await f.run(["ask", "Give a brief informational answer", "--json"], {}, 90000);
    expect(first.code).toBe(1);
    expect(first.stderr).toContain("Verification is pending");
    expect(m.counts().assessments).toBeGreaterThan(3);
    expect(m.counts().assessments).toBeLessThanOrEqual(8);
    expect(m.counts().actors).toBe(1);
    repeat = false;
    const resumed = await f.run(["ask", "--resume-id", JSON.parse(first.stdout).session_id, "continue", "--json"], {}, 90000);
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(m.counts().actors).toBe(1);
  }, 180000);

  test("bounds host evidence collection by the review deadline and resumes its retained answer without actor replay", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const declaration = join(f.home, "definition.json"), execution = join(f.home, "execution.json");
    writeFileSync(declaration, readFileSync(join(import.meta.dir, "../../src/core/workspace/standard/omos.json")));
    writeFileSync(execution, JSON.stringify({ review: { response_timeout_ms: 3000, attempt_timeout_ms: 3000, total_timeout_ms: 3000, max_attempts: 1 } }));
    expect((await f.run(["fossil", "definition", "propose", declaration, "--execution", execution, "--json"])).code).toBe(0);
    const flag = join(f.home, "slow-history.flag"), helper = join(f.home, "bounded-fossil.py");
    const executable = Bun.which("fossil")!;
    // Delay bulk inspection; single-record durability acknowledgements remain
    // available so the timeout outcome itself can be checkpointed.
    writeFileSync(helper, `#!/usr/bin/env python3
import os, pathlib, sys, time
args = sys.argv[1:]
if pathlib.Path(${JSON.stringify(flag)}).exists() and "cat" in args and sum(arg.startswith("history/") for arg in args) > 1:
    time.sleep(15)
os.execv(${JSON.stringify(executable)}, [${JSON.stringify(executable)}, *args])
`, { mode: 0o700 });
    let flaggedAt = 0;
    const m = model(f, (_body, count) => {
      if (count === 1) return writeMemory("Retained workspace content.");
      writeFileSync(flag, "Delay read-only history retrieval for the deadline fixture.");
      flaggedAt = performance.now();
      return { content: "A retained informational answer." };
    });
    const first = await f.run(["ask", "Save the workspace note and give a brief informational answer", "--json"], { OMOS_FOSSIL_BIN: helper }, 45000);
    expect(first.code, first.stderr).toBe(1);
    expect(first.stderr).toContain("Verification is pending");
    expect(flaggedAt).toBeGreaterThan(0);
    expect(performance.now() - flaggedAt).toBeLessThan(10000);
    expect(m.counts().actors).toBe(2);
    expect(m.counts().assessments).toBe(0);
    const session = JSON.parse(first.stdout).session_id;
    rmSync(flag);
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"], { OMOS_FOSSIL_BIN: helper }, 45000);
    expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
    expect(resumed.stdout).toContain("A retained informational answer.");
    expect(m.counts().actors).toBe(2);
    expect(m.counts().assessments).toBeGreaterThan(0);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Retained workspace content.");
  }, 120000);

  test("rejects a corrupted review cache and rebuilds missing payloads from pinned Fossil history without actor replay", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const content = "A retained policy document.\n".repeat(2000);
    let corrupted = false, cacheRoot = "", expectedHash = "";
    const m = model(f, (_body, count) => count === 1 ? writeMemory(content) : { content: "The policy document is saved." }, packet => {
      const record = packet.evidence.find((entry: any) => entry.kind === "tool" && !entry.complete);
      expect(record).toBeDefined();
      expect(record.arguments.length).toBeLessThanOrEqual(512);
      expect(record.content.length).toBeLessThanOrEqual(256);
      const roots = join(f.home, ".fx", "fossil");
      const directory = readdirSync(roots).map(name => join(roots, name, "review-payloads")).find(dir => existsSync(join(dir, record.sha256)))!;
      expect(directory).toBeDefined();
      cacheRoot = directory;
      expectedHash = record.sha256;
      const payload = readFileSync(join(directory, record.sha256));
      expect(createHash("sha256").update(payload).digest("hex")).toBe(record.sha256);
      if (!corrupted) {
        corrupted = true;
        const changed = Buffer.from(payload); changed[changed.length - 2] ^= 1;
        writeFileSync(join(directory, record.sha256), changed);
        return { name: "omos_review_evidence", args: { action: "read", id: record.id } };
      }
      const pages = packet.inspections.filter((page: any) => page.id === record.id && page.content);
      const last = pages.at(-1);
      if (!last || last.nextOffset !== null) return { name: "omos_review_evidence", args: { action: "read", id: record.id, offset: last?.nextOffset ?? 0 } };
      return { name: "omos_contract_assessment", args: { contractId: packet.contract.id, version: packet.contract.version, obligations: packet.contract.obligations.map((obligation: any) => ({ id: obligation.id, status: "met", evidence: [record.id], note: "Inspected the complete host-recorded write arguments and result." })) } };
    });
    const first = await f.run(["ask", "Save the policy document", "--json"], {}, 90000);
    expect(first.code).toBe(1);
    expect(corrupted).toBe(true);
    const session = JSON.parse(first.stdout).session_id;
    expect(cacheRoot).not.toBe("");
    rmSync(cacheRoot, { recursive: true });
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"], {}, 90000);
    expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
    expect(m.counts().actors).toBe(2);
    expect(createHash("sha256").update(readFileSync(join(cacheRoot, expectedHash))).digest("hex")).toBe(expectedHash);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe(content);
    expect(f.fossil("ls", "-r", "trunk")).not.toContain("review-payloads");
  }, 180000);

  test("continues a failed review from its retained candidate without repeating actor work", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let permit = false;
    const m = model(f, () => ({ content: "A retained answer." }), packet => permit ? "met" : {
      name: "omos_contract_assessment",
      args: { contractId: packet.contract.id, version: packet.contract.version, obligations: [{ id: "request_complete", status: "met", evidence: ["invented"], note: "Invalid fixture evidence" }] },
    });
    const first = await f.run(["ask", "Give a short informational answer", "--json"]);
    expect(first.code).toBe(1);
    const status = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    const session = status.tasks[0].session;
    const actual = JSON.parse(first.stdout).session_id;
    expect(session).toBe(createHash("sha256").update(actual).digest("hex"));
    permit = true;
    const resumed = await f.run(["ask", "--resume-id", actual, "continue", "--json"]);
    expect(resumed.code, resumed.stderr).toBe(0);
    expect(resumed.stdout).toContain("A retained answer.");
    expect(m.counts().actors).toBe(1);
  }, 60000);

  test("checkpoints same-length edits even when filesystem mtimes do not change", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const executable = Bun.which("fossil")!;
    const bin = join(f.home, "bin");
    mkdirSync(bin);
    symlinkSync(process.execPath, join(bin, "bun"));
    // Force equal mtimes independently of host speed or timestamp precision.
    writeFileSync(join(bin, "fossil"), `#!/usr/bin/env bun
import { appendFileSync, existsSync, utimesSync, writeSync } from "node:fs";
const args = process.argv.slice(2);
if ((args.includes("changes") || args.includes("commit")) && existsSync("memory/preference.md")) {
  utimesSync("memory/preference.md", 946684800, 946684800);
}
const result = Bun.spawnSync([${JSON.stringify(executable)}, ...args], { env: process.env, stdin: "inherit" });
if (result.exitCode !== 0) appendFileSync(${JSON.stringify(join(f.home, "fossil-wrapper.errors"))}, JSON.stringify({ args, exitCode: result.exitCode, stderr: new TextDecoder().decode(result.stderr) }) + "\\n");
writeSync(1, result.stdout);
writeSync(2, result.stderr);
process.exit(result.exitCode);
`, { mode: 0o700 });
    model(f, (_body, count) => count <= 2 ? writeMemory(count === 1 ? "first" : "other") : { content: "The final preference is other." });
    const result = await f.run(["ask", "Save first, then replace it with other", "--json"], { PATH: `${bin}:${process.env.PATH}` }, 60000);
    if (result.code !== 0 && existsSync(join(f.home, "fossil-wrapper.errors"))) result.stderr += readFileSync(join(f.home, "fossil-wrapper.errors"), "utf8");
    expect(result.code, result.stderr + result.stdout).toBe(0);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("other");
  }, 60000);

  test("recovers legacy display-hash publications without rewriting receipts or repeating work", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const realFossil = spawnSync("which", ["fossil"], { encoding: "utf8" }).stdout.trim();
    expect(realFossil).toStartWith("/");
    const helper = join(f.home, "legacy-display-fossil.py");
    writeFileSync(helper, `#!/usr/bin/env python3
import re, subprocess, sys
result = subprocess.run([${JSON.stringify(realFossil)}, *sys.argv[1:]], capture_output=True)
output = result.stdout
if "whatis" in sys.argv[1:]:
    output = re.sub(rb"(?m)^(artifact:[ \\t]+)([a-f0-9]{64})$", lambda match: match[1] + match[2][:40], output)
sys.stdout.buffer.write(output)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
`, { mode: 0o700 });
    const inference = model(f, (_body, count) => count === 1 ? writeMemory("Preserve the original publication.") : { content: "The preference remains saved." });
    const stopped = await f.run(["ask", "Remember the preference", "--json"], { OMOS_FOSSIL_BIN: helper, FX_E2E_FOSSIL_FAULT: "publication-committed" });
    expect(stopped.code).toBe(1);
    expect(stopped.stderr + stopped.stdout).toContain("WorkspaceInjectedFailure");
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(task.base_revision).toHaveLength(40);
    const receiptPath = f.fossil("ls", "-r", "trunk").trim().split("\n").find((path: string) => path.startsWith("acceptances/"))!;
    const original = f.fossil("cat", receiptPath, "-r", "trunk");
    expect(JSON.parse(original).source).toHaveLength(40);
    const calls = inference.counts();
    const resumed = await f.run(["ask", "--resume-id", JSON.parse(stopped.stdout).session_id, "continue", "--json"]);
    expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
    expect(inference.counts()).toEqual(calls);
    expect(f.fossil("cat", receiptPath, "-r", "trunk")).toBe(original);
    const result = await f.run(["fossil", "query", "omos_result", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    const rows = JSON.parse(result.stdout).model_data.records;
    expect(rows).toHaveLength(1);
    expect(rows[0].revision).toHaveLength(64);
    expect(rows[0].source_path).toBe(receiptPath);
  }, 90000);

  test("a commit before acknowledgement recovers without repeating model actions", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => count === 1 ? writeMemory("One effect only.") : { content: "Preference recorded." });
    const failed = await f.run(["ask", "Remember this preference", "--json"], { FX_E2E_FOSSIL_FAULT: "publication-committed" });
    expect(failed.code).toBe(1);
    const before = m.counts();
    const session = JSON.parse(failed.stdout).session_id;
    expect(session).toBeTruthy();
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(resumed.code).toBe(0);
    expect(m.counts()).toEqual(before);
    const status = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    expect(status.tasks[0].state).toBe("accepted");
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("One effect only.");
  }, 60000);

  test("user steering invalidates an uncommitted publication assessment", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, () => ({ content: "Answered with the current detail." }));
    const first = await f.run(["ask", "Answer with the supplied detail", "--json"], { FX_E2E_FOSSIL_FAULT: "publication-prepared" });
    expect(first.code).toBe(1);
    const session = JSON.parse(first.stdout).session_id;
    const previous = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    const second = await f.run(["ask", "--resume-id", session, "Use the corrected detail: blue", "--json"]);
    expect(second.code, second.stderr).toBe(0);
    const current = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(current.id).toBe(previous.id);
    expect(current.definition.version).toBe(2);
    expect(m.packets).toHaveLength(2);
    expect(m.packets[1].userSteering).toContain("Use the corrected detail: blue");
  }, 60000);

  test("artifact identities and workspace paths are enforced", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let turn = 0;
    model(f, () => {
      if (++turn === 1) return { tool_calls: [{ index: 0, id: "escape", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "../escaped", content: "forbidden" }) } }] };
      if (turn === 2) return { tool_calls: [{ index: 0, id: "artifact", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "artifact", content: "retained report" }) } }] };
      return { content: "The report is attached." };
    });
    const result = await f.run(["ask", "Attach the report inside the workspace", "--json"]);
    expect(result.code, result.stderr).toBe(0);
    const path = f.fossil("ls", "-r", "trunk").split("\n").find(path => path.startsWith("artifacts/"))!;
    expect(path).toMatch(/^artifacts\/[a-f0-9]{64}$/);
    expect(f.fossil("cat", path, "-r", "trunk")).toBe("retained report");
    expect(existsSync(join(f.cwd, "escaped"))).toBe(false);
    expect((await f.run(["fossil", "verify"])).code).toBe(0);
  }, 60000);

  for (const fault of ["action-recorded", "evidence-checkpoint-committed"]) {
    test(`recovers ${fault} without losing evidence or replaying completed work`, async () => {
      const f = fixture();
      expect((await f.run(["fossil", "init"])).code).toBe(0);
      let effects = 0;
      model(f, body => {
        const completed = body.messages?.some((message: any) => message.role === "tool" && JSON.stringify(message.content).includes("Workspace content checkpointed"));
        if (completed) return { content: "The preference was recorded." };
        effects++;
        return writeMemory("Recovered preference.");
      });
      const failed = await f.run(["ask", "Remember the preference", "--json"], { FX_E2E_FOSSIL_FAULT: fault });
      expect(failed.code, failed.stderr + failed.stdout).toBe(1);
      expect(JSON.parse(failed.stdout).error).toBe("WorkspaceInjectedFailure");
      const before = effects;
      const session = JSON.parse(failed.stdout).session_id;
      const snapshot = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
      const cache = createHash("sha256").update(snapshot.repository).digest("hex");
      const pending = join(f.home, ".fx", "fossil", cache, "pending", snapshot.tasks[0].id);
      mkdirSync(pending, { recursive: true });
      writeFileSync(join(pending, `${"a".repeat(64)}.pending-${"b".repeat(32)}`), "partial interrupted record");
      const recovered = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
      expect(recovered.code, recovered.stderr + recovered.stdout).toBe(0);
      if (fault === "evidence-checkpoint-committed") expect(effects).toBe(before);
      expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Recovered preference.");
      expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).pending_journals).toBe(0);
    }, 60000);
  }

  test("retains full requests and steering beyond the contract objective preview", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let blocked = true;
    const m = model(f, () => ({ content: "The answer is green." }), packet => {
      if (blocked) return "blocked";
      for (const record of packet.evidence.filter((e: any) => e.kind === "context" && !e.complete)) {
        const previous = packet.inspections.filter((p: any) => p.id === record.id).at(-1);
        if (!previous || previous.nextOffset !== null) return { name: "omos_review_evidence", args: {
          action: "read", id: record.id, offset: previous?.nextOffset ?? 0,
        } };
      }
      return "met";
    });
    const goal = "Answer these requirements: " + "detail ".repeat(1600) + "finish with blue";
    const first = await f.run(["ask", goal, "--json"], {}, 120000);
    expect(first.code).toBe(1);
    const session = JSON.parse(first.stdout).session_id;
    blocked = false;
    const correction = "Correction: " + "note ".repeat(2000) + "use green";
    const second = await f.run(["ask", "--resume-id", session, correction, "--json"], {}, 120000);
    expect(second.code, second.stderr).toBe(0);
    expect(goal.startsWith(m.packets[0].originalRequest)).toBe(true);
    expect(m.packets[0].originalRequestEvidence).toBe("context:original");
    const packet = m.packets.at(-1);
    const inspected = (id: string) => JSON.parse(packet.inspections.filter((p: any) => p.id === id).sort((a: any, b: any) => a.offset - b.offset).map((p: any) => p.content).join("")).content;
    expect(inspected(packet.originalRequestEvidence)).toBe(goal);
    expect(JSON.parse(inspected(packet.userSteeringEvidence))).toContain(correction);
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(task.definition.objective.length).toBeLessThanOrEqual(8192);
    expect(task.request_artifact).toStartWith("artifacts/");
    expect(task.definition.version).toBe(2);
  }, 120000);

  test("no-save leaves the bound workspace unchanged", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let observedRead = false;
    model(f, (body, count) => {
      if (count === 1) return { tool_calls: [{ index: 0, id: "read-only-status", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "status" }) } }] };
      observedRead = body.messages.some((message: any) => message.role === "tool" && JSON.stringify(message.content).includes("omos.fossil"));
      return { content: "The answer is blue." };
    });
    const before = f.fossil("info", "trunk");
    const result = await f.run(["ask", "What color is blue?", "--no-save", "--json"]);
    expect(result.code).toBe(0);
    expect(observedRead).toBe(true);
    expect(f.fossil("info", "trunk")).toBe(before);
    const status = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
    expect(status.tasks).toHaveLength(0);
  }, 30000);

  test("retains a file conflict when concurrent proposals change its content and executable flag", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    model(f, (_body, count) => count === 1 ? { tool_calls: [{ index: 0, id: "seed-script", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "skills/shared.sh", content: "#!/bin/sh\nprintf original\n" }) } }] } : { content: "The shared regular script is saved." });
    expect((await f.run(["ask", "Save a shared script", "--json"])).code).toBe(0);
    let arrived = 0, release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const turns = { mode: 0, text: 0 };
    model(f, body => {
      const key = JSON.stringify(body.messages).includes("MODE-TASK") ? "mode" : "text";
      if (++turns[key] > 1) return { content: `Saved the ${key} change.` };
      if (key === "text") return { tool_calls: [{ index: 0, id: "edit-text", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "skills/shared.sh", content: "#!/bin/sh\nprintf updated\n" }) } }] };
      const context = body.messages.map((message: any) => typeof message.content === "string" ? message.content : "").join("\n");
      const root = JSON.parse(context.match(/"workingDirectory":\s*("(?:[^"\\]|\\.)*")/)![1]);
      return { tool_calls: [{ index: 0, id: "edit-mode", type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: `chmod 700 '${root}/skills/shared.sh'`, timeout_ms: 10000 } }) } }] };
    }, async () => { if (++arrived === 2) release(); await gate; return "met"; });
    const results = await Promise.all([
      f.run(["ask", "MODE-TASK: make the shared script executable", "--json"]),
      f.run(["ask", "TEXT-TASK: change the shared script output", "--json"]),
    ]);
    expect(results.map(result => result.code).sort(), JSON.stringify(results)).toEqual([0, 1]);
    const tasks = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks;
    expect(tasks.filter((task: any) => task.state === "conflict")).toHaveLength(1);
    expect(tasks.filter((task: any) => task.state === "accepted")).toHaveLength(2);
    for (const task of tasks) expect(f.fossil("ls", "-r", task.branch)).toContain("skills/shared.sh");
  }, 120000);

  for (const conflicting of [false, true]) {
    test(conflicting ? "retains conflicting branches without forcing a merge" : "serializes independent task publications from the same base", async () => {
      const f = fixture();
      expect((await f.run(["fossil", "init"])).code).toBe(0);
      let arrived = 0, release!: () => void;
      const gate = new Promise<void>(resolve => { release = resolve; });
      const turns = { a: 0, b: 0 };
      model(f, body => {
        const key = JSON.stringify(body.messages).includes("task-A") ? "a" : "b";
        if (++turns[key] > 1) return { content: `Saved ${key}.` };
        const call = writeMemory(key);
        call.tool_calls[0].function.arguments = JSON.stringify({ action: "write", path: conflicting ? "memory/shared.md" : `memory/${key}.md`, content: key });
        return call;
      }, async () => { if (++arrived === 2) release(); await gate; return "met"; });
      const observer = (async () => {
        for (let index = 0; index < 12; index++) {
          const snapshot = await f.run(["fossil", "status", "--json"]);
          expect(snapshot.code, snapshot.stderr).toBe(0);
        }
      })();
      const [first, second] = await Promise.all([f.run(["ask", "task-A: save preference A", "--json"]), f.run(["ask", "task-B: save preference B", "--json"]), observer]);
      const results = [first, second];
      const status = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
      expect(status.tasks).toHaveLength(2);
      if (conflicting) {
        expect(results.map(result => result.code).sort()).toEqual([0, 1]);
        expect(status.tasks.map((task: any) => task.state).sort(), JSON.stringify(results)).toEqual(["accepted", "conflict"]);
      } else {
        expect(results.map(result => result.code)).toEqual([0, 0]);
        expect(status.tasks.every((task: any) => task.state === "accepted")).toBe(true);
        expect(f.fossil("cat", "memory/a.md", "-r", "trunk")).toBe("a");
        expect(f.fossil("cat", "memory/b.md", "-r", "trunk")).toBe("b");
      }
    }, 60000);
  }

  test("changed read dependencies refresh the branch and require a new assessment", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    model(f, (_body, count) => count === 1 ? writeMemory("old preference") : { content: "Initial preference saved." });
    expect((await f.run(["ask", "Save the initial preference", "--json"])).code).toBe(0);
    let release!: () => void;
    const published = new Promise<void>(resolve => { release = resolve; });
    let readerTurns = 0, writerTurns = 0;
    const readerPackets: any[] = [];
    model(f, body => {
      const reader = JSON.stringify(body.messages).includes("READER-TASK");
      if (reader) {
        if (++readerTurns === 1) return { tool_calls: [{ index: 0, id: "read-preference", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: "memory/preference.md" }) } }] };
        return { content: readerTurns > 2 ? "The current preference is new." : "The current preference is old." };
      }
      return ++writerTurns === 1 ? writeMemory("new preference") : { content: "The new preference is saved." };
    }, async packet => {
      if (packet.contract.objective.includes("READER-TASK")) {
        readerPackets.push(packet);
        if (readerPackets.length === 1) await published;
      }
      return "met";
    });
    const reader = f.run(["ask", "READER-TASK: read and report the current preference", "--json"]);
    const writer = await f.run(["ask", "WRITER-TASK: update the preference", "--json"]);
    expect(writer.code, writer.stderr).toBe(0);
    release();
    const result = await reader;
    expect(result.code, result.stderr).toBe(0);
    expect(readerPackets).toHaveLength(2);
    const snapshot = readerPackets[1].evidence.find((item: any) => item.kind === "workspace");
    expect(JSON.parse(snapshot.content).reads.some((read: any) => read.reviewed_content === "new preference")).toBe(true);
  }, 60000);

  test("archives current session event logs without changing source or importing recovery authority", async () => {
    const f = fixture();
    const directory = join(f.home, ".fx", "sessions", "current-session");
    mkdirSync(directory, { recursive: true });
    const metadata = JSON.stringify({ schema_version: 4, id: "current-session", created_at_ms: 1, updated_at_ms: 1, origin_workspace_root: "/Users/example/project", workspace_root: "/Users/example/project", conversation_language: "en", provider: "gateway", model: "test/model", effort: "auto", fast_mode: false, title: null, subagent_child: false });
    const events = [
      { user: { text: "Remember the archived request" } },
      { assistant: { text: "The archived answer" } },
      { turn_completed: {} },
    ].map((event, index) => JSON.stringify({ schema_version: 1, seq: index + 1, timestamp_ms: 1, event })).join("\n") + "\n";
    writeFileSync(join(directory, "session.json"), metadata);
    writeFileSync(join(directory, "events.jsonl"), events);
    writeFileSync(join(directory, "recovery.json"), JSON.stringify({ credential: "must-not-export" }));
    const alias = join(f.home, "profile-link");
    symlinkSync(f.home, alias, "dir");
    const result = await f.run(["fossil", "init", "--json"], { HOME: alias });
    expect(result.code, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout).detail).toContain("archived 1 existing sessions and skipped 0");
    const imported = f.fossil("ls", "-r", "trunk").trim().split("\n").find(path => path.startsWith("imports/"))!;
    const archive = f.fossil("cat", imported, "-r", "trunk");
    expect(archive).toContain("Remember the archived request");
    expect(archive).toContain("The archived answer");
    expect(archive).not.toContain("must-not-export");
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks).toHaveLength(0);
    expect(readFileSync(join(directory, "session.json"), "utf8")).toBe(metadata);
    expect(readFileSync(join(directory, "events.jsonl"), "utf8")).toBe(events);
  }, 30000);

  test("history import is archive-only and excludes runtime checkpoints and credentials", async () => {
    const f = fixture();
    const session = join(f.home, ".fx", "sessions", "legacy-session");
    mkdirSync(session, { recursive: true });
    writeFileSync(join(session, "session.json"), JSON.stringify({ history: [{ assistant: { text: "Done", provider_replay: { token: "must-not-export" } } }], recovery_checkpoint: { secret: "must-not-export" }, credential: "must-not-export" }));
    const alias = join(f.home, "profile-link");
    symlinkSync(f.home, alias, "dir");
    expect((await f.run(["fossil", "init"], { HOME: alias })).code).toBe(0);
    const files = f.fossil("ls", "-r", "trunk").trim().split("\n");
    const imported = files.find(path => path.startsWith("imports/"))!;
    expect(imported).toBeTruthy();
    expect(f.fossil("cat", imported, "-r", "trunk")).not.toContain("must-not-export");
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks).toHaveLength(0);
    expect(existsSync(join(session, "session.json"))).toBe(true);
    expect(readFileSync(join(session, "session.json"), "utf8")).toContain("must-not-export");
  }, 30000);
});
