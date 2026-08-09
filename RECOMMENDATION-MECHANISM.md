# Cơ chế Recommendation của Fakebook

## 1. Mục tiêu và ranh giới trách nhiệm

Fakebook dùng một pipeline nhiều tầng, kết hợp candidate generation, vector ngữ nghĩa,
tín hiệu sở thích có time decay, freshness, exploration, social affinity, seen suppression,
impression reranking và diversity quota. Đây là thiết kế phù hợp với dữ liệu hiện có của
Fakebook; không phải bản sao hay tuyên bố tái tạo thuật toán độc quyền của Facebook.

Ranh giới trách nhiệm luôn được giữ nguyên:

- SocialGraph là nguồn sự thật về post/reel, tác giả, nhóm, privacy, membership và block.
- Recommendation chỉ xếp hạng tập candidate đã được SocialGraph cho phép; nó không tự cấp quyền xem.
- Gateway là đường GraphQL duy nhất cho browser và giữ nguyên Snowflake ID dưới dạng `ID`/chuỗi.
- Frontend chỉ đo hành vi hiển thị/phát thực tế; browser không được tự khai viewer, ownership hay policy.
- Trước khi trả nội dung cho browser, SocialGraph hydrate và kiểm quyền hiện tại một lần nữa.

Vì vậy, nếu privacy, membership, block hoặc trạng thái xoá thay đổi sau khi một ID đã lọt vào
snapshot Recommendation, bước hydrate cuối vẫn loại bỏ ID đó.

## 2. Luồng tổng thể

~~~text
Browser
  -> Gateway GraphQL (viewer lấy từ phiên xác thực)
  -> Recommendation
  -> signed internal REST lấy candidate metadata từ SocialGraph
  -> vector score + freshness + affinity + exploration + exposure penalty
  -> seen suppression + author/group/content-family diversity
  -> snapshot ID ổn định theo session
  -> Gateway/Fusion
  -> SocialGraph hydrate và kiểm privacy/block/membership hiện tại
  -> Browser

Viewport/video telemetry
  -> Gateway GraphQL
  -> SocialGraph rehydrate theo trusted viewer
  -> phân loại POST / VIDEO_POST / REEL ở server
  -> transactional outbox
  -> signed, nonce-protected internal REST
  -> Recommendation semantic aggregation + seen + interest signals
~~~

## 3. Candidate generation ở SocialGraph

SocialGraph chiếu metadata xếp hạng từ dữ liệu canonical sẵn có, không nhân đôi các trường
nghiệp vụ sang Recommendation:

- `contentId`, `authorId`, `createdAt`, `contentType`, `groupId`;
- `source`: self, friend, followed, group member, public hoặc public-group discovery;
- privacy của post/reel hoặc privacy của group;
- quan hệ friend/follow, block hai chiều và membership/admin hiện tại.

Feed lấy candidate từ nhiều nguồn: nội dung của chính viewer, bạn bè, người đang theo dõi,
nhóm đã tham gia/quản lý, feed công khai gần đây và nhóm công khai. Mỗi nguồn và mỗi tác giả
đều có hard cap; query dùng indexed bounded window và policy over-fetch có giới hạn. Thiếu một
nguồn không làm feed ngắn: slot được chuyển sang nguồn hợp lệ còn lại.

Reel có hai chế độ chính:

- `FOR_YOU`: trộn social sources với public discovery.
- `FOLLOWING`: chỉ lấy reel của bạn bè và người đang theo dõi.

Candidate generation chỉ là bước thu hẹp và không thay cho bước kiểm quyền cuối.

## 4. Content embedding

Mỗi nội dung có vector 512 chiều:

- text: `clip-ViT-B-32-multilingual-v1`;
- image/video frame: `clip-ViT-B-32`;
- có cả text và media: trộn có trọng số rồi chuẩn hoá;
- video lấy số frame, số byte, số pixel và thời gian xử lý có giới hạn.

Media fetch giữ các guard SSRF hiện có: chỉ HTTP(S), kiểm host/DNS/IP, chặn loopback,
link-local và cloud-metadata, tắt redirect, cap response size và chỉ allow host nội bộ được
cấu hình rõ ràng.

## 5. Interest model của user

### 5.1 Anchor và signal state

