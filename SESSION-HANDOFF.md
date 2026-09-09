# セッション引き継ぎ(2026-08-21 更新)

## 2026-09-09 Amazon認可の更新

- ユーザー指定で `ASWebAuthenticationSession` のみ導入。AmazonAuthorizationSessionがセッションと表示ウィンドウを保持し、完了結果の検証後にKeychain保存する。
- 通常の `onOpenURL` 経由のSP-API認可受信は廃止。キャンセル・エラー時は既存連携を保持。外部Safariへのフォールバックは設けない。
- サーバー、Universal Links、PKCE、短命コードは変更なし。URL/HTMLへのトークン埋め込みは残る。
- バージョン/ビルド番号は未変更。公開済みアプリにはまだ反映されない。実機でAmazon認可成功・キャンセル・再連携・シート経由の開始を確認してから新ビルドを提出する。
- コールバック検証テスト: `swiftc -module-cache-path /tmp/sellerlens-swift-cache ios/BarcodeSedori/Sources/Models/SpApiAuthorizationCallback.swift ios/tests/SpApiAuthorizationCallbackTests.swift -o /tmp/sellerlens-oauth-tests && /tmp/sellerlens-oauth-tests`
- 検証結果: 上記テスト、generic iOS Simulator向けの署名なしDebugビルド成功。シミュレーターは起動していない。既存箇所の非推奨API・Swift 6移行向け警告は残る。`docs/infra.drawio` はdraw.io CLIでSVG書き出し成功。
- 掲載承認後のサーバー対応も実施。通常の認可URLから`version=beta`を除去し、`SPAPI_AUTH_VERSION=beta`の明示時だけDraft版へ切替可能にした。初回LWAトークン交換へ、必須設定`LWA_REDIRECT_URI`の値を`redirect_uri`として送る。
- 本番設定は`LWA_REDIRECT_URI=https://api.sellira.jp/oauth/callback`、`SPAPI_AUTH_VERSION`未設定。Worker Version ID `afa55254-cec3-443a-921f-f9357f7d195b`としてデプロイ済み。本番`/oauth/login`が302を返し、転送先に`version`が含まれないことを確認済み。
- OAuth単体17件、サーバー全417件、Wrangler dry-run成功。残件は第三者セラーによる本番OAuthの通し確認。

アプリ名: **セラーレンズ**(旧アマレンズ、さらに前は「バーコードせどり」)。
Amazonセラー向けの仕入れリサーチiPhoneアプリ。**App Storeへ初回申請中**。

## 関連リポジトリ

| 対象 | 場所 | デプロイ |
|---|---|---|
| iOSアプリ＋サーバー | このディレクトリ / `yuriasu2/-barcode_sedori` | サーバーは**手動** `cd server && npx wrangler deploy` |
| LP(sellira.jp) | `~/Claude/Projects/sellira-site` / `yuriasu2/sellira-site` | push→Cloudflare Pages が自動 |

## 現在の状態(2026-08-21)

### App Store審査

**2度目の却下(REJECTED)。ビルド6。対応方針は決定済み・未着手。**

状態はWeb UIを開かなくてもAPIで確認できる:

```bash
node tools/appstore-connect/status.mjs
```

経緯: 8/16初回提出 → 8/17 **Guideline 2.1** で却下(審査メモの情報不足)→ 8/20再提出
→ **8/21 Guideline 5.6 と 4.8 で再び却下**(審査端末: iPad Air 11-inch M3)。

#### 却下1: Guideline 5.6 Developer Code of Conduct 【要修正】

> the app paid contents are free for 7 days if users connect with Amazon account

指摘の実質は「**Pro機能の無料体験を、StoreKitの無料トライアルではなくAmazon連携という
自前の条件で配っている**」こと。実際、サブスク`jp.sellira.sellerlens.pro.monthly`には
導入オファー(無料トライアル)が**1件も設定されていない**(ASC APIで確認済み)。

**方針(A)を2026-08-21に実装済み**: Amazon連携特典の7日間お試しを**廃止**し、
App Store Connectでサブスクに**7日間の無料トライアル(導入オファー)**を設定した。

- サーバー: `requireProByoCredentials()`のお試し分岐、`/api/trial-status`、`sellerTrial.js`、
  `sellerTrialDurableObject.js`を削除。`wrangler.jsonc`は`SELLER_TRIAL`バインディングと
  `SPAPI_TRIAL_DAYS`を削除し、migration v5で`SellerTrialDO`を`deleted_classes`に指定。
  **未デプロイ**(DO削除を含むため、デプロイ時は内容を確認してから実行すること)。
- アプリ: `isProOrTrial`を廃止し全22箇所を`isPro`へ。無料体験中も通常の購読者として
  `isPro`がtrueになるためゲートは1本で足りる。PaywallViewは導入オファーが使えるとき
  「最初の7日間無料 / その後 ¥1,980 / 月」＋「無料で始める」に変わる。期間はApp Store
  Connect側の設定を読み取り、アプリに焼き込んでいない。
- App Store Connect: `jp.sellira.sellerlens.pro.monthly` に導入オファー
  (ONE_WEEK / FREE_TRIAL / numberOfPeriods=1、開始2026-08-21・終了なし)を
  **価格設定済みの175地域すべてへ登録済み**(ASC APIで作成。`introductoryOffers`で確認できる)。
