# omos workspace profile

`omniform.schema.json`, `validate.js`, `LICENSE` and `PROVENANCE.md` are unchanged
copies of the SaaS pinned standard at commit
`28168db5d4522ffe3f0c2539f4c0e0c20ff38b53`.
`omos.json` is the native host's seed declaration and is maintained in this fork.

The declaration API is `omniform.org/v1alpha1`; the pinned standard is
`1.0.0-alpha.7`. The native profile is `omos.workspace/v1` and accepts the
SaaS `omniseedos.semantic/v1` extension. It strips that extension only while
validating the upstream structural schema, then validates native semantic
references and supported execution features separately.

The native profile rejects Git-specific governance and stewardship autonomy,
required operation approvals, destructive data migrations and unsupported
operation-schema keywords. It retains permission policy in the host. Schema
references are local; declarations cannot fetch schemas or run programs.
The upstream JavaScript validator is exercised only by parity tests with Ajv
pinned in the E2E development dependencies.

The execution policy is a separate `omos.execution/v1` document. Its bounded
fields are `progress_interval` (1–100), `stalled_checks` (1–20) and
`max_actor_steps` (2–10000). Defaults are 4, 3 and 100 respectively.
The optional `review` section bounds model calls, reserved decision calls,
response and attempt deadlines, automatic attempts, total time, serialized
context, individual reads and reported token usage. New workspaces save these
settings explicitly. Missing review settings retain the legacy eight-call,
60-second, single-attempt policy. Automatic proposals may tighten allowances;
increases remain inactive. The optional `server.review_workers` setting accepts
1–4 independent review workers. New workspaces use 2; older policies retain 1.
The server reads this capacity at startup. Increasing capacity requires an
explicit contract migration rather than automatic proposal activation. Existing
task policy hashes remain unchanged. See [contract authority](../CONTRACTS.md).

`semantic.ts` is an unchanged reference copy of the SaaS extension from commit
`e3d1d5f1ed7d5918f9d6997949a942c7fcdcb2f1`. Parity tests use it with the SaaS's
pinned Zod version, 4.6.5. The native runtime uses the Zig implementation.

The first native profile does not rewrite existing company data from migration
defaults. Nonempty `migration.defaults`, field removals and type removals are
rejected explicitly. Compatible model additions use new entity types or
optional fields and require no rewrite of active task data.
