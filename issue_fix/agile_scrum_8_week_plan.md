# Fakebook – Eight-Week Agile/Scrum Delivery Plan

## Scope and assumptions

This plan covers the ten application repositories below and intentionally excludes `fakebook-workspace`:

- `Backend-Authentication`
- `API-Gateway`
- `Backend-SocialGraph`
- `Backend-Recommendation`
- `Backend-Search`
- `Backend-Messaging`
- `Backend-Notification`
- `Backend-Payment`
- `Upload-Server`
- `Frontend`

The delivery period is eight weeks, divided into four two-week Sprints. Production deployment starts in Week 7. The workspace/deployment repository is not part of the development backlog, but the application repositories must provide deployable images, migrations, configuration requirements, health checks, and release notes for the deployment activity.

## Scrum structure

Each Sprint contains:

- Sprint Planning at the beginning of the two-week period.
- Short regular stand-ups covering completed work, next tasks, blockers, and cross-repository dependencies.
- Backlog refinement during the Sprint.
- Sprint Review using the integrated Fakebook application.
- Sprint Retrospective with one or more improvement actions for the following Sprint.

GitHub Issues are used for individual tasks and defects. Milestones represent the four larger delivery stages. A cross-repository feature is not closed until its backend, Gateway, frontend, database, security, and test work is complete where applicable.

## Dependency order

The main technical dependency chain is:

```text
Authentication
      ↓
API Gateway and trusted identity propagation
      ↓
SocialGraph and Upload
      ↓
Messaging, Notification, Search and Recommendation
      ↓
Payment, full integration and production release
```

Authentication and Gateway work therefore starts first. SocialGraph remains the owner of canonical users, relationships, content, privacy, and block rules. Search and Recommendation consume identifiers and permitted data from SocialGraph instead of becoming independent owners of private content.

## Milestone 1 – Core foundation and identity

### Sprint 1: Weeks 1–2

**Sprint Goal:** Establish a runnable vertical slice with secure authentication, a public GraphQL Gateway, and the initial frontend integration.

| Repository | Planned work | Sprint deliverable |
| --- | --- | --- |
| `Backend-Authentication` | Register, email verification, BCrypt password handling, login, JWT access tokens, refresh-token sessions, logout, validation options, schema/migration checks, unit and contract tests | A user can register, verify, log in, refresh a session, and log out securely. |
| `API-Gateway` | Load and validate the Fusion archive, configure Authentication endpoint and dedicated secrets, validate RS256 tokens, establish correlation IDs, route Authentication operations, add readiness checks | A single `/graphql` entry point validates and routes authentication operations. |
| `Frontend` | Login, registration, verification, logout, session restoration, typed GraphQL client, basic error/loading states | A user can complete the initial account journey through the browser. |
| `Upload-Server` | Confirm JWT/session contract, storage configuration, basic upload validation and health endpoints | An authenticated upload contract is available for the next Sprint. |
| Other repositories | Review API dependencies and create linked GitHub Issues for required contracts | Dependency and integration risks are visible before social feature work begins. |

**Sprint Review evidence:** registration, verification, login, refresh, logout, protected `me` query, Gateway readiness, and a basic frontend flow.

**Sprint 1 exit criteria:** Authentication and Gateway tests pass; the access-token public/private key boundary is documented; runtime configuration and database migration requirements are recorded; no frontend request calls Authentication directly.

## Milestone 2 – Social core and media

### Sprint 2: Weeks 3–4

**Sprint Goal:** Deliver the core social experience with privacy-aware content and media operations.

| Repository | Planned work | Sprint deliverable |
| --- | --- | --- |
| `Backend-SocialGraph` | Profiles, friendship/follow relationships, posts, feed reads, comments, reactions, privacy levels, block visibility, ownership checks, migrations, service tests | Users can create and view permitted social content and interactions. |
| `Upload-Server` | File size/type/extension/magic-byte validation, owner-scoped pending/finalize/delete lifecycle, safe media responses, cleanup worker | Authenticated users can upload and manage owned media safely. |
| `API-Gateway` | Compose SocialGraph schema, forward trusted user/session headers, enforce dedicated subgraph secret, add GraphQL security limits | SocialGraph operations are available only through the protected Gateway. |
| `Frontend` | Feed, profile, friend relationship, post, comment, reaction, privacy, and media UI | The main social workflow works through the browser without direct subgraph calls. |
| `Backend-Authentication` | Support any identity/session contract required by SocialGraph provisioning and deletion | User lifecycle integration remains idempotent and consistent. |

**Sprint Review evidence:** create a post with media, view the feed, edit or delete owned content, add a comment/reaction, manage a friendship, and verify that privacy and block rules affect the result.

**Sprint 2 exit criteria:** privacy, ownership, and both directions of block behavior have negative tests; media cannot be claimed by another user; Gateway schema composition and frontend API types are updated together.

## Milestone 3 – Communication and discovery

### Sprint 3: Weeks 5–6

**Sprint Goal:** Complete real-time communication, notification delivery, search, recommendations, and the cross-service integration required for the production candidate.

