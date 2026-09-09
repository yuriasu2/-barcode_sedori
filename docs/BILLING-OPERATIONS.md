# Pro購入検証の運用

2026-09-09: コード実装済み。本番未デプロイ、Apple Sandbox実購入・オンライン証明書確認は未検証。

## 検証サーバー（2026-09-10公開）

- URL: `https://barcode-sedori-api-staging.saastids2025.workers.dev`
- 設定: `server/wrangler.staging.jsonc`。デプロイは `cd server && npx wrangler deploy --config wrangler.staging.jsonc`。
- 初回コードデプロイVersion: `fb831f10-3cec-49ee-8f78-36a1900c9015`（その後Secretsを登録）。4つのDO名前空間は本番と独立。本番ドメイン・KVは参照しない。追加変数は`keep_vars: true`で保持。
- `/health` 200、`/api/billing/session` 200でセッション発行成功。発行セッション付きの不正購入証明は400 `invalid_purchase`で拒否。
- 本番Workerの購入設定5項目は登録確認済み。ダウンロード済みApp内課金キーと登録済みKey ID/Issuer IDで、Apple Sandbox通知履歴APIへの認証に成功（ローカルから確認、秘密値・通知本文は出力せず）。
- ユーザーの明示承認を受け、Apple課金キー3項目と検証専用BILLING_TOKEN_KEYS/BILLING_TOKEN_KEY_IDの計5項目を登録済み。署名鍵IDは`staging-v1`、鍵は32バイトの暗号学的乱数から生成。本番署名鍵・Amazon秘密情報はコピーしていない。
- Keepaキー・Amazon OAuth開始設定は未登録。まず購入・復元・Pro資格とquotaを検証する。商品検索も試す場合は外部API設定の追加が必要。

実機ではXcodeのStoreKit ConfigurationをNoneにしてRunし、アプリの「設定 → サーバー設定」（DEBUG限定）に上記URLを入力する。検証WorkerのSecrets登録後にSandbox購入を試す。終了後は `https://api.sellira.jp` へ戻す。

Sandbox通知URL候補: `https://barcode-sedori-api-staging.saastids2025.workers.dev/api/apple/notifications`。App Store Connect側への登録、通知配送、実購入、オンライン証明書確認は未実施。

## 設定と公開前確認

App ID `6801570852` / Bundle ID `jp.sellira.sellerlens` / 商品 `jp.sellira.sellerlens.pro.monthly`。
App Store Connect APIでFamily Sharing無効、Billing Grace PeriodはProduction/Sandboxとも無効を確認。
将来Grace Periodを有効にした場合もAppleのstatus=4と猶予期限で判定する。

Worker Secretsへ次を設定する。値や.p8ファイルをGit・チャット・ログへ載せない。

| Secret | 値 |
|---|---|
| `APPLE_IAP_PRIVATE_KEY` | ユーザとアクセス → 統合 → App内課金で発行した.p8の内容 |
| `APPLE_IAP_KEY_ID` | 上記キーのKey ID |
| `APPLE_IAP_ISSUER_ID` | Issuer ID |
| `BILLING_TOKEN_KEYS` | `{"v1":"専用の暗号学的乱数64文字以上"}`。Apple/OAuthの鍵と共用しない |
| `BILLING_TOKEN_KEY_ID` | `v1`など現在の発行鍵ID |

`wrangler secret put NAME`の標準入力で登録する。秘密値をシェルの引数に書かない。
秘密鍵未設定時は購入検証を503で拒否する。無料のAPIは引き続き利用できる。

公開の前に、実キーとSandbox取引で署名・OCSP確認・購読照会を通すこと。端末で新規購入、復元、別端末復元、更新、解約後の残期間、返金、通信障害からの復帰を確認する。
本番公開前の動作確認を完了するまで、この変更を本番へデプロイしない。
サーバー切替と新しいiOSビルドの配布を合わせる。公開中の旧ビルドは新しい購入検証APIに対応していない。
ユーザーの指示により自己申告Proへの案内・観測モードは追加していない。新サーバーは旧ヘッダーを無条件で信用しない。

## APIと保存

- `POST /api/billing/session`: サーバー署名付き匿名セッション（1年）とappAccountToken用UUID。
- `POST /api/billing/verify`: `X-Billing-Session`、JSON `signedTransaction`。Apple署名を検証して最新購読状態を照会。
- `POST /api/billing/refresh`: 同じセッションとJSON `refreshToken`。15分以内の検証済み状態を再利用。
- 通常API: `Authorization: Bearer <accessToken>` と `X-Billing-Session`。利用資格は最長15分、既知の購読・猶予期限を超えない。
- `POST /api/apple/notifications`: AppleのJSON `signedPayload`。署名検証と永続保存後に200。処理失敗はエラーで再送を促す。