User có một deterministic anchor embedding làm mốc ổn định. Vector hiệu dụng không còn được
cập nhật đệ quy rồi dùng chính kết quả cũ làm anchor. Thay vào đó, mỗi tín hiệu được lưu riêng
và vector được dựng lại từ:

~~~text
effective_user_vector = normalize(
  deterministic_anchor
  + tổng(decayed_signal_weight * unit(content_embedding))
)
~~~

Các signal hiện hành:

| Signal | Base strength | Half-life | Ý nghĩa |
| --- | ---: | ---: | --- |
| WATCH | phụ thuộc chất lượng xem | 7 ngày | tín hiệu ngắn hạn, đổi nhanh |
| COMMENT | 0.25, saturating | 21 ngày | chủ động tương tác |
| LIKE | 0.50, exact toggle | 30 ngày | phản hồi rõ ràng |
| SHARE | 0.40, saturating | 45 ngày | phản hồi mạnh |
| SAVE | 0.65, exact toggle | 90 ngày | ý định dài hạn mạnh nhất |

Mỗi signal hết hiệu lực sau tám half-life. Khi dựng vector, tối đa 512 signal hiệu lực mạnh
nhất được dùng; storage tối đa 2.048 signal/user. Khi đầy, chỉ các signal tổng hợp có thể tái
tạo như WATCH/SHARE/COMMENT mới được cân nhắc loại theo độ mạnh đã decay. LIKE/SAVE đang hoạt
động và tombstone UNLIKE/UNSAVE chưa hết hạn không bị eviction, vì chúng là hàng rào chống
event cũ đến muộn làm sống lại sở thích đã huỷ.

### 5.2 Exact toggle và sự kiện đến sai thứ tự

LIKE/SAVE dùng `(occurred_at, event_key)` làm thứ tự quyết định. UNLIKE/UNSAVE không xoá dấu
vết ngay mà ghi inactive tombstone có retention. Event cũ hơn không thể ghi đè event mới hơn.

SHARE/COMMENT được cộng bằng hàm saturation thay vì tăng vô hạn. Interaction và impression
đều idempotent; lock luôn theo thứ tự user trước, target sau để tránh lost update/deadlock với
xoá user/content.

### 5.3 Rolling deployment và bootstrap user cũ

User cũ được bootstrap lười từ tối đa 2.048 interaction mới nhất. Migration tiếp theo giữ một
cursor riêng theo user để new worker có thể reconcile các interaction mà old worker ghi sau lúc
bootstrap. Cursor và signal update nằm trong cùng transaction; vì vậy rolling deployment không
làm mất sự kiện và không double-apply SHARE/COMMENT.

## 6. Semantics đo view

Post và reel không dùng chung một định nghĩa "xem".

### 6.1 POST: text/image/static post

- Đo thời gian element thực sự hiển thị và user còn chú ý.
- Card rất cao dùng visible-pixel threshold có giới hạn; không bắt buộc đạt 50% nếu bản thân card
  cao hơn viewport quá nhiều.
- Dưới 350 ms là incidental contact, trung tính.
- 350–799 ms chỉ là `FAST_SKIP` khi có scroll intent thực tế; đây là âm rất nhẹ.
- 800 ms–3 giây là `SHORT`; 3–15 giây là `READ`; từ 15 giây là `DEEP`.
- Khi tab ẩn, window mất focus hoặc user bất hoạt, đoạn thời gian đó không tiếp tục được cộng.
- Một post bị để mở quá lâu không biến thành tín hiệu mạnh; idle sentinel là trung tính nhưng vẫn
  hữu ích cho seen suppression.

### 6.2 REEL

- Chỉ cộng thời gian khi đúng video đang nhìn thấy thực sự phát.
- Pause, ended, seeking, buffering/stalled, tab ẩn, mất focus hoặc player không render đều dừng cộng.
- Completion dựa trên tổng tiến trình nội dung đã phát, không lấy thẳng `currentTime`; seek không thể
  giả tạo tỷ lệ hoàn thành.
