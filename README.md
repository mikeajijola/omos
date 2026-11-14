# OMOS (OmniseedOS)

OMOS is a contract-driven agent operating system built in a single native Zig binary and paired with a portable Fossil workspace (`omos.fossil`). Every substantive task receives a pinned contract, an isolated Fossil branch, a sparse filesystem projection, host-recorded evidence, independent completion verification, and a cryptographically verified Fossil publication receipt before work is accepted.

Git owns project source code; `omos.fossil` owns portable company definitions, task contracts, skills, memory, documents, immutable artifacts, execution journals, and editable workspace UI source.

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/releases/latest"><img alt="CLI release" src="https://img.shields.io/github/v/release/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Architecture

- **Portable Fossil workspace (`omos.fossil`)**: Native turns invoked through `omos`, `omo`, `fxos`, or `ui-host` bind to a format 2 Fossil workspace (`~/.omos/omos-workspace.json`, with automatic fallback to `~/.fx/omos-workspace.json`). Each saved task runs on its own Fossil branch (`task/<id>`) with an isolated filesystem projection of `memory/`, `skills/`, `documents/`, `artifacts/`, and `ui/`.
- **OmniForm capability and realisation graph**: Workspaces pin `omniform/company.json` and `execution/omos.json`. When a work request is admitted, the parent coordinator identifies the affected capability (`general_task` or `coding_task`) and selects the preferred realisation path (`realisation_selection.zig`) using the declaration's `semantic.search.ranking` weights (`relevance`, `precedent`, `evidence`, `recency`).
- **Pre-equipped workers and child sub-agent contracts**: Dispatched background workers receive an explicit `<omos_realisation_assignment>` block, pre-bound workspace skills (such as `browseros-neo`), and pre-advertised MCP tool schemas on their first step. Synchronous child sub-agents (`subagent` tool) also branch from their parent task in `omos.fossil`, receive pre-bound realisation skills, verify against their child contract, and publish back to the parent task branch.
- **Independent completion review and publication**: Actors cannot mark their own contracts fulfilled. An independent reviewer inspects host-recorded tool evidence, canonical MCP companions, and workspace file snapshots through `omos_review_evidence` and `omos_review_checkpoint`, then submits `omos_contract_assessment`. Only after all obligations are verified does the host merge the reviewed revision and record a signed publication receipt.
- **Permission-first execution**: Routine local work runs in `auto` mode while external or unparsed actions pass through an independent security reviewer that checks for prompt injection or malicious intent.

## Unified Surfaces

All surfaces share the same native contract engine, capability graph, and Fossil workspace:

| Surface | Invocation | Role |
| --- | --- | --- |
| Interactive TUI | `omos` or `omo` | Terminal conversation and coordinator loop with inline scrollback, `/task` controls, and background worker dispatch. |
| Headless CLI | `omos ask "<prompt>"` | Single-turn or resumed (`--resume`) contract execution with `--json` output for scripts and automation. |
| Workspace Web UI | `omos-ui` (`bin/start.mjs`) | Browser shell serving the live Fossil `ui/` React source, Conversation, Workspace, Calendar, Artifacts, Context, BrowserOS Neo desktop, and Settings over `ui-host --stdio`. |
| Local MCP Server | `omos-ui/bin/mcp.mjs` | Exposes `omos_search`, `omos_read`, `omos_query`, `omos_classify`, `omos_attention`, `omos_conversations`, and governed chat controls over MCP stdio. |
| Messaging Channels | `omos-ui/bin/channel.mjs` | Terminal, Telegram, and WhatsApp contract routing and subscription delivery over the shared local host socket (`bin/host.mjs`). |
| Agent Client Protocol | `omos acp` | JSON-RPC 2.0 ACP server over stdio with full contract governance, skill bindings, and child sub-agent task branching when invoked as `omos` or with `OMOS_CONTRACT_REVIEW=1`. |
| JavaScript SDK | [`libfx`](sdk/README.md) | Embeddable Node.js native addon and WebAssembly agent runtime. |

## Build and Quick Start

