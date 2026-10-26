# Workspace contract authority

The pinned OmniForm declaration defines the workspace's expected data and
operation contracts. Host records establish observed state. Independent
assessment compares those records with the task's acceptance obligations.

## Authority and ownership

| Record | Governing contract | Writer | Verification |
| --- | --- | --- | --- |
| Workspace declaration | Pinned OmniForm standard and native profile | Host proposal activation | Structural, semantic and compatibility validation |
| Execution policy | `omos.execution/v1` | Host activation | Bounded policy fields; automatic changes cannot increase allowances |
| Task | Pinned declaration, policy and original request | Host | Preserved acceptance obligations and contract revision |
| Contract amendment and revision | Authenticated user update and current task | Host and independent planner | Version fence, explicit superseded IDs and preserved unaffected obligations |
| Plan | Parent task and `omos_record_plan` | Host planner | Typed fields and preservation of parent requirements |
| Action intent | `omos_record_action` | Host | Invocation and transcript position qualify provider call IDs; intent is not execution |
| Evidence | `omos_record_evidence` | Host | Typed record and producing action identity |
| Command receipt | `omos.command-receipt/v1` | Host | Known completed process outcome; original output retained |
| Assessment | Task and `omos_record_assessment` | Independent assessor, recorded by host | Identity, obligations, evidence references and inspection coverage |
| Result | Capability operation output | Host | Accepted assessment, current source and verified publication |
| Server review job | `omos_record_review_job` | Host scheduler | Pinned workspace contract, task contract, candidate hash and generation-fenced lease |

Operation schemas are declared in `standard/omos.json`. They describe host
records and do not advertise executable model tools. The native host enforces
permissions, evidence inspection and protected task transitions separately.
Agents can propose plan refinements through typed records. Changing an existing
obligation requires the separate host revision process below. Protected records
cannot be written through typed record APIs.

Existing tasks keep their pinned declaration and execution basis. A missing
review policy uses the legacy eight-call, 60-second, single-attempt policy.
Fresh workspaces explicitly record the current review defaults. A declaration
without the newer record operations uses the legacy adapter; audit reports
these tasks rather than rewriting their history.

## User updates

For model-pinned tasks, an authenticated user update increments the contract
version and marks its requirements for revision. Before the next actor request,
the independent planner identifies affected obligation IDs and proposes their
replacement requirements. The host preserves every unlisted obligation and
the protected `request_` requirements. The planner cannot supersede `coding_`
requirements. When an authenticated update withdraws all coding work, the host
switches the task to `general_task` and removes only its native
`coding_validation` and `coding_summary` requirements. Continuing a task without
an update preserves its capability and requirements.

The `contract_amendment` history record retains the user text and previous
contract. The `contract_revision` record retains the previous and current
contracts, previous and current capabilities, superseded IDs, removed native
requirements, planner summary, and applied amendments. The original
request and all evidence remain available. Earlier assessments cannot accept
the new contract version; the assessor checks retained evidence against the
current requirements and applies authenticated user changes in order.

While revision is pending, the host blocks new actor actions, review jobs, and
publication. A rejected revision retains the update for a later continuation.
Updates received during execution are applied at the next steering boundary;
actions already performed remain in the evidence history.

## Retrieval and derived relationships

`omos_review_evidence` supports `query`, `search`, `related` and `coverage`, in
addition to record listing, byte reads and retained assessments. Exact filters
include record kind, tool, status, action identity, source and obligation.
Search is case-insensitive lexical matching over retained content, arguments
and tool names. It is scoped to the complete pinned review manifest. It is not
an embedding index or a search over other workspaces.

An absent source or relationship remains unknown. The host does not infer
validation coverage from similar command text. Source metadata attached to an
action describes the observed source context; the separate source-validation
check still determines whether validation covers the current files.

Query results project canonical events into OmniForm records. Action-to-evidence
relationships describe host-observed provenance. Evidence-to-assessment
relationships are marked as assessor claims, including claims the host rejected.
Neither kind of relationship establishes completion by itself. Record and
relationship pages are independently bounded to 32 entries and expose their
continuation offsets.

The managed reviewer traverses hash-verified history in bounded batches and
keeps file identities and bounded previews in its manifest. Large evidence
payloads live in a private, rebuildable `review-payloads/` cache under the
repository's profile cache. They are not additional canonical records and do
not enter portable exports. The host reconstructs them from the pinned Fossil
revision when missing, repairs corrupted cache entries during reconstruction,
and checks size and full SHA-256 before delivering cached bytes. The manifest
never treats a preview as the original payload. Progress checkpoints use the
same backing records and preserve the full canonical identities used to
distinguish useful work from repeated results.

Retrieval and lexical search load one payload into independently released
scratch memory at a time. Each serialized payload has a 64 MiB host ceiling;
workspace content and canonical records retain their existing, separate file
bounds. Memory still scales with manifest and assessment metadata, rather than
with the sum of all payload bodies. Arbitrary external process memory and
provider session storage are outside this bound.

Raw prior-page replay has a 256 KiB host window and a 160 KiB assessor-packet
window. Older pages remain in canonical history. Independently verified segment
assessments retain inspection progress beyond these windows; an unassessed page
may need to be retrieved again. Candidate recovery, source-validation lookup,
and dependency preview generation also release each content batch before
loading the next one. Binary workspace files receive an explicit base64 content
envelope with their original file hash and byte count.

Search previews never establish inspection of omitted bytes. Coverage queries
return exact missing ranges and the payload hash. Complete record citations
still require complete coverage or independently verified segment assessments.
Command receipts establish only the process outcome. A zero exit code alone
does not establish test coverage or a successful external action.

Typed queries return at most 32 records and approximately 64 KiB of record
data per page. Records larger than 8 KiB become references containing the
original path, revision, size and hash. The original records remain available
through bounded reads. Relationship pages have a separate continuation offset.

## Review policy

Fresh workspaces store these settings under `review` in `execution/omos.json`:

```json
{
  "max_calls": 8,
  "reserved_calls": 2,
  "response_timeout_ms": 120000,
  "attempt_timeout_ms": 300000,
  "max_attempts": 3,
  "total_timeout_ms": 900000,
  "max_context_bytes": 524288,
  "max_read_bytes": 16384
}
```

The host withdraws evidence retrieval during reserved calls. Rejected calls
are never executed or aliased. Each response is bounded by both its response
timeout and the remaining attempt allowance. Automatic continuation reuses
retained evidence and stops when inspection stops advancing or the total
allowance expires. Continuing a paused task creates another bounded invocation.

The attempt deadline also covers host evidence collection. Fossil processes and
command, writer and authority lock waits inherit that deadline. A timed-out or
cancelled history batch stops instead of falling back to more reads. The host
drains the collection worker before releasing its turn memory. Timeout handling
uses an in-memory progress counter rather than another history scan.

Canonical history seeds byte-range deduplication without renewing an attempt.
Newly delivered ranges, complete records retrieved beyond the initial packet,
and valid independent segment assessments advance that counter. Repeating the
same bytes does not. A collection timeout retains verification as pending;
it does not replay actor actions or classify a server review as completed.
Saving and acknowledging the pending outcome remains a separate durability
step; the review budget cannot turn an unacknowledged write into a success.

Exhausted verification leaves the task paused with its candidate and review
progress retained. It does not publish the task or return to actor execution.
Other review failures preserve their specific failure diagnostics. Optional
`max_tokens` stops further review after the reported input and output usage
reaches its allowance. Usage is recorded after each response and shared across
automatic attempts. A provider that omits usage cannot satisfy an enabled token
allowance. Reported usage arrives after a request, so this is not an exact
billing ceiling. Monetary limits are unsupported and are rejected as unknown
policy fields.

## Workspace service