- `BarcodeSedori.storekit`にも同じ導入オファー(P1W・無料)を追加し、ローカルで確認できる。

**残した仕様と、その理由**: 「Amazon連携が必要な機能(出品制限・出品登録・価格一覧)は
Pro＋連携が条件」という構造はそのまま。また**連携済みなら無料プランでもスキャン無制限**
も残した(ユーザー判断)。1日5回の制限はKeepa APIの費用が理由で、連携すると価格取得が
利用者自身のAmazon枠で行われ費用が発生しないため制限する理由が無い、という技術的な事情。
**形としては5.6の指摘(外部アカウント連携で有料機能が開く)と似ているため、再提出時の
審査メモでこの理由を明記すること。**

#### 却下2: Guideline 4.8 Login Services 【返信で反論する。コード修正不要】

**反論が通る見込みが高い**。根拠:

- このアプリには**ユーザーアカウントの概念が一切ない**(ログイン画面もサインアップも無く、
  `ASAuthorization`の参照はソースにゼロ)。全機能が匿名で動く。
- Amazon認可(SP-API OAuth)はアプリの主アカウントの作成・認証ではなく、
  **利用者自身のAmazon出品用アカウントのデータ**(出品制限・出品登録)にアクセスするための
  任意の連携。
- 4.8には「特定のサードパーティサービスにアクセスするためのアプリで、利用者が自分の
  アカウントへ直接サインインしてコンテンツにアクセスする場合」という**明示的な適用除外**があり、
  本件はこれに当たる。
- Sign in with Appleを足しても**サインイン先が存在しない**(Appleアカウントでは他人の
  Amazon出品データは取れない)ため機能的に無意味。

**注意**: 5.6の「連携すれば有料機能が無料」が残っていると「その連携は任意です」という
4.8の主張の説得力が落ちる。**5.6の修正と4.8の返信は同時に出すこと。**

却下メール全文は本ファイル末尾の履歴ではなくResolution Centerにある。返信は
**Web UI操作が必須**(Resolution CenterはASC APIに無い)。

#### 前回(8/17 Guideline 2.1)への対応内容

- 却下理由の8項目に答える英文を作成 → Resolution Centerへ**2通に分けて**投稿(1通4000文字上限のため)
- 画面収録(iPhone 16e / iOS 26.6.1)を添付
- App Review情報の**メモ欄に3999文字版**を登録
- ビルドを6に差し替え(下記のグラフ不具合修正を含めるため)

文面はすべて `APPSTORE-CONNECT-DRAFT.md` と `appstore-review-reply/` にある。
**次に却下された場合、返信はWeb UI操作が必須**(Resolution CenterはAPIに無い)。

### 却下対応中に見つけて直した不具合

- **無料枠5回目でグラフだけ消える**(`2d429bd`)。表示判定に「次のスキャンができるか」
  (`quota.canScanToday`)を使っていたため、開始時の楽観的減算(`consumeLocally()`)により
  最後の1回で必ず消えていた。「今回の検索が枠切れで拒否されたか」で判定するよう修正。
- リワード広告のログが`#if DEBUG`で囲まれておらず、本番に広告ユニットIDが残っていた(`fd68091`)。

### 次回ビルドで直すこと(申請中のため今は触らない)

`project.yml` の `NSLocalNetworkUsageDescription` を削除する。Releaseでは接続先が
`https://api.sellira.jp` に固定されローカルネットワークを一切使わないのに権限説明が残っている。
しかも文面が「PC上のサーバーが必要なアプリ」と読め、審査担当者に誤解を与える。

### 未デプロイ・未反映

- **サーバーは2026-08-21にデプロイ済み**(Version `3c13787f`)。溜まっていた無料枠クォータの
  管理者リセットAPI(`21a3d90`)も反映され、**`ADMIN_TOKEN` secret も登録済み**
  (アプリ側 `APIClient.AdminConfig.token` と同じ値。DEBUGビルド専用)。
  設定 → 開発者向け → 「無料枠クォータをリセット」が実際に使える状態。
  無効化されていないことは、誤ったトークンで叩いて **503ではなく403** が返ることで確認できる。
- **AdMobは2026-09-09に本番IDへ切り替え済み**。本番KV `ADS_CONFIG` は `version:10`。`https://sellira.jp/app-ads.txt` も公開済みで、AdMob管理画面の再クロールとSSV設定確認が残っている（手順は本ファイル後半）。
- サーバーテストは438件パス(2026-08-21時点)。

### Keepaトークンの容量見積もり(2026-08-21)

無料トライアルをStoreKit方式へ変える(5.6対応)と、**Keepa共有枠の負荷が確実に増える**。
現行のAmazon連携型トライアルでは利用者が必ずSP-API連携済み＝**検索でKeepaを消費しない**
(自分のAmazon枠を使う)ため、トライアル利用者は共有枠の外にいた。StoreKit方式では
その逃がし弁が無くなる。

実測・試算した結論: **20トークン/分なら当面足りる**。

- 1スキャン＝**1トークン**。`/api/search`のKeepa経路は`history=1`で取得してグラフ用データを
  先入れするため(`routes.js`)、グラフを見ても追加消費が無い。`offers`は使っていない。
