import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { cleanupFixtures, fixture, model, writeMemory } from "./fossil-workspace-helpers";

afterEach(cleanupFixtures);

// Profile routine workspace and coding flows; recovery cases have their own verification owner.
describe("portable Fossil agent workspace", () => {
  test("a progress finalize decision still passes the independent completion gate", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (body, count) => !body.tools?.length ? { content: "This is an omos agent workspace." } : {
      tool_calls: [{ index: 0, id: `inspect-${count}`, type: "function", function: { name: "fossil_workspace", arguments: JSON.stringify({ action: "read", path: "workspace.json" }) } }],
    }, undefined, { progress: () => ({ outcome: "finalize", meaningful: false, evidence: [], remaining: ["request_complete"], note: "The actor has enough information to answer" }) });
    const result = await f.run(["ask", "Identify the workspace kind", "--json"], {}, 120000);
    expect(result.code, result.stderr).toBe(0);
    expect(m.counts()).toEqual({ actors: 5, assessments: 1 });
    expect(JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0].state).toBe("accepted");
  }, 120000);

  test("pins a coding plan and validates the final source before publication", async () => {
    const f = fixture();
    writeFileSync(join(f.cwd, ".gitignore"), "omos.fossil\n");
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const commands = ["printf 'verified\\n' > answer.txt", "test \"$(cat answer.txt)\" = verified"];
    const m = model(f, (_body, count) => count <= 2 ? {
      tool_calls: [{ index: 0, id: `coding-${count}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: commands[count - 1], timeout_ms: 10000 } }) } }],
    } : { content: "Created answer.txt with verified and ran the content check successfully." }, undefined, { plan: { capability: "coding_task", summary: "Create and check answer.txt", obligations: [], checks: [commands[1]] } });
    const result = await f.run(["ask", "Implement answer.txt containing verified and test its contents", "--json"], {}, 120000);
    expect(result.code, result.stderr + result.stdout).toBe(0);
    expect(readFileSync(join(f.cwd, "answer.txt"), "utf8")).toBe("verified\n");
    expect(m.counts()).toEqual({ actors: 3, assessments: 1 });
    const task = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(task.model_basis.capability).toBe("coding_task");
    expect(task.definition.obligations.map((o: any) => o.id)).toEqual(["request_complete", "coding_validation", "coding_summary"]);
    expect(task.state).toBe("accepted");
  }, 120000);

  test("initializes, binds across directories, verifies and exports without overwriting", async () => {
    const f = fixture();
    const initialized = await f.run(["fossil", "init", "--json"]);
    expect(initialized.code, initialized.stderr).toBe(0);
    expect(initialized.stderr).toBe("");
    const first = JSON.parse(initialized.stdout);
    expect(first.repository).toBe(join(f.cwd, "omos.fossil"));
    const other = await runFx(["fossil", "status", "--json"], { cwd: f.home, env: f.env });
    expect(JSON.parse(other.stdout).workspace_id).toBe(first.workspace_id);
    expect((await f.run(["fossil", "verify"])).code).toBe(0);
    const destination = join(f.home, "portable.fossil");
    expect((await f.run(["fossil", "export", destination, "--json"])).code).toBe(0);
    expect((await f.run(["fossil", "export", destination, "--json"])).code).toBe(1);
    expect((await f.run(["fossil", "use", destination, "--json"])).code).toBe(0);
    expect((await f.run(["fossil", "init", destination, "--json"])).code).toBe(1);
    expect(f.fossil("settings", "autosync", "--value").trim()).toBe("off");
  }, 30000);

  test("keeps task content on a branch until reviewed and automatically publishes it", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    const m = model(f, (_body, count) => count === 1 ? writeMemory("Prefer concise answers.") : { content: "Saved and verified the preference." });
    const result = await f.run(["ask", "Remember that I prefer concise answers", "--json"]);
    expect(result.code).toBe(0);
    expect(result.stderr).not.toContain("fx:");
    const status = JSON.parse((await f.run(["fossil", "status", "--json"])).stdout);
    expect(status.tasks).toHaveLength(1);
    expect(status.tasks[0].state).toBe("accepted");
    expect(status.tasks[0].branch).toStartWith("task/");
    expect(m.counts()).toEqual({ actors: 2, assessments: 1 });
    expect(m.packets[0].contract.id).toBe(status.tasks[0].id);
    expect(m.packets[0].evidence.some((entry: any) => entry.tool === "fossil_workspace" && entry.status === "success")).toBe(true);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Prefer concise answers.");
    expect(f.fossil("ls", "-r", "trunk")).toContain("acceptances/");
    const expectedFiles = f.fossil("ls", "-r", "trunk").trim().split("\n");
    const inventoryHelper = join(f.home, "manifest-inventory-helper.py");
    const realFossil = Bun.which("fossil")!;
    writeFileSync(inventoryHelper, `#!/usr/bin/env python3\nimport os, sys\nif 'ls' in sys.argv[1:]:\n    sys.stderr.write('Inventory must not compute commit ages\\n')\n    sys.exit(97)\nos.execv(${JSON.stringify(realFossil)}, [${JSON.stringify(realFossil)}, *sys.argv[1:]])\n`);
    chmodSync(inventoryHelper, 0o755);
    const manifestStatus = await f.run(["fossil", "status", "--json"], { OMOS_FOSSIL_BIN: inventoryHelper });
    expect(manifestStatus.code, manifestStatus.stderr).toBe(0);
    expect(JSON.parse(manifestStatus.stdout).files).toEqual(expectedFiles);
    expect(status.pending_journals).toBe(0);
    const raw = fixture();
    const rawCopy = join(raw.home, "direct-copy.fossil");
    copyFileSync(join(f.cwd, "omos.fossil"), rawCopy);
    expect((await raw.run(["fossil", "use", rawCopy])).code).toBe(0);
    const reconstructed = JSON.parse((await raw.run(["fossil", "tasks", "--json"])).stdout);
    expect(reconstructed.tasks[0].id).toBe(status.tasks[0].id);
    expect(reconstructed.tasks[0].state).toBe("accepted");
    expect(existsSync(join(raw.home, ".fx", "settings.json"))).toBe(false);
    const portable = join(f.home, "task-export.fossil");
    expect((await f.run(["fossil", "export", portable])).code).toBe(0);
    const cold = fixture();
    expect((await cold.run(["fossil", "use", portable])).code).toBe(0);
    const reopened = JSON.parse((await cold.run(["fossil", "tasks", "--json"])).stdout);
    expect(reopened.tasks[0].id).toBe(status.tasks[0].id);
    expect(reopened.tasks[0].state).toBe("accepted");
  }, 60000);

  test("verified children publish to their parent before the root publishes to trunk", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let roots = 0, children = 0;
    const m = model(f, body => {
      const root = body.tools?.some((tool: any) => tool.function?.name === "subagent");
      if (root) {
        if (++roots === 1) return { tool_calls: [{ index: 0, id: "delegate", type: "function", function: { name: "subagent", arguments: JSON.stringify({ request: { action: "run", task: "task-FOSSIL-CHILD: save the child preference" } }) } }] };
        return { content: "The child preference is saved and verified." };
      }
      return ++children === 1 ? writeMemory("Verified child preference.") : { content: "Child preference saved." };
    });
    const result = await f.run(["ask", "Delegate saving a child preference", "--json"], {}, 90000);
    expect(result.code, result.stderr).toBe(0);
    const status = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout);
    expect(status.tasks).toHaveLength(2);
    const root = status.tasks.find((task: any) => task.parent === "trunk");
    const child = status.tasks.find((task: any) => task.parent !== "trunk");
    expect(child.parent).toBe(root.branch);
    expect(child.parent_contract_version).toBe(root.definition.version);
    expect(status.tasks.every((task: any) => task.state === "accepted")).toBe(true);
    expect(m.packets.length).toBeGreaterThanOrEqual(2);
    expect(f.fossil("cat", "memory/preference.md", "-r", "trunk")).toBe("Verified child preference.");
  }, 90000);

  test("blocked work resumes the same task with a versioned user amendment", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let blocked = true;
    const m = model(f, () => ({ content: blocked ? "Need the requested detail." : "Answered with the supplied detail." }), () => blocked ? "blocked" : "met");
    const first = await f.run(["ask", "Answer after I supply a detail", "--json"]);
    expect(first.code).toBe(1);
    const session = JSON.parse(first.stdout).session_id;
    const before = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    blocked = false;
    expect((await f.run(["ask", "--resume-id", session, "The detail is blue", "--json"])).code).toBe(0);
    const after = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(after.id).toBe(before.id);
    expect(after.branch).toBe(before.branch);
    expect(after.definition.version).toBe(2);
    expect(m.packets.at(-1).contract.objective).toBe("Answer after I supply a detail");
    expect(m.packets.at(-1).userSteering).toContain("The detail is blue");
  }, 60000);

  test("a user update revises affected obligations and preserves the remaining contract", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let blocked = true;
    const update = "Explain the HTML format instead of PDF. Keep the source comparison.";
    const m = model(f, () => ({ content: blocked ? "Waiting for the requested format choice." : "HTML uses markup and keeps the original source comparison." }), () => blocked ? "blocked" : "met", {
      plan: { capability: "general_task", summary: "Explain the format and compare sources", obligations: [{ id: "format", description: "Explain the PDF format" }, { id: "sources", description: "Compare the original sources" }], checks: [] },
      revise: () => ({ capability: "general_task", summary: "The user replaced the PDF explanation with HTML", obligations: [{ id: "format", description: "Explain the HTML format" }], checks: [], superseded: ["format"] }),
    });
    const first = await f.run(["ask", "Explain PDF and compare the original sources after I confirm the format", "--json"]);
    expect(first.code, first.stderr).toBe(1);
    const session = JSON.parse(first.stdout).session_id;
    const before = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect((await f.run(["ask", "--resume-id", session, "continue", "--json"])).code).toBe(1);
    expect(m.revisionPackets).toHaveLength(0);
    blocked = false;
    const result = await f.run(["ask", "--resume-id", session, update, "--json"]);
    expect(result.code, result.stderr + result.stdout).toBe(0);
    const after = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(after.id).toBe(before.id);
    expect(after.definition.version).toBe(before.definition.version + 1);
    expect(after.revision_pending).toBe(false);
    expect(after.planned_amendments).toBe(1);
    expect(after.definition.obligations).toEqual([
      before.definition.obligations[0], { id: "sources", description: "Compare the original sources" }, { id: "format", description: "Explain the HTML format" },
    ]);
    expect(m.revisionPackets).toHaveLength(1);
    expect(m.revisionPackets[0].context.pendingAmendments).toEqual([update]);
    expect(m.packets.at(-1).contract.version).toBe(after.definition.version);
    const history = f.fossil("ls", "-r", after.branch).split("\n").filter(path => path.startsWith(`history/${after.id}/`)).map(path => JSON.parse(f.fossil("cat", path, "-r", after.branch)));
    const revision = history.find(row => row.kind === "contract_revision");
    expect(revision.value.previous_contract.obligations.find((o: any) => o.id === "format").description).toBe("Explain the PDF format");
    expect(revision.value.superseded).toEqual(["format"]);
    expect(revision.value.amendments).toEqual([update]);
  }, 120000);

  test("an invalid revision pauses before the actor and can resume from the retained user update", async () => {
    const f = fixture();
    expect((await f.run(["fossil", "init"])).code).toBe(0);
    let blocked = true, valid = false;
    const m = model(f, () => ({ content: blocked ? "Waiting for detail." : "Explained the changed detail." }), () => blocked ? "blocked" : "met", {
      plan: { capability: "general_task", summary: "Explain the requested detail", obligations: [{ id: "detail", description: "Explain the initial detail" }], checks: [] },
      revise: () => ({ capability: "general_task", summary: "Apply the user's changed detail", obligations: [{ id: "detail", description: "Explain the changed detail" }], checks: [], superseded: valid ? ["detail"] : [] }),
    });
    const first = await f.run(["ask", "Explain a detail after I provide it", "--json"]);
    const session = JSON.parse(first.stdout).session_id;
    blocked = false;
    const invalid = await f.run(["ask", "--resume-id", session, "The detail has changed", "--json"]);
    expect(invalid.code, invalid.stderr).toBe(1);
    expect(m.counts().actors).toBe(1);
    expect(m.revisionPackets).toHaveLength(8);
    const pending = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(pending.revision_pending).toBe(true);
    expect(pending.definition.obligations.find((o: any) => o.id === "detail").description).toBe("Explain the initial detail");
    valid = true;
    const resumed = await f.run(["ask", "--resume-id", session, "continue", "--json"]);
    expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
    expect(m.revisionPackets).toHaveLength(9);
    const after = JSON.parse((await f.run(["fossil", "tasks", "--json"])).stdout).tasks[0];
    expect(after.definition.version).toBe(pending.definition.version);
    expect(after.revision_pending).toBe(false);
  }, 120000);

});