`omos fossil serve [PORT] --json` starts a loopback HTTP service for the bound
workspace. It requires `OMOS_WORKSPACE_TOKEN`, with 32 to 1,024 bytes, from the
host environment. The default port is 8765; port 0 requests an available port.
The startup JSON reports the selected port and workspace identity. The token
is not part of the declaration or portable repository.

Requests require `Authorization: Bearer TOKEN`. Browser-origin requests are
rejected. `GET /v1/definition` bootstraps the workspace identity and declaration
basis. `POST /v1/workspace` accepts the `omos_workspace_request` contract:

```json
{
  "version": "omos.workspace-api/v1",
  "workspace": "WORKSPACE_ID",
  "definition_hash": "DEFINITION_HASH",
  "revision": "REVISION",
  "action": "query",
  "entity": "omos_task"
}
```

Actions include definition inspection, typed queries, public content reads and
contract audit. Starting the service with `--write` also allows custom typed
records, plan refinement proposals, declaration proposals and queued verification
of retained answers. It never grants
permission to forge host evidence, activate incompatible definitions or publish
a task directly. Writes check the expected revision under the workspace lease.
The HTTP host supports persistent connections, at most 32 concurrent connection
handlers and at most 100 requests per connection.
Typed history queries consume and release bounded canonical history batches.
Only the requested page's record bodies remain in the response arena; large
records become immutable hash-and-size references. Provenance joins retain
plan and action identities separately from their bodies. Queries still inspect
every relevant canonical history identity, including records outside the page.
Inventories and plan/action metadata grow with the selected history; pagination
does not claim constant total memory or an indexed constant-time lookup.

`read` accepts an original `path`, byte `offset` and a `limit` of at most 16,384
bytes. Text segments use UTF-8; binary segments use base64 with offsets in the
original bytes. Each response includes the full original size, content hash and
next offset. Reads can name an older revision after verifying that it belongs
to the bound workspace. A historical read does not make old validation current.

`queue_review` requires a task ID and a retained candidate. The host records a
durable job before a worker claims it. `job` returns live status using the task
and job IDs. Workers run independent verification only. They cannot execute
actor tools; a finding of unfinished work returns `changes_required`.

A worker lease carries an owner, generation and expiry. Publication checks the
lease inside the host transaction and records the published job with its
publication receipt. Expired workers cannot publish. A restarted scheduler can
reclaim an expired job, reload inspected evidence and reconcile an interrupted
publication against its original receipt. Native actor execution cannot race a
queued or running server review of the same task.
The job reserves each review attempt durably before making model calls. Its
start time, consumed attempts and reported usage survive worker replacement.
An explicit requeue creates a new allowance epoch while preserving the worker
generation and prior evidence. Restarting the service does not renew an
exhausted allowance.

`omo fossil remote URL [REQUEST.json] --json` uses this API without creating a
local repository. Omitting the request file fetches the definition. HTTP is
restricted to loopback; other endpoints require HTTPS. Redirects are refused.
The client does not automatically retry a mutation after an uncertain outcome.

The owner service uses the existing Fossil-backed manager and a single host
credential, with durable review scheduling. The scoped company service below
adds actor signatures and delegated path grants. Distributed storage, remote
filesystem mounting, and hosted company actor sessions require additional
implementations.

## Audit and migration

`omos fossil audit --json` validates canonical action, evidence and plan records
against their pinned operation contracts. It reports validation issues and
legacy tasks without rewriting them or repeating actions. This is a structural
audit, not a completion assessment.

`omos fossil migrate --contracts --json` creates a verified backup and adds
native contracts. For known native company and scoped-export transports, it also
adds optional schema properties and extends recognized native version values.
Company field types, required fields, operation bindings, and other constraints
remain intact. Review defaults are added only when that policy section is
missing. Active tasks keep their original declaration and execution basis.
Definition proposals continue to require exact preservation of existing
operation contracts; these transport extensions require explicit migration. Repeating a current migration
does not create another backup. Older tasks can use the current transport API
while their record writes and assessments retain the older task contract.

Fossil remains authoritative for portable records during this stage. Existing
export, verified-copy restoration and migration retain their ownership. A
future server cutover must preserve record identities, content hashes, review
progress and publication receipts, use a single authoritative writer, and
reconcile any records created after cutover before rollback.

## Personal instance and filesystem views

`omos fossil ensure` creates an empty personal instance under
`~/.fx/instances/personal.fossil` when no repository is bound. Saved native turns
and the UI host use the same bootstrap. Existing bindings remain unchanged.
Each fresh instance receives a unique workspace identity, a declaration, and an
execution policy. Unlike `fossil init`, bootstrap never imports old sessions.
Initialization publishes the verified repository before publishing its binding.

Task selection is retained as a host-owned `omos_event` on the `omos-runtime`
branch. Each session binding names its workspace and selected task; it contains
no provider replay state or credentials. Selecting work does not advance the
accepted company branch. These events are available through typed event queries
and travel with an ordinary repository copy, independently of the last export.
They preserve an explicit switch to older work instead of guessing that the
newest task must be active.

Independent personal sessions can execute concurrently. A task has one kernel
execution lease shared by CLI turns, UI turns, and the review worker. Selecting
a task in another session does not duplicate execution ownership. A second
execution or an attempt to resume actively owned work returns
`WorkspaceExecutionBusy` before model actions. The kernel releases ownership
after a process exits or crashes, allowing another session to resume retained
work. Selecting other work does not pause a task another runtime is executing.
An idle selected task's paused state is committed with the selection change.
These leases coordinate runtimes on one host; they are not distributed leases.

### Scoped company execution ownership

The company gateway exposes durable execution ownership separately from the
native host's process locks. A grant needs the `execution` action to claim,
renew, or release ownership of its own view. Requests use `action: "execution"`,
the current view `revision`, `execution_change: "claim" | "renew" | "release"`,
and an `execution` fence containing a runtime identity and generation:

```json
{
  "action": "execution",
  "view": "VIEW_ID",
  "revision": "CURRENT_VIEW_REVISION",
  "execution_change": "claim",
  "execution": {"runtime": "worker-instance", "generation": 0},
  "execution_lease_ms": 60000
}
```

These fields belong inside the normal signed company envelope. The initial
claim expects generation zero and returns generation one. Later claims use
the last retained generation and increment it. An active owner must release
or expire before another runtime can claim the view. Renewals require the
current runtime and generation before expiry. Lease duration is 1–300,000
milliseconds, clipped to the grant's expiry; release omits the duration.
Every operation also checks the current grant and its delegation chain.

Unclaimed legacy views retain their existing protocol. Once a view has been
claimed, content mutations and active input observations must carry its live
`execution` fence. Release and expiry preserve a tombstone, so they never
restore unfenced writes. `status` remains available without ownership and
returns the current fence, retained contract, pinned model basis, and checkpoint
revision. Frozen proposal inspection also remains read-only. A replacement
runtime can obtain this context, claim a new generation, and continue from
the recorded checkpoint. Former generations cannot mutate the view.

Ownership records and immutable transition records live under the protected
`company/execution/` tree. The company operation lease serializes transitions
with scoped mutations on the single server. Each transition commits its
current record and exact operation outcome together. Retrying a transition
whose acknowledgement was lost returns the retained generation and expiry;
it doesn't renew a lease or replace a newer owner. A fresh `reconcile` request
can inspect and resolve a retained internal mutation under the current owner's
fence. These operations run no actor tools or external effects.

Ownership fences coordinate authorized clients of this gateway. They don't
provide a sandbox, cross-server consensus, or permission to execute a hosted
company actor. Hosted execution still requires an isolated backend.

