# Báo cáo bảo mật hệ thống Fakebook

**Ngày chốt kiểm tra:** 27/07/2026

**Phạm vi:** workspace điều phối, Gateway, 7 subgraph, Upload Server, Recommendation Python và frontend
**Mục tiêu:** hoàn tất giai đoạn 3 đang dở, kiểm tra lại hai giai đoạn Claude Code đã push, và tạo một mốc đủ rõ để nhóm quay lại tập trung frontend.

> File này mô tả trạng thái mã nguồn và môi trường Fakebook hiện tại. Không đưa secret,
> JWT key, mật khẩu hay connection string thật vào báo cáo.

## 1. Kết luận

Tám mục của giai đoạn 3 đã hoàn tất. Các thay đổi quan trọng nhất:

- mỗi service có PostgreSQL login riêng, chỉ có quyền dữ liệu trong schema của mình;
- toàn bộ đường đọc/ghi SocialGraph liên quan block, tag, mention, comment và danh sách người dùng dùng chung một lớp kiểm tra block hai chiều;
- đăng ký user không còn để lại tài khoản ma khi Auth thất bại;
- nonce chống replay được lưu atomically trong Redis dùng chung và fail-closed;
- session có thời hạn tuyệt đối 90 ngày;
- JWT chuyển sang RS256, chỉ Auth giữ private key;
- 8 ứng dụng .NET có OpenTelemetry và HTTP resilience an toàn;
- toàn bộ project .NET đã chuyển lên .NET 10.

Frontend không bị thay đổi giao diện. Phần frontend của đợt này chỉ nâng toolchain lint để
loại dependency có CVE và sửa hai chi tiết nội bộ không đổi hành vi, DOM hay CSS.

Hệ thống đã chạy đầy đủ ở host mode và mọi readiness/smoke check đều qua. Có thể quay lại
tập trung UI. Các giới hạn vận hành còn lại được ghi minh bạch ở mục 8.

## 2. Đối chiếu giai đoạn 3

| # | Hạng mục | Trạng thái | Bằng chứng chính |
| ---: | --- | --- | --- |
| 1 | Tách role DB | ✅ Hoàn tất cả code và DB đang dùng | 7 role runtime đăng nhập được, không superuser/createdb/createrole/inherit/bypassrls, không có quyền chéo schema; mật khẩu owner đã rotate |
| 2 | Vá #9 block ở đường đọc/ghi còn lại | ✅ Hoàn tất | BlockVisibilityService, 7 regression test, lọc group member/admin, like/tag/mention/story viewer/comment author và validate lúc ghi |
| 3 | Half-commit đăng ký/tài khoản ma | ✅ Hoàn tất | Auth là cổng bắt buộc; projection chỉ chạy sau Auth; lỗi Auth terminal sẽ compensate user SocialGraph |
| 4 | Nonce sang Redis + fail-closed | ✅ Hoàn tất | Redis SET NX EX, key theo audience, readiness check, lỗi Redis trả 503; .NET/Python và cross-validator test |
| 5 | Thời hạn tuyệt đối cho phiên | ✅ Hoàn tất | absolute_expires_at, mặc định 90 ngày; refresh/cookie bị chặn bởi deadline tuyệt đối |
| 6 | JWT RS256 | ✅ Hoàn tất | PKCS#8 private key ở Auth, SPKI public key ở Gateway/Upload, kiểm tra alg và kid; HS256 chỉ còn tùy chọn migration |
| 7 | OpenTelemetry + Polly | ✅ Hoàn tất | trace/metrics cho ASP.NET, HttpClient, runtime; OTLP optional; retry chỉ cho method an toàn |
| 8 | .NET 10 | ✅ Hoàn tất | toàn bộ 17 project target net10.0, Docker/CI/global.json dùng .NET 10 |

### 2.1. Lưu ý về hạn .NET

Mốc **10/11/2026** là ngày .NET 8 hết hỗ trợ, không phải hạn của .NET 10. .NET 10 là bản
LTS và được hỗ trợ tới **14/11/2028** theo lifecycle chính thức của Microsoft:
<https://learn.microsoft.com/en-ie/lifecycle/products/microsoft-net-and-net-core>.

## 3. Chi tiết triển khai

### 3.1. PostgreSQL least privilege

