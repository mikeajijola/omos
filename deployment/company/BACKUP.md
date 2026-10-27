# Encrypt company backups and verify recovery

The optional `backup.mjs` operator companion stores verified Fossil exports and
selected authority keys in an encrypted Restic repository. Run it as the company
service account on Linux with Node.js 22, Restic with repository format 2 support,
`flock`, and the installed native runtime and Fossil helper.

The active Fossil repository, sparse projections, and temporary backup candidates
remain plaintext. Protect their volumes with host storage encryption. This
companion adds encrypted disaster recovery; it does not implement encrypted
canonical records or encryption for scoped capability exports.

## Configure a private backup domain

Use one Restic repository per company. Put it on persistent storage independent
of the company's active repository. Keep the password in a private file and
back it up separately through your organization's secret recovery process.
Losing that password prevents recovery of the repository and its keys.

Create the repository directory, staging directory, and configuration with modes
`0700`, `0700`, and `0600`, respectively. The password file must be `0600`.
Paths must be absolute and normalized. Symlinked paths, exposed credentials,
writable executable files, and overlapping repository/staging paths are rejected.
Use the actual immutable executable files behind installed aliases.

The following configuration is illustrative. Replace the workspace identity and
paths with those from the company service account's installation and binding:

```json
{
  "version": "omos.company-backup/v1",
  "workspace": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "profile": "/srv/omos/profile",
  "runtime": "/opt/omos/release/fx",
  "fossil": "/opt/omos/release/libexec/fossil",
  "restic": "/usr/bin/restic",
  "repository": "/mnt/backup/omos-company",
  "password_file": "/srv/omos/secrets/backup-password",
  "staging_root": "/srv/omos/backup-staging",
  "client_key_handles": [],
  "timeout_ms": 600000
}
```

`profile` is the service account's home directory. For creation, its
`.fx/omos-workspace.json` binding must match `workspace`. `client_key_handles`
selects up to 64 actor keys already enrolled in that company; an empty array
backs up only the current issuer key. Provider credentials, opaque provider
replay state, and unselected actor keys are excluded.

The companion passes a password file path to Restic, never its contents in
arguments or JSON output. Restic owns encryption and authentication; see its
[repository preparation](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
and [encryption documentation](https://restic.readthedocs.io/en/stable/070_encryption.html).
The encrypted domain manifest binds the Restic repository ID to the company.
An existing repository assigned to another company is rejected.

## Create and inspect a backup

From the unpacked distribution directory, initialize the encrypted domain:

```sh
node deployment/company/backup.mjs initialize --config /srv/omos/backup.json
```

Create a backup using a stable operation ID chosen by your scheduler:

```sh
node deployment/company/backup.mjs create --config /srv/omos/backup.json \
  --operation scheduled-2026-01-01
```

The JSON receipt identifies the exact snapshot, source accepted/control
revisions, company, key domain, and manifest hash. The companion checks every
stored file's SHA-256 digest and size and rejects files outside the manifest
before returning `verified: true`. A completed backup removes its private
plaintext candidate while retaining its receipt and encrypted snapshot.

Inspect a snapshot using the full 64-character ID returned in that receipt:

```sh
node deployment/company/backup.mjs inspect --config /srv/omos/backup.json \
  --snapshot "$SNAPSHOT_ID"
```

The manifest records all included files, source revisions, selected key handles,
runtime/helper identities, exclusions, and access requirements. Ordinary portable
exports remain separate from this private backup and do not include issuer keys.

## Retry interrupted operations

Repeat `create` with the same configuration and operation ID. A verified existing
snapshot returns `replayed: true`. An incomplete local candidate remains pinned
to its source revisions and key selection; retries verify and reuse it. Changing
those inputs under the same operation ID produces `BackupOperationConflict`.
Choose a new operation ID for a new scheduled backup.

A failed upload can return `outcome: "uncertain"` even when Restic committed the
snapshot. A retry searches by operation ID and verifies the existing snapshot
before deciding whether to upload. Multiple matching snapshots are a conflict.
The companion never automatically removes a Restic lock. Reconcile any previous
writer before applying Restic's operator recovery procedure.

A kernel lock beside the Restic repository serializes callers across different
profiles and staging roots on the same host. One deadline covers lock acquisition,
export, upload, content verification, and recovery. Its default is 10 minutes;
`timeout_ms` accepts 1 second through 1 hour. Cancellation terminates and joins
owned subprocesses before releasing the lock. Retain incomplete staging data on
encrypted storage until the operation is reconciled.

## Restore into quarantine

On a recovery host, install compatible native tools and provide the encrypted
repository, password file, and private configuration. A fresh `profile` directory
is sufficient for inspection and restoration; the original binding and live
issuer files are not needed. Set `profile` to that new private directory.

Restore to a new directory directly under `staging_root`:

```sh
node deployment/company/backup.mjs restore --config /srv/omos/backup.json \
  --snapshot "$SNAPSHOT_ID" --directory /srv/omos/backup-staging/recovery
```

Restoration verifies the manifest, exact tree, every file digest, company identity,
and native Fossil integrity. Native verification uses a separate copy, preserving
the restored repository's recorded bytes. A matching interrupted restore can be
retried at the same directory. An unrelated destination is rejected.

A successful receipt reports `restoration_verified: true`, with activation,
old-host fencing, and authority rotation still required. Restoration does not
replace an active binding, install recovered keys, start workers, or grant access.

Before activation, fence the previous host and review the restored revision and
pending external operations. For a fresh recovery profile, bind a separate copy
of the verified repository, inspect local company `status`, and submit a local
`rotate` request with that returned `revision`. Rotation creates a new issuer key,
advances the authority epoch, and revokes existing grants. Re-enroll actors
deliberately. This path does not require installing the archived issuer descriptor,
which still names the original repository path. Preserve recovered keys in
quarantine for the operator's audit and recovery policy; do not rewrite a bound
descriptor to bypass the native relocation checks.

Validate provider configuration separately. The backup contains no provider
credentials, and restoring a snapshot cannot undo external actions performed
after its source revision. Native authority recovery is described in the
[company service guide](README.md#backup-and-restore).