Copied personal tasks retain their original project directory. Ordinary resume
refuses a different directory with `TaskProjectMismatch`. Select the new project
explicitly with `/task resume <id> --rebind-project`, or supply
`rebind_project: true` to the revision-fenced native `task.resume` operation.
Relocation retains the task identity, pinned definition and policy, obligations,
original request, and evidence. A `project_rebind` history record preserves the
previous directory and contract. The contract version advances and earlier
source checks cannot validate execution in the new environment. Accepted tasks,
pending publications, conflicts, active review jobs, execution owned by another
runtime, and company-authorized tasks cannot be relocated this way. Company
execution requires its separate authority and ownership flow.

Before an actor restores execution context, the host refreshes the canonical
contract, model, base, project, and authority under execution ownership. Matching
contract version numbers do not make cached values authoritative. Local
selection and publication recovery state is preserved. Buffered read observations
survive only while their base still matches. This also fences an old project
after a committed relocation whose local cache update was interrupted. A
relocated task's provider checkpoint is retained in a private invalidated
archive, outside Fossil, rather than replayed against the new contract.

When task or session index directories are missing, opening the bound instance
reconstructs them from canonical task branches, acceptance receipts, and these
selection events. A durable restore marker makes an interrupted rebuild resume
before those indexes are used. A legacy export registry remains compatible;
newer canonical task records and selection events take precedence. This rebuild
does not restore private provider checkpoints or repeat actor actions.

Task mutation and publication boundaries, including review queuing, claims,
attempts, and checkpoints, refresh canonical task context under their writer
boundary. A cache entry cannot replace a committed contract
or company authority. New action intents are fenced before execution when a
committed amendment advances the contract. Evidence and command receipts for
already completed effects retain their original contract version and model
provenance; they do not authorize another action or automatically satisfy the
amended contract. A private recovery marker spans the canonical job commit
and its local index update. After interruption, the scheduler repairs at most
16 marked task pointers per pass under execution ownership. It does not recreate
jobs or repeat actor actions. Copies of the repository rebuild job pointers
from canonical task records without those private markers.

Repository verification uses Fossil's public check-in manifests and its full
object integrity check. The host checks the complete integrity report, including
error counts, missing content, and the database result; a zero process exit code
alone does not establish integrity. Shared records reuse verification only when
their pathname, immutable object identity, size, and validation context match.
The bounded verification cache can discard entries and repeat checks. File
reads use batches of at most 32 files with a 4 MiB target and the existing
8 MiB individual record limit. Canonical symbolic links are unsupported.

File comparisons use the immutable check-in manifests, including executable
flags. `omos fossil diff` reports a mode change even when the file's content
object is unchanged. Historical 40-character SHA-3 abbreviations are resolved
to complete check-in identities before manifest verification.

Index reconstruction loads publication receipts once per parent revision. An
accepted task must match its receipt's task, contract version, source revision,
and publication target. Portable repository exports explicitly include private
branches and retained proposals. These checks preserve original record and
receipt bytes.

New host history entries carry a recording timestamp. If execution stops after
retaining an answer but before recording an assessment outcome, `continue`
resumes independent verification of that answer. Later actor intentions prevent
an older candidate from taking this recovery path. A completed assessment that
requires more work still returns control to the actor. Neither a retained
answer nor a recovered index establishes completion by itself.

The installation script copies its packaged Fossil helper, or an existing
Fossil executable for a source install, into protected `~/.fx/libexec/` storage.
A content-addressed filename and atomic integrity manifest identify the helper.
The native host verifies its bytes and rechecks file identity before reusing a
process-local verification cache. `OMOS_FOSSIL_BIN` can select an absolute helper
path for host-managed deployments. Development checkouts without an installed
helper retain the existing `PATH` lookup. A bare CLI binary does not contain a
statically linked Fossil engine.

A task receives a filesystem view under
`<project>/.fx/workspaces/<workspace-id>/<task-id>/`. Ordinary file tools and
shell programs can edit `memory/`, `skills/`, `documents/`, `artifacts/`, and
`ui/` there. The host hashes changes and checkpoints them automatically at tool
batch boundaries and before review. Git project files retain their existing
ownership. Files written elsewhere are not automatically workspace content.

The view is not the host's Fossil checkout and contains no editable contracts,
assessments, or publication records. A separate baseline records canonical
hashes and executable flags. Materialization compares the baseline, current
files, and the selected revision before changing a view. Files are restored
with private permissions: `600` for regular files and `700` for executables.
Text edits preserve an existing executable flag; mode-only edits are checkpointed
and verified against the committed Fossil manifest. Filesystem ACLs and special
permission bits are not portable workspace data. Earlier baselines are
upgraded without discarding local drafts. Version 3 tracks only materialised
canonical files. New views remain empty until file tools request content or
skill discovery requests its instruction indexes. File mutations fetch the
target before permission preflight, preserving existing-file approval rules.
File searches fetch the selected managed directory; loading a skill fetches its
package. Shell execution fetches the complete personal view before the process
starts, since arbitrary operating-system reads cannot use the tool hook.
Hydration and checkpoints share a kernel-owned projection lock. Content hashes
are computed and materialised in separate per-file allocation scopes rather
than retaining every fetched body. A private hydration intent retains expected
hashes before writing files. Recovery adopts present files and preserves their
local edits; it never treats an unwritten intent entry as a deletion. Baseline
metadata is bounded to 8 MiB before atomic publication. Divergent changes stop with
`WorkspaceProjectionConflict`; local drafts remain available. Deletions require
a known baseline. A view with uncheckpointed edits must not be discarded as
cache garbage. Views retain the existing limits of 8 MiB per file, 256 MiB of
materialised content, and 10,000 files. This does not provide a transparent remote
filesystem or a sandbox for company actors.

Managed turns also hold a shared kernel pin for their view. Captured-command
workers own an additional pin; the foreground supervisor and shell inherit its
descriptor. Persistent terminal launchers retain the corresponding task pin
after a turn releases its execution lease. Closing a parent descriptor does not
explicitly unlock a lease that a child still holds. Pins contain no credentials
or execution authority and remain outside portable company state. Their private
lock directory sits beside the physical views, so different repository bindings
cannot disagree about whether that same view is in use.

An agent terminal carries its host-selected task identity through native
startup. The server checks the task's project against its authenticated terminal
grant and checks ownership through the canonical task ancestry. Company tasks
still require an isolated execution backend. A child task can have a different
project from its parent when the terminal grant authorises that project. Clients
cannot supply a lock-file path through terminal request parameters.
The native Darwin spawn adapter preserves these explicit descriptors separately
from its process-tree witness.

New view directories include the repository binding hash. Copies of a repository
therefore share immutable canonical objects without sharing mutable drafts. An
owned legacy baseline keeps its original directory; legacy views remain outside
automatic collection because older process launchers do not retain lifetime pins.

`fossil cache status`, `prune`, and `trim` report view retention reasons. Pruning
requires an accepted personal task, exclusive task and lifetime locks, and the
projection lock. It scans every local entry, including directories deliberately
omitted from normal checkpoints. Unknown files, execution caches, missing baseline
files, pending hydration, and mismatched canonical hashes prevent deletion. The
collector renames a clean view into quarantine and verifies it again before
removal. Interrupted quarantines remain available for inspection. Baselines and
Fossil history are retained.

Fresh execution policies bound clean cached views to 256 MiB and 32 views.
The `projections` field is omitted when absent in legacy policies, preserving
pinned policy hashes. Saved managed turns, the writable service, and the persistent
UI host share one kernel-owned background maintenance lease per repository binding.
The worker runs a cancellable 15-second pass every 30 seconds. Turn shutdown joins
its worker before releasing borrowed state or execution and resource leases. Standalone cache commands are bounded
to 30 seconds. Protected drafts and resources do not count as evictable cache.

