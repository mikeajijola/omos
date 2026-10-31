import { expect } from "bun:test";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";

const homes: string[] = [];
const servers: ReturnType<typeof Bun.serve>[] = [];
export function cleanupFixtures() {
  for (const server of servers.splice(0)) server.stop(true);
  for (const home of homes.splice(0)) cleanupIsolatedTestHome(home);
}

export function fixture() {
  const home = realpathSync(createIsolatedTestHome());
  homes.push(home);
  const cwd = join(home, "project");
  mkdirSync(cwd);
  mkdirSync(join(home, ".fx"));
  const env = {
    FX_TRACE_LOG: join(home, "fossil.trace"), FX_TRACE_SCOPES: "workspace",
    HOME: home, FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1", FX_CONTRACT_REVIEW: "1", FX_E2E_FOSSIL_FAULT: undefined,
    AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined, GEMINI_API_KEY: undefined,
    OMOS_CLASSIFIER_URL: undefined, OMOS_CLASSIFIER_TOKEN: undefined, OMOS_CLASSIFIER_MODEL: undefined,
    FX_PROVIDER: undefined, FX_MODEL: undefined, FX_REVIEW_MODEL: undefined, OMOS_FOSSIL_BIN: undefined,
  };
  const run = async (args: string[], extra: Record<string, string | undefined> = {}, timeoutMs = 60000) => {
    const result = await runFx(args, { cwd, env: { ...env, ...extra }, timeoutMs });
    if (result.code !== 0 && existsSync(env.FX_TRACE_LOG)) result.stderr += "\n" + readFileSync(env.FX_TRACE_LOG, "utf8");
    return result;
  };
  const fossil = (...args: string[]) => {
    const result = spawnSync("fossil", [...args, "-R", join(cwd, "omos.fossil")], { env: { PATH: process.env.PATH, HOME: home, FOSSIL_HOME: home, XDG_CONFIG_HOME: home, USER: "fixture", LC_ALL: "C" }, encoding: "utf8" });
    expect(result.status, result.stderr + result.stdout).toBe(0);
    return result.stdout;
  };
  return { home, cwd, env, run, fossil };
}

export function model(f: ReturnType<typeof fixture>, actor: (body: any, count: number, signal?: AbortSignal) => object | Promise<object>, assess?: (packet: any) => string | { name: string; args: object } | Promise<string | { name: string; args: object }>, governance: { reply?: (body: any, packet: any, phase: "plan" | "revise" | "progress") => object | undefined; plan?: object | ((packet: any) => object | Promise<object>); revise?: (packet: any) => object; progress?: (packet: any) => object; usage?: { prompt_tokens: number; completion_tokens: number; total_tokens: number } } = {}) {
  let actors = 0, assessments = 0;
  const packets: any[] = [];
  const revisionPackets: any[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      if (request.method !== "POST") return Response.json({ data: [] });
      const body = await request.json() as any;
      let delta: any, reason = "stop";
      if (body.tools?.some((tool: any) => tool.function?.name === "omos_task_plan" || tool.function?.name === "omos_progress_assessment" || tool.function?.name === "omos_contract_revision")) {
        const planning = body.tools.some((tool: any) => tool.function?.name === "omos_task_plan");
        const revising = body.tools.some((tool: any) => tool.function?.name === "omos_contract_revision");
        const packet = JSON.parse(body.messages.find((message: any) => message.role === "user").content);
        if (revising) revisionPackets.push(packet);
        const decision = planning ? (typeof governance.plan === "function" ? await governance.plan(packet) : governance.plan) ?? { capability: "general_task", summary: "Answer the original request", obligations: [], checks: [] }
          : revising ? governance.revise?.(packet) ?? { capability: packet.context.model.basis?.capability ?? "general_task", summary: "Retain requirements with the supplied clarification", obligations: [], checks: [], superseded: [] }
          : governance.progress?.(packet) ?? { outcome: "continue_work", meaningful: false, evidence: [], remaining: packet.context.contract.obligations.map((o: any) => o.id), note: "No further useful progress observed" };
        delta = governance.reply?.(body, packet, planning ? "plan" : revising ? "revise" : "progress") ?? { tool_calls: [{ index: 0, id: `governance-${actors}`, type: "function", function: { name: planning ? "omos_task_plan" : revising ? "omos_contract_revision" : "omos_progress_assessment", arguments: JSON.stringify(decision) } }] };
        reason = "tool_calls";
      } else if (body.tools?.some((tool: any) => tool.function?.name === "omos_contract_assessment")) {
        assessments++;
        const packet = JSON.parse(body.messages.find((message: any) => message.role === "user").content);
        packet.currentInspections = body.messages.filter((message: any) => message.role === "tool").map((message: any) => JSON.parse(message.content));
        packet.inspections = [...(packet.previousInspections ?? []), ...packet.currentInspections];
        packets.push(packet);
        const status = await assess?.(packet) ?? "met";
        const evidence = packet.evidence.filter((item: any) => item.complete && (item.kind === "candidate" || item.status === "success")).map((item: any) => item.id);
        delta = { tool_calls: [{ index: 0, id: `assessment-${assessments}`, type: "function", function: {
          name: typeof status === "string" ? "omos_contract_assessment" : status.name, arguments: JSON.stringify(typeof status === "string" ? { contractId: packet.contract.id, version: packet.contract.version, obligations: packet.contract.obligations.map((o: any) => ({ id: o.id, status, evidence: status === "met" ? evidence : [], note: status === "blocked" ? "Waiting for requested input" : "Checked host evidence" })) } : status.args),
        } }] };
        reason = "tool_calls";
      } else {
        delta = await actor(body, ++actors, request.signal);
        if ((delta as any).tool_calls) reason = "tool_calls";
      }
      const chunks: object[] = [
        { id: "fossil-fixture", model: body.model, choices: [{ index: 0, delta, finish_reason: null }] },
        { id: "fossil-fixture", model: body.model, choices: [{ index: 0, delta: {}, finish_reason: reason }] },
      ];
      if (governance.usage) chunks.push({ id: "fossil-fixture", model: body.model, choices: [], usage: governance.usage });
      return new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
    },
  });
  servers.push(server);
  writeFileSync(join(f.home, ".fx", "settings.json"), JSON.stringify({
    provider: "local", models: { local: "fixture-model" }, permission_mode: "full-access", auto_upgrade: false, session_titles: false,
    providers: { local: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${server.port}/v1`, auth: { type: "none" }, model_metadata: { "fixture-model": { supports_tool_use: true, context_window: 262144, max_output_tokens: 8192 } } } },
  }));
  return { packets, revisionPackets, counts: () => ({ actors, assessments }) };
}

export function writeMemory(content: string) {
  return { tool_calls: [{ index: 0, id: "save-memory", type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "write", path: "memory/preference.md", content }) } }] };
}

export async function startWorkspaceService(f: ReturnType<typeof fixture>, writable = false, extra: Record<string, string | undefined> = {}) {
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
