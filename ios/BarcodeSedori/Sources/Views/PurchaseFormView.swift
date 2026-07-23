import SwiftUI

/// 仕入れフォーム(仕入れフロー再設計)。出品フォーム(旧ListingFormView)と同じ項目構成
/// (コンディション/価格/数量/SKU/説明文)を持つが、「出品する」ボタンは無く、保存(緑チェック)で
/// 仕入れリストへの登録・上書きのみを行う。出品制限チェックは行わない(一括出品時に従来通り行う)。
enum PurchaseFormMode {
    /// 新規追加: まだ仕入れリストへ登録していない下書き。保存で初めてPurchaseListStoreへ追加される。
    case add(draft: PurchaseListItem)
    /// 編集: 仕入れリストに既にある項目。保存で上書きする。
    case edit(item: PurchaseListItem)
}

@MainActor
final class PurchaseFormViewModel: ObservableObject {
    @Published var condition: ListingConditionType {
        didSet {
            // コンディション変更でテンプレートを再適用する(旧ListingFormViewと同じ挙動)。
            conditionNote = settings.listingTemplate(for: condition)
            // 価格の自動提案(新品/中古バケット最安)は新規追加時のみ再計算する。
            // 編集時にコンディションを変えても、既に保存されている(またはユーザーが入力した)価格は保持する。
            if case .add(let draft) = mode {
                price = ListingModels.bucketLowestPrice(offers: draft.offersResult, condition: condition)
            }
        }
    }
    @Published var price: Int?
    @Published var quantity: Int
    @Published var sku: String
    @Published var conditionNote: String

    let mode: PurchaseFormMode

    private let settings: SettingsStore
    private let purchaseList: PurchaseListStore

    var title: String? {
        switch mode {
        case .add(let draft): return draft.title
        case .edit(let item): return item.title
        }
    }

    var asin: String {
        switch mode {
        case .add(let draft): return draft.asin
        case .edit(let item): return item.asin
        }
    }

    init(
        mode: PurchaseFormMode,
        settings: SettingsStore = .shared,
        purchaseList: PurchaseListStore = .shared
    ) {
        self.mode = mode
        self.settings = settings
        self.purchaseList = purchaseList

        switch mode {
        case .add(let draft):
            // 前回フォームで保存したコンディション。一度も保存していなければ「非常に良い」。
            let initialCondition = settings.lastListingCondition ?? .usedVeryGood
            self.condition = initialCondition
            self.conditionNote = settings.listingTemplate(for: initialCondition)
            self.quantity = 1
            self.price = ListingModels.bucketLowestPrice(offers: draft.offersResult, condition: initialCondition)
            // SKUプレビュー: まだ仕入れリストへ登録していないため、連番は「消費せず覗き見る」だけにする
            // (実際の採番はadd()保存時にPurchaseListStore.add(_:)が行う)。
            let previewSequence = purchaseList.peekNextSequence(for: draft.addedAt)
            self.sku = SkuGenerator.build(
                components: settings.listingSkuFormat,
                addedDate: draft.addedAt,
                asin: draft.asin,
                jan: draft.scannedCode,
                sequence: previewSequence
            )
        case .edit(let item):
            // 旧データ(SKU枝番の採番導入前に仕入れリストへ追加された項目)は、ここで遅延採番する
            // (採番済みならそのまま返る。冪等)。
            let numberedItem = purchaseList.assignSkuSequenceIfNeeded(id: item.id) ?? item
            // 当該アイテムの保存値。未設定(旧データ)は仕入れタブ行表示・一括出品と同じ既定「良い」。
            let initialCondition = numberedItem.condition ?? .usedGood
            self.condition = initialCondition
            self.conditionNote = numberedItem.conditionNote ?? settings.listingTemplate(for: initialCondition)
            self.quantity = numberedItem.quantity ?? 1
            self.price = numberedItem.price
            self.sku = numberedItem.sku ?? settings.listingSku(for: numberedItem)
        }
    }

    var canSave: Bool {
        !sku.trimmingCharacters(in: .whitespaces).isEmpty && quantity > 0
    }

    /// 保存(緑チェック)。新規追加時はPurchaseListStoreへ登録し、編集時は上書きする。
    /// 直近コンディションはSettingsStoreへ記憶し、次回の新規追加フォームの初期値にする。
    func save() {
        let trimmedSku = sku.trimmingCharacters(in: .whitespaces)
        settings.lastListingCondition = condition

        switch mode {
        case .add(let draft):
            var itemToAdd = draft
            itemToAdd.condition = condition
            itemToAdd.price = price
            itemToAdd.quantity = quantity
            itemToAdd.conditionNote = conditionNote
            itemToAdd.sku = trimmedSku
            purchaseList.add(itemToAdd)
        case .edit(let item):
            purchaseList.update(
                id: item.id,
                condition: condition,
                price: price,
                quantity: quantity,
                conditionNote: conditionNote,
                sku: trimmedSku
            )
        }
    }
}

struct PurchaseFormView: View {
    @StateObject private var viewModel: PurchaseFormViewModel
    @Environment(\.dismiss) private var dismiss

    /// numberPadキーボードの価格TextFieldのフォーカス対象。キーボードツールバーの「完了」で
    /// nilにしてフォーカスを外す(numberPadにはReturnキーが無いため。ListingFormViewと同方式)。
    private enum Field: Hashable {
        case price
    }
    @FocusState private var focusedField: Field?

    init(mode: PurchaseFormMode) {
        _viewModel = StateObject(wrappedValue: PurchaseFormViewModel(mode: mode))
    }

    var body: some View {
        Form {
            Section("商品") {
                Text(viewModel.title ?? "(タイトル不明)")
                    .font(.subheadline)
                HStack {
                    Text("ASIN")
                    Spacer()
                    Text(viewModel.asin)
                        .foregroundColor(.secondary)
                }
            }

            Section("仕入れ内容") {
                Picker("コンディション", selection: $viewModel.condition) {
                    ForEach(ListingConditionType.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }

                HStack {
                    Text("価格(円)")
                    Spacer()
                    TextField("価格", value: $viewModel.price, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .focused($focusedField, equals: .price)
                }

                HStack {
                    Text("SKU")
                    Spacer()
                    TextField("SKU", text: $viewModel.sku)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                }

                Stepper("数量: \(viewModel.quantity)", value: $viewModel.quantity, in: 1...99)
            }

            Section("コンディション説明") {
                TextEditor(text: $viewModel.conditionNote)
                    .frame(minHeight: 100)
                Text("設定タブの「出品説明文テンプレート」を自動適用しています。この商品だけ個別に編集できます。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("仕入れ内容")
        .navigationBarTitleDisplayMode(.inline)
        // numberPadキーボードにはReturnキーが無く閉じる手段が無いため、キーボード上に「完了」を出す。
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
            ToolbarItem(placement: .cancellationAction) {
                // キャンセル・スワイプ閉じは登録しない(saveを呼ばずに閉じるだけ)。
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                // 保存(緑チェックマーク)。押したら保存して閉じる。「出品する」ボタンは無い。
                Button {
                    viewModel.save()
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                }
                .disabled(!viewModel.canSave)
            }
        }
    }
}