Task context lists bounded memory and skill inventories independently of body
previews. Oversized files remain discoverable through `omos_memory` and
`omos_skill` query pages. Managed skill calls prefer complete versioned packages
over compatibility copies with the same name. Skill installation in a saved
turn targets the task view. Runtime executables and system dependencies still
require a compatible host environment.

The native `profile.read` and `profile.update` methods store the local owner's
photo as an `omos_profile` record and a content-addressed image. The UI imports
an existing local photo only when no canonical profile record exists. Removing
a canonical photo does not re-import the old file. Original local files remain
available during migration. Profile updates require the profile entity in the
current declaration; existing installations must update their contracts first.

## Scoped company service

Signed `status` with `entity: "omos_workspace_view"` lists only views owned by
the authenticated actor and grant. Check `features.owned_views` before using
this operation. Pages contain at most 32 bounded task headers, including the
current task revision, contract version, review state, and verified publication
status. They omit evidence bodies and other actors' objectives. Carry the
returned `index_revision` and `next_offset` into the next request to preserve
page membership while new views are created. Task status can advance between
pages. Every request rechecks live authority; a saved page position does not
preserve access after revocation. The index is derived from Fossil manifests
and does not introduce another task database.

`features.conversation` advertises a read-only conversation projection. Use
signed `status` with `entity: "omos_company_conversation"` and an owned `view`
to retrieve the original request, amendments, and retained answer. The
`conversation` object contains SHA-256, size, encoding, byte offset, and a next
position. Requests read at most 16 KiB. Continue with the returned immutable
`revision`; concurrent checkpoints do not alter those bytes. The answer remains
an `actor_claim`. Acceptance requires the separate verified publication receipt.
Other actors' views and unrelated private revisions are rejected.

When `features.scoped_inventory` is true, `discover` accepts a `path` selecting
one file or an entire directory. The current grant must cover the selector.
Pagination and metadata inspection budgets apply within that selector, so
retrieving `ui/` does not hash unrelated company document bodies. The selected
revision remains pinned and no additional authority is granted.

`features.inventory_export` additionally permits `export_scope` with a directory
`path`. It returns the same bounded inventory within that directory. This
requires an explicit export grant covering the entire selector. As with file
exports, inspection creates no task input dependency or company control commit.
Presentation clients use this operation and file exports to render an interface;
actor tools retain their normal tracked reads. A grant for presentation does
not grant task mutation or hosted execution.

`features.actor_archives` advertises public worker-history retention. The owner
uses `omos_company_archive_admin` through the private archive endpoint. It
requires a live execution generation and stores immutable content objects plus
the owning task's scope and upload checkpoint. `omos_company_archive_read`
projects complete archives through signed `status` with
`entity: "omos_company_archive"`, an owned `view`, and optional `record_id`.
List pages contain at most 32 entries. Content requests return at most 16 KiB
with the original file SHA-256 and immutable control revision. Revocation and
the original path scope are checked again for every request. Archive contents
are labelled `actor_public_history_only`; they cannot replace company checks,
assessments, or publication receipts.

`features.worker_checkpoints` advertises the host-only
`omos_company_worker_checkpoint` operation. Its worker `change: "checkpoint"`
requires a live execution fence and expected worker-record hash. The optional
checkpoint records a stable image identity, original runtime and generation,
source revision, model handle, phase, and export-directory basename. Phases
advance through `prepared`, `running`, `stopped`, and `retained`. A replacement
generation preserves an unfinished image instead of dispatching another actor.
Successful submission marks the invocation retained as part of the native
worker outcome. Omitting the optional field preserves legacy request hashes
and record encoding.

`features.desired_state` requires `omos_company_desired_admin` and
`omos_company_desired_read`. Accepted `company_desired_capability` records
express intent. Protected operator policies assign the actor, scope, execution
capability, and invocation allowance. The host retains an intent before task
creation and pins the target hash, policy hash, and reconciliation episode in
the task's authority binding. Publication rechecks these pins and rejects a
candidate that rewrites its own target. Superseded episodes remain inactive,
including after restoring an older target document.

The worker supervisor can enable continuous checks with its private
`reconciliation` flag. Native ticks compare selected immutable file identities
against the last verified publication. An unchanged result creates no actor
work. Scoped status pages expose only the current actor and grant's assigned
policies; membership is pinned while live permission checks remain mandatory.
See [desired capability reconciliation](../../../deployment/company/DESIRED.md)
for the record, operator request, budgets, and status protocol.

The local operator can initialize company authority using
`omos fossil company REQUEST.json --json`. Administrative requests use
`omos.company-admin/v1`; actions are `initialize`, `status`, `grant`, `revoke`,
`rotate`, `inspect_proposal`, `approve`, and `deny`. Mutations require the
control revision returned by `status`.
Root grant enrollment requires local operator access. Definitions cannot grant
server authority.

`omos fossil company-key HANDLE --json` creates a local Ed25519 actor key and
returns its public key. Repeating the command preserves the existing key;
concurrent callers receive the same identity. The seed stays in the private
profile directory `~/.fx/company-keys/` with mode `0600` and is excluded from
workspace exports. Back up these credentials separately from company content.
The command also works without a local repository. An operator must enroll the
public key in a scoped company grant before it can authorize service access.

For a grant with `human_approval: true`, submit the proposal normally. Its
review job remains blocked without spending inference calls until an operator
records a valid approval. `inspect_proposal` takes the current control
`revision` and the `view` identity. It returns the exact proposal inputs and a
`candidate_hash`. An `approve` or `deny` request supplies those same fields,
the returned `candidate_hash`, and `expires_ms`. Decisions expire within
24 hours and cannot outlive the grant. A busy task returns
`WorkspaceExecutionBusy`; the operator can inspect it again after the current
execution releases ownership.

Approval binds the actor, grant, authority epoch, task, accepted base,
submitted revision, integration revision, task contract, pinned model and
policy, retained answer, and changed content. Edits or a new integration base
require a new decision. Denial, expiry, grant revocation, and issuer recovery
cannot be bypassed by retrying a queued review. Approving queues independent
verification with the retained evidence; it does not run the actor or declare
the task successful. Publication checks approval again under the writer
boundary and includes its hash in the signed publication proof. Historical
verification uses the decision and authority revision recorded at publication,
so later revocation does not erase a valid historical outcome.

Decisions are signed host records at `company/approvals/<task>.json` on the
protected company branch. The local operator is the identity with privileged
access to this installation. Scoped actors cannot call the operator interface
or edit these records. An organization identity provider and a remote human
approval interface require separate integration. Older profiles retain grant
and issuer recovery commands, but proposal decisions require the updated
`omos_company_admin` operation and `omos_company_approval` entity declaration.

Authority, view bindings, and operation outcomes live on the protected
`omos-company` branch in the same repository. Grants bind an actor's Ed25519
public key, allowed actions, exact paths or directory prefixes, expiry, and an
optional parent grant. Delegation can only narrow a parent's scope, operations,
expiry, and approval conditions. Ancestor revocation invalidates descendants.

`GET /v1/company` returns public instance discovery. `POST /v1/company` accepts
an envelope with `payload` and `signature`. The signature is hex-encoded Ed25519
over the exact UTF-8 payload bytes. The payload binds the workspace, actor,
grant, unique operation ID, expiry, action, and action parameters.
`omos.company/v1` retains the existing operations and byte-only file responses.
`omos.company/v2` supports `discover`, `read`, and `export_scope` with signed
executable flags. Mutations still require version 1. Both versions enforce the
same authority rules. File attributes require an updated company declaration;
unsupported representations fail before execution. Requests expire within five minutes. Browser-origin requests are
rejected; the existing shared bearer token remains a local-owner interface.
The company transport and operation shapes are declared in OmniForm.

