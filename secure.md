# Báo cáo bảo mật hệ thống Fakebook

Ngày kiểm thử: 27/07/2026 · Phạm vi: toàn bộ 10 service + edge nginx + frontend

---

## 1. Tóm tắt

Kiểm thử bảo mật toàn hệ thống ghi nhận **16 lỗ hổng** đã được xác minh trên mã nguồn thật, trong đó
**1 lỗ hổng cho phép phá hoại dữ liệu không thể phục hồi**. **Đã vá 10/16**, kèm **44 test hồi quy
mới** (SocialGraph +22, Upload +7, Auth +8, Gateway +4, Frontend +3); 1 mục cần thao tác thủ công trên
PostgreSQL server (mục 5.1) và 6 mục còn lại được xếp thứ tự ở mục 9.

Song song, hai API duy nhất chặn frontend đã được bổ sung và **CI chạy test đã được bật cho cả 10
repo** (mục 4b).

Thế trận phòng thủ nền của hệ thống ở mức khá: **không tìm thấy SQL injection** ở bất kỳ service
nào (Auth dùng Dapper tham số hoá, SocialGraph dùng EF LINQ, Recommendation không nối chuỗi SQL),
**không có path traversal** (Upload có `IsSafeLeafFileName` + kiểm tra prefix thư mục gốc),
**không có SSRF/RCE**, và **không có đường bypass xác thực từ Internet**. Gateway xoá sạch mọi
header `X-User-Id`/`X-Gateway-Secret`/`X-Internal-*` do client gửi lên trước khi gán giá trị tin
cậy, mọi cổng service chỉ bind `127.0.0.1`, và 15 secret nội bộ đều dài 32 byte và khác nhau.

Điểm yếu tập trung ở ba nhóm: (1) tầng **đọc** của SocialGraph — quy tắc privacy và block được cài
lại ở ba nơi khác nhau nên rò ở đường Story; (2) **sự tin cậy mù** giữa SocialGraph và Upload Server
đối với chuỗi URL do client gửi; (3) **chống lạm dụng** — rate limit không phân biệt được người dùng.

---

## 2. Phương pháp

- Rà soát mã nguồn theo 10 hướng chuyên biệt (xác thực/phiên, gateway/biên tin cậy, uỷ quyền
  SocialGraph, messenger, notification, payment, upload, recommendation, search, hạ tầng/bí mật/frontend).
- Mỗi phát hiện đi qua một vòng **phản biện đối kháng** độc lập: người phản biện mở lại đúng
  file/dòng, đọc cả các lớp middleware/filter/policy chạy trước đó, và mặc định bác bỏ nếu không tự
  chứng minh được đường khai thác. 115 phát hiện thô ban đầu → 140 mục được xác minh (số tăng vì
  vòng phản biện tự tìm thêm lỗi bị bỏ sót) → gộp còn 16 lỗ hổng.
- Mọi tuyên bố bảo mật trong README đều được kiểm chứng lại trên mã nguồn. **11 tuyên bố sai lệch**
  so với thực tế (chi tiết ở mục 6).

---

## 3. Bảng tổng hợp

| # | Lỗ hổng | Mức | Trạng thái |
|---|---|---|---|
| 1 | Bất kỳ người dùng nào cũng xoá vĩnh viễn được media của người khác | High | ✅ Đã vá |
| 2 | Bypass lớp lọc refresh token của Gateway (3 biến thể) | Medium | ✅ Đã vá |
| 3 | Reel riêng tư rò qua Story; đường Story bỏ qua block | Medium | ✅ Đã vá |
| 4 | Rate limit "theo IP" thực chất là một bucket toàn cục | Medium | ✅ Đã vá |
| 5 | Khoá tài khoản nạn nhân từ xa qua bộ đếm đăng nhập | Medium | ✅ Đã vá |
| 6 | Liệt kê tài khoản qua `resendEmailVerification` / `login` | Medium | ✅ Đã vá |
| 7 | Toàn hệ thống dùng chung 1 tài khoản PostgreSQL, mật khẩu 9 ký tự | Medium | ⚠️ Cần thao tác thủ công |
| 8 | Thu hồi phiên không tức thì với stream SSE đang mở | Medium | ✅ Đã vá |
| 9 | Block không áp dụng ở tag/mention, danh sách người dùng, bình luận | Medium | ⏳ Chưa vá |
| 10 | Cookie refresh token gửi tới Upload Server ở mọi request `/media` | Low | ✅ Đã vá |
| 11 | Khoá ký JWT dùng chung cho Auth/Gateway/Upload (HS256) | Low | ⏳ Chưa vá |
| 12 | Nonce chống replay lưu trong RAM; `RequireSignature` mặc định false | Low | ⏳ Chưa vá |
| 13 | Pool BCrypt 2 permit — flood đăng ký làm ngưng xác thực | Low | ⏳ Chưa vá |
| 14 | `login` ghi identifier tuỳ ý, không giới hạn độ dài, vào audit log | Low | ✅ Đã vá |
| 15 | Phiên không có thời hạn tuyệt đối | Low | ⏳ Chưa vá |
| 16 | Edge nginx không đặt header bảo mật nào (clickjacking) | Low | ✅ Đã vá (trừ CSP) |

