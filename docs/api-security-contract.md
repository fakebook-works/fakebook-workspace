# Fakebook API security contract

This document is mandatory for humans and coding agents that add or change an API in
Fakebook. It describes the trust boundaries that already exist. Do not replace these
controls with a new local convention.

## 1. Definition of done

An API change is not complete until all applicable items below are true:

1. The caller and trust boundary are identified.
2. Authentication establishes a server-owned identity.
3. Authorization is checked against the target resource and current database state.
4. Inputs, list sizes, body sizes and pagination are bounded.
5. Cross-service effects are idempotent and do not leave half-committed state.
6. Logs and telemetry contain no credentials, tokens, message/content bodies or GraphQL variables.
7. Security regression tests cover unauthorized, spoofed, blocked/private and duplicate/replay cases.
8. The workspace security contract and complete test suite pass.

~~~powershell
.\scripts\check-api-security-contracts.ps1
.\scripts\test-all.ps1
~~~

If Docker is unavailable, test-all reports the skipped Payment Testcontainers explicitly.
Do not describe those integration tests as executed.

## 2. Public entry points

Browser traffic has only these supported entry points:

- Gateway /graphql for application reads, writes and subscriptions.
- Upload Server /media for authenticated multipart upload and media delivery.
- Gateway /api/webhooks/payos for PayOS server callbacks.

Do not expose a subgraph port, add a browser-to-service REST shortcut, or let frontend call
service URLs directly. A new public REST route needs a written reason plus authentication,
authorization, content-type validation, a body-size cap, rate limiting and security tests.

Gateway must continue to enforce query parser, depth, field-cycle, planner, execution
timeout/concurrency and request-rate limits. Do not bypass Fusion by proxying arbitrary
GraphQL documents to a subgraph.

The Nitro browser IDE on `/graphql` is Development-only. Production must keep normal
GraphQL HTTP/SSE application traffic working while returning no Nitro HTML. Fusion
subgraph destinations come only from startup-validated `Subgraphs:<Name>:Url`
configuration: defaults use canonical loopback ports and deployment Compose may override
them for its reviewed network topology. Never derive a transport URL from a browser input.

## 3. Identity and trusted headers

Never authorize from a userId, sessionId, role, ownerId or admin flag supplied in GraphQL
input, query string or JSON. IDs in input identify a target; they do not prove who calls.

Gateway strips browser-supplied internal headers, validates RS256 JWT issuer, audience,
algorithm and kid, validates the live Auth session, then builds trusted identity headers.
Subgraphs consume identity only through their established accessors:

| Service | Required identity accessor |
| --- | --- |
| SocialGraph | TrustedCallerAccessor/current trusted caller helpers |
| Search | TrustedGatewayUserAccessor |
| Notification | ICurrentGatewayUser/CurrentGatewayUser |
| Messenger | ITrustedUserContextAccessor |
| Payment | IGatewayRequestContextAccessor |
| Authentication | validated JWT/session context or protected internal caller |
| Upload | validated bearer JWT plus active Auth session |

Do not read X-User-Id directly in a resolver. Do not add a second identity parser. A public
operation requiring login must reject missing, duplicate, malformed or untrusted identity.

Authorization must be resource-specific. At minimum test:

- anonymous caller;
- valid caller who does not own/cannot view the target;
- spoofed user/session headers;
- deleted/revoked session where applicable;
- block and privacy rules for SocialGraph data.

## 4. Internal REST

Every service-to-service route under /internal uses the existing request-signing
implementation. Clients use the registered signing handler; targets use the existing
validation middleware.

Required properties:

- distinct secret per target; never fall back to one fleet-wide secret;
- HMAC covers version, method, path/query, timestamp, nonce and exact body hash;
- managed runtime sets RequireSignature=true and SendLegacySecret=false;
- nonce is claimed atomically in shared Redis with NX and expiry;
- Redis outage fails readiness and returns 503, never in-memory/fail-open;
- partial/malformed headers, timestamp skew, duplicate nonce and invalid signature fail;
- request body validation remains bounded and the stream is rewound for model binding.

Do not hand-build signature headers in feature code. Do not send the raw target secret.
Do not disable signature enforcement to make a test pass. See
[internal request signing](internal-request-signing.md) for the wire contract.

## 5. JWT and session rules

- Auth alone receives JWT_PRIVATE_KEY_BASE64 and signs RS256 tokens.
- Gateway and Upload receive only JWT_PUBLIC_KEY_BASE64.
- Validate issuer, audience, lifetime, RS256 algorithm and kid.
- JWT_LEGACY_SIGNING_KEY is migration-only and stays empty in the current environment.
- Access-token acceptance does not replace live session validation at public edges.
- Refresh tokens remain hashed at rest, rotate on refresh and are never returned in the
  public composed schema.
- Sliding refresh cannot pass absolute_expires_at.
- Reuse of a superseded refresh token follows the existing compromise/revocation flow.
- BCrypt work must stay behind IPasswordHasher and its bounded concurrency queue.

Never log JWTs, refresh tokens, cookies, OTP values or password hashes.

## 6. SocialGraph privacy, block and ownership

Use existing services instead of recreating policy in a resolver:

- BlockVisibilityService for two-way block filtering.
- SocialReadModelService/ContentGraphService visibility methods for content.
- trusted caller helpers for actor identity.
- Upload authorization/finalization clients for media ownership.