| Repository | Planned work | Sprint deliverable |
| --- | --- | --- |
| `Backend-Messaging` | Conversations, membership checks, messages, attachments, reactions/replies, SSE subscriptions, SocialGraph permission calls, outbox processing, idempotency and security tests | Users can use authorised direct/group messaging with real-time updates. |
| `Backend-Notification` | Notification persistence, receiver-scoped queries, cursor pagination, read state, idempotency, delivery worker, SSE integration | Users receive and manage their own notifications in real time. |
| `Backend-Search` | Index upsert/delete APIs, token normalisation, prefix search, bounded pagination, ranking impressions, signed internal calls, migration tests | Users can search permitted users, groups, posts, and reels. |
| `Backend-Recommendation` | User/content embeddings, bounded media processing, interaction ledger, ranking, SocialGraph candidate filtering, resilient internal APIs, pytest coverage | The system returns bounded recommendations based on authorised candidates. |
| `API-Gateway` | Compose Messaging, Notification, Search, and Recommendation schemas; configure timeouts, secrets, subscriptions, and rate limits | All discovery and communication operations use one protected GraphQL entry point. |
| `Frontend` | Messenger, notification, search, recommendation, subscription reconnect and error handling | Communication and discovery features are usable from the frontend. |
| `Backend-Payment` | Implement or verify plan/order schema, authentication and SocialGraph contracts, provider abstraction, webhook verification tests, and disabled-by-default production configuration | Payment is integration-ready without enabling unverified provider credentials. |

**Sprint Review evidence:** send a message, receive a notification, reconnect an SSE stream, search indexed content, view recommendations, verify privacy filtering, and run payment tests with provider credentials disabled or mocked.

**Sprint 3 exit criteria:** signed internal requests and replay protection are covered; unsafe methods are not automatically retried; outbox operations are idempotent; search and recommendation never bypass SocialGraph visibility rules; frontend subscription errors terminate or reconnect safely.

## Milestone 4 – Production deployment and release

### Sprint 4: Weeks 7–8

**Sprint Goal:** Begin production deployment in Week 7, validate the integrated platform, and complete a stable component release in Week 8.

### Week 7 – Production deployment begins

| Repository | Planned work | Production activity |
| --- | --- | --- |
| All backend repositories | Freeze the production candidate, build release images, verify migrations, review environment variables and health checks, resolve release-blocking defects | Deploy services progressively in dependency order, beginning with database-dependent services and Authentication, then Gateway and user-facing services. |
| `Backend-Authentication` | Verify production JWT public/private key separation, session expiry, refresh-cookie settings, SMTP configuration, database role and readiness behavior | Validate registration/login/refresh/logout against the production-like database. |
| `API-Gateway` | Verify Fusion archive, subgraph URLs, dedicated secrets, trusted proxy networks, rate limits, body limits, CORS and webhook routing | Expose only the Gateway/approved edge paths and perform authenticated smoke tests. |
| `Backend-SocialGraph` and `Upload-Server` | Verify schema, media storage, ownership checks, cleanup, privacy and block behavior | Test content and media flows with production storage and service credentials. |
| `Backend-Messaging`, `Backend-Notification`, `Backend-Search`, `Backend-Recommendation` | Verify workers, indexes, signed internal calls, Redis dependencies, timeouts and readiness endpoints | Execute communication, notification, search, and recommendation smoke tests. |
| `Backend-Payment` | Keep real payment activation disabled until provider credentials and webhook routing are verified | Run provider-independent tests and verify that invalid webhooks fail safely. |
| `Frontend` | Build the production bundle, verify public Gateway/Upload URLs, authentication persistence, SSE reconnect behavior and media handling | Perform browser smoke tests through the production edge. |

**Week 7 deployment gates:** all required containers are healthy; database migrations are applied before normal traffic; secrets are present and distinct; Gateway GraphQL, upload, health, and SSE paths work; no service is exposed directly as a browser API; rollback versions are recorded.

### Week 8 – Stabilisation and final release

**Sprint Goal:** Operate the production candidate, resolve observed defects, and publish stable component releases.

Planned work:

- Run full smoke tests for authentication, social content, media, messaging, notifications, search, recommendations, and Gateway routing.
- Review application errors, latency, readiness failures, failed outbox rows, database performance, and Redis behavior.
- Use OpenTelemetry traces and service metrics to investigate cross-service failures and slow requests.
- Apply only reviewed and prioritised hotfixes; rerun the affected unit, integration, API, security, and frontend tests.
- Verify backup/restore and migration rollback procedures where applicable.
- Record known limitations, disabled payment behavior, operational runbooks, and production configuration notes.
- Create component-level GitHub Releases and version tags for the verified services, frontend, and deployment artifact references.

**Sprint 4 exit criteria:** the production candidate has passed end-to-end smoke tests, release-blocking incidents are resolved or documented, observability is usable, rollback information is available, and the final component versions are published.

## Weekly delivery view

| Week | Sprint focus | Main repository groups | Primary output |
| --- | --- | --- | --- |
| 1 | Identity foundation | Authentication, API-Gateway, Frontend | Secure account and Gateway skeleton |
| 2 | Identity integration | Authentication, API-Gateway, Frontend, Upload-Server | Working login/session vertical slice |
| 3 | Social and media implementation | SocialGraph, Upload-Server, Frontend | Posts, feed, relationships, media |
| 4 | Social integration and security | SocialGraph, API-Gateway, Frontend, Authentication | Privacy-aware social increment |
| 5 | Communication and discovery | Messaging, Notification, Search, Recommendation | Service implementations and contracts |
| 6 | Cross-service quality | All application repositories | Production candidate and integration tests |
| 7 | Production deployment begins | All application repositories | Progressive production rollout and smoke tests |
| 8 | Stabilisation and releases | All application repositories | Observability review, hotfixes, final releases |

## Definition of Done for this eight-week plan

A task is complete only when the relevant code is implemented, the owning repository builds, the associated tests pass, required migrations and configuration are included, security and privacy checks are covered, dependent contracts are updated, and the feature is demonstrated through the Gateway or approved Upload path. A production task additionally requires a health check, a rollback reference, a smoke test, and monitoring evidence.
