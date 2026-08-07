# 出品価格の自動入力を「最安値 − 配送料」にする 設計書

作成日: 2026-08-07 / ステータス: 設計承認済み・実装未着手

## 1. 目的

仕入れフォーム(`PurchaseFormView`)の出品価格は、現在そのコンディションの最安値がそのまま自動入力される。しかし自己発送(MFN)では購入者が支払う総額は「出品価格 + 配送料」であり、競合の最安値(`landed` = 商品代 + 送料)と総額で並ぶには、最安値から自分の配送料を引いた額を出品価格にする必要がある。

この「最安値 − 配送料」の自動入力を、既定オフの設定として追加する。あわせて、いくら引かれたのかが分かるよう出品価格の直下に配送料を表示する。

## 2. 決定事項

| 論点 | 決定 | 理由 |
|---|---|---|
| 差し引きに使う配送料 | 設定「利益計算用送料」の**配送料デフォルト**(`purchaseShippingIncomeDefault`) | 商品ごとにブレない基準値を使う。表示も同じ値で変更不可にする |
| 利益セクションの既存「配送料」(編集可) | **変更しない** | 粗利益の微調整用として引き続き必要。ここを編集しても出品価格は再計算しない |
| 設定トグルの置き場所 | 設定タブ「出品」セクション、「FBAを利用」の直下 | 1タップで到達でき、同じ出品まわりの挙動設定として並ぶ |
| トグルの既定値 | **オフ** | 既存ユーザーの挙動を変えない |
| FBA利用時 | **差し引かない**(配送料0として扱う) | FBAはAmazonが配送し出品者に配送料収入が無い。引くと意図しない安売りになる |
| 差し引き結果が0以下 | **¥1を下限**にクランプ | 0円・負値はAmazonへ出品できず、保存時のバリデーションでも弾かれるため、フォーム上で破綻させない |
| フォームでFBAトグルを切替えたとき | **設定がオンのときだけ**出品価格を再計算する。算出できた(非nil)ときだけ入れ直す | 切替で配送料の扱いが変わるため。ただしこれは本機能の一部なので、設定がオフのときは何もしない(オフの挙動を変更前と完全に同じに保つ)。またFBA切替では`offers`/`condition`が変わらないため、nilは新しい情報ではなく手入力価格の消失にしかならない |
| 編集モード(`.edit`) | **自動入力しない** | 保存済みの価格を上書きしない現在の挙動を維持する |

## 3. 変更点

### 3.1 `SettingsStore`(`ios/BarcodeSedori/Sources/Store/SettingsStore.swift`)

`purchaseUseFbaDefault` と同じ作法で追加する。

- キー: `Keys.purchaseSubtractShippingFromLowest = "purchase.subtractShippingFromLowest"`
- プロパティ: `@Published var purchaseSubtractShippingFromLowest: Bool`(`didSet`で`defaults.set`)
- 初期化: `defaults.bool(forKey:)`(未設定は`false` = 既定オフ)

### 3.2 計算ロジック(`ios/BarcodeSedori/Sources/Models/ListingModels.swift`)

`bucketLowestPrice` の直下に純粋関数を追加する。判定が3つ(トグル・配送料の有無・下限クランプ)に増えるため、呼び出し箇所(3箇所)へ複製せず1箇所に集約する。

```swift
/// 仕入れフォームの出品価格に自動入力する額を返す。
/// - Parameters:
///   - shippingIncome: 差し引く配送料。FBA利用時は0を渡すこと(Amazonが配送するため
///     出品者に配送料収入が無く、引くと実際より安い価格で出品してしまう)。
///   - subtractShipping: 設定「配送料を引いた最安値自動入力」のオン/オフ。
/// - Returns: 最安値が取れなければnil(従来どおり空欄)。
static func autoFillListingPrice(
    offers: OffersResult?,
    condition: ListingConditionType,
    shippingIncome: Int,
    subtractShipping: Bool
) -> Int? {
    guard let lowest = bucketLowestPrice(offers: offers, condition: condition) else { return nil }
    guard subtractShipping, shippingIncome > 0 else { return lowest }
    // 0円・負値はAmazonへ出品できないため1円を下限にする。
    return max(1, lowest - shippingIncome)
}
```

