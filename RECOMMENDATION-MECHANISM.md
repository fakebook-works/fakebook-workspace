# Cơ chế Recommendation của Fakebook

## 1. Phạm vi và mục tiêu

Tài liệu này mô tả cơ chế recommendation hiện được triển khai xuyên suốt bốn thành phần:

- SocialGraph tạo tập ứng viên hợp lệ và metadata phục vụ xếp hạng.
- Recommendation tạo embedding, học sở thích, xếp hạng và quản lý trạng thái phiên/đã xem.
- Gateway giữ ranh giới tin cậy, compose GraphQL và bảo toàn Snowflake ID.
- Frontend duy trì phiên phân trang và chỉ ghi impression khi nội dung thực sự được nhìn thấy.

Đây là một bộ xếp hạng nhiều tầng phù hợp với kiến trúc và dữ liệu hiện tại của Fakebook. Nó áp dụng các nguyên lý thường dùng ở mạng xã hội lớn như candidate sourcing, semantic relevance, freshness, exploration, diversity, seen suppression và impression reranking; không tuyên bố sao chép thuật toán độc quyền của Facebook.

## 2. Luồng tổng thể

~~~text
Browser
  -> Gateway GraphQL (xác thực phiên, không tin userId từ input)
  -> Recommendation (lấy tối đa 500 candidate metadata qua signed internal REST)
  -> SocialGraph (privacy/block/group-membership candidate filter)
  -> Recommendation (score + diversity + snapshot phiên)
  -> Gateway/Fusion
  -> SocialGraph rehydrate theo quyền hiện tại
  -> Frontend hiển thị các phần tử còn xem được

Frontend thấy nội dung >= 50% trong >= 800 ms
  -> Gateway GraphQL
  -> SocialGraph kiểm quyền lại theo trusted viewer
  -> transactional outbox
  -> signed internal REST
  -> Recommendation ghi impression/seen idempotent
~~~

Recommendation không phải nguồn sự thật về privacy. Nó chỉ trả ID đã xếp hạng; bước hydrate cuối ở SocialGraph luôn có quyền loại bỏ nội dung vừa đổi privacy, bị xoá, bị block hoặc không còn đủ điều kiện xem.

## 3. Dữ liệu nguồn từ SocialGraph

Không thêm trường canonical mới vào FeedPost/Reel. Candidate metadata được chiếu từ dữ liệu đã tồn tại:

- `authorId`: association tác giả của object.
- `source`: `self`, `friend`, `followed`, `group_member`, `public`, `public_group` hoặc `recent_public`.
- `createdAt`: trường thời gian hiện có trong data của object.
- `contentType`: loại FeedPost/Reel.
- `groupId`: association bài đăng thuộc nhóm, nếu có.
- privacy, block, friend/follow và Member/Admin: lấy từ object/association hiện hành.

Cách này tránh duplicate dữ liệu nghiệp vụ trong Recommendation và bảo đảm khi tên, quan hệ, privacy hoặc trạng thái nhóm thay đổi thì SocialGraph vẫn là nơi quyết định cuối cùng.

## 4. Candidate generation

### 4.1 Bảng feed

SocialGraph tạo nhiều nguồn rồi trộn theo lịch có tỷ lệ mục tiêu:

| Nguồn | Tỷ lệ mục tiêu |
| --- | ---: |
| Nội dung của chính người xem | 10% |
| Bạn bè | 20% |
| Người đang theo dõi | 20% |
| Nhóm đã tham gia/quản lý | 20% |
| Feed công khai gần đây | 20% |
| Nhóm công khai | 10% |

Nếu một nguồn không đủ phần tử, slot được chuyển tuần tự cho nguồn còn dữ liệu; feed không bị rút ngắn chỉ vì thiếu một nguồn.

### 4.2 Thước phim

- `FOR_YOU`: khoảng 10% self, 30% bạn bè, 30% đang theo dõi, 30% khám phá công khai.
- `FOLLOWING`: chỉ lấy reel của bạn bè và người đang theo dõi; không trộn reel công khai ngoài quan hệ.

### 4.3 Chống một tác giả chiếm feed

- Quan hệ của viewer được đọc theo snapshot bounded thay vì gọi lặp theo từng loại.
- Nội dung mới theo tác giả được lấy bằng indexed `LATERAL` query có giới hạn mỗi tác giả.
- Mỗi nguồn được round-robin theo tác giả trước khi trộn nguồn.
- Public discovery chỉ quét một cửa sổ mới nhất có hard cap, sau đó ưu tiên một lượng nhỏ từ mỗi tác giả.
- Các query có policy-overfetch bounded để bài mới nhưng không đủ quyền không che mất toàn bộ bài hợp lệ cũ hơn.