Canonical feed/reel privacy:

- 0: public;
- 1: friends and current followers;
- 2: friends;
- 3: author only.

Block always wins. Tag/mention never grants read access. Group membership/admin and content
privacy are evaluated from current state at read time.

For new SocialGraph APIs test public/friend/follower/other/author, both block directions,
deleted source, private shared source, group member/non-member and target ownership as
applicable.

## 7. Cross-service mutation and consistency

Do not keep a database transaction open as a substitute for atomicity across HTTP.

- Persist local state and integration outbox state atomically.
- Encrypt sensitive outbox payloads with the configured payload protector.
- Make downstream create/update/delete operations idempotent.
- Classify retryable versus permanent failures.
- Bound retries and move terminal work to dead-letter.
- Release worker locks before network dispatch.
- Use a saga/compensation when a required projection can leave canonical state unusable.

Registration is the reference: Auth is the required gate; derived projections run only
after Auth accepts; terminal Auth failure compensates the SocialGraph user.

Automatic HTTP retry is allowed only for GET, HEAD and OPTIONS. POST, PUT, PATCH, DELETE
and CONNECT require explicit idempotency semantics before any retry.

## 8. Database contract

- Runtime services use their own schema-scoped role.
- Runtime code must not receive DB_USER/DB_PASSWORD of the migration owner.
- Runtime roles do not create/alter schema.
- Put DDL in a reviewed migration and run it with writers stopped when required.
- New tables/sequences need grants/default privileges for exactly the owning runtime role.
- Queries and deletes must be bounded; add indexes for new authorization/hot paths.
- Parameterize SQL. Never construct SQL from user-controlled identifiers or values.

After a DB privilege/migration change run:

~~~powershell
$dotnet = & .\scripts\resolve-dotnet.ps1
& $dotnet run --project .\scripts\Fakebook.Maintenance -- verify-service-roles --env-file .\.env --json
~~~

## 9. Upload and remote media

Upload APIs retain all of these checks:

- authenticated bearer plus active Auth session;
- safe leaf filename and generated storage name;
- extension/content-type allowlist and magic-byte match;
- request/file count and byte limits;
- full-stream active-content audit before publish;
- fail-closed removal of privacy metadata from every accepted image/audio/video container
  before its generated public path becomes visible;
- raster image decoding/re-encoding must force the already-validated MIME decoder, cap
  dimensions/cumulative pixels/frames/native memory/time, strip profiles/comments and
  preserve orientation/transparency/animation or reject the upload; it must never copy
  an unsupported animation or vendor metadata record through unchanged;
- per-user and edge rate limits;
- owner-scoped authorization plus signed, idempotent, exact parent-reference attach/detach;
- attach authorization before the parent transaction commits, and a durable lifecycle outbox in
  the same database transaction as the parent mutation; rollback cancels only its exact pending
  reservation and never hides the original parent-write failure;
- cross-process lifecycle serialization and tombstone-before-byte deletion. The final exact
  detach denies serving immediately and deletes primary bytes without a retention grace; a
  periodic cleanup sweep only retries an interrupted delete. A URL-only stale event must never
  delete an asset while any content/profile/message reference or bounded reservation remains;
- attach requires the trusted media owner. Ownerless signed calls may detach an exact server-
  derived reference, but may not attach/pin media or perform online legacy repair;
- corrupt, missing or pre-reconciliation lifecycle metadata is retained for operator repair,
  never guessed safe for destructive cleanup;
- media responses are `private, no-store` until a verified CDN purge contract exists;
- nosniff response header.

Recommendation remote fetches must go through the SSRF guard: exact deployment allowlist,
DNS/IP validation, dangerous-range blocking, redirects disabled, byte/time cap and bounded
temporary-file decoding. Never pass a user-controlled URL directly to requests, HttpClient,
OpenCV or another decoder.

## 10. Logging, errors and telemetry

- Return stable public error codes; do not leak stack traces, SQL, secret names or account
  existence.
- Keep correlation IDs, operation names, status and duration.
- Do not capture Authorization, Cookie, signature headers, GraphQL variables, request/
  response bodies, message text or uploaded content.
- Do not put PII into metric labels or high-cardinality trace attributes.
- Security-store/DB readiness failure is 503; invalid authentication/signature is 401/403
  according to the existing boundary.

## 11. Required tests for a new API

At minimum add:

1. happy path;
2. anonymous/untrusted caller;
3. caller authenticated as the wrong user;
4. malformed and boundary-size input;
5. duplicate/idempotent request where a mutation crosses services;
6. dependency timeout/failure and retry classification;
7. privacy/block/ownership matrix if content or media is involved;
8. schema composition test when GraphQL surface changes;
9. rate-limit/body-limit test for a public REST exception;
10. a regression test for the concrete vulnerability the change could introduce.

Run package audits after dependency changes. Never weaken a rule or remove a negative test
merely to make CI green.

## 12. What the guard script can and cannot guarantee

check-api-security-contracts.ps1 detects accidental removal of major structural controls:
distributed replay protection, signing implementation drift, JWT key separation, safe
retry, Gateway limits, BCrypt isolation, SocialGraph visibility kernel, Upload full scan,
Recommendation SSRF guard and owner DB isolation.

It cannot prove that new business authorization is correct. A human or capable review
agent must still inspect the resolver/endpoint, data flow and negative tests. Security is
a release gate, not a one-time property inherited automatically from the repository.
