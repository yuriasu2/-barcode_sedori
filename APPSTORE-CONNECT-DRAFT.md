# App Store Connect 申請文言 記入案

作成: 2026-08-14 / 対象: App Store Connect のアプリ情報・バージョン情報

> 注意: 別ファイルの `APPSTORE-LISTING-DRAFT.md` は **Amazon販売パートナーアプリストア用**であり、こことは別物。
> あちらは「書籍セラー向け」「3日間の無料体験つき」など古い記述が残っているため、そのまま流用しないこと。

## アプリ名（30文字以内）

**採用（25文字）**

```
セラーレンズ - 相場リサーチ/仕入/価格比較/せどり
```

- App Store の検索結果に表示される名前。**ホーム画面のアイコン下に出る名前とは別物**で、
  そちらは `project.yml` の `CFBundleDisplayName`（=「セラーレンズ」）が使われる。
  App Store側だけキーワードを足しても、アプリのコード変更は不要。
- 競合（Amacode等）もアプリ名にキーワードを含めており、アプリ名はサブタイトルより
  検索順位への影響が大きいとされるため、余った文字数をキーワードに充てている。
- 検索結果では末尾が「…」で省略されることが多い。重要な語ほど前に置くこと。

## サブタイトル（30文字以内）

**採用（24文字）**

```
バーコードからAmazon相場、売行が1画面でわかる
```

- 「相場」「売行（売れ行き）」= せどりの判断材料そのもの。機能の説明ではなく
  **ユーザーが知りたいこと**を並べている。
- 「1画面でわかる」= 他アプリとの差別化ポイント（価格一覧とグラフが同一画面）。

## プロモーションテキスト（170文字以内・審査なしで随時変更可）

```
バーコードをかざすだけで、Amazonの新品・中古価格、売れ筋ランキング、Keepaの価格推移グラフを1画面で確認。手数料を差し引いた利益も自動計算し、その場で仕入れを判断できます。
```

## 説明（4000文字以内）

```
セラーレンズは、Amazonセラーのための仕入れリサーチアプリです。店頭で商品のバーコードをかざすだけで、Amazonでの価格・売れ行き・利益の見込みをその場で確認できます。


■ 価格一覧からグラフまで、1画面で完結

このアプリの最大の特徴です。バーコードをスキャンすると、画面を切り替えることなく、そのままスクロールするだけで以下がすべて確認できます。

・スキャンした商品の情報
・新品・中古の価格一覧（出品者ごとの送料込み価格、最安値順）
・価格とランキングの推移グラフ
・出品者数の推移グラフ

多くのリサーチツールでは「価格を見る画面」と「グラフを見る画面」が分かれていますが、セラーレンズは1つの縦スクロール画面に収めています。視線を動かすだけで、価格の「今」と「これまでの推移」を同時に判断できます。


■ その場で仕入れを判断するための機能

・バーコードスキャン（JANコード）に対応。汚れや折れで読み取れないときは、OCRで印字された数字を認識して検索できます
・新品・中古それぞれの出品者一覧を、送料込みの実質価格で比較できます
・販売手数料・カテゴリ成約料・消費税を差し引いた実質利益を自動計算します
・利益が一定ラインを超えた商品はハイライト表示され、有望な候補を見逃しにくくなります


■ 仕入れから出品までをアプリで完結

・スキャンした商品をワンタップで仕入れリストへ追加
・コンディション（新品／ほぼ新品／非常に良い／良い／可）ごとに説明文テンプレートを自動入力
・FBA利用と自己発送の切り替え、送料・発送コストのプリセット管理
・仕入れリストから複数商品をまとめてAmazonへ出品
・出品説明文テンプレートとSKUフォーマットのカスタマイズ
・仕入れデータをCSVファイルとして書き出し、Excelなどで管理


■ Amazonアカウントとの連携

Amazonアカウントと連携すると、価格一覧の表示、1日の検索回数制限の解除、出品可否の確認、アプリからの出品登録が利用できるようになります。連携した時点から7日間、主要機能を無料でお試しいただけます。

連携により取得した情報は、ご本人の仕入れ判断のためだけに使用します。第三者への提供は行いません。購入者の個人情報にはアクセスしません。


■ 他サイトの相場もワンタップで

検索結果や商品詳細から、Amazon・メルカリ・楽天市場・Yahoo!ショッピング・ヤフオク・ラクマ・価格.com・Keepaへワンタップで移動できます。表示するボタンは設定で選べます。


■ 料金

基本機能は無料でご利用いただけます。検索は1日5回まで、広告が表示されます。

すべての機能を制限なく、広告なしで使える有料プラン「セラーレンズ Pro」（月額1,980円）をご用意しています。

Proでできること
・スキャン・検索が無制限
・OCRスキャンが無制限
・価格推移グラフが無制限
・出品者一覧をフル表示
・Amazon出品制限の警告表示
・アプリからのAmazon出品登録
・広告なし
・仕入れリスト・利益アラートが使い放題


■ 動作環境

iOS 16.0以上のiPhone


■ サブスクリプションについて

・お支払いはApple IDアカウントに請求されます
・期間終了の24時間前までに解約しない限り、自動的に更新されます
・解約は、iPhoneの「設定」→ Apple ID →「サブスクリプション」から行えます
・利用規約: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
・プライバシーポリシー: https://sellira.jp/privacy/
```

