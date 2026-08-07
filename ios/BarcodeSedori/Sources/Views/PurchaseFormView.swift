import SwiftUI
import UIKit

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
                price = ListingModels.autoFillListingPrice(
                    offers: draft.offersResult,
                    condition: condition,
                    shippingIncome: shippingToSubtract,
                    subtractShipping: subtractShippingFromLowest
                )
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
    /// 配送料(円)。購入者が支払い自分に入金される額。販売手数料の計算基礎(出品価格+配送料)に
    /// 使うため、変更のたびに出品価格と同じデバウンスで手数料を取り直す。初期値は設定の
    /// 配送料デフォルト(新規)/保存値(編集)。
    @Published var shippingIncome: Int? {
        didSet {
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
    /// FBAはAmazonが配送するため出品者に配送料収入が無く、購入者への発送費用も発生しない
    /// (FBA倉庫への納品送料がある場合は発送費用に手入力してもらう)。そのためONで配送料・発送費用を
    /// 自動的に0にし、OFFに戻したら設定の各デフォルトへ戻す(手入力での上書きは引き続き可能)。
    @Published var useFba: Bool {
        didSet {
            guard useFba != oldValue else { return }
            shippingIncome = useFba ? 0 : settings.purchaseShippingIncomeDefault
            shippingCost = useFba ? 0 : settings.purchaseShippingCostDefault
            // FBAの切替で配送料を引くかどうかが変わるため、出品価格も入れ直す
            // (コンディション変更時に再計算する既存の挙動と揃える)。
            // startFeesFetchより前に置くこと: priceのdidSetが張るデバウンスを
            // 直後のstartFeesFetchがキャンセルするので、新しい価格で1回だけ取得できる。
            // 自動入力の一部なので、設定がオフのときは何もしない
            // (オフのときの挙動をこの機能の追加前と完全に同じに保つ)。
            if subtractShippingFromLowest, case .add(let draft) = mode {
                // 算出できたときだけ入れ直す。FBA切替ではoffers/conditionが変わらないので、
                // nil(オファー無し)は新しい情報ではなく手入力価格の消失にしかならない。
                if let recalculated = ListingModels.autoFillListingPrice(
                    offers: draft.offersResult,
                    condition: condition,
                    shippingIncome: shippingToSubtract,
                    subtractShipping: true
                ) {
                    price = recalculated
                }
            }
            startFeesFetch()
        }
    }
    /// 仕入れ価格(円)。利益セクションの入力値。
    @Published var purchasePrice: Int?
    /// 発送費用(円)。自分が実際に払う発送コスト。利益セクションの入力値。
    /// 初期値は設定の発送費用デフォルト(新規)/保存値(編集)。手数料の計算には影響しない。
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
        /// サーバーがfees_estimate_unavailableを返した(SP-APIがその商品の手数料見積りを
        /// 返さなかった)場合。概算に逃がすと「概算」として誤った金額を信じさせてしまうため、
        /// 他のエラー(通信断・quota等)とは別扱いにして取得できなかった旨をそのまま出す。
        case unavailable(String)
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

    /// 出品価格から差し引く配送料(設定「送料設定」の配送料デフォルト)。FBA利用時は0
    /// (Amazonが配送するため出品者に配送料収入が無く、引くと実際より安い価格で出品してしまう)。
    /// 出品価格の下に常時表示する値もこれを使う(自動入力のオン/オフ・新規/編集を問わない)。
    var shippingToSubtract: Int {
        useFba ? 0 : settings.purchaseShippingIncomeDefault
    }

    /// 設定「配送料を引いた最安値自動入力」がオンか。出品価格の自動計算にのみ使う
    /// (出品価格の下の配送料表示行はこの設定に関わらず常に出すため、表示条件には使わない)。
    var subtractShippingFromLowest: Bool {
        settings.purchaseSubtractShippingFromLowest
    }

    /// 商品セクションに表示するJANコード(ISBN-13があればそれ、無ければスキャンしたコード)。
    var janCode: String? {
        switch mode {
        case .add(let draft): return draft.isbn13 ?? draft.scannedCode
        case .edit(let item): return item.isbn13 ?? item.scannedCode
        }
    }

    /// 商品セクションに表示するランキング(スキャン時点の値)。
    var salesRank: Int? {
        switch mode {
        case .add(let draft): return draft.salesRank
        case .edit(let item): return item.salesRank
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
            // shippingToSubtractはself.useFba初期化前のため使えない。同じ判定をここで書く。
            self.price = ListingModels.autoFillListingPrice(
                offers: draft.offersResult,
                condition: initialCondition,
                shippingIncome: settings.purchaseUseFbaDefault ? 0 : settings.purchaseShippingIncomeDefault,
                subtractShipping: settings.purchaseSubtractShippingFromLowest
            )
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
            // FBA時は配送料収入も発送費用も発生しないため0で始める。
            self.shippingIncome = settings.purchaseUseFbaDefault ? 0 : settings.purchaseShippingIncomeDefault
            self.shippingCost = settings.purchaseUseFbaDefault ? 0 : settings.purchaseShippingCostDefault
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
            let initialUseFba = numberedItem.useFba ?? settings.purchaseUseFbaDefault
            self.useFba = initialUseFba
            self.purchasePrice = numberedItem.purchasePrice
            // 未保存(旧データ)は設定のデフォルトで補うが、FBAなら配送料・発送費用とも0とする。
            self.shippingCost =
                numberedItem.shippingCost ?? (initialUseFba ? 0 : settings.purchaseShippingCostDefault)
            self.shippingIncome =
                numberedItem.shippingIncome ?? (initialUseFba ? 0 : settings.purchaseShippingIncomeDefault)
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

    /// 粗利益 = 出品価格 + 配送料 − 仕入れ価格 − 手数料 − 発送費用。
    /// 出品価格・仕入れ価格が未入力、または手数料が未取得(idle/loading)の間は計算せずnilを返す
    /// (呼び出し側は「—」表示にする)。
    var grossProfit: Int? {
        guard let price, let purchasePrice, case .loaded(let display) = feesState else { return nil }
        return price + (shippingIncome ?? 0) - purchasePrice - display.total - (shippingCost ?? 0)
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
        // 販売手数料の計算基礎は「出品価格+配送料」であって発送費用ではない。
        let checkShipping = shippingIncome ?? 0

        guard entitlements.isPro && settings.isListingReady else {
            feesState = .loaded(Self.estimateFeesDisplay(price: checkPrice, shipping: checkShipping, fba: checkFba))
            return
        }

        feesState = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.apiClient.feesEstimate(
                    asin: checkAsin,
                    price: checkPrice,
                    fba: checkFba,
                    shipping: checkShipping
                )
                guard sequence == self.feesCheckSequence else { return }
                self.feesState = .loaded(FeesDisplay(
                    total: result.total,
                    breakdown: result.breakdown,
                    isEstimate: false,
                    fbaRequiresLinkNote: nil
                ))
            } catch {
                guard sequence == self.feesCheckSequence else { return }
                if case APIClientError.feesEstimateUnavailable(let message) = error {
                    // SP-APIがその商品の手数料見積りを返さなかった(例: FBA用の梱包サイズ・重量が
                    // カタログに未登録)。概算に逃がすと実際とは違う金額を「概算」として
                    // 信じさせてしまうため、他のエラーとは別に取得できなかった旨をそのまま出す。
                    self.feesState = .unavailable(message ?? "この商品の手数料情報を取得できませんでした。")
                } else {
                    // それ以外のAPI失敗(通信断・quota等)は概算フォールバックに切り替える
                    // (「取得できません」で詰まらせない)。
                    self.feesState = .loaded(Self.estimateFeesDisplay(price: checkPrice, shipping: checkShipping, fba: checkFba))
                }
            }
        }
    }

    /// アプリ内概算: 販売手数料15%(出品価格+配送料が基礎) + カテゴリ成約料80円 +
    /// 消費税(小計の10%)。FBA手数料は実額取得(SP-API連携)でしか算出できないため、
    /// FBAトグルONのときは内訳に「連携が必要」の注記だけ出し、合計には含めない。
    private static func estimateFeesDisplay(price: Int, shipping: Int, fba: Bool) -> FeesDisplay {
        let referral = Int((Double(price + shipping) * 0.15).rounded())
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
            itemToAdd.shippingIncome = shippingIncome
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
                shippingIncome: shippingIncome,
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

    /// キーボードを表示するTextField/TextEditorのフォーカス対象。キーボードツールバーの「完了」で
    /// nilにしてフォーカスを外す(numberPadにはReturnキーが無いため。ListingFormViewと同方式。
    /// sku/memo/conditionNoteは通常キーボードだが、同じ「完了」ボタンで統一して閉じられるようにする)。
    private enum Field: Hashable {
        case price
        case sku
        case purchasePrice
        case shippingIncome
        case shippingCost
        case memo
        case conditionNote
    }
    @FocusState private var focusedField: Field?

    /// キーボードを閉じる。複数行TextField(axis: .vertical)やTextEditorでは@FocusStateを
    /// nilにするだけでは閉じない(日本語入力の変換中は特に残る)ため、
    /// first responderの解除も併せて行う。
    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

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
                    Text("JANコード")
                    Spacer()
                    Text(viewModel.janCode ?? "-")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("ランキング")
                    Spacer()
                    if let rank = viewModel.salesRank {
                        Text("\(rank)位")
                            .foregroundColor(.secondary)
                    } else {
                        Text("-")
                            .foregroundColor(.secondary)
                    }
                }
                restrictionRow
            }

            Section("出品内容") {
                HStack {
                    Text("出品価格(円)")
                    Spacer()
                    TextField("出品価格", value: $viewModel.price, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .focused($focusedField, equals: .price)
                }

                // 配送料を出品価格の直下に常時示す(自動入力のオン/オフ・新規/編集を問わない)。
                // 値は設定「送料設定」の配送料デフォルトで、ここでは変更できない。
                HStack {
                    Text("配送料")
                    Spacer()
                    Text(Self.currencyText(viewModel.shippingToSubtract))
                }
                .font(.footnote)
                .foregroundColor(.secondary)

                Picker("コンディション", selection: $viewModel.condition) {
                    ForEach(ListingConditionType.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }

                // コンディション説明。設定タブのテンプレートを自動適用し、この商品だけ個別に編集できる。
                TextField("コンディション説明", text: $viewModel.conditionNote, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focusedField, equals: .conditionNote)

                HStack {
                    Text("SKU")
                    Spacer()
                    TextField("SKU", text: $viewModel.sku)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                        .focused($focusedField, equals: .sku)
                }

                Stepper("数量: \(viewModel.quantity)", value: $viewModel.quantity, in: 1...99)

                Toggle("FBAを利用", isOn: $viewModel.useFba)
            }

            profitSection

            purchaseInfoSection
        }
        .navigationTitle("仕入れ内容")
        .navigationBarTitleDisplayMode(.inline)
        // numberPadキーボードにはReturnキーが無く閉じる手段が無いため、キーボード上に「完了」を出す。
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { dismissKeyboard() }
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

    /// 出品制限の1行表示。商品セクションに出す(Pro+SP-API未連携のunavailableのみ非表示)。
    /// 保存はブロックしない(制限があっても仕入れ登録は可能。出品時のブロックは一括出品側が担う)。
    @ViewBuilder
    private var restrictionRow: some View {
        switch viewModel.restrictionState {
        case .unavailable:
            EmptyView()
        case .checking:
            restrictionLine {
                ProgressView()
                    .scaleEffect(0.8)
                Text("出品制限を確認中…")
                    .foregroundColor(.secondary)
            }
        case .allowed:
            restrictionLine {
                Text("✅出品可能です")
            }
        case .restricted(_, let approvalUrl):
            restrictionLine {
                Text("⚠️出品制限により出品不可")
                    .foregroundColor(.orange)
                Spacer()
                if let approvalUrl, let url = URL(string: approvalUrl) {
                    Link("許可を申請", destination: url)
                }
            }
        case .failed:
            restrictionLine {
                Text("⚠️出品制限を確認できませんでした")
                    .foregroundColor(.secondary)
                Spacer()
                Button("再確認") {
                    viewModel.retryRestrictionCheck()
                }
            }
        }
    }

    /// 出品制限の1行に共通の体裁(他の行と同じ文字サイズで1行に収める)。
    private func restrictionLine<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// 利益セクション: 出品価格・配送料(黒=入る)/ 仕入れ価格・手数料・発送費用(赤=出る)/
    /// 粗利益(青太字=結果)。出品価格は表示のみ、配送料・仕入れ価格・発送費用は入力可。
    /// 粗利益 = 出品価格 + 配送料 − 仕入れ価格 − 手数料 − 発送費用。
    private var profitSection: some View {
        Section("利益") {
            HStack {
                Text("出品価格")
                Spacer()
                Text(viewModel.price.map(Self.currencyText) ?? "—")
            }

            // FBAでは購入者の配送料をAmazonが受け取るため、出品者の収入にならない。
            // 常に0とし入力も受け付けない(値を入れると手数料の計算基礎が実際と合わなくなる)。
            HStack {
                Text("配送料")
                Spacer()
                TextField("配送料", value: $viewModel.shippingIncome, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                    .focused($focusedField, equals: .shippingIncome)
                    .disabled(viewModel.useFba)
                    .foregroundColor(viewModel.useFba ? .secondary : .primary)
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
                Text("発送費用")
                    .foregroundColor(.red)
                Spacer()
                TextField("発送費用", value: $viewModel.shippingCost, format: .number)
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
        case .unavailable(let message):
            HStack(alignment: .top) {
                Text("手数料")
                    .foregroundColor(.red)
                Spacer()
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.trailing)
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
            DatePicker(
                "仕入れ日",
                selection: $viewModel.purchaseDate,
                displayedComponents: [.date, .hourAndMinute]
            )

            Picker("仕入先", selection: $viewModel.supplier) {
                ForEach(viewModel.supplierOptions, id: \.self) { option in
                    Text(option ?? "未選択").tag(option)
                }
            }

            TextField("メモ", text: $viewModel.memo, axis: .vertical)
                .lineLimit(1...6)
                .focused($focusedField, equals: .memo)
        }
    }
}
