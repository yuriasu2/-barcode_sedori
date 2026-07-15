# Keepa API トークン枯渇 対応 企画書

作成: 2026-07-15 / ステータス: **企画（未実装。Phase 1 の一部＝30分キャッシュのみ実装済み）**

## 0. 背景・現状

- **構成**: サーバー（Render）に **Keepa APIキーを1つ**だけ持ち、Keepa経路を使う**全ユーザーがその1つのトークンバケットを共有**する。
- **Keepaを使うのは誰か**:
  - 無料・SP-API未連携ユーザーの検索（第1段階 `getProduct`）＝共有コスト。
  - Keepaグラフ（`/api/graph`）＝Pro限定だが、**グラフは常にKeepa**なので枯渇時は誰でも落ちる。
  - Keepaオファー（`/api/offers?source=keepa`）＝Pro限定。
  - ※SP-API連携ユーザーは検索/オファーは自分の枠を使うためKeepaを消費しない（グラフのみ影響）。
- **現状の挙動（要改善）**:
  - 枯渇すると Keepaクライアントが `keepa_tokens_exhausted` を投げ、サーバーは **HTTP 503** を返す（`server/src/keepa/client.js` / `server/src/routes.js`）。
  - アプリは 503 を**汎用エラー扱い**し「サーバーエラー(503): …」と raw 表示（`SearchTabView.swift`）。グラフは `AsyncImage` の `.failure` で**無言の空白**。
  - **即失敗・キューなし・順番保証なし**（＝回復トークンは「その瞬間に叩いた人の早い者勝ち」）。

## 1. Keepaトークンの仕組み（調査結果）

- トークンは **APIキー（アカウント）単位のバケット**。レスポンスに毎回3値が入る:
  - `tokensLeft`: 現在の残トークン
  - `refillRate`: **毎分**生成されるトークン数（プランで決まる）
  - `refillIn`: 次の補充までのミリ秒（補充は概ね5分周期）
- **1トークン＝1商品の完全データ**（要求データが多い/詳細だと消費増）。**未使用トークンは1時間で失効**。
- 枯渇すると **HTTP 503**。次の補充まで待つ必要がある。
- **`check_status`（状態確認）はトークンを消費しない**（＝`tokensLeft` を無料で監視できる）。
- プランは「毎分トークン数」で差別化される（上位プランほど回復が速い）。

## 2. 複数利用者でも快適に運用するための一般的な仕組み（調査結果）

Keepaに限らず、レート/トークン制の外部APIを多人数向けサービスで捌く定石:

- **A. キャッシュ最優先**: 同一クエリの結果を使い回す。「1日200回の同一問い合わせ→キャッシュで1回のAPI＋199ヒット」＝**約99.5%削減**。最も効果が大きい。
- **B. サーバー側キュー＋トークンアウェア・スロットリング**: リクエストを一斉に投げず**キューに入れ、`refillRate` に合わせて順番に流す**。Keepa公式/主要クライアントも「トークンが足りなければ**回復を待って**から送る（fail-fastしない）」実装。ユーザーは**エラーの代わりに少し待つ**。
- **C. 指数バックオフ＋ジッター**: 再試行は **429/500/503 のみ**。基準遅延1秒→2→4…と倍化＋ランダム化。全クライアントが同時に再試行して**リトライストーム**を起こすのを防ぐ。
- **D. 優先度キュー（フェア/加重キュー）**: 有料/無料でキューを分け、**有料（Pro）を優先**。残量が少ないときは無料を先に待たせて課金者の体験を守る。
- **E. 監視・アラート**: `tokensLeft` を（無料の `check_status` で）監視し、枯渇前に検知。ログ＋ダッシュボード＋しきい値アラートで、**プラン増強の判断材料**にする。
- **F. BYOキー（利用者に自分の枠を使わせる）**: 各利用者が自分のAPIキー/枠を使えば共有バケットの競合が消える。→ **本アプリは SP-API を BYO 化済みで同じ発想**（SP-API連携ユーザーはKeepaを消費しない）。
- **G. 分散時は共有ストア（Redis）**: 複数インスタンスでレート状態を一貫させる。※現状は単一Renderインスタンスのため不要。

## 3. 本アプリでの推奨設計（フェーズ別）