## キーワード（100文字以内・カンマ区切り・スペース不要）

```
せどりツール,スキャン,アマゾン,出品,転売,古本,中古,利益計算,keepa,在庫,物販,副業,検品,棚卸,バーコードリーダー,ランキング
```

- **アプリ名・サブタイトルに含まれる語はここに書かない**（別枠で評価されるため重複は無駄）。
  除外済み: セラーレンズ / 相場 / リサーチ / 仕入 / 価格比較 / せどり / バーコード / Amazon / 売行 / 1画面
- 「せどり」単体はアプリ名にあるため、複合語の「せどりツール」だけを残している。

## サポートURL

```
https://sellira.jp/contact/
```

※ 旧 `support.astro` は削除済み（sellira-siteリポジトリで確認）。問い合わせフォームを案内する。

## マーケティングURL（任意）

```
https://sellira.jp/sellerlens/
```

## プライバシーポリシーURL

```
https://sellira.jp/privacy/
```

## カテゴリ

- **プライマリ**: ビジネス
- **セカンダリ**: ユーティリティ（任意）

## 年齢制限

**4+ で申告する**（2026-08-14決定）。

年齢制限の質問票は暴力・性的表現・ギャンブル等すべて「なし」。加えて、判断が必要な項目が1つある。

### 「無制限のWebアクセス」→ **いいえ**

App Store Connectの年齢制限の質問に「無制限のWebアクセス」という項目がある。
アプリ内ブラウザ（`SafariView`）で外部サイトを開くが、以下の理由で**「いいえ」を選ぶ**:

- **利用者が任意のURLを入力して閲覧できる機能はない**。アドレスバーのある汎用ブラウザではなく、
  アプリが指定したURLを開くだけ。Appleが言う「無制限のWebアクセス」は、利用者がどこへでも
  自由に移動できるブラウザ機能を指す。
- 開く先は、リンクボタン（Amazon・メルカリ・楽天市場・Yahoo!ショッピング・ヤフオク・ラクマ・
  価格.com・Keepa の商品ページ）と、sellira.jp の自社ページ（お問い合わせ・お知らせ・
  プライバシーポリシー）、Appleの標準EULA。いずれもアプリ側で組み立てている。

