# App Store Connect API クライアント

App Store Connect の審査ステータス確認やメタデータ更新を、Web UIを開かずに行うための最小クライアント。
**依存パッケージなし**(Node標準の `crypto` だけでES256のJWTを生成する)。

## 秘密鍵の扱い

`.p8` は **Appleが再ダウンロードを許さない秘密鍵**。紛失するとキーの再発行が必要になる。

- **リポジトリには絶対に置かない。** ルートの `.gitignore` で `*.p8` と `AuthKey_*.p8` を除外済み。
- スクリプトは鍵の**パスだけ**を環境変数で受け取り、内容を標準出力に出さない。
- キーのロールは **App Manager 以上**が必要。Developer以下だとメタデータ更新が403になる。

## 使い方

3つの環境変数を渡す。Key IDは `.p8` のファイル名（`AuthKey_<KeyID>.p8`）から分かる。
Issuer IDは App Store Connect → ユーザとアクセス → 統合 → App Store Connect API の上部に出るUUID。

```bash
export ASC_KEY_PATH="$HOME/Downloads/AuthKey_XXXXXXXXXX.p8"
export ASC_KEY_ID="XXXXXXXXXX"
export ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
```

### 審査ステータスの確認

```bash
node tools/appstore-connect/status.mjs
```

バージョンの状態・ビルド番号・メモ欄の文字数・提出物の内訳が出る。
却下されている場合はここに理由（ガイドライン番号）が出るため、Web UIを開く必要がない。

### 任意のエンドポイントを叩く

```bash
node tools/appstore-connect/asc.mjs GET "/v1/apps?limit=10"
```

### スクリプトから使う

```js
import { asc } from './tools/appstore-connect/asc.mjs';
const r = await asc('PATCH', `/v1/appStoreReviewDetails/${id}`, {
  data: { type: 'appStoreReviewDetails', id, attributes: { notes: '...' } },
});
```

## できること / できないこと

できる:

- 審査ステータス・却下理由の取得
- App Review情報（メモ欄・連絡先・デモアカウント）の更新
- 説明文・キーワード等のメタデータ更新
- ビルドの差し替え
- 審査への提出（`reviewSubmissions`）

**できない:**

- **Resolution Center のメッセージ送受信。** APIに存在せず、Web UI専用。
  却下されたときの返信は今後も手作業になる。
- 審査用添付ファイル（画面収録など）のアップロードも実質Web UI側で行う。

## 注意

**審査への提出は取り消しが効きにくい外向きの操作**なので、スクリプトで自動化しないこと。
確認のうえ手動で実行する。
