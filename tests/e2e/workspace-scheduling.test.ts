import { afterEach, expect, test } from "bun:test";
import { resolve, join } from "node:path";
import { NativeClient } from "./workspace-ui-client.mjs";
import { cleanupFixtures, fixture, model, writeMemory } from "./fossil-workspace-helpers";

const clients: NativeClient[] = [];
afterEach(async () => {
  for (const client of clients.splice(0)) await client.close();
  cleanupFixtures();
});

test("recurring exports require fresh local authority and fenced controls retain their occurrence", async () => {
  const f = fixture();
  const { task, provider } = await savedContract(f);
  const actorCount = provider.counts().actors;
  const add = await f.run(["schedule", "series", "add", task.id, "--at", "2020-01-01T09:00:00Z", "--every", "1m", "--count", "1", "--json"]);
  expect(add.code, add.stderr).toBe(0);
  const created = JSON.parse(add.stdout);
  const id = created.series[0].id;
  const archive = join(f.home, "portable-recurring.fossil");
  expect((await f.run(["fossil", "export", archive, "--json"])).code).toBe(0);
  expect((await f.run(["fossil", "use", archive, "--json"])).code).toBe(0);
  const native = host(f, { FX_E2E_SCHEDULE_CLOCK_MS: String(Date.parse("2020-01-01T09:00:00Z")) });
  expect((await native.request("initialize")).capabilities).toContain("schedule_series_v1");
  const paused: any = await until(() => native.request("schedule.series", { action: "show", id }), (value: any) => value.series[0].state === "paused");
  expect(paused.series[0].reason).toBe("LocalSeriesAuthorityRequired");
  expect(paused.series[0].materialized_count).toBe(1);
  expect(provider.counts().actors).toBe(actorCount);
  await expect(native.request("schedule.series", { action: "resume", id })).rejects.toThrow("WorkspaceRevisionRequired");
  const occurrence = paused.occurrences[0];
  const moved = await native.request("schedule.series", { action: "move", id, occurrence: occurrence.id, at: "2099-01-01T09:00:00Z", revision: paused.revision });
  expect(moved.occurrences[0].nominal_ms).toBe(occurrence.nominal_ms);
  await expect(native.request("schedule.series", { action: "resume", id, revision: paused.revision })).rejects.toThrow("WorkspaceRevisionChanged");
  await native.request("schedule.series", { action: "resume", id, revision: moved.revision });
  const prepared: any = await until(() => native.request("schedule.series", { action: "show", id }), (value: any) => value.occurrences[0]?.preparation === "prepared");
  expect(prepared.occurrences[0].id).toBe(occurrence.id);
  expect(prepared.series[0].materialized_count).toBe(1);
  expect(provider.counts().actors).toBe(actorCount);
  const fenced = await native.request("schedule.series", { action: "pause", id, revision: prepared.revision });
  expect((await native.request("schedule", { action: "show", id: occurrence.schedule })).schedules[0].state).toBe("cancelled");
  const cancelled = await native.request("schedule.series", { action: "cancel", id, revision: fenced.revision });
  expect(cancelled.series[0].state).toBe("cancelled");
  expect(cancelled.occurrences[0].id).toBe(occurrence.id);
  expect(provider.counts().actors).toBe(actorCount);
  expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks).toHaveLength(2);
}, 120000);