- アプリ側に**7秒クールダウン**があり(`SearchTabView.searchCooldown`、共有Keepa枠を使う端末のみ)、
  1端末の上限は 60÷7 ≒ **8.6トークン/分**。同時2人までは補充20/分が勝って減らない。
  5人同時でもバケット(1,200)が約52分もつ。
- 日次総量は 28,800。ヘビーユーザー1人1日150〜400トークン程度。

**現在はまだ5トークン/分**(`/api/keepa-test`の`tokensLeft`が300＝60×5で確認できる)。
プランを20/分へ上げたら、**`wrangler.jsonc`の`KEEPA_REFILL_PER_MIN`を`20`にして再デプロイする**
ことを忘れないこと。ここが5のままだと適応ブレーキが5/分想定で効き続け、増強分を活かせない。

## 覚えておくと早いこと

- **App Store Connect API が使える**(`tools/appstore-connect/`)。認証設定済みで**環境変数不要**。
  審査状況・却下理由の取得、メモ欄や説明文の更新、ビルド差し替えが可能。
  秘密鍵は `~/.appstoreconnect/private_keys/`、設定は `~/.config/appstore-connect/config.json`。
- **無料枠を使い切った実機のリセット**: DEBUGビルドの 設定 → 開発者向け →「無料枠クォータをリセット」。
  端末IDはKeychain永続のため、**アプリを削除・再インストールしてもリセットされない**(意図的な設計)。

## 2026-08-09 セッションで実装したもの(概要)

膨大な変更が入ったため、テーマ別に要点だけまとめる。詳細は各コミットメッセージを参照。

### 1. 商品詳細・仕入れ内容画面のレイアウト刷新
`ProductSummaryHeader`(共通ヘッダー部品)導入、リンクボタン共有化、出品制限の表示、利益セクションを出品内容へ畳み込み等。設計書は `docs/superpowers/specs/2026-08-08-product-detail-and-purchase-form-layout-design.md`、計画書は `docs/superpowers/plans/2026-08-08-product-detail-and-purchase-form-layout.md`。

### 2. Amazon連携で7日間Proお試し(重要な設計)
- 開始日時の判定は**サーバー権威**(`server/src/sellerTrial.js` + `SellerTrialDO`)。出品者ID(sellerId)単位でwrite-once管理。クライアント側での計算は完全に撤去した(過去に「再インストールで無限お試し」「端末時計操作で無期限」の穴があり、その修正としてサーバー権威化した経緯)。
- お試し対象: 利益アラート・OCR無制限・仕入れリスト追加・出品フォーム・一括出品・出品制限チェック。
- お試し対象外: Keepaグラフ無制限・広告非表示・Keepa BYOキー(いずれも`isPro`のみ判定、`isProOrTrial`にしない)。
- お試しの発行条件(サーバー側 `requireProByoCredentials()`): 非Pro **かつ** リフレッシュトークンを提示した場合のみ。トークン無しでseller-idだけ送っても発行されない(他人のIDを送って勝手に開始・満了させる詐称対策)。
- 設定 → 連携 → **Amazon連携**画面(新設)にログインボタン・連携状態・連携特典・接続テスト・連携解除を集約。旧SP-API連携セクションのトグルは廃止。

### 3. 仕入れタブの操作ボタン
出品ボタンを常時表示にし、未連携/非Proでは鍵バッジ付きでタップ可能なまま残す(タップで案内アラート)。ゴミ箱・コンディションは常に使える。アイコンを1.3倍(22pt)に拡大。

### 4. レビュー依頼機能(新規)
`ReviewPromptController`。主トリガー=一括出品成功、副トリガー=起動時(無料/Keepa-BYOユーザー向け)。利用バー(検索50回・利用3日・仕入れ5件or一括出品1回)・ネガティブイベント抑制(5分)・クールダウン(120日)・年間上限(2回)・バージョン上限(1回)。詳細は `REVIEW-PROMPT.md`。

### 5. PostHog分析(新規、Amazon DPP対応済み)
`Analytics.swift`。**構造的にAmazon由来データを送れない設計**(closed enumのみ受け付け、ASIN/価格/出品者ID等は型として渡せない)。セッションリプレイ無効、distinct_id未設定(匿名ID)。APIキー・ホスト(USリージョン)は設定済みで**現在計測中**。PostHog管理画面でSession Replayが実際にOFFになっているか要確認(アプリ側は無効化済みだが二重の保険)。

### 6. 課金画面(PaywallView)
利用規約(Apple標準EULA)・プライバシーポリシー(`https://sellira.jp/privacy/`、未公開)へのリンクを追加。Apple 3.1.2ガイドライン対応。「Amazon連携で7日間無料体験」ボタンも追加(タップで設定タブのAmazon連携画面をシート提示)。

### 7. 設定タブの再編成
プラン → 連携(Amazon連携・Keepa連携) → 検索(リンクボタン設定・アラート設定・バイブレーション2種) → 出品 → サポート(お問い合わせ)。「型番で検索する」はリンクボタン設定画面へ移動。

