# Reconcile desired company capabilities

Desired outcomes are versioned records under the accepted OmniForm declaration.
An operator policy separately assigns an actor, grant, paths, and execution
budget. Editing a desired record cannot enroll an actor or enlarge its rights.
An empty installation contains the record contract and no desired records or
reconciliation policies.

## Record the desired outcome

Create a `company_desired_capability` record through the scoped `record`
operation on a task, then submit that task for independent review. Its accepted
path is `records/company_desired_capability/weekly-calculator.json`. Use the
following JSON as its record data:

```json
{
  "version": "omos.company-desired-capability/v1",
  "capability": "coding_task",
  "objective": "Maintain documents/team/calculator.py with add(a, b).",
  "criteria": [
    "Calling add(2, 3) returns 5.",
    "The operator-configured addition behavior check passes."
  ],
  "paths": ["documents/team/"],
  "observations": [],
  "enabled": true
}
```

The capability and the policy's execution capability must exist in the accepted
OmniForm declaration. `paths` selects the task's writable scope. `observations`
adds company paths whose changes should trigger another reconciliation; these
paths must also fit the operator policy and live grant. Observation selectors
are server watch inputs, not additional actor access. Include any input the
actor must read within its task paths and enrolled authority. Criteria are
retained in the task's original request. The host pins the target record's SHA-256 and
policy revision before creating the task.

A target allows at most 32 paths, 32 observation selectors, and 16 criteria.
Its objective and criteria together allow at most 12 KiB. These bound each
intent; they do not limit accumulated evidence or history.

## Assign authority separately

Enroll the worker's signing key through the company operator. Its grant needs
`create_view`, `read`, `status`, `checkpoint`, `submit`, and either `execution`
or `execute_task`, with paths covering the proposed policy. Configure the
isolated worker and the coding validation handle as described in
[WORKERS.md](WORKERS.md).

Register this request through `omos fossil company REQUEST.json --json`, or the
private owner endpoint `POST /v1/company/desired` with its transport envelope:

```json
{
  "version": "omos.company-admin/v1",
  "action": "desired",
  "desired": {
    "version": "omos.company-desired/v1",
    "change": "register",
    "policy": {
      "version": "omos.company-reconciliation-policy/v1",
      "workspace": "COMPLETE_WORKSPACE_ID",
      "id": "weekly-calculator",
      "target_path": "records/company_desired_capability/weekly-calculator.json",
      "actor": "company-maintainer",
      "grant": "team-maintenance",
      "allowed_paths": ["documents/team/"],
      "execution_capability": "coding_task",
      "enabled": true,
      "auto_retry": false,
      "max_invocations": 3,
      "max_runtime_ms": 240000
    }
  }
}
```

Replace the workspace and enrolled identities with the operator's values.
Updating an existing policy requires its current `expected_sha256` from
`change: "inspect"`. Disabling it prevents further work under that policy.
The policy is protected company state; scoped actors cannot overwrite it.

Add `"reconciliation": true` to the private worker supervisor configuration.
The supervisor checks one policy assigned to its actor and grant every five
seconds, retaining a cursor for the next policy. Other workers can process
other assigned policies. Native code owns comparison, task creation, budgets,
and publication decisions. The Node supervisor supplies the timer and transport.

## Observe, retry, and recover

An unchanged accepted outcome does not create another task or call an actor.
The host compares selected file identities with the verified publication's
snapshot. Unrelated company changes leave that outcome satisfied. Changed
selected state or a changed desired record creates another governed task.
If selected accepted inputs change during execution, the pending episode loses
execution and publication authority before the next reconciliation tick. The
host creates a replacement task against the new accepted inputs.

A durable intent precedes task creation. Repeated ticks reuse its task and view.
A task also pins its reconciliation episode. Superseded work cannot publish,
and restoring an older target document does not reactivate an obsolete task.
A task cannot publish a change to the target record it is meant to satisfy.

Without a suitable live runtime, the task remains retained as `unavailable`.
`auto_retry` defaults to false. Enabling it permits requeueing waiting, failed,
or rejected work within the existing invocation allowance. It cannot reset an
exhausted budget or restart cancelled work. Failed checks and partial answers
remain available for inspection. Unknown external effects still require
reconciliation before retrying them.

The local operator uses `inspect` and `tick` requests through the same desired
API. Signed clients use `company_workspace` with `action: "status"` and
`entity: "omos_company_reconciliation"`. They see only policies assigned to
their current actor and grant. Membership pages pin `index_revision`; pass that
value as `revision` for later pages. Pages contain at most four outcomes and
return `next_offset`. A worker bound to a view can inspect only that view's
current policy episode. Every request rechecks live permissions.

A `met` outcome cites an independently verified company publication. A stored
phase, actor answer, or successful tool call alone does not establish completion.