| Service | Role | Schema |
| --- | --- | --- |
| Authentication | fakebook_auth | auth |
| SocialGraph | fakebook_social_graph | social_graph |
| Recommendation | fakebook_recommendation | recommendation + USAGE public để dùng pgvector |
| Search | fakebook_search | search |
| Notification | fakebook_notification | notification |
| Messenger | fakebook_messenger | messenger |
| Payment | fakebook_payment | payment |

Runtime role chỉ có CRUD/sequence cần thiết trong schema sở hữu, không được CREATE schema
và không có quyền bảng/sequence chéo schema. Compose và host launcher không truyền
DB_USER/DB_PASSWORD của owner vào service nữa. DDL lúc startup đã tắt; migration chạy bằng
owner trong maintenance window.

~~~powershell
.\scripts\provision-database-roles.ps1 -WritersStopped -InitializeCredentials
.\scripts\rotate-database-owner-password.ps1 -WritersStopped
~~~

Lần kiểm tra live gần nhất:

- fingerprint DB: 45F140B053B7;
- cả 7 role: Success=true;
- missing own-table/sequence privileges: 0;
- cross-schema table/sequence privileges: 0;
- public không có USAGE công khai.

Role owner fakebook có OID 10, tức bootstrap superuser của cluster. PostgreSQL không cho
bootstrap superuser tự bỏ quyền superuser. Vì vậy role này vẫn là migration owner, nhưng
credential đã được rotate thành secret ngẫu nhiên 32 byte, nằm trong .env gitignored và
không được đưa vào runtime container. Đây là giới hạn của cluster hiện tại, không phải
runtime service còn chạy bằng superuser.

### 3.2. Visibility/block kernel của SocialGraph

BlockVisibilityService định nghĩa block hai chiều: nếu A chặn B hoặc B chặn A thì quan hệ
hiển thị/tương tác giữa hai người bị loại. Kernel này được dùng khi:

- tạo/cập nhật post, reel, comment, tag và mention;
- đọc feed, group, reel và share source;
- hydrate liked/tagged/mentioned users;
- đọc group member/admin, story viewer và comment author;
- tạo notification/projection liên quan user.

Block không bị privacy, friendship, follow, tag hay mention ghi đè. Tag/mention không cấp
quyền đọc nội dung.

### 3.3. Đăng ký không còn half-commit

Luồng đăng ký mới:

1. SocialGraph dựng canonical user/profile và outbox.
2. UserProvisioningCoordinator gọi Auth trước.
3. Chỉ khi Auth thành công mới dispatch Search, Recommendation, Messenger và projection còn lại.
4. Projection là idempotent và có retry/dead-letter.
5. Nếu Auth thất bại terminal, coordinator xóa/compensate canonical user thay vì để lại profile không đăng nhập được.
6. Auth coi request lặp đúng cặp userId/email là idempotent; không băm BCrypt lại.

### 3.4. Anti-replay dùng Redis

Protocol HMAC vẫn ký method, path/query, timestamp, nonce và SHA-256 body. Thay đổi:

- tất cả validator dùng Redis atomic SET với NX và EX;
- key có audience/prefix để cô lập target;
- replay vào replica khác vẫn bị từ chối;
- thiếu Redis khi enforcement bật làm readiness fail và endpoint trả 503;
- không có fallback in-memory hoặc fail-open;
- managed Compose/host đặt RequireSignature=true, SendLegacySecret=false.

Chi tiết wire format: [docs/internal-request-signing.md](docs/internal-request-signing.md).

### 3.5. Session tuyệt đối

Migration 20260727_add_absolute_session_expiry.sql thêm absolute_expires_at.

- deadline mặc định: 90 ngày từ khi tạo session;
- sliding refresh không thể kéo session qua deadline;
- expiry token/cookie dùng giá trị nhỏ nhất giữa sliding và absolute expiry;
- schema, model, repository và config đã đồng bộ;
- migration đã áp dụng vào DB hiện tại mà không reset dữ liệu.

### 3.6. JWT RS256

