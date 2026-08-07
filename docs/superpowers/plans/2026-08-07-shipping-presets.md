# 送料設定を名前付きプリセットの複数登録+選択式にする 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 配送料・発送費用のそれぞれについて、名前付きの金額を複数登録し、設定画面でどれを使うかを選べるようにする。

**Architecture:** `SettingsStore`に「プリセット一覧」と「選択中ID」を持たせ、既存の`purchaseShippingIncomeDefault` / `purchaseShippingCostDefault`を**選択中の金額を返す computed プロパティへ置き換える**。この2つを書き込んでいるのは送料設定画面の入力欄だけ(残りはすべて読み出し)なので、名前と型を保ったまま中身を差し替えれば`PurchaseFormView`は一切変更不要になり、プリセット化の影響が設定画面の中に閉じ込められる。

**Tech Stack:** SwiftUI / UserDefaults(JSONエンコードで配列を永続化)/ Xcodeビルドによる検証

**設計書:** `docs/superpowers/specs/2026-08-07-shipping-presets-design.md`

## Global Constraints

- このプロジェクトは `main` へ直接コミットする(確立された規約)。ブランチを切らない。
- コメントは既存コードと同じ密度・文体(日本語、「なぜそうしたか」を書く)で揃える。
- iOSにテストターゲットは無い。**テストターゲットを新設しない。** 検証はXcodeビルドと手動確認で行う。
- シミュレータ起動での目視確認は不要(ビルド成功まででよい)。
- サーバー側は変更しない。デプロイ不要。
- Xcodeプロジェクトファイルは XcodeGen 生成でgit非追跡。`Sources/`配下は自動で取り込まれるため、新規ファイルの手動登録は不要。
- **`PurchaseFormView.swift` を変更しない。** 変更が必要になったら設計の前提(読み出し側は無変更で動く)が崩れているので、実装を止めて報告すること。
- デプロイメントターゲットは iOS 16.0。
- ビルド確認コマンド:
  ```bash
  cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
  ```

---

### Task 1: 送料プリセットの導入(モデル・ストア・設定画面)

**Files:**
- Create: `ios/BarcodeSedori/Sources/Models/ShippingPreset.swift`
- Modify: `ios/BarcodeSedori/Sources/Store/SettingsStore.swift`(Keys・プロパティ・移行ヘルパー・init)
- Modify: `ios/BarcodeSedori/Sources/Views/ShippingSettingsView.swift`(全面的に書き換える)

**Interfaces:**
- Produces（このプラン内で完結。後続タスクは無い）:
  - `ShippingPreset`(`id: UUID` / `name: String` / `amount: Int`、`Codable, Equatable, Identifiable`)
  - `SettingsStore` の4つの新プロパティと、computed へ置き換えた `purchaseShippingIncomeDefault` / `purchaseShippingCostDefault`

**背景(実装者向け):** `purchaseShippingIncomeDefault` / `purchaseShippingCostDefault` は現在`@Published var Int`。書き込んでいるのは`ShippingSettingsView`の金額入力欄2箇所だけで、それ以外の参照(`PurchaseFormView`の5箇所)はすべて読み出し。だから computed に変えても読み出し側は無変更で動く。

**1タスクにまとめている理由:** ストアだけを先に変えると`ShippingSettingsView`が旧プロパティへのバインディングを使ったままになりビルドが通らない。中途半端に壊れたコミットを`main`へ残さないよう、モデル・ストア・画面をまとめて1コミットにする。

`@Published`でない computed プロパティになるが、依存元の`presets` / `selectedId`が`@Published`なので、変更時に`objectWillChange`が発火して画面は正しく再描画される。

- [ ] **Step 1: `ShippingPreset.swift` を作成する**

Create `ios/BarcodeSedori/Sources/Models/ShippingPreset.swift`:

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

- [ ] **Step 2: `SettingsStore` にキーを追加し、旧キーのコメントを直す**

Modify `ios/BarcodeSedori/Sources/Store/SettingsStore.swift`。

置換前(`Keys` 列挙内):