Nhờ vậy candidate generation không phải N+1, không scan toàn bộ lịch sử và không để một tài khoản đăng dày đặc lấn át mọi tài khoản khác.

## 5. Embedding và học sở thích

### 5.1 Content embedding

Mỗi nội dung có vector 512 chiều:

- Văn bản: `clip-ViT-B-32-multilingual-v1`.
- Ảnh và frame video: `clip-ViT-B-32`.
- Có cả chữ và media: `0.6 * text + 0.4 * media`, sau đó chuẩn hoá.
- Video lấy frame theo khoảng thời gian và có giới hạn số frame, dung lượng, pixel, timeout.

Media fetch giữ các lớp chống SSRF hiện có: chỉ HTTP(S), kiểm DNS/IP, chặn loopback/link-local/cloud metadata, allowlist cho host nội bộ được vận hành kiểm soát, tắt redirect và giới hạn số byte.

### 5.2 User embedding và interaction

User mới được provision vector cold-start deterministic. Mỗi interaction cập nhật vector theo bước EMA có dấu và chuẩn hoá lại:

~~~text
candidate = (1 - abs(weight)) * current + weight * target
user_embedding = normalize(candidate)
~~~

Trọng số hiện hành:

| Interaction | Weight |
| --- | ---: |
| LIKE | +0.25 |
| UNLIKE | -0.15 |
| SAVE | +0.35 |
| UNSAVE | -0.20 |
| WATCH | +0.08 |
| SHARE | +0.40 |
| COMMENT | +0.20 |

Interaction được ghi idempotent. Update cùng user và cùng target được tuần tự hoá bằng PostgreSQL advisory transaction lock để tránh mất update hoặc đua với xoá projection.

## 6. Công thức xếp hạng

Với mỗi candidate:

~~~text
semantic    = cosine(user_embedding, content_embedding)
freshness   = exp(-ln(2) * age_hours / half_life_hours)
affinity    = điểm theo nguồn
exploration = 1 nếu candidate nằm trong epsilon của phiên, ngược lại 0
penalty     = min(0.5, prior_impression_count * impression_penalty)

score = 0.58 * semantic
      + 0.20 * freshness
      + 0.10 * affinity
      + 0.12 * exploration
      - penalty
~~~

Mặc định `half_life_hours = 72`, nghĩa là sau 72 giờ freshness còn đúng 0.5.

Affinity mặc định:

- friend/followed/group member/admin: `1.0`.
- self: `0.8`.
- public/public group/discovery: `0.35`.
- metadata legacy `group`: `0.65` trong thời gian tương thích chuyển tiếp.

Exploration dùng SHA-256 của `session seed + candidate ID`, tỷ lệ mặc định 12%. Vì vậy nó tạo độ khám phá nhưng vẫn deterministic trong cùng phiên, không làm trang hai đổi thứ tự vì random lại.

## 7. Diversity, quota và seen suppression

Sau khi sort score:

1. Candidate chưa xem trong TTL được đưa lên trước.
2. Candidate đã xem vẫn được giữ ở cuối để feed không bị cụt.
3. Mỗi nhóm unseen và seen được rerank riêng theo quota.
4. Mặc định ưu tiên tối đa 3 nội dung/tác giả và 4 nội dung/nhóm trước khi phần bị hoãn được nối lại.

Quota là ưu tiên diversity, không phải bộ lọc cứng. Nếu nguồn còn lại không đủ, phần bị hoãn vẫn được trả về.

Impression phát sinh trong chính phiên hiện tại không loại phần tử khỏi các trang sau. Chỉ trạng thái seen trước `session_started` mới được suppression, nhờ đó offset pagination không tự phá sau khi trang một được nhìn thấy.

## 8. Phiên recommendation ổn định

Frontend tạo `sessionKey` riêng cho mỗi vòng feed/reel. Server:

- validate key, tối đa 128 ký tự và cấm control character;
- hash `viewer + mode + key`, không lưu raw key;
- giữ tối đa 20 phiên/viewer;
- mỗi phiên có sliding expiry 2 giờ;
- lấy một candidate pool cố định tối đa 500 phần tử;
- lưu `ranked_ids BIGINT[]` tối đa 500 ID sau lần rank đầu.

