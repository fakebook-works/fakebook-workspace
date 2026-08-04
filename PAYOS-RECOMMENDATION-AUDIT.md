# Audit PayOS và Recommendation

Ngày: 2026-08-04

## Phạm vi

Đây là audit chỉ đọc source và tài liệu hiện có.

Trong audit này:

- không sửa code;
- không build;
- không chạy test;
- không khởi động service;
- không thay đổi cấu hình;
- không đụng vào phần code có thể đang được agent khác chỉnh sửa.

Các kết luận runtime cần được kiểm chứng riêng.

## Kết luận nhanh

### PayOS

Có hai flow riêng:

1. User checkout/reconcile: Frontend → Gateway GraphQL → Payment GraphQL mutation.
2. PayOS webhook: PayOS → Gateway REST → Payment REST.

Webhook không biến thành GraphQL mutation. Gateway forward nguyên HTTP body bằng REST tới Payment.

### Recommendation

Flow bảo mật chính đang hợp lý:

1. Frontend gọi recommendFeed qua Gateway GraphQL.
2. Recommendation kiểm tra Gateway secret và trusted user.
3. Recommendation gọi SocialGraph bằng signed REST để lấy candidate IDs.
4. SocialGraph lọc privacy, block, relationship và membership.
5. Recommendation rank candidate bằng dot product của user vector và post vector.
6. SocialGraph hydrate lại post và visibility-check lần cuối.
7. Frontend bỏ các item hydrate thành null.

Tuy nhiên recommendation hiện khá deterministic, nên refresh feed thường không thay đổi nhiều là phù hợp với logic hiện tại.

## 1. PayOS

### 1.1 Checkout do user khởi tạo

Flow:

Frontend
→ POST /graphql tới Gateway
→ createPremiumCheckout
→ Payment GraphQL Mutation
→ Payment lấy giá plan server-side
→ Payment tạo order
→ Payment gọi PayOS
→ trả checkout URL

Các thao tác GraphQL có liên quan:

- createPremiumCheckout;
- reconcilePremiumCheckout;
- premiumOrder;
- premiumPlans.

Payment lấy actor từ trusted Gateway context. Client không quyết định owner, amount, currency hoặc entitlement.

### 1.2 Webhook từ PayOS

PayOS gọi:

POST /api/webhooks/payos

Gateway:

- AllowAnonymous;
- rate limit theo IP;
- chỉ nhận application/json;
- giới hạn body khoảng 64 KiB;
- đọc nguyên body thành byte array;
- không deserialize rồi serialize lại;
- tạo HTTP POST tới Payment;
- gắn dedicated Payment gateway secret;
- giữ nguyên body;
- không truyền browser JWT/cookie.

Payment nhận:

POST /internal/webhooks/payos

Payment:

- fixed-time compare X-Gateway-Secret;
- kiểm tra content type/body size;
- verify exact body với PayOS provider;
- lock payment order;
- kiểm tra order code;
- kiểm tra amount;
- kiểm tra currency;
- kiểm tra provider payment link ID;
- insert transaction bằng ON CONFLICT DO NOTHING;
- đổi order thành PAID;
- ghi activation outbox.

Sơ đồ:

PayOS
→ Gateway REST /api/webhooks/payos
→ Payment REST /internal/webhooks/payos
→ verify provider
→ payment transaction
→ premium activation outbox

Kết luận: PayOS webhook là REST forward nguyên body, không phải GraphQL mutation.

Source:

- APIGateway/API-Gateway/fakebookGateway/Gateway/PaymentWebhookProxy.cs
- PaymentService/Backend-Payment/fakebookPayment/Endpoints/PayOSWebhookEndpoint.cs
- PaymentService/Backend-Payment/fakebookPayment/GraphQL/PaymentGraphQL.cs
- PaymentService/Backend-Payment/fakebookPayment/Repositories/PaymentRepository.cs

## 2. Recommendation candidate và ranking

### 2.1 Candidate

