# 改修仕様 v4 — PA-API連携の全削除 + SP-API連携への置換 (2026-07-02)

v3のPA-API連携はユーザーの要望取り違えだったため**きれいに全削除**し、
代わりに**SP-API連携**を実装する: アプリ利用者が自分のAmazon大口出品アカウントの
SP-API認証情報(LWAクライアントID/クライアントシークレット/リフレッシュトークン)を
アプリの設定画面に入力し、自分のアカウントのSP-API枠で検索できるようにする。

## 1. PA-API連携の全削除

### サーバー
- `src/paapi/` ディレクトリ(client.js / isbn.js / mapper.js)削除
- `test/paapi.test.js` 削除
- routes.js: PA-API関連import・resolvePaApiCredentials・searchViaPaApi・
  `/api/paapi/test`・PA-API分岐・`source`フィールド付与を削除
- `.env.example` から PAAPI_* を削除

### iOS
- SettingsStore: paapi* プロパティ削除
- SettingsView: 「PA-API連携」セクション削除
- APIClient: X-Paapi-*ヘッダー付与・paapiTest()削除
- SearchModels: `source` フィールド・PaApiTestResult 削除
- SearchTabView: 「PA-API」バッジ削除

## 2. SP-API連携の追加

### アーキテクチャ
- 認証情報は**iOSアプリのUserDefaultsにのみ保存**し、リクエストごとにHTTPヘッダーで渡す:
  - `X-Spapi-Client-Id` / `X-Spapi-Client-Secret` / `X-Spapi-Refresh-Token`
- サーバーは認証情報を「ヘッダー > .env(LWA_CLIENT_ID等)」の優先順で解決。
  ヘッダーがあればそれを使い、なければ従来どおり.envで動作(後方互換)。

### サーバー実装
- `src/spapi/auth.js`: 認証情報セット(clientId/clientSecret/refreshToken)を引数で受け取れるよう変更。
  アクセストークンのメモリキャッシュは認証情報ごとに分離
  (キー: clientIdとrefreshTokenのハッシュ。トークン本体をキーにしない)。キャッシュ有効55分は維持。
- `src/spapi/client.js` / `pricing.js`: 認証情報を引き回せるようにする
  (callSpApi({..., credentials}) 形式。credentials未指定なら.envフォールバック)。
- routes.js:
  - `resolveSpApiCredentials(headers)`: X-Spapi-*ヘッダー(なければ.env)から解決。
    どちらにも無ければ /api/search・/api/offers は 503 でエラーメッセージ
    「SP-API認証情報が設定されていません」を返す。
  - /api/search・/api/offers の全SP-API呼び出し(searchCatalogItems/getItemOffers/getMyFeesEstimates)に
    解決した認証情報を渡す。
  - searchCache/offersCacheのキーに認証情報ハッシュの先頭8文字を含める(異なるアカウント間で結果を混ぜない)。
  - `GET /api/spapi/test` 新規: ヘッダーの認証情報でLWAトークン取得を1回試行し
    `{ ok: true }` / `{ ok: false, message }` を返す(SP-API本体は呼ばない。トークン取得成功=連携成功)。
- テスト: `test/spapi-credentials.test.js` 新規
  - resolveSpApiCredentialsの優先順(ヘッダー > env > null)
  - authのトークンキャッシュが認証情報ごとに分離されること(fetchをモック)

### iOS実装
- SettingsStore: `spapiLinkEnabled`(Bool) / `spapiClientId` / `spapiClientSecret` / `spapiRefreshToken` をUserDefaultsで永続化。3項目が揃っていて有効な場合のみ使用可とするヘルパー `isSpApiLinkUsable`。
- SettingsView: 「SP-API連携」セクション:
  - Toggle「自分のSP-APIを使用する」
  - TextField: クライアントID / SecureField: クライアントシークレット / SecureField: リフレッシュトークン
  - 「接続テスト」ボタン → GET /api/spapi/test (ヘッダー付き) → 成功/失敗アラート
  - 説明文: 「Seller Centralの『アプリ管理』で発行したSP-API認証情報を入力すると、
    自分の大口出品アカウントのAPI枠で検索できます」
- APIClient: isSpApiLinkUsable時に全リクエストへ X-Spapi-* ヘッダー付与。spapiTest()追加。
