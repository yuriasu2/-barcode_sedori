# 出品価格を「最安値 − 配送料」で自動入力する 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 仕入れフォームの出品価格に「そのコンディションの最安値 − 配送料」を自動入力する機能を、既定オフの設定トグル付きで追加する。

**Architecture:** 差し引きの判定(トグル・FBA・下限クランプ)は`ListingModels`の純粋関数1箇所に集約し、`PurchaseFormViewModel`の3つの再計算箇所(初期化・コンディション変更・FBA切替)から共通で呼ぶ。差し引く配送料は設定「利益計算用送料」の配送料デフォルトで、`PurchaseFormViewModel`が`shippingToSubtract`として公開し、計算と画面表示の両方でこの1つの値を使う。

**Tech Stack:** SwiftUI / UserDefaults(`SettingsStore`) / 純粋ロジックの検証は`swiftc`単体コンパイル

**設計書:** `docs/superpowers/specs/2026-08-07-listing-price-minus-shipping-design.md`

## Global Constraints

- このプロジェクトは `main` へ直接コミットする(確立された規約)。ブランチを切らない。
- 各タスク完了ごとにコミットする(確認不要)。
- コメントは既存コードと同じ密度・文体(日本語、「なぜそうしたか」を書く)で揃える。
- iOSにテストターゲットは無い。**テストターゲットを新設しない。** 検証はTask 1のスタンドアロン検証とXcodeビルドで行う。
- シミュレータ起動での目視確認は不要(ビルド成功まででよい)。
- サーバー側は変更しない。デプロイ不要。
- Xcodeプロジェクトファイルは XcodeGen 生成でgit非追跡。`.xcodeproj`への手動登録作業は不要だが、新規ファイルを追加した場合は`cd ios/BarcodeSedori && xcodegen generate`の実行が必要(このプランでは新規ファイルは作らない)。
- 設定トグルの既定値は **オフ**。既存ユーザーの挙動を変えない。
- ビルド確認コマンド:
  ```bash
  cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
  ```

---

### Task 1: 差し引き計算の純粋関数

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Models/ListingModels.swift`(`bucketLowestPrice`の直下に追加)
- Test: スクラッチ領域の使い捨て検証スクリプト(コミットしない)

**Interfaces:**
- Consumes: 既存の `ListingModels.bucketLowestPrice(offers:condition:) -> Int?`
- Produces: `ListingModels.autoFillListingPrice(offers: OffersResult?, condition: ListingConditionType, shippingIncome: Int, subtractShipping: Bool) -> Int?` — Task 3 がこれを3箇所から呼ぶ

**背景(実装者向け):** `ListingModels.swift` は「swiftc単体コンパイルで検証可能なようViewから分離」された純粋ロジック置き場。依存は `OffersModels.swift` のみで、どちらも `import Foundation` だけ。この2ファイル＋使い捨ての `main.swift` を `swiftc` でまとめてビルドすれば、Xcodeテストターゲット無しで本物の検証ができる(この手順は事前に動作確認済み)。

- [ ] **Step 1: 失敗する検証スクリプトを書く**

作業ディレクトリを作り、実ソース2ファイルをコピーする:

```bash
W="/private/tmp/claude-501/-Users-yuyads-Claude-Projects-----------1-/59dd209b-744e-4ddf-b592-9c36f36ce57d/scratchpad/listing-price-check"
rm -rf "$W" && mkdir -p "$W"
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)"
cp ios/BarcodeSedori/Sources/Models/OffersModels.swift ios/BarcodeSedori/Sources/Models/ListingModels.swift "$W/"
```

`$W/main.swift` を次の内容で作成する(トップレベルコードは `main.swift` という名前でないとコンパイルできない):

```swift
import Foundation

var failures = 0

func expect(_ actual: Int?, _ expected: Int?, _ label: String) {
    if actual == expected {
        print("OK   \(label) -> \(String(describing: actual))")
    } else {
        print("FAIL \(label): expected \(String(describing: expected)), got \(String(describing: actual))")
        failures += 1
    }
}

/// 中古バケットに指定のlandedを1件だけ持つオファー。
func usedOffers(landed: Int) -> OffersResult {
    OffersResult(
        source: "spapi", referencePrice: nil, newCount: nil, usedCount: nil, releaseDate: nil,
        new: nil,
        used: [Offer(condition: "good", price: landed, shipping: 0, landed: landed,
                     isBuyBox: nil, isAmazon: nil, sameCount: nil)]
    )
}

