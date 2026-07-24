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
    /// 出品制限チェックの状態(仕入れフォームでは表示のみ。保存はブロックしない)。
    /// SP-API未連携/Pro未加入では`.unavailable`のままチェック自体を行わず、セクションも表示しない
    /// (Keepa経路ユーザーのフォームを汚さないため)。
    enum RestrictionState: Equatable {
        case unavailable
        case checking
        case allowed
        case restricted(message: String?, approvalUrl: String?)
        case failed(String)
    }

    @Published var condition: ListingConditionType {
        didSet {
            // コンディション変更でテンプレートを再適用する(旧ListingFormViewと同じ挙動)。
            conditionNote = settings.listingTemplate(for: condition)
            // 価格の自動提案(新品/中古バケット最安)は新規追加時のみ再計算する。
            // 編集時にコンディションを変えても、既に保存されている(またはユーザーが入力した)価格は保持する。
            if case .add(let draft) = mode {
                price = ListingModels.bucketLowestPrice(offers: draft.offersResult, condition: condition)
            }
            regenerateSkuIfNotEdited()
            // コンディションが変われば制限判定も変わり得るため再チェックする。
            startRestrictionCheck()
        }
    }
    @Published private(set) var restrictionState: RestrictionState = .unavailable
    @Published var price: Int?
    @Published var quantity: Int {
        didSet {
            regenerateSkuIfNotEdited()
        }
    }
    @Published var sku: String
    @Published var conditionNote: String

    let mode: PurchaseFormMode

    private let settings: SettingsStore
    private let purchaseList: PurchaseListStore
    private let apiClient: APIClient
    private let entitlements: EntitlementStore
    /// 制限チェックのリクエスト連番。コンディション連打で古いチェックの結果が後から返っても
    /// 「実行時点の最新連番と一致するときだけ反映する」ことで、新しい結果を古い結果が上書きしないようにする。
    private var restrictionCheckSequence = 0
    /// SKU組み立てに使う枝番。init時に確定した値をそのまま再生成にも使い回す
    /// (addモードは覗き見の連番、editモードは遅延採番済みの確定値)。
    private let skuSequence: Int
    /// 直近の自動生成SKU。現在の`sku`がこれと一致する間だけ「未編集」とみなし再生成する。
    /// SwiftUIのTextFieldは初期化時のprogrammatic設定とユーザー入力を区別できないため、
    /// 値の一致比較で判定する(onChangeフラグ方式は使わない)。
    private var lastAutoSku: String

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
        purchaseList: PurchaseListStore = .shared,
        apiClient: APIClient = .shared,
        entitlements: EntitlementStore = .shared
    ) {
        self.mode = mode
        self.settings = settings
        self.purchaseList = purchaseList
        self.apiClient = apiClient
        self.entitlements = entitlements

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
            self.skuSequence = previewSequence
            let generatedSku = SkuGenerator.build(
                components: settings.listingSkuFormat,
                addedDate: draft.addedAt,
                asin: draft.asin,
                jan: draft.scannedCode,
                sequence: previewSequence,
                quantity: 1
            )
            self.sku = generatedSku
            self.lastAutoSku = generatedSku
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
            self.skuSequence = numberedItem.skuSequence ?? 1
            let generatedSku = numberedItem.sku ?? settings.listingSku(for: numberedItem)
            self.sku = generatedSku
            self.lastAutoSku = generatedSku
        }
    }

    /// 現在のSKUが直近の自動生成値(lastAutoSku)と一致する場合のみ、現在のquantity/コンディションで
    /// SKUを再生成する(=ユーザー未編集のときだけ再生成する。手入力済みなら何もしない)。
    private func regenerateSkuIfNotEdited() {
        guard sku == lastAutoSku else { return }
        let newSku: String
        switch mode {
        case .add(let draft):
            newSku = SkuGenerator.build(
                components: settings.listingSkuFormat,
                addedDate: draft.addedAt,
                asin: draft.asin,
                jan: draft.scannedCode,
                sequence: skuSequence,
                quantity: quantity
            )
        case .edit(let item):
            newSku = SkuGenerator.build(
                components: settings.listingSkuFormat,
                addedDate: item.addedAt,
                asin: item.asin,
                jan: item.scannedCode,
                sequence: skuSequence,
                quantity: quantity
            )
        }
        sku = newSku
        lastAutoSku = newSku
    }

    var canSave: Bool {
        !sku.trimmingCharacters(in: .whitespaces).isEmpty && quantity > 0
    }

    /// フォーム表示時に呼ぶ。制限チェックの実行条件(Pro+SP-API連携済み)を満たさなければ
    /// `.unavailable`のままセクション自体を出さない(Keepa経路ユーザーのフォームを汚さない)。
    func onAppear() {
        startRestrictionCheck()
    }

    /// 「再確認」ボタンからの再チェック(failed時)。挙動はstartRestrictionCheckと同じ。
    func retryRestrictionCheck() {
        startRestrictionCheck()
    }

    /// 出品制限チェックを開始する。Pro+SP-API連携済みのときだけAPIを呼ぶ。
    /// コンディション変更で連打されても、実行完了時点の連番が最新でなければ結果を捨てる
    /// (古いチェックが後から返って新しい結果を上書きしないようにするガード)。
    private func startRestrictionCheck() {
        guard entitlements.isPro && settings.isListingReady else {
            restrictionState = .unavailable
            return
        }
        restrictionCheckSequence += 1
        let sequence = restrictionCheckSequence
        let checkAsin = asin
        let checkCondition = condition
        restrictionState = .checking
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.apiClient.listingsRestrictions(
                    asin: checkAsin,
                    condition: checkCondition.rawValue
                )
                guard sequence == self.restrictionCheckSequence else { return }
                if result.restricted {
                    self.restrictionState = .restricted(message: result.message, approvalUrl: result.approvalUrl)
                } else {
                    self.restrictionState = .allowed
                }
            } catch {
                guard sequence == self.restrictionCheckSequence else { return }
                self.restrictionState = .failed(error.localizedDescription)
            }
        }
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

            restrictionSection

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
        .task {
            viewModel.onAppear()
        }
    }

    /// 出品制限の状態表示。Pro+SP-API連携済みのときだけ表示し(unavailableはセクション自体を出さない)、
    /// 保存はブロックしない(制限があっても仕入れ登録は可能。出品時のブロックは一括出品側が担う)。
    @ViewBuilder
    private var restrictionSection: some View {
        switch viewModel.restrictionState {
        case .unavailable:
            EmptyView()
        case .checking:
            Section("出品制限") {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("確認中…")
                        .foregroundColor(.secondary)
                }
            }
        case .allowed:
            Section("出品制限") {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("出品可能です")
                }
            }
        case .restricted(let message, let approvalUrl):
            Section("出品制限") {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("出品制限があります")
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if let approvalUrl, let url = URL(string: approvalUrl) {
                    Link("Seller Centralで解除申請", destination: url)
                        .font(.footnote)
                }
            }
        case .failed(let message):
            Section("出品制限") {
                Text("確認できませんでした")
                    .foregroundColor(.secondary)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("再確認") {
                    viewModel.retryRestrictionCheck()
                }
            }
        }
    }
}
