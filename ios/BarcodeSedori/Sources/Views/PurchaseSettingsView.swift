import SwiftUI

/// 「仕入先」画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// ここで登録した仕入先が、仕入れフォーム(PurchaseFormView)の仕入先ピッカーの選択肢になる。
struct PurchaseSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// 仕入先追加用の入力中テキスト。追加確定するとクリアする。
    @State private var newSupplier: String = ""
    @FocusState private var isNewSupplierFocused: Bool

    var body: some View {
        Form {
            Section("仕入先") {
                ForEach(settings.purchaseSuppliers, id: \.self) { supplier in
                    Text(supplier)
                }
                .onDelete(perform: deleteSuppliers)

                HStack {
                    TextField("仕入先を追加", text: $newSupplier)
                        .focused($isNewSupplierFocused)
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
        .navigationTitle("仕入先")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { isNewSupplierFocused = false }
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
