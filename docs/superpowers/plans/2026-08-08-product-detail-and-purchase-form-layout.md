# 商品詳細・仕入れ内容画面のレイアウト刷新 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 商品詳細と仕入れ内容の上部を共通の「サムネイル+2列×3行の情報グリッド」に統一し、商品詳細にリンクボタン9種を並べ、仕入れ内容の利益セクションを出品内容へ畳み込む。

**Architecture:** 両画面で同一の見た目になるヘッダー+情報グリッドを`ProductSummaryHeader`として1つ作り2画面から使う。リンクボタンの`ResultCardActionButtons`は`SearchTabView`内のprivate構造体なので別ファイルへ出して共有し、表示種別を引数で切り替える。仕入れ内容の利益は「粗利益1行+タップで明細展開」に畳み、配送料・発送費用の入力欄は廃止して送料設定のプリセットに一本化する。

**Tech Stack:** SwiftUI / XcodeGen(新規ファイル追加時は`xcodegen generate`が必要)

**設計書:** `docs/superpowers/specs/2026-08-08-product-detail-and-purchase-form-layout-design.md`

## Global Constraints

- このプロジェクトは `main` へ直接コミットする(確立された規約)。ブランチを切らない。
- 各タスク完了ごとにコミットする。
- コメントは既存コードと同じ密度・文体(日本語、「なぜそうしたか」を書く)で揃える。
- iOSにテストターゲットは無い。**テストターゲットを新設しない。** 検証はXcodeビルドと手動確認で行う。
- サーバー側は変更しない。デプロイ不要。
- **新規ファイルを追加したら`cd ios/BarcodeSedori && xcodegen generate`を実行する。** 忘れると「Build input file cannot be found」でビルドが落ちる。
- **ASINの取得・保存・出品は既に実装済みなので触らない。** 今回やるのは表示だけ。
- デプロイメントターゲットは iOS 16.0。
- ビルド確認コマンド:
  ```bash
  cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
  ```

---

### Task 1: 共通ヘッダー部品と商品詳細への適用

**Files:**
- Create: `ios/BarcodeSedori/Sources/Views/ProductSummaryHeader.swift`
- Modify: `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`
- Modify: `ios/BarcodeSedori/Sources/Views/ProductsTabView.swift`(呼び出し側に`scannedAt`を足す)
- Modify: `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`(同上)

**Interfaces:**
- Produces: `ProductSummaryHeader(imageUrl:title:jan:asin:salesRank:listPrice:releaseDate:dateLabel:date:)` — Task 3 が仕入れ内容画面から同じものを使う。

- [ ] **Step 1: `ProductSummaryHeader.swift` を作成する**

Create `ios/BarcodeSedori/Sources/Views/ProductSummaryHeader.swift`:

```swift
import SwiftUI

/// 商品のサムネイル・タイトルと、JAN/ASIN/ランク/参考価格/発売日/日付の6項目をまとめて出す部品。
/// 商品詳細画面と仕入れ内容画面で見た目を揃えるため、両方からこれを使う
/// (別々に書くと片方だけ直し忘れてズレるため)。
///
/// 右下のセルだけ画面によってラベルが変わる(商品詳細は「検索日」、仕入れ内容は「追加日」)ので、
/// ラベルと値を引数で受け取る。
///
/// **Formの中で使うときの注意**: 行の余白と背景が付いてカードに見えなくなるため、
/// `.listRowInsets(EdgeInsets())` と `.listRowBackground(Color.clear)` を必ず付けること。
struct ProductSummaryHeader: View {
    let imageUrl: String?
    let title: String?
    /// JAN欄に出す値。呼び出し側で `isbn13 ?? スキャンコード` を解決して渡す。
    let jan: String?
    let asin: String?
    let salesRank: Int?
    /// 定価(税込・円)。「参考価格」欄に出す。
    let listPrice: Int?
    /// 発売日(ISO日付文字列、例 "2025-06-17")。表示時に "2025/6/17" へ整形する。
    let releaseDate: String?
    /// 右下セルのラベル。「検索日」または「追加日」。
    let dateLabel: String
    let date: Date?

    /// 発売日のパース用(サーバーはSP-APIの "2019-05-30" 等のISO日付文字列をそのまま返す)。
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 日付の表示用(例: "2025/6/17")。
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    /// 数値の3桁区切り用(ランク・参考価格)。
    private static let groupedNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func groupedNumber(_ value: Int) -> String {
        groupedNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var rankText: String {
        salesRank.map { "\(Self.groupedNumber($0))位" } ?? "圏外"
    }

    private var listPriceText: String {
        listPrice.map { "¥\(Self.groupedNumber($0))" } ?? "-"
    }

    private var releaseDateText: String {
        guard let releaseDate, let parsed = Self.isoDateFormatter.date(from: releaseDate) else { return "-" }
        return Self.displayDateFormatter.string(from: parsed)
    }

    private var dateText: String {
        guard let date else { return "-" }
        return Self.displayDateFormatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            productImage
                .frame(width: 88, height: 88)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

            Text(title ?? "(タイトル不明)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    /// 商品画像。URLが無い/読み込み失敗時はプレースホルダ
    /// (URLなしでAsyncImageを使うとempty phaseでスピナーが回り続けるため先に分岐する)。
    @ViewBuilder
    private var productImage: some View {
        if let url = imageUrl.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    imagePlaceholder
                case .empty:
                    ProgressView()
                @unknown default:
                    Color.clear
                }
            }
        } else {
            imagePlaceholder
        }
    }

    private var imagePlaceholder: some View {
        Image(systemName: "photo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.secondary)
            .padding(24)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            gridRow(leftLabel: "JAN", leftValue: jan ?? "-", rightLabel: "ASIN", rightValue: asin ?? "-")
            Divider()
            gridRow(leftLabel: "ランク", leftValue: rankText, rightLabel: "参考価格", rightValue: listPriceText)
            Divider()
            gridRow(leftLabel: "発売日", leftValue: releaseDateText, rightLabel: dateLabel, rightValue: dateText)
        }
    }

    private func gridRow(leftLabel: String, leftValue: String, rightLabel: String, rightValue: String) -> some View {
        HStack(spacing: 0) {
            gridCell(label: leftLabel, value: leftValue)
            Divider()
            gridCell(label: rightLabel, value: rightValue)
        }
        // セル間の縦線を行の高さいっぱいにするため、縦方向だけ内容に合わせて固定する。
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gridCell(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.footnote)
                .fontWeight(.medium)
                .monospacedDigit()
                // ASINやJANは桁が多く、狭いセルでは折り返さず縮めて1行に収める。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 2: `xcodegen generate` を実行する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/ios/BarcodeSedori" && xcodegen generate
```

Expected: エラーなく完了。これを飛ばすと新規ファイルが`.xcodeproj`に入らずビルドが落ちる。

- [ ] **Step 3: `ProductDetailView` にプロパティを追加する**

Modify `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`。

`let title: String?` の**直前**に追加:

```swift
    /// ASIN。情報グリッドの「ASIN」欄に出す(JANの無い商品でも識別できるようにするため)。
    let asin: String?
```

`let prices: SearchPrices?` の**直後**に追加:

```swift
    /// 検索日(履歴の`scannedAt`)。情報グリッドの右下セルに出す。
    let scannedAt: Date?
```

`init` の中で、`self.title = title` の**直前**に追加:

```swift
        self.asin = asin
```

`self.prices = prices` の**直後**に追加:

```swift
        self.scannedAt = scannedAt
```

`init`の引数リストにも `scannedAt: Date?` を追加する(`prices: SearchPrices?` の直後)。`asin`は既に引数にあるのでそのまま。

- [ ] **Step 4: `ProductDetailView` の本文を差し替える**

同ファイル。置換前:

```swift
                headerCard
                infoCard
                offersPanels
```

置換後:

```swift
                ProductSummaryHeader(
                    imageUrl: imageUrl,
                    title: title,
                    jan: janCode,
                    asin: asin,
                    salesRank: salesRank,
                    listPrice: listPrice,
                    releaseDate: releaseDate,
                    dateLabel: "検索日",
                    date: scannedAt
                )
                offersPanels
```

そのうえで、使われなくなった以下を**削除**する(`ProductSummaryHeader`へ移したため)。

- `headerCard` / `productImage` / `imagePlaceholder` / `infoCard` / `infoRow`
- `releaseDateText` / `groupedNumber` / `releaseDateInputFormatter` / `releaseDateOutputFormatter` / `groupedNumberFormatter`

**注意:** `groupedNumber`が他の場所(オファーパネル等)からも呼ばれていないか、削除前に必ず確認すること。

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && grep -n "groupedNumber\|releaseDateText" ios/BarcodeSedori/Sources/Views/ProductDetailView.swift
```

残っている参照があれば、その箇所は削除せず残すか、`ProductSummaryHeader`側と同じ実装をこのファイルに残すこと。

- [ ] **Step 5: 呼び出し側に `scannedAt` を渡す**

Modify `ios/BarcodeSedori/Sources/Views/ProductsTabView.swift`。`prices: selectedItem.prices` の**直後**に追加:

```swift
                scannedAt: selectedItem.scannedAt,