test("follow-up planning retains the referenced specification and repository validation context", async () => {
  const f = fixture();
  const spec = "Each weekly recurrence creates a fresh work contract and preserves occurrence evidence.";
  const validation = "test -s schedule.txt";
  writeFileSync(join(f.cwd, "AGENTS.md"), `Validate fixture source changes with ${validation}.`);
  const plans: any[] = [];
  const commands = ["printf 'recurring\\n' > schedule.txt", validation];
  const m = model(f, (_body, count) => count === 1 ? { content: spec } : count <= 3 ? {
    tool_calls: [{ index: 0, id: `implement-${count}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ request: { action: "run", command: commands[count - 2], timeout_ms: 10000 } }) } }],
  } : { content: "Implemented schedule.txt and verified it with the repository check." }, undefined, {
    plan(packet) {
      plans.push(packet);
      return packet.context.originalRequest === "Implement the feature" ? { capability: "coding_task", summary: "Implement the referenced weekly scheduling specification", obligations: [{ id: "weekly_contracts", description: spec }], checks: [validation] } : { capability: "general_task", summary: "Write the requested specification", obligations: [], checks: [] };
    },
  });
  const first = await f.run(["ask", "Write a specification for recurring tasks", "--json"], {}, 120000);
  expect(first.code, first.stderr).toBe(0);
  const session = JSON.parse(first.stdout).session_id;
  const second = await f.run(["ask", "--resume-id", session, "Implement the feature", "--json"], {}, 120000);
  expect(second.code, second.stderr + second.stdout).toBe(0);
  expect(m.counts().actors).toBe(4);
  expect(plans).toHaveLength(2);
  expect(plans[1].context.referenceConversation.messages.some((message: any) => message.role === "assistant" && message.text === spec)).toBe(true);
  expect(plans[1].context.rootUserContext).toContain("Write a specification for recurring tasks");
  expect(plans[1].context.repositoryContext).toContain(validation);
  expect(plans[1].context.workspaceRoot).toBe(f.cwd);
  expect(readFileSync(join(f.cwd, "schedule.txt"), "utf8")).toBe("recurring\n");
}, 120000);