### 8. バイブレーション設定を分離
「バイブレーション(スキャン時)」(新規、`scanSuccessHapticsEnabled`)と「バイブレーション(利益アラート)」(既存)を別設定に分離。以前は1つのトグルが利益アラート専用なのに紛らわしかった。

### 9. AdMob関連の不具合調査・修正
- SKAdNetworkIDを2件→50件(Google公式の全リスト)へ補完。
- リワード広告の読み込み失敗をログ出力するよう修正(以前は握りつぶされ原因不明だった)。
- **本番のKV `ADS_CONFIG`で`rewarded_scan`スロットが本番広告ユニットIDになっており、未公開アプリのため在庫なし(No Fill)だった**。一時的にGoogle公式テストIDへ差し替え済み(`version:6`)。**ただしテストIDだとAdMobコンソールでSSVコールバックURLを設定する手段が無く、報酬(スキャン+5回)が付与されない新たな問題が発生中**(下記「未解決の課題」参照)。
- グラフ表示専用の「動画を見てグラフを見る」機能を廃止(`934c7c9`)。グラフ枠切れ時はPro案内のみ表示。1日5回の文言はサーバーの`BASE_DAILY_UNITS`(=5)と一致させている。

### 10. その他の小さな修正
- FBA切替時に編集中アイテムの保存済み配送料/発送費用が失われる不具合を修正。
- 商品一覧からの一括追加で参考価格・発売日が引き継がれない不具合を修正。
- 出品内容カードの角丸が潰れて見える不具合(複数回の試行錯誤の末、Formの外に出す構造変更で解決)。

## お知らせ・障害告知の運用方法(2026-08-13追加)

設定→サポート→「お知らせ」はアプリ内ブラウザで `https://sellira.jp/amalens/news/` を開くだけ(自前画面は持たない。中身はsellira-site側で管理する)。

それとは別に、**サーバーから障害告知ポップアップを出せる**ようにした。アプリ更新なしで「今まさに起きている問題」を伝えるための手段。

- エンドポイント: `GET /api/notice`(認証不要)。実装は `server/src/routes.js` の「障害告知(notice)」セクション。
- KVは新規namespaceを作らず、**既存の`ADS_CONFIG` namespaceに`notice`キーで同居**させている(広告イベントのカウンタが同namespaceに同居している前例に倣った)。
- **告知を出す/止めるのは対話式スクリプトを使う**(コマンドの手打ちは不要):
  ```bash
  cd server && npm run notice
  ```
  現在の状態を表示したあと「1) 新しい告知を出す / 2) 配信中の告知を止める / 3) 何もせず終了」を選ぶ。題名・本文・URLを聞かれ、確認画面で `yes` と正確に入力したときだけ本番KVへ書き込む(`y`や`Yes`は通らない。誤操作防止)。実体は `server/scripts/notice.js`。
- 反映まで**最大60秒**かかる(サーバーキャッシュのため)。出しても消えても、すぐに変わらないのは正常。
- `id`は`YYYY-MM-DD-HHmmss`(JST)で自動採番される。**「停止」では`id`を変えない**(停止したはずの告知が新しい告知として再表示されるのを防ぐため)。
- 一度閉じたユーザーには同じ`id`の告知は二度と出ない(端末のUserDefaultsで既読管理)。スクリプト経由なら再配信時に必ず新しい`id`が振られるので、この点を意識する必要はない。
- `url`は**`https://sellira.jp/` 配下のみ**受け付ける(サーバー・スクリプト双方で検証)。万一KVへの書き込み手段が漏れても外部サイトへ誘導させないため。
- フェイルセーフ: 必須項目の欠落・型不正・長さ超過・JSON破損はすべて「告知なし」に倒れる(誤った告知を出すより出さない方が安全という判断)。取得失敗時もアプリは何も表示しない。
- 障害告知を表示したら `ReviewPromptController.recordNegativeEvent()` を呼び、5分間レビュー依頼を抑制する(障害を知らせた直後にレビューを求めないため)。取得は起動直後に行い、表示だけ2秒遅らせる設計(取得を遅らせるとこの抑制がレビュー判定に間に合わないため)。
- **限界**: サーバー自体が落ちている障害では当然出せない。Keepa障害・SP-API側の問題・料金改定の予告など「サーバーは生きているがサービスに問題がある」ケースが守備範囲。

## カメラのピント設定(2026-08-13追加)

以前は `ScannerView.swift` にフォーカス設定が**一切無く**(`lockForConfiguration()` が1つも無い状態)、すべてiOSの初期値任せだった。「近くでピントが合わない」という報告を受けて `configureFocus(for:)` を新設した。

**全機種に共通で適用**: `focusMode = .continuousAutoFocus` / `autoFocusRangeRestriction = .near`(遠景を探しに行かせない) / `isSmoothAutoFocusEnabled = false`(動画向けの緩慢な合焦をやめる)。実機で「ピント調整は完璧」と評価された部分なので**安易に変えないこと**。

**機種で振り分けている理由**: 近距離で合焦しない主因は設定ではなく広角カメラの物理的な最短撮影距離。設定では縮まらないので「近づかずに済むようにする」しかない。手段が機種で違う。

