# App Store Connect API クライアント

App Store Connect の審査ステータス確認やメタデータ更新を、Web UIを開かずに行うための最小クライアント。
**依存パッケージなし**(Node標準の `crypto` だけでES256のJWTを生成する)。

## セットアップ済み（2026-08-20）

このマシンでは設定済みで、**環境変数なしでそのまま動く**。

| | 場所 |
|---|---|
| 秘密鍵 | `~/.appstoreconnect/private_keys/AuthKey_*.p8`（`600`） |
| 設定 | `~/.config/appstore-connect/config.json`（`600`） |

実際のKey ID・Issuer IDは `config.json` にのみ書く。リポジトリには固有値を残さない。

どちらもリポジトリ外にあるため、**別セッション・別プロジェクトからでも同じように使える**。

`config.json` の形式（秘密鍵の中身は書かない。パス参照だけ）:

```json
{
  "keyPath": "~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8",
  "keyId": "XXXXXXXXXX",
  "issuerId": "00000000-0000-0000-0000-000000000000",
  "defaultAppId": "6801570852"
}
```

認証情報の解決順は **環境変数 → `config.json`**。一時的に別のキーを使いたいときだけ
`ASC_KEY_PATH` / `ASC_KEY_ID` / `ASC_ISSUER_ID` を上書きすればよい。

## 秘密鍵の扱い

`.p8` は **Appleが再ダウンロードを許さない秘密鍵**。紛失するとキーの再発行が必要になる。

- **リポジトリには絶対に置かない。** ルートの `.gitignore` で `*.p8` と `AuthKey_*.p8` を除外済み。
- `~/Downloads` に置いたままにしない（整理や自動削除で消えるため）。上記の固定パスへ置く。
- スクリプトは鍵の**パスだけ**を扱い、内容を標準出力に出さない。
- キーのロールは **App Manager 以上**が必要。Developer以下だとメタデータ更新が403になる。

## 使い方

### 審査ステータスの確認

```bash
node tools/appstore-connect/status.mjs
```

バージョンの状態・ビルド番号・メモ欄の文字数・提出物の内訳が出る。
却下されている場合はここに理由（ガイドライン番号）が出るため、Web UIを開く必要がない。

別のアプリを見るときは引数でアプリIDを渡す:

```bash
node tools/appstore-connect/status.mjs 1234567890
```

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
