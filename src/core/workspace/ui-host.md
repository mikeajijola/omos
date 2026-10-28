# Native workspace UI host

`zig-out/bin/fx ui-host --stdio` connects an external interface to the existing saved native session runtime. The interface does not own agent continuation, permissions, contracts, assessments or publication.

Each request is one JSON line with `version: "omos.ui-host/v1"`, an alphanumeric or hyphenated `id` of at most 128 bytes, a `method` and typed `params`. Responses retain the request identity. Public events carry a turn identity and monotonically increasing cursor. An invocation writes its public journal before sending events. Journals and session checkpoints remain operational profile state outside Fossil.

Supported operations:

| Method | Behavior |
| --- | --- |
| `initialize` | Inspect the transport version, project and active invocation. |
| `prompt` | Run a saved native turn with optional session, model, effort and host-resolved images. |
| `coordinate` | Run the main conversation with read-only inspection and durable handoff of its unchanged contract to an independent worker. |
| `background` | Inspect workers and bounded event pages, or submit trusted generation-fenced guidance, cancellation, input, validation and resumption controls. |
| `events`, `session.events` | Retrieve up to 32 retained public events by byte offset. |
| `cancel`, `steer` | Stop or steer the exact active invocation. |
| `input` | Resolve an exact pending native question or permission request. |
| `validation` | Return a host compilation receipt for an exact pending source revision request. |
| `snapshot` | Read an allowlisted native JSON snapshot; arbitrary CLI arguments are unavailable. |
| `workspace` | Use the revision-pinned read-only workspace service. |
| `profile.read`, `profile.update` | Read or explicitly replace the local owner's portable profile photo through the host-owned record and image store. |
| `ui.current`, `ui.history`, `ui.inspect`, `ui.read` | Inspect saved or selected-task UI source and historical versions. Individual source reads are bounded to 16 KiB. |
| `ui.install` | Install and verify the first compatible source tree without overwriting an existing interface. |
| `ui.write` | Write task source with a revision fence; publication remains pending. |
| `ui.import_legacy` | Retain local appearance history as an unpublished migration artifact on a paused task branch. |
| `task.resume` | Select retained work with a current task revision fence. Explicit `rebind_project: true` relocates eligible personal work to the host's project and requires fresh source validation. |

A repeated prompt ID must identify the same request. Reconnection reads events; it never starts another invocation. If the native process stops, the external host reports retained partial work and requires explicit continuation.

A coordinated handoff releases the main session's task selection after its checkpoint is durable. It reports delegated work rather than completed obligations. Background workers own independent saved sessions and task leases; only independently verified Fossil publication establishes completion. Worker input and validation decisions belong to the trusted external host. Its main conversation can continue while a worker waits. See [background contract workers](README.md#background-contract-workers) for lifecycle, local activation and recovery semantics.

Complete frontend source belongs under `ui/`. Its manifest pins `omos.ui-source/v1`, `omos.ui-bridge/v1`, `omos.react/v1` and the external compiler identity. The host creates a compilation receipt with version `omos.ui-validation/v1`, status, compiler and bundle identities, and the exact source-file hashes and sizes. Only trusted external host code may answer validation requests. Editable interface code must not have this authority or permission approval authority.

The native completion path retains the candidate before requesting validation. A source change invalidates earlier validation. Compilation failure requires further work; unavailable validation retains a review failure for later verification. Validation uses the pinned review policy's first attempt deadline, clipped to the total review allowance. Waiting for the host consumes that same allowance rather than starting a separate 60-second timer or renewing the model budget. Cancellation stops the wait; late responses cannot satisfy a retired request. Independent contract review still decides whether obligations are met. Publication checks the source receipt again before writing its durable publication operation.

Compilation receipts establish compilation, not visual correctness or external-action success. The compatible external renderer must provide isolation, preview recovery, browser verification and a way to rebuild its disposable cache from saved Fossil source.

Native UI turns identify the Fossil `ui/` tree as the running interface source. Tool-start events expose only bounded `path` and workspace `action` presentation fields, not file content or arbitrary arguments. Tool outcomes preserve their native kind and summary so the interface can show a held or denied action.

The `fossil_workspace` tool uses native workspace ownership and protected-path checks without a second model safety review. Configured permission rules still apply. A saved task is required for mutations; ephemeral sessions remain read-only. The tool cannot overwrite host-owned evidence, assessments or publication receipts. Completion still requires independent verification and native publication.

The UI host initializes an empty personal Fossil instance when no workspace is bound. Profile updates accept a validated base64 PNG, JPEG or WebP up to 512 KiB, or null for removal. They return the content and saved revision. The profile entity must exist in the current declaration. The external UI host owns migration of an old operational photo and retains its original source.
