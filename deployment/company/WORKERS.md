# Isolated worker runtime components

The worker launcher and Unix broker provide an execution boundary for the
company coordinator. They do not enroll actors, create grants, or publish
company state. The gateway still reports `hosted_execution: false` until its
coordinator is connected to a verified backend. External actors continue to use
the signed company service.

## Check the Linux host

The launcher requires Python 3.11 or newer, Linux x86_64 or arm64, pidfds,
Landlock, and operator privileges. Its default mode also requires private
mount, process, network, IPC, and UTS namespaces. Check the actual kernel:

```sh
sudo /usr/bin/python3 -I deployment/company/worker-launcher.py --probe
```

`kernel_supported` identifies the required kernel interfaces.
`private_namespaces` reports the result of an isolated namespace creation
attempt. A launcher that cannot establish the requested namespaces exits with
code 125 before running the actor. It never automatically falls back to a
different isolation mode. The namespace-free mode is reserved for explicit
component tests and does not support the hosted shell lifecycle.

Linux CI requires private namespaces and exercises the shell path. Component
tests on a restricted host can still verify the filesystem boundary, credential
separation, Unix transport, Fossil publication, and export. macOS clients can
use the company gateway; this launcher is Linux-specific.

## Prepare an image as the operator

The coordinator must prepare the image from trusted runtime packages and the
actor's authorized inputs. Copy mutable files into independent inodes. Do not
hard-link them to accepted state or move directories out of an active image.
The image root and executable hierarchy must be root-owned and unwritable by
the actor. The actor's working directory is `/workspace`, its private profile
is `/home/worker`, and temporary files live under `/tmp`.

Provide a matching worker account in the image's `/etc/passwd`, with the
allocated UID, `/home/worker`, and an installed login shell. Include only the
runtime binaries and libraries required by the declared implementations. The
native executable and Fossil helper live at `/runtime/bin/omos` and
`/runtime/bin/fossil`. The launcher creates private procfs and devpts mounts
before dropping privileges; its image must provide the corresponding parent
directories and permitted basic devices.

Store this descriptor as `.omos-worker-root.json`, owned by root with mode
`0600`. Replace the identity and hash placeholders with verified values:

```json
{
  "version": "omos.worker-root/v1",
  "uid": 1000000,
  "workspace": "COMPANY_WORKSPACE_SHA256",
  "view": "COMPANY_VIEW_SHA256",
  "generation": 1,
  "source_revision": "COMPANY_VIEW_REVISION_SHA256",
  "max_runtime_ms": 300000,
  "executable": "/runtime/bin/omos",
  "executable_sha256": "VERIFIED_EXECUTABLE_SHA256"
}
```

The launcher checks the descriptor, executable ownership and hash, and the
allocated UID's availability. A protected host lease prevents concurrent reuse
of that UID. Image preparation and company execution ownership remain the
coordinator's responsibility. A descriptor grants no company authority.

Invoke the root-owned installed launcher with an isolated interpreter:

```sh
sudo /usr/bin/python3 -I deployment/company/worker-launcher.py IMAGE_ROOT -- ask "TASK_GOAL" --json
```

The child enters its prepared root and working directory, drops supplementary
groups, changes all UID and GID identities, clears effective, permitted,
inheritable, and ambient capabilities, and sets `no_new_privs`. Landlock confines
filesystem access and, where supported, scopes Unix abstract sockets and
signals. Seccomp rejects IP sockets, namespace changes, tracing and cross-process
memory access, descriptor theft, and io_uring network bypasses. The default
private namespaces provide procfs and terminal support without exposing host
processes or devices.

Only standard input, output, and error survive exec. Explicit Unix stream
channels are accepted for piped stdio; inherited IP sockets and directory
handles are rejected. The child receives a fixed environment, without provider
credentials or the caller's environment. Process, file, data, CPU, and invocation
limits bound execution. Parent-death signals and the private PID namespace
terminate descendants when their execution owner is lost. Normal cleanup also
uses stable pidfds to avoid signalling a reused PID.

## Keep service credentials in the broker

`worker-broker.mjs` exposes a Unix socket to the isolated runtime. The native
process uses `OMOS_WORKER_BROKER=/run/omos-broker.sock` to route its IP connection
requests through that socket. The launcher blocks direct IP sockets; the
transport adapter itself is not an isolation boundary.

### Connect a worker to its company view

