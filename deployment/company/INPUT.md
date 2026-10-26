# Company task input and cancellation

Authenticated users can answer a hosted worker's questions or cancel their own
queued or running task. The service advertises `task_input` only when its signed
control, owner delivery, and scoped outcome operations are all declared.

The UI uses the same native question and approval presentation as personal
sessions. The trusted browser shell displays requests outside the editable
workspace interface. Partial answers to a batch remain unsent form state. Once
all questions have answers, the bridge sends one signed decision to Fossil.

## Signed decisions

The owning signed client uses `execute_task` with its expected task revision,
current execution fence, and a `content` string containing
`omos.company-task-control/v1`. An input command identifies the immutable public
activity event offset and native request ID. It supplies either an approval
boolean or one answer per native question. It cannot identify an invented
request, target a replacement generation, or overwrite an existing decision.
Credential literals are rejected; configure secrets through private handles.

These requests require explicit compute authority. Hosted actor clients omit
compute controls from both their advertised actions and their execution scope.
They cannot answer their own questions through the company service.

## Delivery and interruption

`omos_company_task_input` records the user decision, contract hash, source
identity, execution generation, expiry, and request hash. The owner-only
`POST /v1/company/controls` endpoint inspects at most eight pending decisions,
claims a decision with a unique delivery ID, and acknowledges its outcome.
The worker sends the answer through the existing native `ui-host` input method.

Exact claim and acknowledgement retries preserve that delivery ID. A replacement
process cannot replay a command already marked `dispatching`. A missing native
acknowledgement remains uncertain. Only a known rejection before input effects
can be recorded as failed. Neither an applied answer nor a public activity event
establishes task completion.

Signed status requests for `omos_company_task_input` identify the owned view,
generation in `record_id`, and event offset. They expose delivery state under
current retrieval authority. The UI hides actionable choices after a decision
has been recorded and retains the visible work while delivery or review waits.

## Cancellation

A cancel command contains only its version and mode. Queued tasks need no
execution fence; running tasks require the current fence. Cancellation records
the host worker's cancelled state and releases its matching execution ownership.
The coordinator stops its runtime and joins descendants. A stale actor cannot
checkpoint or publish. Completed publications and active independent reviews
cannot be cancelled through this interface.

Interrupted images remain retained when their history has not been acknowledged.
Cancellation does not erase recorded activity, contracts, prior checkpoints, or
company history. Retained images require recovery before removal.

Task amendments, steering, owner configuration, and browser delegation have
separate authority and contract requirements. Input decisions cannot change
acceptance obligations or grant additional permissions.