App Store ConnectのProduction/Sandbox通知URLを `https://api.sellira.jp/api/apple/notifications`、V2に設定する（現時点では未設定）。Appleのテスト通知を送り成功を確認する。
通知による取消後も発行済み利用資格は最大15分残る。通常APIでDOを毎回照会しない設計上の上限。

購読DOのキーは環境とoriginalTransactionId。JWSはサーバー永続保存せず、検証済み購読の最小状態を保持。
通知は再照会して反映し、古い署名日時で新しい状態を上書きしない。返金確認時は再照会障害中でも保守的な状態を保存し、暫定Proを発行しない。
購読データは終了後90日で削除。通知UUIDは更新処理時に30日超を除去し、購読DO自体の削除でも消える（30日ちょうどの物理削除ではない）。生JWS・セッション・秘密鍵のログ出力は実装していない。
Apple障害中は検証済み状態だけを最終照会から最大24時間再利用。ただし既知の購読期限を超えず、新規未検証・取消済み・通知再確認待ちには適用しない。

IP単位20回/分、セッション単位10回/分、本文64KiBの上限。DO障害時は購入・利用資格を発行しない。
TestFlight/審査のSandboxも署名検証する。Sandboxの検索・グラフ要求は全体で100回/UTC日（キャッシュ読出し要求も含む）に制限し、Production購読と別予算にする。既存Keepaスロットルも有効。Xcodeローカル署名とDEBUGのPro強制は本番APIの購入証明にならない。

## 鍵更新・通知漏れ・復旧

- 署名鍵を更新するときは`BILLING_TOKEN_KEYS`へ新旧両方を入れ、`BILLING_TOKEN_KEY_ID`を新鍵へ変更。旧鍵を消すと旧セッションも失効し、StoreKit証明による再同期が必要。鍵漏洩時は旧鍵を即時削除する。
- 通知漏れは15分後の資格更新でApple再照会して補完する。Apple公式ライブラリの`getNotificationHistory`で期間を絞って取得し、各`signedPayload`を同じ通知エンドポイントへ再送できる。通知内容やJWSを公開ログに残さない。通知履歴の自動回収ジョブは今回追加していない。
- DO保存障害は503。通知を200で握り潰さない。復旧後にAppleの再送または通知履歴から再処理する。
- iOSは購入同期をKeychainへ保存できた後にfinishする。失敗時は未完了取引/currentEntitlementsから再試行する。起動・前面復帰・購入の復元・API利用が再確認の契機。
- 認証401時の自動再送はGETだけ1回。Amazonへの出品POSTは自動再送しない。
- ロールバック時は購読DOを削除しない。旧サーバーコードへ戻すと自己申告Proの脆弱性が再開するため、通常の障害フォールバックとしては行わない。

## プライバシー説明の更新

本番反映時はプライバシーポリシーの「端末識別子は無料枠管理にのみ使用」という説明と区別して、購入検証用の匿名セッションおよび購読状態のサーバー保存を追記する。記載案:

> Proプランの購入・復元と利用資格の確認のため、Appleから提供される取引識別子、商品識別子、購読の有効期限・取消状態、および匿名の利用識別子を処理します。匿名のセッション資格は端末のキーチェーンに保存します。サーバーでは購読状態を有効期間中と終了後90日間保持し、利用資格の確認と不正利用防止に使用します。Apple IDのメールアドレスや決済カード情報は取得しません。

この文面は下書き。サイト側のポリシーは本作業では更新していない。

## 再現できる検証

`cd server && npm test`。

iOS同期クライアント（ネットワーク・Keychainをテスト専用実装へ置換）:

```
swiftc -parse-as-library -module-cache-path /tmp/sellerlens-swift-cache ios/BarcodeSedori/Sources/API/BillingClient.swift ios/tests/BillingClientTests.swift -o /tmp/sellerlens-billing-client-tests
/tmp/sellerlens-billing-client-tests
```

WorkersでのApple署名検証・API JWT署名:

```
cd server
npx wrangler dev --config test/worker/wrangler.json --local --port 8793
curl http://127.0.0.1:8793
```

6項目すべてtrueを確認。テストルート証明書を使うため、このテスト用Workerは絶対にデプロイしない。
これは証明書チェーンと署名の実行互換性試験であり、実際のSandbox・Apple API権限・OCSPのネットワーク試験の代用ではない。
本番バンドルは `npx wrangler deploy --dry-run` で検証する。