**Đã vá 10/16.** Mục Medium còn lại duy nhất là #9; các mục Low được mô tả ở phần 9.

---

## 4. Chi tiết các lỗ hổng đã vá

### 4.1 — Xoá vĩnh viễn media của người khác `HIGH`

**Vị trí:** `UploadSever/Upload-Server/UploadAssetStore.cs:85-101` ·
`SocialGraphService/SocialGraph.Api/SubGraphQL/Mutation.cs:38-62` ·
`SocialGraphService/SocialGraph.Api/Service/UserGraphService.cs:741-758`

**Đường khai thác** (đã dựng lại và kiểm chứng từng mắt xích):

1. Kẻ tấn công đọc URL avatar của nạn nhân qua query hồ sơ công khai.
2. Gọi `changeUserAvatar(userId: <chính mình>, avatarUrl: <URL nạn nhân>)`. Resolver chỉ gọi
   `trustedCaller.RequireUserId(userId)` — nghĩa là "bạn đang sửa hồ sơ của chính bạn" — và
   **không hề kiểm tra chuỗi URL kia thuộc về ai**.
3. Gọi `changeUserAvatar` lần thứ hai với URL bất kỳ khác. Lúc này `UserGraphService.cs:741` lấy
   `previousUrl` = URL của nạn nhân, và dòng 754-758 gọi thẳng `DeleteMediaAsync(previousUrl)`.
4. Upload Server nhận `POST /internal/media/delete`, chỉ xác thực caller là service nội bộ rồi gọi
   `DeleteByUrlsAsync` — hàm này chuyển URL thành tên file rồi xoá, **không kiểm tra
   `OwnerUserId`, không kiểm tra trạng thái pending/committed**. Đối chiếu: hàm
   `DeletePendingOwnedAsync` ngay bên dưới (dòng 103-123) kiểm tra đủ cả hai.

**Tác động:** file bị xoá khỏi đĩa vĩnh viễn, không có thùng rác, không có backup trong compose.
Cùng đường này áp dụng cho `changeUserBackground`, ảnh bìa nhóm, và đính kèm tin nhắn Messenger.
Một script chạy vài phút có thể xoá sạch avatar của toàn bộ người dùng.

**Cách đã sửa** — vá cả hai phía:

*Phía Upload Server* (commit `9cb4758`):
- `FinalizeAsync` / `DeleteByUrlsAsync` nhận thêm `ownerUserId`. Khi có giá trị, chỉ thao tác trên
  asset có `OwnerUserId` khớp, và **fail closed** khi không xác định được quyền sở hữu (thiếu
  metadata, metadata hỏng, file legacy).
- Thêm endpoint `POST /internal/media/authorize` (`{ownerUserId, urls}` → `{authorized, unauthorizedUrls}`)
  để service nghiệp vụ kiểm tra trước khi lưu URL.
- Đọc metadata không còn ném exception với tên file legacy/không phải GUID; trả về "không xác định
  chủ sở hữu" thay vì crash.
- Dọn dẹp dây chuyền (xoá user/nhóm/bài) vẫn hoạt động bằng cách bỏ trống `ownerUserId`, vì các URL
  đó đến từ trạng thái đã lưu phía server chứ không phải request hiện tại.

*Phía SocialGraph* (commit `cbd6484`):
- Thêm `IMediaOwnershipGuard` / `UploadMediaOwnershipGuard`: hỏi Upload xem người thực hiện có sở hữu
  từng URL client gửi lên không, và **fail closed** khi không lấy được câu trả lời (chưa cấu hình,
  không kết nối được, response không thành công).
- Áp dụng cho avatar/ảnh bìa người dùng, avatar/ảnh bìa nhóm, và mọi `MediaInput` khi tạo bài viết,
  bài nhóm, bình luận, story, reel, cũng như khi cập nhật bài.
- `FinalizeMediaAsync`/`DeleteMediaAsync` mang theo `ownerUserId` qua integration outbox.
  `MediaLifecycleEvent.OwnerUserId` để optional nên các bản ghi outbox cũ vẫn deserialize được.
- Lỗi trả về mã `FORBIDDEN` qua `MediaOwnershipErrorFilter`, không tiết lộ URL nào tồn tại.

**Test:** `MediaOwnershipTests` ở cả hai repo — từ chối media của người khác, cho phép đúng chủ,
dọn dẹp dây chuyền, fail-closed với file legacy, chặn finalize chéo, và endpoint authorize.

