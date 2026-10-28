# Recurring scheduling specification

Status: proposed. This document replaces the ambiguous recurrence design in
the scheduling conversation. Recurring scheduling is not implemented by the
current CLI, native host, HTTP service, or calendar.

Recurring work uses a series that materializes separate occurrences. Every
occurrence owns a fresh root contract and saved native session. Accepted
contracts, published evidence, and publication receipts remain immutable.
Resuming an interrupted occurrence uses its retained session and evidence;
it never creates a replacement run merely because a lease expired.

1. **Persistent identities and compatibility.** Store series and occurrences
   in `schedules/series-v1.json` on `omos-schedules`, with version
   `omos.schedule-series/v1`. Preserve the existing `schedules/state.json` and
   `omos.schedule/v1` format for one-time execution records. Older hosts can
   execute materialized one-time starts but cannot generate or edit a series.
   Native initialization advertises `schedule_series_v1`; clients must check it
   before offering recurrence editing. Unsupported series API versions fail
   explicitly. No migration changes an existing one-time schedule into a series.

   A series records its ID, rule version, pinned template identity, recurrence
   anchor, next nominal slot, policies, end conditions, materialized count, and
   state. Series states are active, paused, cancelled, and completed. An
   occurrence records its series, rule version, nominal slot, optional moved
   start, task ID, session binding, one-time schedule ID, preparation state,
   execution outcome, and transition history. Keep these identities separate;
   the template ID never becomes the active task ID.

2. **Template and authority.** Pin the source contract revision, original
   request, amendments, referenced specification, obligations, model basis, and
   project root when creating a series. A source task may be finished, but a
   template never imports its completion state, assessments, effects, command
   receipts, conversation replay, credentials, or saved permissions. Creation
   requires an explicit authenticated request to repeat the work. Each run
   receives fresh evidence and the normal current permission checks. Missing
   project access, local authority, model bindings, or native-session storage
   pauses preparation with a retained reason.

3. **Crash-safe materialization.** Derive an occurrence key from the series ID,
   rule version, and nominal UTC slot. Under the workspace writer lock, reserve
   that key before creating a session or task. Persist the reservation and its
   deterministic session, task, and schedule identities. Session and task
   creation must support idempotent lookup by that reservation, verify existing
   bindings, and reject mismatched identities. Mark an occurrence prepared only
   after all bindings are durable. Publish its one-time schedule exactly once,
   then advance the series cursor in a recoverable commit.

   Recovery reconciles reservations, task branches, session bindings, and
   one-time schedules before generating another occurrence. A crash at any step
   must converge on the same occurrence and task, without orphaning a second
   executable schedule. No actor or external effect runs during materialization.
   Existing generation-fenced leases and the workspace actor lock still govern
   execution. A lost execution lease retains the occurrence for inspection;
   it does not establish that an external effect can safely be retried.

4. **Recurrence arithmetic.** Support fixed-duration intervals of at least
   60 seconds and calendar daily, weekly, or monthly rules. Duration suffixes
   `m`, `h`, `d`, and `w` mean fixed UTC durations; calendar rules use explicit
   cadence names. Reject incompatible fields rather than ignoring them.

   The initial version supports UTC and explicit fixed offsets only. Store the
   offset independently of the UTC instant and display it in the editor. A
   fixed offset does not follow daylight-saving changes. Reject IANA timezone
   identifiers until a versioned timezone implementation exists; do not silently
   interpret them as fixed offsets. Browser-local rendering may change offsets
   across daylight changes while the series execution rule remains fixed.

   Calendar rules retain the original local clock and anchor. Weekday tokens
   use Monday through Sunday; weekly multiples are measured from the anchor's
   Monday. Monthly day 31 clamps to the last day when needed, but a February
   clamp does not change the March anchor to day 28. Use checked arithmetic and
   the existing supported UTC instant range. Compute future slots from the
   anchor and ordinal, never from completion time.