```swift
        /// 発送費用(自分が払う発送コスト)のデフォルト。キー名は導入時の「配送料」のまま流用する
        /// (意味は元々こちら)。
        static let purchaseShippingCostDefault = "purchase.shippingDefault"
        /// 配送料(購入者が支払い自分に入金される額)のデフォルト。
        static let purchaseShippingIncomeDefault = "purchase.shippingIncomeDefault"
```

置換後:

```swift
        /// 【旧】発送費用の単一値。プリセット化前のバージョンが書いた値で、初回起動時の移行にのみ読む
        /// (移行後は削除する)。キー名は導入時の「配送料」のまま流用していた。
        static let purchaseShippingCostDefault = "purchase.shippingDefault"
        /// 【旧】配送料の単一値。プリセット化前のバージョンが書いた値で、初回起動時の移行にのみ読む
        /// (移行後は削除する)。
        static let purchaseShippingIncomeDefault = "purchase.shippingIncomeDefault"
        /// 配送料の名前付きプリセット一覧。JSONエンコードして保存する。
        static let purchaseShippingIncomePresets = "purchase.shippingIncomePresets"
        /// 選択中の配送料プリセットのID(uuidString)。未選択なら削除する。
        static let purchaseShippingIncomeSelectedId = "purchase.shippingIncomeSelectedId"
        /// 発送費用の名前付きプリセット一覧。JSONエンコードして保存する。
        static let purchaseShippingCostPresets = "purchase.shippingCostPresets"
        /// 選択中の発送費用プリセットのID(uuidString)。未選択なら削除する。
        static let purchaseShippingCostSelectedId = "purchase.shippingCostSelectedId"
```

- [ ] **Step 3: 既存の2プロパティをプリセット+computed へ置き換える**

同ファイル。置換前:

```swift
    /// 仕入れフォームの発送費用(円。自分が払う発送コスト)の初期値。既定0円。
    @Published var purchaseShippingCostDefault: Int {
        didSet {
            defaults.set(purchaseShippingCostDefault, forKey: Keys.purchaseShippingCostDefault)
        }
    }

    /// 仕入れフォームの配送料(円。購入者が支払い自分に入金される額)の初期値。既定0円。
    @Published var purchaseShippingIncomeDefault: Int {
        didSet {
            defaults.set(purchaseShippingIncomeDefault, forKey: Keys.purchaseShippingIncomeDefault)
        }
    }
```

置換後:

```swift
    /// 配送料(購入者が支払い自分に入金される額)の名前付きプリセット一覧(追加順)。
    @Published var purchaseShippingIncomePresets: [ShippingPreset] {
        didSet {
            guard let data = try? JSONEncoder().encode(purchaseShippingIncomePresets) else { return }
            defaults.set(data, forKey: Keys.purchaseShippingIncomePresets)
        }
    }

    /// 選択中の配送料プリセットのID。未選択(または選択中を削除した直後)はnil。
    @Published var purchaseShippingIncomeSelectedId: UUID? {
        didSet {
            if let purchaseShippingIncomeSelectedId {
                defaults.set(purchaseShippingIncomeSelectedId.uuidString, forKey: Keys.purchaseShippingIncomeSelectedId)
            } else {
                defaults.removeObject(forKey: Keys.purchaseShippingIncomeSelectedId)
            }
        }
    }

    /// 発送費用(自分が払う発送コスト)の名前付きプリセット一覧(追加順)。
    @Published var purchaseShippingCostPresets: [ShippingPreset] {
        didSet {
            guard let data = try? JSONEncoder().encode(purchaseShippingCostPresets) else { return }
            defaults.set(data, forKey: Keys.purchaseShippingCostPresets)
        }
    }

    /// 選択中の発送費用プリセットのID。未選択(または選択中を削除した直後)はnil。
    @Published var purchaseShippingCostSelectedId: UUID? {
        didSet {
            if let purchaseShippingCostSelectedId {
                defaults.set(purchaseShippingCostSelectedId.uuidString, forKey: Keys.purchaseShippingCostSelectedId)
            } else {
                defaults.removeObject(forKey: Keys.purchaseShippingCostSelectedId)
            }
        }
    }

    /// 仕入れフォームの配送料(円)の初期値。選択中プリセットの金額。未選択なら0円。
    /// 呼び出し側(PurchaseFormView)の契約を変えないため、プリセット化後も名前と型を保っている。
    var purchaseShippingIncomeDefault: Int {
        Self.selectedAmount(in: purchaseShippingIncomePresets, id: purchaseShippingIncomeSelectedId)
    }

    /// 仕入れフォームの発送費用(円)の初期値。選択中プリセットの金額。未選択なら0円。
    var purchaseShippingCostDefault: Int {
        Self.selectedAmount(in: purchaseShippingCostPresets, id: purchaseShippingCostSelectedId)
    }

    /// 選択中プリセットの金額を解決する。配送料・発送費用で同じ規則のため共通化する。
    /// 未選択(IDがnil)・選択中が削除済み(IDに対応するプリセットが無い)ときは0を返す。
    private static func selectedAmount(in presets: [ShippingPreset], id: UUID?) -> Int {
        guard let id, let preset = presets.first(where: { $0.id == id }) else { return 0 }
        return preset.amount
    }

    /// 送料プリセットを読み込む。プリセットがまだ無く、旧バージョンの単一値が残っていれば、
    /// そのときだけプリセット1件へ移行して選択状態にする(既存ユーザーの設定を失わないため)。
    ///
    /// init内から呼ぶためstatic。init内でのプロパティ代入はdidSetを発火させないので、
    /// 移行結果の永続化はこの中で明示的に行う。
    /// - Returns: (プリセット一覧, 選択中ID)
    private static func loadShippingPresets(
        defaults: UserDefaults,
        presetsKey: String,
        selectedIdKey: String,
        legacyAmountKey: String
    ) -> ([ShippingPreset], UUID?) {
        var presets: [ShippingPreset] = []
        if let data = defaults.data(forKey: presetsKey),
           let decoded = try? JSONDecoder().decode([ShippingPreset].self, from: data) {
            presets = decoded
        }
        let selectedId = defaults.string(forKey: selectedIdKey).flatMap(UUID.init(uuidString:))

        // 既にプリセットがあれば移行済み。旧値が未設定/0円なら移行するものが無い。
        guard presets.isEmpty,
              let legacyAmount = defaults.object(forKey: legacyAmountKey) as? Int,
              legacyAmount > 0 else {
            return (presets, selectedId)
        }

        let migrated = ShippingPreset(id: UUID(), name: "デフォルト", amount: legacyAmount)
        guard let data = try? JSONEncoder().encode([migrated]) else {
            return (presets, selectedId)
        }
        defaults.set(data, forKey: presetsKey)
        defaults.set(migrated.id.uuidString, forKey: selectedIdKey)
        // 次回起動で二重に取り込まないよう旧キーを消す。
        defaults.removeObject(forKey: legacyAmountKey)
        return ([migrated], migrated.id)
    }
```

- [ ] **Step 4: `init` の読み込みを差し替える**

同ファイル、`init` 内。置換前:

```swift
        self.purchaseShippingCostDefault = (defaults.object(forKey: Keys.purchaseShippingCostDefault) as? Int) ?? 0
        self.purchaseShippingIncomeDefault = (defaults.object(forKey: Keys.purchaseShippingIncomeDefault) as? Int) ?? 0
```

置換後:

```swift
        // 送料プリセット。旧バージョンの単一値が残っていれば初回だけ1件へ移行する(loadShippingPresets参照)。
        let (costPresets, costSelectedId) = Self.loadShippingPresets(
            defaults: defaults,
            presetsKey: Keys.purchaseShippingCostPresets,
            selectedIdKey: Keys.purchaseShippingCostSelectedId,
            legacyAmountKey: Keys.purchaseShippingCostDefault
        )
        self.purchaseShippingCostPresets = costPresets
        self.purchaseShippingCostSelectedId = costSelectedId

        let (incomePresets, incomeSelectedId) = Self.loadShippingPresets(
            defaults: defaults,
            presetsKey: Keys.purchaseShippingIncomePresets,
            selectedIdKey: Keys.purchaseShippingIncomeSelectedId,
            legacyAmountKey: Keys.purchaseShippingIncomeDefault
        )
        self.purchaseShippingIncomePresets = incomePresets
        self.purchaseShippingIncomeSelectedId = incomeSelectedId
```