Các trang tiếp theo đọc cùng snapshot thay vì mở rộng/chấm lại candidate pool. Điều này loại duplicate, omission và nhảy thứ tự do thời gian, vector hoặc candidate mới thay đổi giữa các request.

Snapshot chỉ chứa ID, không chứa nội dung, score, tên hay privacy. Mỗi lần hydrate vẫn kiểm quyền hiện tại ở SocialGraph. Frontend dùng raw offset và tự bù các ID hydrate thành `null`: tối đa 4 raw page cho một lần tải, hard ceiling 50 raw page trong một phiên để không tạo vòng lặp vô hạn.

## 9. Impression-based reranking

### 9.1 Điều kiện ghi ở frontend

- Element giao ít nhất 50% viewport.
- Duy trì ít nhất 800 ms.
- Không tính tab ẩn, prefetch hoặc lướt qua nhanh.
- Một session/target chỉ queue một lần ở client.
- Batch tối đa 50; retry client tối đa một lần.
- Queue gắn với generation của tài khoản đang đăng nhập và bị xoá ngay khi logout/đổi tài khoản, kể cả race với request đang chạy.

Viewer ID không được gửi từ browser trong impression input. Gateway/SocialGraph lấy viewer từ trusted authenticated context.

### 9.2 Kiểm quyền và giao sự kiện

SocialGraph:

- parse `targetId` dưới GraphQL `ID!`, giữ nguyên Snowflake lớn hơn giới hạn an toàn của JavaScript Number;
- giới hạn batch/metric/key;
- hydrate hàng loạt bằng chính viewer hiện tại;
- kiểm lại privacy, membership và block hai chiều;
- im lặng bỏ ID không nhìn thấy để mutation không thành existence oracle;
- lấy thời gian tin cậy từ database;
- tạo storage idempotency key theo viewer/target/bucket UTC 5 phút;
- đưa event vào transactional outbox.

Outbox gửi signed internal request đến Recommendation. `occurredAt` được giữ nguyên qua retry; Recommendation yêu cầu timezone, chỉ cho lệch tương lai tối đa 5 phút và không nhận event ngoài retention 90 ngày.

Nếu projection user chưa đến Recommendation, endpoint trả trạng thái retryable `425` thay vì ACK rồi làm mất impression. Nó không tự tạo user từ impression, nên một event cũ retry sau user-delete không thể tái tạo derived state.

### 9.3 Dữ liệu dùng để rerank

- `recommendation_impressions`: ledger idempotent, dwell/completion và thời điểm quan sát.
- `recommendation_seen`: chỉ giữ `last_seen_at` mới nhất theo viewer/content.
- Score trừ mặc định `0.06` cho mỗi impression trước phiên, cap tổng penalty `0.5`.
- Seen/impression query chỉ đọc candidate của request và chỉ trong TTL.

## 10. Privacy, block và an toàn dữ liệu

Recommendation có nhiều lớp nhưng không thay thế authorization:

1. Candidate source ở SocialGraph lọc privacy/quan hệ/group/block.
2. Impression mutation kiểm quyền lại bằng trusted viewer.
3. Hydration cuối kiểm quyền lần nữa trước khi dữ liệu đến browser.
4. ID biến mất giữa các bước được coi là unavailable, không làm lộ lý do.

Các đường nội bộ reuse request signing, timestamp/nonce/replay protection và secret theo service hiện có. Không có browser-to-Recommendation REST shortcut và không lấy actor từ input `userId` không tin cậy.

Input được giới hạn: candidate tối đa 500, GraphQL page tối đa 100, impression batch tối đa 50, dwell tối đa 15 phút, ID là positive signed 64-bit, idempotency/session key có giới hạn độ dài.

Database/runtime fail closed khi advanced ranker bật: thiếu table/index/privilege hoặc lỗi đọc/ghi session/exposure trả `SERVICE_UNAVAILABLE`, không âm thầm trả một feed có state sai.

## 11. Xoá dữ liệu, race và retention

### 11.1 Xoá user/content

- Xoá user dọn interactions, impressions, seen, feed sessions và user embedding.
- Xoá content dọn interactions, impressions, seen và post embedding.
- Upsert/delete embedding, interaction và impression dùng advisory lock theo user/target với thứ tự ổn định.
- Impression chỉ nhận target vẫn có embedding; target đã xoá bị bỏ, không tạo orphan exposure.