The native `fossil remote` client discovers the company issuer through the same
configured HTTPS or loopback endpoint before sending a signed request. It
checks the receipt signature, issuer, epoch, workspace, actor, grant, operation,
action, and hash of the exact request bytes. A mismatched response fails the
command and is not retried. Discovery and actor requests never forward the
local owner's bearer token, and redirects are not followed. The configured
endpoint is the trust anchor for discovery; a receipt's embedded public key
alone does not establish an organization's identity.

After sending a mutation, a missing or rejected HTTP response reports
`WorkspaceServiceOutcomeUnknown`. An unverifiable receipt reports
`WorkspaceServiceOutcomeUnverified`. Neither establishes that the action
failed: inspect or reconcile the original operation before retrying it. The
client never silently sends another mutation to repair a response.

An optional MCP stdio companion forwards the same native signed operations.
Its fixed client configuration supplies the actor, grant, workspace, issuer,
and epoch. It verifies original receipts and retains no separate product state.
See [the company deployment guide](../../../deployment/company/README.md#connect-an-external-mcp-client)
for enrollment, protocol versions, request bounds, and uncertain outcomes.

Supported actions are `discover`, `read`, `create_view`, `checkpoint`, `submit`,
`status`, `export_scope`, `delegate`, `reconcile`, `query`, and `record`. Reads
and inventories enforce the live grant and restrict historical revisions to
accepted ancestry or the caller's own view. Content reads use bounded base64
byte ranges and SHA-256 hashes. Canonical filenames are case-sensitive even
when the host or repository defaults to case-insensitive lookup. Checkpoints
reject new ASCII case collisions before changing working files.
When declared, version 1 `checkpoint` requests can set an `executable` boolean.
Changing an existing file's flag requires its `previous_hash` and
`previous_executable`. New files have no previous flag; deletions cannot specify
a desired executable flag. Omitting `executable` preserves the existing flag for
text or binary updates. The whole-view revision fence still applies. Saved flags
are verified in the same checkpoint receipt as content and deletions. Conflicting
flags fail without changing the source branch, and retries retain the original
operation outcome.

When discovery reports `features.schema_discovery: true`, `discover` with
`entity: "*"` returns a scoped catalogue of custom record types. It lists at
most 32 names per page, with an offset for continuation. A grant needs the
`discover` action and a path covering records of that type. Host-owned types
and types outside that scope are filtered before counts and pagination.

Set `entity` to a listed name to retrieve its exact OmniForm contract.
`schema.content` contains a base64 byte range; `schema.sha256` and `schema.bytes`
identify the complete canonical entity declaration. Each byte range is bounded
to 16 KiB. Follow `schema.next_offset` and verify the complete hash after reading
all ranges. Retain the returned `revision` for later pages. The response also
identifies the full declaration's hash, revision, and semantic version.

With a view selected, schemas come from that task's pinned model even after
the accepted declaration advances. Without a view, they describe the selected
accepted revision. These reads also work on a read-only service and do not add
content dependencies: the model basis already retains their provenance.
The server rechecks live authority on each page. `scope_filtered: true` marks
the response as a projection; omitted types do not establish company-wide
absence. Schema discovery describes expected data and cannot establish that
a capability has been realised. Older declarations enable it through explicit
`omos fossil migrate --contracts`, which adds `omos_company_schema`.

Capability metadata has separate authority from file paths. The operator uses
`grant_capabilities` with a live `grant`, an explicit `capabilities` array, and
`expected_revision` matching the company control revision. `inspect_capabilities`
returns the current policy and revision. An empty array removes a metadata scope.
The protected `authority/capabilities.json` policy binds each assignment to its
grant hash and issuer epoch. Existing file grants receive no metadata scope by
default. Every delegated scope remains bounded by all live ancestors.

When discovery reports `features.capability_discovery: true`, use `discover` with
`capability: "*"` for the authorised capability catalogue, or a capability ID for
its selected realisation and transitive dependency metadata. Specify
`realisation` when the root has multiple choices. Every transitive capability
requires metadata authority before its resources are inspected. Unknown and
inaccessible names both return access denied.

The `omos.company-capability/v1` response identifies the definition revision,
hash, semantic version, and task model basis. Its `package` field contains
16 KiB base64 pages with a complete SHA-256 digest. Read and verify all pages
against the same revision. This is declared metadata: `file_verification` and
`runtime_verification` remain `required`, and no file bodies are retrieved.
Ordinary content reads continue to require path authority and retain their
usual read dependencies. A declared dependency cannot grant tool permissions.

A signed `delegate` request can include `delegated_capabilities` when discovery
advertises `features.capability_delegation`. The request pins the accepted
revision. Grant and metadata scope are committed together. Replaying a prior
delegation cannot restore a scope narrowed by an operator. Legacy delegation
without this optional field preserves its existing behavior. Explicit
`omos fossil migrate --contracts` adds these operations to older declarations
without changing active task contracts.

When public discovery reports `features.progress_history: true`, signed
`status` requests for the caller's own view can include `progress_cursor: ""`
to start a revision feed. Each page contains at most 32 `view_revision` events,
newest first, with complete revision and first-parent identities and the
committed timestamp. `limit` can reduce the page size. No document bodies,
filenames, host paths, commit comments, or other actors' private views are
included. Revision notifications do not establish useful progress or contract
completion; the status snapshot's job and publication receipt report those
separate outcomes.

The `progress` response uses `omos.company-progress/v1`. Drain `next_cursor`
until it is null, then retain `resume_cursor` for the next poll. Later pages
remain pinned to the first page's revision. Checkpoints arriving during paging
appear after resuming, without changing pages already being inspected. An idle
poll returns an empty event list. Each page shares a 30-second allowance across
admission, operation and issuer locks, Fossil reads, and receipt signing. A
timeout does not advance the caller's retained cursor. A shorter caller-owned
deadline remains in force.

Cursors are signed by the current issuer and bind the workspace, actor, grant,
view, epoch, stop revision, and pinned position. They supply no access authority.
Every request checks the live grant. Tampered, cross-view, cross-grant, or
obsolete-issuer cursors are rejected. Requests with progress cursors cannot
also select an operation outcome, revision, or byte offset. The cursor format
uses immutable first-parent identities, so restart and rebuilt local indexes
do not change its position. The feed stops before the view's original base.

Clients can poll this bounded feed or POST the same signed status envelope with
`Accept: text/event-stream` to subscribe. Discovery advertises
`features.progress_stream: "omos.company-progress/v1"` when the progress input
and the `omos_company_subscription` operation are declared. Each `workspace`
event contains the original signed receipt. Its `request_hash` binds the opening
actor request, including the starting cursor. The host advances only
issuer-signed continuation positions for that
same view and checks live authority, expiry, and the accepted operation model
before every page. Paging and new checkpoints follow the same cursor rules as
polling. No subscription database or additional authority token is created.

The SSE event ID is its progress page's `next_cursor`, or `resume_cursor` when
the page is complete. Verify the receipt signature, issuer, identity, and
opening request hash before retaining that ID. Reconnect by signing a new
status request whose `progress_cursor` is the last fully consumed event ID.
Native `EventSource` cannot send this authenticated POST; browser interfaces
need their trusted bridge or a signed streaming-fetch client. Browser-origin
requests remain rejected. The MCP companion continues to use JSON status calls.

At most four subscriptions run per service process. Each stream shares one
30-second allowance across initial admission, locks, reads, signing, and later
pages. A socket watcher cancels disconnected or expired streams, including
while initial admission is pending. Streams also stop after 32 workspace
events or 1 MiB of SSE body data, leaving room for transport termination.
Subscriptions treat request-side EOF as cancellation, including a write
half-close after the POST body. Keep the connection open while consuming the
stream and retain the last verified cursor before disconnecting.
Heartbeats, `error` events, `end` events, and connection closure are transport
information and never establish task acceptance. Grant revocation stops new
workspace events; reconnecting still requires live authority. Consumers keep
their last verified cursor across expiry, cancellation, and service restarts.

The optional MCP companion accepts the progress fields through
`company_workspace`. Older declarations do not advertise the feed; an explicit
`omos fossil migrate --contracts` adds its optional transport field and the
subscription operation while preserving existing constraints and task contracts.

When `features.chunked_upload` is true, `checkpoint` also accepts
`upload: { "sha256": "FULL_LOWERCASE_SHA256", "bytes": 1234567 }`.
Every part repeats the same actor, grant, view, target path, expected revision,
previous file hash and flags. Send base64 `content` at byte offsets that are
multiples of 131,072. Each part must contain exactly 131,072 bytes, except the
last part, which contains the remainder. The complete file is bounded to 8 MiB;
the HTTP envelope retains its separate 1 MiB limit.

A successful part returns `state: "uploading"`, the unchanged view revision,
upload binding, offset, byte count and part hash. Parts are immutable protected
`omos_company_upload` records on the company control branch. They survive a
service restart and replacement of local task indexes and scratch checkouts.
An identical part under a fresh operation ID returns the existing result;
a different part at the same bound offset fails with `CompanyUploadConflict`.
Normal operation IDs still identify uncertain requests and their recorded
outcomes.

To finish, send another signed `checkpoint` with the identical upload binding,
`offset: 0`, and omitted or null `content`. The host requires every part, checks
each part hash, assembles at most 8 MiB and verifies the full file size and hash.
Only then does the normal task checkpoint compare the expected revision and
previous file state. Missing or mismatched parts leave the task content
unchanged. Parts cannot be moved to another actor, grant, view, path, revision or
file state. Every request checks live authority, so revocation stops subsequent
parts and finishing. An upload does not publish or assess its file; those remain
the normal proposal and independent-review operations. Uploaded parts remain in
versioned control history after finishing or abandonment.

Public discovery derives `file_attributes`, `checkpoint_attributes` and
`chunked_upload` from the accepted operation declaration. An older declaration does not advertise these
features. Read clients fail with `CompanyDefinitionUpdateRequired` when the
signed attribute representation is unavailable; they do not silently discard it.

`export_scope` returns a paginated content manifest, or bounded base64 content
when `path` is supplied. An export-only grant needs no separate `read` action.
Export transfers inspect content without changing a task's observed input set.
They work through a read-only company service and enforce the live grant on
every request. Inventory responses declare `dependency_closure: "not_evaluated"`;
an empty list of external dependencies is not inferred from a file listing.

`omos fossil export-scope CONFIG.json OUTPUT.tar --json` downloads a file
snapshot at one complete, pinned revision. The configuration uses
`omos.scope-export-request/v1`:

```json
{
  "version": "omos.scope-export-request/v1",
  "endpoint": "https://company.example.com",
  "workspace": "your_company_workspace_id",
  "actor": "your_actor_id",
  "grant": "your_export_grant_id",
  "key_handle": "your_local_key_handle",
  "issuer": "your_trusted_company_public_key",
  "revision": "your_complete_accepted_revision"
}
```

Replace the identity placeholders with the company's enrolled values. The
issuer must come from a trusted enrollment or discovery channel. An optional
`view` selects the caller's own private view. Historical accepted revisions
remain subject to the grant's current scope. Actor signing seeds stay in the
private profile and never enter the archive.

The archive contains `manifest.json` and deduplicated `objects/<sha256>` files.
New `omos.scope-package/v2` manifests map original paths to hashes, sizes, and
executable flags and retain signed version 2 inventory receipts with their exact
requests. The export client requires a server that supports this representation.
Content objects remain private regular files; executable flags belong to each
original path. The client verifies every
response against the pinned issuer and epoch, then verifies the complete
archive before publishing it. Publication uses an exclusive file link and
refuses to replace an existing output.

`omos fossil verify-scope CONFIG.json ARCHIVE.tar --json` verifies the package
offline against the separate configuration pins. It requires no local Fossil
repository, actor key, or server connection. It checks object hashes and sizes,
manifest coverage, signed inventory pages, exact request bindings, and company,
actor, grant, view and revision identities. This establishes historical package
integrity; it does not establish that the grant remains live. Version 2 reports
`file_attributes: "verified"` after matching every flag to its signed inventory.
Changing or dropping a flag, or relabeling that inventory as version 1, fails
verification. Historical version 1 packages remain readable and report
`file_attributes: "unavailable"`. Neither format proves that a script can run
without its declared host dependencies.

### Selected capability packages

A version 2 export configuration adds a nonempty `selections` array. Its first
entry names the root capability; additional entries choose realisations for
transitive dependencies with multiple alternatives. For example:

```json
{
  "capability": "cv_builder",
  "realisation": "cv_builder_skill"
}
```

Place this entry in `selections` alongside the same endpoint, workspace, actor,
grant, issuer, revision, and key handle fields shown above, and set `version` to
`omos.scope-export-request/v2`. The server must advertise
`features.capability_packages: true`. The grant needs both `discover` and
`export_scope`, metadata authority for every capability in the closure, and
path authority covering every required directory or file selector in full.
A grant covering one file cannot establish completeness for its containing
directory. Missing files, missing metadata authority, undeclared skill inputs,
and ambiguous realisations fail before an archive is published.

Version 3 archives declare `scope: "selected_capabilities"` and
`dependency_closure: "declared_complete"`. They include the exact selected
capability, resource, and realisation definitions, dependency edges, declared
external handles, and issuer-signed paginated metadata proofs. Signed inventory
pages bind the same plan hash and revision. Unrelated authorised files are
excluded. Offline verification checks the metadata proofs, exact selections,
complete required-path coverage, file hashes, modes, and inventory proofs.
Metadata is bounded to 1 MiB and 64 pages. The declared graph still reports
`runtime_verification: "required"`; the archive carries no executable authority,
provider credentials, or host configuration secrets.

`omos fossil package import CONFIG.json ARCHIVE.tar --json` verifies a selected
capability package offline and retains its files, source manifest, and an
additive declaration candidate on an isolated task branch in the bound local
workspace. The source signatures and original company revision remain in
content-addressed artifacts. Existing content or definitions with different
bytes, flags, or identities cause a conflict. The destination declaration and
accepted files remain unchanged. Imported content is bounded to 256 MiB and
the retained manifest to 8 MiB.

The result identifies a paused task with obligations for files, destination
runtime dependencies, and declaration activation. Import does not execute
package programs or publish the branch. Resume that task through the normal
agent and independent-review path. Repeating the same import reuses its retained
task and checkpoint. A portable Fossil export preserves this pending work.

The local owner runs `omos fossil package verify TASK --bindings BINDINGS.json
--json` to check the retained package against explicitly selected destination
runtimes. The private bindings file has this shape:

```json
{
  "version": "omos.runtime-handles/v1",
  "handles": [
    {"handle": "node", "kind": "node", "executable": "/opt/omos/bin/node"}
  ]
}
```

Supported runtime kinds are `node` and `python`. Executable paths must be
absolute, regular executable files without group or world write permission.
The host rejects symlinks. It hashes each executable, records its file
fingerprint, and runs only the fixed version query in a clean environment:
`node --version` or `python -I --version`. Each query has a five-second ceiling
within the shared 60-second operation deadline and cancellation control.
Constraints accept exact versions or numeric minimums such as `>=22`.
Configuration and service requirements without a verifier remain unverified.
Definitions and imported files cannot supply probe commands.

The command saves bindings with owner-only permissions under
`~/.fx/runtimes/handles.json`; later checks can omit `--bindings`. The signing
key stays in the private profile. Signed receipts retain handle names, version
observations, executable hashes, and fingerprints without executable paths or
credentials. These observations verify the declared inputs and runtime
constraints. Functional behavior and external outcomes still need their own
contract evidence.

The canonical task records its package context and latest host receipt. A
managed agent can refresh that receipt with `fossil_workspace` action
`verify_runtime` for its currently leased task, but cannot supply private
bindings. Independent completion review receives a compact host receipt only
after live validation. Publication checks it again under the writer boundary
and atomically commits the files, additive declaration, implementation record,
and acceptance receipt. Missing, stale, or invalid evidence prevents activation.

`capability_search` reports `verified_workspace_implementation` only while the
accepted files, selected graph, private bindings, host identity, and executable
fingerprints match. Source changes, configuration changes, and executable
changes invalidate availability. Historical acceptance verification remains
possible without the private signing key or current runtime configuration,
including recovery after a commit whose acknowledgement was interrupted.

A portable export preserves accepted files and signed historical evidence; it
doesn't export private bindings or signing keys. Verifying an accepted import
on another host creates a separate retained verification task. Resume and
publish that task to establish destination availability. The original accepted
task remains immutable. An active managed task can adopt an accepted package's
references with `verify_runtime` and `path` set to the source task ID.

Exports use at most 32 inventory entries per page and 16 KiB per content
request. Files are limited to 8 MiB, inventories to 10,000 paths and 8 MiB of
receipt metadata. `max_bytes` defaults to 1 GiB of logical file content and
`deadline_ms` defaults to five minutes. Requests have a 30-second ceiling
clipped to that overall deadline; a timeout cancels and drains the operation
before its memory is released. The overall deadline can be configured from
100 milliseconds to one hour, and the byte budget up to 1 TiB. These are
bounds, not measured capacity guarantees.

A private adjacent `OUTPUT.tar.partial-<request-hash>` directory caches complete
verified objects. Retrying fetches a fresh authorised inventory and checks
cached size and full hash before reuse. Corrupt objects are downloaded again;
incomplete individual downloads restart from zero. A final authorised request
checks access again before publication. Revocation stops subsequent service
retrieval; previously downloaded plaintext remains with its recipient. Cache
files can be removed when no export process is using them.

Scoped exports also reuse immutable objects across output destinations through
the private profile cache at `~/.fx/cache/company-objects/`. Its retained
payload limit is 256 MiB and 4,096 objects. Writes share one lock and evict
objects by approximate last use. Cache inventory scans, lock waits, and object
reads inherit the export's cancellation and deadline controls. Files use mode
0600; directories use mode 0700. Reads reject symlinks and verify size and the
complete content hash.

Company identity, issuer, and authority epoch partition this cache. A fresh
signed inventory must authorise each object before lookup, including reuse by
another grant in the same company. The final live authority check still gates
publication when every content read was cached. Corrupt objects trigger
verified retrieval. Cache loss affects reuse; the pinned company revision
retains the original content. `shared_cache` reports this operation's cache
hits, misses, stored bytes, and evictions. The host validates the export summary
against its OmniForm operation schema before publishing the final archive.

This limit covers the shared immutable object cache. Adjacent export staging
directories retain their separate recovery files. Task filesystem views and
private edits have their own lifetime and are not evicted by this cache.

This package declares `scope: "grant_file_snapshot"` and
`dependency_closure: "not_evaluated"`. It includes the listed files, rather than
a company repository clone, issuer authority, execution ownership, or a verified
closure of capability and external runtime dependencies. Complete capability
packages require a separate dependency-closure assessment.

Reads attached to an active view record their inputs on the protected company
branch. The response includes `read_tracking: "recorded"` and an `observation`
reference. Tracking does not change the view's content revision. Authorized
missing-file reads return `exists: false` with a null hash, so absence becomes
an explicit dependency. Version 2 file observations bind content and executable
flags as one state. A later byte-only read cannot replace that attribute
dependency. Historical
read identities remain hashes of their original stored bytes, independent of
new host fields and defaults. Query and inventory observations retain scoped
result membership as well as hashes for returned files or records. Inaccessible rows
never affect that membership.

Submission pins these observations to an immutable control revision before
integration. Refresh preserves them. Validation runs before reconciliation,
before independent assessment, and at publication. A changed file, a missing
file becoming present, a changed returned record, or a changed query membership
returns `WorkspaceReadDependencyChanged`. The failed submission releases its
operation fence; the actor can read the relevant inputs at a newer authorized
revision and submit again. Re-reading a selector updates the active reference
while preserving previous observations in Fossil history. Changes outside the
observed scope do not invalidate a result. Private edits still use the normal
three-way conflict checks.

Queued, running, and accepted views serve reads as `frozen_inspection`, without
changing the submitted inputs. Reading an active view through a read-only
service returns `CompanyReadTrackingRequired`; unbound scoped reads remain
available. A view retains at most 100 active read selectors. It returns
`CompanyReadSetTooLarge` before delivering an unrecorded result when that bound
would be exceeded. Observations use the `omos_company_read` entity and live at
`company/reads/<task>/<hash>.json`. Publication proofs bind the frozen read set,
and exported history retains its original observations.

Before freezing inputs or refreshing a submitted branch, the host records an
`omos_company_submission` intent at
`company/submissions/<task>/<request-hash>.json`. It retains the exact request
identity, initial revision, contract and model hash, answer hash, and input
references. An interrupted submission remains fenced until a fresh signed
`reconcile` request resolves it. Recovery reuses those inputs even if later
inspection added other active observations. Completed actor actions are not
repeated. A deterministic input-change failure releases the operation fence
and retains the failed outcome for a corrected submission.

Instance discovery advertises `read_dependencies` and `operator_approvals` in
`features`. Older company views keep their original stored shape until the
declaration supports read tracking. New tracked reads and submissions return
`CompanyDefinitionUpdateRequired` when those contracts are absent. Update them
with `omos fossil migrate --contracts`; existing task contracts, grants,
private files, and operation outcomes remain retained.

`query` enumerates custom entity records at an authorized pinned revision. Path
permissions and the optional `entity` filter apply before totals and pagination,
so inaccessible rows do not affect the returned count. Pages contain at most
32 records and 64 KiB of record data. Rows larger than 8 KiB become references
with their original path, revision, byte size, and SHA-256 identity; retrieve
those bytes through bounded `read` calls. A historical revision preserves its
original query results.

New references contain the complete Fossil check-in hash: 64 hexadecimal
characters for SHA-3 or 40 for legacy SHA-1. Earlier hosts retained Fossil's
40-character display abbreviation for SHA-3 objects. Historical retrieval
resolves those references only against authorized ancestry and returns the
complete identity. Ancestry requests use bounded pages. Recovery preserves
historical receipt bytes, operation identities, and signatures; it does not
rewrite them to change the reference format.

`record` requires explicit operation authority and a writable view. Supply
`entity`, a stable `record_id`, JSON text in `content`, and the expected view
revision. The path is `records/<entity>/<record_id>.json` and must fall within
the grant. The task's pinned OmniForm declaration validates the data. Updates
and deletions also supply the previous record hash; `remove: true` deletes a
record. Different records can reconcile independently. Concurrent changes to
the same record remain subject to the file conflict boundary and independent
assessment. Existing content-addressed records retain their identities.

Decoded record content, including fields declared as `json`, uses the same
64-level and 20,000-value boundary as declaration validation. This check runs
before privacy filtering and serialization. A bounded outer transport string
does not exempt its decoded contents. Excessive trees and prohibited object
keys fail without changing the view; the operation remains inspectable as failed.

Company actors cannot write `omos_` entities or bypass validation by sending a
raw checkpoint into `records/`. Structural validation failures retain a failed
operation receipt and release its view. `CompanyRecordNotPortable` rejects
values that privacy filtering would silently change, including optional fields.
A corrected request uses a new
operation ID. Uncertain persistence failures keep the view fenced for recovery.
Typed writes and their checkpoint receipts commit together. These are draft
changes until independent review and authorized publication succeed.

Each company view retains its own task branch, base revision, contract, and
private changes. Unchanged files reuse Fossil content objects. Scoped actors
retrieve content through the service; they receive no access to the host's
scratch directories. The host serializes task mutations through one reusable task checkout and uses
one integration checkout for publication. Personal and company tasks share this
rule; definition proposals also reuse one checkout. Creating more tasks or views
does not create another host checkout for each actor. Agent filesystem views
remain separate. Dirty host scratch is retained in a private recovery directory
before rebuilding, including when its revision has not changed. Recovery copies
and earlier cache layouts are retained; they are not silently evicted. These host
checkouts can still materialize a complete revision. Personal task tools fetch
their selected files on demand; arbitrary shell commands hydrate the full view.
Clean accepted personal projections use the bounded collector described above.
Personal projection hydration reuses the profile object cache after selecting
an object from a verified canonical Fossil manifest. A separate personal scope
and object-key domain isolate it from signed company export caches. Each lookup
verifies the full Fossil SHA-1 or SHA-3 identity; cache names never supply
retrieval authority. Corrupt or missing cache files fall back to Fossil. View
files are copied and never hard-linked to immutable cache objects. Both cache
namespaces share the 256 MiB and 4,096-object storage bound. Scoped exports use
the signed-inventory path described above.

Mutations retain a request hash and pending outcome before effects. Completed
retries return the saved result after a fresh authority check. Reusing an
operation ID for different bytes is rejected. Checkpoint receipts commit with
the changed files. Acknowledgement verifies exact paths, saved bytes, deletions,
and the change set against the committed revision. Recovery and assessment
repeat these checks against the original receipt commit; a receipt alone cannot
establish that the intended content was saved. A corrupted checkpoint remains
uncertain and is never replayed or accepted through its receipt. An uncertain
operation retains ownership of its view until reconciled. `status` can inspect
an outcome using its original operation ID. The outcome retains the exact signed
request and final signed receipt. Original request bytes are available through
bounded base64 pages with a SHA-256 identity, so another authorized client can
inspect the retained intent without relying on the first client's files.
Receipts identify the actor, grant, operation, authority epoch, and result.
When a status or reconciliation request also selects a view, the retained
operation must belong to that view. This check includes execution operations
whose recovery journal does not hold a view lock and completed view-creation
operations. An unresolved creation cannot be associated with an arbitrary view.

An expired envelope remains expired, including when a cached result exists.
An actor with explicit `reconcile` authority can send a fresh signed request
whose `outcome` names an existing operation. Recovery verifies the original
signature and the current grant, then reconciles that operation's retained
Fossil effects. A committed checkpoint is acknowledged without committing it
again. A submitted proposal whose review already published returns its retained
job. This path dispatches no external command or provider action. Legacy outcomes
without a retained request remain inspectable; they cannot use this recovery path
to invent missing intent.

Issuer seeds remain in protected profile storage under `~/.fx/authority/`,
outside the repository and disposable checkout caches. Immutable seed files
have mode `0600`. An atomically published descriptor binds the issuer to one
repository path, workspace identity, and authority epoch. Interrupted creation
can retry without adopting a partial seed. All company mutations and publication
share a per-workspace operation lease on the host.

The protected descriptor also records the last observed company control and
accepted revisions. Issuer use requires both current heads to descend from those
observations. The host advances these observations after committed mutations
and publication, before acknowledging success. An older repository restored at
the same path, or an accepted branch moved backwards, returns
`CompanyAuthorityRollbackDetected`. Explicit recovery rotates the key and
revokes existing grants. A descriptor from an earlier installation records its
first observed heads when the upgraded runtime uses it.

Stored heads constrain issuer use; authority policies remain versioned in
Fossil. The descriptor and its seeds are protected recovery material rather than
disposable caches. Restore both the repository and protected issuer material
through explicit rotation: local observations cannot detect a rollback of both
together and do not replace an external authority or distributed coordination.

Copying a repository does not restore issuer power. Explicit operator rotation
advances the epoch, creates a new key, and revokes existing grants. When the
protected descriptor names another local repository, recovery compares committed
history while holding that source's writer lease. `CompanyRecoverySourceAdvanced`
means the copy is stale: preserve it, export the current source again, and retry
with the fresh copy. Successful activation fences requests and publication from
the previous local instance. An unavailable recorded source requires recovery
of that source before local rebinding. A new host has no such descriptor;
operators must fence the previous host before activating recovered authority.
The local lease does not coordinate independent machines. Back up protected keys
separately from portable company content.

Submission retains an immutable proposal, integrates compatible accepted
changes, and queues independent review. Candidate files and host checkpoint
receipts enter the assessor's evidence manifest. Publication checks live
authority and the evaluated parent revision again. Independent reviews run on
separate workers, with capacity pinned in `execution/omos.json` at server
startup. Each claim follows the task's atomically committed current job pointer;
retained historical jobs cannot become active by being rediscovered.

If accepted state advances during assessment, the coordinator refreshes a
compatible unpublished candidate and independently assesses it again within the
same job's attempt, time, and token allowance. It never renews that allowance or
replays actor tools. Conflicts and changed observed inputs require revision.
An existing publication intent stays under publication recovery. Grants requiring
human approval need a new exact decision after integration changes.
Inspection compares an original proposal with its own recorded base. An
interruption after committing refreshed state cannot make that retained
proposal impossible to inspect or approve against the new base. Integration
receipts preserve the original operation and candidate revision. Hosted company
actor execution requires a registered live isolated backend and an explicit
compute grant. External runtimes use the same scoped service operations.

New company publications retain an issuer-signed authorization proof in their
Fossil acceptance receipt. The proof binds the actor, grant, task, exact source,
evaluated target base, contract hash, candidate hash, assessment hash, authority
revision, epoch, and issuance time. `status` for an accepted view returns the
receipt hash, this proof, and the check-in that published it. Later accepted
changes do not change that resulting revision. Verification uses the public
issuer and authority state retained at the signed revision; exporting and
checking a repository does not require its issuer seed. Historical unsigned
receipts retain their original format and are not retroactively signed.

The signed proof records what the issuer attested. A verifier must establish
trust in that company issuer separately. The resulting check-in contains the
proof; it cannot embed its own final check-in hash. Fossil ancestry and the
immutable receipt path connect the proof to the resulting revision.

Protected company-control records use a metadata-only host checkout and commit
only explicitly named changed files. The first authority commit creates its
control branch atomically; an interruption before that commit leaves the
instance uninitialized and permits a retry with the prepared issuer key. Unchanged company content stays referenced
in Fossil and is not materialized in that scratch directory. The host compares
the complete parent and resulting manifests, verifies the changed object hashes
and saved bytes, and rejects unrelated changes. Healthy scratch files are removed
after verification. An interrupted or independently edited scratch tree is
retained under a recovery name before reuse. Generic add/remove scans and
incremental VCS import are not used for these writes. Task content, publication,
and actor filesystem projections keep their existing paths; this change does
not provide a remote filesystem mount or fully sparse actor views.

This service supports path scopes and file or record conflict boundaries.
Capability packages follow explicitly selected declared dependencies. Hosted
workers require the separately configured Linux isolation boundary; desired-state
reconciliation requires separately delegated operator policies. A signed request
or successful checkpoint does not enable either feature. Field-level record
merges, remote filesystem mounting, and federated identity enrollment remain
unsupported.

## Company activity

`omos_company_activity` retains bounded public worker events on the control
branch. The host checks live execution ownership before append and live scoped
retrieval authority on each read. Activity cannot establish execution or task
completion. See [Public worker activity](../../../deployment/company/ACTIVITY.md)
for the transport and cursor contracts.
