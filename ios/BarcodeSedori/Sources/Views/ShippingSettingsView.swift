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
