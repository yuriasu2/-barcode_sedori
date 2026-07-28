import SwiftUI

/// 「仕入れ設定」画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// 仕入れフォーム(PurchaseFormView)のFBA・配送料デフォルト値と、仕入先リストの管理を行う。
struct PurchaseSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// numberPadキーボードの配送料TextFieldのフォーカス対象。キーボードツールバーの「完了」で
    /// nilにしてフォーカスを外す(numberPadにはReturnキーが無いため。PurchaseFormViewと同方式)。
    private enum Field: Hashable {
        case shipping
        case newSupplier
    }
    @FocusState private var focusedField: Field?

    /// 仕入先追加用の入力中テキスト。追加確定するとクリアする。
    @State private var newSupplier: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("FBAを利用", isOn: $settings.purchaseUseFbaDefault)
            } header: {
                Text("FBA")
            } footer: {
                Text("仕入れフォームのデフォルト値になります。商品ごとに変更できます。")
            }

            Section("配送料") {
                HStack {
                    Text("配送料デフォルト(円)")
                    Spacer()
                    TextField("配送料", value: $settings.purchaseShippingDefault, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .focused($focusedField, equals: .shipping)
                }
            }

            Section("仕入先") {
                ForEach(settings.purchaseSuppliers, id: \.self) { supplier in
                    Text(supplier)
                }
                .onDelete(perform: deleteSuppliers)

                HStack {
                    TextField("仕入先を追加", text: $newSupplier)
                        .focused($focusedField, equals: .newSupplier)
                        .onSubmit(addSupplier)
                    Button {
                        addSupplier()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(!canAddSupplier)
                }
            }
        }
        .navigationTitle("仕入れ設定")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
    }

    /// 空文字・前後空白のみ・登録済みと重複する場合は追加しない。
    private var canAddSupplier: Bool {
        let trimmed = newSupplier.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !settings.purchaseSuppliers.contains(trimmed)
    }

    private func addSupplier() {
        let trimmed = newSupplier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.purchaseSuppliers.contains(trimmed) else { return }
        settings.purchaseSuppliers.append(trimmed)
        newSupplier = ""
    }

    private func deleteSuppliers(at offsets: IndexSet) {
        settings.purchaseSuppliers.remove(atOffsets: offsets)
    }
}