Recommendation gọi các endpoint nội bộ của SocialGraph:

- GET /internal/recommendation/post-candidate-ids
- GET /internal/recommendation/reel-candidates

Candidate được SocialGraph lấy từ:

- accepted friends;
- active follows;
- group member/admin;
- public feed post;
- public group post;
- public/friend/follow reels.

SocialGraph đã lọc:

- block hai chiều;
- content privacy;
- relationship;
- group membership;
- loại content phù hợp.

Candidate được deduplicate, sau đó sort ID giảm dần. Vì Snowflake ID thường tăng theo thời gian, thứ tự này gần giống mới nhất trước. Candidate pool bị giới hạn, thường tối đa khoảng 500 IDs.

### 2.2 Ranking

Recommendation đọc:

- recommendation.user_embeddings;
- recommendation.post_embeddings.

Công thức chính:

score = dot(user_vector, post_vector)

Post không có embedding vẫn nằm trong candidate list nhưng có score bằng 0.

Khi score bằng nhau, Python stable sort giữ thứ tự candidate do SocialGraph trả về.

Hiện không thấy các thành phần:

- random exploration;
- freshness score;
- author diversity;
- seen suppression;
- time decay;
- quota theo author;
- impression-based reranking.

Vì vậy cùng candidate pool và cùng vector thường cho cùng thứ tự.

Source:

- SocialGraphService/SocialGraph.Api/RestAPI/RecommendationController.cs
- SocialGraphService/SocialGraph.Api/Service/CandidateService.cs
- RecommendationService/Backend-Recommendation/ForFakebook/recommendation_service.py
- RecommendationService/Backend-Recommendation/ForFakebook/EmbeddingModel.py
- SocialGraphService/SocialGraph.Api/SubGraphQL/HomePostByIdDataLoader.cs

## 3. User vector hiện tại

### 3.1 Vector ban đầu

Khi user được provision:

SocialGraph
→ Auth provision thành công
→ RecommendationUserUpsert outbox
→ PUT /internal/recommendation/users/{userId}/embedding

Recommendation tạo vector 512 chiều bằng random deterministic với seed là user ID rồi normalize.

Vector ban đầu:

- không dựa trên profile;
- không dựa trên friend/follow;
- không dựa trên lịch sử xem;
- không có semantic meaning thực sự cho user mới.

Nếu user vector không tồn tại, ranking dùng vector zero. Khi đó mọi dot product bằng 0 và kết quả gần như đi theo thứ tự candidate SocialGraph.

### 3.2 Post vector

Post embedding:

- text-only: text embedding normalized;
- media-only: media embedding normalized;
- text và media: normalize 0.6 text embedding + 0.4 media embedding.

Model được load lazy. Media còn phải qua:

- host allowlist;
- DNS/IP validation;
- no redirect;
- byte limit;
- pixel limit;
- video frame limit;
- temporary file.

Post mới có thể được candidate trả về trước khi embedding hoàn tất.

### 3.3 Feedback cập nhật vector

| Action | Weight |
|---|---:|
| LIKE | +0.25 |
| UNLIKE | -0.15 |
| SAVE | +0.35 |
| UNSAVE | -0.20 |
| WATCH | +0.08 |
| SHARE | +0.40 |
| COMMENT | +0.20 |

Công thức:

newVector = normalize((1 - abs(weight)) * currentVector + weight * targetPostVector)

Interaction được ghi bằng:

- Idempotency-Key;
- recommendation interaction ledger;
- PostgreSQL advisory lock theo user;
- cùng transaction với việc update vector.

Nếu target post chưa có embedding, Recommendation trả HTTP 425. Outbox SocialGraph xem đây là lỗi tạm thời và retry.

Source:

- RecommendationService/Backend-Recommendation/ForFakebook/operations.py
- RecommendationService/Backend-Recommendation/ForFakebook/database.py
- RecommendationService/Backend-Recommendation/ForFakebook/user_embedding.sql
- RecommendationService/Backend-Recommendation/ForFakebook/recommendation_interactions.sql