5. **Overlap, missed slots, and blockers.** These are separate policies. The
   first version supports `overlap=block` and `overlap=skip`, with
   `missed=coalesce_latest` only. Default to block. There is no concurrent
   occurrence execution for the same series.

   With block, a running, waiting, or failed occurrence prevents the next
   materialization. With skip, due slots while an occurrence remains unresolved
   are recorded as skipped; they do not cancel or replace that occurrence.
   Failed or waiting work is never automatically replayed under either policy.
   Users may resolve and resume the retained occurrence or explicitly skip it.

   On recovery after downtime, coalesce all unmaterialized due slots to the
   latest due nominal slot, recording the omitted range and count. Materialize
   at most one such slot per series before calculating the next future slot.
   Do not accumulate a backlog of catch-up executions. A blocked occurrence
   retains its original nominal slot even when later slots are coalesced.

6. **Counts and endings.** `max_occurrences` limits materialized occurrences,
   with valid values 1 through 10,000. It is not a count of successes or retry
   attempts. Reservation consumes one count exactly once; recovery reuses that
   reservation. Resuming or retrying a retained occurrence consumes no extra
   count. Skipping an already materialized occurrence leaves its consumed count
   intact. Missed or overlapping slots that never materialize consume no count.

   `until` is an inclusive bound on the nominal start instant, strictly after
   the initial anchor. When both count and until are present, stop at whichever
   prevents another materialization first. A moved start cannot exceed until.
   The series becomes completed after generation ends and every materialized
   occurrence is terminal. A failed or waiting last occurrence therefore keeps
   the series unresolved until resumed, skipped, or cancelled explicitly.

7. **Edits, pause, and cancellation.** Every mutation requires the revision
   returned by a read. Moving one unclaimed occurrence changes only its actual
   start, preserving its identity and the recurrence anchor. Editing a series
   changes its rule version. It may replace unclaimed future reservations in
   one revision-fenced transition; it cannot create a second occurrence for an
   already materialized slot. Reject moves of running or final occurrences.
   Rule changes during a running occurrence apply after that occurrence ends.

   Pausing prevents generation and dispatch of unclaimed starts, while allowing
   an already-running occurrence to finish. Resume uses the same coalescing
   policy. Skipping a blocked occurrence makes it terminal without accepting or
   publishing its task. Cancellation ends generation and cancels unclaimed
   starts, preserving history and task evidence. A running occurrence continues
   unless the user also explicitly cancels its normal task execution.

8. **Interfaces and calendar.** Add typed series create, inspect, list, update,
   pause, resume, skip, and cancel operations, separate from existing one-time
   schedule requests. The CLI and slash command use `schedule series` with the
   same operations and revision requirements. The HTTP series endpoint uses
   the existing bearer authentication and writable-host requirement. The UI
   bridge allowlists every recurrence field and operation.

   Distinguish committed occurrences, derived future slots, and past runs.
   Projection requests use a half-open range no longer than 366 days and return
   at most 2,000 slots with an explicit truncation marker. Derived slots cannot
   execute until materialized by the host. History is pageable against a pinned
   revision; a bounded inline preview must not discard authoritative history.
   The editor distinguishes moving one occurrence from editing the series,
   states the fixed-offset behavior, and shows blockers and end conditions.

9. **Acceptance and execution bounds.** Limit the store to 256 series and
   materialize at most one occurrence per series per worker tick. Retain the
   existing workspace execution exclusion, independent assessment, and verified
   publication requirements. Tests must cover count one, count two with distinct
   tasks and sessions, failed and skipped runs, offline coalescing, overlap,
   inclusive until, leap years, monthly anchoring, fixed-offset behavior,
   overflow, revision conflicts, unsupported versions, and calendar bounds.
   Inject failures between each materialization step and verify that restart
   creates no second task, session, schedule, or external effect. Use a
   controllable clock for deterministic tests rather than minute-long sleeps.

Implementation belongs in the workspace scheduling and worker modules, with
typed transport adapters, command specifications, and the existing calendar
bridge. The deterministic scheduling E2E owner remains
`tests/e2e/workspace-scheduling.test.ts`; transport and UI tests must exercise
the same series and occurrence identities. This proposal does not enable any
recurring execution until those paths and their recovery tests are implemented.