### Phase 1 — すぐやる（小さく高効果・少人数でも有効）
1. **親切メッセージ**: 503 の中身 `error: keepa_tokens_exhausted` を判別し（汎用503と区別）、「**価格情報が一時的に混み合っています。少し待って再試行してください**」を表示。
2. **再試行ボタン**: スキャンし直さず再取得できる導線（トークンは毎分回復するため手動再試行が有効）。
3. **グラフのフォールバック文言**: 無言の空白ではなく「**グラフを一時的に取得できません**」。
4. **無料・SP-API未連携ユーザーを"転換"へ**: 「混雑中です。**Amazon(SP-API)連携**で自分の枠で安定検索／**Pro**でも快適に」→ 障害を連携・課金の入口に変える（かつ連携ほどKeepa競合が減る）。
5. **キャッシュ**: ✅ Keepa結果を **30分キャッシュ**（実装済み `KEEPA_CACHE_TTL_MS`）。必要ならさらに延長。

### Phase 2 — 同時アクセスが増えてきたら
6. **サーバー側キュー＋トークンアウェア・スロットリング**: `tokensLeft`/`refillRate` を見て、Keepaへのアウトバウンドを**順番に流す**。ユーザーには「順番に処理中…（あと約N秒）」。**最大待ち時間＋タイムアウト**必須。
7. **リクエスト・コアレッシング**: 同一コードの同時リクエストを1本にまとめ、結果を共有（人気書籍で効く）。
8. **tokensLeft 監視＋ログ/アラート**: 無料の `check_status` で残量を定期取得し、枯渇の予兆をログ。

### Phase 3 — さらにスケール／課金者保護
9. **優先度キュー**: Proを優先。残量が少ないとき無料のKeepa検索を先に「混雑中」にして、Proのグラフ/オファー用トークンを温存。
10. **Keepa上位プラン**: 毎分トークン数を増やす（回復速度の底上げ）。
11. **複数インスタンス化するなら Redis** でトークン/キュー状態を共有。

## 4. UX方針（表示メッセージ）

| 状況 | メッセージ（案） |
|---|---|
| 検索失敗（無料・Keepa枯渇） | 「価格情報が混み合っています。少し待つか、設定→Amazon連携／Proで安定してご利用いただけます」＋**再試行** |
| グラフ失敗（Keepa枯渇） | 「グラフを一時的に取得できません（時間をおいて再度お試しください）」＋**再試行** |
| キュー方式採用時 | 「順番に処理しています…（あと約N秒）」 |

## 5. 実装対象ファイル（目安）

- サーバー:
  - `keepa/client.js`: `tokensLeft`/`refillRate` の取り出し、（Phase2）回復待ち・スロットリング。
  - `routes.js`: 503エラーの整形、（Phase2）キュー/コアレッシングの組み込み。
  - `keepaQueue.js`（新規, Phase2）: トークンアウェアな順次処理キュー。
- iOS:
  - `APIClient.swift` / `SearchTabView.swift`: `keepa_tokens_exhausted` の判別、専用メッセージ＋再試行UI、SP-API/Pro誘導。

## 6. 実装前に決めること

1. **「エラー即返し」か「キューで待たせる」か** — 少人数なら Phase 1（エラー＋再試行＋誘導）で十分。同時アクセスが増えたら Phase 2（キュー）。
2. 待たせる場合の**最大待ち時間**（例: 15〜30秒でタイムアウト）。
3. **Pro優先度**を入れるか（Phase 3）。
4. **Keepaプランのアップグレード**予算・タイミング。

## 7. リスク・注意

- **キューは単一インスタンス前提**。Renderを複数インスタンスにするとキュー/トークン状態の共有（Redis等）が必要。
- **待たせすぎ**はUX悪化＋サーバーリソース占有 → タイムアウト必須。
- **リトライは 429/500/503 のみ・指数バックオフ＋ジッター**でリトライストームを避ける。
- 根本緩和は「**共有Keepa枠の競合を減らす**」こと：SP-API連携の促進・キャッシュ・上位プラン。

## 参考（調査ソース）

- [Keepa API methods (keepaapi.readthedocs.io)](https://keepaapi.readthedocs.io/en/latest/api_methods.html)
- [Keepa 公式 API backend (keepacom/api_backend, KeepaAPI.java)](https://github.com/keepacom/api_backend/blob/master/src/main/java/com/keepa/api/backend/KeepaAPI.java)
- [Keepa API Documentation Overview (scribd)](https://www.scribd.com/document/571210466/keepa-api)
- [How to Handle API Rate Limits Gracefully (apistatuscheck.com)](https://apistatuscheck.com/blog/how-to-handle-api-rate-limits)
- [Best practices for handling API rate limiting (zigpoll.com)](https://www.zigpoll.com/content/what-are-the-best-practices-for-handling-api-rate-limiting-when-integrating-thirdparty-services-in-a-web-application)
- [Design A Rate Limiter (bytebytego.com)](https://bytebytego.com/courses/system-design-interview/design-a-rate-limiter)
- [Token Bucket Algorithm Explained (dev.to)](https://dev.to/0xtanzim/token-bucket-algorithm-explained-4ceo)