判定表:

| トグル | FBA | 配送料設定 | 最安値 | 自動入力される値 |
|---|---|---|---|---|
| オフ | — | ¥350 | ¥1000 | ¥1000(従来どおり) |
| オン | OFF | ¥350 | ¥1000 | ¥650 |
| オン | **ON** | ¥350 | ¥1000 | ¥1000(引かない) |
| オン | OFF | ¥0 | ¥1000 | ¥1000 |
| オン | OFF | ¥350 | ¥200 | **¥1**(クランプ) |
| — | — | — | 取得不可 | 空欄(`nil`) |

### 3.3 呼び出し側(`PurchaseFormViewModel`)

まず、差し引く配送料と表示条件を`PurchaseFormViewModel`に公開プロパティとして持たせる。`PurchaseFormView`(View)は`viewModel`しか保持しておらず`SettingsStore`を直接参照できないため、表示行(3.4)もここを経由する。

```swift
/// 出品価格から差し引く配送料。FBA利用時は0(Amazonが配送するため出品者に配送料収入が無い)。
/// 出品価格の下に表示する値もこれを使う。
var shippingToSubtract: Int { useFba ? 0 : settings.purchaseShippingIncomeDefault }

/// 設定「配送料を引いた最安値自動入力」がオンか。出品価格の下の配送料行の表示条件に使う。
var subtractShippingFromLowest: Bool { settings.purchaseSubtractShippingFromLowest }
```

`useFba`は`@Published`のため、FBAトグルを切り替えると`shippingToSubtract`が再評価されて表示にも反映される。`settings`はフォーム表示中に変わらない(設定タブへ行くにはフォームを閉じる必要がある)ため、スナップショット参照で問題ない。

以下、渡す配送料は共通して`shippingToSubtract`。既存の`shippingIncome`初期化と同じ考え方。

**(a) `init` の `.add` ケース**

現状の `self.price = ListingModels.bucketLowestPrice(...)` を置き換える。この時点では `self.useFba` がまだ初期化されておらず `shippingToSubtract` を呼べないため、FBA判定には `settings.purchaseUseFbaDefault` を直接使い、同じ式をその場に書く(直後の `self.shippingIncome` / `self.shippingCost` の初期化と同じ書き方)。

**(b) `condition` の `didSet`(`.add` のときのみ)**

現状の `price = ListingModels.bucketLowestPrice(...)` を置き換える。配送料は `shippingToSubtract` を使う。

**(c) `useFba` の `didSet`(新規。**設定がオン** かつ `.add` のときのみ)**

`shippingIncome` / `shippingCost` を更新した後、**`startFeesFetch()` を呼ぶ前**に `price` を再計算する。

設定のゲートが必須な理由: この再計算は本機能の一部なので、設定がオフのときは何もしてはいけない。変更前の `useFba.didSet` には価格代入が一切無かったため、ゲートを忘れると「機能をオフにしている既存ユーザーがFBAトグルを触ると、手入力した出品価格が最安値へ戻る」という挙動変更になる。

nilガードが必須な理由: FBA切替では `offers` も `condition` も変わらないため、`autoFillListingPrice` が `nil`(オファー無し)を返す場合、それは新しい情報ではなく単に手入力価格を消すだけになる。算出できたときだけ代入する。

順序が重要な理由: `price` の `didSet` は `scheduleFeesFetch()`(0.5秒デバウンス)を発火させるが、直後の `startFeesFetch()` が `feesDebounceTask` をキャンセルして即時取得するため、新しい価格で1回だけ手数料を取得できる。逆順にすると、即時取得が古い価格で走ったうえにデバウンス分がもう一度走る。