- Auth ký bằng RSA private key PKCS#8 tối thiểu 2048 bit.
- Gateway và Upload chỉ nhận public key SPKI.
- Token có kid; validator khóa thuật toán ở RS256.
- Auth tạo và validate token bằng System.IdentityModel.Tokens.Jwt thay vì tự ghép/parse JWT.
- Validator giới hạn kích thước token, issuer, audience, lifetime, key type, thuật toán và kid.
- JWT_LEGACY_SIGNING_KEY chỉ dùng cho cửa sổ chuyển đổi token HS256 cũ và hiện để trống.
- Script khởi tạo tạo cặp key đồng bộ và không in key ra terminal.

Việc tách private/public key loại bỏ khả năng một verifier bị compromise có thể tự ký access
token mới.

### 3.7. OpenTelemetry và resilience

Tám ứng dụng .NET có cùng service defaults:

- ASP.NET Core, outgoing HttpClient và runtime metrics/traces;
- OTLP exporter chỉ bật khi có endpoint;
- sample ratio mặc định 10%;
- không capture body, GraphQL variables, auth header hay secret;
- health endpoint bị loại khỏi trace noise.

HttpClient dùng Microsoft.Extensions.Http.Resilience (Polly bên dưới). Retry bị vô hiệu cho
POST/PUT/PATCH/DELETE/CONNECT để tránh nhân đôi mutation; GET/HEAD/OPTIONS mới được retry.
Recommendation Python áp dụng cùng quy tắc.

Collector Compose được pin image digest. Cấu hình dev xuất trace dạng debug và metrics
Prometheus; production có thể thay exporter mà không sửa service.

### 3.8. .NET 10

- 17 project target net10.0;
- SDK local/global: 10.0.302; runtime kiểm tra: 10.0.10;
- Docker SDK/runtime và GitHub Actions dùng major 10;
- EF Core, TestHost/MvcTesting, OpenAPI, Npgsql và package framework đã cùng major;
- Swashbuckle đã chuyển sang API v10.

## 4. Đối chiếu 16 finding ban đầu

| # | Finding | Mức ban đầu | Kết quả hiện tại |
| ---: | --- | --- | --- |
| 1 | User xoá media của người khác | High | ✅ ownership + parent reference validation |
| 2 | Bypass refresh-token filter Gateway | Medium | ✅ field internal + scrub response/cookie scope |
| 3 | Reel private/story bỏ qua block | Medium | ✅ privacy và block kiểm tra tại read time |
| 4 | Rate limiter IP thành global bucket | Medium | ✅ partition theo IP/user đúng |
| 5 | Khoá tài khoản nạn nhân từ xa | Medium | ✅ failure counter chỉ cập nhật ở credential path phù hợp |
| 6 | Account enumeration login/resend | Medium | ✅ response/timing/status được đồng nhất |
| 7 | Mọi service dùng chung DB superuser yếu | Medium | ✅ 7 role runtime + rotate owner; xem ngoại lệ bootstrap ở mục 3.1 |
| 8 | Session revoke không cắt SSE | Medium | ✅ Gateway revalidate session khi stream mở |
| 9 | Block thiếu ở tag/mention/list/comment | Medium | ✅ kernel block tập trung + regression tests |
| 10 | Refresh cookie gửi tới Upload | Low | ✅ cookie path hẹp |
| 11 | HS256 key dùng chung Auth/Gateway/Upload | Low | ✅ RS256 private/public split |
| 12 | Nonce RAM và signature không fail-closed | Low | ✅ Redis atomic + readiness/503 |
| 13 | BCrypt CPU exhaustion | Low | ✅ concurrency 2, queue 16, timeout 5s, work factor 10–14 |
| 14 | Identifier tùy ý vào audit log | Low | ✅ normalize/limit + retention worker |
| 15 | Session không có absolute lifetime | Low | ✅ absolute_expires_at 90 ngày |
| 16 | Edge thiếu security headers | Low | ✅ nosniff/frame/referrer/permissions/HSTS phù hợp |

## 5. Finding bổ sung đã kiểm tra

### 5.1. Recommendation SSRF — đã vá

Media embedding fetch chỉ cho host/port allowlist chính xác, resolve DNS rồi chặn dải nguy
hiểm, tắt redirect, giới hạn bytes/time và tải video vào file tạm có giới hạn trước khi decode.

### 5.2. GraphQL amplification — đã vá

