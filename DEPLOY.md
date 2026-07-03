# デプロイ手順(Render + SP-API OAuth連携)

このドキュメントでは、バーコードせどりサーバーをRenderにデプロイし、
Seller CentralのSP-APIアプリとOAuth連携できるようにするまでの手順をまとめます。

## 1. GitHubリポジトリの作成とpush

1. GitHubで新しいリポジトリを作成します(Private推奨)。
2. ローカルのプロジェクトルートでgitリポジトリを初期化し、pushします。
   ```bash
   cd "バーコードせどり"
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin <あなたのGitHubリポジトリURL>
   git push -u origin main
   ```
3. push前に必ず `.gitignore` に以下が含まれていることを確認してください。
   実認証情報を誤ってpushしないための重要な確認です。
   ```
   server/.env
   server/data/
   ```
   `.gitignore` に無い場合は追記してから `git status` で `.env` が
   トラッキング対象に含まれていないことを確認してください。

## 2. Renderでのデプロイ

1. [Render](https://render.com/) にログインします(GitHubアカウントで連携可能)。
2. ダッシュボードで **New** → **Blueprint** を選択します。
3. 先ほどpushしたGitHubリポジトリを選択します。Renderはリポジトリルートの
   `render.yaml` を自動検出し、`barcode-sedori-api` サービスの内容を提示します。
4. `render.yaml` 内で `sync: false` に指定されている環境変数は、
   セキュリティ上リポジトリに値を含めていないため、Render側の画面で
   手動入力が必要です。以下を入力してください。
   - `LWA_CLIENT_ID`
   - `LWA_CLIENT_SECRET`
   - `LWA_REFRESH_TOKEN`(お持ちの場合。無くてもOAuth連携で後から取得可能)
   - `SPAPI_APP_ID`(Seller Centralの「アプリ管理」に表示されるapplication_id)
   - `OAUTH_BASE_URL`(この時点ではまだ確定しないため、後述の手順でRenderのURLが
     発行されてから設定・再デプロイしてください)
5. デプロイを実行します。完了すると `https://barcode-sedori-api-xxxx.onrender.com`
   のようなURLが発行されます。このURLを控えてください。
6. 発行されたURLを `OAUTH_BASE_URL` に設定し、再デプロイします。

## 3. Seller Central側の設定(アプリ管理)

1. Seller Centralにログインし、開発者向け「アプリ管理」画面を開きます。
2. 対象アプリの「編集」を開き、以下のURIを登録します(Renderで発行されたURLに置き換えてください)。
   - OAuthログインURI: `https://<RenderのURL>/oauth/login`
   - OAuthリダイレクトURI: `https://<RenderのURL>/oauth/callback`
3. 保存します。

## 4. iOSアプリの設定変更

1. アプリの「設定」タブを開きます。
2. サーバーURLを、ローカルPCのURLからRenderのURL(`https://<RenderのURL>`)に変更します。
   ローカルPCサーバーと使い分けたい場合は、都度この欄を書き換えて切り替えることも可能です。

## 5. 動作確認手順

1. アプリの「設定」タブ → 「SP-API連携」セクションの
   「SP-API認証を開始」ボタンをタップします。
2. Amazonのログイン画面が開くので、Amazonアカウントでログインします。
3. アプリへのアクセス許可画面が表示されるので、内容を確認して「承認」します。
4. 承認後、自動的にアプリに戻り、「SP-API連携が完了しました」というアラートが
   表示されることを確認してください。
5. 設定画面で「連携済み」の表示になっていること、「接続テスト」ボタンで
   接続成功と表示されることを確認してください。

## 6. 注意事項

- Renderの無料プラン(Free)は一定時間アクセスが無いとスリープし、
  次回アクセス時に起動まで時間がかかります。本番運用では
  Starterプラン(月額$7程度)へのアップグレードを推奨します。
- ローカル(自宅PC等)で動かすサーバーも引き続き使用可能です。
  アプリの設定画面でサーバーURLを切り替えるだけで、Render版とローカル版を
  使い分けることができます。
