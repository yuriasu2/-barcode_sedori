# セラーレンズ

Amazonせどり向けの仕入れリサーチiPhoneアプリです。店頭で商品のバーコード(ISBN/JAN)をかざすと、Amazonでの価格一覧・価格とランキングの推移グラフ・見込み利益をその場で確認でき、そのまま仕入れリストへ追加して Amazon へ出品するところまで行えます。

このリポジトリには、iOSアプリ本体、バックエンドAPI(Cloudflare Workers)、App Store Connect 用の補助ツール、デザイン素材、設計・運用ドキュメントが入っています。

> 状態は 2026-10-23 時点です。コードとドキュメントが食い違う場合はコードを正としています。

## 概要

| 項目 | 内容 |
|---|---|
| アプリ名 | セラーレンズ(旧「アマレンズ」、さらに前は「バーコードせどり」。2026-08-14 に改名) |
| 配信状態 | App Store で公開中。App ID `6801570852` |
| Bundle ID | `jp.sellira.sellerlens`(`ios/BarcodeSedori/project.yml`) |
| バージョン | `project.yml` 上は 1.0.3 (build 21)。1.0.2 は承認・公開済みで、1.0.3 は TestFlight 用にアップロードした段階(審査提出の有無は未確認) |
| 対象OS | iOS 16.0 以上、iPhone 専用(`TARGETED_DEVICE_FAMILY: 1`)、縦向きのみ |
| 運営 | sellira(LP: https://sellira.jp/sellerlens/ ) |
| API | https://api.sellira.jp(Cloudflare Workers、Worker 名 `barcode-sedori-api`) |
| 主な外部サービス | Keepa API、Amazon SP-API(Login with Amazon で認可)、App Store Server API、Google AdMob、PostHog |
| プライバシーポリシー | https://sellira.jp/privacy/(LP と一緒に別リポジトリ `sellira-site` で管理) |

## 主な機能

凡例: 「Pro」は有料プラン限定、「要連携」は Amazon 連携(SP-API の OAuth 認可)が必要。無印は無料で使えます。

### 検索・価格確認

| 機能 | 内容 | 条件 |
|---|---|---|
| バーコードスキャン | EAN-13(ISBN-13 / JAN)を読み取り検索。近距離でピントが合うよう機種ごとにカメラを調整(`Scanner/ScannerView.swift`) | 無料(1日の無料枠あり) |
| OCR検索 | 印字された ISBN / JAN の数字をカメラで読み取る。バーコードが汚れていても使える | 無料は1日5回、Proは無制限 |
| 手入力検索 | 検索欄から入力。10桁 ISBN は13桁へ自動変換 | 無料枠を消費 |
| 価格表示 | 新品・中古・Amazon 本体の価格、ランキング、定価、発売日。日本の Keepa の最安値は送料込み | 無料 |
| 出品者ごとの価格一覧(オファー) | 新品・中古の出品者別価格を送料込みの安い順に表示。未連携の場合は鍵表示で連携へ誘導 | 要連携(無料プランでも可) |
| Keepa グラフ | 価格(Amazon/新品/中古)とランキング、出品者数(新品/中古/コレクター)の推移。期間は 1ヶ月/3ヶ月/1年/全期間 | 無料は無料枠を消費、Proは無制限 |
| リンクボタン | 仕入れリストへ追加・Amazon・メルカリ・価格.com・楽天市場・Yahoo!ショッピング・ヤフオク・ラクマ・Keepa の9種から選んで並べ替え。アプリ内ブラウザで開く | 無料(仕入れリスト追加はPro) |
| 検索クールダウン | 共有 Keepa キーを使う検索は7秒、Amazon 連携済み(または Pro で自前 Keepa キー設定済み)は1秒 | - |

### 履歴

- 直近5,000件までのスキャン履歴を端末内に保存(100件ずつのファイルに分割し、ページ単位で読み込み。`Store/HistoryChunkStorage.swift`)。
- 履歴から商品詳細を開くと、保存済みのグラフを通信なしで再表示。グラフは最大5,000ファイルまで端末に保存(`Store/GraphArchive.swift`)。
- 各行の商品画像の下に、直近1年のランキング推移ミニグラフ(保存済みグラフから描画。API 通信も無料枠消費もなし)。
- 検索、複数選択での削除、仕入れリストへの一括追加(Pro)、設定からの全削除。
- 利益アラートに該当した商品は緑枠で表示。

### 利益アラート(Pro)

ランキング、粗利益(仕入れ額を入力)、出品者数(新品/中古の閾値)、定価超えの4条件を AND で組み合わせ、対象コンディション(新品/中古/両方)を選べます。該当するとスキャン結果に緑の枠とバナーを出し、振動します。振動はスキャン成功時の振動(無料)とは別の設定です(`Models/ProfitAlertEvaluator.swift`)。

### 仕入れリスト・仕入れフォーム(Pro)

- 仕入れタブに未出品/出品済みの2タブ、検索、複数選択(削除・コンディション一括変更・一括出品)、CSV 書き出し(UTF-8 BOM 付き、自分用データ。Amazon の在庫ファイル形式ではない)。
- 仕入れフォーム: 仕入れ価格・仕入先・コンディション(新品/ほぼ新品/非常に良い/良い/可)・FBA か自己発送か・配送料・発送費用・数量を入力。
- 出品価格の自動入力: 要連携ならオファー一覧の最安値(送料込み)。未連携でも Keepa の送料込み最安値(`landedPrices`、無ければ `prices`)にフォールバックして空欄にしない。設定で「最安値から配送料を引いた額」を自動入力することもできる(既定オフ。`Models/ListingModels.swift`)。
- SKU の自動採番: 項目の並べ替えができるフォーマットビルダーと、同一 SKU の二重発行防止(`Models/SkuGenerator.swift`)。
- コンディション別の説明文テンプレート、送料の名前付きプリセット、仕入先リスト。
- 手数料と粗利益の計算は2系統あります。
  - 要連携: SP-API の手数料見積り(`GET /api/fees-estimate`)で販売手数料・カテゴリ成約料・FBA 手数料の実額を取得。
  - 未連携または API 失敗時: アプリ内概算。販売手数料率は Keepa 経路の `feeInfo.referralFeePercent`(カテゴリ別の紹介料率)を使い、無ければ書籍想定の15%。成約料80円はメディア系カテゴリ(本・洋書・ミュージック・DVD/ビデオ)のみ計上し、消費税は(販売手数料+成約料)の10%。合計行に「(概算)」と付記し、FBA 手数料は概算できない旨を注記する。ただし SP-API が「その商品の見積りを返さない」と答えた場合は概算に逃がさずエラー文言を出す。

### Amazon への出品(Pro かつ要連携)

- 出品制限の事前チェック(`GET /api/listings/restrictions`)。検索結果にバッジ、仕入れフォームに制限あり/出品可能を表示。解除申請リンクも出す。
- 単品出品と一括出品(進捗表示付き)。Listings Items API の `putListingsItem` を `LISTING_OFFER_ONLY` で呼ぶ(`POST /api/listings`)。FBA は `AMAZON_JP`、自己発送は `DEFAULT`。納品プランの作成はセラーセントラルで行う。
- 一括出品が全件成功したときがレビュー依頼の主トリガー。

### 無料枠・広告・課金まわり

- 無料プランは1日の「無料枠ユニット」で検索・グラフ取得を制限(料金体系の節を参照)。Amazon 連携済みなら検索はユニットを消費しない。
- 広告: AdMob のバナー(検索・履歴・仕入れ・設定の各タブ)と、無料枠を増やすリワード広告。配信設定はサーバーの KV で管理(運用の節を参照)。Pro は広告非表示。
- Pro で自前の Keepa API キーを設定でき(端末の Keychain に保存)、グラフを自分のトークンで取得して待ち時間を短縮できる。
- ATT(トラッキング許可)は、初回起動時にカメラ許可が確定した約1秒後に Apple 標準のダイアログを直接要求する(事前説明ダイアログは審査 5.1.1 の指摘で廃止。`Store/AttPromptController.swift`)。許可しなくても広告は非パーソナライズで表示される。
- お知らせ・障害告知ポップアップ: 起動時にサーバーから取得し、同じ告知は一度閉じると再表示しない。設定タブの「お知らせ」は https://sellira.jp/sellerlens/news/ を開く。
- レビュー依頼(`Store/ReviewPromptController.swift`、詳細は `REVIEW-PROMPT.md`): 累計検索10回かつ起動2日以上、直近5分に失敗・枠切れ・ペイウォール表示・ATT表示が無い、前回依頼から120日以上、直近365日で2回未満、同一バージョンで未依頼、のすべてを満たしたときだけ。起動時トリガーでは無料枠切れの間は依頼しない。
- 行動計測は PostHog(`Store/Analytics.swift`)。型で許可した列挙値しか送れず、ASIN・価格・出品者 ID などの Amazon 由来データは構造的に送れない。セッションリプレイ無効、匿名 ID のみ。

## 料金体系

| | 無料 | Pro |
|---|---|---|
| 価格 | 無料 | 月額 ¥1,980(自動更新サブスク)、初回7日間無料体験 |
| 商品 ID | - | `jp.sellira.sellerlens.pro.monthly`(`EntitlementStore.proProductID`) |
| 検索(未連携) | 1日の無料枠ユニット(Keepa 実取得1回=1ユニット。サーバーのキャッシュ命中は0) | 無制限 |
| 検索(Amazon 連携済み) | 無制限(ユニット消費0、待ち時間1秒) | 無制限 |
| グラフ | 未連携は検索直後のグラフは追加消費なし、それ以外の取得は1ユニット | 無制限 |
| OCR | 1日5回(ユニットとは別枠) | 無制限 |
| 利益アラート・仕入れリスト・出品・一括出品・出品制限チェック・Keepa キー設定 | 使えない(鍵表示から課金画面へ) | 使える(出品系は要連携) |
| 広告 | あり | なし |

- 無料枠ユニットの既定値は `server/wrangler.jsonc` の `BASE_DAILY_UNITS=5`(基本)、`UNITS_PER_AD=10`(リワード広告1本あたり)、`MAX_DAILY_UNITS=100`(1日の上限)。実際の値はサーバーの KV(`ADS_CONFIG` の `quota-limits` キー)が優先され、デプロイなしで調整できます。アプリの「無料は1日◯回」の文言は `/api/quota` が返す値から組み立てるため、数値はアプリに埋め込んでいません。
- リワード広告は AdMob の SSV(サーバー側検証)コールバック `GET /api/admob/ssv` が署名検証して枠を加算します。クライアントの自己申告は信用しません。
- 端末識別子は Keychain に保存した UUID で、アプリを再インストールしても無料枠はリセットされません。
- 課金は StoreKit 2。無料体験は App Store Connect で設定した導入オファー(7日間無料)で、期間はアプリに焼き込まず StoreKit から読み取ります。課金画面のボタン内に請求額と無料体験期間を表示します(審査 3.1.2(c) 対応)。
- 購入の検証はサーバー側で行います(`server/src/billing/`)。
  - 端末は購入・復元・起動・前面復帰のたびに署名付き取引(JWS)を `POST /api/billing/verify` へ送り、Apple 公式ライブラリ(`@apple/app-store-server-library` 3.1.0)で署名・証明書チェーン・OCSP を検証したうえで App Store Server API から最新の購読状態を取得します。
  - サーバーは匿名セッション(1年)と、最長15分の署名付き利用資格を発行します。Pro 判定はこの検証済み資格だけを見ます。旧来の自己申告ヘッダー `X-App-Plan` は信用しません。
  - App Store Server Notifications V2 は `POST /api/apple/notifications` で受信します(Production / Sandbox とも登録済み)。
  - 購読状態は `BillingDO` に保存し、購読終了から90日後に削除します。Apple 側の障害時は検証済みの状態を最終照会から最大24時間まで再利用します。
  - 運用の詳細は `docs/BILLING-OPERATIONS.md` を参照してください。

## アーキテクチャ

```
 iPhone (SwiftUI, iOS 16+)
   StoreKit 2 / AdMob / PostHog / Keychain
        |  HTTPS
        v
 Cloudflare Workers  api.sellira.jp  (barcode-sedori-api)
   src/worker.js -> src/routes.js
     |-- KV: ADS_CONFIG  ... config(広告) / notice(告知) / quota-limits(無料枠) / stats:*(広告イベント集計)
     |-- Durable Objects
     |     DeviceQuotaDO     端末ごとの日次ユニットと広告付与
     |     KeepaThrottleDO   共有 Keepa キーのトークン残量推定と適応ブレーキ(グローバルに1つ)
     |     IpRateLimitDO     クライアント IP ごとのレート制限カウンタ
     |     BillingDO         購読状態、通知の重複排除、Apple 照会の直列化
     |-- Cache API (L2) + isolate 内 LRU (L1) ... 検索結果とグラフ生データ
     |
     |--> Keepa API ................ 未連携ユーザーの検索・グラフ(共有キー or 利用者の自前キー)
     |--> Amazon SP-API (LWA OAuth) .. 連携済みユーザーの検索・手数料見積り・出品制限・出品
     |--> App Store Server API ..... 購読状態の照会(Apple からの通知 V2 も受信)
     `--> Google (gstatic) .......... AdMob SSV 検証用の公開鍵取得
```

構成図の draw.io ソースは `docs/infra.drawio` にあります。ただし現時点で収録しているのは「SP-API 認可」と「Pro 購入検証」の2図のみで、システム全体の図ではありません。

### バックエンドの要点

| 要素 | 役割 |
|---|---|
| エンドポイント | `GET /health`、`GET /api/search`、`GET /api/graph-data`、`GET /api/quota`、`GET /api/fees-estimate`、`GET /api/listings/restrictions`、`POST /api/listings`、`GET /api/ads`、`POST /api/ads/event`、`GET /api/notice`、`GET /api/admob/ssv`、`POST /api/billing/{session,verify,refresh}`、`POST /api/apple/notifications`、`GET /oauth/login`、`GET /oauth/callback`。ほかに検証用の `/api/spapi/test`、`/api/keepa-test`、`/api/keepa-throttle-demo/*`、管理用の `POST /api/admin/quota-reset`(`ADMIN_TOKEN` 必須)、旧仕様の `/api/graph` |
| 検索の経路 | リクエストに SP-API 認証情報(利用者の refresh token)があれば SP-API 経路(自分の Amazon 枠で取得、無料枠消費なし、オファー一覧と `profitInputs` を同梱)。無ければ Keepa 経路(共有キーまたは `X-Keepa-Key` の自前キー、`history=1` でグラフ用データを先入れ) |
| コード判定 | `server/src/instore/convert.js`。978/979 始まりは ISBN、チェックデジットが正しい13桁は JAN、191/192 始まり(書籍 JAN 2段目)と不正コードは未解決として扱う |
| 認可 | `server/src/billing/service.js` が入口で署名を検証し、Pro 判定を提供。出品系は Pro + SP-API 連携 + 出品者 ID が必須 |
| OAuth | `server/src/oauth.js`。state は HMAC-SHA256 署名付きの自己完結トークン(サーバー側に状態を持たない)。完了後は `barcodesedori://spapi-auth` のディープリンクでアプリへ渡し、アプリは `ASWebAuthenticationSession` で受け取って検証後に Keychain へ保存。refresh token はサーバーに保存しない |
| キャッシュ | L1 は isolate 内の LRU、L2 は Cloudflare Cache API(`server/src/sharedCache.js`)。L2 に載せるのは Keepa 経路の検索結果とグラフ生データのみ。TTL は Keepa 経路の検索30分、グラフ生データ6時間(`GRAPH_CACHE_TTL_MS`)。広告設定・告知・無料枠設定は KV を60秒キャッシュ。ローカルの `wrangler dev` では Cache API が働かない |
| コアレッシング | `server/src/keepaCoalesce.js`。同一商品への同時リクエストを1回の Keepa 取得にまとめる(isolate 内のベストエフォート) |
| Keepa スロットル | `server/src/keepaThrottle.js`。補充レート `KEEPA_REFILL_PER_MIN`(wrangler.jsonc では5)に基づきトークン残量を推定し、枯渇時は待たせず即 `keepa_busy` を返す。枯渇に向かうときは適応ブレーキで無料側を先に遅くする。Keepa プランを上げたら `wrangler.jsonc` の値も更新して再デプロイが必要 |
| IP レート制限 | `server/src/ipRateLimit.js`。共有 Keepa キーを実際に消費する経路と無料枠確認に対し、IP 単位(IPv6 は /64 に丸める)で `IP_RATE_LIMIT_PER_MIN`(20回/分)。DO 障害時は可用性を優先して許可する |
| ステージング | Worker `barcode-sedori-api-staging`(`server/wrangler.staging.jsonc`)。DO は本番と独立で、購入検証の実機確認に使う。本番ドメイン・KV は参照しない |
| 静的配信 | `server/public/` は Cloudflare の assets 設定で配信(`/health`、`/api/*`、`/oauth/*` は Worker が先に処理) |
| ローカル用 Node 版 | `server/src/index.js`(`npm start`)は Render 時代の名残の動作確認用。本番は Workers |

## ディレクトリ構成

```
.
├── ios/
│   ├── BarcodeSedori/
│   │   ├── project.yml            XcodeGen の定義(バージョン、依存パッケージ、Info.plist の元)
│   │   ├── Sources/               App / API / Ads / Models / Scanner / Store / Views
│   │   ├── Resources/             PrivacyInfo.xcprivacy、ja.lproj(日本語ローカライズ)
│   │   ├── Assets.xcassets/       アプリアイコン等
│   │   ├── BarcodeSedori.storekit ローカル StoreKit 構成(通常の実行では None を使用)
│   │   └── BarcodeSedori.xcodeproj  xcodegen で生成(git 管理外)
│   └── tests/                     swiftc 単体で実行する Swift テスト
├── server/                        Cloudflare Workers の API
│   ├── src/                       routes.js、keepa/、spapi/、billing/、各 Durable Object、oauth.js ほか
│   ├── test/                      node:test のテスト(`worker/` は workerd での Apple 署名検証の互換性試験)
│   ├── scripts/notice.js          障害告知を配信/停止する対話式スクリプト
│   ├── public/                    静的アセット
│   ├── wrangler.jsonc             本番設定
│   └── wrangler.staging.jsonc     ステージング設定
├── tools/appstore-connect/        App Store Connect API クライアント(審査状況の確認、メタデータ更新)
├── design/                        ロゴ、アプリアイコン、App Store スクリーンショット、課金画面案、Amazon 掲載用ロゴ
├── docs/
│   ├── BILLING-OPERATIONS.md      購入検証の運用手順
│   ├── infra.drawio               構成図(SP-API 認可、Pro 購入検証の2図)
│   └── superpowers/               機能ごとの設計書(specs/)と実装計画(plans/)
├── appstore-review-reply/         App Store 審査への返信文・審査メモ(提出用テキスト)
├── *.md                           企画書・引き継ぎ書・申請文言案など(主要ドキュメント一覧を参照)
├── render.yaml, DEPLOY.md         旧 Render 構成の名残(現在は使っていない)
└── .claude/, .superpowers/        Claude Code の設定と作業ログ
```

## 開発環境のセットアップ

必要なもの: Xcode(作業機は Xcode 27.1)、XcodeGen(2.46.0 で確認)、Node.js 18 以上、Cloudflare アカウント(デプロイ時)。

### iOS アプリ

```bash
brew install xcodegen
cd ios/BarcodeSedori
xcodegen generate        # project.yml から BarcodeSedori.xcodeproj を生成
open BarcodeSedori.xcodeproj
```

- 新しい Swift ファイルを追加したら、必ず `xcodegen generate` をやり直してからビルドします。
- 実機で動かす場合は Xcode の Signing & Capabilities でチームを選びます(`project.yml` に `DEVELOPMENT_TEAM` を設定済み)。カメラを使うので実機が前提です。
- 実機の Sandbox 購入を試すときは、スキームの StoreKit Configuration を None にします。
- シミュレータを起動せずにビルドだけ確認する場合:

```bash
xcodebuild -project ios/BarcodeSedori/BarcodeSedori.xcodeproj \
  -scheme BarcodeSedori -destination 'generic/platform=iOS Simulator' build
```

- 接続先は Release では `https://api.sellira.jp` に固定です。DEBUG ビルドだけ、設定タブの「サーバー設定」で別 URL(ステージング Worker など)へ切り替えられます。DEBUG には Pro 強制トグルや無料枠リセットなどの開発者向け機能もありますが、`#if DEBUG` で囲んであり Release には含まれません。
- 依存パッケージ(Swift Package Manager): `GoogleMobileAds`(11 系に固定)、`PostHog`(3 系)。

### サーバー

```bash
cd server
npm install
npm test                 # 全テスト
npx wrangler dev         # ローカル実行(npm run dev:cf でも可)
```

- 本番へのデプロイは**手動**です。`git push` では反映されません。

```bash
cd server
npx wrangler login       # ブラウザ認証が必要。未ログインならまずこれ
npx wrangler deploy
```

- `wrangler.jsonc` には `keep_vars: true` を設定してあり、ダッシュボードで設定した変数や Secrets は保持されます。ただし `vars` に書いた値はデプロイで上書きされます。ダッシュボードで値を変えたら、同じ値を `wrangler.jsonc` にも反映してからデプロイしてください(過去に `UNITS_PER_AD` で食い違いがあり、本番値の10に合わせてからデプロイしました)。
- wrangler v4 の KV 操作は既定でローカル環境を見ます。本番の値を読み書きするときは必ず `--remote` を付けてください(付け忘れると「値が無い」と誤判定します)。
- ステージング: `npx wrangler deploy --config wrangler.staging.jsonc`。
- 本番の Keepa API キーなどは Cloudflare の Secrets にだけあり、ローカルの `.env` にはありません。そのためローカルで Keepa 実データの検証はできません。

#### Secrets(名前のみ。値はリポジトリやチャットに書かない)

`npx wrangler secret put <NAME>` で登録します。秘密値をシェルの引数に書かず、標準入力から渡します。

| Secret | 用途 |
|---|---|
| `LWA_CLIENT_ID` / `LWA_CLIENT_SECRET` | Login with Amazon(SP-API の OAuth) |
| `SPAPI_APP_ID` | Seller Central のアプリ管理に表示される application_id |
| `OAUTH_STATE_SECRET` | OAuth state の HMAC 署名専用。未設定だと `/oauth/login` は 503 |
| `KEEPA_API_KEY` | 共有 Keepa キー |
| `ADMIN_TOKEN` | 無料枠リセット API 用。未設定だと 503、不一致は 403 |
| `APPLE_IAP_PRIVATE_KEY` / `APPLE_IAP_KEY_ID` / `APPLE_IAP_ISSUER_ID` | App Store Server API 用の App 内課金キー(App Store Connect API の鍵とは別物) |
| `BILLING_TOKEN_KEYS` / `BILLING_TOKEN_KEY_ID` | 匿名セッション・利用資格の署名鍵(Apple や OAuth の鍵と共用しない) |

`LWA_REFRESH_TOKEN` はどの環境にも置きません。利用者ごとの refresh token を端末から都度受け取る方式(BYO)です。公開値の `MARKETPLACE_ID`、`SPAPI_ENDPOINT`、`LWA_REDIRECT_URI` などは `wrangler.jsonc` の `vars` にあります。

## テスト

### サーバー

```bash
cd server && npm test        # node --test test/*.test.js。439件(2026-10-23 時点ですべて成功)
```

購入検証のうち Workers 上の Apple 署名検証は、テスト用 Worker で別途確認します(テスト用ルート証明書を使うため、この Worker は絶対にデプロイしない)。

```bash
cd server
npx wrangler dev --config test/worker/wrangler.json --local --port 8793
curl http://127.0.0.1:8793
```

### iOS

`ios/tests/` の Swift ファイルは、対象のソースだけを `swiftc` でコンパイルして実行する単体テストです(Xcode のテストターゲットは使っていません)。リポジトリのルートで実行します。

```bash
# 例1: 出品価格の自動入力フォールバック
swiftc -module-cache-path /tmp/sellerlens-swift-cache \
  ios/BarcodeSedori/Sources/Models/ListingModels.swift \
  ios/BarcodeSedori/Sources/Models/OffersModels.swift \
  ios/tests/ListingAutoFillFallbackTests.swift -o /tmp/lf && /tmp/lf

# 例2: 購入同期クライアント
swiftc -parse-as-library -module-cache-path /tmp/sellerlens-swift-cache \
  ios/BarcodeSedori/Sources/API/BillingClient.swift \
  ios/tests/BillingClientTests.swift -o /tmp/sellerlens-billing-client-tests
/tmp/sellerlens-billing-client-tests
```

テストは `AdaptiveBannerLayout`、`BillingClient`、`EntitlementRestore`、`GraphArchive`、`HistoryChunkStorage`、`ListingAutoFillFallback`、`ReviewPromptPolicy`、`SpApiAuthorizationCallback` の8本です。各ファイルの先頭コメントに実行コマンドがあるものと、上記のようにソースを自分で組み合わせるものがあります(`@main` を持つものは `-parse-as-library` が必要)。

## リリース手順

App Store Connect API の鍵と設定は、このリポジトリの外にあります(パスのみ記載)。

- 鍵: `~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8`
- 設定: `~/.config/appstore-connect/config.json`(`keyPath`、`keyId`、`issuerId`、`defaultAppId`)

`.p8` は Apple が再ダウンロードを許さないため、紛失すると鍵の再発行が必要です。`.gitignore` で `*.p8` を除外しています。App 内課金用の鍵(Worker の `APPLE_IAP_*`)は別物で、App Store Connect API には使えません。

### 1. バージョンとビルド番号を上げる

`ios/BarcodeSedori/project.yml` の `MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を更新し、`xcodegen generate` します。ビルド番号は App Store Connect 上で増え続ける必要があります。`Generated/Info.plist` はビルド設定を参照しているので、固定値を書かないでください(過去に固定値のせいでアップロードが拒否されました)。

### 2. アーカイブとアップロード

このMacは Xcode に Apple ID をログインしておらず証明書もないため、App Store Connect API の鍵で署名します。**必ず Release 構成**でアーカイブします。

```bash
CFG=~/.config/appstore-connect/config.json
KEY_PATH=$(node -p "JSON.parse(require('fs').readFileSync('$CFG','utf8')).keyPath.replace(/^~/, require('os').homedir())")
KEY_ID=$(node -p "JSON.parse(require('fs').readFileSync('$CFG','utf8')).keyId")
ISSUER=$(node -p "JSON.parse(require('fs').readFileSync('$CFG','utf8')).issuerId")

xcodebuild -project ios/BarcodeSedori/BarcodeSedori.xcodeproj -scheme BarcodeSedori \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/SellerLens.xcarchive -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER" archive

xcodebuild -exportArchive -archivePath /tmp/SellerLens.xcarchive \
  -exportOptionsPlist /tmp/ExportOptions.plist -exportPath /tmp/SellerLens-export \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER"
```

- `ExportOptions.plist` はリポジトリに置いていません。`method` を `app-store-connect`、`destination` を `upload` にし、`teamID` に `project.yml` の `DEVELOPMENT_TEAM` を入れて作ります。
- zsh は変数の単語分割をしないため、上記のように鍵情報は個別の変数に分けて渡します。
- GoogleMobileAds / UserMessagingPlatform の dSYM 不足の警告は出ますが、アップロード自体は成功します。
- アップロード後、`node tools/appstore-connect/status.mjs` などでビルドの `processingState` が `VALID` になるのを待ちます。TestFlight で実機確認します。
- 輸出コンプライアンス(暗号化の使用)は、`Info.plist` に `ITSAppUsesNonExemptEncryption` が無いため、ビルドごとに回答が必要です。build13 以降は App Store Connect API でビルドに `usesNonExemptEncryption=false` を設定しています(独自の暗号化は使っておらず、HTTPS のみ)。回答しないと TestFlight で `MISSING_EXPORT_COMPLIANCE` のまま配信されません。

### 3. 審査への提出

- メタデータ(説明、キーワード、スクリーンショット、審査メモ、「このバージョンの新機能」)を整え、ビルドを紐付けて提出します。
- **審査への提出は取り消しが効きにくい操作**なので、スクリプトで自動化せず、確認のうえ手動で行います。
- 却下後の再提出は、API 経由だと 409「not ready」になるため、App Store Connect の画面から行います。Resolution Center のメッセージ送受信と添付ファイルのアップロードも API に無く、Web 画面での操作が必須です。返信文の過去例は `appstore-review-reply/` にあります。

### `tools/appstore-connect/` の使い方

依存パッケージなしの Node スクリプトで、鍵のパスだけを扱い鍵の中身は出力しません。環境変数なしで動きます(一時的に別の鍵を使うときだけ `ASC_KEY_PATH` / `ASC_KEY_ID` / `ASC_ISSUER_ID` を指定)。キーのロールは App Manager 以上が必要です。

```bash
node tools/appstore-connect/status.mjs               # 審査状況、ビルド番号、却下理由まで表示
```

任意のエンドポイントを叩くときは、`asc.mjs` の CLI 実行に頼らず、`asc` を import するスクリプトを書いて実行します。**リポジトリのパスに日本語が含まれると `asc.mjs` を直接実行しても何も起きません**(`import.meta.url` の比較が一致しないため)。

```js
// /tmp/asc-run.mjs
import { asc } from '/絶対パス/tools/appstore-connect/asc.mjs';
const r = await asc('GET', '/v1/apps?limit=10');
console.log(JSON.stringify(r, null, 2));
```

できること: 審査状況・却下理由の取得、審査メモ・説明文・キーワードの更新、ビルドの差し替え、審査への提出。詳細は `tools/appstore-connect/README.md`。

## 運用

### 障害告知・お知らせ(アプリ更新なしで出せる)

```bash
cd server && npm run notice
```

対話式で「新しい告知を出す / 配信中の告知を止める」を選べます。確認画面で `yes` と正確に入力したときだけ本番 KV(`ADS_CONFIG` の `notice` キー)へ書き込みます。反映まで最大60秒かかります。リンク先は `https://sellira.jp/` 配下のみ受け付けます。一度閉じた利用者には同じ `id` の告知は再表示されません。サーバー自体が落ちている障害では出せません。

### 広告設定(AdMob)

広告枠の配信設定は KV の `ADS_CONFIG` / `config` キー(JSON: `version`、`slots`、`affiliates`)です。枠は `search_ad`、`products_bottom`、`purchase_bottom`、`settings_bottom`(バナー)と `rewarded_scan`(リワード)。アプリ側の AdMob アプリ ID は `project.yml` の `GADApplicationIdentifier` で、こちらはアプリ更新が必要です。KV の切り替えはアプリ更新が不要で、`version` を1つ上げて書き込みます。

```bash
cd server
npx wrangler kv key get "config" --binding ADS_CONFIG --remote --text   # 現在値
npx wrangler kv key put "config" --binding ADS_CONFIG --remote --path <編集したファイル>
```

本番の広告ユニットを自分でタップしないでください(無効トラフィックとして AdMob アカウント停止のリスクがあります)。`https://sellira.jp/app-ads.txt` は LP リポジトリ側で配信しています。

### 無料枠の調整とリセット

- 調整: KV の `quota-limits` キーに `{"baseDailyUnits":5,"unitsPerAd":10,"maxDailyUnits":100}` の形で書く(`--remote` 必須)。不正な JSON や範囲外の値は無視して環境変数の値に戻ります。
- 端末単位のリセット: DEBUG ビルドの 設定 → 開発者向け →「無料枠クォータをリセット」(`POST /api/admin/quota-reset`、`ADMIN_TOKEN` が必要)。

### 課金まわり

購入検証の設定・鍵更新・通知漏れの復旧・ロールバック時の注意は `docs/BILLING-OPERATIONS.md` にまとまっています。署名鍵を更新するときは `BILLING_TOKEN_KEYS` に新旧両方を入れてから `BILLING_TOKEN_KEY_ID` を新鍵へ切り替えます。旧サーバーコードへ戻すと自己申告 Pro の脆弱性が再開するため、通常の障害フォールバックとしては戻しません。

### 別リポジトリ

LP(sellira.jp、プライバシーポリシー、お知らせページ、お問い合わせ、`app-ads.txt`)は `sellira-site`(`~/Claude/Projects/sellira-site`)で管理し、push で Cloudflare Pages に自動デプロイされます。このリポジトリの GitHub は `yuriasu2/-barcode_sedori` です。

## 主要ドキュメント一覧

最新の状況を知りたいときは `SESSION-HANDOFF.md` の先頭から読みます。ただし先頭の「現在の状態」は 2026-10-03 時点で、それ以降の変更は下の「実装履歴」と `git log` で補ってください。

| ファイル | 内容 | 現在の信頼度 |
|---|---|---|
| `SESSION-HANDOFF.md` | セッション間の引き継ぎ書。新しい順の作業記録と運用ノウハウ(AdMob 切替、Keepa キャッシュ、再インストールで連携が壊れた件など) | 先頭は2026-10-03時点。下の古い節は当時の前提 |
| `APP-FEATURES.md` | 機能紹介(営業・説明用) | 概ね有効 |
| `DESIGN.md` | 初期の設計書(ローカル PC サーバー前提) | 古い。インストアコード対応や Node 構成は廃止済み |
| `FREEMIUM-PLAN.md` | フリーミアム化の企画書。StoreKit・AdMob・公開後の課題 | 冒頭にある通り、プラン別制限の数値は廃止済み |
| `docs/superpowers/specs/2026-07-31-freemium-v2-limits-design.md` | 現行の無料枠ユニット設計(クールダウン等の数値は実装と差異あり) | 概念は有効 |
| `REVIEW-PROMPT.md` | レビュー依頼の表示条件 | コードと一致 |
| `APP-STORE-SERVER-VERIFICATION-PLAN.md` | Pro 購入のサーバー検証の企画と実装状況 | 冒頭の「現在の状態」が最新 |
| `docs/BILLING-OPERATIONS.md` | 購入検証の運用手順、Secrets、鍵更新、復旧 | 有効 |
| `KEEPA-TOKEN-PLAN.md` | Keepa トークン枯渇対応の旧企画 | 旧版。新版は `docs/superpowers/specs/2026-08-02-keepa-token-depletion-design.md` |
| `CLOUDFLARE-MIGRATION-PLAN.md` | Render から Cloudflare Workers への移行計画 | 移行済みの記録 |
| `tools/appstore-connect/README.md` | App Store Connect API クライアントの使い方 | 有効 |
| `APPSTORE-CONNECT-DRAFT.md` | App Store Connect への申請文言案 | 履歴 |
| `APPSTORE-LISTING-DRAFT.md` | Amazon 販売パートナーアプリストア掲載フォームの記入案 | 古い記述あり |
| `SPAPI-APPSTORE-CHECKLIST.md` | SP-API アプリを公開・掲載するためのチェックリスト | 参考 |
| `PRIVACY-POLICY-DRAFT.md` | プライバシーポリシーの草案(公開版は LP 側) | 草案。公開版が正 |
| `appstore-review-reply/` | 審査への返信文・審査メモ | 履歴 |
| `DEPLOY.md`、`render.yaml` | 旧 Render 構成のデプロイ手順 | 古い。現在は Workers |
| `server/README.md` | 旧サーバー(Node)の README | 古い |
| `CHANGES-v2.md` 〜 `CHANGES-v6.1.md` | 2026-07 初期の改修仕様 | 履歴 |
| `docs/superpowers/specs/`、`plans/` | 機能ごとの設計書と実装計画 | 履歴として参照 |
| `CLAUDE.md` | Claude Code 向けの作業ルール(役割分担、README 更新、push 方針) | 有効 |

## 実装履歴

新しいものを上に追記します(日付、1〜2行)。

- 2026-10-12 バージョンを 1.0.3 (build 21) へ更新し TestFlight 用にアップロード。1.0.2 は承認・公開済み。
- 2026-10-12 Keepa 経路の検索結果に `feeInfo`(カテゴリの販売手数料率・成約料の有無)を追加して本番デプロイ(Worker Version `8a65a28d`)。アプリは Keepa の最安値で出品価格を自動入力し、カテゴリ別の手数料率で概算(build 21 に収録)。デプロイ前に `wrangler.jsonc` の `UNITS_PER_AD` を本番値の10へ合わせた。
- 2026-10-09 ATT を初回起動時(カメラ許可確定の約1秒後)に直接要求する方式へ変更(審査対応、build 20)。Amazon SP-API アプリ掲載審査で名前・ロゴ・価格の不一致を指摘され、正しいロゴを `design/amazon-listing/` に用意(対応結果は未確認)。
- 2026-10-07 ATT の事前説明ダイアログから先送りの選択肢を削除(build 18、5.1.1 対応)、その後ダイアログ自体を廃止して検索成功4回目に ATT を直接要求(build 19)。
- 2026-10-05 課金画面を審査 3.1.2(c) に合わせて修正。請求額を最も目立つ表示にし、購入ボタン内に請求額と無料体験期間、ボタン下に体験中の解約案内を表示(build 15〜17)。
- 2026-10-03 1.0.2 (build 14) を審査提出。日本語ローカライズ(`developmentLanguage: ja`、`ja.lproj`)、検索欄・履歴欄の入力中キャンセルボタン、レビュー依頼条件の緩和(検索10回・起動2日)を収録。審査では3回却下され、build 20 までで対応して承認・公開。
- 2026-10-03 ASO を見直し。タイトル「せどり・仕入れリサーチ - セラーレンズ」、サブタイトル「バーコードでAmazon相場・利益計算・ランキング」、キーワードを変更し、スクリーンショット全8枚を新デザイン(#4169E1)へ刷新。
- 2026-10-03 App Store Connect API の鍵を再発行して再設定。購入検証の企画書を「本番反映済み・公開中」に更新。
- 2026-09-11 スキャン履歴を100件ずつのファイルに分割保存し、履歴の各行に直近1年のランキングミニグラフを追加(1.0.1 build 11〜13)。Sandbox の Pro に共有100要求/日制限を課していた処理を撤去(`977d988`)。
- 2026-09-10 Pro 購入のサーバー検証を本番に反映(1.0.1 build 10)。Workers で Apple の OCSP 確認が失敗する問題を標準 fetch のアダプターで解消、通知 V2 を本番・Sandbox とも登録、ステージング Worker を公開。
- 2026-09-10 iOS 16 で履歴一覧が先頭商品を取り違える問題を、`List` から `ScrollView` + `LazyVStack` への移行で解消。AdMob バナーを広告枠の実幅に合わせるアダプティブサイズへ変更。
- 2026-09-09 Amazon 連携の受け取りを `ASWebAuthenticationSession` に変更。SP-API の OAuth を掲載承認後の Published 版へ切り替え。AdMob を本番 ID へ切り替え(KV `version:10`)。Pro 購入のサーバー検証(BillingDO ほか)を実装。
- 2026-09-09 までに 1.0 (build 9) が審査を通過して公開。
- 2026-08-31 ATT の審査指摘(Guideline 2.1)への返信文を作成、ビルド 9 に審査メモを合わせて再提出。
- 2026-08-23 履歴一覧の価格行に出品者数を表示(「新品:¥11849(出品者40人)」形式)。Keepa 経路の履歴で出品者数が出ない不具合を修正(build 7〜9)。
- 2026-08-22 グラフを端末に永続化して履歴から見返せるようにし、履歴の保存上限を5,000件に設定。
- 2026-08-21 審査 5.6 対応: Amazon 連携による7日間 Pro お試しを廃止し、StoreKit の導入オファー(7日間無料)へ移行。同日、Keepa キャッシュを L1/L2 の2段構成にしてグラフの TTL を6時間へ延長、検索の7秒待ちに理由と解消手段を表示。
- 2026-08-20 App Store Connect API クライアント(`tools/appstore-connect/`)を追加。無料枠の管理者向けリセット API と DEBUG 用ボタンを追加。無料枠5回目でグラフだけ消える不具合を修正。
- 2026-08-16 初回審査へ提出(build 2〜6、Guideline 2.1 で却下され再提出)。OAuth state を署名付きの自己完結トークンに変更。「商品」タブを「履歴」タブへ改名。
- 2026-08-15 アプリアイコンを新ロゴへ差し替え、iPad 扱いになる設定を修正。商品タブで利益アラート該当商品を緑枠で表示。
- 2026-08-14 アプリ名を「セラーレンズ」、Bundle ID を `jp.sellira.sellerlens` に変更。`PrivacyInfo.xcprivacy` がバンドルに入っていなかった不具合と、再インストールで出品者 ID が失われ出品系が黙って無効になる不具合(出品者 ID を Keychain へ移行)を修正。PostHog を導入。
- 2026-08-13 サーバー駆動の障害告知ポップアップと対話式スクリプト `npm run notice` を追加。仕入れリストの CSV 書き出し、カメラのピント・近距離対応を追加。
- 2026-08-09 レビュー依頼、スキャン成功時の振動設定の分離、設定タブの再編、Amazon 連携画面の集約、商品詳細・仕入れ内容のレイアウト刷新。
- 2026-08-05 〜 08-08 端末 ID を必須化しクライアント IP 単位のレート制限を追加。Keepa のキューを撤去してリクエスト・コアレッシングを導入。送料の名前付きプリセットと「最安値−配送料」の自動入力を追加。
- 2026-07-31 フリーミアム v2(無料枠ユニットとリワード広告)を実装。07-30 にサーバー管理型の広告配信(`/api/ads`)を実装。
- 2026-07-21 〜 07-29 利益アラート、仕入れリスト・出品フォーム・一括操作、出品制限チェック、SKU の重複防止、手数料と粗利益の表示を実装。
- 2026-07-14 〜 07-19 フリーミアム化(サーバー側プランゲート、StoreKit 2、AdMob)を開始、Cloudflare Workers 移行計画を作成、アプリ名を「アマレンズ」に決定。
- 2026-07-02 〜 07-05 初期版。インストアコード対応を廃止して OCR 検索を追加(v2)、Keepa グラフと価格・ランキング表示を追加(v3〜v6)。07-03 に LP を追加。