**ただし1点、アプリ側で固定されていない経路がある**（`Sources/Views/AdSlotView.swift`）:
カスタム広告（`type: "custom"`）のリンク先 `linkUrl` は、サーバー（KV `ADS_CONFIG`）から
配信される値をそのまま開く。運用上は自社・提携先のURLしか入れないが、**コード上の制約はない**。
広告のリンク先が可変なのは一般的な広告アプリと同じ扱いで、これをもって「無制限のWebアクセス」
とは通常みなされないため 4+ の判断は維持する。

「はい」を選ぶと17+になるため、この判断は年齢区分に直結する。
将来、利用者が任意のURLを開ける機能を追加した場合は再検討すること。

## App Review情報（審査メモ）

### デモアカウントについて

**デモアカウントは提供しない方針**。理由:

- Amazon連携は利用者本人のAmazon出品用アカウント（有料の大口出品プラン）とのOAuth連携であり、
  認証情報の第三者共有は**Amazonのデータ保護ポリシー（DPP）上認められていない**。
- 審査用に別のセラーアカウントを用意する案もあるが、大口出品は月額登録料がかかるうえ、
  審査のためだけに用意するのは現実的でない。
- 幸い**Amazon連携なしでもアプリの中核機能は動作する**ため、その範囲を審査メモで明示する。

### 課金の確認方法

審査担当者は **Sandbox環境で実際の課金なくサブスクリプションを購入できる**ため、
Pro限定機能の確認に特別な仕組みは不要。購入画面は設定タブ、または各機能のロック表示から開ける。

**ただし Pro を購入しても Amazon連携が無いと確認できない機能がある**点に注意（下表）。

| 機能 | 必要なもの |
|---|---|
| スキャン・OCR無制限、グラフ無制限、広告なし、仕入れリスト、利益アラート | Proのみ |
| 価格一覧の表示、出品制限チェック、アプリからの出品 | Pro **+ Amazon連携** |

### 審査メモ 記入案（App Store Connect の「メモ」欄へ）

```
【アプリ内課金の確認方法】

「セラーレンズ Pro」（月額1,980円）は、設定タブ、または各機能のロック表示を
タップすると購入画面が開きます。Sandbox環境ではそのままご購入いただけます。

【Proのみで確認できる機能】

・スキャン、検索の無制限化（無料は1日5回まで）
・OCR（文字認識）スキャンの無制限化
・価格推移グラフの無制限化
・広告の非表示
・仕入れリスト、利益アラート

【Proに加えてAmazon連携も必要な機能】

・出品者ごとの価格一覧の表示
・Amazonへの出品可否の確認（出品制限の警告表示）
・アプリからのAmazon出品登録

これらはAmazon出品用アカウントとのOAuth連携が前提です。
Amazonのデータ保護ポリシー上、出品用アカウントの認証情報を第三者と
共有することが認められていないため、デモアカウントのご提供ができません。
何卒ご理解ください。

連携していない状態でこれらの機能を操作された場合は、鍵アイコンとともに
「Amazon連携が必要です」という案内が表示されます。
クラッシュや無反応にはなりません。

【出品制限の警告表示についての補足】

「出品制限の警告表示」は、Amazonが出品を制限している商品をスキャンしたときにのみ
警告バッジが表示される機能です。制限のない商品では何も表示されないため、
機能が動作していないように見える場合がございますが、正常な動作です。
この判定にはAmazon連携が必要なため、連携がない状態では常に非表示となります。

【Amazon連携なしで確認いただける機能】

以下の主要機能は、アカウント登録・ログインなしでそのままご確認いただけます。

・バーコードスキャンによる商品検索
・商品情報、価格、売れ筋ランキングの表示
・価格推移グラフの表示
・仕入れリストへの追加、利益計算
・設定画面の各種機能

バーコードをお持ちでない場合は、検索欄にJANコード（13桁の数字）を
直接入力しても検索できます。
```

### 提出前に実機で確認しておくこと

**Amazon連携を解除した状態**で各機能に触り、案内が正しく出るか確認する。
無反応な箇所があると審査で「機能が動作しない」と判断される恐れがあるため。