let emptyOffers = OffersResult(source: "spapi", referencePrice: nil, newCount: nil, usedCount: nil,
                               releaseDate: nil, new: nil, used: nil)

// 設計書§3.2の判定表をそのまま検証する。

expect(ListingModels.autoFillListingPrice(offers: usedOffers(landed: 1000), condition: .usedGood,
                                          shippingIncome: 350, subtractShipping: false),
       1000, "トグルオフは最安値そのまま")

expect(ListingModels.autoFillListingPrice(offers: usedOffers(landed: 1000), condition: .usedGood,
                                          shippingIncome: 350, subtractShipping: true),
       650, "トグルオンは配送料を引く")

// FBA利用時は呼び出し側が配送料0を渡す。引かれてはいけない。
expect(ListingModels.autoFillListingPrice(offers: usedOffers(landed: 1000), condition: .usedGood,
                                          shippingIncome: 0, subtractShipping: true),
       1000, "配送料0(FBA)は引かれない")

expect(ListingModels.autoFillListingPrice(offers: usedOffers(landed: 200), condition: .usedGood,
                                          shippingIncome: 350, subtractShipping: true),
       1, "配送料が最安値を上回れば1円")

// ちょうど同額。0円はAmazonへ出品できないため1円になること。
expect(ListingModels.autoFillListingPrice(offers: usedOffers(landed: 350), condition: .usedGood,
                                          shippingIncome: 350, subtractShipping: true),
       1, "同額でも0ではなく1円")

expect(ListingModels.autoFillListingPrice(offers: emptyOffers, condition: .usedGood,
                                          shippingIncome: 350, subtractShipping: true),
       nil, "オファー無しはnil(従来どおり空欄)")

expect(ListingModels.autoFillListingPrice(
        offers: OffersResult(source: "spapi", referencePrice: nil, newCount: nil, usedCount: nil,
                             releaseDate: nil,
                             new: [Offer(condition: "new", price: 2000, shipping: 0, landed: 2000,
                                         isBuyBox: nil, isAmazon: nil, sameCount: nil)],
                             used: nil),
        condition: .newNew, shippingIncome: 350, subtractShipping: true),
       1650, "新品バケットでも同じルール")

if failures > 0 {
    print("\(failures) 件失敗")
    exit(1)
}
print("全て成功")
```

- [ ] **Step 2: 検証が失敗する(コンパイルできない)ことを確認する**

Run:

```bash
cd "/private/tmp/claude-501/-Users-yuyads-Claude-Projects-----------1-/59dd209b-744e-4ddf-b592-9c36f36ce57d/scratchpad/listing-price-check" && swiftc -o verify OffersModels.swift ListingModels.swift main.swift 2>&1 | tail -5
```

Expected: `error: type 'ListingModels' has no member 'autoFillListingPrice'` を含むコンパイルエラー。

- [ ] **Step 3: `autoFillListingPrice` を実装する**

Modify `ios/BarcodeSedori/Sources/Models/ListingModels.swift`。`bucketLowestPrice` の閉じ括弧の直後(`enum ListingModels` の中)へ追加する:

```swift

    /// 仕入れフォームの出品価格に自動入力する額。
    ///
    /// 自己発送では購入者が払う総額が「出品価格 + 配送料」になるため、競合の最安値
    /// (landed = 商品代 + 送料)と総額で並ぶには自分の配送料を引いた額を出す必要がある。
    /// この差し引きは設定「配送料を引いた最安値自動入力」がオンのときだけ行う(既定オフ)。
    /// - Parameters:
    ///   - shippingIncome: 差し引く配送料。**FBA利用時は0を渡すこと**(Amazonが配送するため
    ///     出品者に配送料収入が無く、引くと実際より安い価格で出品してしまう)。
    ///   - subtractShipping: 設定トグルのオン/オフ。
    /// - Returns: 最安値が取れなければnil(従来どおり空欄のまま)。
    static func autoFillListingPrice(
        offers: OffersResult?,
        condition: ListingConditionType,
        shippingIncome: Int,
        subtractShipping: Bool
    ) -> Int? {
        guard let lowest = bucketLowestPrice(offers: offers, condition: condition) else { return nil }
        guard subtractShipping, shippingIncome > 0 else { return lowest }
        // 0円・負値はAmazonへ出品できず保存時のバリデーションでも弾かれるため、1円を下限にする。
        return max(1, lowest - shippingIncome)
    }
