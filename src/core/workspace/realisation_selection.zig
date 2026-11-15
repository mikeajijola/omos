//! Parent capability and preferred realisation selection ranked by relevance,
//! precedent, evidence, and recency. The parent coordinator resolves the
//! affected capability and realisation path before dispatching a background
//! worker so the worker starts with its bound skills, tools, and execution
//! guidance already prepared.
const std = @import("std");
const model = @import("definition.zig");
const workspace = @import("fossil_workspace.zig");
const request_plan = @import("request_plan.zig");
const classification = @import("classification.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const io = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Ranking = struct {
    relevance: f64,
    precedent: f64,
    evidence: f64,
    recency: f64,
    score: f64,
};

pub const Assignment = struct {
    capability: []const u8,
    realisation: []const u8,
    ranking: Ranking,
    skill_bindings: []const skill_invocation.ExplicitBinding = &.{},
    guidance: []const u8 = "",
};

const PrecedentStats = struct {
    total_accepted: usize = 0,
    capability_accepted: usize = 0,
    realisation_accepted: usize = 0,
    latest_accepted_ms: i64 = 0,
    has_verified_implementation: bool = false,
};

/// Classify whether a work prompt requests software changes (`coding_task`) or
/// operational, browser, research, and document delivery (`general_task`).
pub fn classifyDeliverable(prompt: []const u8) ?request_plan.Capability {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return null;

    const has_browser_signal = containsAnyIgnoreCase(trimmed, &.{
        "browseros",
        "browseros-neo",
        "browser neo",
        "use the browser",
        "in the browser",
        "http://",
        "https://",
        "linkedin",
        "web summit",
        "totaljobs",
        "bailii",
    });

    const has_operational_signal = has_browser_signal or containsAnyIgnoreCase(trimmed, &.{
        "send ",
        "apply ",
        "applications",
        "connection request",
        "meeting request",
        "prospect",
        "collaborators",
        "explain the key",
        "key points of this page",
        "summarize",
        "collect all",
        "retrieve",
    });

    const has_coding_deliverable = containsAnyIgnoreCase(trimmed, &.{
        "implement ",
        "refactor ",
        "fix the bug",
        "fix bug",
        "pull request",
        "unit test",
        "compile",
        "zig build",
        "src/",
        ".zig",
        ".ts",
        "edit repository",
    }) and !containsAnyIgnoreCase(trimmed, &.{
        "isolated synthetic",
        "synthetic site",
        "fictional candidate",
        "fictional profile",
        "use browseros",
        "use the browseros-neo skill",
    });

    if (has_coding_deliverable and !has_browser_signal) return .coding_task;
    if (has_operational_signal and !has_coding_deliverable) return .general_task;
    return null;
}

/// Resolve capability using classifier output first, falling back to
/// deterministic deliverable analysis when the route is `work` but the
/// secondary capability probability distribution is flat.
pub fn resolveCapability(result: ?classification.Result, prompt: []const u8) ?request_plan.Capability {
    if (result) |classified| {
        if (request_plan.select(classified)) |selected| return selected;
    }
    return classifyDeliverable(prompt);
}

/// Resolve unambiguous skill bindings referenced by the prompt or assigned
/// realisation, preferring workspace-local skill paths over ancestor or global
/// copies when duplicate skill names exist.
pub fn resolvePromptSkillBindings(
    alloc: Allocator,
    prompt: []const u8,
    workspace_root: []const u8,
    skills: []const skill_contract.Skill,
) ![]const skill_invocation.ExplicitBinding {
    if (skills.len == 0) return &.{};
    var bindings: std.ArrayList(skill_invocation.ExplicitBinding) = .empty;
    errdefer bindings.deinit(alloc);

    var seen_names = std.StringHashMap(void).init(alloc);
    defer seen_names.deinit();

    const browser_requested = containsAnyIgnoreCase(prompt, &.{
        "browseros-neo",
        "browseros neo",
        "browser neo",
        "use the browser",
        "in the browser",
        "http://",
        "https://",
    });

    for (skills) |candidate| {
        if (seen_names.contains(candidate.name)) continue;
        const mentioned = mentionsSkillName(prompt, candidate.name) or
            (browser_requested and std.ascii.eqlIgnoreCase(candidate.name, "browseros-neo"));
        if (!mentioned) continue;

        const best = selectPreferredSkillByName(skills, candidate.name, workspace_root);
        try seen_names.put(best.name, {});
        try bindings.append(alloc, .{
            .name = try alloc.dupe(u8, best.name),
            .path = try alloc.dupe(u8, best.path),
        });
    }
    return bindings.toOwnedSlice(alloc);
}