The host can import `createCompanyClient` from `mcp.mjs` and load an operator's
private company-client configuration. Pass `home` explicitly when the key
belongs to a separate operator profile. The configuration and key retain the
same private-file checks as the installed stdio companion.

Create a worker client with a host-selected `binding` containing `view`,
`execution: { runtime, generation }`, `expiresMs`, and `actions`. The binding
can expose discovery, reads, checkpoints, typed records, submission, status,
and reconciliation. It cannot expose grant delegation, view creation, or
execution ownership changes. The host must claim the execution generation
through the signed service before starting the worker.

Pass this client as `companyClient` to `createWorkerBroker`, with matching
company identity, view, actions, and expiry. The private Unix route
`/company/mcp` exposes `company_context` and `company_workspace`. Configure the
native MCP client with `http://127.0.0.1:1/company/mcp`; the explicit port
satisfies its loopback transport policy, while the Unix adapter carries the
connection. The worker receives neither a signing seed nor an owner token.

The host supplies the view and execution fence on each signed operation.
Worker-supplied overrides are rejected. Outcome lookup and reconciliation are
limited to operations issued through that client, and the native service also
checks that a requested outcome belongs to the selected view. Requests retain
their original operation IDs and expiry values. An uncertain mutation is not
automatically retried. A replacement runtime must inspect the retained outcome
and reconcile it under its current authority before attempting further work.

The HTTP MCP transport is stateless and returns bounded JSON responses. It
supports the same 2025 protocol versions as the stdio companion and advertises
them when a client requests a newer version. Closing the broker cancels its
active requests; closing the company client cancels its active signed calls.
The client expires with its binding, independently of the execution lease
that the native company service checks on each operation.

The durable job coordinator and image preparer described below use this
connection. The gateway continues to report `hosted_execution: false` pending
qualification and gateway integration of the complete backend.

The broker accepts fixed model and company routes. Model calls map an allowed
worker model handle to a configured provider model and receive credentials
only in the host's outgoing request. Company requests retain their signatures;
the broker checks the pinned identity, allowed actions, and any specified view
before the gateway applies its current authority rules. Arbitrary destinations,
redirects, caller credentials, and cookies are not forwarded. Provider error
bodies are replaced to avoid returning echoed privileged headers.

The default limits allow 256 requests and four concurrent operations per
invocation. Requests are bounded to 8 MiB for model calls and 1 MiB for company
operations; responses are bounded to 16 MiB. Each operation is clipped to the
invocation expiry and a two-minute ceiling. Closing the broker cancels active
requests. These transport limits supplement the task's actor and review budgets.

Sockets use mode `0600` by default. Sharing a socket with a separate worker UID
requires a private host directory boundary, an operator-owned socket directory,
and an explicitly selected socket mode. The broker validates that boundary
before listening. The actor cannot replace the socket or reach another worker's
physical image through its prepared root.

Native directory resolution can recover a descriptor-bound path without procfs
by walking parent identities and reopening every component without symlinks.
It rejects deleted directories, ambiguous identities, inaccessible ancestors,
and paths that change during verification. This permits private profile and
Fossil operations in constrained component tests without weakening file access
or mounting host procfs.

## Retain worker dispatch in Fossil

The local operator API stores worker jobs under `company/workers/` on the
protected company-control branch. Each job pins its task intent, company view,
actor, grant, declaration, and execution policy. The task retains ownership of
its contract, proposed content, evidence, assessment, and publication receipt.
Worker jobs record dispatch and invocation limits.

New instances declare `omos_company_worker_admin` and
`omos_company_worker_job`. An existing company must explicitly migrate its
contracts before using these operations. Active task definitions retain their
original revisions.

Save this request in a private operator file and invoke
`omos fossil company REQUEST.json --json`:

```json
{
  "version": "omos.company-admin/v1",
  "action": "workers",
  "worker": {
    "change": "inspect",
    "offset": 0,
    "limit": 32
  }
}
```

Inspection returns up to 32 job metadata records with content hashes, live
authority status, execution ownership, review state, and any verified
publication. Follow `next_offset` for further pages. Add `view` to retrieve one
job's task contract, original request, amendments, and policy context. The host
releases each inspected task body before loading the next record. Inspection
remains available after actor revocation so an operator
can account for retained and cancelled work.

