# Public worker activity

The company coordinator runs the existing native `ui-host` protocol inside the
isolated worker image. It keeps stdin open until the native turn ends and sends
public text, tool updates, command output, and input requests to the native
company service. Provider replay, reasoning, session metadata, and credentials
stay inside the worker or its owner service.

## Persistence and authority

`POST /v1/company/activity` accepts the owner bearer token on loopback. Each
request also identifies the view, runtime, and execution generation. The native
service checks the live grant, task scope, desired-state binding, and execution
fence before accepting a batch. A revoked or replaced worker cannot append.

The protected `omos_company_activity` entity stores ordered events and a head
record on the control branch. These records do not advance the task source
revision. Each event is at most 16 KiB; a request contains at most eight events.
An exact repeated offset and payload acknowledges the original write. A changed
payload at the same offset fails. No events can follow a recorded `turn_end`.

Activity carries `actor_public_activity_only` authority. Displayed text, tool
success, and a native turn ending cannot establish completion. Independent
assessment and a verified publication receipt still determine the company
outcome. Complete public worker archives retain the underlying task history.

## Browser delivery

Signed `status` requests with entity `omos_company_activity` retrieve the
actor's own view. Pages contain at most two events and pin the control revision.
The reader finishes that revision before moving to a replacement generation.
Every page checks current retrieval authority.

The browser bridge reuses the personal UI's event reducer and Markdown/tool
components. Its in-memory cursor is delivery state. Fossil owns the journal.
Initial display loads at most the latest 512 events per generation; older
activity remains available through the paged service. A paused snapshot retains
the visible text and tool cards. Only company publication emits completion.

The bridge displays pending native input through the trusted host controls.
[Company task input and cancellation](INPUT.md) describes the separately signed
decisions, delivery acknowledgements, and cancellation fences. Activity records
cannot authorize these actions or change a task's acceptance obligations.
