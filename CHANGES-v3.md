# 改修仕様 v3 — PA-API(Product Advertising API 5.0)連携 (2026-07-02)

目的: アプリ利用者が自分のAmazonアカウント(大口出品者/アソシエイト)のPA-API認証情報を
アプリの設定画面に入力し、自分のPA-API枠で商品検索できるようにする(Amacodeと同様の方式)。

## 認証情報 (利用者が用意するもの)
- アクセスキー (Access Key)
- シークレットキー (Secret Key)
- パートナータグ / トラッキングID (例: xxxx-22)

## アーキテクチャ
- 認証情報は**iOSアプリのUserDefaultsにのみ保存**し、リクエストごとにHTTPヘッダーでサーバーへ渡す:
  - `X-Paapi-Access-Key` / `X-Paapi-Secret-Key` / `X-Paapi-Partner-Tag`
- サーバーは受け取ったヘッダーの認証情報でPA-APIを呼ぶ(サーバー側保存なし)。
  ヘッダーがない場合は .env の `PAAPI_ACCESS_KEY` / `PAAPI_SECRET_KEY` / `PAAPI_PARTNER_TAG` をフォールバックとして使用(任意設定)。
- PA-API認証情報が(ヘッダーにも.envにも)ない場合は従来どおりSP-APIのみで動作。

## サーバー実装

### src/paapi/client.js (新規)
PA-API 5.0 呼び出し。依存ゼロ(node:crypto)でAWS SigV4署名を実装する。
- Host: `webservices.amazon.co.jp` / Region: `us-west-2` / Service: `ProductAdvertisingAPI`
- POST JSON。ヘッダー `x-amz-target`:
  - GetItems: `com.amazon.paapi5.v1.ProductAdvertisingAPIv1.GetItems` (path `/paapi5/getitems`)
  - SearchItems: `com.amazon.paapi5.v1.ProductAdvertisingAPIv1.SearchItems` (path `/paapi5/searchitems`)
- 共通ボディ: `PartnerTag`, `PartnerType: "Associates"`, `Marketplace: "www.amazon.co.jp"`
- Resources:
  `ItemInfo.Title`, `ItemInfo.ExternalIds`, `Images.Primary.Large`,
  `Offers.Summaries.LowestPrice`, `Offers.Summaries.OfferCount`,
  `Offers.Listings.Price`, `BrowseNodeInfo.WebsiteSalesRank`
- SigV4: 標準的な canonical request → string to sign → HMAC-SHA256 チェーン。
  署名ヘッダーは host / x-amz-date / x-amz-target / content-encoding(なし可) / content-type。
- 429/5xxリトライは既存client.jsと同方針(最大2回)。

### /api/search へのPA-API統合 (routes.js)
PA-API認証情報が利用可能な場合、SP-APIの代わりにPA-APIで検索する:
1. コード変換(既存convertCode)でISBN/JAN確定
2. ISBN-13(978始まり) → ISBN-10へ変換(mod11チェック文字再計算、10=X)。**書籍はISBN-10がそのままASIN**なので `GetItems(ItemIds:[isbn10])` で1発取得
3. 979始まりISBN・JAN → `SearchItems(Keywords: code, SearchIndex: "All", ItemCount: 1)`
4. レスポンスを既存のJSON契約にマッピング:
   - title = ItemInfo.Title.DisplayValue
   - imageUrl = Images.Primary.Large.URL
   - salesRank = BrowseNodeInfo.WebsiteSalesRank.SalesRank (なければnull)
   - prices.cart = Offers.Listings[0].Price.Amount (フィーチャードオファー=カート相当)
   - prices.new = Offers.Summaries[Condition=New].LowestPrice.Amount
   - prices.used = Offers.Summaries[Condition=Used].LowestPrice.Amount
   - asin = 取得したASIN
5. PA-APIがエラー(TooManyRequests/InvalidSignature等)の場合は**SP-APIへ自動フォールバック**し、
   レスポンスに `source: "spapi"` を付ける。PA-API成功時は `source: "paapi"`。
- キャッシュは既存searchCacheを流用(キーにソースを含めない)。
- /api/offers (詳細画面)は従来どおりSP-API(手数料見積が必要なため)。

### GET /api/paapi/test (新規)
ヘッダーの認証情報で軽いGetItems(適当な既知ASIN例 `4478025819`)を1回実行し、
`{ ok: true }` または `{ ok: false, message }` を返す接続テスト用エンドポイント。

### .env.example に追記
```
# PA-API (任意。アプリの設定画面から送る場合は不要)
PAAPI_ACCESS_KEY=
PAAPI_SECRET_KEY=
PAAPI_PARTNER_TAG=
```

### テスト (test/paapi.test.js 新規)
- SigV4署名: 固定の日時・キー・ボディで署名文字列がAWS公式の計算手順と一致すること
  (crypto実装の回帰テスト。既知ベクトルを自作してよいが計算過程の各段階を検証する)
- ISBN-13→ISBN-10変換 (9784535516519 → 4535516510、チェック文字X のケースも)
- PA-APIレスポンス(モックJSON)→API契約JSONへのマッピング

## iOS実装

### SettingsView に「PA-API連携」セクション追加
- Toggle「PA-APIを使用する」
- TextField: アクセスキー / シークレットキー(SecureField) / パートナータグ(トラッキングID)
- 「接続テスト」ボタン → GET /api/paapi/test (ヘッダー付き) → 成功/失敗をアラート表示
- 説明文: 「Amazonアソシエイト・セラーアカウントのPA-API認証情報を入力すると、
  自分のAPI枠で検索できます(検索が高速化され、共有制限の影響を受けません)」
- SettingsStore に保存(UserDefaults): paapiEnabled, paapiAccessKey, paapiSecretKey, paapiPartnerTag

### APIClient
- paapiEnabled かつ3項目が空でない場合、全リクエストに
  `X-Paapi-Access-Key` / `X-Paapi-Secret-Key` / `X-Paapi-Partner-Tag` ヘッダーを付与
- paapiTest() メソッド追加 (GET /api/paapi/test)

### 検索結果への表示(任意・小さく)
SearchResultRowに `source` があれば小さく「PA-API」バッジを表示(デバッグ確認用)。
SearchResultモデルに `source: String?` を追加(後方互換のためOptional)。