Gateway enforce max execution depth, field-cycle depth, parser fields/nodes/tokens, planner
expanded nodes, execution timeout/concurrency và rate limit. HTTP batching/multipart
GraphQL bị tắt. Nhận xét cũ “có cost directive nhưng chưa enforcement” không còn đúng.

### 5.3. Upload chỉ scan 8 KB — nhận xét cũ không còn đúng

8 KB đầu chỉ dùng kiểm tra magic header. Active-content audit đọc toàn bộ stream theo chunk
64 KB, giữ overlap để bắt signature vắt qua biên và chạy trước khi publish. Test đặt marker
sau cửa sổ 8 KB cũ và ngay qua biên 64 KB đã pass. Upload có size cap và nosniff.

### 5.4. BCrypt — đã giới hạn đúng

Mọi hash/verify đi qua singleton BCryptPasswordHasher. ConcurrencyLimiter giữ lease tới khi
BCrypt synchronous thực sự kết thúc; timeout chỉ áp dụng lúc chờ queue, không thả permit
sớm khi CPU work còn chạy. Work factor do server cấu hình và validate 10–14.

### 5.5. Dependency và supply-chain

- NuGet: không có package vulnerable trong 8 app .NET và maintenance tool.
- Python: pip-audit không tìm thấy CVE trong requirements.
- npm: 0 vulnerability sau khi nâng ESLint toolchain; UI/CSS không đổi.
- Redis và OpenTelemetry Collector image được pin digest.
- Secret scan không thấy giá trị thật trong file repository.

### 5.6. Sổ kiểm kê đầy đủ các bản vá bảo mật và hardening

Bảng này bổ sung những thay đổi trước đây chỉ được nhắc gián tiếp. Nó được đối chiếu với
lịch sử Git ngày 26–27/07/2026. Cột “Loại” phân biệt lỗ hổng trực tiếp với hardening
availability/defense-in-depth để báo cáo không đánh đồng mọi tối ưu hiệu năng thành CVE.

