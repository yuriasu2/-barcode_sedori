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
    @Published var price: Int? {
        didSet {
            // 出品価格が変わるたびに手数料を取り直す(0.5秒デバウンス。連打で無駄打ちしない)。
            scheduleFeesFetch()
        }
    }
    @Published var quantity: Int {
        didSet {
            regenerateSkuIfNotEdited()
        }
    }
    @Published var sku: String
    @Published var conditionNote: String

    /// FBAを利用して出品するか。トグル切替のたびに手数料を取り直す(FBA手数料の有無が変わるため)。
    /// FBA手数料(配送代行手数料)には購入者への配送料が含まれるため、ONで配送料を自動的に0にし、
    /// OFFに戻したら設定の配送料デフォルトへ戻す(手入力での上書きは引き続き可能)。
    @Published var useFba: Bool {
        didSet {
            guard useFba != oldValue else { return }
            shippingCost = useFba ? 0 : settings.purchaseShippingDefault
            startFeesFetch()
        }
    }
    /// 仕入れ価格(円)。利益セクションの入力値。
    @Published var purchasePrice: Int?
    /// 配送料(円)。利益セクションの入力値。初期値は設定の配送料デフォルト(新規)/保存値(編集)。
    @Published var shippingCost: Int?
    /// 仕入れ日。既定は追加日。
    @Published var purchaseDate: Date
    /// 仕入先(自由文字列。未選択はnil)。
    @Published var supplier: String?
    /// 自分用の内部メモ。
    @Published var memo: String

    /// 手数料取得の状態。DisclosureGroupで内訳を展開する行の表示に使う。
    enum FeesState: Equatable {
        case idle
        case loading
        case loaded(FeesDisplay)
    }
    /// 手数料表示用にAPI実額/アプリ内概算を統一した形。
    struct FeesDisplay: Equatable {
        let total: Int
        let breakdown: [FeesEstimateResult.FeeLine]
        /// 概算フォールバックかどうか(合計行に「(概算)」を付記する)。
        let isEstimate: Bool
        /// 概算フォールバックでFBAトグルONのとき、FBA手数料が算出不可であることを示す注記。
        /// それ以外(実額取得時・自己発送時)はnil。
        let fbaRequiresLinkNote: String?
    }
    @Published private(set) var feesState: FeesState = .idle
    /// 手数料取得のリクエスト連番。制限チェック(restrictionCheckSequence)と同じガード方式で、
    /// 古い応答が新しい結果を後から上書きしないようにする。
    private var feesCheckSequence = 0
    /// 出品価格変更時のデバウンス用タスク。連打のたびにキャンセルし直す。
    private var feesDebounceTask: Task<Void, Never>?

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
            self.useFba = settings.purchaseUseFbaDefault
            self.purchasePrice = nil
            // FBA時は配送料がFBA手数料(配送代行手数料)に含まれるため0で始める。
            self.shippingCost = settings.purchaseUseFbaDefault ? 0 : settings.purchaseShippingDefault
            self.purchaseDate = draft.addedAt
            // 前回選んだ仕入先。登録済みリストから削除されていれば「未選択」扱いにする。
            self.supplier = settings.purchaseLastSupplier.flatMap { settings.purchaseSuppliers.contains($0) ? $0 : nil }
            self.memo = ""
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
            self.useFba = numberedItem.useFba ?? settings.purchaseUseFbaDefault
            self.purchasePrice = numberedItem.purchasePrice
            self.shippingCost = numberedItem.shippingCost ?? settings.purchaseShippingDefault
            self.purchaseDate = numberedItem.purchaseDate ?? numberedItem.addedAt
            self.supplier = numberedItem.supplier
            self.memo = numberedItem.memo ?? ""
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

    /// 仕入先Pickerの選択肢。「未選択」(nil)+設定タブの登録済みリストに加え、
    /// 編集時の保存値がリストから削除されていても選択肢として表示する(値を消さないため)。
    var supplierOptions: [String?] {
        var options: [String?] = [nil]
        options.append(contentsOf: settings.purchaseSuppliers.map { $0 as String? })
        if let supplier, !settings.purchaseSuppliers.contains(supplier) {
            options.append(supplier)
        }
        return options
    }

    /// フォーム表示時に呼ぶ。制限チェックの実行条件(Pro+SP-API連携済み)を満たさなければ
    /// `.unavailable`のままセクション自体を出さない(Keepa経路ユーザーのフォームを汚さない)。
    func onAppear() {
        startRestrictionCheck()
        startFeesFetch()
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

    /// 粗利益 = 出品価格 − 仕入れ価格 − 手数料合計 − 配送料。
    /// 出品価格・仕入れ価格が未入力、または手数料が未取得(idle/loading)の間は計算せずnilを返す
    /// (呼び出し側は「—」表示にする)。
    var grossProfit: Int? {
        guard let price, let purchasePrice, case .loaded(let display) = feesState else { return nil }
        return price - purchasePrice - display.total - (shippingCost ?? 0)
    }

    /// フォーム表示時・FBAトグル切替時に呼ぶ即時実行版(デバウンスしない)。
    private func startFeesFetch() {
        feesDebounceTask?.cancel()
        feesDebounceTask = nil
        performFeesFetch()
    }

    /// 出品価格変更時に呼ぶ。0.5秒デバウンスしてから実行する(連打のたびに無駄打ちしないため。
    /// 制限チェックの連番ガードとは別に、こちらはTask.sleep+キャンセルで間引く)。
    private func scheduleFeesFetch() {
        feesDebounceTask?.cancel()
        feesDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.performFeesFetch()
        }
    }

    /// 手数料取得の本体。SP-API連携済みProはAPIで実額、それ以外(無料ユーザー・未連携Pro)は
    /// 通信せずアプリ内概算にフォールバックする。制限チェックと同じ連番ガードで、
    /// 古い応答(コンディション連打・価格連打)が新しい結果を後から上書きしないようにする。
    private func performFeesFetch() {
        guard let price else {
            feesState = .idle
            return
        }
        feesCheckSequence += 1
        let sequence = feesCheckSequence
        let checkAsin = asin
        let checkPrice = price
        let checkFba = useFba

        guard entitlements.isPro && settings.isListingReady else {
            feesState = .loaded(Self.estimateFeesDisplay(price: checkPrice, fba: checkFba))
            return
        }

        feesState = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.apiClient.feesEstimate(asin: checkAsin, price: checkPrice, fba: checkFba)
                guard sequence == self.feesCheckSequence else { return }
                self.feesState = .loaded(FeesDisplay(
                    total: result.total,
                    breakdown: result.breakdown,
                    isEstimate: false,
                    fbaRequiresLinkNote: nil
                ))
            } catch {
                // API失敗時も概算フォールバックに切り替える(「取得できません」で詰まらせない)。
                guard sequence == self.feesCheckSequence else { return }
                self.feesState = .loaded(Self.estimateFeesDisplay(price: checkPrice, fba: checkFba))
            }
        }
    }

    /// アプリ内概算: 販売手数料15% + カテゴリ成約料80円 + 消費税(小計の10%)。
    /// FBA手数料は実額取得(SP-API連携)でしか算出できないため、FBAトグルONのときは
    /// 内訳に「連携が必要」の注記だけ出し、合計には含めない。
    private static func estimateFeesDisplay(price: Int, fba: Bool) -> FeesDisplay {
        let referral = Int((Double(price) * 0.15).rounded())
        let closing = 80
        let tax = Int((Double(referral + closing) * 0.10).rounded())
        let breakdown: [FeesEstimateResult.FeeLine] = [
            .init(type: "referral", label: "販売手数料", amount: referral),
            .init(type: "closing", label: "カテゴリ成約料", amount: closing),
            .init(type: "tax", label: "消費税", amount: tax),
        ]
        return FeesDisplay(
            total: referral + closing + tax,
            breakdown: breakdown,
            isEstimate: true,
            fbaRequiresLinkNote: fba ? "連携が必要" : nil
        )
    }

    /// 保存(緑チェック)。新規追加時はPurchaseListStoreへ登録し、編集時は上書きする。
    /// 直近コンディションはSettingsStoreへ記憶し、次回の新規追加フォームの初期値にする。
    /// 仕入先も選択していればlastSupplierへ記憶する(lastListingConditionと同じ作法)。
    func save() {
        let trimmedSku = sku.trimmingCharacters(in: .whitespaces)
        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoToSave = trimmedMemo.isEmpty ? nil : trimmedMemo
        settings.lastListingCondition = condition
        if let supplier {
            settings.purchaseLastSupplier = supplier
        }

        switch mode {
        case .add(let draft):
            var itemToAdd = draft
            itemToAdd.condition = condition
            itemToAdd.price = price
            itemToAdd.quantity = quantity
            itemToAdd.conditionNote = conditionNote
            itemToAdd.sku = trimmedSku
            itemToAdd.useFba = useFba
            itemToAdd.purchasePrice = purchasePrice
            itemToAdd.shippingCost = shippingCost
            itemToAdd.purchaseDate = purchaseDate
            itemToAdd.supplier = supplier
            itemToAdd.memo = memoToSave
            purchaseList.add(itemToAdd)
        case .edit(let item):
            // update(...)は渡さなかった新フィールドをnilで上書きする仕様のため、
            // 変更していないフィールドも含めて必ず全て明示的に渡す。
            purchaseList.update(
                id: item.id,
                condition: condition,
                price: price,
                quantity: quantity,
                conditionNote: conditionNote,
                sku: trimmedSku,
                useFba: useFba,
                purchasePrice: purchasePrice,
                shippingCost: shippingCost,
                purchaseDate: purchaseDate,
                supplier: supplier,
                memo: memoToSave
            )
        }
    }
}