You need [Zig 0.17.0](https://ziglang.org/download/) to build the native binary:

```bash
git clone https://github.com/vercel-labs/fx.git
cd omos
zig build
./zig-out/bin/fx --help
```

Link `omos`, `omo`, and `fxos` to the built binary (or install to `~/.local/bin`), then initialize or ensure a workspace and run a governed turn:

```bash
./zig-out/bin/fx fossil ensure --json
./zig-out/bin/fx ask "summarize the workspace capabilities"
```

To launch the Workspace Web UI from the companion `omos-ui` checkout:

```bash
cd ../omos-ui
npm start -- --binary /absolute/path/to/omos/zig-out/bin/fx --workspace /path/to/project
```

## Configuration and Environment

OMOS resolves profile state from `~/.omos/` when `OMOS_PROFILE_DIR=.omos` is set or when `~/.omos` exists on disk, and falls back to `~/.fx/` so existing installations continue working without migration. Project-level defaults are read from `<workspace>/.omos.json` first, with fallback to `<workspace>/.fx.json`.

Environment variables support both `OMOS_*` and `FX_*` prefixes (`OMOS_*` takes precedence):

- `OMOS_PROVIDER` / `FX_PROVIDER`: Active model provider (`gateway`, `codex`, `grok`, or a configured provider ID).
- `OMOS_MODEL` / `FX_MODEL`: Active actor model override for the current process.
- `OMOS_CONTRACT_REVIEW` / `FX_CONTRACT_REVIEW`: Explicitly enable (`1`) or disable (`0`) contract governance. Enabled automatically when invoked as `omos`, `omo`, `fxos`, or `ui-host`.
- `OMOS_CONTRACT_REVIEW_MODEL` / `OMOS_REVIEW_MODEL` / `FX_CONTRACT_REVIEW_MODEL` / `FX_REVIEW_MODEL`: Model or `provider:model` spec for independent completion and permission review.
- `OMOS_COORDINATOR`: Set to `0` to run tasks directly in the foreground turn instead of dispatching to background workers.
- `OMOS_PERMISSION_MODE` / `FX_PERMISSION_MODE`: Baseline permission policy (`auto`, `ask`, or `full-access`).
- `OMOS_MAX_AGENT_STEPS` / `FX_MAX_AGENT_STEPS`: Maximum actor steps per invocation.
- `OMOS_ULTRAFAST` / `FX_ULTRAFAST`: Toggle ultrafast provider routing when supported.
- `OMOS_CLASSIFIER_URL` and `OMOS_CLASSIFIER_MODEL`: Optional System-1 classifier endpoint for fast request routing and lookup stopping checks.
- `OMOS_TRACE_LOG` / `FX_TRACE_LOG` and `OMOS_TRACE_SCOPES` / `FX_TRACE_SCOPES`: Diagnostic trace log destination and comma-separated scope filter.
- `OMOS_MCP_ENGINE` / `FX_MCP_ENGINE`, `OMOS_SOUND` / `FX_SOUND`, `OMOS_AUTO_UPGRADE` / `FX_AUTO_UPGRADE`, `OMOS_DISABLE_KEYCHAIN` / `FX_DISABLE_KEYCHAIN`, `OMOS_NO_OPEN_BROWSER` / `FX_NO_OPEN_BROWSER`.

## Repository Layout

```text
omos/
├── src/
│   ├── main.zig              composition root and CLI entrypoint
│   ├── core/
│   │   ├── workspace/        Fossil workspace, OmniForm model, realisation selection, background workers, schedules
│   │   ├── agent/            orchestrator, work contracts, independent completion review, evidence ledger
│   │   ├── subagent/         child sub-agent runtime and parent-branch contract inheritance
│   │   ├── config/           profile/project config and configured provider definitions
│   │   ├── permissions/      permission gate and independent auto-mode security classifier
│   │   ├── mcp/ & mcp_host/  MCP client engines, always-loaded tool schemas, canonical output companions
│   │   └── skills/           skill discovery, portability contracts, and explicit prompt bindings
│   ├── builtins/             built-in tool specs, command specs, and system prompts
│   ├── tools/                built-in file, shell, web, skill, and workspace tools
│   ├── ui/                   terminal rendering and interactive TUI loop
│   ├── gateway/              provider HTTP/SSE transport
│   └── acp/                  Agent Client Protocol JSON-RPC 2.0 server
├── sdk/                      libfx JavaScript/WebAssembly SDK
├── tests/                    deterministic E2E tests (tests/e2e), model evals, and TLA+ specs
└── benchmarks/               startup latency, UI activity, and file-index benchmarks
```

## Workspace Documentation

- [Workspace Runtime and Operations](src/core/workspace/README.md): Sparse projections, capability realisation ranking, background workers, and recurring schedules.
- [Conversation and Content Capabilities](src/core/workspace/CAPABILITIES.md): Content search, structured JSON/SQLite queries, classifier routing, MCP startup schemas, and multi-channel contract continuity.
- [Workspace Contract Authority](src/core/workspace/CONTRACTS.md): OmniForm record authority, review policy, evidence checkpoints, and scoped company services.
- [Agent and Contributor Instructions](AGENTS.md): Build, test, code style, and verification rules.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
