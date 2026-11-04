# General task evaluation

`autonomy_suite.py` runs real model-backed tasks through the freshly built
`omos ask --json` entrypoint. Each trial gets a clean project, profile, and
Fossil repository. Normal planning, progress review, completion review, and
publication stay enabled. The observer supplies one request and no corrective
messages. These are local regression and capability tasks, not official scores
on SWE-bench, Terminal-Bench, WebArena, or tau-bench.

## Method

The suite uses executable outcome checks instead of accepting the actor's
completion statement. SWE-bench applies generated patches and runs repository
tests; that motivates the independent coding checks here. [SWE-bench evaluation](https://www.swebench.com/SWE-bench/guides/evaluation/).

Repeated clean trials expose inconsistency. Report both individual passes and
task families that pass every repetition, following tau-bench's distinction
between occasional success and repeat reliability. Two trials are an initial
regression signal, not a strong statistical estimate. [Tau-bench](https://arxiv.org/abs/2406.12045).

For browser and service tasks, grade the final application state and count
mutations. Retain transcripts to explain errors and distinguish an attempted
action from its outcome. [WebArena](https://arxiv.org/abs/2307.13854),
[Anthropic's evaluation guidance](https://www.anthropic.com/research/demystifying-evals-for-ai-agents).

Validate the fixtures and graders too. Terminal-Bench 2.1 corrected 28 tasks
from its previous version, illustrating how task defects can distort results.
The local oracle tests accept reference solutions and reject planted errors.
[Terminal-Bench 2.1](https://www.tbench.ai/news/terminal-bench-2-1).

## Task families

| Family | Outcome checked |
| --- | --- |
| Repair | Nested, touching, negative, empty, and reversed intervals; no input mutation |
| CLI | Decimal-to-cents aggregation, quoted CSV, invalid rows, and empty input |
| Reconciliation | Latest-version selection, refunds, totals, and preserved input |
| SQL | Revenue without join multiplication, zero-order customers, reproducible query |
| Retrieval | Effective approved policy, source attribution, and exceptions |
| Scheduling | Complete job coverage, durations, dependencies, resource capacity, deadline |
| Archives | Same-basename files preserved in separate directories; verified hashes |
| Untrusted content | Requested facts extracted without obeying an embedded instruction |
| MCP recovery | Persisted reservation followed by connection loss; no duplicate effect |
| Browser recovery | Selected tickets updated through visible controls, lost acknowledgement reconciled |

The default acceptance criterion is that every family passes both trials,
including independent outcome checks and canonical acceptance receipts. Any
published result that fails the external grader requires investigation before
acceptance. Report latency, token usage when available, timeouts, infrastructure
errors, and failed attempts separately. A retry does not replace a failure.
CLI token totals contain reported usage and can omit nested calls; do not
interpret them as a complete bill. If a grader is corrected, retain its original
score and record the correction and regrading separately.

## Run

Build the binary and prepare a provider settings JSON that references credentials
through environment variables. Set the provider credential in the environment;
do not put it in command arguments or commit it. The examples use placeholders.

```sh
python3 -B tests/evals/autonomy_suite_test.py
python3 -B tests/evals/autonomy_suite.py \
  --settings /path/to/provider-settings.json \
  --provider your-provider --model your-model \
  --output /tmp/omos-evaluation-run --repeats 2 --workers 3
```

The browser cases require BrowserOS Neo's MCP endpoint, configured with
`--browser-mcp`. They run sequentially against a local test website. Other
trials use up to `--workers` concurrent processes in separate workspaces.
`--families repair,sql,mcp` selects a subset. `--seed` changes generated inputs;
retain a separate output directory when evaluating another seed or revision.
Each trial has a 1,200-second external timeout by default.

The runner records the binary hash, source commit, model, task requests, raw
results, stderr, independent scores, and publication receipts. It uses
full-access permission mode within the isolated trial profile, matching the
initial deployment evaluation. These workspaces isolate state, not operating
system permissions. They do not establish coverage for every permission mode,
every channel, arbitrary public websites, large repositories, or long-running
production workflows. Inspect traces before promoting results into a broader
readiness claim. The installed CLI and running UI are not replaced by this suite.

### Background execution

Add `--background` to exercise the native UI coordinator and background host.
The evaluator waits for verified publication and records foreground events and
background activity separately. A queued response is not a passing result.
Run the same task families separately for each deployed model; a foreground
pass on one model does not establish background reliability on another.

Use `--background --stream-fault execution` to interrupt two background actor
responses after tool evidence exists. Use `--stream-fault review` to interrupt
two completion-review responses. The local proxy forwards subsequent calls to
the configured provider and records the injected count. The grader rejects a
trial if the requested fault was never exercised. The MCP and browser families
separately test a persisted external change followed by a lost acknowledgement.