```

Modify `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`(631行目付近の`ProductDetailView(`)。同じく`prices:`の直後に追加:

```swift
                // 検索直後の遷移なので「検索日」は今日。
                scannedAt: Date(),
```

引数の順序は`init`の宣言順に合わせること(Swiftは順序が違うとコンパイルエラーになる)。

- [ ] **Step 6: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Views/ProductSummaryHeader.swift ios/BarcodeSedori/Sources/Views/ProductDetailView.swift ios/BarcodeSedori/Sources/Views/ProductsTabView.swift ios/BarcodeSedori/Sources/Views/SearchTabView.swift && git commit -m "iOS: 商品情報のヘッダーを共通部品にし、ASINと検索日を出す

サムネイル+タイトルと、JAN/ASIN/ランク/参考価格/発売日/検索日の2列グリッドを
ProductSummaryHeaderへ切り出した。仕入れ内容画面でも同じ見た目にするため、
別々に書かず1つの部品を共有する。ASINはJANの無い商品でも識別できるように追加した。"
```

---

### Task 2: リンクボタンの共有化と商品詳細への設置

**Files:**
- Create: `ios/BarcodeSedori/Sources/Views/ResultCardActionButtons.swift`(`SearchTabView.swift`から移動)
- Modify: `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`(移動元の削除・`kinds`引数の受け渡し)
- Modify: `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`(リンクボタン設置・専用ボタン削除)

**Interfaces:**
- Consumes: `ProductSummaryHeader`(Task 1)
- Produces: `ResultCardActionButtons(result:kinds:isPro:isInPurchaseList:onAddToPurchaseList:onLockedPurchaseTap:onOpenLink:)`

**背景(実装者向け):** `ResultCardActionButtons`は現在`SearchTabView.swift`内の`private struct`で他画面から使えない。ボタンは`.frame(maxWidth: .infinity)`で全幅を等分し高さのみ34pt固定なので、9個並べても見切れない(iPhone SEでは1個あたり約33ptと細くなる)。

- [ ] **Step 1: `ResultCardActionButtons` を新規ファイルへ移動する**

`SearchTabView.swift` から `ResultCardActionButtons` の構造体全体(コメント含む。`// MARK: - 結果カードのアクションボタングリッド` から構造体の閉じ括弧まで)を切り取り、`ios/BarcodeSedori/Sources/Views/ResultCardActionButtons.swift` として新規作成する。

新ファイルの先頭は次のとおり:

```swift
import SwiftUI

// MARK: - リンクボタン列(検索結果カード / 商品詳細で共有)
```

構造体の宣言を`private struct`から`struct`へ変える(同一モジュール内なのでアクセス修飾子なし=internalでよい):

```swift
/// 1列横並びのリンクボタン列。検索結果カードと商品詳細で共有する。
/// 表示する種類は`kinds`で受け取る(検索カードは設定で選んだ4つ、商品詳細は9種すべて)。
/// 「仕入れ」= 仕入れフォームを開く(Pro限定・ASINあり)。それ以外は各サービスの検索/商品ページを
/// アプリ内ブラウザで開く(いずれも無料でも使え、検索キーワードが必要)。
struct ResultCardActionButtons: View {
    let result: SearchResult
    /// 表示候補のボタン種別(順序を保つ)。この中から`showsButton`を満たすものだけ並ぶ。
    let kinds: [LinkButtonKind]
    let isPro: Bool
    let isInPurchaseList: Bool
    let onAddToPurchaseList: () -> Void
    let onLockedPurchaseTap: () -> Void
    /// 外部リンクタップ時の処理。親側でアプリ内ブラウザ(SafariView)のシートを開く。
    let onOpenLink: (URL) -> Void
```

`visibleButtons`を置換する。置換前:

```swift
    private var visibleButtons: [LinkButtonKind] {
        settings.linkButtons.filter(showsButton)
    }
```

置換後:

```swift
    private var visibleButtons: [LinkButtonKind] {
        kinds.filter(showsButton)
    }
```

**`settings`プロパティは削除しない。** `searchKeyword`が`settings.linkSearchByModelNumber`を参照しているため引き続き必要。

- [ ] **Step 2: `xcodegen generate` を実行する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)/ios/BarcodeSedori" && xcodegen generate
```

Expected: エラーなく完了。

- [ ] **Step 3: 検索画面の呼び出しに `kinds` を渡す**

Modify `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`。`ResultCardActionButtons(` の呼び出しを探し、`result:` の直後に追加:

```swift
                        // 検索カードは設定で選んだ4つのまま(スキャン中はよく使うものだけ出す)。
                        kinds: settings.linkButtons,
```

呼び出し箇所は次で確認する:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && grep -n "ResultCardActionButtons(" ios/BarcodeSedori/Sources/Views/SearchTabView.swift
```

呼び出し元のビューに`settings`が無い場合は、そのビューに `@ObservedObject private var settings = SettingsStore.shared` を追加すること。

- [ ] **Step 4: 商品詳細にリンクボタンを置き、専用ボタンを削除する**

Modify `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`。本文の置換前:

```swift
                offersPanels
                addToPurchaseButton
                graphSection
```

置換後:

```swift
                offersPanels
                linkButtons
                graphSection
```

`addToPurchaseButton` の実装全体を**削除**し、代わりに次を追加する:

```swift
    /// オファーカードの下に置くリンクボタン列。商品詳細では設定に関わらず9種すべて出す
    /// (スキャン中はよく使うものだけ、じっくり見る詳細では全部、という使い分け)。
    /// 仕入れボタンもこの中に含まれるため、専用の「仕入れリストに追加」ボタンは置かない。
    @ViewBuilder
    private var linkButtons: some View {
        if let result = viewModel.searchResultForLinks {
            ResultCardActionButtons(
                result: result,
                kinds: LinkButtonKind.allCases,
                isPro: entitlements.isPro,
                isInPurchaseList: isInPurchaseList,
                onAddToPurchaseList: { purchaseFormDraft = makePurchaseDraft() },
                onLockedPurchaseTap: { showPaywall = true },
                onOpenLink: { url in browserTarget = BrowserTarget(url: url) }
            )
        }
    }
```

**この時点では `viewModel.searchResultForLinks` / `makePurchaseDraft()` / `browserTarget` がまだ存在しない。** 次のステップで作る。

- [ ] **Step 5: 不足している依存を用意する**

同ファイル。`isInPurchaseList` の**直前**に、次の2つを追加する。

```swift
    /// リンクボタンの「仕入れ」から開く仕入れフォームの下書き。
    /// 旧「仕入れリストに追加」ボタンが作っていたものと同じ内容
    /// (まだ仕入れリストへは登録せず、保存=緑チェックで初めてPurchaseListStoreへ入る)。
    private func makePurchaseDraft() -> PurchaseListItem {
        PurchaseListItem(
            asin: viewModel.asin,
            title: title,
            imageUrl: imageUrl,
            scannedCode: janCode,
            isbn13: nil,
            salesRank: salesRank,
            offersResult: viewModel.offers
        )
    }

    /// リンクボタンへ渡すSearchResult。商品詳細は個別のフィールドしか持たないため、
    /// リンク生成に必要な項目だけを詰めて組み立てる。
    /// `modelNumber`は商品詳細が保持していないためnil固定で、その場合リンクは
    /// タイトル検索へフォールバックする(ResultCardActionButtons.searchKeywordの仕様どおり)。
    private var searchResultForLinks: SearchResult {
        SearchResult(
            codeType: .isbn,
            asin: viewModel.asin,
            title: title,
            isbn13: nil,
            imageUrl: imageUrl,
            salesRank: salesRank,
            releaseDate: releaseDate,
            modelNumber: nil,
            prices: prices,
            source: nil,
            offers: viewModel.offers,
            profitInputs: nil,
            quota: nil,
            keepaDebug: nil
        )
    }
```

`makePurchaseDraft`が`listPrice` / `releaseDate`を渡していないのは、それらを`PurchaseListItem`へ足すのがTask 3だから。**Task 3のStep 1bで、このタスクへ戻って2行を足す**(そこまでは商品詳細から追加した項目の参考価格・発売日が`-`になるが、Task 3完了時点で解消する)。

`SearchResult`の引数はすべて必須(メンバーワイズinit)。`codeType`は`CodeType`列挙で、リンク生成に使われないため`.isbn`固定でよい。定義は`ios/BarcodeSedori/Sources/Models/SearchModels.swift`。**フィールドが増減していたら実際の定義に合わせること。**

Step 4で書いた`linkButtons`の`if let result = viewModel.searchResultForLinks {`は、`searchResultForLinks`が非Optionalかつ`ProductDetailView`側のプロパティになったため次のように直す:

```swift
    @ViewBuilder
    private var linkButtons: some View {
        ResultCardActionButtons(
            result: searchResultForLinks,
            kinds: LinkButtonKind.allCases,
            isPro: entitlements.isPro,
            isInPurchaseList: isInPurchaseList,
            onAddToPurchaseList: { purchaseFormDraft = makePurchaseDraft() },
            onLockedPurchaseTap: { showPaywall = true },
            onOpenLink: { url in browserTarget = BrowserTarget(url: url) }
        )
    }
```

最後に、アプリ内ブラウザのシート。`BrowserTarget`は`ios/BarcodeSedori/Sources/Views/SafariView.swift`で既に`internal`として定義済みなので、移動は不要でそのまま使える。

`@State private var showPaywall = false` の**直後**に追加:

```swift
    /// リンクボタンから開くアプリ内ブラウザ(SafariView)の対象。
    @State private var browserTarget: BrowserTarget?
```

`.sheet(isPresented: $showPaywall) { PaywallView() }` の**直後**に追加:

```swift
        .sheet(item: $browserTarget) { target in
            SafariView(url: target.url)
        }
```

- [ ] **Step 6: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: ファイル冒頭のコメントを直す**

`ProductDetailView.swift` の冒頭に「リンクボタン(仕/a/m/楽 等)は置かない(ユーザー指示 2026-08-02)」というコメントがある。今回の指示で覆るため置換する:

```swift
/// リンクボタンは9種すべてをオファーカードの下に置く(ユーザー指示 2026-08-08。
/// 2026-08-02の「置かない」から変更)。仕入れボタンもこの中に含むため、
/// 専用の「仕入れリストに追加」ボタンは置かない。
```

- [ ] **Step 8: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Views/ResultCardActionButtons.swift ios/BarcodeSedori/Sources/Views/SearchTabView.swift ios/BarcodeSedori/Sources/Views/ProductDetailView.swift && git commit -m "iOS: リンクボタンを共有化し、商品詳細に9種すべて並べる

SearchTabView内のprivate structだったResultCardActionButtonsを別ファイルへ出し、
表示する種類をkinds引数で受け取るようにした。検索カードは従来どおり設定で選んだ4つ、
商品詳細は9種すべて。仕入れボタンが含まれるため、商品詳細の専用「仕入れリストに追加」
ボタンは削除し、タップ時の処理はリンクボタンのコールバックへ引き継いだ。"
```

---

### Task 3: 仕入れ内容画面のヘッダーとキャンセルボタン

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Models/PurchaseListItem.swift`
- Modify: `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`(Step 1bのみ)
- Modify: `ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`

**Interfaces:**
- Consumes: `ProductSummaryHeader`(Task 1)
- Produces: `PurchaseListItem.listPrice: Int?` / `releaseDate: String?`、`PurchaseFormViewModel.showsCancelButton: Bool`

- [ ] **Step 1: `PurchaseListItem` に2項目を追加する**

Modify `ios/BarcodeSedori/Sources/Models/PurchaseListItem.swift`。`var salesRank: Int?` に続く既存プロパティ群の並びに合わせて追加:

```swift
    /// 定価(税込・円)。仕入れ内容画面の「参考価格」に出す。追加時に検索結果から引き継ぐ。
    var listPrice: Int?
    /// 発売日(ISO日付文字列、例 "2025-06-17")。仕入れ内容画面の「発売日」に出す。
    var releaseDate: String?
```

メンバーワイズ`init`にも既定値`nil`付きで追加する(既存の呼び出し側を壊さないため)。引数リストの`salesRank`の直後、本体の代入も同じ位置に入れる:

```swift
        listPrice: Int? = nil,
        releaseDate: String? = nil,
```

```swift
        self.listPrice = listPrice
        self.releaseDate = releaseDate
```

`init(result:scannedCode:offersResult:)` を置換。置換前:

```swift
    init(result: SearchResult, scannedCode: String?, offersResult: OffersResult?) {
        self.init(
            asin: result.asin ?? "",
            title: result.title,
            imageUrl: result.imageUrl,
            scannedCode: scannedCode,
            isbn13: result.isbn13,
            salesRank: result.salesRank,
            offersResult: offersResult
        )
    }
```

置換後:

```swift
    init(result: SearchResult, scannedCode: String?, offersResult: OffersResult?) {
        self.init(
            asin: result.asin ?? "",
            title: result.title,
            imageUrl: result.imageUrl,
            scannedCode: scannedCode,
            isbn13: result.isbn13,
            salesRank: result.salesRank,
            // 参考価格はSearchResult直下ではなくProfitInputsの中にある(発売日は直下)。
            listPrice: result.profitInputs?.listPrice,
            releaseDate: result.releaseDate,
            offersResult: offersResult
        )
    }
```

**引数の順序はメンバーワイズ`init`の宣言順に合わせること。** `offersResult`が`releaseDate`より前に宣言されている場合は、その順に並べ替える。

- [ ] **Step 1b: 商品詳細の下書き生成に2項目を渡す**

Task 2で`PurchaseListItem`にまだこの2項目が無かったため、`ProductDetailView.makePurchaseDraft()`は渡していない。Step 1で追加できたのでここで足す。

Modify `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`。`makePurchaseDraft()` の中、`salesRank: salesRank,` の**直後**に追加:

```swift
            listPrice: listPrice,
            releaseDate: releaseDate,
```

これを入れないと、商品詳細から仕入れリストへ追加した項目の参考価格・発売日が`-`のままになる。

**引数の順序はメンバーワイズ`init`の宣言順に合わせること。**

- [ ] **Step 2: `PurchaseFormViewModel` に読み出しを追加する**

Modify `ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`。既存の`janCode` / `salesRank`計算プロパティの直後に追加:

```swift
    /// 情報グリッドの「参考価格」。編集時は保存値、新規追加時は下書きの値。
    var listPrice: Int? {
        switch mode {
        case .add(let draft): return draft.listPrice
        case .edit(let item): return item.listPrice
        }
    }

    /// 情報グリッドの「発売日」(ISO日付文字列)。
    var releaseDate: String? {
        switch mode {
        case .add(let draft): return draft.releaseDate
        case .edit(let item): return item.releaseDate
        }
    }

    /// 情報グリッドの右下「追加日」。
    var addedAt: Date {
        switch mode {
        case .add(let draft): return draft.addedAt
        case .edit(let item): return item.addedAt
        }
    }

    /// キャンセルボタンを出すか。編集モードは画面遷移(NavigationLink)で開くため
    /// 戻る「‹」があり二重になる。新規追加はシート表示で、消すと下スワイプ以外に
    /// 閉じる手段が無くなるため残す。
    var showsCancelButton: Bool {
        if case .add = mode { return true }
        return false
    }
```

`asin`計算プロパティが無い場合は同じ作法で追加すること(`PurchaseListItem.asin`は両モードとも非Optionalの`String`)。

- [ ] **Step 3: 商品セクションを差し替える**

同ファイル。置換前:

```swift
            Section("商品") {
                Text(viewModel.title ?? "(タイトル不明)")
                    .font(.subheadline)
                HStack {
                    Text("JANコード")
                    Spacer()
                    Text(viewModel.janCode ?? "-")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("ランキング")
                    Spacer()
                    if let rank = viewModel.salesRank {
                        Text("\(rank)位")
                            .foregroundColor(.secondary)
                    } else {
                        Text("-")
                            .foregroundColor(.secondary)
                    }
                }
                restrictionRow
            }
```

置換後:

```swift
            Section {
                ProductSummaryHeader(
                    imageUrl: viewModel.imageUrl,
                    title: viewModel.title,
                    jan: viewModel.janCode,
                    asin: viewModel.asin,
                    salesRank: viewModel.salesRank,
                    listPrice: viewModel.listPrice,
                    releaseDate: viewModel.releaseDate,
                    dateLabel: "追加日",
                    date: viewModel.addedAt
                )
                // Formの行の余白と背景を消して、部品自身のカード見た目をそのまま出す。
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                restrictionRow
            }
```

`viewModel.imageUrl`が無ければ、Step 2と同じ作法で追加する。

- [ ] **Step 4: キャンセルボタンを条件付きにする**

同ファイル。置換前:

```swift
            ToolbarItem(placement: .cancellationAction) {
                // キャンセル・スワイプ閉じは登録しない(saveを呼ばずに閉じるだけ)。
                Button("キャンセル") { dismiss() }
            }
```

置換後:

```swift
            ToolbarItem(placement: .cancellationAction) {
                // キャンセル・スワイプ閉じは登録しない(saveを呼ばずに閉じるだけ)。
                // 編集モードは戻る「‹」があり二重になるため出さない(showsCancelButton参照)。
                if viewModel.showsCancelButton {
                    Button("キャンセル") { dismiss() }
                }
            }
```

- [ ] **Step 5: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Models/PurchaseListItem.swift ios/BarcodeSedori/Sources/Views/ProductDetailView.swift ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift && git commit -m "iOS: 仕入れ内容の商品情報を共通ヘッダーに揃え、編集時のキャンセルを消す

商品詳細と同じProductSummaryHeaderを使い、ASIN・参考価格・発売日・追加日を出す。
参考価格と発売日はPurchaseListItemに無かったため任意項目として追加し、
仕入れリストへの追加時に検索結果から引き継ぐ(参考価格はProfitInputsの中にある)。
キャンセルボタンは編集モードだと戻る「‹」と二重になるため新規追加時のみ出す。"
```

---

### Task 4: 利益セクションを出品内容へ畳み込む

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`

**Interfaces:**
- Consumes: Task 3 の`PurchaseFormViewModel`拡張

**背景(実装者向け):** 現在の`profitSection`は「出品価格(表示)/配送料(入力)/仕入れ価格(入力)/手数料/発送費用(入力)/粗利益」の6行。これを出品内容へ畳み込み、**粗利益1行+タップで明細展開**にする。配送料・発送費用の入力欄は廃止し、送料設定のプリセット由来の値だけを使う。

- [ ] **Step 1: 数量倍の計算をViewModelへ追加する**

Modify `ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`。`grossProfit`を置換。置換前:

```swift
    var grossProfit: Int? {
        guard let price, let purchasePrice, case .loaded(let display) = feesState else { return nil }
        return price + (shippingIncome ?? 0) - purchasePrice - display.total - (shippingCost ?? 0)
    }
```

置換後:

```swift
    /// 数量倍した値。明細と粗利益は合計で見せる(入力欄は1個あたりのまま)。
    func multiplied(_ amount: Int) -> Int { amount * quantity }

    /// 明細に出す各項目(すべて数量倍済み)。入力欄の値は1個あたりなのでここで掛ける。
    var totalPrice: Int? { price.map { $0 * quantity } }
    var totalShippingIncome: Int { (shippingIncome ?? 0) * quantity }
    var totalPurchasePrice: Int? { purchasePrice.map { $0 * quantity } }
    var totalShippingCost: Int { (shippingCost ?? 0) * quantity }

    /// 粗利益(数量倍)。= 数量 × (出品価格 + 配送料 − 仕入れ価格 − 手数料 − 発送費用)。
    /// 出品価格・仕入れ価格が未入力、または手数料が未取得(idle/loading/unavailable)の間は
    /// 計算せずnilを返す(呼び出し側は「—」表示にする)。
    var grossProfit: Int? {
        guard let price, let purchasePrice, case .loaded(let display) = feesState else { return nil }
        let perUnit = price + (shippingIncome ?? 0) - purchasePrice - display.total - (shippingCost ?? 0)
        return perUnit * quantity
    }
```

- [ ] **Step 2: 入力欄の無くなったフォーカス対象を削除する**

同ファイル、`PurchaseFormView`の`private enum Field`。`case shippingIncome` と `case shippingCost` を削除する(入力欄が無くなるため)。`case purchasePrice`は残す。

- [ ] **Step 3: 粗利益の折りたたみを実装する**

同ファイル。`profitSection` と `feesRow` の実装を**すべて削除**し、代わりに次を追加する:

```swift
    /// 粗利益の折りたたみ。タップで明細が開き、明細の中の手数料はさらに入れ子で開く。
    /// 明細は小さめの文字・行間を詰める・区切り線なし(DisclosureGroup1つを1行に収めるため、
    /// Formの行区切りは自動的に入らない)。
    private var profitDisclosure: some View {
        DisclosureGroup {
            VStack(spacing: 2) {
                profitDetailRow("出品価格", viewModel.totalPrice)
                profitDetailRow("配送料", viewModel.totalShippingIncome)
                profitDetailRow("仕入れ価格", viewModel.totalPurchasePrice, isCost: true)
                profitDetailRow("発送費用", viewModel.totalShippingCost, isCost: true)
                feesDisclosure
            }
            .padding(.top, 2)
        } label: {
            HStack {
                Text("粗利益")
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Spacer()
                Text(viewModel.grossProfit.map(Self.currencyText) ?? "—")
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
        }
    }

    /// 明細の1行。出ていくお金(isCost)は赤字にする。
    private func profitDetailRow(_ label: String, _ amount: Int?, isCost: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.map(Self.currencyText) ?? "—")
        }
        .font(.footnote)
        .foregroundColor(isCost ? .red : .primary)
    }

    /// 明細の中の手数料。取得できていれば内訳を入れ子で開ける。
    /// 内訳は取得できた項目をそのまま並べるため、FBA利用時はFBA手数料も含まれる。
    @ViewBuilder
    private var feesDisclosure: some View {
        switch viewModel.feesState {
        case .loaded(let display):
            DisclosureGroup {
                VStack(spacing: 2) {
                    ForEach(display.breakdown, id: \.type) { line in
                        profitDetailRow(line.label, viewModel.multiplied(line.amount), isCost: true)
                    }
                    if let note = display.fbaRequiresLinkNote {
                        HStack {
                            Text("FBA手数料")
                            Spacer()
                            Text(note)
                        }
                        .font(.footnote)
                        .foregroundColor(.red)
                    }
                }
                .padding(.top, 2)
            } label: {
                HStack {
                    Text("手数料")
                    Spacer()
                    Text(Self.currencyText(viewModel.multiplied(display.total))
                         + (display.isEstimate ? "(概算)" : ""))
                }
                .font(.footnote)
                .foregroundColor(.red)
            }

        case .idle:
            profitDetailRow("手数料", nil, isCost: true)

        case .loading:
            HStack {
                Text("手数料")
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            .font(.footnote)
            .foregroundColor(.red)

        case .unavailable(let message):
            HStack(alignment: .top) {
                Text("手数料")
                Spacer()
                Text(message)
                    .multilineTextAlignment(.trailing)
            }
            .font(.footnote)
            .foregroundColor(.red)
        }
    }
```

- [ ] **Step 4: 出品内容セクションへ組み込み、利益セクションを外す**

同ファイル。`Section("出品内容")` の中、`Toggle("FBAを利用", ...)` の**直後**(セクションの末尾)に追加:

```swift
                HStack {
                    Text("仕入れ価格(円)")
                        .foregroundColor(.red)
                    Spacer()
                    TextField("仕入れ価格", value: $viewModel.purchasePrice, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .foregroundColor(.red)
                        .focused($focusedField, equals: .purchasePrice)
                }

                profitDisclosure
```

そのうえで、本文から `profitSection` の呼び出し行を**削除**する。

- [ ] **Step 5: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

`shippingIncome` / `shippingCost` を参照している箇所が残ってエラーになる場合、入力欄以外(初期化・保存・`shippingToDisplay`・手数料計算)は**そのまま残す**こと。削除するのは入力欄とフォーカス対象だけ。

- [ ] **Step 6: 残骸が無いことを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && grep -n "profitSection\|feesRow\|Field.shippingIncome\|Field.shippingCost" ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift; echo "(上が空ならOK)"
```

Expected: 出力が空。

- [ ] **Step 7: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift && git commit -m "iOS: 利益セクションを出品内容へ畳み込み、粗利益をタップで展開にする

利益セクションを廃止し、出品内容の末尾に仕入れ価格の入力欄と粗利益を置いた。
粗利益はタップで明細(出品価格/配送料/仕入れ価格/発送費用/手数料)が開き、
手数料はさらに入れ子で内訳が開く。明細は小さめの文字・行間を詰め・区切り線なし。
出ていくお金(仕入れ価格・発送費用・手数料とその内訳)は赤字にした。

配送料・発送費用の入力欄は廃止し、送料設定のプリセットに一本化した。
明細と粗利益は数量を掛けた合計を出す(入力欄は1個あたりのまま)。"
```

---

## 実装後の確認事項

- [ ] `git status` がクリーンであること
- [ ] Xcodeビルドが `** BUILD SUCCEEDED **` であること
- [ ] サーバーは変更していないため、デプロイは不要

## 手動確認(ユーザー実施。実機/シミュレータ)

設計書§6の18項目。実装者は行わなくてよい。

1. 商品詳細に「JAN / ASIN / ランク / 参考価格 / 発売日 / 検索日」の6セルが出る。値の無いものは`-`
2. 商品詳細のオファーカードの下にリンクボタンが9種並び、見切れない(iPhone SEで確認)
3. 商品詳細から専用の「仕入れリストに追加」ボタンが消えている
4. リンクボタンの仕入れをタップすると、従来と同じく仕入れフォームがシートで開く
5. 非Proでリンクボタンの仕入れをタップするとペイウォールが出る
6. 検索画面の結果カードは従来どおり設定で選んだ4つのまま
7. 仕入れ内容(新規追加)に同じ6セルが出て、右下が「追加日」。**キャンセルボタンがある**
8. 仕入れ内容(編集)でも同じ6セルが出る。**キャンセルボタンが無く、戻る「‹」だけ**
9. アップデート前に保存した仕入れ項目は参考価格と発売日が`-`
10. 新しく追加した項目には参考価格と発売日が入っている
11. 「利益」セクションが無くなり、出品内容の末尾に「仕入れ価格」入力欄と「粗利益」がある
12. 配送料・発送費用の入力欄がどこにも無い
13. 粗利益をタップすると明細が開く。文字が小さく、行間が詰まり、区切り線が無い
14. 明細の中の手数料をタップすると販売手数料・カテゴリ成約料・消費税が開く
15. FBAをONにすると手数料の明細にFBA手数料が並ぶ
16. 仕入れ価格・発送費用・手数料・その内訳が赤字。出品価格・配送料は通常色
17. 数量を1→3に変えると明細と粗利益が3倍になる。入力欄は1個あたりのまま
18. 手数料が取得できない商品では粗利益が`—`
