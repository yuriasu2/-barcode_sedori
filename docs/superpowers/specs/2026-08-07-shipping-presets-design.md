# 送料設定を名前付きプリセットの複数登録+選択式にする 設計書

作成日: 2026-08-07 / ステータス: 設計承認済み・実装未着手

## 1. 目的

現在の「送料設定」画面は、配送料・発送費用をそれぞれ**単一の金額**でしか持てない。実際にはせどりの発送方法は商品サイズで変わる(ネコポス ¥210 / 宅急便コンパクト ¥450 / ゆうメール ¥180 など)ため、そのつど設定画面で数字を打ち直す必要がある。

配送料・発送費用のそれぞれについて、**名前付きの金額を複数登録し、設定画面でどれを使うか選べる**ようにする。

## 2. 検討して見送った案: Amazonの配送パターンを読み込む

当初「Amazonに登録済みの配送パターンを読み込んで選べないか」という案を検討したが、**採用しない**。

SP-APIのProduct Type Definitions API(`getDefinitionsProductType`)に`sellerId`を渡すと、スキーマの`merchant_shipping_group`属性にセラーが登録した配送パターンが`enum`(キー)/`enumNames`(表示名)として返る。しかし:

- **金額が取得できない。** 配送パターンは「地域別・重量別の料金表」であり、SP-APIが公開するのは識別子と名前だけ。このアプリが必要とするのは出品価格の自動入力(最安値 − 配送料)と粗利益計算に使う**金額**なので、名前だけでは目的を果たせない。
- `enumNames`が人間可読な名前ではなく不透明なID(「Migrated template」やランダム文字列)を返す報告が複数あり、名前の取得自体も信頼性が低い。
- SP-API連携済みのProユーザーしか使えず、商品ごとの`productType`が必要で追加のAPI呼び出しも発生する。