---

### 4.2 — Bypass lớp lọc refresh token của Gateway `MEDIUM`

**Vị trí:** `APIGateway/API-Gateway/fakebookGateway/Gateway/GraphQlCookieResponseMiddleware.cs:21-28, 124, 167-171`

**Vấn đề:** middleware lọc refresh token khỏi response bằng cách **so khớp tên khoá JSON**. Có 3
cách qua mặt:

| Biến thể | Cách thực hiện | Vì sao lọt |
|---|---|---|
| (a) Alias | `mutation { refreshToken { rt: refreshToken } }` | Khoá trả về tên `rt`, không khớp chuỗi `refreshToken` |
| (b) Selection set rút gọn | `login(...) { refreshTokenCookie { value } }` | Object chỉ có khoá `value` nên `LooksLikeCookieInstruction` (đòi đủ 4 khoá) sai → không null hoá |
| (c) SSE | Gửi header `Accept: text/event-stream` | Dòng 21-28 thoát sớm trước khi buffer, `ProcessNode()` không bao giờ chạy |

**Tác động:** một đoạn JS chạy trên origin (XSS hoặc script bên thứ ba) lấy được refresh token sống
30 ngày, gia hạn vô hạn, sống sót qua việc đóng tab — vô hiệu hoá toàn bộ tác dụng của `HttpOnly`.
Không khai thác được cross-site vì cookie là `SameSite=Lax` + `Secure`.

**Cách đã sửa** (commit `c269496`): không vá ở tầng response mà **loại field khỏi schema công khai**.
Đánh `@internal` cho `LoginPayload.refreshToken` và `GatewayCookieInstruction.value` trong
`Gateway/schema/Authentication/schema-extensions.graphqls`, rồi recompose lại `gateway.far` và
`gateway.local.far`. Cả 3 biến thể trở thành bất khả thi thay vì phải vá từng cái.

> **Đã kiểm chứng an toàn trước khi đổi:** cookie refresh **không** được set từ body response mà
> từ header nội bộ `X-Fakebook-Refresh-Cookie-Instruction` do Auth phát ra và
> `FusionSubgraphHeaderHandler.cs:66-84` xử lý. Đường trong body chỉ là fallback. Frontend cũng chỉ
> select `accessToken`, `refreshTokenExpiresAt`, `user`. Vì vậy luồng đăng nhập không bị ảnh hưởng.
> Lớp lọc ở response được giữ lại làm phòng thủ chiều sâu.

**Test:** `GatewaySchemaTests` khẳng định hai field đã biến mất khỏi schema công khai và các field
hợp lệ vẫn còn.

---

### 4.3 — Rò rỉ privacy và block ở đường Story `MEDIUM`

**Vị trí:** `SocialGraphService/SocialGraph.Api/Service/ContentGraphService.cs` —
`IsStoryShareSourceVisible` và `GetVisibleStoryAuthorIdsAsync`

**Vấn đề 1 — Reel riêng tư bị lộ:** `IsStoryShareSourceVisible` trả về `true` **vô điều kiện** cho
Reel, rồi mới kiểm tra `privacy == 0` cho FeedPost. Reel có đủ miền privacy 0..3 và sửa được bằng
`updatePost`, nên một reel để "chỉ mình tôi" (privacy 3) hoặc "chỉ bạn bè" (privacy 2) khi được chia
sẻ vào story sẽ hiện **nguyên nội dung, media và tác giả** cho bất kỳ ai xem được story đó.

**Vấn đề 2 — Block không được áp dụng:** `GetVisibleStoryAuthorIdsAsync` trả về đơn thuần
`friends ∪ followed`, **không lọc block**. Người đã chặn bạn vẫn xuất hiện trong khay story của bạn
và ngược lại.

**Cách đã sửa** (commit `65b0667`, điều chỉnh ở `0860f13`):
- `IsStoryShareSourceVisible` áp dụng cùng một kiểm tra `privacy == 0` cho **cả** FeedPost lẫn Reel,
  đúng với hợp đồng "chỉ bài công khai và reel công khai mới chia sẻ được".
- `GetVisibleStoryAuthorIdsAsync` loại bỏ block theo **cả hai chiều** (`Blocked` và `BlockedBy`).

**Quyết định sản phẩm:** người **theo dõi** được xem story bất kể privacy hồ sơ của tác giả — privacy
hồ sơ điều phối hồ sơ, không điều phối khay story. Quy tắc cũ trong
`SocialReadModelService.CanViewTargetCoreAsync` (`isFriend || privacy == 1 && followed`, chỉ áp dụng
cho Story) đã được sửa theo cùng hướng, nên khay story và đường deep-link/`storyViewers` **luôn nhất
quán**: thấy trong khay thì mở ra được. Block vẫn là thứ duy nhất phủ quyết mọi quan hệ.