Queue a view with `change: "queue"`, a unique `operation`, and its `view`.
The actor's current grant must permit execution, status, and submission within
the task's scope. A grant that requires human approval can prepare and execute
its task; that approval is checked against the evaluated publication candidate.
Defaults permit three invocations of at most four minutes each. The operator
can select 1–32 invocations and a runtime limit between one second and four
minutes. These limits supplement the task's actor-step, progress, and review
budgets. Changing them does not weaken the task contract.

Further updates carry `expected_sha256` from the returned job row. A claim
includes an `execution` runtime identity and the preceding generation. The host
commits the new execution fence and running job in one Fossil revision. Claim
recovery returns the original acknowledgement, including when a newer worker
has since taken ownership. Reusing the operation ID for different request bytes
is rejected.

`finish` records a `waiting`, `submitted`, `failed`, or `completed` outcome under
the current live fence. Waiting work requires an explicit `requeue`; exhaustion
does not automatically grant another invocation. Submitted work requires a
retained server review job. A submitted job can be requeued after review finishes
without publication, within its remaining invocation budget. Completion requires
verified company publication.
The operator can use `complete` after asynchronous publication without restoring
an expired worker lease. `cancel` retains the job and releases only its matching
execution owner. These transitions do not replay actor tools or external effects.
An `expire` request retains a worker whose invocation lease has elapsed as
waiting or exhausted, according to its remaining budget. It releases only that
job's matching execution fence. Each successful transition retains its original
typed request and request hash alongside the resulting job record.

Job records and their immutable operation history travel with a full Fossil
export. Private issuer material, provider credentials, actor signing keys,
prepared images, and provider replay caches remain outside that export. Restoring
a job history does not grant a runtime permission to execute it.

### Connect an operator coordinator

`worker-control.mjs` provides the private Node.js transport for these operations.
`createWorkerControl` requires the native binary's SHA-256 identity, a private
operator home, the project directory, and the expected workspace identity. It
pins the repository path and file identity and checks the executable fingerprint
before each invocation. A changed binding requires a new control instance.

The transport invokes only native `company` requests with action `workers`.
It uses private temporary JSON files, bounded output and deadlines, and a
restricted child environment. It deletes transport files after each call.
Requests and outcomes remain in Fossil. An interrupted or failed mutation is
reported as uncertain; inspect its original operation before dispatching an
actor or repeating work. Closing the control instance cancels active calls.

### Dispatch retained jobs

`worker-coordinator.mjs` provides `createWorkerCoordinator({ control, backend })`.
Call `tick()` to inspect native jobs and dispatch queued work. The default allows
one invocation at a time; an operator can select up to four. Each pass reads at
most 1,024 job metadata rows and retains a disposable cursor for the next pass.
Claiming a job retrieves its full pinned contract and authority context.

Before dispatching an unplanned task, the coordinator requests `change: "plan"`.
The native host queues read-only planning on its existing auxiliary worker
pool. Model calls run outside the company writer boundary. Inspection reports
`planning_required`, `planning_state`, and the selected planning job. Waiting
for planning does not consume an actor invocation.

The planner preserves the original request and obligations, records concrete
acceptance criteria, and selects the native task capability. Coding tasks gain
the host's `coding_validation` and `coding_summary` requirements. A committed
plan and its matching contract version survive interruption together. Recovery
finishes that retained plan without another planning call. The operator's next
`plan` request updates the worker's contract pin only after the host verifies
that planning receipt; arbitrary contract changes remain rejected.

A failed plan leaves actor work waiting for inspection and explicit `requeue`.
It cannot publish a task or establish coding validation. Tasks pinned to older
definitions retain their original contracts; migrate company transport
definitions before requesting the new planning operation.

The backend's `run(row, signal)` must resolve or reject only after stopping and
joining every actor process. The coordinator clips that invocation to the job's
runtime and execution lease. Further ticks cancel revoked, cancelled, or replaced
owners. `close()` cancels and joins active invocations. A lost claim acknowledgement
requires inspecting the original operation before dispatch; it never causes an
additional claim or actor retry.

A backend response cannot establish completion. The coordinator records a
submitted outcome only when native state retains a server review job, and records
completion only when canonical state includes accepted publication. Otherwise it
retains waiting or failed work. Waiting work requires explicit requeue and keeps
its invocation count. Restarting the coordinator does not replay an unexpired
running worker; expired work is retained for inspection and explicit resumption.