struct PurchaseFormView: View {
    @StateObject private var viewModel: PurchaseFormViewModel
    @Environment(\.dismiss) private var dismiss

    /// numberPadキーボードのTextFieldのフォーカス対象。キーボードツールバーの「完了」で
    /// nilにしてフォーカスを外す(numberPadにはReturnキーが無いため。ListingFormViewと同方式)。
    private enum Field: Hashable {
        case price
        case purchasePrice
        case shippingCost
    }
    @FocusState private var focusedField: Field?

    /// 金額表示の共通フォーマット(「¥1,234」形式)。
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    private static func currencyText(_ amount: Int) -> String {
        "¥" + (currencyFormatter.string(from: NSNumber(value: amount)) ?? String(amount))
    }

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
                    Text("出品価格(円)")
                    Spacer()
                    TextField("出品価格", value: $viewModel.price, format: .number)
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

                Toggle("FBAを利用", isOn: $viewModel.useFba)
            }

            profitSection

            purchaseInfoSection

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

    /// 利益セクション: 出品価格(表示のみ)/ 仕入れ価格・配送料(入力)/ 手数料(内訳展開)/ 粗利益。
    /// 赤字=コスト、青字太字=粗利益(設計書の色分けに合わせる)。
    private var profitSection: some View {
        Section("利益") {
            HStack {
                Text("出品価格")
                Spacer()
                Text(viewModel.price.map(Self.currencyText) ?? "—")
            }

            HStack {
                Text("仕入れ価格")
                    .foregroundColor(.red)
                Spacer()
                TextField("仕入れ価格", value: $viewModel.purchasePrice, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                    .foregroundColor(.red)
                    .focused($focusedField, equals: .purchasePrice)
            }

            feesRow

            HStack {
                Text("配送料")
                    .foregroundColor(.red)
                Spacer()
                TextField("配送料", value: $viewModel.shippingCost, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                    .foregroundColor(.red)
                    .focused($focusedField, equals: .shippingCost)
            }

            HStack {
                Text("粗利益")
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Spacer()
                Text(viewModel.grossProfit.map(Self.currencyText) ?? "—")
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
        }
    }

    /// 手数料行。取得中はProgressView、取得済みならDisclosureGroupで内訳を展開できる。
    /// 概算フォールバック時は合計に「(概算)」を付記し、FBAトグルON時のみ「連携が必要」の注記を出す。
    @ViewBuilder
    private var feesRow: some View {
        switch viewModel.feesState {
        case .idle:
            HStack {
                Text("手数料")
                    .foregroundColor(.red)
                Spacer()
                Text("—")
                    .foregroundColor(.red)
            }
        case .loading:
            HStack {
                Text("手数料")
                    .foregroundColor(.red)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .loaded(let display):
            DisclosureGroup {
                ForEach(display.breakdown, id: \.type) { line in
                    HStack {
                        Text(line.label)
                        Spacer()
                        Text(Self.currencyText(line.amount))
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                if let note = display.fbaRequiresLinkNote {
                    Text("FBA手数料: \(note)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Text("手数料")
                        .foregroundColor(.red)
                    Spacer()
                    Text(Self.currencyText(display.total) + (display.isEstimate ? "(概算)" : ""))
                        .foregroundColor(.red)
                }
            }
        }
    }

    /// 仕入れ情報セクション: 仕入れ日・仕入先・自分用メモ(出品には使わない)。
    private var purchaseInfoSection: some View {
        Section("仕入れ情報") {
            DatePicker("仕入れ日", selection: $viewModel.purchaseDate, displayedComponents: .date)

            Picker("仕入先", selection: $viewModel.supplier) {
                ForEach(viewModel.supplierOptions, id: \.self) { option in
                    Text(option ?? "未選択").tag(option)
                }
            }

            TextField("メモ", text: $viewModel.memo)
        }
    }
}