| Biên/service | Vấn đề hoặc rủi ro đã xử lý | Loại | Bằng chứng đại diện |
| --- | --- | --- | --- |
| Gateway edge | Browser có thể tự gửi X-User-Id/X-Session-Id/internal headers | Vulnerability | strip toàn bộ trusted header trước auth; 9565eec |
| Gateway edge | JWT hợp lệ nhưng session đã revoke vẫn dùng được | Vulnerability | live Auth session validation và watchdog SSE; 16bdd46 |
| Gateway edge | Một rate-limit bucket toàn cục và client IP không chính xác sau proxy | Vulnerability | partition đúng caller/IP, forwarded address server-owned; 2022c91 |
| Gateway GraphQL | Query sâu/rộng/cycle/planner expansion và batching gây amplification | Vulnerability/DoS | parser/depth/cycle/planner/concurrency/timeout limits; 05c729d |
| Gateway GraphQL | Raw refresh token lọt qua composed response | Vulnerability | field internal, response scrub và cookie instruction; c269496 |
| Browser cookie | Refresh cookie bị gửi tới /media và path không đồng bộ | Vulnerability | cookie path chỉ /graphql; e0f7505, 0bf6bc1 |
| PayOS webhook | Body lớn, spoofed browser context hoặc thay đổi bytes khi proxy | Vulnerability | JSON/body cap, IP rate-limit, exact bytes, không forward cookie/auth/trusted header; 08a0c76 |
| Edge headers | Clickjacking, MIME sniffing và thiếu transport/browser policy | Defense-in-depth | frame/nosniff/referrer/permissions/HSTS; workspace phase 1/2 |
| Secret isolation | Một shared-secret fallback làm compromise một service lan cả fleet | Vulnerability | secret riêng từng subgraph/REST target, Production/env validation chặn trùng/fallback; 9565eec, 0716985 |
| Internal REST | Raw secret trên wire, không body integrity và replay được | Vulnerability | HMAC canonical request, timestamp, body hash, Redis nonce NX/EX; các commit HMAC + phase 3 |
| Internal REST | Replay sang replica khác hoặc Redis chết nhưng request vẫn qua | Vulnerability | shared nonce store, readiness unhealthy, trả 503 fail-closed; 1233b98/dc8a482/1a40cd4/dfed7e7/06c95ea/00f9816/ecc94e3 |
| Authentication | Flood register/login tạo BCrypt task không giới hạn | DoS | concurrency 2, queue 16, timeout lúc chờ, permit giữ tới khi CPU work kết thúc; 8c55807 |
| Authentication | Login/resend phân biệt account tồn tại/trạng thái | Vulnerability | response/timing/status đồng nhất và dummy verify; 9998529 |
| Authentication | Khoá tài khoản nạn nhân bằng failure counter từ xa | Vulnerability | chỉ tăng counter ở credential path hợp lệ; 9998529 |
| Authentication | OTP/login/password endpoint bị brute-force | Vulnerability | per-account/window limits, cooldown, audit indexes; dddd517/b9e1343/1f20723 |
| Authentication | Identifier tùy ý làm phình/log-injection audit | Vulnerability | normalize/bound identifier và retention theo batch; 9998529/9d297cd |
| Authentication | Refresh token cũ bị tái sử dụng | Vulnerability | rotate, hash at rest, compromise flow revoke; 2ab0757 |
| Authentication | Sliding session sống vô hạn | Vulnerability | absolute_expires_at 90 ngày; 4ffbfcd |
| JWT | HS256 cho verifier quyền tự ký và parser JWT tự viết | Vulnerability/defense-in-depth | RS256 private/public split, kid/alg khóa chặt, IdentityModel chuẩn; 4ffbfcd/cac3c9c |
| SocialGraph | Media URL của user khác được gắn rồi xoá qua cascade | Vulnerability | authorize owner trước persist, delete khi parent cuối mất; cbd6484/9cb4758 |
| SocialGraph | Story/reel/share source bỏ privacy hoặc block | Vulnerability | privacy read-time và block hai chiều; 65b0667/0860f13 |
| SocialGraph | Tag/mention/list/comment/group member/story viewer bỏ block | Vulnerability | BlockVisibilityService và regression matrix; 00f9816 |
| SocialGraph | Đăng ký lỗi để lại profile không có Auth identity | Integrity | Auth-first saga, idempotent projections, compensation; 00f9816 |
| SocialGraph outbox | Credential/password trong outbox plaintext hoặc retry vô hạn | Vulnerability/availability | payload protector, bounded attempts, dead-letter, lỗi permanent/retryable |
| SocialGraph runtime | Xoá user/query hydrate/cache có thể giữ lock hoặc dùng tài nguyên không giới hạn | Availability | bounded delete batches, batched hydration, cache cap/expiry/rollback invalidation; 74a70a3/ea91e7a/709e0c9 |
| Upload | Chỉ tin JWT mà không kiểm tra session hiện tại | Vulnerability | gọi Auth me/session contract; e6ae7ca |
| Upload | Path traversal, giả extension/MIME/magic, active payload sau 8 KB | Vulnerability | safe leaf/GUID name, allowlist, magic, full-stream overlapping scan; d8b0d9e/ecc94e3 |
| Upload | Upload flood và file/request không giới hạn | DoS | per-user/edge rate-limit, file count/body/image/video caps; d8b0d9e |
| Upload lifecycle | Finalize/delete asset không kiểm tra owner | Vulnerability | owner-scoped internal lifecycle và parent authorization; 9cb4758 |
| Upload response | Browser sniff active content | Defense-in-depth | X-Content-Type-Options nosniff; ecc94e3 |
| Recommendation | User media URL ép worker gọi metadata/internal/private host | High/SSRF | exact allowlist, DNS/IP guard, no redirect, stream/time caps, bounded temp decode; 046f5fa |
| Recommendation | Retry POST có thể nhân đôi interaction/mutation | Integrity | retry chỉ GET/HEAD/OPTIONS; dfed7e7 |
| Messenger | Browser spoof trusted identity | Vulnerability | GatewayTrustMiddleware và ITrustedUserContextAccessor; fb6e83f |
| Messenger outbox | Giữ DB lock khi gọi mạng và retry vô hạn | Availability | release lock trước dispatch, bounded retry/dead-letter; 103a5b7 |
| Realtime frontend | Subscription reconnect storm khi Gateway từ chối | Availability/DoS | dừng reconnect khi auth/session rejected; ad1af47 |
| Realtime frontend | Nhiều chat tạo nhiều stream không cần thiết | Availability | một subscription theo dõi nhiều conversation, đóng stream khi dock ẩn; 94133ed/722f5c6/f9d2873 |
| Notification | Bảng delivered tăng vô hạn | Availability/data retention | retention theo thời hạn; 5b065ff |
| PostgreSQL | Mọi service dùng migration superuser/mật khẩu yếu | Vulnerability | 7 role schema-scoped, cross-schema denial, owner password rotate; 0716985 |
| Runtime container | Một số service chạy root và health không chờ dependency | Defense-in-depth/availability | non-root user, readiness/dependency ordering; b75669c |
| Supply chain | Floating framework/Python/tool/image versions | Defense-in-depth | package/image digest pins, NuGet/pip/npm audit, checksum tool bootstrap |
| Telemetry | Retry/trace vô tình log body/token hoặc nhân đôi unsafe mutation | Defense-in-depth/integrity | body/header redaction policy, safe-method retry, OTLP optional; phase 3 |

