# バーコードせどり — 設計書

## 概要
商品バーコード(ISBN/JAN)およびブックオフ・TSUTAYA・GEOのインストアコードをスキャンし、
Amazon SP-API経由でカート価格・新品価格・中古最安値を即時表示するiOSアプリ+ローカルバックエンド。

## 構成

```
[iPhone: SwiftUIアプリ] --HTTP(同一Wi-Fi)--> [PC: Node.jsサーバー] --HTTPS--> [Amazon SP-API (FE/日本)]
```

- SP-API認証情報(LWA Client ID/Secret/Refresh Token)はサーバー側 .env のみに保持。アプリには置かない。
- マーケットプレイスID: `A1VC38T7YXB528`(日本) / エンドポイント: `https://sellingpartnerapi-fe.amazon.com`

## リポジトリ構成

```
server/            Node.js 18+ (Express, 依存最小)
  src/index.js         起動・ルーティング
  src/spapi/auth.js    LWAトークン取得+メモリキャッシュ(有効55分)
  src/spapi/client.js  SP-API呼び出し(fetch, 429リトライ指数バックオフ, keep-alive)
  src/instore/convert.js  コード種別判定+インストア→ISBN/JAN変換
  src/routes.js        /api/search, /api/offers
  src/cache.js         結果LRUキャッシュ(TTL 5分)
  test/convert.test.js  変換ロジックのユニットテスト(node:test)
  .env.example
ios/BarcodeSedori/   SwiftUI (iOS 16+), XcodeGen project.yml
  Sources/App.swift
  Sources/Scanner/ScannerView.swift      AVFoundationカメラ+EAN13検出
  Sources/Models/*.swift
  Sources/Views/SearchTabView.swift      スキャン画面+結果リスト(参考画像1)
  Sources/Views/ProductDetailView.swift  価格一覧(参考画像2)
  Sources/Views/SettingsView.swift       サーバーURL設定
  Sources/API/APIClient.swift
DESIGN.md
README.md            セットアップ手順(SP-API設定, XcodeGen, 実行方法)
```

## コード判定・変換仕様 (`convert.js`)

入力は13桁EANを想定。判定順:

| 先頭 | 種別 | 処理 |
|---|---|---|
| 978 / 979 | ISBN-13 | そのままISBNとして検索 |
| 45 / 49 | JAN | そのままEANとして検索 |
| 192 / 191 | 書籍2段目JAN | 無視(ISBN側の読取を待つ)。単独入力時はエラー |
| 99 (13桁) | ブックオフ インストア | `99 + ISBN13下10桁(978除去) + CD` と解釈 → `978 + 中10桁` にJANチェックデジットを再計算してISBN-13復元。CD不一致なら失敗扱い |
| 20〜29 | ブックオフ旧形式/GEO等の可能性 | 既知パターンを順に試行(実装時にWeb調査で確定)。復元不可なら `unresolved` |
| その他(TSUTAYA/GEO独自) | インストア | 決定的変換が公開されていないため、①既知パターン試行 ②ローカル学習テーブル(instore→ASINの対応をSQLite/JSONに保存。未知コードはアプリ側で「続けて商品バーコードをスキャン」を促しペアを学習) |

実装エージェントへの指示: ブックオフ99形式は必ず実装+テスト。TSUTAYA/GEOは追加調査の上、
決定的変換が見つかればstrategy追加、なければ学習テーブル方式で対応。変換はstrategy配列で拡張可能にする。

## API契約

### GET /api/search?code={13桁}
スキャン直後の一覧表示用。レスポンス目標 < 1.5s。

```json
{
  "codeType": "isbn|jan|instore_bookoff|instore_learned|unresolved",
  "asin": "B0...",
  "title": "...",
  "isbn13": "9784471103644",
  "imageUrl": "https://...",
  "salesRank": 162,
  "prices": { "cart": 972, "new": 972, "used": 873, "points": {"cart":646,"new":646,"used":615} }
}
```

処理: 変換 → Catalog Items `searchCatalogItems`(identifiers, includedData=summaries,images,salesRanks) → ASIN確定 →
Product Pricing `getItemOffers`(New) と `getItemOffers`(Used) を**並列**実行。
cart=BuyBoxPrices.New.LandedPrice、new=最安New LandedPrice、used=最安Used LandedPrice。結果はLRUへ。

### GET /api/offers?asin={ASIN}
詳細画面用。`getItemOffers` New/Used並列 + `getMyFeesEstimates`(バッチ, 各オファー価格で手数料見積) 。

```json
{
  "referencePrice": 1700,
  "releaseDate": null,
  "new": [ { "price": 2680, "shipping": 0, "landed": 2680, "isBuyBox": false,
             "sameCount": 1, "breakEven": 2150 } ],
  "used": [ { "condition": "VeryGood", "price": 873, ... } ]
}
```

損益分岐点 breakEven = landed − 販売手数料 − カテゴリ成約料 − (FBA想定なら配送代行手数料)。
手数料APIが失敗した場合はカテゴリ既定率(書籍15%+成約料80円)でフォールバック計算。

### 速度対策
- LWAトークンをメモリキャッシュ、HTTP keep-aliveエージェント共有
- search/offersともASIN単位LRU(TTL5分)。同じ棚の再スキャンが即時になる
- 429はRetry-After尊重+ジッター付きリトライ(最大3回)
- サーバーは全SP-API呼び出しを可能な限り並列化

## iOSアプリ仕様 (SwiftUI, iOS16+)

### スキャン(検索タブ) — 参考画像1
- AVFoundation `AVCaptureMetadataOutput`(ean13, ean8)。DataScannerより低レイテンシ・省電力
- `rectOfInterest` を画面上部のスキャン枠に限定して検出を高速化。検出枠を緑でハイライト
- 同一コードは3秒間デデュープ。読取時に触覚フィードバック+効果音
- 下部トグル「バーコード / インストアコード」(見た目のみ。判定はサーバー側で自動だが、インストア選択時は192/191始まりも送信)
- 読取→即結果リスト先頭に「検索中…」プレースホルダ行を挿入→レスポンスで置換(体感速度優先)
- 結果行: 商品画像 / タイトル / ISBN / ランキング / カート価格・新品価格・中古価格(+ポイント)。参考画像1のレイアウト踏襲
- 行タップ→詳細画面へ

### 詳細画面 — 参考画像2
- 商品情報: 参考価格・発売日
- 新品(n件)/中古(n件)セクション: 各オファーの価格・送料・合計(大字)・「同(x件)」「カート」バッジ・右側に損益分岐点
- Pull to refreshで再取得

### 設定タブ
- サーバーURL(例 `http://192.168.x.x:3000`)をTextFieldで保存(UserDefaults)。接続テストボタン
- Info.plist: `NSAppTransportSecurity` → `NSAllowsLocalNetworking` (ローカルHTTP許可)、カメラ使用許可文言

### タブ構成
検索 / 商品(スキャン履歴) / 仕入れ(プレースホルダ) / 設定

### ビルド
XcodeGen `project.yml` を同梱。`brew install xcodegen && cd ios/BarcodeSedori && xcodegen` で .xcodeproj 生成。

## 環境変数 (.env)
```
LWA_CLIENT_ID=
LWA_CLIENT_SECRET=
LWA_REFRESH_TOKEN=
MARKETPLACE_ID=A1VC38T7YXB528
SPAPI_ENDPOINT=https://sellingpartnerapi-fe.amazon.com
PORT=3000
```