`worker-snapshot.mjs` reads a stopped worker's immutable revision through a
caller-supplied native read-only request transport. It inventories the five
managed content roots in pages of 32 and retrieves content in pages of at most
16 KiB. It verifies both the full SHA-256 and Fossil artifact identity before
returning a file. Default limits are 10,000 files, 32 MiB per file, and 256 MiB
of verified content per reader. These are collection bounds, not permission to
publish those files into the company. The host must still enforce the view's
scope and checkpoint changes through the signed company service.

Use the production image preparer and Linux backend below to connect this
coordinator to isolated execution and scoped proposal collection.

### Prepare a production image

`worker-image.py` is an operator-only image preparer. Run it with Python's
isolated mode and a root-owned `0600` configuration file. Its configuration
version is `omos.worker-images/v1` and requires these fields:

| Field | Purpose |
| --- | --- |
| `root` | Root-owned image pool, mode `0710`, with `service_gid` as its group. |
| `template` | Root-owned runtime tree. The preparer follows no symlinks. |
| `template_manifest` | Root-owned `0600` manifest of permitted runtime files. |
| `template_manifest_sha256` | SHA-256 of that exact manifest file. |
| `executable_sha256` | Verified SHA-256 of `runtime/bin/omos`. |
| `service_uid`, `service_gid` | Operator-selected broker account identities. |
| `max_images` | Pool bound, from 1 to 32, including interrupted preparations. |
| `context_window`, `max_output_tokens` | Verified limits for the selected provider model. |

Ancestor directories must be root-owned and reject group or other writes,
except for a root-owned sticky temporary directory. The pool path must leave
room for its 24-character image name and Unix socket within 100 bytes. A
private host directory must also protect the shared broker socket, as described
above. Image preparation does not establish this broker boundary by itself.

The template manifest has version `omos.worker-template/v1` and a `files`
array. Each entry declares `path`, `sha256`, `bytes`, and `executable`. Only
files beneath `runtime/`, `bin/`, `lib/`, `lib64/`, and `usr/` can be copied.
The template must include `runtime/bin/omos`, `runtime/bin/fossil`, `bin/sh`,
`bin/bash`, `usr/bin/env`, and every runtime dependency they require. Native
command execution selects Bash, and shell environment capture invokes `env`. The preparer verifies all copied
bytes and modes without executing template programs. Limits are 10,000 files,
512 MiB per file, and 2 GiB per image.

Send one JSON request on standard input:

```json
{
  "version": "omos.worker-image-request/v1",
  "action": "prepare",
  "id": "INVOCATION_SHA256",
  "workspace": "COMPANY_WORKSPACE_SHA256",
  "view": "COMPANY_VIEW_SHA256",
  "generation": 1,
  "max_runtime_ms": 240000,
  "model": "worker-model"
}
```

Replace the identity placeholders with full SHA-256 identities, and use the
claimed execution generation and a broker-approved model handle. Invoke the
installed root-owned preparer as the operator:

```sh
sudo /usr/bin/python3 -I deployment/company/worker-image.py /etc/omos/worker-images.json < request.json
```

The generated profile contains only fixed broker routes and model metadata.
It contains no issuer key, actor signing seed, provider credential, or owner
token. The launcher still requires private namespaces. Repeat the exact
preparation request to inspect its existing image; changed identity, model,
configuration, or template pins are rejected. `inspect` and `remove` use the
same request with a different action. Removal refuses an active worker UID.
The optional `source_revision` pins company input for native file tools. The
production backend supplies the claimed view revision and writes that identity
into the image's read-only runtime configuration. Omitting it creates an image
without the company filesystem projection.
Failed preparation removes its partial tree; an interrupted preparation
remains retained and consumes pool capacity for operator inspection.

### Use the private gateway transport

A coordinator on a separate operator account can use
`createWorkerHttpControl({ endpoint, workspaceId, token })` from
`worker-http-control.mjs`. The endpoint must be an explicit loopback IPv4
address and port. Keep the owner token in the operator's private configuration.
It is never a worker credential.

`POST /v1/company/workers` accepts
`{"version":"omos.company-worker-api/v1","workspace":"WORKSPACE_SHA256","request":{"change":"inspect"}}`.
The native gateway requires its owner bearer token, rejects browser origins,
and checks the workspace identity. A read-only gateway permits inspection and
rejects job changes. The supplied public Caddy route does not expose this owner
endpoint. Updates use the existing native job contracts and publication gates.