### 5.7. Guardrail cho API do agent mới viết

Đã thêm ba tầng để quy tắc trên không chỉ nằm trong báo cáo:

1. AGENTS.md và CLAUDE.md là điểm vào tự động cho Codex/Claude Code; mỗi repository
   service/frontend cũng có AGENTS.md riêng để rule vẫn được nạp khi clone standalone.
2. docs/api-security-contract.md định nghĩa trust boundary, identity accessor, internal
   signing, privacy/block, outbox, DB, upload, SSRF, telemetry và test bắt buộc.
3. scripts/check-api-security-contracts.ps1 được gọi trong test-all và chặn drift của:
   - 7 bản InternalRequestSigning .NET;
   - Redis nonce fail-closed và managed Compose enforcement;
   - JWT private/public split và Auth IdentityModel validator;
   - Gateway trusted-header stripping cùng GraphQL resource limits;
   - BCrypt isolation;
   - safe-method retry;
   - SocialGraph block/saga/outbox protection;
   - Upload full scan;
   - Recommendation SSRF guard;
   - DB migration-owner leakage vào runtime.

Guard script chứng minh các control cấu trúc vẫn tồn tại, nhưng không thể chứng minh mọi
business rule mới là đúng. API mới vẫn phải có negative authorization/privacy/ownership
tests và review data flow trước merge.

## 6. Kiểm chứng

### 6.1. Test tự động

| Thành phần | Kết quả |
| --- | ---: |
| Authentication | 35/35 |
| SocialGraph | 221/221 |
| Search | 34/34 |
| Notification | 29/29 |
| Messenger | 61/61 |
| Payment unit | 35/35 |
| Upload | 19/19 |
| Gateway | 35/35 |
| Recommendation Python | 54/54 |
| Frontend Vitest | 293/293 |
| Frontend build/lint | pass |
| API security contract guard | pass |
| Compose standalone validation | pass |

Tổng: **523 backend/Python test + 293 frontend test = 816 test pass**.

### 6.2. Full-stack smoke

Host launcher đã chạy đồng thời security cache; Auth 1001, Social 1002, Recommendation
1003, Search 1004, Notification 1005, Messenger 1006, Payment 1007, Gateway 2001,
Frontend 3001 và Upload 4001. Readiness từng service, Gateway GraphQL, Search/Gateway,
frontend/upload và kiểm tra Messenger từ chối request không trusted đều pass. Stack đã
được stop sạch sau test.

### 6.3. Database invariant

~~~text
invalidAssociations       0
orphanMedia               0
adminsWithoutMembership   0
duplicateDirectPairs      0
deadLetters              18
~~~

18 dead-letter là dữ liệu vận hành cũ từ 19–21/07/2026: projection content rỗng và
recommendation interaction trỏ target chưa có embedding. Code mới coi projection rỗng là
delete idempotent để không tạo thêm lỗi cùng loại. Không tự ý xoá/rewrite 18 record lịch sử
trong đợt bảo mật; chúng không phải lỗ hổng, nhưng cần reconciliation riêng nếu muốn
dashboard sạch tuyệt đối.

Payment Testcontainers chưa chạy trên workstation vì không có Docker daemon. Unit test,
host full-stack smoke và docker-compose config vẫn pass; CI có Docker cần tiếp tục chạy
suite integration này.

