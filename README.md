# Fakebook Microservice System

## Runtime topology

| Component | Port | Public access |
| --- | ---: | --- |
| Authentication | 1001 | Internal/localhost only |
| SocialGraph | 1002 | Through Gateway |
| Recommendation | 1003 | Through Gateway |
| Search | 1004 | Through Gateway |
| Notification | 1005 | Through Gateway/SSE |
| Messenger | 1006 | Through Gateway/SSE |
| Payment | 1007 | Through Gateway |
| API Gateway | 2001 | Edge `/graphql` |
| Frontend | 3001 | Edge `/` |
| Upload Server | 4001 | Edge `/media` |

All PostgreSQL services use the external database configured in `.env`, own a
separate schema, and run with a distinct least-privilege login. Redis has two
independent responsibilities: SocialGraph application caching and the shared,
fail-closed anti-replay nonce store used by internal request validators. Browser
requests must use Gateway GraphQL, except authenticated multipart uploads sent to
Upload Server.

The current application host Tailscale address is `100.101.173.71`. TLS should still
use the MagicDNS HTTPS origin configured by `TAILSCALE_ORIGIN`. Compose points
Tailscale Serve at `127.0.0.1:${EDGE_PORT}`; host mode points it at the Vite edge on
`127.0.0.1:3001`.

Copy variable names from `.env.example`. Environment variables override appsettings.
Use a distinct Gateway-to-subgraph secret and a distinct target-service REST secret.
Managed startup fails closed when any dedicated key is missing, short, or duplicated;
`docker-compose.yml` no longer falls back to `GATEWAY_SHARED_SECRET`.

Initialize any missing local per-service secrets without changing database, SMTP, PayOS,
JWT, or existing secret values:

```powershell
.\scripts\initialize-secrets.ps1
```

### Security baseline

- API changes must follow [the API security contract](docs/api-security-contract.md) and
  pass `scripts/check-api-security-contracts.ps1`; coding-agent entry points are
  `AGENTS.md` and `CLAUDE.md`.
- Edge nginx and Gateway independently rate-limit `/graphql`; Upload Server has
  edge and authenticated per-user limits.
- Fusion rejects excessive depth, field/node/token counts, field cycles and unsafe
  planner expansion; execution time/concurrency is bounded and HTTP batching/multipart
  GraphQL is disabled.
- Internal REST requests use timestamped HMAC signatures and single-use nonces. Managed
  startup enforces signatures and does not transmit raw target secrets; see
  [internal request signing](docs/internal-request-signing.md).
- Recommendation fetches media only from an exact deployment allowlist, blocks unsafe
  address ranges, refuses redirects, caps streamed bytes and decodes downloaded videos
  from bounded temporary files rather than handing remote URLs to OpenCV.
- Upload content auditing scans the full bounded stream (including chunk boundaries),
  not only the first 8 KiB, and served media uses `X-Content-Type-Options: nosniff`.
- Authentication bounds BCrypt concurrency and queue length so anonymous register/login
  floods cannot create unbounded CPU work.

## Repository layout

This repository holds the orchestration layer only: `docker-compose.yml`, `scripts/`,
`docs/`, `.env.example` and this README. Each service lives in its own repository under
`github.com/fakebook-works/` and is cloned into the folder named in the topology table
above; those folders are ignored here so the two histories never mix.

Because the services are versioned separately, this repository cannot say on its own
which build of each service a given compose file was verified against.
`services.manifest.json` records that pairing — remote, branch and commit for all ten
services. Refresh it after a verified run:

```powershell
.\scripts\update-manifest.ps1
```

It warns when a service has uncommitted changes, since the recorded commit would then
not describe what was actually running.

## Verification

Install the repository-local schema/Compose validation tools once (no Docker daemon
is installed or changed by this command):

```powershell
.\scripts\bootstrap-tools.ps1
```

```powershell
.\scripts\test-all.ps1
```

When Docker is available the script also runs Payment Testcontainers. Without a daemon,
it still validates Compose with the checksum-verified standalone binary and reports the
skipped Payment container integration suite explicitly.

## Run without Docker

The repository also includes a host-mode launcher for this workstation. It builds and
starts all services on the canonical ports, generates a Development Fusion archive,
checks every readiness endpoint, and records process IDs/logs under `.run`:

```powershell
.\scripts\start-local.ps1
.\scripts\status-local.ps1
.\scripts\smoke-local.ps1
.\scripts\stop-local.ps1
```

