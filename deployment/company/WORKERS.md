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

This connection does not yet provide a durable hosted job coordinator or image
preparation service. The gateway continues to report `hosted_execution: false`.

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