- **超広角を持つ機種(iPhone 17 Pro Max等)**: `makeCaptureDevice()` が `.builtInDualWideCamera` を返し、`videoZoomFactor` を最初の切り替えポイント(=広角の等倍)に置いたうえで自動切り替えを有効化する。近づくとiOSが超広角へ切り替えてマクロ合焦する。**画角は切り替わっても変わらない**(iOSが超広角を切り取って広角と同じ見え方を保つ)。デジタルズームは一切かけない。→ 実機検証済み、良好。
- **超広角が無い機種(iPhone 16e等)**: `.builtInWideAngleCamera` にフォールバックし、`minimumFocusDistance` から必要倍率を計算するデジタルズーム補正で近距離をカバーする。約1.3倍。→ 実機検証済み、良好。

**`targetFillRatio`(現在0.2)を触るときの注意**: 上げると倍率が上がりピントは合いやすくなるが画角が狭くなる。0.5では必要倍率が3〜4倍になり常に上限へ張り付き、機種差を吸収する意味が無くなる(実機で「狭すぎる」と却下)。0.3でもまだ狭かった。**この値は16eで最適化済み**で、Pro系はそもそもこの経路を通らない。

## AdMob本番IDと切り替え運用(2026-08-14追加)

**本番のAdMob ID(取得済み)**。アプリ側(`project.yml`の`GADApplicationIdentifier`)は本番ID。本番KV `ADS_CONFIG` も2026-09-09に全5枠を本番IDへ切り替え、`version:10` として配信中。

| 用途 | 本番ID |
|---|---|
| アプリID(`project.yml`) | `ca-app-pub-2265019305495449~6870745818` |
| `search_ad`(検索画面) | `ca-app-pub-2265019305495449/5590538879` |
| `products_bottom`(商品タブ) | `ca-app-pub-2265019305495449/2964375535` |
| `settings_bottom`(設定タブ) | `ca-app-pub-2265019305495449/1595453549` |
| `purchase_bottom`(仕入れタブ) | `ca-app-pub-2265019305495449/6879715607` |
| `rewarded_scan`(リワード) | `ca-app-pub-2265019305495449/4518934704` |

**切り替え履歴**: 未公開時は本番広告ユニットがNo Fillだったため、一時的にGoogle公式テストIDを配信していた。App Store公開後の2026-09-09に本番IDへ切り替えた。

**app-ads.txt**: `https://sellira.jp/app-ads.txt` で `google.com, pub-2265019305495449, DIRECT, f08c47fec0942fa0` を配信中。AdMob管理画面で「アップデートを確認」を実行し、クロール・確認完了を待つ。

**切り替え手順**(アプリの更新は不要。KVを書き換えるだけ):
```bash
cd server && npx wrangler kv key get "config" --binding ADS_CONFIG --remote --text   # 現在値を取得
# 各slotのunitIdを上表の本番IDに変更し、versionを1つ上げる
npx wrangler kv key put "config" --binding ADS_CONFIG --remote --path <編集したファイル>
```
反映まで最大60秒(サーバー側の60秒キャッシュ)。

**注意**: 本番IDに切り替えた後は、**自分で広告をタップしないこと**。無効なトラフィックと判定されAdMobアカウント停止のリスクがある。

## プライバシーマニフェスト(2026-08-14追加・重要な発見)

**`PrivacyInfo.xcprivacy` が長期間アプリバンドルに含まれていなかった**(2026-08-14に発覚・修正済み)。ファイルは `Resources/` に存在し企画書にも「対応済み」と書かれていたが、`project.yml` の `resources:` 指定ではXcodeGen(2.45.4)がCopy Bundle Resourcesフェーズに追加せず、**pbxprojに1件も登録されていなかった**(`grep -c PrivacyInfo project.pbxproj` が0件)。つまりトラッキングドメインもRequired Reason APIの申告も**一切効いていなかった**。

`Assets.xcassets` で過去に同じ問題が起きていた(project.yml内にコメントあり)のと同種。**`sources:` にファイルを個別指定**して解決した。`Resources` フォルダごと `sources:` に入れると `.gitkeep` が混入するため、ファイル単位で指定している。

**今後の検証方法**(マニフェストを変更したら必ずこれで確認すること。ビルドが通るだけでは意味が無い):
```bash
ls -la ~/Library/Developer/Xcode/DerivedData/BarcodeSedori-*/Build/Products/Debug-iphonesimulator/BarcodeSedori.app/PrivacyInfo.xcprivacy
plutil -p ~/Library/Developer/Xcode/DerivedData/BarcodeSedori-*/Build/Products/Debug-iphonesimulator/BarcodeSedori.app/PrivacyInfo.xcprivacy
```

**`NSPrivacyTrackingDomains` の調べ方**(Googleは公式リストを公開していないため実測が必要):
Xcodeでアプリを実機実行 → デバッグナビゲータ → Network → 「Profile in Instruments」→ **Restart**を選択(起動時の通信も取るため)→ 広告が出る画面を一通り操作 → 停止 → 「Points of Interest」に `Fault: <ドメイン> is not listed in your app's NSPrivacyTrackingDomain key...` として**Xcodeが名指しで教えてくれる**。

2026-08-14の実測で判明したドメイン(記載済み): `googleads.g.doubleclick.net` / `g.doubleclick.net` / `www.googleadservices.com` / `pagead2.googlesyndication.com`。

