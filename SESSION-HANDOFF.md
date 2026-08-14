# セッション引き継ぎ(2026-08-09 時点)

アプリ名: **セラーレンズ**に確定した(2026-08-14)。旧称アマレンズ(さらにその前は「バーコードせどり」)。Amazonセラー向けの仕入れリサーチiPhoneアプリ。**まだ一般公開前**(App Store/Amazon掲載とも未申請)。

## 関連リポジトリ

| 対象 | 場所 | デプロイ |
|---|---|---|
| iOSアプリ＋サーバー | このディレクトリ / `yuriasu2/-barcode_sedori` | サーバーは**手動** `cd server && npx wrangler deploy` |
| LP(sellira.jp) | `~/Claude/Projects/sellira-site` / `yuriasu2/sellira-site` | push→Cloudflare Pages が自動 |

## 現在の状態

- **未pushコミットが1件**: `934c7c9`(グラフ枠の動画視聴延長を廃止)。次のセッション開始時にpushするか確認すること。
- **サーバーの手動デプロイが必要**: `6612ef4`〜`4787098`(お試し期間のサーバー権威化、`SellerTrialDO`新設)、および `ff0cf5e`(障害告知API `GET /api/notice` の新設)がまだ本番へデプロイされていない。デプロイしないとAmazon連携の7日間お試しが誰にも付与されず、障害告知も配信できない(いずれもフェイルセーフ設計のため安全ではあるが、機能が使えない)。
  ```bash
  cd server && npx wrangler deploy
  ```
- サーバーテストは353件パス(直近確認時点)。

## 今回のセッションで実装したもの(概要)

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

**本番のAdMob ID(取得済み)**。アプリ側(`project.yml`の`GADApplicationIdentifier`)は**既に本番ID**になっている。KVは開発の都合で**テストIDに戻してある**(下記の理由)。

| 用途 | 本番ID |
|---|---|
| アプリID(`project.yml`) | `ca-app-pub-2265019305495449~6870745818` |
| `search_ad`(検索画面) | `ca-app-pub-2265019305495449/5590538879` |
| `products_bottom`(商品タブ) | `ca-app-pub-2265019305495449/2964375535` |
| `settings_bottom`(設定タブ) | `ca-app-pub-2265019305495449/1595453549` |
| `purchase_bottom`(仕入れタブ) | `ca-app-pub-2265019305495449/6879715607` |
| `rewarded_scan`(リワード) | `ca-app-pub-2265019305495449/4518934704` |

**なぜKVはテストIDのままか**: 未公開アプリの本番広告ユニットには在庫が割り当てられず、**No Fillで広告が一切表示されなくなる**ため(2026-08-14に一度本番IDへ切り替えて実際にこの事象が再発し、テストIDへ戻した)。開発中の動作確認ができなくなるので、**本番IDへの切り替えはリリース直前に行う**。

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

2026-08-14の実測で判明したドメイン(記載済み): `googleads.g.doubleclick.net` / `g.doubleclick.net` / `www.googleadservices.com` / `pagead2.googlesyndication.com`。ただし計測結果には **`<private>` と伏せられた項目が最多(42件)** 残っており、まだ未特定のドメインがある可能性がある。**マニフェストがバンドルに入るようになった状態で再計測し、警告が消えるか要確認**。

**注意**: ここに書いたドメインは、ATT未許可のユーザーに対してOSが接続を遮断する。書きすぎると広告配信が壊れるため、ATTを「許可しない」にした状態で広告が出るかの確認も推奨。

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
