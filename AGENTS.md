# Instructions for coding agents

These instructions apply to the entire Fakebook workspace and every nested service repo.

Before changing an API, read in this order:

1. README.md for topology and canonical behavior.
2. docs/api-security-contract.md for mandatory trust and test rules.
3. secure.md for fixed findings, accepted risks and verification evidence.
4. The relevant service schema/plan/AGENT documentation.

Do not weaken authentication, authorization, privacy, block, media ownership, rate limits,
request signing, replay protection, database role isolation or negative tests to make a
feature work.

Do not add a browser-to-service shortcut. Browser application traffic uses Gateway
GraphQL; authenticated multipart upload uses Upload Server. Derive the caller from the
service's trusted accessor, never from an input userId.

Reuse the established policy/signing/outbox/resilience components. Do not implement a
parallel security convention in one resolver or service.

Do not change frontend appearance unless the user explicitly requests UI changes.

Before handing off an API change run:

~~~powershell
.\scripts\check-api-security-contracts.ps1
.\scripts\test-all.ps1
~~~

State any skipped infrastructure test explicitly. Never claim an unavailable Docker,
external provider or production check passed.