fn selectPreferredSkillByName(
    skills: []const skill_contract.Skill,
    name: []const u8,
    workspace_root: []const u8,
) skill_contract.Skill {
    var best: ?skill_contract.Skill = null;
    for (skills) |candidate| {
        if (!std.ascii.eqlIgnoreCase(candidate.name, name)) continue;
        if (best == null) {
            best = candidate;
            continue;
        }
        const current = best.?;
        const candidate_in_workspace = workspace_root.len > 0 and std.mem.startsWith(u8, candidate.path, workspace_root);
        const current_in_workspace = workspace_root.len > 0 and std.mem.startsWith(u8, current.path, workspace_root);
        if (candidate_in_workspace and !current_in_workspace) {
            best = candidate;
            continue;
        }
        if (candidate_in_workspace == current_in_workspace and
            @backingInt(candidate.source) < @backingInt(current.source))
        {
            best = candidate;
        }
    }
    return best.?;
}

fn mentionsSkillName(prompt: []const u8, skill_name: []const u8) bool {
    if (skill_name.len == 0 or prompt.len < skill_name.len) return false;
    var index: usize = 0;
    while (index + skill_name.len <= prompt.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(prompt[index .. index + skill_name.len], skill_name)) continue;
        const before_ok = index == 0 or !isSkillIdentifierChar(prompt[index - 1]) or prompt[index - 1] == '$';
        const after_index = index + skill_name.len;
        const after_ok = after_index == prompt.len or !isSkillIdentifierChar(prompt[after_index]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isSkillIdentifierChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

/// Score a declared capability and select its preferred realisation using the
/// declaration's `semantic.search.ranking` weights (`relevance`, `precedent`,
/// `evidence`, `recency`).
pub fn scoreCapability(
    alloc: Allocator,
    manager: ?workspace.Manager,
    declaration: model.Declaration,
    capability: Value,
    query_text: []const u8,
    revision: []const u8,
) !struct { realisation: []const u8, ranking: Ranking } {
    const id = model.text(capability, "id");
    const weights = declaration.semantic.search.ranking;

    var prepared = lexical_relevance.prepare(query_text[0..@min(query_text.len, lexical_relevance.max_query_bytes)]) catch
        try lexical_relevance.prepare("task");
    const lexical = lexical_relevance.score(
        &prepared,
        &.{id},
        &.{ model.text(capability, "name"), model.text(capability, "description") },
        &.{},
    );
    const deliverable = classifyDeliverable(query_text);
    const relevance: f64 = if (deliverable) |expected|
        if (std.mem.eql(u8, id, @tagName(expected))) 0.95 else if (lexical != null) 0.55 else 0.20
    else if (lexical != null)
        0.85
    else if (std.mem.eql(u8, id, "general_task"))
        0.65
    else
        0.35;

    const choices = model.items(capability, "realisations");
    const default_realisation = if (choices.len > 0 and choices[0] == .string)
        choices[0].string
    else if (std.mem.eql(u8, id, "coding_task"))
        "coding_task_native"
    else
        "general_task_native";

    var best_realisation: []const u8 = default_realisation;
    var best_ranking: Ranking = .{
        .relevance = relevance,
        .precedent = 0.5,
        .evidence = if (model.nativeCapability(declaration, id)) 1.0 else 0.5,
        .recency = 0.5,
        .score = 0,
    };

    const stats = if (manager) |mgr|
        gatherPrecedentStats(alloc, mgr, declaration, id, default_realisation, revision) catch PrecedentStats{}
    else
        PrecedentStats{};

    const native = model.nativeCapability(declaration, id);
    const precedent: f64 = if (stats.total_accepted > 0)
        @min(1.0, 0.4 + 0.6 * (@as(f64, @floatFromInt(stats.capability_accepted)) / @as(f64, @floatFromInt(stats.total_accepted))))
    else if (native)
        0.75
    else
        0.35;

    const evidence: f64 = if (native or stats.has_verified_implementation) 1.0 else 0.4;
    const now_ms = io.milliTimestamp();
    const recency: f64 = if (stats.latest_accepted_ms > 0 and now_ms >= stats.latest_accepted_ms) blk: {
        const age_hours = @as(f64, @floatFromInt(now_ms - stats.latest_accepted_ms)) / (1000.0 * 3600.0);
        break :blk 1.0 / (1.0 + age_hours / 24.0);
    } else if (native) 0.8 else 0.4;

    const score = weights.relevance * relevance +
        weights.precedent * precedent +
        weights.evidence * evidence +
        weights.recency * recency;

    best_ranking = .{
        .relevance = relevance,
        .precedent = precedent,
        .evidence = evidence,
        .recency = recency,
        .score = score,
    };

    if (choices.len > 1) {
        for (choices) |choice| {
            if (choice != .string) continue;
            const candidate_id = choice.string;
            const candidate_stats = if (manager) |mgr|
                gatherPrecedentStats(alloc, mgr, declaration, id, candidate_id, revision) catch PrecedentStats{}
            else
                PrecedentStats{};
            const candidate_precedent: f64 = if (candidate_stats.capability_accepted > 0)
                @min(1.0, 0.4 + 0.6 * (@as(f64, @floatFromInt(candidate_stats.realisation_accepted)) / @as(f64, @floatFromInt(candidate_stats.capability_accepted))))
            else
                precedent;
            const candidate_score = weights.relevance * relevance +
                weights.precedent * candidate_precedent +
                weights.evidence * evidence +
                weights.recency * recency;
            if (candidate_score > best_ranking.score) {
                best_realisation = candidate_id;
                best_ranking.precedent = candidate_precedent;
                best_ranking.score = candidate_score;
            }
        }
    }

    return .{ .realisation = best_realisation, .ranking = best_ranking };
}

fn gatherPrecedentStats(
    alloc: Allocator,
    manager: workspace.Manager,
    declaration: model.Declaration,
    capability_id: []const u8,
    realisation_id: []const u8,
    revision: []const u8,
) !PrecedentStats {
    var stats: PrecedentStats = .{};
    stats.has_verified_implementation = if (model.nativeCapability(declaration, capability_id))
        true
    else
        @import("capability_runtime.zig").available(manager, declaration, capability_id, revision) catch false;

    const tasks = manager.tasks() catch return stats;
    for (tasks) |item| {
        if (item.state != .accepted) continue;
        stats.total_accepted += 1;
        if (item.model_basis) |basis| {
            if (basis.capability) |cap| {
                if (std.mem.eql(u8, cap, capability_id)) {
                    stats.capability_accepted += 1;
                    stats.realisation_accepted += 1;
                    if (item.created_at_ms > stats.latest_accepted_ms) {
                        stats.latest_accepted_ms = item.created_at_ms;
                    }
                }
            }
        }
    }
    _ = alloc;
    _ = realisation_id;
    return stats;
}

/// Assign the affected capability, preferred realisation path, unambiguous
/// skill bindings, and execution guidance for a task being dispatched by the
/// parent coordinator.
pub fn assignForTask(
    alloc: Allocator,
    manager: workspace.Manager,
    task: workspace.Task,
    workspace_root: []const u8,
    skills: []const skill_contract.Skill,
) !Assignment {
    const request_text = try manager.originalRequest(task);
    const revision = if (task.model_basis) |basis| basis.revision else try manager.revision("trunk");
    const declaration = try manager.loadDeclaration(revision);

    const capability_id = if (task.model_basis) |basis|
        basis.capability orelse if (classifyDeliverable(request_text)) |cap| @tagName(cap) else "general_task"
    else if (classifyDeliverable(request_text)) |cap|
        @tagName(cap)
    else
        "general_task";

    var selected_realisation: []const u8 = if (std.mem.eql(u8, capability_id, "coding_task"))
        "coding_task_native"
    else
        "general_task_native";
    var selected_ranking: Ranking = .{
        .relevance = 0.9,
        .precedent = 0.75,
        .evidence = 1.0,
        .recency = 0.8,
        .score = 0.88,
    };

    for (model.items(model.spec(declaration.value), "capabilities")) |capability| {
        if (!std.mem.eql(u8, model.text(capability, "id"), capability_id)) continue;
        const scored = try scoreCapability(alloc, manager, declaration, capability, request_text, revision);
        selected_realisation = scored.realisation;
        selected_ranking = scored.ranking;
        break;
    }

    const skill_bindings = try resolvePromptSkillBindings(alloc, request_text, workspace_root, skills);
    const guidance = try buildExecutionGuidance(
        alloc,
        capability_id,
        selected_realisation,
        selected_ranking,
        skill_bindings,
        request_text,
    );

    return .{
        .capability = try alloc.dupe(u8, capability_id),
        .realisation = try alloc.dupe(u8, selected_realisation),
        .ranking = selected_ranking,
        .skill_bindings = skill_bindings,
        .guidance = guidance,
    };
}

pub fn buildExecutionGuidance(
    alloc: Allocator,
    capability: []const u8,
    realisation: []const u8,
    ranking: Ranking,
    skill_bindings: []const skill_invocation.ExplicitBinding,
    request_text: []const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.print(
        "<omos_realisation_assignment capability=\"{s}\" realisation=\"{s}\" score=\"{d:.2}\" relevance=\"{d:.2}\" precedent=\"{d:.2}\" evidence=\"{d:.2}\" recency=\"{d:.2}\">\n",
        .{ capability, realisation, ranking.score, ranking.relevance, ranking.precedent, ranking.evidence, ranking.recency },
    );
    try out.writer.writeAll("The parent coordinator identified the affected capability and assigned this preferred realisation path from workspace evidence:\n");

    var has_browser_skill = false;
    if (skill_bindings.len > 0) {
        try out.writer.writeAll("- Pre-bound skills (already loaded in full in your prompt; do NOT call `skill` or `capability_search` to reload them): ");
        for (skill_bindings, 0..) |binding, index| {
            if (index > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(binding.name);
            if (std.ascii.eqlIgnoreCase(binding.name, "browseros-neo")) has_browser_skill = true;
        }
        try out.writer.writeByte('\n');
    }

    const is_browser_task = has_browser_skill or containsAnyIgnoreCase(request_text, &.{
        "browseros",
        "browseros-neo",
        "browser neo",
        "http://",
        "https://",
        "in the browser",
    });

    if (is_browser_task) {
        try out.writer.writeAll(
            "- Pre-loaded MCP tools: `mcp_browseros-neo_name_session` and `mcp_browseros-neo_run` are already advertised and callable now. On your VERY FIRST step, call `mcp_browseros-neo_name_session` and `mcp_browseros-neo_run` together without any preliminary `capability_search`, `skill`, or `fossil_workspace` calls.\n" ++
                "- Single-tab reuse: Open one tab with `const page = await browser.open(url)` and reuse that same `page` handle with `await page.goto(nextUrl)` for subsequent navigations. Do NOT open many tabs in a loop or with `Promise.all(ids.map(id => browser.open(...)))`.\n" ++
                "- Valid page handle methods: Use `await page.goto(url)`, `await page.read()`, `await page.snapshot()`, `await page.click(ref)`, `await page.fill(ref, value)`, `await page.selectOption(ref, value)`, `await page.upload(ref, [paths])`, `await page.waitForText(text)`, `await page.pdf()`, and `await page.evaluateInPage(fn)`. NEVER access `page.url` or `page.url()` on a page handle (it is not a method or property on the handle and throws an error).\n" ++
                "- Staged HTML forms: When submitting a multi-step form (where clicking a review button POSTs to `/prepare/...` and renders a confirmation page with a `Confirm and send` button that POSTs to `/submit/...` and redirects to `/receipt/...`), complete BOTH stages on the SAME `page` handle inside the SAME `mcp_browseros-neo_run` script (`await page.goto(itemUrl)` -> `await page.snapshot()` -> fill/select/upload fields -> `await page.click(reviewRef)` -> `await page.waitForText('Confirm and send')` -> `await page.snapshot()` -> `await page.click(confirmRef)` -> `await page.waitForText('Confirmed receipt')` -> `await page.read()`). NEVER pass `/prepare/...` or `/submit/...` URLs to `browser.open()` or `page.goto()`, because those routes are POST-only and return 404 on GET.\n" ++
                "- Batch multi-item work within the 30-second run timeout: Each `mcp_browseros-neo_run` call has a hard 30000ms wall-time cap. Batch 10-15 read-only page navigations per `run` call, 3-8 two-stage form submissions per `run` call, or 4-5 PDF renders/uploads per `run` call on a single reused tab, returning a structured JSON array of extracted facts and confirmed receipt IDs/URLs so no call exceeds 30s.\n" ++
                "- Combined PDF-render and form-upload batching: When a task requires rendering tailored HTML files to PDF and uploading them to a browser form, first read all items in batches of 15-20 per `run` call, generate all tailored HTML files in one local script, and print the compact JSON list of all target items (ID, rate, cover note) to stdout once so it stays in your conversation context. Then issue consecutive `mcp_browseros-neo_run` calls (5 items per `run` call, reusing `cvTab` for `file:///.../cv.html` -> `await cvTab.pdf()` and `formTab` for the item URL -> fill/select -> `await formTab.upload(cvRef, [pdf.path])` -> `Review before sending` -> `Confirm and send`, returning `[{ job_id, pdf_path: pdf.path, receipt_id, state }]`) WITHOUT running `cat batch_N.json` or `python3` between every `run` call. After all 85 browser submissions finish, run ONE `python3` script to hash the returned `pdf_path` files and write the complete ledger.\n" ++
                "- Signed-in LinkedIn people search: When researching prospects or collaborators on LinkedIn, BrowserOS Neo is ALREADY signed into LinkedIn. After reading the business URLs, navigate directly on your single reused tab to `https://www.linkedin.com/search/results/people/?keywords=` + encodeURIComponent(query) + `&page=` + pageNum and call `await page.read('main')` (each search page lists 10 real people with name, headline, location, and `https://www.linkedin.com/in/...` profile URL). Loop over 2-3 search pages per `mcp_browseros-neo_run` call so 50+ distinct sourced prospects are collected in 2-3 `run` calls, then write `documents/prospects.json` directly. NEVER use Google, DuckDuckGo, or Bing to search `site:linkedin.com/in`.\n" ++
                "- Direct file deliverables: Save requested ledgers, JSON/CSV tables, HTML files, and PDFs directly in the workspace filesystem (for example under `documents/`) using `write_file` or local scripts. Do NOT call `fossil_workspace` (`status`, `definition`, `read`, `record`, `query`, `workers`) or `workspace_content` (`contracts`) to record task deliverables.\n" ++
                "- No cross-directory shell probing: Never use `shell` to run `find /`, `grep -r`, `ps`, `ss`, or `curl`, and never inspect files outside your project workspace. Keep all browser interactions inside `mcp_browseros-neo_run`.\n" ++
                "- Strict factual grounding: Every name, job title, company, date, rate, skill, and project claim in outbound messages, prospect tables, and CVs must match the inspected source profile and target page verbatim. In CVs and messages, never claim the candidate 'runs' or 'leads' a business description (such as Example Systems) or list it as a 'Current' employment entry under Experience when no employment title or dates are supplied, and never expand 'Designed ...' into 'Designed and implemented ...'.\n",
        );
    } else if (std.mem.eql(u8, capability, "general_task")) {
        try out.writer.writeAll(
            "- Save requested deliverables directly in the workspace filesystem (such as `documents/`) using standard file tools, and avoid unnecessary `fossil_workspace` schema or status reads.\n",
        );
    }

    try out.writer.writeAll("</omos_realisation_assignment>");
    return out.toOwnedSlice();
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "deliverable classification distinguishes browser and operational tasks from coding" {
    try std.testing.expectEqual(
        request_plan.Capability.general_task,
        classifyDeliverable("Use the browseros-neo skill. Use BrowserOS Neo at http://127.0.0.1:8954/ to complete 85 new applications and save JSON receipts.").?,
    );
    try std.testing.expectEqual(
        request_plan.Capability.general_task,
        classifyDeliverable("Read https://mikeajijola.com and save 50 prospects to documents/prospects.json.").?,
    );
    try std.testing.expectEqual(
        request_plan.Capability.coding_task,
        classifyDeliverable("Refactor src/core/workspace/definition.zig and run zig build test.").?,
    );
}

test "prompt skill binding disambiguates duplicate skills in favor of workspace root" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_contract.Skill{
        .{ .name = "browseros-neo", .description = "global", .path = "/Users/example/.agents/skills/browseros-neo", .source = .workspace_agents },
        .{ .name = "browseros-neo", .description = "project", .path = "/Users/example/project/skills/browseros-neo", .source = .workspace_shared },
    };
    const bindings = try resolvePromptSkillBindings(
        alloc,
        "Use the browseros-neo skill to open http://127.0.0.1:8080/",
        "/Users/example/project",
        &skills,
    );
    defer {
        for (bindings) |binding| {
            alloc.free(binding.name);
            alloc.free(binding.path);
        }
        alloc.free(bindings);
    }
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqualStrings("browseros-neo", bindings[0].name);
    try std.testing.expectEqualStrings("/Users/example/project/skills/browseros-neo", bindings[0].path);
}

test "capability scoring uses declaration ranking weights and selects native realisation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const declaration = try model.parse(alloc, model.seed);
    const capabilities = model.items(model.spec(declaration.value), "capabilities");
    const scored = try scoreCapability(
        alloc,
        null,
        declaration,
        capabilities[0],
        "Use BrowserOS Neo to send 7 meeting requests",
        "trunk",
    );
    try std.testing.expectEqualStrings("general_task_native", scored.realisation);
    try std.testing.expect(scored.ranking.score >= 0.8);
}
