import SwiftUI

/// 送料設定画面のキーボードフォーカス対象(一覧の金額欄用)。行ごとに一意にするためIDを持つ。
private enum ShippingSettingsField: Hashable {
    case amount(UUID)
}

/// 追加シートをどちらのセクションから開いたか。`.sheet(item:)`で使うためIdentifiable。
private struct ShippingAddTarget: Identifiable {
    enum Kind: String {
        case income
        case cost
    }

    let kind: Kind

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .income: return "配送料を追加"
        case .cost: return "発送費用を追加"
        }
    }
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

    /// 追加シートの提示状態。**Sectionや行の中ではなくForm自体に付ける**こと。
    /// Listの行からシートを提示するとSwiftUIが提示先を解決できず、タップしても何も起きない。
    @State private var addTarget: ShippingAddTarget?

    var body: some View {
        Form {
            ShippingPresetSection(
                title: "配送料",
                footnote: "購入者が支払い、自分に入金される額です。",
                presets: $settings.purchaseShippingIncomePresets,
                selectedId: $settings.purchaseShippingIncomeSelectedId,
                focusedField: $focusedField,
                onRequestAdd: { addTarget = ShippingAddTarget(kind: .income) }
            )

            ShippingPresetSection(
                title: "発送費用",
                footnote: "自分が支払う発送コストです。",
                presets: $settings.purchaseShippingCostPresets,
                selectedId: $settings.purchaseShippingCostSelectedId,
                focusedField: $focusedField,
                onRequestAdd: { addTarget = ShippingAddTarget(kind: .cost) }
            )
        }
        .navigationTitle("送料設定")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
        .sheet(item: $addTarget) { target in
            ShippingPresetAddSheet(
                title: target.title,
                existingNames: presets(for: target.kind).map(\.name)
            ) { name, amount in
                add(name: name, amount: amount, to: target.kind)
            }
        }
    }

    private func presets(for kind: ShippingAddTarget.Kind) -> [ShippingPreset] {
        switch kind {
        case .income: return settings.purchaseShippingIncomePresets
        case .cost: return settings.purchaseShippingCostPresets
        }
    }

    /// 追加はシートを持つ親側で行う(シートの提示元と状態の持ち主を揃えるため)。
    /// 未選択のまま追加すると0円が使われ続けて「登録したのに反映されない」となるため、
    /// 1件目(未選択時)は自動で選ぶ。既に選択済みなら選択を横取りしない。
    private func add(name: String, amount: Int, to kind: ShippingAddTarget.Kind) {
        let preset = ShippingPreset(id: UUID(), name: name, amount: amount)
        switch kind {
        case .income:
            settings.purchaseShippingIncomePresets.append(preset)
            if settings.purchaseShippingIncomeSelectedId == nil {
                settings.purchaseShippingIncomeSelectedId = preset.id
            }
        case .cost:
            settings.purchaseShippingCostPresets.append(preset)
            if settings.purchaseShippingCostSelectedId == nil {
                settings.purchaseShippingCostSelectedId = preset.id
            }
        }
    }
}

/// 配送料・発送費用で共通のセクション。構造が完全に同じなので1つにまとめて2回使う。
/// 追加はこのセクションでは行わず、親へ要求だけ投げる(シートは親が持つ)。
private struct ShippingPresetSection: View {
    let title: String
    let footnote: String
    @Binding var presets: [ShippingPreset]
    @Binding var selectedId: UUID?
    @FocusState.Binding var focusedField: ShippingSettingsField?
    let onRequestAdd: () -> Void

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