`head` is a read-only `omos.workspace-api/v1` action for discovering a current
immutable revision. Supply the current transport declaration hash and optional
`task`, omitting `revision`. Its data includes the selected task identity,
current full revision, and pinned definition hash. Subsequent inventory and
content requests use those immutable pins. Looking up a head never activates,
resumes, or publishes the task.

### Connect the Linux execution backend

When creating a company view, supply optional `scope` paths to narrow the
participant's grant for that task. Paths must be exact files or directory
prefixes already covered by the live grant. The native host commits an
immutable `omos_company_task_scope` record with the view. Status and worker
inspection expose the effective paths. Retrieval, discovery, record writes,
checkpoints, delegated file authority and publication enforce that boundary.
Starting another task is required to choose a wider scope. Definitions and
worker arguments cannot widen it. Older views without a task scope keep their
existing live-grant behavior.

Creation retries recover the existing view instead of recreating it. Later
input observations, private checkpoints, the original base and the task scope
remain retained when a creation acknowledgement is lost. New task branches
also check their requested base while holding the source writer boundary.

`worker-linux.mjs` provides `createLinuxWorkerBackend` for a separate privileged
operator process. It requires root-owned, hash-pinned launcher and image tools,
a private image configuration, a private company-client configuration and key
home, and an explicit broker model. The broker account in that image
configuration must be root. Its socket still needs a private root-owned host
directory boundary. The native gateway can remain on its separate service
account; the coordinator controls jobs through the private owner endpoint.

The backend probes the actual kernel before claiming work. It rejects hosts
without private namespaces. It prepares one root for the exact company view
and execution generation, then starts native `ask` inside that root. The prompt
travels through standard input. Provider credentials and signing keys remain in
host-side clients and the broker.

When an explicitly requeued job has a pending native operation, the coordinator
first claims a fresh execution fence. The backend reconciles that exact retained
operation through the signed service and the coordinator inspects native state
again before dispatch. A recovered submission goes straight to host review.
Unresolved outcomes remain fenced; recovery never replays actor tools or an
external effect. Backends without this recovery interface leave pending jobs
queued for operator inspection.

Ordinary file tools fetch selected company files into the private Fossil branch
before materialising them on disk. Skill discovery fetches skill entrypoints;
loading a skill fetches its package. A shell can open arbitrary files, so it
fetches the permitted managed roots before execution. The broker fixes the
workspace, view, revision and execution generation for these reads and the
native service checks current authority on every request. No source tree is
copied when the logical company view is created.

The private `omos_worker_projection` record commits each fetched file's hash,
size and executable flag together with its bytes. Interrupted fetches can
resume without restoring later local deletions. Bounds are 10,000 inventory
entries, 8 MiB per file and 64 MiB of materialised input. The broker allows at
most 20,000 projection requests within the invocation deadline, separately from
its actor request budget. This is an on-demand projection for native managed
roots; it is not a general network filesystem.

Company inventory pages contain at most 32 file rows. They also stop after
inspecting 4 MiB of content, allowing one bounded object to cross that boundary.
With the 8 MiB object limit, a page inspects less than 12 MiB. Follow
`next_offset` until it is null even when a page contains fewer than 32 rows.
Each body is released before the next object is inspected; the accumulated
inventory never has to fit in one response or request deadline.

After stopping and joining the actor, the backend verifies a quiescent worker
UID and reads its private Fossil snapshot through native read-only commands.
It proposes permitted managed files through signed company checkpoints, with
hash and executable-mode preconditions. Larger files use the existing durable
128 KiB upload protocol. Bounds are 8 MiB per file and 64 MiB of verified
content per invocation. The host verifies the projection ledger against the
original company revision before proposing deletions. Files that were never
fetched cannot be inferred deleted. Changed files use the original input hash
and mode as preconditions, so an intervening edit produces a retained conflict.
Unchanged projected files remain references to their company originals.

