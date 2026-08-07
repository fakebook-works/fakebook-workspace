# Legacy media reconciliation (audit/export only)

This runbook inventories legacy Upload metadata against authoritative SocialGraph and
Messenger parents. The current tool is deliberately **read-only**: it exports a deterministic,
sensitive manifest and a non-sensitive receipt, but it never rewrites metadata or deletes media.
Passing `--apply` fails closed.

This boundary is intentional. Clearing `legacyPinned`, replacing reference sets, or unlinking an
unreferenced file must be performed by a separately reviewed offline migration that uses the same
Upload metadata-v3 serialization and bucket locks as the deployed Upload version. A second,
independent implementation inside the maintenance CLI could otherwise resurrect deleted bytes or
delete a still-referenced shared asset.

## What the audit reads

- SocialGraph Media objects still connected through `Contained` associations;
- user and group `avatar`/`background` slots;
- Messenger message attachments, thumbnails and conversation avatars;
- pending, processing and dead-letter media lifecycle outbox rows;
- Upload's physical files and `.metadata/*.json` lifecycle records.

Exact parent IDs are derived from database rows, never supplied by an operator. Managed absolute
URLs are accepted only when their origin exactly matches a repeated `--allowed-origin`; relative
`/media/files/...` paths are accepted. A foreign origin that imitates the managed path is a blocker,
not an external-media exception.

The manifest contains asset IDs, stored names and exact parent references. Treat it as sensitive
operational data: do not paste it into logs, issues or chat. The CLI prints only counts, finding
codes and a SHA-256 digest. On Unix the manifest is written mode `0600`; on Windows write it only
inside a directory whose ACL is restricted to the operator.

## Self-test

The self-test requires neither a database nor Upload storage:

```powershell
.\.tools\dotnet10\dotnet.exe run --project .\scripts\Fakebook.Maintenance -c Release -- `
  --reconcile-media --self-test --json
```

It verifies managed-location normalization, foreign-origin rejection, deterministic canonical
serialization and blocker generation.

## Online diagnostic snapshot

Use a migration/maintenance database credential that can read both the `social_graph` and
`messenger` schemas. Runtime service roles are intentionally schema-isolated and should not be
granted cross-schema access for this job.

First obtain the target fingerprint. `--upload-target` must name the same authoritative volume used
for reconciliation:

```powershell
.\.tools\dotnet10\dotnet.exe run --project .\scripts\Fakebook.Maintenance -c Release -- `
  preflight --env-file .env --upload-path D:\media --upload-target D:\media --json
```

Then export the snapshot outside the Upload storage tree:

```powershell
.\.tools\dotnet10\dotnet.exe run --project .\scripts\Fakebook.Maintenance -c Release -- `
  --reconcile-media `
  --env-file .env `
  --upload-path D:\media `
  --allowed-origin https://fakebook.example `
  --manifest-output D:\restricted-audit\media-manifest.json `
  --receipt-output D:\restricted-audit\media-receipt.json `
  --confirm <fingerprint> `
  --json
```

Repeat `--allowed-origin` for every legitimate historical Fakebook origin. Do not add a wildcard,
path-only hostname match, or third-party CDN unless that origin was actually authoritative for
`/media/files/`.

An online snapshot is diagnostic only. Concurrent parent writes can make it unsuitable as a future
migration input even though PostgreSQL rows are read in one repeatable-read transaction.

## Apply-grade frozen audit

Before producing a manifest that could be reviewed for a later migration:

1. Stop SocialGraph, Messenger, Upload and every lifecycle/outbox worker.
2. Stop the edge from serving `/media/files/`.
3. Take independently restorable PostgreSQL and media-volume backups.
4. Verify no alternate laptop/container instance uses the shared database or media root.
5. Run the same command with all three acknowledgements:

```text
--writers-stopped --serving-stopped --exclusive-lock
```

`--exclusive-lock` acquires all 256 Upload lifecycle bucket locks. The audit still performs no
mutation. `futureApplyPreconditionsSatisfied` is evidence about the frozen snapshot, not permission
to delete anything.

The audit fails with exit code `2` when it finds a blocker or an asset requiring manual review.
Important blockers include:

- outstanding legacy URL-only, exact, or mixed/invalid lifecycle outbox rows (a frozen
  migration snapshot requires every lifecycle queue to be drained);
- missing required tables or runtime database sessions after writers were declared stopped;
- managed-looking URLs from an unapproved origin;
- corrupt, missing or ownerless non-deleted metadata;
- a live database parent whose file is absent;
- unknown reference namespaces or ambiguous physical files.

Do not simply delete legacy outbox rows to make the audit green. A delayed legacy finalize can pin
the asset again, while discarding a legacy delete can retain personal data. Drain, transform or
archive each row as part of the separately reviewed migration and include it in that migration's
receipt.

## Classification guide

| Classification | Meaning |
| --- | --- |
| `ready-exact` | Metadata-v3 reference set matches authoritative parents. |
| `migrate-legacy` | A live parent exists, but metadata is legacy/pinned. |
| `reconcile-exact` | Metadata-v3 references differ from authoritative parents. |
| `migrate-live-parent` | A live parent still points at staged metadata. |
| `delete-unreferenced` | File and metadata exist, but no authoritative parent exists. |
| `metadata-only` | Unreferenced metadata remains but the physical file is absent. |
| `preserve-staged` | No parent yet; normal bounded staging retention still applies. |
| `already-deleted` | A tombstone exists and no live parent references it. |
| `manual-review` | The tool cannot establish a safe automated decision. |

`delete-unreferenced` is a recommendation in the manifest, not an action performed by this tool.

## Determinism and verification

The manifest has no generated timestamp and sorts assets, references and reasons canonically. With
all writers and serving stopped, rerun with the first manifest as `--verify-manifest` and a different
output path:

```text
--verify-manifest <first-manifest> --manifest-output <second-manifest> --confirm <fingerprint>
```

The command succeeds only if the byte-level SHA-256 digest matches. The receipt records the digest
and counts without copying raw references. Store both with the backup/change record.

## Requirements for a future destructive migration

A destructive implementation must be reviewed separately and must, at minimum:

- require the frozen acknowledgements, exclusive Upload locks and an exact manifest digest;
- re-read the authoritative snapshot and refuse any changed parent/reference set;
- rewrite metadata-v3 atomically using Upload's deployed serializer, never ad-hoc JSON patching;
- preserve staged/reserved uploads and pin every corrupt, missing, ownerless or ambiguous asset;
- tombstone before unlinking an unreferenced file and retain the minimal deletion receipt;
- be restartable and idempotent after interruption at every write/unlink boundary;
- produce a signed/restricted receipt without raw URLs or user data;
- pass restore, rollback, Linux filesystem and shared-volume lock tests before production use.

Never expose a restored media snapshot before current tombstones and authoritative parent state have
been replayed; otherwise erased media can be resurrected.
