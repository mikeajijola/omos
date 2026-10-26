# Managed omos workspaces

Git owns project source. The bound Fossil repository owns saved task contracts,
memory, skills, artifacts, execution evidence, and publication receipts. Native
`omos` and `omo` turns use the same workspace binding. Saved turns initialize
an empty personal instance automatically when no repository is bound.
`omos fossil ensure --json` performs the same bootstrap without importing
existing sessions.

Managed turns checkpoint changes in the task's projected `memory/`, `skills/`,
`documents/`, `artifacts/`, and `ui/` directories. The host hashes local files
through fixed-size buffers and retains their metadata while identifying
changes. It loads changed bodies on demand and rechecks their hashes, sizes,
and executable flags before committing. A concurrent edit leaves the previous
baseline intact for the next checkpoint.

New task views start without document bodies. Ordinary file reads and mutations
materialise the requested managed path before permission preflight. File searches
materialise their selected directory. Skill discovery retrieves `SKILL.md`
indexes; loading a skill retrieves its package. Shell commands hydrate the whole
personal view because a process can open paths without calling the file tools.
The baseline tracks only materialised files, so unfetched content cannot become
a deletion. Parallel hydration and checkpoints share a projection lock. This is
a tool-driven sparse projection, rather than a transparent filesystem mount.

Hydration reuses a private immutable object cache across personal task views.
Every lookup follows a verified canonical manifest and verifies the complete
Fossil object hash. Mutable views receive independent copies. Corruption or cache
loss fetches the original bytes again. The shared cache remains bounded to
256 MiB and 4,096 objects; it is excluded from portable exports.

New views use a repository-specific directory, so independently copied repositories
cannot share editable files. Existing views with an owned baseline retain their
original directory and private drafts.

Inspect disposable views with `omos fossil cache status --json`. Use
`omos fossil cache prune --json` to remove verified clean accepted views, or
`omos fossil cache trim --json` to apply the cache policy. Fresh instances store
`projections.max_clean_bytes: 268435456` and `projections.max_clean_views: 32`
in `execution/omos.json`. These limits cover clean disposable views. Drafts,
paused tasks, unknown files, execution caches, and live process resources remain
protected even when they exceed the budget. Legacy policies omit `projections`
and keep automatic cleanup disabled until an explicit contract upgrade.

Managed saved CLI turns, the persistent UI host, and the writable workspace
service trim through one background worker per repository binding every 30 seconds, with a 15-second pass deadline and cancellation during
shutdown. Trimming keeps the newest clean views and reclaims older excess views
as it scans, so a deadline does not postpone every deletion. Standalone inspection and pruning have a 30-second deadline. The
collector holds task, projection, and process lifetime locks, verifies every
file against Fossil, then renames and rechecks the view before deletion. A crash
can leave a quarantined directory for inspection. It does not erase task history,
canonical content, or uncommitted recovery directories.

Read dependency records retain up to 10,000 distinct personal file paths and
20,000 company read selectors, including inventory pages. They store identities
and hashes rather than combining the referenced file bodies. Completion checks
still verify the retained observations against the publication candidate.
Company inventory requests release each hashed file body before inspecting the
next one, so a metadata page does not retain 32 full documents in memory.
Company metadata pagination stops after 32 rows or after inspecting 4 MiB of
content. One object can cross the byte boundary, with an 8 MiB per-object limit.
Use `next_offset` to retrieve every remaining row; a short page can still have
more results. This bounds inspection work without rejecting a large inventory.

Completion review receives a bounded evidence manifest. Larger records remain
available through the assessor's read-only `omos_review_evidence` interface.
Its read action returns UTF-8 byte slices of JSON containing the original
arguments and content. The assessor must inspect every byte of a cited record
before that record can establish a met obligation. Pagination never grants
permission to execute an action.

When a record exceeds one review attempt, the assessor uses
`omos_review_checkpoint` to record decisions about contiguous inspected bytes.
Each segment identifies the obligations it supports, contradicts, or does not
address. The host binds these decisions to the exact payload hash, byte range,
and contract version. Resumption restores their verified coverage and continues
at the next byte without resending every earlier page. Changed evidence or
contracts invalidate the affected decisions. Raw page cursors alone never
establish inspection, and contradictory segment decisions prevent acceptance
based on those checkpoints.

