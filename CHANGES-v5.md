# 改修仕様 v5 — SP-API OAuth認可フロー + Renderデプロイ対応 (2026-07-02)

目的: 利用者がアプリの「SP-API認証を開始」ボタンを押すと、SafariでAmazonログイン→同意画面が開き、
承認するとアプリに利用者のリフレッシュトークンが自動で渡る(Amacode方式)。
アプリ(サーバー)側のLWAクライアントID/シークレットで認可コードを交換するため、
利用者はキー入力不要。アプリはDraft状態のまま `version=beta` で動作させる。

## 認証情報モデルの変更 (サーバー)

resolveSpApiCredentials を「部分オーバーライド」方式に変更:
- clientId / clientSecret: **常にサーバーの .env (LWA_CLIENT_ID / LWA_CLIENT_SECRET)** を使用
  (OAuthで得たトークンはこのアプリのクライアントIDに紐づくため)
- refreshToken: ヘッダー `X-Spapi-Refresh-Token` を優先、なければ .env の LWA_REFRESH_TOKEN
- 旧ヘッダー X-Spapi-Client-Id / X-Spapi-Client-Secret は受け取っても無視してよい(削除)
- どちらにもrefreshTokenが無ければ503(既存メッセージ維持)

## サーバー: OAuthエンドポイント (src/oauth.js 新規 + routes.js統合)

環境変数追加(.env.example):
```
SPAPI_APP_ID=            # Seller Centralのアプリ管理に表示されるapplication_id (amzn1.sp.solution....)
OAUTH_BASE_URL=          # このサーバーの公開URL (例 https://barcode-sedori.onrender.com)。ディープリンク組み立てに使用
SELLER_CENTRAL_URL=https://sellercentral.amazon.co.jp
```

### GET /oauth/login
1. ランダムstate(crypto.randomBytes 16進32文字)を生成し、メモリMapに保存(TTL10分、上限100件)
2. 302リダイレクト:
   `{SELLER_CENTRAL_URL}/apps/authorize/consent?application_id={SPAPI_APP_ID}&state={state}&version=beta`
3. SPAPI_APP_ID未設定なら500でエラーメッセージ表示(設定手順のヒント付きプレーンテキスト)

### GET /oauth/callback
クエリ: `state`, `spapi_oauth_code`, `selling_partner_id`
1. stateを検証(不一致/期限切れは403のHTML表示)
2. LWAトークンエンドポイント `https://api.amazon.com/auth/o2/token` にPOST:
   `grant_type=authorization_code&code={spapi_oauth_code}&client_id={LWA_CLIENT_ID}&client_secret={LWA_CLIENT_SECRET}`
3. 成功 → refresh_token取得 → HTMLページを返す:
   - `barcodesedori://spapi-auth?refresh_token={URLエンコード}&selling_partner_id={id}` への自動リダイレクト
     (meta refresh + JSのlocation.href + 手動タップ用リンクの三重フォールバック)
   - 自動で戻れない場合に備え、同ページにリフレッシュトークンをコピー可能なテキストで表示
     (「アプリの設定画面に貼り付けてください」の説明付き)
4. 失敗 → エラー内容(機密を含めず)をHTML表示
5. refresh_tokenはサーバーに**保存しない**(ログにも出さない)。将来のDB導入(Supabase)時に永続化する設計とし、コメントで明記

## Renderデプロイ対応

- server/render.yaml 新規:
  ```yaml
  services:
    - type: web
      name: barcode-sedori-api
      runtime: node
      rootDir: server
      buildCommand: npm install
      startCommand: npm start
      envVars:
        - key: LWA_CLIENT_ID
          sync: false
        - key: LWA_CLIENT_SECRET
          sync: false
        - key: LWA_REFRESH_TOKEN
          sync: false
        - key: SPAPI_APP_ID
          sync: false
        - key: OAUTH_BASE_URL
          sync: false
        - key: MARKETPLACE_ID
          value: A1VC38T7YXB528
        - key: SPAPI_ENDPOINT
          value: https://sellingpartnerapi-fe.amazon.com
  ```
  ※render.yamlはリポジトリルートに置く(rootDir: serverでserver/を指す)
- サーバーは既にPORT環境変数対応済み(Renderが自動注入)なのでコード変更不要のはず。0.0.0.0でlistenしていることを確認(していなければ修正)
- ルートに DEPLOY.md 新規: 手順書(下記の内容を丁寧に):
  1. GitHubリポジトリ作成とpush(gitignoreに.env/dataが入っていること確認)
  2. Render: New → Blueprint → リポジトリ選択 → 環境変数入力
  3. Seller Central アプリ管理: 対象アプリの「編集」→ OAuthログインURI `https://<render>/oauth/login`、OAuthリダイレクトURI `https://<render>/oauth/callback` を登録
  4. アプリの設定タブでサーバーURLをRenderのURLに変更
  5. 動作確認: 設定→SP-API認証を開始→Amazonログイン→承認→アプリに戻る
  6. 注意: Render無料プランはスリープするため本番は Starter($7/月)推奨。ローカル(PC)サーバーも引き続き使用可

## iOS

### URLスキーム
- project.yml の info.properties に CFBundleURLTypes 追加: スキーム `barcodesedori`
- App.swift(または適切な場所)で `.onOpenURL`:
  `barcodesedori://spapi-auth?refresh_token=...` を受けたら
  SettingsStore.spapiRefreshToken に保存し spapiLinkEnabled=true、
  「SP-API連携が完了しました」アラート(またはバナー)表示

### SettingsView 「SP-API連携」セクション改修
- 主導線: 「SP-API認証を開始」ボタン → `UIApplication.shared.open({サーバーURL}/oauth/login)`
- 連携済み表示: refreshToken保存済みなら「連携済み ✓」+「連携を解除」ボタン(トークン削除)
- 手動入力(リフレッシュトークンのみ)は「詳細設定」DisclosureGroupに残す
  (クライアントID/シークレットの入力欄は削除 — サーバー側の値を使うため)
- 接続テストボタンは維持(X-Spapi-Refresh-Tokenヘッダーのみ送る形に)

### APIClient
- X-Spapi-Client-Id / X-Spapi-Client-Secret ヘッダー送信を削除。
  X-Spapi-Refresh-Token のみ(spapiLinkEnabledかつトークンあり時)

## テスト (server)
- test/oauth.test.js 新規:
  - stateの生成/検証/期限切れ
  - /oauth/login が302で正しいURL(application_id, state, version=beta含む)を返す
  - /oauth/callback のstate不一致が403
  - LWA交換成功時のHTML内に barcodesedori:// ディープリンクが含まれる(fetchモック)
- 既存 spapi-credentials.test.js を新しい解決ロジック(refreshTokenのみヘッダー優先)に更新
