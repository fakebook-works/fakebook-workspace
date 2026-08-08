# Fakebook — tài liệu hiểu toàn bộ kiến trúc, API và bảo mật

> Mục đích của tài liệu này là giúp một người mới hiểu Fakebook bằng cách đọc một file duy nhất, thay vì phải lần lượt đọc toàn bộ source của từng service.
>
> Tài liệu mô tả logic hiện có trong workspace. Khi code thay đổi, source code và các security contract trong docs/ vẫn là nguồn sự thật cuối cùng.

## Mục lục

1. [Tóm tắt trong một phút](#1-tóm-tắt-trong-một-phút)
2. [Topology của hệ thống](#2-topology-của-hệ-thống)
3. [Một API trong Fakebook gồm những gì](#3-một-api-trong-fakebook-gồm-những-gì)
4. [Authentication, session và trusted identity](#4-authentication-session-và-trusted-identity)
5. [Authorization và luật bảo mật dữ liệu](#5-authorization-và-luật-bảo-mật-dữ-liệu)
6. [Chữ ký gọi service nội bộ](#6-chữ-ký-gọi-service-nội-bộ)
7. [Database, Redis, transaction và outbox](#7-database-redis-transaction-và-outbox)
8. [Giải thích từng service](#8-giải-thích-từng-service)
9. [Các luồng nghiệp vụ từ đầu đến cuối](#9-các-luồng-nghiệp-vụ-từ-đầu-đến-cuối)
10. [Frontend giao tiếp với backend](#10-frontend-giao-tiếp-với-backend)
11. [Realtime bằng GraphQL-over-SSE](#11-realtime-bằng-graphql-over-sse)
12. [Triển khai và vận hành](#12-triển-khai-và-vận-hành)
13. [Các lỗi thiết kế dễ mắc phải](#13-các-lỗi-thiết-kế-dễ-mắc-phải)
14. [Checklist khi thêm hoặc sửa API](#14-checklist-khi-thêm-hoặc-sửa-api)
15. [Bản đồ source code](#15-bản-đồ-source-code)
16. [Từ điển thuật ngữ](#16-từ-điển-thuật-ngữ)

---

## 1. Tóm tắt trong một phút

Fakebook là một ứng dụng mạng xã hội được tách thành nhiều service. Tuy nhiên browser không nhìn thấy toàn bộ hệ thống đó. Đối với browser, hệ thống chỉ có ba cửa vào hợp lệ:

~~~text
Browser
  ├── /graphql              → API Gateway
  ├── /media/*              → Upload Server
  └── /api/webhooks/payos   → Payment webhook qua Gateway
~~~

Nguyên tắc quan trọng nhất của toàn dự án là:

> Người đang thao tác không được lấy từ userId do client gửi lên. Người đó phải được suy ra từ token/session đã xác thực và trusted context do Gateway hoặc middleware nội bộ tạo ra.

Có bốn lớp bảo vệ liên tiếp:

1. **Authentication:** token có hợp lệ không, session có bị revoke không?
2. **Trusted identity:** request có thực sự đi qua Gateway/service hợp lệ không, header có bị client giả mạo không?
3. **Authorization:** user hiện tại có quyền trên resource hiện tại không?
4. **Data consistency:** mutation, association, outbox và side effect có được xử lý atomically/idempotently không?

SocialGraph là trung tâm của quyền truy cập xã hội và nội dung. Search và Recommendation không được tự quyết định quyền xem. Upload không chỉ là nơi lưu file; nó còn xác nhận ownership của asset. Auth không chỉ đăng nhập; nó quản lý session sống/chết và refresh-token rotation.

---

## 2. Topology của hệ thống

### 2.1 Các thành phần và port chính

| Thành phần | Port nội bộ mặc định | Trách nhiệm |
|---|---:|---|
| Authentication Service | 1001 | User credential, OTP, password, JWT, session |
| SocialGraph Service | 1002 | Profile, friend/follow/block, group, content, privacy |
| Recommendation Service | 1003 | Embedding, candidate ranking, recommendation IDs |
| Search Service | 1004 | Search index và search reference |
| Notification Service | 1005 | Notification bền vững và realtime |
| Messenger Service | 1006 | Conversation, message, receipt, presence |
| Payment Service | 1007 | Order, PayOS, premium activation |
| API Gateway | 2001 | Public GraphQL edge, Fusion, auth, rate limit |
| Upload Server | 4001 | Multipart upload, scan, file lifecycle |
| Frontend | 3001 hoặc container port 80 | React/Vite application |
| Edge/Nginx | 8080 hoặc operator-managed port | Public reverse proxy |

Các port service không phải public API. Trong deployment Compose, các service nằm trong private Docker network; chỉ edge publish ra bên ngoài.

### 2.2 Sơ đồ request

~~~text
                         ┌────────────────────┐
                         │      Browser        │
                         └─────────┬──────────┘
                                   │
              ┌────────────────────┼─────────────────────┐
              │                    │                     │
              ▼                    ▼                     ▼
        POST /graphql       POST /media/upload     PayOS webhook
              │                    │                     │
              ▼                    ▼                     ▼
        ┌───────────┐       ┌──────────────┐       ┌───────────┐
        │  Gateway  │       │ Upload       │       │  Gateway  │
        │  Fusion   │       │ Server       │       │ webhook   │
        └─────┬─────┘       └──────┬───────┘       └─────┬─────┘
              │                    │                     │
      ┌───────┼────────┐           │                     ▼
      ▼       ▼        ▼           │                Payment
    Auth  SocialGraph  ...          │
              │                    │
              ▼                    ▼
       PostgreSQL/Redis       Pending/committed files
~~~

### 2.3 Bảy GraphQL subgraph

Gateway ghép schema của các subgraph:

- Authentication;
- SocialGraph;
- Recommendation;
- Search;
- Notification;
- Messaging;
- Payment.

Schema được compose ở Gateway, nhưng business logic thật nằm trong service tương ứng. Không được xem file schema của Gateway là nơi duy nhất quyết định security; phải đọc resolver, application service và policy của service.

### 2.4 Source of truth và projection

| Dữ liệu | Source of truth | Nơi chỉ là projection/cache |
|---|---|---|
| Password, session, refresh token | Auth | Frontend chỉ giữ access token |
| Friend/follow/block | SocialGraph | Search/Recommendation chỉ dùng bản sao/candidate |
| Privacy, post, reel, group membership | SocialGraph | Feed cache, search index, recommendation vector |
| Conversation/message | Messenger | Notification/realtime event |
| Notification | Notification | In-memory realtime dispatcher |
| Payment/order | Payment | Auth premium date, SocialGraph verified date là downstream entitlement |
| File ownership/lifecycle | Upload + parent association | URL trong post/message chỉ là reference |

Nếu một projection nói user được nhìn thấy nội dung nhưng SocialGraph nói ngược lại, SocialGraph được ưu tiên.

---

## 3. Một API trong Fakebook gồm những gì

### 3.1 Cấu trúc code tổng quát

Một GraphQL mutation đi qua các lớp sau:

~~~text
Gateway schema
  → Gateway Fusion planner
  → Subgraph resolver
  → Trusted caller accessor
  → Application/domain service
  → Policy/ownership/membership checks
  → Repository/SQL transaction
  → Integration outbox
  → Worker gọi service khác
  → GraphQL response
~~~

Một REST endpoint nội bộ hoặc upload tương tự:

~~~text
HTTP middleware
  → JWT/HMAC/internal-secret validation
  → request size/content validation
  → endpoint/controller
  → application/store
  → transaction hoặc atomic file operation
  → response với stable error code
~~~

### 3.2 Bốn loại thông tin cần phân biệt

Trong một API, phải phân biệt:

1. **Actor:** user đang thao tác. Luôn lấy từ trusted context.
2. **Resource:** object đang được truy cập, ví dụ post ID, group ID, order code.
3. **Target:** user/group khác mà actor muốn tác động tới, ví dụ gửi friend request cho ai.
4. **Policy context:** privacy, block, membership, role, ownership, trạng thái hiện tại.

Ví dụ deleteGroup(groupId):

- groupId là resource;
- actor lấy từ session;
- role/admin/sole-owner được query lại từ DB;
- không có adminId nào từ client được tin.

### 3.3 Quy trình xử lý một mutation

Giả sử có:

~~~graphql
createFeedPost(input: {
  content: String
  privacy: Int
  mediaUrls: [String!]
  taggedUserIds: [ID!]
})
~~~

Quy trình đúng:

1. Browser gửi access token lên Gateway.
2. Gateway xóa trusted headers do browser tự thêm.
3. Gateway verify JWT và gọi Auth kiểm tra session.
4. Gateway chuyển request tới SocialGraph bằng trusted gateway context.
5. Resolver lấy actorId từ TrustedCallerAccessor.
6. Service kiểm tra content, privacy, media ownership, block, tag.
7. Service lock/đọc trạng thái hiện tại nếu cần.
8. DB transaction ghi object và associations.
9. Cùng transaction ghi outbox event.
10. Commit.
11. Worker sau đó gọi Search, Recommendation, Notification hoặc Upload.
12. Response trả content canonical từ SocialGraph.

### 3.4 Query và mutation khác nhau về an toàn

Query không có nghĩa là “không cần authorization”. Một query như profilePosts(profileId) vẫn phải kiểm tra:

- viewer hiện tại là ai;
- viewer có bị profile đó block không;
- post privacy là gì;
- post có phải group post không;
- shared source có còn visible không.

Mutation phải thêm:

- ownership hoặc role;
- state transition hợp lệ;
- transaction locking;
- idempotency nếu request có thể lặp;
- side effect/outbox.

---

## 4. Authentication, session và trusted identity

### 4.1 Login

~~~text
Frontend
  → Gateway: login(email, password)
  → Auth normalize input
  → login rate limit
  → bounded BCrypt verification
  → tạo session và refresh-token hash
  → phát hành access JWT RS256
  → Gateway set HttpOnly refresh cookie
~~~

Auth cố ý chống enumeration: lỗi không nói rõ email có tồn tại hay không. BCrypt được đặt sau bounded concurrency queue để attacker không thể dễ dàng dùng login endpoint làm CPU denial-of-service.

Access JWT ngắn hạn, mặc định khoảng 15 phút. Refresh token dài hơn nhưng chỉ xuất hiện trong HttpOnly cookie.

### 4.2 Refresh

Refresh token được hash rồi so với DB. Mỗi lần refresh:

1. token cũ được rotate;
2. token mới được hash và lưu;
3. token cũ không còn hợp lệ;
4. nếu token cũ bị dùng lại, hệ thống xem đó là reuse attack và revoke các session của user;
5. expiry không được vượt quá absolute session lifetime.

Frontend chỉ retry request một lần sau refresh. Khi nhiều tab cùng hết hạn, frontend dùng coordination để không gửi cùng refresh token nhiều lần.

### 4.3 Logout và revoke

Logout làm session inactive trong Auth. Gateway không chỉ kiểm tra chữ ký JWT vì JWT cũ có thể còn thời hạn; Gateway còn live-validate sid với Auth.

Các API realtime cũng được kiểm tra lại. Khi phát hiện revoke, Gateway hủy stream.

### 4.4 Trusted caller accessors

Service không nên gọi trực tiếp Request.Headers["X-User-Id"] trong resolver.

Quy tắc là:

~~~text
raw request header
  → middleware xác thực nguồn gọi
  → kiểm tra single positive user ID
  → lưu vào request context
  → application service gọi accessor
~~~

Các accessor hiện có:

| Service | Accessor/trusted context |
|---|---|
| SocialGraph | TrustedCallerAccessor |
| Search | TrustedGatewayUserAccessor |
| Notification | ICurrentGatewayUser |
| Messenger | ITrustedUserContextAccessor |
| Payment | IGatewayRequestContextAccessor |
| Auth | JWT/session hoặc internal auth |
| Upload | JWT claim cộng live Auth validation |

Header X-User-Id chỉ đáng tin sau khi secret/caller đã được xác thực. Bản thân header không phải credential.

### 4.5 Gateway kiểm tra JWT và GraphQL

Gateway kiểm tra:

- RS256;
- issuer/audience;
- lifetime;
- key ID;
- token size;
- user_id và sid;
- live Auth session.

Gateway còn bảo vệ GraphQL bằng:

- max execution depth khoảng 15;
- cycle depth giới hạn;
- giới hạn field/node/token/directive;
- planner timeout khoảng 3 giây;
- execution timeout khoảng 20 giây;
- expanded node limit;
- giới hạn concurrency;
- giới hạn body và rate limit;
- không cho browser tự chọn subgraph endpoint.

---

## 5. Authorization và luật bảo mật dữ liệu

### 5.1 Authentication khác authorization

JWT trả lời câu hỏi:

> Đây có phải một user/session hợp lệ không?

Authorization trả lời:

> User đó có quyền làm việc này trên resource này ở trạng thái hiện tại không?

Có JWT hợp lệ không đồng nghĩa được đọc mọi post, xóa mọi group hoặc gửi message cho mọi user.

### 5.2 Block luôn thắng

SocialGraph dùng policy tập trung để kiểm tra block hai chiều:

~~~text
A block B
hoặc B block A
→ loại khỏi visibility/candidate/relationship phù hợp
~~~

Không được chỉ kiểm tra block ở frontend. Không được chỉ kiểm tra ở Recommendation. Read path cuối cùng vẫn phải kiểm tra.

### 5.3 Privacy của FeedPost và Reel

| Giá trị | Ý nghĩa |
|---:|---|
| 0 | Public |
| 1 | Friends và current followers theo policy hiện tại |
| 2 | Friends |
| 3 | Chỉ author |

Các rule bổ sung:

- author luôn có quyền xem object của mình, trừ các trạng thái đặc biệt;
- block loại quyền xem hai chiều;
- tag/mention không cấp quyền xem;
- share wrapper không cấp quyền xem source;
- shared source phải được visibility-check lại theo viewer;
- group post dùng policy của group và membership hiện tại.

### 5.4 Group privacy và membership

Public/private chỉ ảnh hưởng visibility/discovery, không đồng nghĩa ai cũng tự động trở thành member.

- join luôn tạo pending request;
- admin mới approve/reject;
- invite chỉ hợp lệ với friend hiện tại;
- block không được bypass bởi invite;
- group post yêu cầu membership hoặc admin tùy policy;
- group metadata discovery được bounded và không làm lộ private content.

### 5.5 Ownership của media

URL media do client gửi lên không phải bằng chứng ownership. SocialGraph hoặc Messenger phải gọi Upload internal authorization để xác nhận:

~~~text
asset URL → stored asset → owner ID hiện tại
~~~

Nếu Upload không phản hồi hoặc ownership không khớp, mutation phải fail closed.

### 5.6 Authorization phải dùng dữ liệu hiện tại

Không cache quyết định nhạy cảm quá lâu. Đặc biệt cần đọc lại DB ngay trước các thao tác:

- delete/update content;
- approve group request;
- add/remove/demote admin;
- leave group;
- send direct message;
- delete conversation/message;
- use hoặc delete media;
- reconcile payment order.

---

## 6. Chữ ký gọi service nội bộ

Các service .NET dùng cùng implementation signing. Recommendation có implementation Python tương thích.

Canonical string:

~~~text
v1
METHOD
path/query
timestamp
nonce
lowercase sha256(body)
~~~

Header:

~~~text
X-Internal-Timestamp
X-Internal-Nonce
X-Internal-Signature
~~~

Bên nhận kiểm tra:

1. Method/path có đúng không?
2. Body có đúng từng byte không?
3. Timestamp có nằm trong skew cho phép không?
4. Nonce có đúng format không?
5. Nonce có bị dùng lại không?
6. Signature có khớp constant-time không?
7. Redis security nonce store có sẵn sàng không?

Nếu Redis nonce store lỗi thì không được bỏ qua replay protection. Request phải trả lỗi tạm thời/503.

Compose production bật signature và tắt truyền raw legacy secret. Mỗi target có secret riêng để compromise một service không tự động mở được toàn bộ mạng nội bộ.

Các flow có cơ chế riêng:

- Gateway → subgraph: dedicated Gateway secret và trusted context;
- Payment → Auth: Payment secret được Auth kiểm tra;
- Upload → Auth: bearer token và live session validation;
- các service-to-service REST khác: HMAC body/path/timestamp/nonce.

---

## 7. Database, Redis, transaction và outbox

### 7.1 Database isolation

Mỗi service có schema/role riêng, ví dụ:

~~~text
auth           → auth role
social_graph   → social_graph role
search         → search role
messenger      → messenger role
notification   → notification role
payment        → payment role
recommendation → recommendation role
~~~

Runtime role không nên có quyền DDL hoặc quyền ghi vào schema của service khác. Migration/schema setup được thực hiện ngoài runtime deployment.

### 7.2 Transaction local

Một service chỉ chịu trách nhiệm transaction trên dữ liệu mình sở hữu.

Ví dụ SocialGraph tạo post:

~~~text
objects
associations
outbox
cache invalidation metadata
~~~

phải được xử lý theo một transaction hoặc cơ chế rollback phù hợp.

### 7.3 Outbox

Không nên làm:

~~~text
BEGIN DB transaction
  → gọi Search qua HTTP
  → gọi Upload qua HTTP
  → gọi Notification qua HTTP
  → COMMIT
~~~

Nếu network lỗi hoặc service khác timeout, transaction sẽ khó rollback và dễ tạo trạng thái nửa thành công.

Pattern hiện có:

~~~text
BEGIN
  ghi local state
  ghi integration outbox
COMMIT

worker
  claim message bằng FOR UPDATE SKIP LOCKED
  gọi downstream bằng signed request
  success → completed
  transient error → retry/backoff
  permanent/max attempts → dead-letter
~~~

Outbox có idempotency key để cùng một event không tạo side effect lặp. Payload nhạy cảm, đặc biệt provisioning user, được bảo vệ bằng encryption.

### 7.4 Eventual consistency

Sau một mutation thành công, các hệ thống phụ có thể cập nhật chậm:

- Search index;
- recommendation embedding;
- notification;
- Messenger user projection;
- Upload finalize;
- premium activation.

Đây là chủ ý của thiết kế. API phải trả dữ liệu canonical từ service sở hữu, không giả vờ rằng mọi projection đã hoàn tất.

### 7.5 Retry

Chỉ retry an toàn khi:

- method là safe/read-only; hoặc
- operation có idempotency key rõ ràng; hoặc
- downstream đã thiết kế idempotent.

Unsafe HTTP mutation không được tự động retry chỉ vì timeout, vì request có thể đã commit ở server.

---

## 8. Giải thích từng service

### 8.1 API Gateway

Gateway là public edge và GraphQL composition layer.

Nó chịu trách nhiệm:

- nhận /graphql;
- xác thực JWT;
- live-validate Auth session;
- strip browser-controlled trusted headers;
- inject trusted identity khi gọi subgraph;
- rate limit user/IP;
- giới hạn GraphQL depth, cycle, field, node, planner, timeout;
- giới hạn concurrency và body;
- quản lý refresh-cookie instruction;
- proxy PayOS webhook;
- xử lý SSE session watchdog.

Gateway không được:

- tự quyết định business ownership thay SocialGraph;
- nhận subgraph URL từ client;
- để browser gửi thẳng subgraph;
- trả refresh token vào GraphQL data;
- tin X-User-Id do client tự gửi.

### 8.2 Authentication Service

Auth sở hữu:

- user credential;
- password hash;
- email verification/OTP;
- login rate limit;
- JWT issuance/validation;
- refresh token hash/rotation;
- session/revocation/audit;
- premium valid date được Payment cập nhật qua flow được bảo vệ.

Auth là service duy nhất giữ JWT private key. Các service khác chỉ verify public key hoặc gọi Auth để kiểm tra live session.

### 8.3 SocialGraph Service

Đây là service quan trọng nhất về business authorization.

Nó quản lý:

- profile;
- friend request/accepted friend;
- follow;
- block;
- feed post/reel/story;
- comment/like/save/watch;
- tag/mention;
- group/member/admin/join request/invite;
- privacy và visibility;
- media ownership association;
- search/recommendation integration event.

Mô hình nội bộ dùng object và association. Một object có thể được nối với user, group, media hoặc object khác qua association type. Media parent relationship dùng Contained; lượt xem dùng Visited.

Các policy trung tâm:

- BlockVisibilityService;
- ContentGraphService;
- GroupGraphService;
- AssociationService;
- MediaOwnershipGuard;
- trusted caller accessor.

Không nên thêm một resolver tự viết luật privacy/block riêng.

### 8.4 Upload Server

Upload là browser-facing service duy nhất ngoài Gateway.

Nó quản lý:

- multipart body;
- authenticated owner;
- file metadata;
- pending/committed state;
- generated storage filename;
- full stream content audit;
- asset authorize/finalize/delete;
- cleanup file pending hết hạn;
- public read file theo safe leaf path.

Upload không quyết định post có visible hay không. Nó chỉ quyết định file có hợp lệ, thuộc owner nào và lifecycle file ra sao.

### 8.5 Messenger Service

Messenger quản lý state hội thoại, nhưng không tự sở hữu friend/block policy. Với direct conversation, Messenger phải hỏi SocialGraph.

Direct conversation và direct message được phép giữa mọi user active khi không có block ở cả
hai hướng. Friendship không còn là điều kiện nhắn tin, nhưng vẫn là điều kiện để xem presence
trước khi hai người có hội thoại chung và để thêm thành viên vào group chat. Cặp direct user được
chuẩn hóa và có unique index, nên gọi tạo lại trả hội thoại cũ thay vì tạo bản sao.

Các rule quan trọng:

- conversation member check trên mọi read/mutation;
- sender lấy từ trusted context;
- clientMessageId idempotency;
- sequence tăng dưới lock;
- edit/delete author-only với time/window rules;
- system message không bị xử lý như user message;
- group admin/member mutation lock current state;
- attachment URL allowlist;
- upload finalize/delete qua outbox;
- SSE chỉ gửi event tới user/conversation được phép.

### 8.6 Notification Service

Notification sở hữu record notification, read/unread và retention.

Các thao tác đọc/mark-read luôn lấy receiver từ trusted context. Internal writer dùng idempotency key. Realtime chỉ phát sau khi notification đã bền vững trong DB.

### 8.7 Search Service

Search sở hữu index token/reference, không sở hữu privacy.

Search user trong phạm vi relationship:

~~~text
viewer trusted
  → lấy allowed IDs từ SocialGraph/Messenger
  → intersect với index
  → trả references
  → hydrate ở SocialGraph
~~~

Search có giới hạn query/page/batch để tránh amplification.

### 8.8 Recommendation Service

Recommendation lưu embedding và tính điểm. Candidate IDs đến từ SocialGraph sau khi SocialGraph đã lọc quyền.

Recommendation có thể xếp hạng bằng embedding text/media, nhưng không được trả object riêng tư. Kết quả cuối phải được SocialGraph hydrate và visibility-check lại.

Khi tải media để tạo embedding, service phải chống SSRF bằng host allowlist, IP validation, no redirect, byte/pixel/frame/time cap.

### 8.9 Payment Service

Payment sở hữu:

- catalog plan;
- order;
- provider transaction;
- PayOS webhook verification;
- payment outbox;
- premium activation workflow.

Client không được chọn amount hoặc user sở hữu order. Webhook mới là flow authoritative sau khi kiểm tra exact body, checksum, order code, amount, currency và idempotency.

Premium activation có thể là asynchronous: Payment cập nhật Auth valid date và SocialGraph verified state theo worker/lock.

---

## 9. Các luồng nghiệp vụ từ đầu đến cuối

### 9.1 Đăng nhập

~~~text
Browser login mutation
  → Gateway anonymous rate limit
  → Auth normalize + BCrypt bounded verify
  → tạo session + hashed refresh token
  → JWT access token
  → Gateway đặt HttpOnly cookie
  → Frontend lưu access token ngắn hạn
~~~

Request protected sau đó:

~~~text
Bearer JWT
  → Gateway verify chữ ký/claims
  → Auth validate user_id + sid còn active
  → subgraph nhận trusted actor
~~~

### 9.2 Provision user

~~~text
SocialGraph tạo profile/user identity
  → local transaction + encrypted UserCreate outbox
  → Auth tạo credential identity trước
  → Auth success
  → Search/Recommendation/Messenger tạo projection
~~~

Nếu Auth không tạo được user, saga compensation không để các projection mồ côi trở thành user hợp lệ.

### 9.3 Upload và tạo feed post

~~~text
1. Browser POST /media/upload với Bearer token.
2. Upload verify JWT và live Auth session.
3. Upload kiểm tra extension/content type/magic bytes/full stream.
4. Upload lưu GUID filename ở trạng thái pending.
5. Browser nhận relative media URL + asset ID.
6. Browser gọi createFeedPost qua Gateway.
7. SocialGraph lấy actor từ trusted context.
8. SocialGraph gọi Upload authorize để kiểm tra ownership.
9. SocialGraph kiểm tra privacy/block/tag/content.
10. Transaction ghi post + media association + outbox.
11. Commit.
12. Worker gọi Upload finalize, Search upsert, Recommendation upsert, Notification nếu cần.
~~~

Nếu bước 10 thất bại, file pending không được coi là đã attach; cleanup worker sẽ xóa file hết hạn.

### 9.4 Đọc private post

~~~text
Query profile/feed/content
  → viewer từ trusted context
  → load object/source/group
  → block hai chiều
  → privacy
  → relationship
  → group membership/admin
  → source visibility nếu là share
  → projection chỉ những field viewer được phép thấy
~~~

Không dùng authorId == viewerId là check duy nhất. Share wrapper cũng không làm source public.

### 9.5 Gửi friend request/follow/block

~~~text
Mutation
  → actor trusted
  → target/resource tồn tại
  → block hiện tại
  → relationship state hiện tại
  → association inverse trong transaction
  → cache invalidate
  → outbox downstream
~~~

Không bao giờ cho input requesterId, actorId hoặc ownerId quyết định người thực hiện.

### 9.6 Join/leave group

Join:

~~~text
actor trusted
  → group tồn tại
  → actor chưa bị block/ban theo policy
  → tạo pending join request
  → admin approve sau đó mới tạo membership
~~~

Leave:

~~~text
Serializable transaction
  → advisory lock group
  → đọc lại membership/admin hiện tại
  → nếu sole admin: chọn successor sớm nhất
  → promote successor hoặc reject nếu không có successor
  → xóa association cần thiết
  → commit rồi mới cleanup downstream/media
~~~

Admin removal/demotion cũng dùng group lock và không được xóa admin cuối cùng.

### 9.7 Gửi direct message

~~~text
Gateway
  → Messenger trusted user
  → verify conversation/member
  → SocialGraph kiểm tra target tồn tại và block hai chiều
  → validate text/clientMessageId/attachments
  → idempotency lookup
  → lock conversation + sequence
  → insert message + attachments + realtime event
  → attachment finalize outbox
  → emit SSE sau commit
~~~

Nếu SocialGraph unavailable, permission check fail closed. Không tự mặc định “được phép” vì dependency đang lỗi.

### 9.8 Search user/friend

~~~text
Search trusted viewer
  → signed call SocialGraph/Messenger lấy allowed IDs
  → Search intersect allowed IDs với index
  → trả reference
  → SocialGraph hydrate và lọc visibility
~~~

Search không được tự trả full private profile chỉ vì index có record.

### 9.9 Recommendation feed/reels

~~~text
Recommendation nhận viewer trusted
  → signed call SocialGraph lấy candidate IDs đã policy-filtered
  → rank bằng embedding
  → trả ID + score/metadata tối thiểu
  → SocialGraph hydrate
  → visibility-check lần cuối
~~~

Nếu quan hệ/block/privacy thay đổi sau lúc candidate được tạo, lần hydrate cuối vẫn phải loại item không còn hợp lệ.

### 9.10 Notification

~~~text
SocialGraph/Messenger/Payment
  → signed internal notification write
  → idempotency key
  → Notification DB commit
  → realtime dispatcher
  → receiver topic
~~~

Client chỉ subscribe topic của chính user đã xác thực.

### 9.11 Payment checkout và webhook

Checkout:

~~~text
Browser
  → Gateway
  → Payment actor từ trusted context
  → lấy giá plan server-side
  → tạo order owned by actor
  → gọi PayOS
~~~

Webhook:

~~~text
PayOS exact body
  → Gateway /api/webhooks/payos
  → rate/body/content-type check
  → Payment verify checksum
  → lock order
  → validate order/amount/currency/link
  → idempotent transaction
  → activation outbox
~~~

Browser authentication không được dùng để authorize webhook.

### 9.12 Xóa content và media

~~~text
delete content
  → actor author hoặc exact group admin
  → transaction xóa/hide object và associations
  → giữ tombstone/edge cần thiết cho comment history nếu policy yêu cầu
  → kiểm tra media còn parent nào không
  → outbox Upload delete chỉ khi không còn parent
~~~

Comment tombstone không được cho phép like/reply/edit/mention như comment hoạt động.

---

## 10. Frontend giao tiếp với backend

Frontend nằm trong Frontend/Frontend.

### 10.1 URL

Production/browser nên dùng URL tương đối:

~~~text
/graphql
/media
/api/webhooks/... chỉ dành cho provider/server flow
~~~

Development dùng Vite proxy tới port nội bộ. Không để browser nhận URL localhost của server khác khi chạy qua remote edge.

### 10.2 GraphQL client

Frontend client:

- dùng fetch tới Gateway;
- gửi Authorization: Bearer access token;
- gửi credentials: include để refresh cookie hoạt động;
- timeout request;
- retry sau 401 bằng refresh một lần;
- không retry mutation vô điều kiện;
- deduplicate read query đang in-flight;
- parse Snowflake IDs thành string để không mất precision JavaScript.

Snowflake ID có thể lớn hơn 2^53 - 1; mọi ID trong frontend nên xử lý như string.

### 10.3 Upload frontend

Frontend:

1. upload file trực tiếp tới Upload Server;
2. nhận asset ID/state/url;
3. truyền URL qua GraphQL mutation;
4. nếu mutation thất bại, cố cancel pending asset;
5. backend finalize sau khi parent commit.

Frontend không tự cho rằng upload xong nghĩa là file đã được sử dụng trong post.

---

## 11. Realtime bằng GraphQL-over-SSE

Realtime đi qua cùng Gateway GraphQL endpoint nhưng response là event stream.

Các loại stream:

- conversation events;
- inbox events;
- presence events;
- notification created.

Gateway phải:

- xác thực JWT trước khi mở stream;
- kiểm tra session đang sống;
- theo dõi revoke trong lúc stream mở;
- hủy stream khi session không còn hợp lệ;
- không buffer response như request GraphQL thường.

Service phải:

- giới hạn subscription scope;
- verify tất cả conversation/resource trước khi subscribe;
- filter từng event trước khi gửi;
- không chỉ kiểm tra lúc handshake rồi tin mãi.

Frontend phải:

- deduplicate event theo ID/sequence;
- refetch nếu phát hiện sequence gap;
- reconnect exponential backoff + jitter;
- dừng reconnect khi lỗi authentication terminal;
- không reset backoff chỉ vì HTTP connection vừa mở.

Nginx phải tắt buffering và có read timeout dài cho SSE.

---

## 12. Triển khai và vận hành

### 12.1 Docker Compose production-style

Compose hiện dùng image build sẵn từ GHCR và pull_policy: always. Runtime service không tự build source và không tự dùng migration owner.

Các service trong private network:

~~~text
authentication
social-graph
recommendation
search
notification
messaging
payment
gateway
upload
frontend
redis
otel-collector
edge
~~~

Chỉ edge publish port ra ngoài. Internal service không nên mở public firewall/port.

### 12.2 Redis

Redis dùng:

- SocialGraph cache;
- security nonce replay protection;
- auth/rate/security state tùy service;
- Recommendation security replay store.

Security Redis là dependency fail-closed. Không được biến lỗi Redis thành “bỏ qua chữ ký”.

### 12.3 PostgreSQL

Runtime connection string dùng service role riêng. Schema/migration phải được chuẩn bị trước deployment. Không bật auto migration với owner credential trong production runtime.

### 12.4 Upload volume

Upload dùng volume media. Nếu scale nhiều replica, phải bảo đảm các replica cùng nhìn thấy storage hoặc chuyển sang object storage có lifecycle/ownership tương đương.

### 12.5 Edge limits

Edge/Nginx có các nhóm limit riêng:

- GraphQL request rate;
- GraphQL connection;
- upload request rate;
- upload connection;
- GraphQL SSE timeout;
- media body size lớn hơn GraphQL body size.

Không được để upload đi qua limit 2 MiB của GraphQL; upload phải đi /media với limit riêng khoảng 502 MiB.

### 12.6 Observability

Log/trace được phép chứa:

- correlation ID;
- request ID;
- stable error code;
- latency/status;
- aggregate/resource ID nếu không làm lộ dữ liệu nhạy cảm.

Không log:

- password;
- access/refresh token;
- private key/secret;
- raw webhook body;
- nội dung private;
- full upload content;
- SQL stack/error có thông tin nhạy cảm.

---

## 13. Các lỗi thiết kế dễ mắc phải

### Lỗi 1: lấy actor từ input

Sai:

~~~csharp
var actorId = input.UserId;
~~~

Đúng:

~~~csharp
var actorId = trustedCallerAccessor.RequireUserId();
~~~

### Lỗi 2: tin trusted header từ browser

Browser có thể tự gửi bất kỳ header nào. Chỉ header được Gateway tạo sau authentication mới có ý nghĩa, và subgraph vẫn phải verify gateway secret.

### Lỗi 3: upload URL là ownership proof

URL chỉ là reference. Phải gọi Upload authorize với actor hiện tại.

### Lỗi 4: Search hoặc Recommendation quyết định visibility

Hai service này là projection/ranking. SocialGraph phải hydrate và kiểm tra quyền cuối cùng.

### Lỗi 5: privacy check nhưng quên block

Mọi content read nên dùng policy kernel có block. Đừng viết if privacy == 0 riêng trong resolver.

### Lỗi 6: kiểm tra quyền trước transaction rồi không kiểm tra lại

Membership/admin có thể thay đổi giữa lúc đọc và lúc ghi. Các thao tác nhạy cảm cần lock/isolation và reauthorization trong transaction.

### Lỗi 7: gọi downstream trong DB transaction

Dùng outbox. Network call trong transaction dễ tạo half-commit và lock lâu.

### Lỗi 8: retry mutation không idempotent

Timeout không chứng minh request chưa commit. Chỉ retry nếu có idempotency hoặc service đã thiết kế deduplication.

### Lỗi 9: fallback khi security Redis lỗi

Cache ứng dụng có thể fallback tùy policy. Replay nonce store thì không được fallback.

### Lỗi 10: expose subgraph hoặc Auth private key

Browser chỉ vào Gateway/Upload. Auth private key chỉ nằm trong Auth. Gateway/Upload chỉ dùng public key.

### Lỗi 11: log dữ liệu nhạy cảm

Không ghi token, password, secret, raw payment body hoặc private media vào log.

### Lỗi 12: quên eventual consistency

Search, recommendation, notification, media finalize và premium activation có thể đến sau local mutation. UI nên hiểu trạng thái pending/retry thay vì giả định mọi thứ đồng bộ tức thì.

---

## 14. Checklist khi thêm hoặc sửa API

### 14.1 Trước khi code

- Đọc README.md.
- Đọc docs/api-security-contract.md.
- Đọc secure.md.
- Đọc docs/internal-request-signing.md nếu có service-to-service call.
- Đọc AGENTS.md của service liên quan.
- Xác định service nào là source of truth.
- Xác định actor, resource, target và policy.

### 14.2 Trong lúc code

- Actor có lấy từ trusted accessor không?
- Có chấp nhận userId, ownerId, adminId của client làm identity không?
- Có kiểm tra resource hiện tại trong DB không?
- Có block/privacy/ownership/membership check không?
- Có giới hạn string/list/page/body/time không?
- Mutation có transaction không?
- Side effect có nằm trong outbox không?
- Downstream có idempotent không?
- Có retry unsafe không?
- Có log secret/body/content không?
- Có lộ stack trace/SQL/PII không?

### 14.3 Negative test cần có

Mỗi API nhạy cảm nên test ít nhất:

- anonymous;
- JWT sai;
- session đã revoke;
- trusted header bị thiếu/trùng/giả;
- user A thao tác resource của user B;
- blocked user;
- privacy không đủ;
- không còn membership/admin;
- media không thuộc owner;
- malformed input;
- pagination quá lớn;
- duplicate request;
- downstream timeout/unavailable;
- Redis nonce unavailable;
- webhook body/signature/amount sai;
- query GraphQL quá sâu hoặc quá lớn.

### 14.4 Trước khi bàn giao API change

Chạy:

~~~powershell
.\scripts\check-api-security-contracts.ps1
.\scripts\test-all.ps1
~~~

Nếu Docker, external provider, database integration hoặc PayOS không khả dụng thì phải nói rõ test hạ tầng nào bị bỏ qua. Không được ghi “đã pass” nếu chưa thực sự chạy.

check-api-security-contracts.ps1 là structural guard. Nó rất hữu ích nhưng không thay thế business authorization tests.

---

## 15. Bản đồ source code

### Tài liệu nền

- README.md: topology, canonical behavior và API surface.
- docs/api-security-contract.md: security definition of done.
- docs/internal-request-signing.md: HMAC signing contract.
- secure.md: security findings, accepted risks và evidence đã ghi nhận.
- AGENTS.md: quy tắc bắt buộc cho coding agent.
- docker-compose.yaml: deployment topology và runtime security config.

### Gateway

- APIGateway/API-Gateway/fakebookGateway/Program.cs
- APIGateway/API-Gateway/fakebookGateway/Gateway/GatewayEdgeMiddleware.cs
- APIGateway/API-Gateway/fakebookGateway/Gateway/AuthSessionValidator.cs
- APIGateway/API-Gateway/fakebookGateway/Gateway/FusionSubgraphHeaderHandler.cs
- APIGateway/API-Gateway/fakebookGateway/Gateway/PaymentWebhookProxy.cs
- APIGateway/API-Gateway/fakebookGateway/schema/

### Auth

- AuthenticationService/Backend-Authentication/fakebookAuth/Program.cs
- AuthenticationService/Backend-Authentication/fakebookAuth/GraphQL/GraphQLSchema.cs
- AuthenticationService/Backend-Authentication/fakebookAuth/Services/AuthService.cs
- AuthenticationService/Backend-Authentication/fakebookAuth/Security/SecurityServices.cs

### SocialGraph

- SocialGraphService/SocialGraph.Api/Program.cs
- SocialGraphService/SocialGraph.Api/TrustedCallerAccessor.cs
- SocialGraphService/SocialGraph.Api/Service/BlockVisibilityService.cs
- SocialGraphService/SocialGraph.Api/Service/ContentGraphService.cs
- SocialGraphService/SocialGraph.Api/Service/GroupGraphService.cs
- SocialGraphService/SocialGraph.Api/Service/AssociationService.cs
- SocialGraphService/SocialGraph.Api/Service/MediaOwnershipGuard.cs
- SocialGraphService/SocialGraph.Api/Infrastructure/Outbox/
- SocialGraphService/SocialGraph.Api/SubGraphQL/Query.cs
- SocialGraphService/SocialGraph.Api/SubGraphQL/Mutation.cs

### Upload

- UploadSever/Upload-Server/Program.cs
- UploadSever/Upload-Server/UploadAssetStore.cs
- UploadSever/Upload-Server/InternalRequestSigning.cs
- UploadSever/Upload-Server/README.md

### Messenger

- MessengerService/MessengerService/Program.cs
- MessengerService/MessengerService/GatewayTrustMiddleware.cs
- MessengerService/MessengerService/GraphQL/MessagingMutation.cs
- MessengerService/MessengerService/Services/MessagingApplicationService.cs
- MessengerService/MessengerService/Services/SocialGraphPermissionClient.cs
- MessengerService/MessengerService/Services/UploadMediaClient.cs

### Notification

- NotificationService/NotificationService/Program.cs
- NotificationService/NotificationService/GraphQL/NotificationQueries.cs
- NotificationService/NotificationService/GraphQL/NotificationMutations.cs
- NotificationService/NotificationService/InternalRequestAuthenticationMiddleware.cs

### Search

- SearchService/Backend-Search/Program.cs
- SearchService/Backend-Search/GraphQL/Query.cs
- SearchService/Backend-Search/GraphQL/Mutation.cs
- SearchService/Backend-Search/SearchService.cs
- SearchService/Backend-Search/IndexerService.cs
- SearchService/Backend-Search/SocialGraphFriendClient.cs

### Recommendation

- RecommendationService/Backend-Recommendation/ForFakebook/EmbeddingModel.py
- RecommendationService/Backend-Recommendation/ForFakebook/operations.py
- RecommendationService/Backend-Recommendation/ForFakebook/internal_signing.py
- RecommendationService/Backend-Recommendation/ForFakebook/embedding_service.py

### Payment

- PaymentService/Backend-Payment/fakebookPayment/Program.cs
- PaymentService/Backend-Payment/fakebookPayment/GraphQL/PaymentGraphQL.cs
- PaymentService/Backend-Payment/fakebookPayment/PayOS/PayOSWebhookEndpoint.cs
- PaymentService/Backend-Payment/fakebookPayment/Services/PremiumPaymentService.cs
- PaymentService/Backend-Payment/fakebookPayment/Services/PremiumActivationWorker.cs
- PaymentService/Backend-Payment/fakebookPayment/PaymentRepository.cs

### Frontend

- Frontend/Frontend/src/api/client.ts: Gateway client, auth refresh, upload helper.
- Frontend/Frontend/src/api/realtime.ts: GraphQL-over-SSE.
- Frontend/Frontend/src/api/gatewayTypes.ts: typed Gateway model.
- Frontend/Frontend/src/api/social.ts: social operations.
- Frontend/Frontend/src/api/messenger.ts: messenger operations.
- Frontend/Frontend/src/api/search.ts: search operations.

---

## 16. Từ điển thuật ngữ

### Actor

User thực sự đang thực hiện request. Không lấy từ input; lấy từ trusted session/context.

### Resource

Object mà request muốn đọc/sửa/xóa, ví dụ postId, groupId, orderCode.

### Trusted context

Thông tin identity đã được middleware xác thực nguồn và đặt vào request context. Resolver không tự tin raw browser header.

### Gateway secret

Secret dành cho Gateway gọi một subgraph cụ thể. Mỗi subgraph có secret riêng.

### Internal signing

HMAC signature cho service-to-service request, bao phủ method, path, timestamp, nonce và exact body hash.

### Replay attack

Attacker lấy một request hợp lệ rồi gửi lại. Nonce + Redis SET NX ngăn request cũ được dùng lại.

### Source of truth

Service sở hữu dữ liệu và policy chính. Với privacy/social/content, đó là SocialGraph.

### Projection

Bản sao phục vụ search, recommendation, notification hoặc read performance. Projection không được thay source of truth.

### Outbox

Bản ghi side effect được lưu cùng local transaction, sau đó worker gửi sang service khác.

### Idempotency

Gửi cùng một operation nhiều lần vẫn chỉ tạo một kết quả logic.

### Pending media

File đã upload nhưng chưa được parent domain object chấp nhận/finalize.

### Tombstone

Record/edge còn lại sau khi nội dung bị xóa để bảo toàn lịch sử, sequence hoặc quan hệ cần thiết, nhưng không còn cho phép thao tác như object hoạt động.

### Fail closed

Không xác minh được security dependency thì từ chối request, thay vì cho phép tạm.

### Eventual consistency

Local mutation hoàn tất trước, projection/downstream cập nhật sau qua worker/outbox.

---

## Kết luận ngắn

Nếu chỉ cần nhớ một luồng chuẩn, hãy nhớ:

~~~text
Browser
  → Gateway/Upload edge
  → verify token + live session
  → trusted actor
  → current-resource authorization
  → local transaction
  → outbox
  → signed/idempotent downstream work
  → visibility check khi đọc lại
~~~

Nếu một thay đổi phá vỡ một trong các điểm trên, đặc biệt là actor từ input, direct browser-to-service shortcut, bypass block/privacy/ownership, unsafe retry hoặc fail-open khi Redis/signature lỗi, thì thay đổi đó đi ngược kiến trúc bảo mật của Fakebook.