```

- [ ] **Step 4: 検証が通ることを確認する**

実装した `ListingModels.swift` を作業ディレクトリへコピーし直してからビルド・実行する:

```bash
W="/private/tmp/claude-501/-Users-yuyads-Claude-Projects-----------1-/59dd209b-744e-4ddf-b592-9c36f36ce57d/scratchpad/listing-price-check"
cp "/Users/yuyads/Claude/Projects/バーコードせどり (1)/ios/BarcodeSedori/Sources/Models/ListingModels.swift" "$W/"
cd "$W" && swiftc -o verify OffersModels.swift ListingModels.swift main.swift && ./verify
```

Expected: 7行すべて `OK` で終わり、最後に `全て成功`。終了コード0。

- [ ] **Step 5: コミット**

検証スクリプトはスクラッチ領域にあるためコミット対象に入らない。実ソースのみコミットする。

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Models/ListingModels.swift && git commit -m "iOS: 最安値から配送料を引く出品価格の計算関数を追加する

自己発送では購入者の支払総額が「出品価格+配送料」になるため、競合の最安値(landed)と
総額で並ぶには自分の配送料を引く必要がある。判定(トグル・配送料0・下限クランプ)を
呼び出し箇所へ複製しないよう純粋関数として1箇所に集約した。
この時点ではまだどこからも呼ばれていない(配線は後続コミット)。"
```

---

### Task 2: 設定トグルの追加

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Store/SettingsStore.swift`(キー定義・プロパティ・初期化の3箇所)
- Modify: `ios/BarcodeSedori/Sources/Views/SettingsView.swift`(`listingSection` 内)

**Interfaces:**
- Produces: `SettingsStore.purchaseSubtractShippingFromLowest: Bool`(既定`false`)— Task 3 が参照する

**背景(実装者向け):** `SettingsStore` は「Keys列挙にキー文字列」「`@Published`プロパティ + `didSet`で`defaults.set`」「`init`で`defaults`から読み込み」の3箇所セットで1つの設定を表す。既存の `purchaseUseFbaDefault` が同じ`Bool`型の手本なので、それに完全に倣うこと。

- [ ] **Step 1: `SettingsStore` にキーを追加する**

Modify `ios/BarcodeSedori/Sources/Store/SettingsStore.swift`。`Keys` 列挙内の `static let purchaseUseFbaDefault = "purchase.useFbaDefault"` の**直後の行**に追加:

```swift
        /// 出品価格の自動入力で、最安値から配送料(purchaseShippingIncomeDefault)を引くか。既定OFF。
        static let purchaseSubtractShippingFromLowest = "purchase.subtractShippingFromLowest"
```

- [ ] **Step 2: `SettingsStore` にプロパティを追加する**

同ファイル。`purchaseUseFbaDefault` のプロパティ定義(`@Published var purchaseUseFbaDefault: Bool { didSet { ... } }`)の**閉じ括弧の直後**に追加:

```swift

    /// 出品価格の自動入力で、最安値から配送料を引くか。既定OFF(既存ユーザーの挙動を変えないため)。
    /// 引く額は purchaseShippingIncomeDefault。FBA利用時は配送料収入が無いため引かない
    /// (判定はListingModels.autoFillListingPriceの呼び出し側で配送料0を渡すことで表現する)。
    @Published var purchaseSubtractShippingFromLowest: Bool {
        didSet {
            defaults.set(purchaseSubtractShippingFromLowest, forKey: Keys.purchaseSubtractShippingFromLowest)
        }
    }
```

- [ ] **Step 3: `SettingsStore` の初期化に追加する**

同ファイル。`init` 内の `self.purchaseUseFbaDefault = defaults.bool(forKey: Keys.purchaseUseFbaDefault)` の**直後の行**に追加(`defaults.bool` は未設定時に `false` を返すので、これが既定オフになる):

```swift
        self.purchaseSubtractShippingFromLowest = defaults.bool(forKey: Keys.purchaseSubtractShippingFromLowest)