The initial manifest lists 16 evidence records. Further records remain available
through the evidence interface's `list` action. Its `assessments` action retrieves
retained segment decisions by evidence ID. Large requests and steering are also
retrievable records; completion requires inspection of their omitted contents.

A review attempt permits at most eight auxiliary model calls under one deadline.
Exhausting the review budget retains the answer, evidence, and review records.
Continuing a task with a retained failed-review candidate starts with verification.
The actor resumes only when assessment identifies useful remaining work.

The host commits each actor tool-batch intent before any tool effect starts.
The host records review requests, evidence accesses, assessments, and failures.
These records describe observable decisions. Provider replay state and private
model reasoning remain outside the portable workspace. Review audit records are
checkpointed before publication, with a fence against changes to the reviewed
branch.

Local hosts can invoke the read-only workspace API with
`omos fossil request REQUEST.json --json`. The request uses the same
`omos.workspace-api/v1` envelope and active declaration hash as the HTTP API.
This command cannot write records, propose definitions, or queue reviews.

The `head` action discovers the current full revision of the workspace or an
optional `task`. It takes the current transport declaration hash and omits
`revision`. Its data supplies the immutable revision and selected task's pinned
definition hash for subsequent retrieval. It never resumes or publishes work.

The `inventory` action lists up to 32 portable file identities per page at an
immutable Fossil revision. Supply `offset` to continue, and an optional exact
`path` or directory prefix ending in `/` to select content. Rows contain a path,
Fossil artifact identity, and executable flag. They exclude protected runtime
records and reject symlinks. The artifact identity is a Fossil hash, not a
SHA-256 receipt. Use `read` for bounded byte pages with the complete content's
SHA-256 and byte count. Binary pages use base64; text pages preserve UTF-8
boundaries. Subsequent accepted revisions do not change a pinned inventory or
read. Existing instances must explicitly upgrade their contracts before using
the new `omos_workspace_inventory` and `omos_workspace_head` operations.

The read-only `candidate` action returns a task's exact recorded answer at its
current immutable revision. It requires a task and revision, marks the text as
`actor_claim`, and rejects answers larger than 32 KiB. A returned claim is input
for independent review; it does not establish completion or permission to
publish. The company worker adapter uses this operation to preserve answers
even when the original task requested no file changes.

`fossil_workspace` supports `verify_manifest` with a workspace-relative `path`.
The referenced JSON has a `files` array whose entries contain `path`, `sha256`,
and `bytes`. Entries can also request an `executable` boolean check. The host
verifies every listed file against one pinned revision and returns a bounded
receipt with the number of executable flags checked. This establishes consistency with the supplied
manifest. Source provenance and external effects require their own evidence.

Configured-provider responses with invalid tool names are rejected before tool
execution. The runtime distinguishes missing, malformed, and unadvertised names
from invalid outgoing definitions. It records bounded diagnostics and the
advertised tool identities, then permits one corrected response when effects are
known to be absent. Possible provider effects use the existing reconciliation
path before any retry. Repeated rejection pauses the turn. Earlier successful
actions remain retained.

## Schedule work contracts

Schedule an existing unfinished root task with an explicit timestamp:

```sh
omos schedule add TASK_ID --at '2026-10-23T09:00:00+01:00'
omos schedule list --json
omos schedule show SCHEDULE_ID
omos schedule move SCHEDULE_ID --at '2026-10-24T10:00:00Z'
omos schedule cancel SCHEDULE_ID
```

Timestamps require seconds and an explicit UTC offset. `list` accepts `--from`
and `--to` for a half-open date range. JSON responses include the calendar
revision; pass it with `--revision HASH` when changing a calendar you previously
read. Cancelling a start preserves the contract and its evidence.

The persistent native `ui-host --stdio` or writable `fossil serve` host runs due
contracts through their saved native sessions. The host must be running, the
project directory must exist, and the original native session must be available.
Overdue starts queue when the host returns. A workspace actor lock prevents
concurrent scheduled and interactive root invocations. Ordinary permission rules,
bounded invocations, independent assessment, and verified publication still apply.
A headless HTTP host retains work when it needs user input.

Schedules and their transition history live on the portable `omos-schedules`
Fossil branch. Credentials and session checkpoints remain profile state. A lost
worker lease retains an interrupted schedule for inspection and continuation;
it does not automatically replay potentially completed external effects.
Reschedule retained waiting work explicitly after resolving its blocker.