参考: [Tutorial: Retrieve Merchant Shipping Templates](https://developer-docs.amazon.com/sp-api/docs/tutorial-retrieve-merchant-shipping-templates) / [issue #3276](https://github.com/amzn/selling-partner-api-docs/issues/3276) / [issue #1522](https://github.com/amzn/selling-partner-api-models/issues/1522)

Amazon側の配送パターンと同じ名前を手動で付けておけば実質的に対応は取れるため、手動登録方式で十分と判断した。

## 3. 決定事項

| 論点 | 決定 | 理由 |
|---|---|---|
| 登録方法 | 手動。名前と金額をセットで登録する | 上記§2のとおりAmazonからは金額が取れない |
| 選択する場所 | **設定画面(送料設定)** | 仕入れフォームにPickerを増やさない。選んだものが全商品の初期値になる |
| 対象 | **配送料と発送費用の両方** | 発送方法が変われば自分が払うコストも変わるため、同じ扱いにする |
| 名前の編集 | できない(削除して追加し直す) | 選択のタップと編集のタップが衝突する画面設計を避ける |
| 金額の編集 | **その場でできる** | 運送会社の値上げに1タップで追随できる。既存の金額入力欄と同じ作法で実装できる |
| 既存の単一値 | プリセット1件(名前「デフォルト」)として取り込み、選択状態にする | 既存ユーザーの設定を失わない |
| 選択中を削除したとき | 未選択(0円)に戻す | 別のものを勝手に選ぶより、選び直しを促すほうが誤った金額で出品する事故が起きにくい |
| 未選択の状態で追加したとき | 追加したものを自動で選択する | 1件目を登録しても選択されないと0円のままで、なぜ反映されないのか分かりにくいため。2件目以降(既に選択済み)は選択を横取りしない |
| 名前の重複 | 追加を許可しない | 既存の「仕入先」リストと同じ作法。どれを選んでいるか分からなくなるのを防ぐ |

## 4. 変更点

### 4.1 データモデル(新規ファイル)

`ios/BarcodeSedori/Sources/Models/ShippingPreset.swift`:

```swift
import Foundation

/// 送料設定で登録する名前付きの金額(配送料・発送費用で共用)。
///
/// 名前を後から変えられないのは、行のタップを「選択」に使っているため
/// (名前編集も同じタップに乗せると操作が衝突する)。変えたい場合は削除して追加し直す。
/// 金額だけは運送会社の値上げに追随できるよう、その場で編集できる。
struct ShippingPreset: Codable, Equatable, Identifiable {
    /// 選択状態(SettingsStoreのselectedId)が指す先。名前を識別子にすると
    /// 同名を許した瞬間に選択が壊れるため、独立したIDを持たせる。
    let id: UUID
    let name: String
    var amount: Int
}
```

Xcodeプロジェクトは XcodeGen 生成で`Sources/`配下を自動で取り込むため、ファイル追加に伴うプロジェクト登録作業は不要。

### 4.2 `SettingsStore`

配送料・発送費用それぞれに「プリセット一覧」と「選択中ID」を追加し、**既存の2プロパティを computed に置き換える**。

```swift
@Published var purchaseShippingIncomePresets: [ShippingPreset]   // 永続化あり
@Published var purchaseShippingIncomeSelectedId: UUID?           // 永続化あり
@Published var purchaseShippingCostPresets: [ShippingPreset]     // 永続化あり
@Published var purchaseShippingCostSelectedId: UUID?             // 永続化あり

/// 選択中の配送料(円)。未選択・選択中が削除済みなら0。
/// 呼び出し側(PurchaseFormView)の契約を変えないため、プリセット化後も名前と型を保つ。
var purchaseShippingIncomeDefault: Int {
    Self.selectedAmount(in: purchaseShippingIncomePresets, id: purchaseShippingIncomeSelectedId)
}

/// 選択中の発送費用(円)。未選択・選択中が削除済みなら0。
var purchaseShippingCostDefault: Int {
    Self.selectedAmount(in: purchaseShippingCostPresets, id: purchaseShippingCostSelectedId)
}

/// 選択中プリセットの金額を解決する。配送料・発送費用で同じ規則を使うため共通化する。
/// IDが無い(未選択)・IDに対応するプリセットが無い(削除済み)ときは0を返す。
private static func selectedAmount(in presets: [ShippingPreset], id: UUID?) -> Int {
    guard let id, let preset = presets.first(where: { $0.id == id }) else { return 0 }
    return preset.amount
}
```

**computed にする理由(この設計の要):** `purchaseShippingIncomeDefault` / `purchaseShippingCostDefault` を書き込んでいるのは送料設定画面の入力欄だけで(今回それを置き換える)、残りはすべて読み出し。名前と型を保ったまま中身を差し替えれば、`PurchaseFormView`の5箇所の読み出しは**一切変更不要**になり、プリセット化の影響を設定画面の中に閉じ込められる。

`@Published`ではない computed プロパティだが、依存元の`presets`/`selectedId`が`@Published`なので、変更時に`objectWillChange`が発火して画面は正しく再描画される。

永続化は`listingSkuFormat`と同じ`JSONEncoder`→`defaults.set(data:forKey:)`方式。`selectedId`は`uuidString`で保存する。

**移行(`init`内):** 既存キー`purchase.shippingIncomeDefault` / `purchase.shippingDefault`に0以外の値が入っていて、かつプリセット一覧が空の場合のみ、`ShippingPreset(id: UUID(), name: "デフォルト", amount: 旧値)`を1件作って選択状態にする。旧値が0または未設定なら空リスト・未選択のままで、実効値0円という従来の挙動と一致する。移行後は旧キーを削除する(次回起動で二重に取り込まないため)。

### 4.3 送料設定画面(`ShippingSettingsView.swift`)

現在の2つの金額入力欄を、同じ構造の2セクションに置き換える。

**各セクション(「配送料」「発送費用」)の構成:**

- 登録済みプリセットの一覧。1行 = チェックマーク(選択中のみ) + 名前 + 金額入力欄 + 「円」
  - 名前部分のタップで選択(チェックマークが移動する)
  - 金額入力欄のタップで金額を編集(`keyboardType(.numberPad)`、既存の入力欄と同じ作法)
  - スワイプで削除(`onDelete`)。選択中を削除したら`selectedId`を`nil`に戻す
- 一覧の末尾に追加行: 「名前」テキスト欄 + 「金額」数値欄 + 追加ボタン
  - 名前が空・前後空白のみ、金額が未入力、名前が既存と重複するときは追加ボタンを無効化(既存`PurchaseSettingsView.canAddSupplier`と同じ判定)
- セクション下の補足文は現行のものを流用: 配送料「購入者が支払い、自分に入金される額です。」/ 発送費用「自分が支払う発送コストです。」

キーボードツールバーの「完了」は現行どおり維持する(numberPadにReturnキーが無いため)。フォーカス対象(`Field`)は行ごとに一意である必要があるため、`case incomeAmount(UUID)` / `case costAmount(UUID)` / `case incomeNewName` などプリセットIDを含む形に拡張する。

**金額をその場で編集する方法:** `ForEach`に配列そのものではなく**バインディングを渡す**(`ForEach($settings.purchaseShippingIncomePresets) { $preset in ... }`)。要素のコピーを受け取る通常の`ForEach`では`preset.amount`を書き換えても配列へ反映されない。バインディング経由なら配列全体が書き戻されるので`@Published`の`didSet`が走り、永続化も画面更新も自動で行われる。デプロイメントターゲットはiOS 16.0なのでこの形式を使える。

## 5. 変更しない範囲

- `PurchaseFormView`(利益セクションの編集可能な配送料/発送費用、粗利益の計算式、出品価格の自動入力ロジック、出品価格下の配送料表示行)
- `PurchaseListItem`の保存構造(`shippingIncome` / `shippingCost`は引き続き商品ごとの`Int?`)。既に保存済みの仕入れ項目の金額は変わらない
- サーバー側(変更なし。デプロイ不要)

## 6. 検証

iOSにテストターゲットが無いため、ビルド成功と手動確認で検証する。

**ビルド**

```bash
xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

**手動確認項目**

1. 移行: アップデート前に配送料¥350を設定していた場合、送料設定を開くと「デフォルト ¥350」が1件あり選択済みになっている。仕入れフォームの配送料も従来どおり¥350で入る
2. 配送料に「ネコポス ¥210」「宅急便コンパクト ¥450」を追加し、ネコポスを選択。仕入れフォームを新規で開くと利益セクションの配送料が¥210、出品価格下の配送料表示も¥210になる
3. 宅急便コンパクトに選択を切り替えると、次に開いた仕入れフォームが¥450になる
4. 登録済みの金額を¥210→¥230に直すと、次に開いた仕入れフォームに¥230が入る
5. 選択中のプリセットを削除すると未選択になり、仕入れフォームの配送料が¥0で入る
6. 発送費用でも1〜5と同じ操作ができる
7. 名前が空・金額が空・既存と同じ名前のときは追加ボタンが押せない
7b. 未選択(または1件も無い状態)でプリセットを追加すると、そのプリセットが自動で選択される。既に選択済みなら追加しても選択は移らない
8. 既に仕入れリストに保存済みの項目を開いても、保存時の配送料・発送費用が変わっていない