```

- [ ] **Step 4: 設定画面にトグルを追加する**

Modify `ios/BarcodeSedori/Sources/Views/SettingsView.swift`。`listingSection` 内の `Toggle("FBAを利用", isOn: $settings.purchaseUseFbaDefault)` の**直後の行**に追加:

```swift
                Toggle("配送料を引いた最安値自動入力", isOn: $settings.purchaseSubtractShippingFromLowest)
                Text("出品価格に、最安値から「利益計算用送料」の配送料を引いた額を自動入力します。FBA利用時は配送料を引きません。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
```

- [ ] **Step 5: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Store/SettingsStore.swift ios/BarcodeSedori/Sources/Views/SettingsView.swift && git commit -m "iOS: 設定「配送料を引いた最安値自動入力」トグルを追加する

設定タブ「出品」セクションの「FBAを利用」の下に置く。既定OFFで既存の挙動は変わらない。
この時点ではトグルはまだ何も制御していない(仕入れフォームへの反映は後続コミット)。"
```

---

### Task 3: 仕入れフォームへの反映

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`(`PurchaseFormViewModel` の `condition`/`useFba` の`didSet`・`init`・公開プロパティ、および `PurchaseFormView` の出品内容セクション)

**Interfaces:**
- Consumes: `ListingModels.autoFillListingPrice(offers:condition:shippingIncome:subtractShipping:) -> Int?`(Task 1)/ `SettingsStore.purchaseSubtractShippingFromLowest: Bool`(Task 2)
- Produces: `PurchaseFormViewModel.shippingToSubtract: Int` / `PurchaseFormViewModel.subtractShippingFromLowest: Bool`(同ファイル内のViewが参照する)

**背景(実装者向け):** このファイルには `PurchaseFormViewModel`(ViewModel)と `PurchaseFormView`(View)の両方が入っている。Viewは `viewModel` しか保持しておらず `SettingsStore` を直接参照できないため、表示に必要な値はViewModel経由で公開する。

価格の自動入力は**新規追加(`.add`)モードのときだけ**行う。編集(`.edit`)モードで保存済みの価格を上書きしないという既存の挙動をそのまま維持すること。

- [ ] **Step 1: ViewModelに公開プロパティを追加する**

Modify `ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`。`PurchaseFormViewModel` 内の `var asin: String { ... }` 計算プロパティの**閉じ括弧の直後**に追加する(`init` より前で、`mode`/`settings` が使える位置ならどこでもよい):

```swift

    /// 出品価格から差し引く配送料。FBA利用時は0(Amazonが配送するため出品者に配送料収入が無く、
    /// 引くと実際より安い価格で出品してしまう)。出品価格の下に表示する値もこれを使い、
    /// 計算と表示で値がズレないようにする。
    var shippingToSubtract: Int {
        useFba ? 0 : settings.purchaseShippingIncomeDefault
    }

    /// 設定「配送料を引いた最安値自動入力」がオンか。出品価格の下の配送料行の表示条件に使う。
    /// フォーム表示中に設定は変わらない(設定タブへ行くにはフォームを閉じる必要がある)ため、
    /// スナップショット参照でよい。
    var subtractShippingFromLowest: Bool {
        settings.purchaseSubtractShippingFromLowest
    }
```

- [ ] **Step 2: コンディション変更時の再計算を差し替える**

同ファイル、`@Published var condition: ListingConditionType` の `didSet` 内。

置換前:

```swift
            if case .add(let draft) = mode {
                price = ListingModels.bucketLowestPrice(offers: draft.offersResult, condition: condition)
            }
```

置換後:

```swift
            if case .add(let draft) = mode {
                price = ListingModels.autoFillListingPrice(
                    offers: draft.offersResult,
                    condition: condition,
                    shippingIncome: shippingToSubtract,
                    subtractShipping: subtractShippingFromLowest
                )
            }
```

- [ ] **Step 3: FBA切替時に再計算を追加する**

同ファイル、`@Published var useFba: Bool` の `didSet` 内。

置換前:

```swift
        didSet {
            guard useFba != oldValue else { return }
            shippingIncome = useFba ? 0 : settings.purchaseShippingIncomeDefault
            shippingCost = useFba ? 0 : settings.purchaseShippingCostDefault
            startFeesFetch()
        }
```

置換後:

```swift
        didSet {
            guard useFba != oldValue else { return }
            shippingIncome = useFba ? 0 : settings.purchaseShippingIncomeDefault
            shippingCost = useFba ? 0 : settings.purchaseShippingCostDefault
            // FBAの切替で配送料を引くかどうかが変わるため、出品価格も入れ直す
            // (コンディション変更時に再計算する既存の挙動と揃える)。
            // startFeesFetchより前に置くこと: priceのdidSetが張るデバウンスを
            // 直後のstartFeesFetchがキャンセルするので、新しい価格で1回だけ取得できる。
            if case .add(let draft) = mode {
                price = ListingModels.autoFillListingPrice(
                    offers: draft.offersResult,
                    condition: condition,
                    shippingIncome: shippingToSubtract,
                    subtractShipping: subtractShippingFromLowest
                )
            }
            startFeesFetch()
        }
```

- [ ] **Step 4: 初期化時の自動入力を差し替える**

同ファイル、`init` の `case .add(let draft):` 内。

置換前:

```swift
            self.price = ListingModels.bucketLowestPrice(offers: draft.offersResult, condition: initialCondition)
```

置換後(この時点では `self.useFba` がまだ初期化されておらず `shippingToSubtract` を呼べないため、同じ式をその場に書く。直後の `self.shippingIncome` の初期化と同じ書き方):

```swift
            // shippingToSubtractはself.useFba初期化前のため使えない。同じ判定をここで書く。
            self.price = ListingModels.autoFillListingPrice(
                offers: draft.offersResult,
                condition: initialCondition,
                shippingIncome: settings.purchaseUseFbaDefault ? 0 : settings.purchaseShippingIncomeDefault,
                subtractShipping: settings.purchaseSubtractShippingFromLowest
            )
```

- [ ] **Step 5: 出品価格の下に配送料行を追加する**

同ファイル、`PurchaseFormView` の `Section("出品内容")` 内。出品価格の `HStack { ... }`(`TextField("出品価格", ...)` を含むブロック)の**閉じ括弧の直後**に追加:

```swift

                // 差し引いた配送料を出品価格の直下に示す(なぜその価格になったかを分かるようにする)。
                // 値は設定「利益計算用送料」の配送料で、ここでは変更できない。
                // トグルがオフのときは差し引き自体が起きないため行ごと出さない。
                if viewModel.subtractShippingFromLowest {
                    HStack {
                        Text("配送料")
                        Spacer()
                        Text(Self.currencyText(viewModel.shippingToSubtract))
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
```

- [ ] **Step 6: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

`shippingToSubtract` が見つからないというエラーが出た場合は、Step 1のプロパティを `PurchaseFormViewModel` の中(`PurchaseFormView` の中ではない)に置けているか確認すること。

- [ ] **Step 7: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift && git commit -m "iOS: 出品価格へ「最安値−配送料」を自動入力し、引いた配送料を表示する

新規追加時の3箇所(初期化・コンディション変更・FBA切替)でListingModels.autoFillListingPriceを
使う。差し引く配送料と表示する配送料はshippingToSubtractの1つに揃え、値がズレないようにした。
編集モードでは保存済み価格を上書きしない既存の挙動を維持している。"
```

---

## 実装後の確認事項(全タスク完了後)

- [ ] `git status` がクリーンであること
- [ ] Xcodeビルドが `** BUILD SUCCEEDED **` であること
- [ ] Task 1 の検証スクリプトが7項目すべて `OK` であること
- [ ] スクラッチ領域の検証ファイルがコミットに含まれていないこと(`git log -1 --stat` で確認)
- [ ] サーバーは変更していないため、デプロイは不要

## 手動確認(ユーザー実施。実機/シミュレータ)

設計書§5の項目。実装者は行わなくてよい。

1. トグル既定オフ。既存どおり最安値がそのまま入り、配送料行は出ない
2. 設定「利益計算用送料」の配送料を¥350にしトグルON。最安値¥1000の商品で出品価格が¥650になり、直下に「配送料 ¥350」が出る
3. その状態でフォームのFBAトグルをONにすると、出品価格が¥1000に戻り配送料表示が¥0になる
4. 最安値が配送料より安い商品(例: 最安値¥200・配送料¥350)で出品価格が¥1になる
5. コンディションを切り替えても、そのコンディションの最安値から同じルールで再計算される
6. 仕入れリストの既存項目を開いて編集した場合、保存済みの価格が上書きされない