### 3.4 表示(`ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift`)

**2026-08-07改訂**: 当初は「新規追加モード かつ 設定オン」のときだけ表示していたが、自動入力のオン/オフ・新規/編集を問わず常に表示する方針に変更した(ユーザー指示)。

「出品内容」セクションの出品価格行の**直下**に、読み取り専用の配送料行を追加する。

- 表示条件: 常時表示(条件なし)。新規追加・編集のどちらでも、自動入力設定のオン/オフに関わらず出す
- 表示値: `Self.currencyText(viewModel.shippingToDisplay)`。モードで出し分ける(**2026-08-07再改訂**)
  - **新規追加時**: `shippingToSubtract`(設定「送料設定」で選択中の配送料。FBA利用時は自動的に`¥0`)。実際に差し引いた額なので、価格の根拠として正しい
  - **編集時**: その商品に保存されている`shippingIncome`。編集では差し引きが起きておらず、設定側で別のプリセットへ切り替えた後に開くと「出品価格¥790 / 配送料¥450」のように辻褄の合わない数字が並んでしまうため(¥790は¥210を引いて決めた価格)。当初は編集時も設定由来にしていたが、送料プリセット導入で切り替えが日常操作になり食い違いが常態化したため改めた
- ラベル: 「配送料」
- スタイル: `.font(.footnote)` / `.foregroundColor(.secondary)`。入力欄ではなく `Text` のみ(変更不可)

### 3.5 設定画面(`ios/BarcodeSedori/Sources/Views/SettingsView.swift`)

`listingSection` の Pro 分岐内、`Toggle("FBAを利用", isOn: $settings.purchaseUseFbaDefault)` の直下に追加する。設定名は当初「利益計算用送料」としていたが、2026-08-07に「**送料設定**」へ改名した(`ShippingSettingsView`のnavigationTitleも同時に変更)。

```swift
Toggle("配送料を引いた最安値自動入力", isOn: $settings.purchaseSubtractShippingFromLowest)
Text("出品価格に、最安値から「送料設定」の配送料を引いた額を自動入力します。FBA利用時は配送料を引きません。")
    .font(.footnote)
    .foregroundColor(.secondary)
```

## 4. 対象外(この変更では触らない)

- 利益セクションの「配送料」入力欄(編集可のまま。粗利益の計算式も変更しない)
- 編集モード(`.edit`)の価格自動入力(引き続き行わない)
- 一括出品(`BulkListingViewModel`)の価格決定
- サーバー側(変更なし。デプロイ不要)

## 5. 検証

iOSにテストターゲットが無いため、ビルド成功と手動確認で検証する。

**ビルド**

```bash
xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

**手動確認項目**

1. トグル既定オフ。既存どおり最安値がそのまま入る。配送料行は(オフでも)出て、設定の配送料デフォルトが表示される
2. 設定「送料設定」の配送料を¥350にし、トグルON。最安値¥1000の商品で出品価格が¥650になり、直下に「配送料 ¥350」が出る
3. その状態でフォームのFBAトグルをONにすると、出品価格が¥1000に戻り、配送料表示が¥0になる
4. 最安値が配送料より安い商品(例: 最安値¥200・配送料¥350)で出品価格が¥1になる
5. コンディションを切り替えても、そのコンディションの最安値から同じルールで再計算される
6. 仕入れリストの既存項目を開いて編集した場合、保存済みの価格が上書きされない。配送料行は編集モードでも表示され、**その商品に保存されている配送料**が出る(設定で別のプリセットへ切り替えた後でも、保存時の値のまま変わらない)
7. **設定オフのまま**、出品価格を手入力してからFBAトグルを切り替え、入力した価格が保持されることを確認する(オフの利用者の挙動が変わっていないことの確認)
8. 設定オンでオファーが取得できない商品(価格欄が空)に価格を手入力し、FBAトグルを切り替えても入力値が消えないことを確認する
