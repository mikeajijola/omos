# Run the company service on one host

These files deploy the signed company gateway and independent review workers.
An optional privileged Linux coordinator dispatches retained jobs through the
private owner API and an isolated native runtime. The gateway advertises
`hosted_execution` only while a registered, matching runtime has a live
heartbeat. Each dispatch requires an explicit `execute_task` grant.
See the supported operations and limits in
[the workspace contracts](../../src/core/workspace/CONTRACTS.md#scoped-company-service).

The [isolated worker runtime components](WORKERS.md) describe the operator
configuration, verified image template, process boundary, result collection,
and separate system service. Their presence does not enable native hosted
execution or enroll an actor automatically.

Use a dedicated service account with persistent home storage. Install the built
`omos` and `omo` aliases and verified Fossil helper for that account using
`scripts/install-omos.sh`. Keep this profile separate from a person's installation.
The service account's configuration selects the review provider and credentials.

## Initialize the empty instance

Run these commands as the service account, after installing its binaries:

```sh
umask 077
mkdir -p "$HOME/.local/share/omos/company" "$HOME/.config/omos"
cd "$HOME/.local/share/omos/company"
"$HOME/.local/bin/omos" fossil ensure --json
printf '%s\n' '{"version":"omos.company-admin/v1","action":"initialize"}' > initialize.json
"$HOME/.local/bin/omos" fossil company initialize.json --json
rm initialize.json
```

`ensure` creates an empty format 2 instance when no binding exists. It preserves
an existing binding and does not import historical sessions. Check its returned
repository path and workspace identity before initialization. Authority is
stored in that repository; issuer secrets remain in the account's protected
profile. Enroll actors with local operator `grant` requests that specify exact
actions, path scopes, public keys, and expiry. Enrollment does not follow from
editing the OmniForm definition.

Capability definitions require a separate metadata assignment. After enrolling
a grant, inspect company control with a local `inspect_capabilities` request,
then submit `grant_capabilities` with that grant ID, the returned
`expected_revision`, and the permitted capability IDs in `capabilities`.
Assign every dependency needed for the chosen realisation. Use an empty list to
remove this access. File paths and executable authority remain separate.

Scoped clients discover their catalogue with `discover` and `capability: "*"`.
Selecting an ID returns bounded, hash-verifiable package metadata. This metadata
identifies declared dependencies; clients must still verify files and runtime
requirements before treating the capability as available. Delegation may carry
`delegated_capabilities`, bounded by the parent's current metadata scope.

Selected capability exports preserve the signed graph, required files, and
source revision. On a personal destination, import retains an isolated task;
the owner supplies private runtime bindings with `omos fossil package verify
TASK --bindings BINDINGS.json --json`. Resume that task through independent
review to publish its additive declaration and files together. Runtime checks
establish declared inputs and version constraints; functional checks still
belong in the task contract. A copied workspace requires destination host
verification before discovery reports its imported implementation available.
See [selected capability packages](../../src/core/workspace/CONTRACTS.md#selected-capability-packages)
for binding formats, deadlines, and recovery behavior.

Create a private environment file for the local owner endpoint:

```sh
printf 'OMOS_WORKSPACE_TOKEN=%s\n' "$(openssl rand -hex 32)" > "$HOME/.config/omos/company.env"
chmod 600 "$HOME/.config/omos/company.env"
```

The bearer token belongs to local administration or a trusted server bridge.
External company actors use their signed, scoped requests instead.

## Hand a view between runtimes

Add `execution` to the actor's enrolled actions and optional MCP configuration
when clients need durable execution ownership. Discover support through
`features.execution_ownership`. Claim the view with action `execution`, change
`claim`, its current revision, and fence
`{"runtime":"worker-instance","generation":0}`. Specify a lease duration in
`execution_lease_ms`, up to five minutes. The signed response returns the new
generation and expiry.

Carry that runtime and generation in `execution` on subsequent mutations and
active input reads. Renew before expiry or release ownership explicitly. A
replacement runtime reads `status` for the contract, model basis, checkpoint,
and previous generation, then claims a new generation after release or expiry.
Once claimed, the view continues to require ownership after either event;
old runtimes and unfenced mutations are rejected. Lost acknowledgements retain
their original outcome and cannot restore an older owner. See
[scoped company execution ownership](../../src/core/workspace/CONTRACTS.md#scoped-company-execution-ownership)
for request fields and recovery rules.

## Start and expose the service

Copy `omos-company.service` into `~/.config/systemd/user/`, then run:

```sh
systemctl --user daemon-reload
systemctl --user enable --now omos-company.service
systemctl --user status omos-company.service
journalctl --user -u omos-company.service
```

Configure account lingering through the host's administrator if this user
service must continue after logout. The gateway listens on loopback port 8765.
`GET http://127.0.0.1:8765/v1/company` must return the initialized workspace,
issuer, epoch, and accepted revision. A running process alone does not prove
authority is active. Test a signed scoped read and proposal before onboarding
users; inspect its durable job outcome and publication receipt.

Use the supplied `Caddyfile` with Caddy on the same host and set
`OMOS_COMPANY_DOMAIN` to the company's configured domain. Caddy manages the TLS
endpoint. Its route exposes only `/v1/company`; the owner bearer interface,
definition endpoint, and repository file remain private. Browser clients need
a server bridge that signs or forwards each authenticated user's scoped
requests. The gateway rejects browser-origin requests directly. Keep the service
on loopback; this configuration does not authorize exposing its other routes.

## Connect an external MCP client

The optional company MCP companion exposes the same signed operations over
MCP stdio. The installer retains the companion and its pinned operation
declaration; keeping the source checkout or unpacked download is unnecessary.
The transport requires Node.js 22 or newer. The native installation and
company server do not require Node.js. The companion negotiates
MCP `2025-11-25` or `2025-06-18`; newer clients receive an explicit supported-version
response and must negotiate a supported version.

Run `omos fossil company-key HANDLE --json` in the client account. Enroll its
returned public key through the server's local operator with the required paths,
actions, and expiry. The client keeps the private key in its own profile; do not
copy the server issuer key or local owner token to it.

Create a mode `0600` configuration file outside the agent's mutable workspace:

```json
{
  "version": "omos.company-mcp/v1",
  "endpoint": "https://company.example",
  "workspace": "COMPLETE_WORKSPACE_ID",
  "issuer": "COMPLETE_ISSUER_PUBLIC_KEY",
  "epoch": 1,
  "actor": "external-worker",
  "grant": "team-editor",
  "key_handle": "company-worker",
  "actions": ["discover", "read", "create_view", "checkpoint", "query", "record", "submit", "status", "reconcile"]
}
```

Replace the workspace and issuer with complete lowercase hexadecimal identities
verified through your operator. Pin the current issuer epoch explicitly. Match
`key_handle` to the locally created handle. The configured action list narrows
the advertised interface; the native service checks the live grant on every
operation. After issuer recovery, update these pins only after verifying the new
identity and enrolling the client again.

Read the installed entry path and register it with an omos MCP client:

```sh
company_mcp_entry=$(node -p 'require(process.env.HOME+"/.fx/libexec/company-mcp.json").file')
omos mcp add company -- node "$HOME/.fx/$company_mcp_entry" "$HOME/.config/omos/company-mcp.json"
```

Other MCP clients use the same Node command, installed script, and absolute
configuration path. `omos mcp show company --json` verifies connection and lists
the tools. Development checkouts can still run `node
deployment/company/mcp.mjs CONFIG`, with an absolute private configuration path.

`company_context` returns the public instance discovery, configured actor and
grant, current time, and configured actions. It does not certify live access.
`company_workspace` accepts the native operation fields, with workspace, actor,
and grant supplied by the fixed configuration. Supply an operation ID and an
`expires_ms` within five minutes. Use the returned pinned revision for edits and
retain the operation ID when an outcome is uncertain. Successful calls return
the original signed receipt in `structuredContent.receipt` for later inspection.
Submission queues native independent review; it is not an acceptance receipt.

When `company_context` reports `schema_discovery: true`, use `company_workspace`
with `action: "discover", entity: "*"` to list authorised custom record types.
Then set `entity` to a listed name to retrieve its OmniForm contract. Catalogue
pages contain at most 32 names. Schema bodies use base64 byte ranges of at most
16 KiB under `schema`; follow `schema.next_offset`, retain the returned
`revision`, and verify the complete `schema.sha256`. A selected view uses its
task's pinned model. Discovery requires the `discover` action and a record path
in scope, works on read-only hosts, and rechecks live grants on every request.
These schemas describe expected data and grant no additional permissions.

Plain view `status` requests read immutable company and task revisions without
waiting for the company writer. The contract, review job, and publication summary
come from one pinned task revision. Before signing the response, the service
rechecks the caller's current grant, expiry, and issuer authority. A revoked or
changed grant cannot receive a response authorised by the older snapshot.
Mutations and read-dependency recording still use the controlled writer boundary.

For resumable view updates, call `status` with the view identity and
`progress_cursor: ""`. Consume `progress.next_cursor` pages, then retain
`progress.resume_cursor` for the next poll. Each signed request rechecks the
grant. The feed remains pinned while paging and recovers its position after a
service restart. It reports revision notifications; inspect the status snapshot
and publication receipt to determine verification and acceptance.

HTTP clients can POST that signed status request with
`Accept: text/event-stream` when discovery advertises `progress_stream`.
Each `workspace` event carries the normal signed receipt, bound to the opening
request hash. Verify it before saving the event ID as your next cursor. A new
connection signs a new status request with that saved `progress_cursor`.
The service rechecks the live grant and request expiry before every page.
There are at most four streams per process, each bounded to 30 seconds,
32 workspace events, and 1 MiB of SSE data. A client reconnects after the bound;
an end event or closed connection does not establish task completion.
Keep the request side open while waiting for updates. Request-side EOF,
including a write half-close after sending the POST body, cancels a subscription
even while it is waiting for admission. Resume using the last verified cursor.
The MCP companion keeps using JSON polling. Browser interfaces still need
their trusted bridge; raw browser-origin requests are rejected.

The companion verifies response signatures, request hashes, issuer epoch, and
identity fields. It forwards no owner bearer token or cookies and follows no
redirects. It never automatically retries mutations. Cancellation or a missing
response after sending a mutation leaves its outcome uncertain; inspect `status`
or reconcile the original operation. Inputs and HTTP responses are bounded to
1 MiB, with 16 active requests and a 30-second deadline shared by discovery and
the operation. The companion stores no task, grant, or operation database.

## Backup and restore

Create a verified portable export with `omos fossil export PATH`. Preserve all
company branches, including authority, views, proposals, and operation outcomes.
Back up issuer material under `~/.fx/authority/`, review provider credentials,
and the private environment file separately using the operator's protected
backup procedure. Plain company exports do not contain those secrets. Fossil
repositories and scoped packages currently contain plaintext content. Use the
host's encrypted storage and protected backup transport where your deployment
requires encryption; object-level encryption and portable key-domain recovery
are not implemented by this service. Current scoped exports can be downloaded as signed, content-addressed file packages with
`omos fossil export-scope`, then verified offline with `omos fossil verify-scope`.
Version 1 configurations export file snapshots without inferred capability
closure. Version 2 configurations explicitly select capabilities and their
realisations, require authority over the complete declared input paths, and
retain signed dependency metadata. See [selected capability packages](../../src/core/workspace/CONTRACTS.md#selected-capability-packages).

Before activating a restored instance on another host, stop and fence the old
host. Bind the verified repository, inspect authority with `company` action
`status`, and explicitly rotate the issuer using that control revision. Rotation
advances the epoch and revokes old grants. Re-enroll actors deliberately. On the
same host, recovery refuses a stale copy and fences the previous repository after
successful activation. These local locks do not provide cross-host consensus.

Personal and company tasks reuse host mutation and integration checkouts while
retaining separate canonical branches and actor filesystem views. Protected
company-control writes materialize only the named records being committed.
Measure repository size, host checkout size, active view count, review duration,
and storage growth when setting capacity expectations. Scoped export clients
reuse verified objects through a private 256 MiB cache, bounded to 4,096 objects,
while checking current grant authority. Their JSON summaries report cache
activity. Personal task projections retrieve files on demand and retain live resources
during clean-view collection and reuse verified immutable content through the
bounded profile cache. Enable separately delegated desired-state policies to
reconcile capability outcomes continuously. See [desired-state reconciliation](DESIRED.md) for
record contracts, scope, budgets, and recovery.

## Review capacity

New instances store `server.review_workers: 2` in `execution/omos.json`. The
accepted execution policy permits 1–4 workers. Restart the service after an
explicit policy change; existing policies without this field use one worker.
Each task retains its own review allowance and execution lease. Compatible
changes to accepted state trigger reconciliation and fresh assessment within
that allowance, while publication stays behind the coordinated writer boundary.
Conflicts, stale approvals, and exhausted allowances remain recorded outcomes.

Interrupted worker retention reports its archive or activity position and a
sanitised transport code when available. A deadline, cancelled request, or
closed socket leaves a mutation's outcome uncertain. These diagnostics do not
retry the mutation or spend another actor invocation.
