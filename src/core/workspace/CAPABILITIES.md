# Conversation and content capabilities

The native `omos.capabilities/v1` contract supplies content retrieval,
classification, conversation inspection, and the human attention feed. The CLI,
workspace UI, local MCP adapter, and agent tools call the same implementation.
These operations do not replace task contracts, permission checks, or publication
receipts.

## Call from the CLI

Save a request as JSON and run the repository binary:

```sh
./zig-out/bin/fx fossil capabilities request.json --json
```

For example, find retained application records:

```json
{"action":"search","retrieval":{"query":"applications","limit":10}}
```

Read a result with its returned `path` and `revision`. Both the source artifact
and the check-in revision appear in the response. Search excerpts are previews;
read the source before asserting that an action happened. A conversation saying
an application was sent is not itself a submission receipt.

```json
{"action":"query","retrieval":{"path":"documents/applications.json","filters":[{"field":"status","equals":"submitted"}],"order_by":"submitted_at","descending":true,"limit":1}}
```

JSON queries accept a slash-separated `pointer` to an array, exact scalar filters,
and an optional sort field. Numbers sort numerically and strings lexically; use
normalised ISO timestamps for dates. Missing sort values come last. Returned rows
include their original array index. Without a document path, `query` uses the
existing typed workspace-record query and optional `entity`.

SQLite artifacts use the same `query` action. Supply a database `path` without
`entity` to list its ordinary tables, then select a table with `entity`. The
response includes columns, filtered rows, and the source revision. Exact filters,
sorting, and pagination use column names. SQLite column affinity controls sorting;
primary keys or row IDs break ties. BLOB values are returned as hexadecimal.
Views and virtual tables are excluded. Queries run against a verified, read-only
snapshot through the bundled Fossil helper; callers cannot submit SQL.

Search pages include `next_offset`, `revision`, and `runtime_revision`. Pass all
three back when continuing a search so later commits do not change its source
set. Queries and reads accept the source revision too. A task ID selects that
task's retained branch; default searches inspect published personal content and
retained runtime projections. Raw execution history is searched only with an
explicit `history/` path filter, avoiding a full scan of tool journals for ordinary
knowledge questions. Company repositories are not implicitly downloaded
or searched.

The disposable local text cache is keyed by verified Fossil artifact hashes.
Unchanged artifacts reuse their entries and new artifacts are indexed on demand.
A read always verifies the original object. Search reports coverage gaps for
binary files, PDFs without extracted text, and text above the indexing limit.
An empty result with incomplete coverage is not proof that no matching record
exists. Search and query limits are result counts from 1 to 32. Omit `limit` for
reads: each read returns up to 16,384 bytes and preserves UTF-8 boundaries. Use
the returned `next_offset` to continue reading.

## Classify explicit choices

Configure the classifier in the host environment:

```sh
export OMOS_CLASSIFIER_URL=http://127.0.0.1:11435
export OMOS_CLASSIFIER_MODEL=laya:en
```

Alternatively, save `{"version":"omos.classifier/v1","endpoint":"http://127.0.0.1:11435","model":"laya:en"}`
in the private profile file `~/.fx/classifier.json` with mode `0600`. That setting
applies to CLI and UI hosts using the same profile. Environment endpoint
configuration overrides the profile file.

`OMOS_CLASSIFIER_TOKEN`, when needed, supplies the bearer token. Keep credentials
and private endpoints out of workspace files and Git. The endpoint must implement
Ollaya's `/v1/systemone` choice API. This configuration is owned by the host;
agent arguments cannot override it.

```json
{
  "action":"classify",
  "classification":{
    "state":{"message":"What was our last application?"},
    "questions":[{
      "id":"route",
      "instructions":"Choose whether this requires information or changes.",
      "choices":[
        {"label":"retrieval","description":"Read existing information"},
        {"label":"work","description":"Change state or perform actions"}
      ]
    }]
  }
}
```

`fossil classify classification.json --json` accepts the inner classification
object directly. Results include the selected label, offered-choice probabilities,
model, elapsed time, and an advisory marker. Invalid labels or distributions are
errors. Requests have a 10-second transport deadline and explicit size limits;
the model may reject input that exceeds its own token window. Rejected input is
not silently truncated.

With the endpoint configured, saved root requests are classified before task
planning using the latest message and bounded recent conversation. Confident
conversation and retrieval routes get a read-only tool set and at most six agent
steps. They do not create task contracts. Uncertain classifications get one bounded contextual model call with recent
conversation and the active task identity. A resolved work request retains the
existing governed execution path. If resolution fails, the read-only turn can
inspect information or ask for missing context without starting actions. Routing records retain the outcome, probability
scores, reason, and whether context was omitted. Background workers continue their
existing contracts. Classification remains available as the `classify` tool to
ordinary, coordinator, read-only, background, and child agent tool projections,
subject to the normal permission rules.

## Conversations and attention

Use `conversations` to list chats and `conversation` with `session` to read public
turns. Saved turns project their public history into
`runtime/conversations/<session-hash>.json` on `omos-runtime`. Provider replay,
credentials, and recovery payloads stay in the private profile. A retained
projection can be read from another working directory or after moving the Fossil repository to another machine;
it does not restore the private execution session or grant permission to resume
work. Large histories are paginated.

`attention` projects unresolved UI-host and background-worker input events.
Retained background work in the waiting state appears with its reason and task
identity, without being treated as an actionable approval. Blocked tasks,
publication conflicts, and pending publication also appear for inspection. It checks live journal locks
before showing a request as actionable, so an abandoned journal cannot become an
approval after a crash. A feed item carries its originating conversation and
request identity. Responses still use the existing protected host controls and
current generation/request fences. Incomplete scans are marked incomplete and
omit possibly stale approvals.

Readable input and resolution events live under `runtime/attention/`. These are
historical records, not live approval authority. Routing diagnostics live under
`runtime/routing/`. Search includes these runtime projections. `--no-save` turns
do not retain conversation or routing projections.

## Surface mapping

| Capability | CLI request action | Workspace UI | Local MCP tool | Agent tool |
| --- | --- | --- | --- | --- |
| Classification | `classify` | Classify | `omos_classify` | `classify` |
| Content search | `search` | Search | `omos_search` | `workspace_content` |
| Pinned source read | `read` | Open search result | `omos_read` | `workspace_content` |
| Structured records | `query` | Query records | `omos_query` | `workspace_content` |
| Pending human inputs | `attention` | Needs you | `omos_attention` | `workspace_content` |
| Conversation history | `conversations`, `conversation` | Chats | `omos_conversations`, `omos_conversation` | `workspace_content` |

The local MCP adapter is `omos-ui/bin/mcp.mjs`; set `OMOS_BINARY` to the absolute
native binary and `OMOS_PROJECT` to the project directory. It also exposes chat,
event polling, steering, and cancellation through the native conversation host.
Start it with `--operator` only for a trusted human-operated client that needs
protected input and background mutation controls. Classification output never
changes that authority. The signed company MCP transport retains its separate
company scope and grants.