**Test:** `StoryVisibilityTests` — 11 test phủ mọi mức privacy của reel, cả hai chiều block, và từng
mức privacy của tác giả.

---

### 4.4 — Rate limit "theo IP" là một bucket toàn cục `MEDIUM`

**Vị trí:** `docker-compose.yml` — config `edge-nginx`

**Vấn đề:** edge nginx khoá theo `$binary_remote_addr` nhưng **không có `set_real_ip_from` /
`real_ip_header`**. Traffic đi qua Tailscale Serve rồi qua Docker port publisher, nên `$remote_addr`
luôn là một địa chỉ cố định (docker-proxy). Hệ quả: giới hạn 8r/s burst 40 là **dùng chung cho tất
cả mọi người** — khoảng 9 req/s từ một máy bất kỳ trong tailnet, không cần xác thực, làm đăng
nhập/đăng ký/mọi query công khai của **tất cả** người dùng trả 429.

Nặng hơn: `limit_conn fakebook_connections_per_ip 20` cũng thành toàn cục, trong khi `/graphql` giữ
subscription SSE với `proxy_read_timeout 3600s`. Khoảng **10 người dùng đồng thời** (mỗi người vài
stream SSE) là hết sạch 20 kết nối và cả hệ thống chết — **không cần kẻ tấn công nào**.

**Cách đã sửa:**
- Thêm `set_real_ip_from` cho loopback + các dải mạng Docker (`172.16.0.0/12`, `192.168.0.0/16`,
  `10.0.0.0/8`), `real_ip_header X-Forwarded-For`, `real_ip_recursive on`. **Cố ý không tin dải
  tailnet** để client không thể đẩy một entry `X-Forwarded-For` giả thành `$remote_addr`.
- Tách zone `limit_conn` riêng: `fakebook_graphql_conn_per_ip` (64, đủ cho nhiều tab × nhiều stream
  SSE) và `fakebook_upload_conn_per_ip` (16). Trước đây hai loại dùng chung một zone.
- Bổ sung header bảo mật (mục 4.5).

**Kiểm chứng:** `docker-compose config -q` hợp lệ. Máy này **không có Docker daemon** nên
**chưa chạy được `nginx -t`** — cần xác nhận lại khi deploy.

---

### 4.5 — Thiếu header bảo mật ở edge `LOW`

Toàn bộ server block của edge không có một `add_header` nào, cho phép clickjacking: trang của kẻ
tấn công nhúng iframe origin tailnet, phủ overlay trong suốt để lừa nạn nhân đang đăng nhập bấm các
hành động 1-click (xoá bài, rời nhóm).

**Cách đã sửa:** thêm `X-Frame-Options DENY`, `X-Content-Type-Options nosniff`,
`Referrer-Policy strict-origin-when-cross-origin`.

> **Chưa thêm CSP** một cách có chủ đích. `Content-Security-Policy default-src 'self'` có thể làm vỡ
> SPA (Vite dùng inline style/script), và giao diện đang được chỉnh sửa song song. CSP nên được thêm
> sau, kèm kiểm thử frontend thực tế. HSTS không cần vì TLS kết thúc ở Tailscale Serve.

---

### 4.6 — Cookie refresh token gửi tới Upload Server `LOW`

**Vị trí:** `AuthenticationService/.../Configuration/Configuration.cs:36`

**Vấn đề:** `RefreshTokenCookiePath = "/"`, trong khi edge phục vụ `/graphql`, `/api/` và `/media/`
trên **cùng một origin**. Trình duyệt vì thế gửi kèm chứng chỉ 30 ngày `fb_refresh` vào **mọi
request tải media** — hàng trăm request mỗi lần mở trang, kể cả thẻ `<img>`. Đích đến là Upload
Server: thành phần xử lý file do người dùng tải lên, tức bề mặt tấn công lớn nhất hệ thống. Bất kỳ
log truy cập nào ghi header, hay bất kỳ lỗ đọc request nào trong Upload, đều lấy được refresh token.

**Cách đã sửa** (commit `e0f7505` + `0bf6bc1`): đổi mặc định thành `/graphql` ở cả Auth và Gateway,
cùng `appsettings.example.json` và `appsettings.Development.json`. Đã kiểm chứng cookie chỉ được đọc
tại `FusionSubgraphHeaderHandler` cho request `/graphql`, và Gateway không map route nào khác.
`HttpOnly`, `Secure`, `SameSite=Lax` giữ nguyên.