- [ ] **Step 5: `ShippingSettingsView.swift` を全面的に書き換える**

Replace the entire contents of `ios/BarcodeSedori/Sources/Views/ShippingSettingsView.swift` with:

```swift
import SwiftUI

/// 送料設定画面のキーボードフォーカス対象。
/// 金額欄は行ごとに一意である必要があるためプリセットIDを持つ。追加行は2セクションで
/// 区別する必要があるためセクション識別子("income"/"cost")を持つ。
private enum ShippingSettingsField: Hashable {
    case amount(UUID)
    case newName(section: String)
    case newAmount(section: String)
}

/// 「送料設定」画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// 配送料・発送費用それぞれについて名前付きの金額を複数登録し、どれを使うかを選ぶ。
/// 選んだ金額が仕入れフォーム(PurchaseFormView)の初期値になる。
/// どちらもAmazonへは送らず、粗利益の計算にのみ使う。
struct ShippingSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// キーボードツールバーの「完了」でnilにしてフォーカスを外す
    /// (numberPadにはReturnキーが無いため。PurchaseFormViewと同方式)。
    @FocusState private var focusedField: ShippingSettingsField?

    var body: some View {
        Form {
            ShippingPresetSection(
                title: "配送料",
                footnote: "購入者が支払い、自分に入金される額です。",
                section: "income",
                presets: $settings.purchaseShippingIncomePresets,
                selectedId: $settings.purchaseShippingIncomeSelectedId,
                focusedField: $focusedField
            )

            ShippingPresetSection(
                title: "発送費用",
                footnote: "自分が支払う発送コストです。",
                section: "cost",
                presets: $settings.purchaseShippingCostPresets,
                selectedId: $settings.purchaseShippingCostSelectedId,
                focusedField: $focusedField
            )
        }
        .navigationTitle("送料設定")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
    }
}

/// 配送料・発送費用で共通のセクション。構造が完全に同じなので1つにまとめて2回使う。
private struct ShippingPresetSection: View {
    let title: String
    let footnote: String
    /// 追加行のフォーカスを2セクションで区別するための識別子("income"/"cost")。
    let section: String
    @Binding var presets: [ShippingPreset]
    @Binding var selectedId: UUID?
    @FocusState.Binding var focusedField: ShippingSettingsField?

    /// 追加行の入力中の値。追加が確定したらクリアする。
    @State private var newName = ""
    @State private var newAmount: Int?

    var body: some View {
        Section(title) {
            // 配列そのものではなくバインディングをForEachへ渡す。要素のコピーを受け取る
            // 通常のForEachでは金額を書き換えても配列へ反映されず、永続化も走らない。
            ForEach($presets) { $preset in
                HStack {
                    Image(systemName: selectedId == preset.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedId == preset.id ? .accentColor : .secondary)

                    Text(preset.name)

                    Spacer()

                    TextField("金額", value: $preset.amount, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focusedField, equals: .amount(preset.id))

                    Text("円")
                        .foregroundColor(.secondary)
                }
                // 金額欄以外をタップしたら選択を切り替える(金額欄のタップは編集に使う)。
                .contentShape(Rectangle())
                .onTapGesture { selectedId = preset.id }
            }
            .onDelete(perform: delete)

            HStack {
                TextField("名前", text: $newName)
                    .focused($focusedField, equals: .newName(section: section))

                TextField("金額", value: $newAmount, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($focusedField, equals: .newAmount(section: section))

                Button {
                    add()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(!canAdd)
            }

            Text(footnote)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    /// 名前が空・前後空白のみ・金額未入力・既存と同名のときは追加させない
    /// (同名を許すとどれを選んでいるか分からなくなるため。仕入先リストと同じ作法)。
    private var canAdd: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, newAmount != nil else { return false }
        return !presets.contains { $0.name == trimmed }
    }

    private func add() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let amount = newAmount,
              !presets.contains(where: { $0.name == trimmed }) else { return }

        let preset = ShippingPreset(id: UUID(), name: trimmed, amount: amount)
        presets.append(preset)
        // 未選択のまま追加すると0円が使われ続けて「登録したのに反映されない」となるため、
        // 1件目(未選択時)は自動で選ぶ。既に選択済みなら選択を横取りしない。
        if selectedId == nil {
            selectedId = preset.id
        }
        newName = ""
        newAmount = nil
        focusedField = nil
    }

    private func delete(at offsets: IndexSet) {
        let removingSelected = offsets.contains { presets[$0].id == selectedId }
        presets.remove(atOffsets: offsets)
        // 選択中を消したら未選択(0円)へ戻す。別のものを勝手に選ぶと、
        // 気づかないまま違う金額で出品する事故になりうるため。
        if removingSelected {
            selectedId = nil
        }
    }
}
```