**重要: Instrumentsの警告が消えるかどうかは検証に使えない。** マニフェストをバンドルに含めた状態で再計測しても、記載済みの4件を含め警告(Fault)が出続けることを確認した。これは**Appleの既知のバグ**で、Apple社員がフォーラムで「NSPrivacyTrackingDomainsに追加すればfaultは出ないはず。バグのようなのでフィードバック報告してほしい」と回答している([forums/thread/744659](https://developer.apple.com/forums/thread/744659))。計測結果に `<private>`(80件)が残る点も同じバグの影響とみられ、**この計測からは未特定ドメインの有無を判断できない**。

**確実な検証方法**: Xcode Organizer の **Generate Privacy Report**(アーカイブから実際のプライバシー情報のレポートを生成する公式機能)。アーカイブ作成が必要なため、**App Store提出用ビルドを作るタイミングで確認する**のが効率的。

**注意**: ここに書いたドメインは、ATT未許可のユーザーに対してOSが接続を遮断する。書きすぎると広告配信が壊れるため、ATTを「許可しない」にした状態で広告が出るかの確認も推奨。

### マニフェストとApp Store Connectのプライバシー申告の使い分け

**両方必要で、役割が違う**。片方だけでは不十分で、両者が矛盾していると審査で問題になる。

| | 役割 | 何を書くか |
|---|---|---|
| `PrivacyInfo.xcprivacy` | 機械向け。Appleがバイナリを解析し、宣言と実際の挙動の一致を機械的に検証する | **自社アプリのコードが収集する分**。SDK分は各SDKが自前のマニフェストを同梱しており、Appleがアプリと全SDKの分を**合算して**評価するため書かなくてよい |
| App Store Connectのプライバシー申告(Webフォーム) | 人間向け。App Store製品ページの「プライバシー」欄になる | **SDK分も含めた全体**。ここはアプリ提供者の責任範囲 |

つまり **AdMob分をマニフェストに追加する必要はない**(Google側が申告済み)。代わりに**提出時のWebフォームでAdMob分を漏れなく申告する**こと。Googleが申告すべき内容を公式に公開している: <https://developers.google.com/admob/ios/privacy/data-disclosure>

なお2026-08-14に追加したPostHog分(`NSPrivacyCollectedDataTypeOtherUsageData`)は、上記の整理からすると厳密には過剰(PostHog SDKが自前で申告済み)。ただし実態と矛盾せず害は無いためそのままにしている。

### PostHogとATTの関係(2026-08-14確認)

**PostHogにATTの許可は不要**。根拠:
- PostHog SDK同梱のマニフェストで、収集データ2種とも `NSPrivacyCollectedDataTypeTracking = false` / `Linked = false` と申告。`NSPrivacyTracking` キー自体が無い
- SDK内に `ASIdentifierManager` / `advertisingIdentifier` の参照がゼロ(IDFA不使用)
- アプリ側も `distinct_id` を設定せず匿名IDのまま(`Analytics.swift`)。端末のdeviceIdと突き合わせられない

Appleの言う「トラッキング」= 他社アプリ/サイトのデータと紐付けた個人識別 に当たらないため。**ATTを拒否されてもPostHogの計測は継続する**(広告が非パーソナライズになるだけ)。ATTが要るのは**AdMobのみ**。

## 再インストールで連携が壊れるバグ(2026-08-14発見・修正済み)

**症状**: アプリを再インストールすると、Amazon連携画面は「連携済み」で接続テストも通るのに、**出品制限の表示と出品機能だけが黙って使えなくなる**。エラーも出ないため原因が分からない。

**原因**: 保存先の非対称性。**iOSではKeychainはアプリを削除しても残るが、UserDefaultsは消える**。

| データ | 旧・保存先 | 再インストール時 |
|---|---|---|
| リフレッシュトークン | Keychain | **残る** |
| 出品者ID(`spapiSellerId`) | UserDefaults | **消える** |
| 連携フラグ(`spapiLinkEnabled`) | UserDefaults | 消える |

さらに `SettingsStore` の旧バージョン移行用の救済処理(「トークンが非空なら `spapiLinkEnabled = true` にする」)が**再インストール時にも発動**し、「連携済み」に復元してしまう。結果、トークンはあるが出品者IDが空という中途半端な状態になる。`isListingReady`(= `isSpApiLinkUsable && spapiSellerId 非空`)が false になり、出品制限・出品が**エラーを出さず非表示**になる(失敗時は「制限なし」に倒す設計のため画面上で切り分け不能)。接続テストはトークンだけで通るので「連携は正常」に見えてしまう。

**修正**:
1. **根本策**: 出品者IDもKeychainへ保存(`keychainSellerIdAccount = "spapi.sellerId"`)。トークンと永続性を揃えた。旧UserDefaults値は初回起動時に自動移行して削除する(リフレッシュトークンの移行処理と同じ流儀)。
2. **補強策**: `SettingsStore.needsSpApiRelink`(トークン非空 かつ 出品者ID空)を追加し、Amazon連携画面で「連携済み」より優先して**「再連携が必要です」(オレンジ)** と案内を表示する。既存のログインボタンで再認可すれば解消する。

**注意点**:
- **出品者IDはOAuth認可コールバックでしか取得できない**(Sellers APIの応答にsellerId相当のフィールドが無い)。したがってこの不整合は再連携でしか解消できない。
- **7日間お試しは失われない**。サーバー側で出品者ID単位のwrite-once管理のため、再連携すれば同じ記録が返る。ただし**開始日は最初のまま**なので残り日数は経過分だけ減る(再インストールで無限にお試しできる穴を塞ぐための意図的な設計)。
- 教訓: サーバー側は「再インストールでお試しを復活させない」ため正しく出品者ID単位にしていたが、**アプリ側がその出品者IDを再インストールで失う場所に置いていた**という噛み合わせの悪さだった。今後、連携に必要な値を追加するときは**Keychainに置いて永続性を揃えること**。

## Keepaキャッシュの2段構成(2026-08-21追加)

キャッシュは **L1=Workersのisolate内LRU / L2=Cloudflare Cache API(`caches.default`)** の
2段になった(`server/src/sharedCache.js`)。

**なぜ必要だったか**: 従来はisolate内のインメモリMapだけで、isolateはPoPごとに複数あり
短命に作り直されるため、「別の人が同じ商品をスキャンしたときに効く」という当初の狙いが
ほとんど効いていなかった。Keepaは1リクエスト1トークンを共有キーから消費するので、
ヒット率がそのままトークン消費量に直結する。

**なぜKVではなくCache APIか**: 無料プランのKVは**書き込みが1日1,000回**まで。キャッシュミス
のたびに書き込むため桁が足りない。Cache APIは書き込み上限が無い。共有範囲がコロケーション
単位に限られるが、利用者はほぼ日本国内(東京・大阪PoP)に集中するため実効差は小さい。
有料プランへ移ってグローバル共有が欲しくなったらL2をKVへ差し替えればよい(クラス外へ影響しない)。

- **検索は`keepa:`接頭辞のキーだけL2へ載せる**。SP-API経路は認証情報ハッシュを含む個人ごとの
  結果で、共有Keepaトークンも消費しないため共有する利点が無い。
- **グラフ生データのTTLは6時間**(`GRAPH_CACHE_TTL_MS`で調整可)。検索結果(30分)とは別。
  グラフは現在価格ではなく履歴の表示なので鮮度要求が低い。
- L2ヒットはL1へ**L2の残り時間**で載せ直す(既定TTLで載せ直すとL2の期限を超えて古い値を
  返し続けるため)。
- Node(`src/index.js`)・テストでは`caches`未定義でL2を丸ごと無効化し、従来と同じ挙動になる。

**検証方法**: `wrangler dev`のローカルモードではCache APIが**no-op**のため、ローカルでは
確認できない。本番デプロイ後に以下で確認する(2回目が`bypass: cache`になれば効いている):

```bash
curl -s -H "X-App-Plan: pro" -H "X-Keepa-Debug: 1" "https://api.sellira.jp/api/graph-data?asin=B0CX23V2ZK"
```

**落とし穴**: デプロイ直後は古いバージョンが動いているエッジが残るため、数十秒はキャッシュが
効かないように見える(2026-08-21に実際にこれで誤判定しかけた)。判断は数十秒おいてから行うこと。

## スキャンの7秒クールダウン(2026-08-21に文言追加)

共有Keepa枠を使う端末は1検索7秒、SP-API連携済み(または Pro＋BYO Keepaキー)は1秒
(`SearchTabView.searchCooldown` / `consumesSharedKeepaToken`)。**プランではなく、
共有Keepa枠を使うか自分の枠を使うかで決まる**。

従来は画面に「あと◯秒」としか出ず理由も解消手段も分からなかった。5.6対応でStoreKit
トライアルへ移行すると**連携していないProユーザーが7秒待たされる**ことになり、まさに
「Proがどれだけ快適か」を判断されている期間に「課金しているのに遅い」と映る。そのため
カメラ上の表示に「Amazon連携で待ち時間が1秒になります」を添え、Amazon連携画面の特典も
「Proが無料になる」ではなく「検索が自分のAmazon枠で行われるので速い」という書き方へ変えた。
この書き方は**5.6の指摘とも整合する**(特典で釣るのではなく機能的な理由で誘導する)。

## 未解決の課題(次のセッションで判断・対応が必要)

### 1.【要判断】AdMobリワード広告のSSV(報酬付与)が機能しない

**経緯**: No Fill対策でリワード広告ユニットをGoogleテストIDに戻したが、テストユニットはAdMobコンソールに存在しないため**SSVコールバックURL(`https://api.sellira.jp/api/admob/ssv`)を設定する手段が無い**。結果、広告は表示されるが視聴完了後もGoogleがサーバーを呼ばず、無料枠が復活しない(「反映に時間がかかっています」のまま)。

**選択肢**(ユーザーへ提示済み、まだ回答待ち):
- **A(推奨)**: 本番広告ユニットIDに戻し、AdMobコンソールでSSVコールバックURLを設定する。「URLを確認」ボタンで疎通確認は可能(サーバー側は署名不正・パラメータ欠落時も常に200を返す設計になっており、コンソールの検証に対応済み)。ただし広告本体はNo Fillのままなので、視聴からの一気通貫の動作確認はアプリ公開後になる。
- **B**: `#if DEBUG`限定で、視聴完了後にアプリから直接枠を付与する開発用の抜け道を作る。「自己申告を信用しない」という現在の設計思想に穴を開けるため、Releaseビルドに残らないよう厳重に囲う必要がある。

### 2.【決定済み】アプリ名「アマレンズ」→「セラーレンズ」への変更

2026-08-14に「セラーレンズ」への改名を実施済み。`project.yml`の`CFBundleDisplayName`/`CFBundleName`/`bundleIdPrefix`/`PRODUCT_BUNDLE_IDENTIFIER`、`EntitlementStore.proProductID`、`KeychainStore`のフォールバック値、`BarcodeSedori.storekit`の商品ID、企画書・LP文言用ドキュメント類を一括更新した。バンドルIDも`com.example.barcodesedori`→`jp.sellira.sellerlens`に変更(開発端末に保存済みのSP-APIリフレッシュトークンはKeychainのサービス名変更により読めなくなるが、未公開アプリのため開発端末のみへの影響)。

URLスキーム`barcodesedori://`はサーバー(`server/src/oauth.js`)にハードコードされているため据え置き(ユーザー判断)。Amazon Developer Consoleの`application_id`(認可フローで参照する値)には影響しない。**ただしAmazon Developer Console上のSP-APIアプリ表示名(まだ「アマレンズ」で登録済み)とSelling Partner Appstoreへの掲載申請は未対応**。掲載申請はまだ行っていないため露出は限定的だが、次回申請時は表示名の更新が必要。

### 3.【要確認】プライバシーポリシーの公開

以前は「まだ存在しない」と記載していたが、2026-08-13時点で sellira-site に `src/pages/privacy.astro` と `dist/privacy/index.html` が**存在することを確認済み**。ただし本番(`https://sellira.jp/privacy/`)へデプロイ済みかまでは未確認なので、次回ブラウザで実際にアクセスして確かめること。草案は `PRIVACY-POLICY-DRAFT.md`。課金画面から直接リンクしているため、未公開だとApple審査に落ちる。

### 3-2.【要対応・未着手】お知らせページの作成(sellira-site)

アプリの設定→サポート→「お知らせ」が `https://sellira.jp/amalens/news/` を開くが、**このページはまだ存在しない**(sellira-siteの`src/pages/`にnews系は無い)。公開前に作らないとリンク切れになる。既存の`blog`コレクション(`src/content/config.ts`のdefineCollection、`src/pages/blog/index.astro`が日付降順で一覧表示)がそのままお手本になる。アプリから読む用途なので、個別ページへ遷移させず**一覧ページ内で日付+本文がそのまま読める**形が望ましい。

### 4.【要対応】お問い合わせフォームのクエリ受け取り対応

設定タブの「ご意見・お問い合わせ」が診断情報(app_version/build/os/device/plan/spapi)をクエリパラメータとして`https://sellira.jp/contact/`に付与するが、**フォーム側がこれを受け取って保存・表示する対応がまだ無い**。sellira-siteリポジトリでの対応が必要。

## 公開前 必須TODO(`FREEMIUM-PLAN.md`に集約済み。要点のみ再掲)

- `SPAPI_APP_ID`周りの.env整理、バンドルID変更、AdMob本番ID差し替え(**アプリ側`project.yml`とサーバー側KV `ADS_CONFIG`の2系統がある**点に注意。今回まさにここで詰まった)
- 試験用の手動SP-APIトークン入力欄を削除(現状は既にAmazon連携画面の刷新で削除済みのはず、要確認)
- PostHog APIキー設定(**完了済み**)+プライバシーポリシーへの記載(未完了、上記3番)
- プライバシーポリシー公開(上記3番)、App Store アプリID設定(`AppStoreReviewConfig.appId`、未リリースのため空のまま)

## 作業ルール(プロジェクト固有)

- 変更完了ごとに確認なしでコミットする。push/deployは都度ユーザーに確認する。
- iOSシミュレーターは**勝手に使わない**(CLAUDE.mdに明記されたルール)。目視確認が必要な場合はユーザーにスクリーンショットを送ってもらう、または明示的な許可を得る。ビルド確認は `xcodebuild -destination 'generic/platform=iOS Simulator' build` で行う(シミュレータを起動しない)。
- 新規Swiftファイルを追加したら必ず `cd ios/BarcodeSedori && xcodegen generate` を実行してからビルドする。
- サーバーは自動デプロイされない。反映するには明示的に `wrangler deploy` が必要。`KEEPA_API_KEY`はCloudflare secretのみに存在しローカル`.env`には無いため、ローカルでKeepa実データ検証はできない。
- wrangler v4のKV操作は**既定でローカル環境を見る**。本番の値を確認・更新するときは必ず `--remote` を付ける(付け忘れると「値が無い」と誤判定する)。
- 要件定義・計画・レビュー・設計相談・複雑なバグ調査はOpus、実装・ファイル整理・単純作業はSonnetのサブエージェントへ委任、質問への回答はSonnet(プロジェクトCLAUDE.mdの指示)。
- 実装作業は基本的にAgentツール(Sonnetサブエージェント)へ委任し、完了後にコード差分をopusが自分でも確認する運用で進めた。