> **Lưu ý triển khai:** trình duyệt vẫn đang giữ cookie cũ ở path `/`. Sau khi đổi, thao tác logout
> sẽ xoá cookie ở `/graphql`, còn bản sao `/` cũ nằm lại phía client tới khi hết hạn. Nó vô hại vì
> logout đã thu hồi phiên phía server, nhưng **nên bắt đăng xuất toàn bộ phiên một lần sau khi
> triển khai**.

---

### 4.7 — Khoá tài khoản nạn nhân từ xa `MEDIUM`

**Vị trí:** `AuthenticationService/.../Repositories/Repositories.cs:1174-1196` ·
`APIGateway/.../Gateway/FusionSubgraphHeaderHandler.cs`

**Vấn đề:** Auth lấy IP từ `HttpContext.Connection.RemoteIpAddress` nhưng không gọi
`UseForwardedHeaders`, và Gateway **không** forward `X-Forwarded-For` xuống subgraph. Nên IP mà Auth
thấy **luôn là IP container gateway**. Điều kiện `ip_address = CAST(@IpAddress AS inet)` trong
`CountRecentLoginFailuresAsync` vì thế luôn đúng, khiến bộ đếm rate limit thực chất **chỉ phân vùng
theo email**.

Kẻ tấn công gọi `login('victim@x.com', 'sai')` 5 lần là nạn nhân nhận `LOGIN_RATE_LIMITED` **kể cả
khi gõ đúng mật khẩu**. Cửa sổ chỉ reset khi có `LOGIN_SUCCESS`, mà nạn nhân thì không thể thành
công — nên không tự phục hồi. Lặp 5 request mỗi 15 phút = khoá vĩnh viễn.

Cùng gốc nguyên nhân còn làm `mySessions` hiển thị IP container `172.x` và `deviceName`/`os`/
`browser` đều null cho **mọi** phiên (User-Agent cũng không được forward) — tính năng "Nơi bạn đã
đăng nhập" vô dụng, nạn nhân bị chiếm tài khoản không thể nhận ra phiên lạ.

**Cách đã sửa** (commit `2022c91` + `75aaedf`):
- Gateway phát **một** entry `X-Forwarded-For` duy nhất lấy từ địa chỉ chính nó đã phân giải, cùng
  `User-Agent` của trình duyệt. Cả hai header do client gửi lên đều bị xoá trước, nên không giả mạo được.
- Auth bật `UseForwardedHeaders` với `ForwardLimit = 1`, chỉ tin loopback và các dải mạng riêng —
  **cố ý không tin dải tailnet**.

Bộ đếm giờ phân vùng theo (identifier, IP thật): kẻ tấn công ở IP A không khoá được nạn nhân ở IP B.

### 4.8 — Liệt kê tài khoản `MEDIUM`

**Vị trí:** `AuthenticationService/.../Services/AuthService.cs`

Ba endpoint không cần xác thực đều cho biết một địa chỉ có tồn tại hay không:

| Endpoint | Rò rỉ thế nào |
|---|---|
| `login` | Kiểm tra **trạng thái tài khoản trước khi verify mật khẩu**, nên một request với mật khẩu bất kỳ đã phân biệt được "đã đăng ký nhưng chưa xác minh" / "bị khoá" với "không tồn tại" |
| `resendEmailVerification` | Trả về `ACCOUNT_NOT_FOUND`, "Email is already verified" và `ACCOUNT_UNAVAILABLE` — ba kết quả phân biệt được |
| `requestPasswordReset` | Thông điệp đã chung chung, nhưng lỗi `OTP_COOLDOWN` / `OTP_RESEND_RATE_LIMITED` vẫn thoát ra, mà throttling chỉ kích hoạt cho tài khoản thật |

Ngoài ra lời gọi SMTP của `requestPasswordReset` nằm **ngoài** `try/catch`, nên mail server hỏng sẽ
trả lỗi máy chủ về client — và vì chỉ gửi mail cho tài khoản thật, chính lỗi đó xác nhận địa chỉ tồn tại.

**Cách đã sửa** (commit `9998529`):
- `login`: chuyển kiểm tra trạng thái xuống **sau** khi verify mật khẩu. Người dùng thật vẫn nhận
  `EMAIL_UNVERIFIED` nên **màn hình nhập OTP của SPA hoạt động y như cũ** (`LoginPage.tsx:31`).
- `resendEmailVerification`: một phản hồi duy nhất cho mọi trường hợp.
- `requestPasswordReset`: gộp lỗi throttling vào cùng phản hồi chung.
- Cả hai luồng OTP: gửi mail bọc trong guard, thất bại chỉ ghi log.

### 4.9 — Identifier không giới hạn ghi vào audit log `LOW`

**Vị trí:** `AuthenticationService/.../Services/AuthService.cs` — `LoginAsync`