test("recurring HTTP reads require bearer authority and read-only hosts cannot mutate series", async () => {
  const f = fixture();
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const token = "recurring-isolated-owner-token-for-fixtures";
  const child = Bun.spawn([resolve(import.meta.dir, "../../zig-out/bin/fx"), "fossil", "serve", "0", "--json"], { cwd: f.cwd, env: { ...process.env, ...f.env, OMOS_WORKSPACE_TOKEN: token }, stdout: "pipe", stderr: "pipe" });
  try {
    const reader = child.stdout.getReader();
    let output = "";
    while (!output.includes("\n")) {
      const chunk = await Promise.race([reader.read(), Bun.sleep(15000).then(() => { throw Error("Recurring HTTP service did not become ready"); })]);
      if (chunk.done) throw Error("Recurring HTTP service exited before readiness");
      output += new TextDecoder().decode(chunk.value);
    }
    reader.releaseLock();
    const ready = JSON.parse(output.trim().split("\n")[0]);
    const url = `http://127.0.0.1:${ready.port}/v1/schedule-series`;
    const body = { version: "omos.schedule-series/v1", workspace: ready.workspace, request: { action: "list" } };
    const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
    const post = (data: object) => fetch(url, { method: "POST", headers, body: JSON.stringify(data) });
    expect((await fetch(url, { method: "POST", body: JSON.stringify(body) })).status).toBe(401);
    const listed = await post(body);
    expect(listed.status, await listed.clone().text()).toBe(200);
    const snapshot: any = await listed.json();
    expect(snapshot.series).toEqual([]);
    expect((await post({ ...body, workspace: "other" })).status).toBe(403);
    expect((await post({ ...body, request: { action: "pause", id: "series", revision: snapshot.revision } })).status).toBe(403);
  } finally {
    child.kill(); await child.exited;
    expect(await new Response(child.stderr).text()).toBe("");
  }
}, 30000);

async function savedContract(f: ReturnType<typeof fixture>, assessment: Parameters<typeof model>[2] = () => "blocked", actor?: Parameters<typeof model>[1]) {
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  const provider = model(f, actor ?? ((_body, count) => count === 1 ? writeMemory("Retain this contract's evidence.") : { content: "The work and evidence are retained." }), assessment);
  const first = await f.run(["ask", "Save a preference and keep the work contract available for continuation", "--json"]);
  expect(first.code, first.stderr).toBe(1);
  const snapshot = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
  return { task: snapshot.tasks[0], provider, first };
}

function host(f: ReturnType<typeof fixture>, extra: Record<string, string | undefined> = {}) {
  const client = new NativeClient({ binary: resolve(import.meta.dir, "../../zig-out/bin/fx"), project: f.cwd, env: { ...process.env, ...f.env, ...extra } });
  clients.push(client);
  return client;
}

async function until<T>(read: () => Promise<T>, matches: (value: T) => boolean): Promise<T> {
  const deadline = Date.now() + 60000;
  let latest: T;
  do {
    latest = await read();
    if (matches(latest)) return latest;
    await Bun.sleep(250);
  } while (Date.now() < deadline);
  throw Error(`Scheduled state did not converge: ${JSON.stringify(latest!)}`);
}

test("CLI schedules share a revision-fenced calendar and survive workspace export", async () => {
  const f = fixture();
  const { task } = await savedContract(f);
  const invoke = async (...args: string[]) => {
    const result = await f.run(["schedule", ...args, "--json"]);
    expect(result.code, result.stderr + result.stdout).toBe(0);
    return JSON.parse(result.stdout);
  };
  const created = await invoke("add", task.id, "--at", "2099-10-23T09:00:00+01:00");
  const event = created.schedules[0];
  expect(event.task).toBe(task.id);
  expect(event.at_ms).toBe(Date.parse("2099-10-23T08:00:00Z"));
  expect(event.state).toBe("scheduled");
  expect(event.definition.obligations).toEqual(task.definition.obligations);
  expect((await f.run(["schedule", "add", task.id, "--at", "2099-10-24T09:00:00Z", "--json"])).code).toBe(1);
  const moved = await invoke("move", event.id, "--at", "2099-10-24T10:00:00Z", "--revision", created.revision);
  expect(moved.revision).not.toBe(created.revision);
  expect(moved.schedules[0].history.map((entry: any) => entry.kind)).toEqual(["created", "rescheduled"]);
  const stale = await f.run(["schedule", "cancel", event.id, "--revision", created.revision, "--json"]);
  expect(stale.code).toBe(1);
  expect(stale.stdout + stale.stderr).toContain("WorkspaceRevisionChanged");
  expect((await invoke("list", "--from", "2099-10-23T00:00:00Z", "--to", "2099-10-24T00:00:00Z")).schedules).toEqual([]);
  const native = host(f);
  const calendar = await native.request("schedule", { action: "show", id: event.id });
  expect(calendar.schedules[0]).toEqual(moved.schedules[0]);
  await expect(native.request("schedule", { action: "cancel", id: event.id })).rejects.toThrow("WorkspaceRevisionRequired");
  const cancelled = await native.request("schedule", { action: "cancel", id: event.id, revision: moved.revision });
  expect(cancelled.schedules[0].state).toBe("cancelled");
  await native.close(); clients.splice(clients.indexOf(native), 1);
  const archive = join(f.home, "portable-schedules.fossil");
  expect((await f.run(["fossil", "export", archive, "--json"])).code).toBe(0);
  expect((await f.run(["fossil", "use", archive, "--json"])).code).toBe(0);
  expect((await invoke("show", event.id)).schedules[0].state).toBe("cancelled");
  expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0].state).not.toBe("accepted");
}, 120000);