Host mode requires the configured external PostgreSQL endpoint. The launcher starts the
checksum-verified Microsoft Garnet-compatible Redis server when no Redis endpoint is
already available. SocialGraph may fall back to PostgreSQL for its application cache,
but the security nonce store deliberately fails closed while unavailable. The Vite
launcher proxies `/api` and `/graphql` to Gateway and `/media` to Upload Server, so the
same relative browser URLs work through localhost or Tailscale.

Pass `-ConfigureTailscale` to expose the same-origin Vite development edge through the
configured tailnet HTTPS origin. Use `stop-local.ps1 -ClearTailscale` when that Serve
mapping should also be removed. Tailscale Serve must first be enabled by a tailnet admin;
if it is disabled, the launcher reports Tailscale's activation URL after 20 seconds and
keeps the fully healthy localhost stack running. Docker Compose remains the
production-like runtime.

## Canonical implemented behavior

The runtime contract is:

- Feed privacy is dynamic at read time: `0=public`, `1=friends and current followers`,
  `2=friends`, `3=author only`. Block always wins; tags and mentions never grant access.
- Group admins are also members. Group posts use mentions only and are linked to their
  author plus the group through `Published`; the removed `Owned` association is not used.
- `Contained=28` is the only media-parent association and `Visited=29`. A physical
  upload is deleted only after its final content/profile/message parent is removed.
- Only public feed posts and reels are shareable. Feed share wrappers remain present
  when their source is deleted or becomes private and render an unavailable-source state.
- User/group photo galleries and existing-photo pickers are context-scoped and paged.
  Avatar/cover crops are separate assets; original uploads create activity posts.
- Messenger creates direct conversations idempotently on the server, exposes Message on
  friend profiles, supports the topbar overlay and at most three floating chat windows.
  Message attachments are finalized/deleted through Messenger's retrying outbox.
- Notification has durable realtime delivery retry, server-side unread filtering,
  unread badges, mark-one/mark-all, pagination and object deep-links.
- Search returns authorization-filtered SocialGraph references. Fusion hydrates people,
  groups and reel authors in the same request; punctuation-aware tokens, bounded query
  fanout and orphan-token cleanup reduce database work.
- Uploads begin as pending assets. Domain services finalize them only after a successful
  mutation; abandoned assets expire and partial frontend upload batches are cancelled.
- Idle SocialGraph, Notification and Messenger outbox workers use bounded exponential
  polling backoff, and routine EF command logging is suppressed. This keeps realtime
  latency low after activity without continuously loading the external PostgreSQL host.

The configured PostgreSQL target is external (and may add visible network latency).
Frontend read requests also share simultaneous identical GraphQL queries and fail with a
bounded timeout (`VITE_GRAPHQL_TIMEOUT_MS`, default 20 seconds) instead of hanging.
`reset-demo.ps1` performs a read-only preflight by default and prints a fingerprint. It
never applies against Production, requires writers to be stopped, requires explicit
remote-Development approval, preserves every `__EFMigrationsHistory` table, and validates
upload cleanup targets before deletion:

```powershell
.\scripts\reset-demo.ps1
# Re-run the exact command printed by dry-run after stopping all writers.
```

For the Compose named media volume, pass its verified concrete Docker volume name with
`-DockerVolume`; for a workspace bind mount, pass `-UploadPath`. Backup with `pg_dump` is
the default; `-SkipBackup` and `-SkipUploadCleanup` are explicit acknowledgements.

After reset and migrations/service startup, deterministic demo data can be created and
verified without committing passwords or generated IDs:

```powershell
$env:FAKEBOOK_DEMO_PASSWORD = '<development-only-password>'
.\scripts\seed-demo.ps1 -AllowRemoteDevelopmentDatabase
.\scripts\verify-demo.ps1 -AllowRemoteDevelopmentDatabase
```

The seeder creates six users, all four feed privacy variants, public/private groups,
friend/follow/block topology, group posts, a photo post, notifications, Search indexes,
and an idempotent Alice/Bob direct conversation. Generated IDs are stored only in the
gitignored `scripts/seed/demo.receipt.json`.

## Architecture contract

This section is the source of truth for how the pieces talk to each other. **The
backend/API is implemented and stable — treat it as fixed and build the frontend against
it.** The frontend (`Frontend/Frontend`, a Vite + React + TypeScript SPA) is the part
still under active development.

### Communication rules

- **Browser ⇄ Gateway — GraphQL only**, over the edge `/graphql` endpoint. All
  reads/writes go through Hot Chocolate Fusion, which composes the seven subgraphs.
  Realtime Notification and Messenger updates arrive as GraphQL subscriptions delivered
  over SSE.
- **Browser ⇄ Upload Server** — the one non-GraphQL browser path: authenticated
  `multipart/form-data` uploads to `/media/*`, which return a URL the SPA then sends to
  the Gateway inside a normal GraphQL mutation. (PayOS webhooks are the only other REST
  path, and they reach the Gateway as a server-to-server proxy, not from the browser.)