- `SEEN` là đã xuất hiện nhưng chưa phát đủ để học.
- `SKIP` cần cả dwell thấp và completion thấp; đây là âm nhẹ.
- `LOW`, `MID`, `HIGH`, `COMPLETE` chủ yếu dựa trên phần trăm thời lượng đã xem.
- Không có luật "phát quá 5 phút là idle". Reel 10 phút được xem hết vẫn là tín hiệu mạnh. Idle là
  không có tiến triển phát/chú ý, không phải tổng độ dài video.

### 6.3 VIDEO_POST

FeedPost/GroupPost chứa video vẫn là post về nghiệp vụ, privacy và candidate source; nó không bị
đổi thành Reel. Tuy nhiên event nội bộ được SocialGraph phân loại `VIDEO_POST` từ media đã hydrate.
Telemetry dùng kiểu lai:

- attentive dwell tuyệt đối của post;
- active playback/completion của video;
- caption được đọc sâu vẫn có giá trị kể cả khi không phát hết video;
- completion cao có thể nâng tín hiệu, còn skip chỉ âm khi cả dwell lẫn completion đều thấp;
- idle không được dùng để thưởng cho autoplay hoặc một tab bị treo.

Kind này là metadata signed nội bộ; browser không được tự chọn `POST`, `VIDEO_POST` hay `REEL`.

### 6.4 Nội dung của chính user và mọi bề mặt

View nội dung của chính mình vẫn được ghi vào seen/impression để pagination và suppression đúng,
nhưng không huấn luyện vector của chính chủ.

Telemetry được gắn vào renderer dùng chung nên áp dụng cho Home, Reels, group feed/profile,
user profile, search, saved, post detail, photo viewer và reel viewer. Thumbnail/grid chỉ ghi khi
người dùng mở/xem thực, không ghi vì prefetch hoặc chỉ mount. Overlay giành ownership của target
khỏi card nằm dưới để cùng một view không chạy hai đồng hồ.

## 7. Semantic exposure và chống double count

Transport event có thể bị retry hoặc cùng view có thể đi qua key v2/v3. Recommendation quy chúng
về một semantic exposure duy nhất theo:

~~~text
(viewer_id, content_id, UTC five-minute observation bucket)
~~~

Trong cùng bucket:

- tier mạnh hơn nâng cấp tier yếu hơn;
- cùng tier giữ metric tốt nhất;
- IDLE không được ghi đè một observation hợp lệ;
- ownership correction có thể đổi observation thành own-content neutral;
- WATCH của target được tính lại từ tập bucket còn retention, không cộng một delta không thể đảo;
- số lần impression dùng để phạt reranking cũng đếm bucket semantic, không đếm số retry transport.

Aggregate read/recompute có giới hạn và dùng index theo bucket/content. Retention dựa trên trusted
`observation_bucket`, không dựa vào thời gian retry/update.

## 8. Ranking

Với mỗi candidate đã được SocialGraph cho phép:

~~~text
semantic    = cosine(effective_user_vector, content_embedding)
freshness   = exp(-ln(2) * age_hours / freshness_half_life_hours)
affinity    = điểm nguồn social/group/public
exploration = deterministic epsilon cho session và content
penalty     = min(0.5, semantic_exposure_count * impression_penalty)

score = 0.58 * semantic
      + 0.20 * freshness
      + 0.10 * affinity
      + 0.12 * exploration
      - penalty
~~~

Giá trị mặc định có bounds và có thể rollout bằng environment variables. Exploration dùng hash
của session seed + candidate ID nên có khám phá nhưng không làm pagination đổi thứ tự ngẫu nhiên.

Sau score:

1. unseen trong TTL được ưu tiên trước previously-seen;
2. quota mềm mặc định tối đa 3 content/author, 4 content/group và 3 nội dung liên tiếp cùng họ
   `FeedPost`/`GroupPost`/`Reel`; loại mới chưa biết được giữ trung tính để rollout không làm mất nội dung;
3. phần bị trì hoãn được nối lại nếu cần để feed không bị ngắn;
4. một session snapshot giữ tối đa 500 ranked ID trong hai giờ.

Seen/impression phát sinh sau `session_started` không tự loại phần tử ở trang kế tiếp của chính
session đó. Snapshot chỉ lưu ID, không lưu nội dung hay quyền, nên hydrate cuối vẫn áp dụng policy mới.

## 9. Frontend delivery và account lifecycle

