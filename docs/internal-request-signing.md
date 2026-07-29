# Internal REST request signing (anti-replay) — v1

Status: **implemented and enforced** by the managed Compose and host launchers.

This protocol applies to every service-to-service REST request under `/internal`.
It replaces the legacy pattern of sending a raw target-service secret over the
internal HTTP connection.

## Security properties

- The target secret is never put on the wire when
  `SendLegacySecret=false`.
- The HTTP method, path/query and exact request body are authenticated.
- A timestamp limits the lifetime of a captured request.
- A random nonce can be accepted only once during its retention window, across
  every replica, through an atomic Redis `SET key value NX EX ttl` operation.
- Partial signing headers, malformed signatures and replayed nonces fail closed,
  including while a service is in migration-compatible legacy mode. When
  signature enforcement is enabled, an unavailable nonce store returns 503
  instead of accepting the request without replay protection.

Internal transport remains private HTTP inside localhost/Docker bridge/Tailscale.
Tailscale encrypts host-to-host traffic and TLS terminates at the tailnet edge.
Per-service mTLS is not added because it would introduce a second certificate
lifecycle without improving browser-edge security; request signing removes the
raw application credential and gives internal messages integrity and
anti-replay protection.

## Wire headers

A signed request carries:

```text
X-Internal-Timestamp: <Unix seconds UTC>
X-Internal-Nonce:     <32 hexadecimal characters>
X-Internal-Signature: <64 lowercase hexadecimal HMAC-SHA256 characters>
```

The old `X-Internal-<Target>Service-Secret` header is included only when
`SendLegacySecret=true`. Managed production/local startup sets it to `false`.

## Canonical value

Six values are joined with `\n`, without a final newline:

```text
v1
{HTTP-METHOD-UPPERCASE}
{path-and-query}
{timestamp}
{nonce}
{lowercase-hex-sha256-of-exact-body}
```

Example path/query: `/internal/users/42/friend-ids?scope=direct`. Empty
bodies use SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
The signature is
`HMAC-SHA256(target-secret-utf8, canonical-value-utf8)`.

Internal endpoint URLs intentionally use IDs and fixed query values that need
no ambiguous percent-encoding.

## Validation

A target service performs these checks before its existing authorization
middleware/handler:

1. The three headers must be all absent or all present exactly once.
2. If they are absent, the request is accepted only in explicit legacy mode
   (`RequireSignature=false`); the old constant-time secret check still runs.
3. If any signing header is present but invalid, the request returns 403 even
   in legacy mode.
4. Timestamp skew is at most 300 seconds by default.
5. Nonces are exactly 32 hexadecimal characters and are reserved atomically in
   the shared security Redis store for 900 seconds by default.
6. The signature comparison is constant-time.
7. The body used for validation is capped at 2 MiB by default and rewound before
   downstream model binding.
8. A validated signature causes the target's old secret header to be injected
   only into the in-memory server request. This reuses the existing target
   authorization logic without transmitting the secret.

Nonce state is not process-local. Every validating service uses the same Redis
deployment with an audience-specific key prefix, so replaying a captured
request against another replica is rejected. Readiness fails and signed
internal endpoints return 503 while that store is unavailable.

## Configuration

.NET services:

```text
InternalAuth__RequireSignature=true
InternalAuth__SendLegacySecret=false
InternalAuth__ClockSkewSeconds=300
InternalAuth__NonceRetentionSeconds=900
InternalAuth__MaxBodyBytes=2097152
InternalAuth__RedisKeyPrefix=fakebook:internal-nonce:v1
InternalAuth__RedisOperationTimeoutMilliseconds=1000
ConnectionStrings__SecurityRedis=redis:6379
```

Recommendation (Python):

```text
INTERNAL_AUTH_REQUIRE_SIGNATURE=true
INTERNAL_AUTH_SEND_LEGACY_SECRET=false
INTERNAL_AUTH_CLOCK_SKEW_SECONDS=300
INTERNAL_AUTH_NONCE_RETENTION_SECONDS=900
INTERNAL_AUTH_REDIS_KEY_PREFIX=fakebook:internal-nonce:v1
INTERNAL_AUTH_REDIS_TIMEOUT_SECONDS=1
SECURITY_REDIS_URL=redis://redis:6379/0
```

Bare service runs default to migration-compatible mode
(`RequireSignature=false`, `SendLegacySecret=true`). Both
`docker-compose.yaml` and `scripts/start-local.ps1` enable enforcement for
the whole fleet atomically.

## Covered calls

| Client | Target | Endpoint family |
| --- | --- | --- |
| SocialGraph outbox | Authentication | `/internal/users*` |
| SocialGraph outbox | Search | `/internal/search/indexes/*` |
| SocialGraph outbox | Recommendation | `/internal/recommendation/*` |
| SocialGraph outbox | Messenger | `/internal/users*` |
| SocialGraph outbox | Notification | `/internal/notifications*` |
| SocialGraph outbox | Upload | `/internal/media/*` |
| Search | SocialGraph | `/internal/users/*` |
| Search | Messenger | `/internal/users/*/direct-contact-ids` |
| Messenger | SocialGraph | `/internal/messaging/permissions/check` |
| Messenger | Upload | `/internal/media/*` |
| Recommendation | SocialGraph | `/internal/recommendation/*` |
| Payment | SocialGraph | `/internal/users/*/verify` |

The .NET implementation is copied into each independently built service as
`InternalRequestSigning.cs`. Recommendation uses
`ForFakebook/internal_signing.py`. Cross-language tests assert the two
canonical vectors below, while Upload integration tests assert required
signatures and replay rejection.

## Compatibility vectors

Secret: `test-internal-secret-0123456789ab`

- POST `/internal/users?x=1`, timestamp `1753500000`, nonce
  `0123456789abcdef0123456789abcdef`, body `{"userId":42}`:
  `e0f96895cf6c2f5b4f075e7f6f36902e591d2ce178321550041d45e6c8726512`
- GET `/internal/users/42/friend-ids`, same timestamp, nonce
  `ffffffffffffffffffffffffffffffff`, empty body:
  `3ff404655307935abc5825da27bf6fd4b311b0f2034a23a0d7ebbc012aa430c1`

## Deliberate exclusions

These GraphQL channels are not part of the REST protocol:

- Gateway → subgraphs (`X-Gateway-Secret`, trusted user/session headers)
- Payment → Authentication
- Upload → Authentication session validation

They are constrained to localhost/private Docker networking, use distinct
target secrets, and are not browser-addressable through the edge. Gateway
GraphQL additionally enforces rate, parsing, depth, cycle, planner, execution
timeout/concurrency and batching limits. Extending v1 signing to these channels
requires a separate Fusion/subscription-compatible protocol.