- 検索結果の価格一覧 → ロック表示（ぼかし＋鍵）になるか
- 仕入れタブの出品ボタン → 鍵バッジ付きでタップでき、案内アラートが出るか
- 出品制限 → 非表示になる（審査メモで補足済み）

### その他

- **サブスクの審査用スクリーンショット**が必要（Pro画面を撮影したもの）。
- **ATTを使用**しているため、審査時にトラッキングの用途を説明できるようにしておく。
- 年齢制限: アプリ内ブラウザで外部サイト（メルカリ・楽天等）を開くため、
  「無制限のWebアクセス」に該当すると17+になる可能性がある。開くURLは固定のため
  4+で通る見込みだが、判断が分かれる箇所。

---

# Guideline 2.1 却下（2026-08-20）への返信

初回提出が **Guideline 2.1 - Information Needed** で差し戻された。機能不備ではなく
「審査メモの情報が足りない」という新規アプリ向けの定型差し戻しで、要求された8項目を
Resolution Center から返信すれば再審査に進む。**新しいビルドのアップロードは不要**。

## 今回の反省点（次回以降も守ること）

1. **審査メモは英語で書く。** 前回の記入案は日本語だったが、App Reviewの担当者が
   日本語を読めるとは限らない。日本語だけだと「情報が無い」と同じ扱いになる。
2. **デモアカウントを出せない場合は、代わりに画面収録を必ず添える。** 「出せません」
   だけで終えると 2.1 のループに入る。Appleが項目1で画面収録を求めているのは、
   これが認証情報の代替手段として認められているため。
3. 最初から8項目すべてを埋めておけば、この差し戻し自体が避けられた。

## 必須作業: 画面収録（これだけは実機でしか作れない）

**要件**: 実機・最新OS・アプリ起動から開始・主要フローを通す。

撮影順のシナリオ:

| # | 撮影内容 | 注意 |
|---|---|---|
| 1 | ホーム画面からアイコンをタップして起動 | 「起動から始める」が明示要件 |
| 2 | カメラ許可ダイアログ → 許可 | 権限ダイアログは必須撮影対象 |
| 3 | 商品バーコードをスキャン | 実物のバーコードを用意 |
| 4 | 結果画面を下までスクロール（価格一覧・ランキング・推移グラフ） | 中核機能 |
| 5 | 仕入れフォームで利益計算 → 仕入れリストへ追加 | |
| 6 | **スキャンを合計4回以上行い、ATTの事前説明→システムダイアログを出す** | 下記の注意参照 |
| 7 | 無料枠を使い切る、またはロック機能をタップしてペイウォールを開く | 価格・期間・規約リンクが映るように |
| 8 | Sandboxでサブスクリプションを購入 → Pro機能が解放されるところまで | 項目8の要求 |
| 9 | 設定 → Amazon連携 → OAuth連携（自分の実アカウント） | パスワード入力中は指で隠すか編集で伏せる |
| 10 | 連携後に、価格一覧・出品制限警告・出品登録が動くところ | デモアカウントを出せない分の代替証拠 |
| 11 | 設定 → Amazon連携 →「連携を解除」 | 連携の取り消し手段があることを示す |

**ATTの注意**: `AttPromptController` の設計上、ATTの事前説明は
**スキャン成功が4回に達するまで表示されない**（`minScanCountToShow = 4`）。
1〜2回スキャンしただけの収録ではATTダイアログが映らず、Appleに
「ATTプロンプトを収録していない」と判断されて再度差し戻される恐れがある。
必ず4回以上スキャンしてから先へ進むこと。
（この遅延表示の理由も、下記メモの項目1に書いてある。）

## 返信文（英語 / Resolution Center と「メモ」欄の両方に貼る）

> `[ ]` の箇所は提出前に埋めること。