                    // TextFieldと「円」を隙間なく並べて「100円」の見た目にする。
                    HStack(spacing: 0) {
                        TextField("金額", value: $preset.amount, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .focused($focusedField, equals: .amount(preset.id))
                        Text("円")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        delete(preset)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    // Formの行にButtonを置くと行のどこをタップしても反応してしまい、
                    // 名前タップの「選択」が動かなくなる。アイコンだけを反応させる。
                    .buttonStyle(.borderless)
                }
                // 金額欄・ゴミ箱以外をタップしたら選択を切り替える。
                .contentShape(Rectangle())
                .onTapGesture { selectedId = preset.id }
            }
            .onDelete(perform: deleteAt)

            Button(action: onRequestAdd) {
                Label("追加", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Text(footnote)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    /// ゴミ箱アイコンからの削除。確認は挟まない(誤タップしても再登録が容易なため)。
    private func delete(_ preset: ShippingPreset) {
        presets.removeAll { $0.id == preset.id }
        clearSelectionIfMissing()
    }

    /// スワイプ削除。ゴミ箱と併存させる(iOSの操作感として自然で、追加コストが無い)。
    private func deleteAt(offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        clearSelectionIfMissing()
    }

    /// 選択中を消したら未選択(0円)へ戻す。別のものを勝手に選ぶと、
    /// 気づかないまま違う金額で出品する事故になりうるため。
    private func clearSelectionIfMissing() {
        guard let selectedId, !presets.contains(where: { $0.id == selectedId }) else { return }
        self.selectedId = nil
    }
}

/// 「+ 追加」で開く入力シート。
///
/// システムのアラートではなくシートにしているのは、アラートが本文を赤文字にできず、
/// ボタンを押すと必ず閉じてしまうため。「不正なら閉じずに、該当の入力欄の直下へ
/// 赤文字で理由を出す」という要件を満たせるのはシートだけ。
///
/// フォーカスは親から受け取らずシート内に持つ。@FocusStateはシート境界をまたぐと
/// 正しく働かないため。
private struct ShippingPresetAddSheet: View {
    let title: String
    /// 重複判定に使う既存の名前。シートを開いた時点のスナップショットでよい
    /// (開いている間に他所から増えることが無いため)。
    let existingNames: [String]
    let onAdd: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case name
        case amount
    }
    @FocusState private var focusedField: Field?

    @State private var name = ""
    @State private var amountText = ""
    /// 「追加」を押して検証に失敗したときだけ表示するメッセージ。
    /// 該当の入力欄を編集し直したら消す(直したのに赤文字が残ると直っていないように見えるため)。
    @State private var nameError: String?
    @State private var amountError: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("名前")
                        Spacer()
                        TextField("名前", text: $name)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .name)
                            .onChange(of: name) { _ in nameError = nil }
                    }
                    if let nameError {
                        Text(nameError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    HStack {
                        Text("金額")
                        Spacer()
                        HStack(spacing: 0) {
                            TextField("金額", text: $amountText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .focused($focusedField, equals: .amount)
                                .onChange(of: amountText) { _ in amountError = nil }
                            Text("円")
                                .foregroundColor(.secondary)
                        }
                    }
                    if let amountError {
                        Text(amountError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                // 「追加」は常に押せる状態にする。グレーアウトさせると押せない理由が
                // 分からないため、押させて該当の欄に理由を出す。
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") { submit() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { focusedField = nil }
                }
            }
        }
    }

    /// 両方の欄を検証し、該当するメッセージをすべて出す。1つでも不正ならシートを閉じない。
    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 名前が空のときは重複判定をしない(表示するメッセージは名前につき1つ)。
        if trimmedName.isEmpty {
            nameError = "名前が入力されていません"
        } else if existingNames.contains(trimmedName) {
            nameError = "同じ名前が既に登録されています"
        } else {
            nameError = nil
        }

        // 0円は送料無料の運用がありうるためエラーにしない。未入力だけを弾く。
        let amount = Int(amountText.trimmingCharacters(in: .whitespaces))
        amountError = amount == nil ? "金額が入力されていません" : nil

        guard nameError == nil, let amount else { return }
        onAdd(trimmedName, amount)
        dismiss()
    }
}
