# バーコードせどり サーバー (Node.js)

iOSアプリからのバーコードスキャン結果を受け取り、Amazon SP-API(日本)経由で
カート価格・新品/中古最安値・損益分岐点を返すローカルHTTPサーバー。

外部npmパッケージへの依存はゼロ(`dependencies: {}`)。Node.js標準の `http` / `fetch` / `https.Agent`
のみで構成しており、`express`/`dotenv` 相当の機能は `src/miniRouter.js` / `src/env.js` に
最小実装している(npmレジストリにアクセスできない環境でも `npm install` 不要で動作する)。

## セットアップ

```bash
cd server
cp .env.example .env
# .env にSP-APIの認証情報を設定
npm install
npm start
```

`http://<このPCのIP>:3000` にiOSアプリの設定画面からアクセスできるようにする(同一Wi-Fi内)。

## 環境変数 (.env)

| 変数名 | 説明 |
|---|---|
| `LWA_CLIENT_ID` | LWAクライアントID |
| `LWA_CLIENT_SECRET` | LWAクライアントシークレット |
| `LWA_REFRESH_TOKEN` | SP-API用リフレッシュトークン |
| `MARKETPLACE_ID` | 既定 `A1VC38T7YXB528` (日本) |
| `SPAPI_ENDPOINT` | 既定 `https://sellingpartnerapi-fe.amazon.com` |
| `PORT` | 既定 `3000` |
| `SPAPI_APP_ID` | Seller Centralの「アプリ管理」に表示されるapplication_id。OAuth認可フローで使用 |
| `OAUTH_BASE_URL` | このサーバーの公開URL(例: Renderのデプロイ先URL)。ディープリンク組み立てに使用 |
| `SELLER_CENTRAL_URL` | 既定 `https://sellercentral.amazon.co.jp` |

## API

### `GET /api/search?code={13桁コード}`
スキャン直後の一覧表示用。ISBN/JANを自動判定し、
Catalog Items検索 → 新品/中古オファーを並列取得してカート・新品・中古価格を返す。

### `GET /api/offers?asin={ASIN}`
詳細画面用。新品/中古オファー一覧と、各オファーの手数料見積りに基づく損益分岐点(`breakEven`)を返す。
手数料APIが失敗した場合は書籍カテゴリの既定率(15%+成約料80円)でフォールバック計算する。

### `GET /oauth/login`
利用者自身のAmazon大口出品アカウントでSP-API連携するためのOAuth認可フロー起点。
Seller Centralの認可画面(consent)へリダイレクトする。

### `GET /oauth/callback`
Amazon側からのリダイレクトを受け取り、LWAトークンエンドポイントでrefresh_tokenを取得し、
iOSアプリへディープリンク(`barcodesedori://spapi-auth`)で引き渡す。

## コード変換仕様

インストアコード(ブックオフ/TSUTAYA/GEO等)の変換・学習機能は v2 で全廃止した
(DBなしでは決定的に解決できないため)。判定は以下の4分類のみ:

- `978`/`979`始まり: ISBN-13としてそのまま検索
- `45`/`49`始まり: JANとしてそのまま検索
- `192`/`191`始まり: 書籍JANコード2段目。単独では商品を特定できないため `unresolved`(reason: `book_jan_second_line`)
- その他: `unresolved`(reason: `unsupported`)

変換ロジックは `strategy` 配列(`src/instore/convert.js`)で構成されている。

## テスト

```bash
npm test
```

`test/convert.test.js` でEAN-13チェックデジット計算とコード種別判定を検証する。