## 4. Khi nào vector được cập nhật?

### Có cập nhật

SocialGraph tạo recommendation interaction khi action thành công:

- like;
- unlike;
- save;
- unsave;
- watch;
- share;
- comment.

Flow:

SocialGraph mutation
→ local association change
→ RecommendationInteraction outbox
→ signed POST tới Recommendation
→ interaction ledger và user vector update

### Không cập nhật

Hiện chưa thấy vector được cập nhật từ:

- mở Home;
- scroll feed;
- đọc feed post;
- dừng ở post;
- xem ảnh feed;
- hover post;
- follow;
- friend;
- tạo post;
- sửa profile;
- search topic.

Frontend có watchContent cho story và reel. Reel thường ghi watch khi video play. Story ghi watch khi mở story.

Feed post thông thường không có impression/watch event trong Home feed.

Đây là nguyên nhân lớn: user chỉ xem và refresh thì vector gần như không đổi.

## 5. Vì sao refresh feed không thay đổi nhiều?

### 5.1 Ranking deterministic

Nếu cùng:

- candidate pool;
- user vector;
- post vectors;
- privacy/relationship state;

thì dot product và thứ tự giống nhau.

Frontend không có persistent recommendation cache rõ ràng. Client chỉ deduplicate query giống nhau đang chạy đồng thời. Vì vậy nguyên nhân chính không phải Gateway cache lâu, mà là backend tính lại cùng kết quả.

### 5.2 Không có passive browsing feedback

Người dùng có thể xem rất nhiều post nhưng nếu không like/save/comment/share thì Recommendation không nhận được tín hiệu.

Flow hiện tại không có:

post visible
→ impression event
→ vector update

### 5.3 Outbox có độ trễ

Like/save có thể đã thành công ở SocialGraph nhưng event RecommendationInteraction vẫn đang chờ worker.

Nếu refresh ngay sau action:

GraphQL mutation commit
→ outbox chưa dispatch
→ recommendation đọc vector cũ
→ feed chưa đổi

Nếu outbox lỗi lâu hoặc dead-letter, vector tiếp tục stale.

### 5.4 Post embedding có độ trễ

Post mới có thể chưa được Recommendation tạo vector. Khi đó score bằng 0. Nếu có nhiều post đã có vector dương, post mới có thể không đứng đầu.

### 5.5 Không có exploration

Recommendation hiện chủ yếu là candidate filtering cộng semantic dot product. Không có cơ chế trộn:

- sở thích cũ;
- nội dung mới;
- author mới;
- random exploration;
- freshness.

Vì vậy refresh không tự sinh ra feed khác.

## 6. Điểm logic đáng chú ý

### 6.1 Hạn chế chắc chắn: vector ban đầu random

User mới không có sở thích thực. Vector random deterministic chỉ giúp có row để query.

### 6.2 Hạn chế chắc chắn: không học từ việc xem feed

Nếu user chỉ scroll/đọc mà không tương tác, vector không đổi.

### 6.3 Hạn chế: like/unlike không đối xứng

LIKE +0.25 nhưng UNLIKE -0.15. SAVE +0.35 nhưng UNSAVE -0.20.

LIKE rồi UNLIKE không đưa vector chính xác về trạng thái ban đầu. Toggle nhiều lần có thể tạo drift/noise. Đây có thể là chủ ý để coi unlike là negative feedback, nhưng không phải phép đảo ngược chính xác.

### 6.4 Hạn chế: watch cùng content thường chỉ ghi một lần

Watched là association. Sau khi association tồn tại, xem lại cùng content có thể không tạo interaction mới. Không có watch duration, completion percentage hoặc repeated impression.

### 6.5 Hạn chế: candidate pool bounded

Content ngoài pool SocialGraph trả về không được Recommendation rank, dù semantic match tốt.

### 6.6 Edge case frontend: item hydrate thành null

Recommendation trả postId và nullable post. SocialGraph có thể trả post null vì content đã xóa, privacy đổi, block hoặc mất membership.