`LoginAsync` chỉ chuẩn hoá và kiểm `IsNullOrWhiteSpace`, **không validate định dạng hay độ dài**.
Mỗi lần thất bại ghi một dòng jsonb chứa nguyên chuỗi đó vào `auth.id_audit_log`, trên DB **dùng
chung cho toàn hệ thống**, và không có chính sách retention nào. Kẻ tấn công ẩn danh làm phình DB
vĩnh viễn; với identifier lớn hơn ~2704 byte còn làm vỡ index btree khiến exception thoát ra thành
lỗi máy chủ.

**Cách đã sửa** (commit `9998529`): validate định dạng email và cắt ở 254 ký tự (RFC 5321) ngay đầu
`LoginAsync`, **trước mọi truy cập DB**. Chuỗi có khoảng trắng bị từ chối tường minh vì
`EmailAddressAttribute` của .NET chấp nhận chúng.

---

## 4b. Hoàn thiện API và CI

**Hai API chặn frontend đã được bổ sung** (commit `ddc5dbf` + `9e67ee3`):

1. **Deep-link thông báo trên bình luận.** Thông báo LIKE/MENTION mang `objectId` = id của **bình
   luận**, nhưng `postDetail` lọc `otype` về FeedPost/GroupPost/Reel nên trả null → màn hình
   "Content unavailable". `GetPostDetailAsync` giờ tự giải bình luận lên bài viết chứa nó (đi ngược
   chuỗi trả lời, giới hạn độ sâu 20 như các kiểm tra visibility). **Frontend không cần đổi gì.**
2. **`updateComment`** — mutation sửa bình luận, dùng chung `RequireContentAuthorAsync` với
   `updatePost`, xử lý nội dung, đồng bộ lại mention và thay media (tri-state: giữ / thay / xoá),
   chịu cùng kiểm tra quyền sở hữu media như mọi URL client gửi lên.

SDL của SocialGraph đã export lại và **cả hai Fusion archive đã recompose**.

**CI đã bật cho cả 10 repo** (commit `e7b9afa`, `69c4ae2`, `c09dd72`, `fd7676f`, `e3c9894`,
`3ff3050`, `f1753ec`, `1ada88f`, `b2ba13e`, `48ae626`): chạy test trên push và pull request. Với 2
repo có publish Docker image, job build/push giờ **phụ thuộc vào job test** — trước đây image vẫn
được push kể cả khi test đỏ.

Phát hiện kèm theo: `NotificationService.Tests` **không nằm trong** `NotificationService.sln`, nên
`dotnet test` ở mức solution im lặng không chạy 24 test đó. Đã thêm vào solution (commit `fd7676f`).

---

## 5. Việc cần làm thủ công

### 5.1 — Đổi mật khẩu PostgreSQL `MEDIUM` (chưa làm)

`DB_PASSWORD` trong `.env` hiện dài **9 ký tự** — quá yếu cho một cổng Postgres mở trên tailnet.
Tệ hơn, anchor `*postgres-base` trong `docker-compose.yml:7-12` định nghĩa **duy nhất một** cặp
`DB_USER`/`DB_PASSWORD` và mọi service chỉ đổi `Search Path`. `Search Path` **không phải ranh giới
bảo mật**: bất kỳ ai vào được tailnet hoặc chiếm được **bất kỳ container nào** (đọc
`/proc/self/environ` là ra ngay) đều `SELECT` thẳng được `auth.id_credential`, `auth.id_verification`,
`auth.id_session` của toàn hệ thống.

**Chưa tự động thực hiện** vì việc này đòi hỏi đổi đồng thời trên PostgreSQL server bên ngoài (ngoài
phạm vi repo), và README ghi rõ các giá trị `.env` đã cấp không được tự ý sửa. Cần thực hiện thủ công:

1. Đổi `DB_PASSWORD` sang chuỗi ngẫu nhiên 32 byte, đồng bộ trên server PostgreSQL và `.env`.
2. Tạo role PostgreSQL riêng cho từng service + `REVOKE ALL ON SCHEMA <schema> FROM PUBLIC`, mỗi
   service chỉ `GRANT` trên schema của mình. Đây là thay đổi phòng thủ chiều sâu có giá trị lớn nhất
   của cả hệ thống.
3. Bỏ việc nhúng cặp credential dùng chung vào mọi container qua anchor.

### 5.2 — Đăng xuất toàn bộ phiên sau khi triển khai

Xem lưu ý ở mục 4.6.

### 5.3 — Chạy `nginx -t` và smoke test khi deploy

Máy phát triển không có Docker daemon nên chưa kiểm chứng được cú pháp nginx lúc chạy thật, và chưa
chạy được smoke test đăng nhập đầu-cuối. Cần xác nhận khi triển khai:
- `nginx -t` trong container edge.
- Đăng nhập → cookie `fb_refresh` được set với `Path=/graphql` → `refreshToken` mutation hoạt động.
- Đổi avatar bằng ảnh của chính mình vẫn thành công; đổi bằng URL ảnh người khác trả `FORBIDDEN`.

