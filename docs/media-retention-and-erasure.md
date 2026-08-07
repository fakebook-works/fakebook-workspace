# Media retention and erasure runbook

This document defines the operational retention contract for Fakebook's authoritative
Upload storage. It is an engineering control, not a legal-compliance certification.

Legacy deployments must be inventoried with the read-only procedure in
[Legacy media reconciliation](media-legacy-reconciliation.md). That tool does not delete or rewrite
assets; destructive migration remains a separately reviewed offline operation.

## Primary-storage lifecycle

| State | Default retention | Serving policy |
| --- | ---: | --- |
| Quarantined raw upload | 60 minutes after it becomes stale | Never served |
| Staged upload not attached to content | 24 hours; an active browser reservation is bounded to 2 hours | Preview only through its unguessable managed path |
| Server-authorized exact parent awaiting durable finalize | 7 days, renewed by safe outbox retry | `private, no-store` |
| Media with one or more exact parent references | While at least one parent exists | `private, no-store` |
| Final parent detached | No reference deletion grace | Tombstoned first, then physically deleted immediately |
| Minimal deletion tombstone | 30 days | Never served |

Each durable parent uses a server-derived reference ID. Posts, reels, stories, comments,
profile/group image slots, message attachments, message thumbnails and conversation avatars
must attach and detach their own reference. Deleting one parent must not delete a shared asset;
deleting the last exact parent must not leave the bytes available.

The content mutation and its media lifecycle outbox row commit in the same service database
transaction. Upload authorization reserves the exact new parent before that commit. If the
parent transaction fails, the service cancels only that reservation. Upload writes a minimal
tombstone before unlinking bytes, so an interrupted unlink is denied by the serving path and
retried by the startup/periodic cleanup sweep.

The seven-day exact-parent reservation is a bounded recovery window, not a normal retention target:
it protects a committed parent when Upload/finalize delivery is unavailable for an extended outage.
Retrying a committed finalize safely renews the same exact reference with its original database
operation time; a newer/equal detach tombstone still wins, so renewal cannot resurrect deleted
content. Alerting must act long before the lease expires. The lease does not delay a valid final
detach, which is tombstoned immediately when no active or pending parent remains.

An unprocessed media lifecycle or account-erasure event remains retryable with bounded backoff and
is excluded from dead-letter retention purge. The deletion instruction is not discarded merely to
keep the outbox table small. Once an asset is deleted, its minimal tombstone drops active, pending
and released parent identifiers; duplicate detach only retries unlink and never extends `DeletedAt`.

A successful content-deletion mutation means the deletion event is durably scheduled; it is not
an assertion that a remote filesystem unlink has already completed. Under healthy dependencies the
priority outbox should dispatch promptly. Alert when the oldest retryable `media.delete` event or a
tombstoned-but-present file is older than five minutes, and treat continued growth as an erasure
incident. Dependency outages can extend physical deletion beyond the normal target and must remain
visible rather than being reported as completed.

## Deployment and restore requirements

- Deploy the exact-reference-capable Upload Server before SocialGraph or Messenger clients that
  require it. Clients must verify Upload's exact-lifecycle acknowledgement and fail closed when
  an older server ignores the reference payload.
- Keep SocialGraph and Messenger lifecycle writers on the same authoritative PostgreSQL clock
  domain (the supported Fakebook topology uses one PostgreSQL host). If services are split across
  databases with independently skewed clocks, do not enable exact-reference replacement until a
  shared monotonic lifecycle sequence is deployed; wall-clock timestamps alone are not a total order.
- Run only one periodic cleanup owner for a shared media root unless the underlying filesystem's
  cross-host locking semantics have been verified. Deploy Compose is the default cleanup owner;
  `start-local.ps1` defaults `LOCAL_UPLOAD_CLEANUP_ENABLED=false`. A standalone local environment
  may opt in explicitly. Lifecycle request writes remain locked on every instance.
- Do not enable CDN or reverse-proxy media caching without a tested purge API. The application
  currently emits `Cache-Control: private, no-store`.
- Backups, snapshots and object-store versioning need a documented maximum retention period.
  Before a restored media volume is made reachable, replay current deletion tombstones and parent
  state so an older snapshot cannot resurrect erased media.
- A legal hold, if required by the operator's jurisdiction, must use a separately authorized and
  audited mechanism. Do not silently turn the normal user-deletion path into indefinite retention.
- Existing URL-only/legacy-pinned assets require the frozen audit and separately reviewed offline
  migration described in [Legacy media reconciliation](media-legacy-reconciliation.md). The current
  audit/export command is deliberately read-only; never clear `legacyPinned` by guessing from one
  service or URL.

## Verification checklist

1. Delete a parent whose media has no other reference; after the durable `media.delete` outbox row
   is dispatched, the media URL must return 404. Under healthy dependencies this is expected within
   seconds, but the API response itself means "durably scheduled", not "filesystem unlink confirmed".
2. Verify the primary file is absent, or remains behind a tombstone only until the next two-minute
   retry sweep if the filesystem temporarily rejects unlink.
3. Delete one of two parents sharing a URL; the remaining parent and URL must continue to work.
4. Kill Upload after tombstone creation but before unlink, restart it and verify the startup sweep
   removes the lingering file.
5. Verify a stale attach/authorize event cannot revive a released reference.
6. Verify raw quarantine files older than the configured retention are removed while locked/current
   sanitizer jobs are preserved.
7. Monitor repeated physical-delete failures and outbox retries; an unprocessed deletion event is an
   operational incident, not a successful erasure.

The design follows the storage-minimization and erasure principles expressed in GDPR Articles 5
and 17: <https://eur-lex.europa.eu/eli/reg/2016/679/oj>. Vietnamese deployments must also assess
their controller/processor duties under Decree 13/2023/NĐ-CP:
<https://vanban.chinhphu.vn/default.aspx?docid=207759&pageid=27160>. Operators remain responsible
for the law, backup policy and processor contracts applicable to their deployment.