```
Thank you for reviewing SellerLens. Please find the requested information below.


1. SCREEN RECORDING

A screen recording captured on a physical iPhone has been uploaded to the
App Review Information section. It begins with launching the app from the
Home screen and covers: the camera permission prompt, barcode scanning,
the product/price/sales-rank/price-history screen, the profit calculation
and purchase list, the App Tracking Transparency prompt, the subscription
paywall and the in-app purchase flow, and the optional Amazon account
linking flow together with the features it unlocks.

Note on the App Tracking Transparency prompt: by design, we do not show the
ATT request on first launch. We first let the user perform several scans so
that they understand what the app does, and only then show a short
explanation followed by Apple's system ATT dialog. In the recording this
appears after the fourth successful scan.

This app does not have account registration, login, or account deletion
flows, and it does not host any user-generated content, so those are not
included in the recording. Please see item 4 for details.


2. DEVICES AND OPERATING SYSTEMS TESTED

- [iPhone model] — iOS [version]
- [iPhone model] — iOS [version]


3. APP FUNCTIONS AND TARGET AUDIENCE

SellerLens is a product-sourcing research tool for Amazon Japan sellers.

Problem it solves: when a seller is standing in a physical store, they have
only a few seconds to decide whether an item is worth buying to resell.
Checking the current Amazon price, the sales rank, the historical price
trend, and the fees that Amazon will deduct normally requires several
separate websites and a calculator.

Value it provides: scanning the product's barcode shows all of that
information on a single scrollable screen, and the app automatically
calculates the expected profit after Amazon's referral fee, category
closing fee, and consumption tax.

Target audience: individuals and small businesses in Japan who sell on
Amazon.co.jp. The user interface is Japanese only.


4. SETUP AND ACCESS TO MAIN FEATURES

No account registration or login is required to use the core features.

Steps:
  1. Launch the app and allow camera access.
  2. Point the camera at any product barcode (JAN / EAN-13).
     If you do not have a physical product at hand, tap the search field at
     the top and type a 13-digit JAN code manually.
     Sample codes you can use: [JANコードを2〜3件]
  3. The result screen appears immediately, showing the product information,
     new and used offer prices, the sales rank, and price-history graphs.
  4. Scroll down on the same screen to reach the profit calculation form.

There is no user account system in this app. Therefore there is no
registration, no login, no account deletion flow, and no user-generated
content, content reporting, or blocking mechanism.

OPTIONAL AMAZON ACCOUNT LINKING

Three features additionally require the user to link their own Amazon Seller
Central account through Amazon's official OAuth flow (Login with Amazon):

  - the per-seller offer price list
  - Amazon listing eligibility / restriction warnings
  - creating listings on Amazon from within the app

We are not able to provide demo credentials for this, for two reasons.
First, Amazon's Data Protection Policy does not permit sharing Selling
Partner account credentials with third parties. Second, these features act
on the user's own seller account and can create real listings on Amazon, so
a shared test account cannot be used safely.

Instead, the attached screen recording demonstrates all three of these
features end to end, using our own seller account.

Without linking, these features are not broken. They display a lock icon
together with a message meaning "Amazon account linking is required". The
app does not crash or become unresponsive.

A note on the listing-restriction warning: this badge is shown only when the
scanned product is actually restricted for the linked seller account. For
unrestricted products, nothing is displayed. This is expected behavior
rather than a malfunction.


5. EXTERNAL SERVICES USED

  - Keepa API (api.keepa.com)
    Amazon product data, price history and sales-rank history.
    Accessed under a paid commercial API subscription.

  - Amazon Selling Partner API (sellingpartnerapi-fe.amazon.com)
    Fee estimates, listing restrictions, and listing creation.
    Called only on behalf of the signed-in user, for their own account.

  - Login with Amazon (api.amazon.com, sellercentral.amazon.co.jp)
    OAuth authorization for the Selling Partner API above.

  - Amazon product image CDN (images-na.ssl-images-amazon.com)
    Product thumbnail images.

  - Google AdMob
    Banner and rewarded advertising. Shown to free-tier users only.

  - PostHog
    Anonymous product analytics.

  - Cloudflare Workers (api.sellira.jp)
    Our own backend. It proxies the APIs above and manages the free-tier
    daily quota.

  - Apple StoreKit
    In-app purchase.

The app does not use any AI services, and it does not use any payment
processor other than Apple.


6. REGIONAL DIFFERENCES

The app is built exclusively for the Amazon.co.jp (Japan) marketplace, and
the user interface is available in Japanese only. [配信範囲をここに記載]
There are no regional differences in features or content.


7. REGULATED INDUSTRY / PROTECTED THIRD-PARTY MATERIAL

SellerLens does not operate in a regulated industry.

Regarding third-party material:

  - Amazon product data and product images are obtained through Keepa, a
    commercial data provider, under a paid API subscription and in
    accordance with its terms of service.

  - Access to the Amazon Selling Partner API is granted through our
    registered developer profile in Amazon Seller Central. Each user
    authorizes access to their own account through Amazon's official OAuth
    flow. We never access other sellers' data, and we never access any
    buyer's personal information.

  - SellerLens is an independent tool. It is not affiliated with, endorsed
    by, or sponsored by Amazon. The word "Amazon" is used only to describe
    interoperability.

We are happy to provide our Amazon developer registration details or our
Keepa subscription confirmation if you require documentation.


8. IN-APP PURCHASE SUMMARY

There is one in-app purchase:

  SellerLens Pro (セラーレンズ Pro)
  Auto-renewable subscription, 1,980 JPY per month
  Product ID: jp.sellira.sellerlens.pro.monthly

How to reach the purchase screen:

  (a) Open the Settings tab (the rightmost tab) and tap the button labelled
      "Proを始める" (Start Pro), or
  (b) Use up the free daily scan quota (5 scans per day), or tap any locked
      feature such as the blurred offer list, OCR scanning, or the price
      history graph. The paywall opens automatically.

The paywall screen displays the subscription title, its length (monthly),
its price, and links to the Terms of Use (Apple's standard EULA) and to our
Privacy Policy.

What the subscription unlocks:

  - Unlimited scanning and searching (the free tier allows 5 per day)
  - Unlimited OCR (text recognition) scanning
  - Unlimited price-history graphs
  - Full display of the offer list
  - Amazon listing-restriction warnings (also requires Amazon linking)
  - Creating Amazon listings from the app (also requires Amazon linking)
  - Removal of advertisements
  - Unlimited purchase list and profit alerts

In the Sandbox environment this subscription can be purchased without being
charged.


Thank you for your time. Please let us know if anything further is needed.
```

