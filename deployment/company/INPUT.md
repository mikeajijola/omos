# Company task input, updates, and cancellation

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
An unanswered question has an empty decision queue. The worker keeps waiting
until an authenticated answer arrives, its authority changes, or its deadline
expires.

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
company history. Where `retired_archives` is declared, the host permanently
retires the cancelled execution and archives its public history before removing
its image. Failed archival remains pending and preserves the image. Further work
after retirement requires a new task.

## Update a task from chat

When `task_amendments` is advertised, follow-up messages and steering submit a
signed `execute_task` request with the current task revision and, for running
work, its current execution fence. Its content contains
`{"version":"omos.company-task-amend/v1","text":"Use blue instead of red."}`.
Updates are limited to 16 KiB and require explicit compute and submission
authority. Hosted actor clients cannot submit these controls. Desired-state tasks
retain their operator policy: change the accepted desired-capability record
through a proposal so reconciliation can create the replacement task.

The host first retains an immutable `omos_company_task_amendment` intent. It
retains the original worker precondition, releases the old execution fence,
and queues the same company task without
resetting its invocation allowance. The independent planner revises only
requirements affected by the authenticated update and retains every unaffected
obligation. Publication still requires independent assessment of the resulting
candidate. Completed or permanently retired tasks require new work; an exhausted
invocation allowance cannot be enlarged through a chat update.

Interruption preserves the intent and any applied amendment. A signed
reconciliation can finish this internal transition after the old execution
fence has been released. It verifies the original admitted operation and never
replays actor tools. The private worker checkpoint pins the company contract
delivered to its invocation. A stale private answer cannot skip execution of an
updated contract. Before replacing a private image whose task has already
become read-only, the host acknowledges its public history and collects its
files into the company proposal. The replacement image projects that revision,
so an amendment preserves unaffected work. The old answer is not submitted.

Owner configuration and browser delegation retain their separate authority
requirements. Input decisions and task updates cannot grant permissions.

## Continue independent verification

When `verification_resume` is advertised, a plain `execute_task` request can
resume the retained completion review. It requires compute and submission
authority, but no live hosted actor implementation. The host pins the retained
candidate, contract, review generation, and review budget before allocating a
new bounded review attempt. It preserves the worker invocation count.

A review that is already queued or running returns its recorded progress.
An interrupted admission exposes `pending_verification`; signed reconciliation
can finish that exact internal operation after execution ownership has ended.
Retrying its operation ID cannot allocate another review allowance. A verdict
requiring changes or human approval retains its existing resolution path.

Existing company workspaces adopt this additive operation with
`omos fossil migrate --contracts`. Active tasks keep their pinned definitions
and execution policies.