- Batch tối đa 50 impression; client retry tối đa một lần.
- Dedupe/LRU state đều có hard cap và TTL năm phút.
- Page lifecycle flush dùng authenticated Gateway GraphQL `fetch keepalive`; không có browser-to-
  Recommendation shortcut.
- Background telemetry không tự refresh token và không được làm phiên tương tác logout vì một lỗi
  analytics.
- Đổi tài khoản/logout abort request đang chạy, tăng generation và xoá queue/cache; event của tài
  khoản trước không thể retry dưới tài khoản sau.
- Page hidden/blur và ownership giữa feed/overlay được xử lý tập trung, không cài listener riêng vô
  hạn cho từng card.

## 10. Security và privacy

SocialGraph xử lý impression như một policy-sensitive write:

- caller luôn lấy từ trusted authenticated accessor;
- input không có `viewerId`, `contentKind`, ownership, privacy hay group membership;
- batch hydrate một lần bằng viewer hiện tại và kiểm block hai chiều;
- ID không xem được bị bỏ im lặng, không biến endpoint thành existence oracle;
- kind/quality/own-content và `occurredAt` được tạo ở trusted server path;
- outbox giữ idempotency và gửi request đã ký có timestamp/nonce/replay protection;
- Recommendation kiểm signed caller, bounds, timezone, future skew và retention;
- user/target projection thiếu trả retryable thay vì tự tạo lại state sau xoá.

Database production giữ owner/runtime role split. Runtime không cần DDL; khi migration tự động tắt,
startup/readiness vẫn kiểm exact table/column/PK/index/CHECK và DML privileges, fail closed nếu schema
drift.

## 11. Migration và retention

Tám owner migration theo thứ tự bất biến:

1. `user_embedding.sql`
2. `post_embedding.sql`
3. `recommendation_interactions.sql`
4. `recommendation_impressions.sql`
5. `recommendation_seen.sql`
6. `recommendation_feed_sessions.sql`
7. `recommendation_interest_model.sql`
8. `recommendation_impression_aggregates.sql`

Migration 7 và 8 là additive. File migration đã phát hành không được sửa checksum; thay đổi tiếp theo
phải là migration mới.

Retention chính:

- raw impression ledger: 90 ngày;
- semantic exposure aggregates: 90 ngày theo observation bucket;
- seen state: 90 ngày, suppression TTL mặc định 30 ngày;
- interest signal: tám half-life tương ứng; khi chạm hard cap, chỉ `WATCH/SHARE/COMMENT` active
  mới được cân nhắc loại, còn LIKE/SAVE active và toggle tombstone chưa hết hạn luôn được giữ;
- feed/reel session: sliding expiry hai giờ;
- cleanup chạy theo bounded batch, time budget và non-blocking global advisory lock.

Migration 8 bắt mọi interaction insert, kể cả worker phiên bản cũ, lấy user lock trước khi cấp
`ingestion_id` và từ chối insert nếu lifecycle user đã bị xoá. Target lock dùng try-lock với lỗi
retryable khi tranh chấp, tránh deadlock giữa backlog rolling và target của request hiện tại.

Xoá user/content dọn interaction, impression, seen, aggregate, interest state, reconciliation cursor,
session và embedding tương ứng trong transaction có lock. Event cũ retry sau đó không thể tái tạo user
hoặc content đã xoá.

## 12. Điều hệ thống này chưa tuyên bố

Fakebook hiện có online content-embedding interest model và heuristic multi-objective ranker, chưa có
traffic đủ lớn để huấn luyện/calibrate một learning-to-rank model như hệ thống quy mô Meta. Những nâng
cấp cần dữ liệu thật thay vì đoán thêm hệ số:

- A/B test và cohort calibration;
- explicit `Not interested`/hide/report và survey về true interest;
- offline Recall@K, NDCG, satisfaction, author/content diversity và drift metrics;
- sequence model/multi-interest representation khi lịch sử đủ dày;
- integrity/quality model riêng, không suy diễn từ engagement đơn thuần.

Các bước đó phải tiếp tục giữ nguyên policy boundary: SocialGraph quyết quyền, browser không tự khai
actor/policy, event nội bộ signed/idempotent và hydrate cuối luôn kiểm privacy/block hiện tại.
