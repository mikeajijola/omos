# Pinned Omniform standard

Source: https://github.com/mikeajijola/omniform

Revision: `28168db5d4522ffe3f0c2539f4c0e0c20ff38b53`

Package standard: `1.0.0-alpha.8`; declaration API: `omniform.org/v1alpha1`.

The schema, Apache-2.0 licence, and architecture reference are copied unchanged.
The upstream `src/validate.js` semantic validator is copied with only its schema
loading changed from filesystem reads to a static JSON import for application
bundling. No OmniSeed or Omniform runtime package is required.

## Local authority profile

`omniseedos.local-authority/v1` accepts an explicit subset of this standard.
Company definitions remain local immutable revisions. `spec.governance` is
rejected because it requires Git pull-request authority. Stewardship references
are supported, but `spec.stewardship.autonomy` is rejected because its gates,
merge duties and after-merge contract require Git semantics this profile does
not implement. Instance authority lives outside the declaration. Unsupported
settings must never be silently accepted as enforced policy.

The wrapper runs the full pinned schema and semantic validator before checking
these profile restrictions. New standard versions require an explicit release,
compatibility tests and definition migration; runtime repository updates do not
change accepted definitions.