Company submission queues independent host assessment. Private worker reviews
and actor prose do not establish company acceptance. The adapter submits the
exact answer recorded in the stopped worker's task, including answers that
change no files. The read-only `candidate` workspace action requires that task's
current immutable revision and returns `authority: "actor_claim"`. Missing or
oversized answers retain the image for inspection instead of substituting a
generated summary. Failed or interrupted
collection retains the bounded image and its private Fossil checkpoint for
operator inspection. Unconfirmed process cleanup leaves the native job fenced
until recovery or expiry. A frozen company proposal with additional private
files also retains its image. The host removes an image only after accounting
for its proposed files. Native `hosted_execution` remains disabled pending
qualification and gateway integration of the complete backend.

### Review proposals from external runtimes

New company tasks pin `omos_company_completion_plan` in their declaration.
When an external runtime submits an unclassified task, the completion worker
runs the host's read-only planner before assessing the proposal. Hosted tasks
already planned before actor dispatch keep that plan. Historical declarations
without this operation retain their original contract adapter.

The host preserves the original request and obligations. Coding classification
adds the native validation and delivery obligations, so successful preparation
calls or an actor's answer cannot substitute for current check evidence. The
planner cannot replace the submitted answer: its exact bytes and hash travel
with the strengthened contract in the same atomic checkpoint as the review
fence. Recovery after that checkpoint reuses the retained plan and answer.

Planning shares the completion job's attempt, time, and token allowance. It
does not allocate another actor invocation or reset the review deadline. A
live submission grant authorizes this evaluation; actor dispatch still needs
its separate execution authority. Any required human approval must cover the
resulting contract and candidate. Planning itself neither accepts nor publishes
company state.

### Run isolated coding checks

Coding tasks require the operator's `backend.validationConfiguration` file and
the private evaluation transport supplied by `worker-server.mjs`. Without that
configuration, the job waits before starting an actor. The configuration is a
root-owned file, read and pinned by the supervisor. It selects commands from
the verified runtime template; task text cannot select a host executable.

For example, a company whose approved check script lives in
`documents/project/tests/check_behavior.py` can configure:

```json
{
  "version": "omos.worker-validation/v1",
  "handle": "company-default",
  "entry": {
    "path": "/bin/bash",
    "sha256": "VERIFIED_TEMPLATE_BASH_SHA256"
  },
  "checks": [{
    "id": "behavior",
    "arguments": ["/runtime/bin/python3", "-I", "-B", "tests/check_behavior.py"],
    "cwd": "documents/project",
    "timeout_ms": 60000
  }]
}
```

Include the interpreter, libraries, and approved check dependencies in the
runtime template. Set the Bash hash to that template's executable identity.
Allow at least two image slots per configured concurrent worker: the actor's
retained image and its separate checker image must coexist.
The handle must match the task's pinned `server.validation_handle` execution
setting; an omitted setting uses `company-default`. Changing a configured
handle requires an explicit policy decision. Handles confer no permissions.

After stopping the actor and collecting its proposals, the host obtains an
immutable scoped input manifest. It creates a separate image, verifies every
input's Fossil identity and content hash, and installs those files under the
root-owned, read-only `/runtime/validation-source/` tree. Checks use the declared
relative working directory there. Write caches and temporary outputs beneath
`/tmp`. The checker has no broker socket, provider credential, signing key, or
owner token. Coding actors cannot submit their proposal before this host step.

Checks share the invocation deadline and permit 1–16 commands, each limited to
two minutes. Input limits are 10,000 files, 8 MiB per file and 64 MiB overall.
The launcher stops descendants before the host rechecks source identities.
Output is bounded to 8 KiB per stream per check. Failed checks, changed inputs,
timeouts, and incomplete output cannot produce a passing receipt.

The host checkpoints the actor's exact candidate answer before starting checks.
That answer remains an unverified actor claim and travels with the task even
when validation stops before recording a result.

The owner-only `/v1/company/evaluation` endpoint provides `candidate`, `prepare`
and `record` operations. The same requests are available through `omos fossil company`
with action `evaluate`. Receipts bind the task, immutable source fingerprint,
configuration and environment hashes, execution generation, command arguments
and observed outcomes. They use the existing host-owned evidence records in
Fossil. A retained image result permits retrying its recording without running
the checks again. Actor requests and browser-origin requests cannot enter this
owner boundary.

Independent completion review must cite successful validation for the current
source fingerprint. Later source edits invalidate earlier checks. A receipt
does not accept or publish a task. Failed checks retain their evidence and the
actor's image for inspection; successful submission still passes the normal
contract, authority, integration and publication gates.