### 11.2 Retention

- Impression ledger: 90 ngày.
- Seen state: 90 ngày; TTL dùng để suppression mặc định 30 ngày.
- Feed session: hết hạn sau 2 giờ không được resolve tiếp.
- Cleanup chạy định kỳ toàn cục, không phụ thuộc user còn hoạt động.
- Mỗi SQL delete có batch cap và index timestamp.
- Một chu kỳ có giới hạn batch và time budget, dùng non-blocking global advisory lock để nhiều instance không cùng quét một batch.

Default vận hành:

| Biến | Giá trị |
| --- | ---: |
| `RECOMMENDATION_RETENTION_CLEANUP_INTERVAL_SECONDS` | 3600 |
| `RECOMMENDATION_RETENTION_CLEANUP_BATCH_SIZE` | 1000 |
| `RECOMMENDATION_RETENTION_CLEANUP_MAX_BATCHES` | 10 |
| `RECOMMENDATION_RETENTION_CLEANUP_TIME_BUDGET_SECONDS` | 30 |

## 12. Schema và migration

Sáu owner migration của Recommendation:

1. `user_embedding.sql`
2. `post_embedding.sql`
3. `recommendation_interactions.sql`
4. `recommendation_impressions.sql`
5. `recommendation_seen.sql`
6. `recommendation_feed_sessions.sql`

Runtime production không cần quyền `CREATE` schema/table. Migration chạy bằng owner role; runtime role chỉ có `USAGE` và DML cần thiết. Readiness kiểm tra table, column, primary key, exact secondary-index shape và DML privilege để bắt schema drift thay vì chạy với cấu trúc gần giống nhưng sai.

## 13. Feature flags và rollback

Các flag độc lập:

- `RECOMMENDATION_ADVANCED_RANKING_ENABLED`
- `RECOMMENDATION_EXPLORATION_ENABLED`
- `RECOMMENDATION_FRESHNESS_ENABLED`
- `RECOMMENDATION_DIVERSITY_ENABLED`
- `RECOMMENDATION_SEEN_SUPPRESSION_ENABLED`
- `RECOMMENDATION_IMPRESSION_RERANKING_ENABLED`

Khi master flag tắt, Recommendation quay về semantic cosine legacy và không sử dụng session/seen/diversity/impression state trong đường rank. Các trọng số, half-life, quota, TTL và penalty đều có environment variable bounded để rollout/tuning không cần sửa code.

## 14. Bằng chứng kiểm thử

Các lớp test bao phủ:

- Công thức freshness đúng half-life, deterministic exploration và source affinity.
- Author/group quota, unseen-before-seen và không làm feed ngắn.
- Snapshot ổn định qua candidate/vector/time thay đổi, phân trang không duplicate.
- Session expiry/reset/cap/delete-user và fail-closed khi DB lỗi.
- Impression validation, idempotency, trusted time, target/user race và retention cleanup.
- Candidate source ratio, privacy, block, self, public group và FOLLOWING-only reels.
- Snowflake `ID!` xuyên Frontend -> Gateway -> SocialGraph.
- Visibility observer, hidden tab, batching, retry, account switch và null-hydration backfill.
- API security contracts, schema composition, frontend build/lint/audit.

Số test cuối cùng và giới hạn kiểm chứng được ghi trong phần bàn giao của thay đổi. Máy phát triển không có Docker, nên test Payment Testcontainers và raw PostgreSQL production-query integration không được tuyên bố là đã chạy; unit/contract/build và compose validation được chạy độc lập.

## 15. Giới hạn có chủ đích và hướng phát triển

Implementation hiện tại là heuristic + embedding online, chưa phải mô hình learning-to-rank được huấn luyện từ hàng triệu nhãn. Các bước nâng cấp hợp lý khi có đủ traffic/telemetry:

- A/B test và calibration trọng số theo cohort.
- Negative feedback riêng cho hide/not-interested/report.
- Dwell/completion-derived preference update có guard chống gaming.
- Multi-objective ranking cho quality, integrity và creator fairness.
- Offline evaluation dataset, NDCG/Recall@K/diversity metrics và drift monitoring.

Những bước này phải tiếp tục giữ nguyên nguyên tắc: SocialGraph quyết quyền, browser không tự khai actor, event nội bộ signed/idempotent, và hydration cuối luôn kiểm privacy/block hiện tại.