---

## 6. Các tuyên bố trong README không đúng với mã nguồn

Kiểm chứng phát hiện **11 tuyên bố sai lệch**. Đáng chú ý nhất:

1. *"Ngoại lệ Payment→Auth gọi GraphQL `me { userId }` để validate session"* — **sai**. Chỉ Upload
   làm vậy (`Upload-Server/Program.cs:198`). Payment gọi `paymentPremiumState(userId)` và xác thực
   bằng `X-Payment-Secret`; danh tính người dùng lấy từ header `X-User-Id` do gateway gán.
2. *"Các thao tác theo viewer yêu cầu `X-Internal-SocialGraphService-Secret`; `X-Gateway-Secret` chỉ
   là alias tương thích"* — **ngược lại hoàn toàn**: `TrustedCallerAccessor.cs:32` **chỉ** chấp nhận
   `X-Gateway-Secret`.
3. *"Block luôn thắng"* — không áp dụng ở tag/mention, mọi danh sách người dùng
   (`likedUsers`/`taggedUsers`/`mentionedUsers`/`groupMembers`/`groupAdmins`/`storyViewers`), bình
   luận, và share source trong story. **Phần story đã vá**, phần còn lại chưa (mục #9).
4. *"Service→Service HMAC chống replay bằng nonce dùng 1 lần"* — nonce chỉ nằm trong RAM tiến trình
   (`InternalRequestSigning.cs:152`), mất sau restart và không chia sẻ giữa replica;
   `RequireSignature` mặc định `false`.
5. *"Gateway rate-limit `/graphql` theo IP"* — có đăng ký policy nhưng mọi client chia chung một
   bucket (mục 4.4). **Phần edge đã vá**; phân vùng phía Gateway (`ForwardLimit=1`) vẫn cần xem lại.
6. `README.md:238` ghi `~68 query, ~78 mutation` — số thật là **70 query / 81 mutation /
   4 subscription** công khai.

---

## 7. Kiểm chứng

Toàn bộ test chạy sau khi vá:

| Repo | Kết quả |
|---|---|
| SocialGraphService | **194/194 pass** (175 gốc + 11 story + 8 comment API) |
| Upload Server | **19/19 pass** (12 gốc + 7 ownership) |
| API Gateway | **32/32 pass** (kèm assertion schema + forwarded header) |
| Authentication | **23/23 pass** (kèm cookie scope + identifier hardening) |
| MessengerService | **61/61 pass** |
| NotificationService | **24/24 pass** (trước đây bị solution bỏ sót) |
| PaymentService | **35/35 pass** (trừ 4 class Testcontainers cần Docker — sẽ chạy trên CI) |
| SearchService | **34/34 pass** |
| RecommendationService | **52/52 pass** (pytest) |
| Frontend | **287/287 pass** (46 file, vitest) + `npm run build` sạch |
| `docker-compose config -q` | hợp lệ |

Build sạch (0 error) trên cả 8 project .NET.

Lưu ý lint frontend: `ProfilePage.tsx` có **2 lỗi ESLint sẵn có** —
`react-hooks/rules-of-hooks` báo `useAsProfileImage` gọi trong callback. Đây là **báo nhầm**: hàm đó
là `async function` xử lý sự kiện thường (dòng 842), rule chỉ kích hoạt vì tên bắt đầu bằng `use`.
Đổi tên hàm (ví dụ `applyAsProfileImage`) là hết cả hai. CI vẫn chạy lint nhưng chưa chặn build; nên
bật chặn sau khi đổi tên.

---

## 8. Lịch sử commit

Mỗi repo có một commit **baseline** ghi lại phần công việc ký HMAC nội bộ + hardening đã hoàn thành
nhưng chưa commit từ trước, để các bản vá bảo mật nằm tách bạch ở commit riêng.

| Repo | Baseline | Bản vá bảo mật | Khác |
|---|---|---|---|
| Upload Server | `ea53ec7` | `9cb4758` owner-scoped media, `3044467` gitignore | `69c4ae2` CI |
| SocialGraph | `77921c7` | `cbd6484` media ownership, `65b0667` story privacy/block, `0860f13` điều chỉnh story | `ddc5dbf` comment API, `e7b9afa` CI |
| API Gateway | `9565eec` | `c269496` @internal refresh token, `0bf6bc1` cookie path, `2022c91` forwarded headers | `9e67ee3` publish updateComment, `b2ba13e` CI |
| Authentication | `8c55807` | `e0f7505` cookie path, `75aaedf` forwarded headers, `9998529` enumeration + identifier | `48ae626` CI |
| Messenger | `fb6e83f` | — | `c09dd72` CI |
| Notification | `c5eb31d` | — | `fd7676f` CI + thêm test project vào solution |
| Payment | `e422463` | — | `e3c9894` CI |
| Search | `56c5cb8` | — | `3ff3050` CI |
| Recommendation | `5c06094` | — | `f1753ec` CI |
| Frontend | — | `ad1af47` bão reconnect SSE | `1ada88f` CI |
| **Workspace** *(mới)* | — | — | `c8e8fdd` khởi tạo repo, `582ce91` secure.md |

Bổ sung sau đó: `16bdd46` (Gateway — watchdog phiên cho SSE), `b71249c` (SocialGraph — ghim EF Core),
`e2a5d41` (Recommendation — ghim Python), `ec39c11` (Notification — bỏ track `obj/`).

Toàn bộ đã push lên `origin/main` của từng repo. **Cả 11 repo hiện sạch, không còn thay đổi chưa
commit.**

### Repo workspace

`D:\Fakebook` trước đây chỉ có thư mục `.git` **rỗng** nên root không phải git repo hợp lệ và mọi
lệnh git tại đó đều fail — `docker-compose.yml` (492 dòng), toàn bộ `scripts/`, `docs/`, `README.md`,
`.env.example` và chính file này đều nằm ngoài version control. Mất máy là mất toàn bộ tầng điều phối
trong khi 10 service vẫn an toàn trong repo riêng.

Đã tạo repo **private** `github.com/fakebook-works/fakebook-workspace` chứa 31 file đó. Thư mục 10
service được ignore để hai lịch sử không trộn vào nhau, cùng với `.env`, `.run/`, `.tools/`, seed
receipt và build output. `scripts/check-secrets.ps1` xác nhận **không có secret nào lọt vào file
được track**.

Kèm theo `services.manifest.json` + `scripts/update-manifest.ps1` ghi remote/branch/commit của cả 10
service — đây là thứ cho phép ghép một bản `docker-compose.yml` với đúng các build đã được kiểm
chứng cùng nó. Script cảnh báo khi service còn thay đổi chưa commit, vì khi đó commit id ghi lại
không mô tả đúng thứ đang chạy.

> Repo để **private** có chủ đích: file này mô tả chi tiết các lỗ hổng **chưa vá** kèm `file:line`.
> Nếu sau này muốn chuyển sang public, phải tách `secure.md` ra khỏi repo trước.

---

## 9. Các lỗ hổng còn lại và thứ tự đề xuất

**Ưu tiên tiếp theo (Medium):**

- **#8 Thu hồi phiên với SSE** — "Đăng xuất tất cả thiết bị" không cắt được subscription đang mở:
  `GraphQlCookieResponseMiddleware` cho request `text/event-stream` đi thẳng qua, edge giữ kết nối
  `proxy_read_timeout 3600s`, và subgraph Messaging/Notification chỉ nhận `X-User-Id` một lần lúc
  thiết lập. *Sửa:* kiểm tra lại phiên định kỳ 30-60s cho stream đang mở và huỷ
  `CancellationTokenSource`, hoặc đẩy sự kiện invalidate xuống Gateway khi Auth thu hồi phiên.
- **#9 Block ở các đường đọc còn lại** — `GetAssociatedUsersAsync` (dùng chung cho `likedUsers`/
  `taggedUsers`/`mentionedUsers`/`groupMembers`/`groupAdmins`/`storyViewers`), tag/mention lúc tạo
  nội dung (vẫn gửi thông báo tới người đã chặn mình), và `GetCommentsAsync`.