## 7. Thay đổi dữ liệu và secret

Đợt này không reset bảng, không xoá user/post/message/media và không đổi schema nghiệp vụ
ngoài trường session tuyệt đối.

Các thay đổi có chủ đích:

1. thêm auth.id_session.absolute_expires_at;
2. tạo/đồng bộ 7 runtime role least-privilege;
3. rotate password migration owner;
4. tạo cặp JWT RSA và kid;
5. thêm credential role runtime vào .env;
6. dùng Redis/Garnet cho nonce.

Tất cả secret nằm trong .env gitignored, không được in trong log và không xuất hiện trong
Git diff.

## 8. Rủi ro chấp nhận và việc vận hành còn lại

Không có mục nào trong 8 việc giai đoạn 3 còn chờ code. Các điểm sau là ranh giới kiến trúc
hoặc vận hành:

1. **Bootstrap DB owner vẫn là superuser:** PostgreSQL không cho OID 10 tự demote. Giữ role
   offline cho migration, không truyền credential vào runtime. Muốn bỏ hoàn toàn cần một
   DBA/cluster admin khác tạo migration owner mới.
2. **Internal HTTP:** TLS terminate ở Tailscale edge và host-to-host được tailnet mã hóa.
   HMAC bảo vệ integrity/replay. mTLS từng service là milestone riêng nếu threat model đổi.
3. **CSP:** chưa ép CSP nghiêm vì media/blob/dynamic asset có thể vỡ frontend. Các header
   còn lại đã bật; CSP nên rollout report-only trước.
4. **Legacy JWT verifier:** code còn hỗ trợ HS256 để rollback, nhưng môi trường để legacy
   key rỗng. Có thể xóa nhánh sau khi chắc chắn token cũ hết hạn.
5. **OTel production backend:** collector dev đã có; production cần chọn exporter/storage
   và retention.
6. **18 dead-letter lịch sử:** cần quyết định retry/discard theo nghiệp vụ, không xóa mù
   trong security rollout.

## 9. Đối chiếu commit Claude Code và mốc phát hành

Đã kiểm tra history trước khi tiếp tục. Workspace phase 1/2 có các mốc đại diện:

- 582ce91: báo cáo security/orchestration ban đầu;
- 4b5862d: post-review fixes;
- b75669c: readiness và không chạy container root;
- 00e6e94, 8292b15: refresh manifest;
- b99c7c1: migration runner;
- 7ad69f2: bản đầu script per-service DB role.

Các repo service cũng đã có commit riêng cho media ownership, story privacy/block,
Gateway refresh hardening, enumeration/identifier, SSE session watchdog, retention,
indexing và CI. Giai đoạn 3 tiếp nối các mốc đó, không revert chúng.

Commit mới nhất của phase 3 và guardrail đã kiểm chứng:

| Repo | Commit |
| --- | --- |
| Gateway | 644746c |
| Authentication | cac3c9c |
| Frontend | a9b0170 |
| Messenger | 8392f0f |
| Notification | 55ba737 |
| Payment | 020aae1 |
| Recommendation | 51d607a |
| Search | 08cd571 |
| SocialGraph | 532d2a4 |
| Upload | 6e9ef5e |

services.manifest.json là danh sách commit canonical sau vòng verify cuối:

~~~powershell
.\scripts\update-manifest.ps1
~~~

## 10. Lệnh kiểm tra lại

~~~powershell
# Toàn bộ test/build/lint/config
.\scripts\test-all.ps1

# Chạy đủ service và smoke
.\scripts\start-local.ps1
.\scripts\smoke-local.ps1
.\scripts\stop-local.ps1

# Kiểm tra role DB, không in password
$dotnet = & .\scripts\resolve-dotnet.ps1
& $dotnet run --project .\scripts\Fakebook.Maintenance -- verify-service-roles --env-file .\.env --json

# Kiểm tra secret/encoding
.\scripts\check-secrets.ps1
.\scripts\check-encoding.ps1
~~~

---

**Verdict:** phase 3 đã hoàn tất về code, migration, cấu hình và kiểm chứng. Backend đủ ổn
để chuyển trọng tâm sang frontend, với các ngoại lệ vận hành ở mục 8 được theo dõi riêng.