Frontend lọc post null nhưng Home page:

- tăng offset theo raw item count;
- tính hasMore theo raw item count;
- không tính theo số post thực sự hiển thị.

Nếu một page có nhiều item null, feed có thể ngắn hơn mong đợi. Nếu toàn bộ page null và posts đang rỗng, loader tiếp theo có thể không được gắn vì IntersectionObserver chỉ được bật khi posts.length lớn hơn 0.

Đây là edge case code-level cần kiểm chứng nếu thực tế feed bị ngắn/rỗng.

### 6.7 Outbox có thể làm personalization stale

Nếu Recommendation unavailable, thiếu secret, thiếu schema, model embedding lỗi hoặc media không tải được:

- SocialGraph mutation chính vẫn có thể thành công;
- recommendation event retry;
- vector chưa cập nhật;
- sau max attempts event có thể dead-letter.

## 7. Những phần đang đúng về bảo mật

Qua source hiện tại:

- Recommendation GraphQL yêu cầu Gateway secret;
- userId input phải khớp trusted X-User-Id;
- Recommendation gọi SocialGraph bằng signed REST;
- SocialGraph lọc block/privacy/membership;
- SocialGraph hydrate và visibility-check lần cuối;
- interaction có idempotency;
- interaction cùng user được serialize;
- target vector chưa có thì trả lỗi tạm thời 425;
- outbox retry lỗi transient;
- media embedding có SSRF/size/pixel/frame protection;
- PayOS webhook kiểm tra exact body, amount, currency và provider link;
- Payment transaction có lock và idempotency.

Không thấy auth/privacy bypass rõ ràng khi chỉ đọc source. Tuy nhiên chưa chạy runtime/test nên chưa thể khẳng định deployment thực tế không có lỗi cấu hình.

## 8. Chẩn đoán theo hiện tượng

### Nếu refresh nhưng feed giống cũ

Nguyên nhân phù hợp nhất:

Không có impression learning
+ user vector không đổi khi chỉ scroll
+ ranking deterministic
+ không có exploration/randomness

### Nếu feed đôi khi ngắn hoặc không load thêm

Cần nghi ngờ:

Recommendation trả item nhưng SocialGraph hydrate thành null
+ frontend lọc null
+ offset tính theo raw item
+ sentinel không gắn khi posts rỗng

### Nếu vừa like/save nhưng refresh chưa đổi

Cần nghi ngờ:

GraphQL mutation đã commit
nhưng RecommendationInteraction vẫn đang pending trong outbox.

## Source chính

- APIGateway/API-Gateway/fakebookGateway/Gateway/PaymentWebhookProxy.cs
- PaymentService/Backend-Payment/fakebookPayment/Endpoints/PayOSWebhookEndpoint.cs
- PaymentService/Backend-Payment/fakebookPayment/GraphQL/PaymentGraphQL.cs
- PaymentService/Backend-Payment/fakebookPayment/Repositories/PaymentRepository.cs
- RecommendationService/Backend-Recommendation/ForFakebook/EmbeddingModel.py
- RecommendationService/Backend-Recommendation/ForFakebook/operations.py
- RecommendationService/Backend-Recommendation/ForFakebook/recommendation_service.py
- RecommendationService/Backend-Recommendation/ForFakebook/embedding_service.py
- SocialGraphService/SocialGraph.Api/Service/CandidateService.cs
- SocialGraphService/SocialGraph.Api/Service/ContentGraphService.cs
- SocialGraphService/SocialGraph.Api/Service/ExternalServiceClient.cs
- SocialGraphService/SocialGraph.Api/Infrastructure/Outbox/IntegrationOutboxPublisher.cs
- Frontend/Frontend/src/api/client.ts
- Frontend/Frontend/src/pages/GatewayHomePage.tsx
- Frontend/Frontend/src/components/ContentActions.tsx
- Frontend/Frontend/src/pages/ReelsPage.tsx