## 次回ビルドで直すこと（今回の返信では不要）

**`NSLocalNetworkUsageDescription` を削除する。**

`project.yml` に以下が残っているが、Releaseビルドでは接続先が
`SettingsStore.defaultServerURL`（= `https://api.sellira.jp`）に固定され、
「サーバー設定」セクションも `#if DEBUG` で消えるため、**ローカルネットワークには一切接続しない**。

```yaml
NSLocalNetworkUsageDescription: "同一Wi-Fi内のPCで動作する価格検索サーバーに接続するためにローカルネットワークを使用します。"
NSAppTransportSecurity:
  NSAllowsLocalNetworking: true
```

実際には使わない権限の説明文が残っている状態で、Guideline 5.1.1（purpose string は
実際の用途を正確に説明すること）に照らして望ましくない。さらに悪いことに、この文面は
**「このアプリはPC上の自社サーバーが必要」と読める**ため、審査担当者に不要な疑問を
生じさせる。今回の 2.1 差し戻しの一因になっている可能性も否定できない。

ただし、この文字列は実際に権限要求が発生しない限りユーザーには表示されないため、
今回の返信をブロックする理由にはならない。**次のバージョン更新時に削除すること。**
（削除するとビルド番号の更新とアップロードが必要になり、審査がやり直しになる。）