**Gốc rễ cần xử lý:** quy tắc privacy 0/1/2/3 + block đang được **cài lại 3 lần ở 3 nơi**. Chính sự
nhân bản này sinh ra lỗ #3 và #9. Nên gom thành một "visibility kernel" duy nhất dạng
`CanView(viewerId, objectId[])` và cho mọi đường đọc gọi vào đó.

**Ưu tiên thấp:** #11 (JWT HS256 dùng chung khoá → chuyển RS256/EdDSA), #12 (nonce sang Redis,
`RequireSignature` mặc định true), #13 (tách hàng đợi BCrypt register/login), #15 (thêm
`absolute_expires_at` cho phiên). Còn lại từ mục #14: **retention cho `auth.id_audit_log`** — phần
validate độ dài đã xong, nhưng bảng vẫn chỉ INSERT và không bao giờ được dọn.

**Ngoài bảo mật, các mục ưu tiên cao từ báo cáo audit chưa làm:** 3 lệnh index của SocialGraph
(`associations` thiếu index chứa cột `time`, `idx_associations` trùng khít PRIMARY KEY, `objects`
thiếu index trên `otype`), migration baseline cho `objects`/`associations` (DDL hiện chỉ nằm trong
markdown), retention cho bảng `notification`, và đưa tầng điều phối vào git.