- **Service ⇄ Service — signed REST** with a per-target HMAC key, timestamp and
  single-use nonce, never GraphQL, with two
  deliberate exceptions: Payment→Auth and Upload→Auth validate sessions by calling
  Auth's GraphQL `me { userId }` contract.

### Ports & trust headers

Services `100X` (1–7), Gateway `2001`, Frontend `3001`, Upload Server `4001`. Each hop
uses a distinct 32+ byte key. Internal REST sends only an HMAC signature in managed
environments; the Gateway forwards its separate trusted headers (user id / session id)
to subgraphs.

| Trust target/key | Header or protocol |
| --- | --- |
| JWT RS256 key pair | `Authorization: Bearer …` (`kid` selects the public key) |
| Gateway → subgraph | `X-Gateway-Secret` |
| Internal REST targets | `X-Internal-Timestamp`, `X-Internal-Nonce`, `X-Internal-Signature` |
| SocialGraph legacy migration header | `X-Internal-SocialGraphService-Secret` |
| Recommendation legacy migration header | `X-Internal-RecommendationService-Secret` |
| Search legacy migration header | `X-Internal-SearchService-Secret` |
| Notification legacy migration header | `X-Internal-NotificationService-Secret` |
| Authentication legacy migration header | `X-Internal-AuthenticationService-Secret` |
| Messenger legacy migration header | `X-Internal-MessengerService-Secret` |
| Payment | `X-Internal-PaymentService-Secret` |
| Upload Server | `X-Internal-UploadService-Secret` |

Use a **different** value for every key. `GATEWAY_SHARED_SECRET` remains a legacy-named
configuration value, but it is not a fallback for any dedicated key; environment
validation and Gateway Production startup reject collapsed key separation.

### Databases & Redis

Every service connects to the same external PostgreSQL host but uses its own
`<SERVICE>_DB_USER` / `<SERVICE>_DB_PASSWORD` runtime role and owns one schema: `auth`,
`social_graph`, `recommendation`, `search`, `notification`, `messenger`, or `payment`.
`DB_USER` / `DB_PASSWORD` are owner-only migration credentials and are not injected into
runtime containers. Each service folder documents its tables in `schema.sql` /
`*Schema.md`. Compose provisions Redis for SocialGraph caching and the shared security
nonce store. Never write real credentials into docs or source control.

### Service-to-service calls (REST)

- **SocialGraph → Recommendation** — create/delete user vectors and post/reel vectors.
- **SocialGraph → Search** — create/update/delete user/group/post/reel indexes.
- **SocialGraph → Notification** — create notifications.
- **SocialGraph → Authentication** — create/delete users.
- **SocialGraph → Messenger** — create/delete users.
- **Recommendation → SocialGraph** — fetch candidate post/reel ids.
- **Messenger → SocialGraph** — read friend/block relationships.
- **Payment → SocialGraph** — update the verified-badge (tích xanh) state.

## Operational constraints (do not change)

- `.env` as shipped: the external PostgreSQL over Tailscale, the optional Authentication
  email delivery, and the optional (disabled) PayOS credentials must not be modified.
- Internal service transport is private HTTP by design; TLS terminates at the tailnet
  edge (Tailscale Serve / MagicDNS HTTPS origin). REST payload integrity, target
  authentication and anti-replay are provided by HMAC request signing, without sending
  the raw key.
- Shared application secrets are 32+ characters each and must use different values.

## Frontend — the remaining work

The API surface is mature (~68 queries, ~78 mutations, 4 subscriptions), so frontend work
does not require backend changes. Start here:

- Code lives in `Frontend/Frontend` (Vite + React + TypeScript). See its own `README.md`
  for routes, environment variables (`VITE_*`) and `npm test`.
- All Gateway access goes through `src/api/client.ts`. It quotes Snowflake ids as strings
  before `JSON.parse` (they exceed 2^53 and would otherwise round), deduplicates identical
  in-flight read queries, and enforces a bounded request timeout — reuse these helpers
  rather than calling `fetch` directly.
- Upload media through the Upload Server helper (`/media/upload`), then pass the returned
  URL to the Gateway mutation that references it.
- The schema the SPA targets is the composed Fusion gateway; the per-subgraph SDL under
  `APIGateway/API-Gateway/fakebookGateway/Gateway/schema/**` is the authoritative field
  list.

The **Canonical implemented behavior** section above describes the exact runtime
semantics (feed privacy, groups, media lifecycle, sharing, messenger, notifications,
search, uploads) that the UI must honor.