Authenticated user updates mark a contract revision pending. The independent
planner can replace affected obligations while preserving unrelated obligations
and host requirements. The host records old and new contract versions and the
user amendments that caused the change. Work resumes against the revised
requirements, with existing evidence available for independent reassessment.

The workspace UI Calendar displays planned starts, current requirements,
schedule history, and execution state. Its editor creates, moves, or cancels
starts with a revision fence. Calendar timestamps display in the browser's
local timezone; stored execution instants use UTC. Schedules are one-time starts,
not deadlines or recurring templates.

### Calendar service

`POST /v1/schedules` uses the existing workspace service bearer authentication.
Requests contain `version: "omos.schedule/v1"`, the bound `workspace` identity,
and an `action` of `list`, `show`, `add`, `move`, or `cancel`. `show`, `move`, and
`cancel` take `id`; `add` takes `task`; `add` and `move` take `at`. `list` accepts
`from` and `to`. Mutations require writable service mode and the calendar
`revision` returned by the previous read. The native UI bridge exposes the same
operations through its typed `schedule` method.

## Declare the workspace model

New workspaces contain `omniform/company.json` and `execution/omos.json`.
The company declaration uses the same pinned OmniForm schema and semantic
extension as the SaaS model. The native profile is `omos.workspace/v1`.
The files under `standard/` record the upstream version, license and provenance.
The binary validates declarations itself; JavaScript and Ajv are test tools.
The [contract authority reference](CONTRACTS.md) describes record schemas,
review policy, derived relationships, auditing and the workspace service.

Inspect or validate the model with either CLI name:

```bash
omos fossil definition show --json
omo fossil definition validate company.json --json
omos fossil definition propose company.json --json
omos fossil definition propose company.json --execution execution.json --json
omos fossil query omos_task --json
omo fossil query omos_task --offset 32 --json
```

The JSON snapshot exposes model results in `model_data`. Validation reports
include `valid`, `errors`, the native profile, the pinned standard version and,
when valid, the canonical declaration hash. Semantic scopes describe data relationships
and discovery metadata in this single-user host; they do not create user roles
or grant tool permissions. Unknown policy features, unsupported
JSON Schema keywords, secret literal fields, Git-specific governance and
required operation approvals are rejected. A declaration cannot grant tool
permissions or install executable implementations.

A proposal receives a separate Fossil branch. The host validates structural
and semantic references and compares the candidate with the active declaration.
Existing capabilities, operations, realisations and resources retain their
contracts. Existing entity fields keep their types and required status. New
entities and optional fields can be added. Compatible proposals activate for
future tasks after the host publishes a compatibility receipt. Incompatible
proposals remain inactive and retained. A task always uses the declaration
revision, canonical hash and execution policy saved when it started.

The `general_task` and `coding_task` capabilities bind to the native task
runtime. Capability discovery reports these bindings alongside installed skills
and configured MCP tools. Other declared capabilities remain `declared_only`
until the host has an implementation. An exact MCP server filter continues to
search that server only. Operation input/output schemas describe the company
contract; they do not create new executable tool names.

`fossil_workspace` adds these actions:

| Action | Input | Result |
| --- | --- | --- |
| `definition` | None | The task's pinned declaration and execution basis |
| `query` | Optional `entity` and `offset` | A page of records with source revision and next offset |
| `record` | `entity`, JSON string in `content` | A validated custom entity record or proposed plan refinement |
| `propose_definition` | Declaration JSON string in `content`, optional execution JSON string in `execution` | Host compatibility decision and retained proposal |

Task contracts, actions, evidence, assessments and results project from existing
canonical files and history. Memory, skills and artifacts retain their existing
paths. Custom records are content addressed under `records/`. Agents cannot
write host-owned entity types. An `omos_plan` write records a refinement proposal;
it cannot replace a host contract or remove an obligation. Indexes and query
results are derived from canonical records and are not another editable source.

## Inspect capability dependencies

`omos fossil package plan CAPABILITY --json` follows the selected OmniForm
realisation and transitive `capabilityHierarchy.dependsOn` requirements. Use
`--realisation ID` when a capability has multiple choices, or `--selections PATH`
with an array of explicit root and dependency choices. The result pins the
company revision and declaration hash, lists required files with their Fossil
object identities and executable flags, and reports missing inputs.

A skill resource declares its portable inputs in `spec.portability`:

```json
{
  "implementation": "fossil_skill",
  "portability": {
    "version": "omos.resource-portability/v1",
    "paths": ["skills/cv-builder/"],
    "dependencies": [
      {"kind": "runtime", "handle": "node", "constraint": ">=22"}
    ]
  }
}
```

A trailing slash includes all canonical files under that directory. Paths cannot
refer to credentials, checkout caches, or project source owned by Git. External
entries name configuration, service, runtime, or host implementation handles;
they carry no credentials or authority. `declaration_complete` establishes that
the declared requirements and files are accounted for. The separate
`runtime_verification: "required"` result preserves the distinction between
retained files and an executable capability. Owner inspection reports
`file_verification: "manifest_inspected"`; scoped metadata discovery reports
`file_verification: "required"` until content has been retrieved and verified.
See [capability metadata authority](CONTRACTS.md#scoped-company-service) for
company grant and delegation rules.

Selected company packages can be exported with a version 2 export configuration
and verified offline. `omos fossil package import CONFIG.json ARCHIVE.tar --json`
retains a verified package and additive declaration candidate on a paused task
branch. Configure trusted destination runtimes and verify the retained task with
`omos fossil package verify TASK --bindings BINDINGS.json --json`. Bindings stay
in the private profile. A successful check produces signed host evidence for the
exact imported files, declared implementations, and runtime constraints. It
doesn't execute package programs or establish their functional behavior.

Resume the import through the normal agent and independent-review path. The
host requires current runtime evidence before publishing the imported files,
additive declaration, and implementation record in the same Fossil commit.
Capability discovery reports verified availability while the files and local
runtime bindings still match. A copied workspace retains historical evidence
but needs verification on the destination host before reporting availability.
See [selected capability packages](CONTRACTS.md#selected-capability-packages) for
request fields, authority, integrity checks, and import bounds.

## Plan and bound an invocation

Before the first actor call of a modeled task, a separate read-only planner
selects a native capability and derives checkable obligations. The host retains
`request_complete` and adds validation and final-answer obligations for coding.
Repository checks must follow applicable repository instructions. Commits and
remote publication are required only when requested or required by those
instructions. Planning and assessment cannot execute tools.

The execution policy defaults to a progress check after every four completed
tool batches, a pause after three consecutive stalled checks, and at most 100
actor steps per invocation. The last actor slot is reserved for a summary with
tools disabled. The existing global agent-step limit still applies. Continuing
a paused task starts another bounded invocation with the same contract and
retained evidence.

Progress assessment records successful evidence, remaining obligation IDs and
a reason to continue, finalize or pause. New call IDs and repeated identical
results cannot establish fresh progress. Finalize requests a candidate answer;
the normal completion assessment and verified publication remain required.
Pause retains a partial result and leaves the task unaccepted.

Start coding tasks in the repository they change. A scan that stops at a nested
repository cannot establish a source basis. Coding validation is associated
with a hash of the repository files exposed by the native indexer. The hash
includes paths, file types, permissions, contents, and symbolic-link targets.
A command must run across an unchanged source state to
provide current validation evidence. A later source edit invalidates that basis.
Incomplete scans, unreadable or oversized files cannot establish validation.
Generated files should follow the repository's ignore rules; changes to visible
generated files also change the source basis.

## Migrate an existing workspace

```bash
omos fossil migrate --json
omos fossil verify
```

Migration creates a verified `.pre-omniform-<timestamp>.fossil` backup before
writing the model and workspace format 2. Repeating migration preserves the
active declaration. Existing task branches, original requests, amendments,
contracts, evidence and publication receipts remain intact. Existing tasks use
the legacy adapter; future root tasks pin the model. Older binaries reject
format 2 rather than silently writing it.

To inspect or restore an exported workspace, bind its verified clone with
`omos fossil use PATH`. Profile credentials, browser sessions and opaque runtime
checkpoints remain outside the portable repository. Migration and recovery do
not replay completed external actions.

### Workspace interface source

The optional [workspace UI host](ui-host.md) stores its complete frontend under `ui/`. Native `ui-host --stdio` owns saved turns, approval boundaries, replay and source validation. Agent edits remain on their task branch until independent review and normal Fossil publication succeed. A fresh host compilation receipt covers the exact current UI files and pinned compiler; changed source cannot publish using stale validation. Interface builds and public delivery journals remain disposable cache and operational profile state respectively.