test("workspace host starts an overdue contract once and publishes retained work", async () => {
  const f = fixture();
  let resume = false;
  const { task, provider, first } = await savedContract(f, () => resume ? "met" : {
    name: "omos_review_evidence", args: { action: "query", kind: "candidate" },
  });
  expect(first.stderr, first.stdout).toContain("Verification is pending");
  const actors = provider.counts().actors;
  const created = await f.run(["schedule", "add", task.id, "--at", "2020-01-01T09:00:00Z", "--json"]);
  expect(created.code, created.stderr).toBe(0);
  const schedule = JSON.parse(created.stdout).schedules[0];
  expect(schedule.state).toBe("overdue");
  resume = true;
  const native = host(f);
  const final: any = await until(() => native.request("schedule", { action: "show", id: schedule.id }), (snapshot: any) => snapshot.schedules[0]?.finished_ms != null && ["completed", "failed", "waiting"].includes(snapshot.schedules[0]?.state));
  expect(final.schedules[0].state, final.schedules[0].reason + native.stderr).toBe("completed");
  expect(final.schedules[0].task_state).toBe("accepted");
  expect(final.schedules[0].started_ms).toBeGreaterThan(schedule.at_ms);
  expect(final.schedules[0].finished_ms).toBeGreaterThanOrEqual(final.schedules[0].started_ms);
  expect(final.schedules[0].history.filter((event: any) => event.kind === "running")).toHaveLength(1);
  expect(provider.counts().actors).toBe(actors);
  await native.close(); clients.splice(clients.indexOf(native), 1);
  const restarted = host(f);
  const persisted = await restarted.request("schedule", { action: "show", id: schedule.id });
  expect(persisted.schedules[0].state).toBe("completed");
  expect(persisted.schedules[0].history.filter((event: any) => event.kind === "running")).toHaveLength(1);
}, 120000);

test("schedule CLI rejects ambiguous and out-of-range dates before creating durable events", async () => {
  const f = fixture();
  expect((await f.run(["fossil", "init", "--json"])).code).toBe(0);
  for (const at of ["2026-10-23T09:00:00", "2026-02-29T09:00:00Z", "2026-10-23T25:00:00Z", "1970-01-01T00:00:00+01:00", "9999-12-31T23:00:00-01:00"]) {
    const result = await f.run(["schedule", "add", "missing-task", "--at", at, "--json"]);
    expect(result.code).toBe(1);
    expect(result.stdout + result.stderr).toContain("InvalidScheduleTime");
  }
  const list = await f.run(["schedule", "list", "--json"]);
  expect(list.code).toBe(0);
  expect(JSON.parse(list.stdout).schedules).toEqual([]);
}, 30000);