- [ ] **Step 6: ビルドが通ることを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

つまずきやすい点:
- `@FocusState.Binding` のエラー → サブビュー側の宣言が `@FocusState.Binding var focusedField: ShippingSettingsField?`(`@FocusState` ではない)か、呼び出し側が `focusedField: $focusedField` を渡しているかを確認する。
- `PurchaseFormView.swift` にエラーが出た場合 → 読み出し側が無変更で動くという設計の前提が崩れている。**実装を止めて報告すること。**

- [ ] **Step 7: `PurchaseFormView.swift` を変更していないことを確認する**

Run:

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git status --short ios/BarcodeSedori/Sources/Views/PurchaseFormView.swift; echo "(上が空ならOK)"
```

Expected: 出力が空(このファイルは触っていない)。何か出た場合は設計の前提が崩れているので報告すること。

- [ ] **Step 8: コミット**

```bash
cd "/Users/yuyads/Claude/Projects/バーコードせどり (1)" && git add ios/BarcodeSedori/Sources/Models/ShippingPreset.swift ios/BarcodeSedori/Sources/Store/SettingsStore.swift ios/BarcodeSedori/Sources/Views/ShippingSettingsView.swift && git commit -m "iOS: 送料設定を名前付きプリセットの複数登録+選択式にする

配送料・発送費用それぞれについて、名前と金額をセットで複数登録し、設定画面で
どれを使うかを選べるようにした。行タップで選択、金額はその場で編集、スワイプで削除。
選択中を削除したら未選択(0円)へ戻し、未選択のまま追加したものは自動で選択する。

既存のpurchaseShippingIncomeDefault/purchaseShippingCostDefaultは「選択中プリセットの
金額を返すcomputedプロパティ」へ置き換えた。名前と型を保ったため、読み出し側
(PurchaseFormViewの5箇所)は無変更で動く。旧バージョンの単一値は初回起動時に
プリセット1件(名前「デフォルト」)へ移行するので既存の設定は失われない。

金額の編集はForEachへバインディングを渡すことで実現している(要素のコピーを受け取る
通常のForEachでは配列へ反映されず永続化も走らないため)。"
```

---

## 実装後の確認事項

- [ ] `git status` がクリーンであること
- [ ] Xcodeビルドが `** BUILD SUCCEEDED **` であること
- [ ] `PurchaseFormView.swift` が変更されていないこと(`git log -1 --stat` で確認)
- [ ] サーバーは変更していないため、デプロイは不要

## 手動確認(ユーザー実施。実機/シミュレータ)

設計書§6の項目。実装者は行わなくてよい。

1. 移行: アップデート前に配送料¥350を設定していた場合、送料設定に「デフォルト ¥350」が1件あり選択済みになっている。仕入れフォームの配送料も従来どおり¥350で入る
2. 配送料に「ネコポス ¥210」「宅急便コンパクト ¥450」を追加しネコポスを選択 → 新規の仕入れフォームで配送料が¥210、出品価格下の配送料表示も¥210になる
3. 宅急便コンパクトへ切り替えると、次に開いた仕入れフォームが¥450になる
4. 登録済みの金額を¥210→¥230に直すと、次に開いた仕入れフォームに¥230が入る
5. 選択中のプリセットを削除すると未選択になり、仕入れフォームの配送料が¥0で入る
6. 発送費用でも1〜5と同じ操作ができる
7. 名前が空・金額が空・既存と同じ名前のときは追加ボタンが押せない
8. 未選択(または1件も無い状態)で追加すると自動で選択される。既に選択済みなら追加しても選択は移らない
9. 既に仕入れリストに保存済みの項目を開いても、保存時の配送料・発送費用が変わっていない