A validation outcome includes `record_id`, the immutable host evidence record
in that task's history. When bootstrap advertises `validation_feedback`, the
owning actor can retrieve it with signed `status`, supplying `view`, `revision`,
`record_id`, `offset`, and a `limit` of at most 16 KiB. Each page identifies the
full receipt's SHA-256 and byte count. The service checks task ownership and
revision ancestry before reading it. Another task's record ID grants no access.
The next hosted invocation receives the previous failed-check note and this
reference; requeueing preserves the note and its remaining invocation budget.

### Supervise the coordinator

`worker-server.mjs` runs the optional Linux coordinator with Node.js 22 or newer.
Its root-owned `0600` configuration has version `omos.company-workers/v1`,
`concurrency` from 1 to 4, `poll_ms` from 250 to 5,000, and these two objects:

- `control`: `endpoint`, `workspaceId`, and the private owner `token` for
  `createWorkerHttpControl`.
- `backend`: `imageTool`, `imageToolSha256`, `launcher`, `launcherSha256`,
  `imageConfiguration`, `companyConfiguration`, `companyHome`, and `model` for
  `createLinuxWorkerBackend`. The model declares its exact completion endpoint,
  worker handle, provider model, and optional credential. Add
  `validationConfiguration` to select the isolated coding checks described above.

Install the reviewed companion tree and its pinned operation schema beneath a
root-owned version directory. Preserve their repository-relative locations:
`deployment/company/` and `src/core/workspace/standard/omos.json`. The image and
launcher paths in the configuration must name their real, hash-pinned paths;
a mutable `current` symlink is insufficient for those pins. Keep image pools,
operator key homes, and broker directories under private persistent storage.

The supplied `omos-company-workers.service` is a separate system service. It
keeps the gateway on its original service account and grants the privileged
coordinator only the host capabilities its launcher and image preparer require.
Its default writable locations are `/var/lib/omos-workers` and
`/run/omos-worker-leases`. Install Node.js and the reviewed companion tree at
the unit's explicit paths, then install private operator configuration and the
runtime template before starting it. Configure an independent actor grant and
signing key for its company client. Queue a test view and inspect the resulting
job, independent assessment, and verified publication before onboarding users.

The supervisor logs sanitized lifecycle and inspection events. Task intent,
provider credentials, signing keys, and owner tokens are omitted. Job state,
invocation budgets, proposals, and publication remain in native Fossil records.
Stopping the supervisor cancels and joins its current workers. Restarting reads
those records and does not replay unexpired or paused actor work. The dedicated
Linux CI job requires private namespaces and exercises the actual production
adapter; tests on a restricted host verify refusal before claiming a job.

### Discover and request hosted execution

The supervisor registers its verified environment fingerprint, model handle,
actor/grant bindings, and validation handles through the local owner endpoint
`/v1/company/runtimes`. These implementation descriptions are versioned in
Fossil. An authenticated heartbeat renews a 60-second process lease in the
gateway's memory; it creates no Fossil commit. Another live process cannot take
that registration's lease. Restarting the gateway clears liveness while
preserving registrations, task checkpoints, and invocation budgets. The
supervisor renews its lease every 10 seconds and stops its workers if renewal
fails.

The public bootstrap advertises `hosted_execution` only while a registered
implementation is live. This reports service availability, not permission.
Enroll `execute_task` explicitly in an actor's grant and client configuration
to permit hosted compute. A signed request uses the same `company_workspace`
operation as other scoped actions:

```json
{
  "version": "omos.company/v1",
  "action": "execute_task",
  "operation": "unique-operation-id",
  "expires_ms": 1900000000000,
  "view": "OWNED_VIEW_ID",
  "revision": "CURRENT_VIEW_REVISION"
}
```

Set the expiry within five minutes of the current time. The native service
checks live authority, view ownership, the exact revision, and a live
implementation for that actor and grant. Coding tasks also require the pinned
validation handle. A new job allows three invocations of at most four minutes
each. Repeated requests reuse the job. An explicit request can resume waiting
or failed work within its remaining budget; it cannot reset that budget or
restart cancelled work. Queueing runs no actor or model in the request thread.

Signed `status` for the view includes `hosted_execution.available` and a bounded
job summary with state, invocation count, limits, and the retained note. The
coordinator checks its configured actor and grant before planning or claiming a
job. Actor processes receive neither `execute_task` nor operator controls.
Publication still requires independent review and a verified company receipt.