test("recurring starts create two independently published tasks and native sessions", async () => {
  const f = fixture();
  expect((await f.run(["fossil", "init"])).code).toBe(0);
  const provider = model(f, (_body, count) => count % 2 === 1 ? writeMemory(`Fresh occurrence evidence ${count}.`) : { content: "Saved the current preference with fresh evidence." });
  const original = await f.run(["ask", "Save the current preference with fresh evidence", "--json"]);
  expect(original.code, original.stderr + original.stdout).toBe(0);
  const source = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
  expect(source.state).toBe("accepted");
  const before = provider.counts().actors;
  const created = await f.run(["schedule", "series", "add", source.id, "--at", "2020-01-01T09:00:00Z", "--every", "1m", "--count", "2", "--json"]);
  expect(created.code, created.stderr + created.stdout).toBe(0);
  const initial = JSON.parse(created.stdout);
  const id = initial.series[0].id;
  const clock = Date.parse("2020-01-01T09:00:00Z");
  const firstHost = host(f, { FX_E2E_SCHEDULE_CLOCK_MS: String(clock) });
  const first: any = await until(() => firstHost.request("schedule.series", { action: "show", id }), (snapshot: any) => snapshot.series[0]?.materialized_count === 1 && snapshot.series[0]?.active_occurrence == null && snapshot.occurrences[0]?.outcome === "completed");
  expect(first.occurrences[0].task).not.toBe(source.id);
  expect(first.occurrences[0].nominal_ms).toBe(clock);
  await firstHost.close(); clients.splice(clients.indexOf(firstHost), 1);
  const secondHost = host(f, { FX_E2E_SCHEDULE_CLOCK_MS: String(clock + 60000) });
  const final: any = await until(() => secondHost.request("schedule.series", { action: "show", id }), (snapshot: any) => snapshot.series[0]?.state === "completed");
  expect(final.series[0].materialized_count).toBe(2);
  expect(final.occurrences).toHaveLength(2);
  expect(new Set(final.occurrences.map((run: any) => run.task)).size).toBe(2);
  expect(new Set(final.occurrences.map((run: any) => run.session)).size).toBe(2);
  expect(final.occurrences.every((run: any) => run.outcome === "completed")).toBe(true);
  expect(final.occurrences[0].nominal_ms).toBe(clock + 60000);
  const tasks = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks;
  expect(tasks).toHaveLength(3);
  expect(tasks.every((task: any) => task.state === "accepted")).toBe(true);
  expect(tasks.find((task: any) => task.id === source.id).definition).toEqual(source.definition);
  expect(new Set(tasks.map((task: any) => task.session)).size).toBe(3);
  expect(provider.counts().actors - before).toBe(4);
  const template = JSON.parse(f.fossil("cat", `schedules/templates/${id}.json`, "-r", "omos-schedules"));
  expect(Object.keys(template.native).sort()).toEqual(["language", "preferences"]);
  expect(template.state).toBeUndefined();
  expect(template.native.permission_state).toBeUndefined();
  expect((await secondHost.request("schedule", { action: "list" })).schedules).toEqual([]);
}, 120000);

for (const point of ["series_after_reservation", "series_after_session", "series_after_task", "series_before_schedule", "series_after_schedule"]) {
  test(`recurring preparation recovers ${point} without duplicating tasks or effects`, async () => {
    const f = fixture();
    let finish = false;
    const { task, provider } = await savedContract(f, () => finish ? "met" : "blocked", (_body, count) => count % 2 === 1 ? writeMemory(`New occurrence effect ${count}.`) : { content: "Recorded fresh occurrence evidence." });
    const created = await f.run(["schedule", "series", "add", task.id, "--at", "2020-01-01T09:00:00Z", "--every", "1m", "--count", "1", "--json"]);
    expect(created.code, created.stderr + created.stdout).toBe(0);
    const id = JSON.parse(created.stdout).series[0].id;
    const before = provider.counts().actors;
    finish = true;
    const clock = String(Date.parse("2020-01-01T09:00:00Z"));
    const failedHost = host(f, { FX_E2E_SCHEDULE_CLOCK_MS: clock, FX_E2E_FOSSIL_FAULT: point });
    const held: any = await until(() => failedHost.request("schedule.series", { action: "show", id }), (snapshot: any) => snapshot.series[0]?.active_occurrence != null);
    const occurrence = held.series[0].active_occurrence.id;
    await failedHost.close(); clients.splice(clients.indexOf(failedHost), 1);
    expect(provider.counts().actors).toBe(before);
    const recoveredHost = host(f, { FX_E2E_SCHEDULE_CLOCK_MS: clock, FX_E2E_FOSSIL_FAULT: undefined });
    const final: any = await until(() => recoveredHost.request("schedule.series", { action: "show", id }), (snapshot: any) => snapshot.series[0]?.state === "completed");
    expect(final.series[0].materialized_count).toBe(1);
    expect(final.occurrences).toHaveLength(1);
    expect(final.occurrences[0].id).toBe(occurrence);
    expect(final.occurrences[0].outcome).toBe("completed");
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks).toHaveLength(2);
    expect(provider.counts().actors - before).toBe(2);
  }, 120000);
}
