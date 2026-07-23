import SwiftUI

/// 出品フォーム(Phase 2)。仕入れタブの「出品」から開く(Pro+SP-API連携時のみ導線が出る)。
/// フロー: 表示時に出品制限チェック(制限ありなら入力不可+解除案内)→
/// /api/offersで最新価格を再取得して初期価格を更新→確認ダイアログ→POST /api/listings。
@MainActor
final class ListingFormViewModel: ObservableObject {
    /// 出品制限チェックの状態。
    enum RestrictionState: Equatable {
        case checking
        case allowed
        case restricted(message: String, approvalUrl: String?)
        case checkFailed(String)
    }

    @Published var condition: ListingConditionType = .usedVeryGood {
        didSet {
            // コンディション変更でテンプレートを再適用し、制限も再チェックする
            // (制限はconditionType単位で変わり得るため)。
            conditionNote = settings.listingTemplate(for: condition)
            applySuggestedPrice()
            Task { await checkRestrictions() }
        }
    }
    @Published var price: Int?
    @Published var sku: String = ""
    @Published var conditionNote: String = ""
    @Published var quantity: Int = 1
    @Published var restrictionState: RestrictionState = .checking
    @Published var isSubmitting = false
    /// 出品結果アラート(受理成功/エラー本文)。
    @Published var resultAlert: ResultAlert?

    struct ResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// trueなら閉じるときにフォームも閉じる(受理成功時)。
        let dismissesForm: Bool
    }

    let item: PurchaseListItem
    /// 表示時に/api/offersで再取得した最新オファー。取得前はitem.offersResult(追加時スナップショット)。
    private var latestOffers: OffersResult?

    private let apiClient: APIClient
    private let settings: SettingsStore
    private let purchaseList: PurchaseListStore

    init(
        item: PurchaseListItem,
        apiClient: APIClient = .shared,
        settings: SettingsStore = .shared,
        purchaseList: PurchaseListStore = .shared
    ) {
        self.item = item
        self.apiClient = apiClient
        self.settings = settings
        self.purchaseList = purchaseList
        self.latestOffers = item.offersResult
        // didSetはinit中に走らないため初期値を明示的に組み立てる。
        self.conditionNote = settings.listingTemplate(for: .usedVeryGood)
        self.sku = settings.nextListingSku()
        self.price = ListingModels.suggestedPrice(offers: item.offersResult, condition: .usedVeryGood)
    }

    /// 画面表示時: 制限チェックと最新オファー再取得を並行実行する。
    func onAppear() async {
        async let restrictions: Void = checkRestrictions()
        async let offers: Void = refreshOffers()
        _ = await (restrictions, offers)
    }

    func checkRestrictions() async {
        restrictionState = .checking
        do {
            let result = try await apiClient.listingsRestrictions(
                asin: item.asin,
                condition: condition.rawValue
            )
            if result.restricted {
                restrictionState = .restricted(
                    message: result.message ?? "出品制限があります。",
                    approvalUrl: result.approvalUrl
                )
            } else {
                restrictionState = .allowed
            }
        } catch {
            restrictionState = .checkFailed(error.localizedDescription)
        }
    }

    /// 最新オファーを再取得して初期価格を更新する(出品はSP-API連携必須のためsource=spapi固定)。
    /// 失敗時は追加時スナップショットの価格のまま(フォーム入力は可能)。
    private func refreshOffers() async {
        if let refreshed = try? await apiClient.offers(asin: item.asin, source: "spapi") {
            latestOffers = refreshed
            applySuggestedPrice()
        }
    }

    private func applySuggestedPrice() {
        if let suggested = ListingModels.suggestedPrice(offers: latestOffers, condition: condition) {
            price = suggested
        }
    }

    var canSubmit: Bool {
        guard case .allowed = restrictionState else { return false }
        guard let price, price > 0 else { return false }
        return !sku.trimmingCharacters(in: .whitespaces).isEmpty && quantity > 0 && !isSubmitting
    }

    func submit() async {
        guard let price else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let trimmedSku = sku.trimmingCharacters(in: .whitespaces)
            let result = try await apiClient.submitListing(ListingSubmissionRequest(
                asin: item.asin,
                sku: trimmedSku,
                conditionType: condition.rawValue,
                price: price,
                quantity: quantity,
                conditionNote: conditionNote
            ))
            if result.isAccepted {
                purchaseList.markListed(id: item.id, sku: trimmedSku)
                resultAlert = ResultAlert(
                    title: "出品を受け付けました",
                    message: "反映まで数分かかります。",
                    dismissesForm: true
                )
            } else {
                // INVALID等: issuesの本文をそのまま表示(日本語化しない)。フォームに留まりリトライ可能。
                resultAlert = ResultAlert(title: "出品できませんでした", message: result.issuesText, dismissesForm: false)
            }
        } catch {
            // 価格不正・制限・トークン失効等: サーバーのエラー本文をそのまま表示してリトライ可能。
            resultAlert = ResultAlert(title: "出品に失敗しました", message: error.localizedDescription, dismissesForm: false)
        }
    }
}

struct ListingFormView: View {
    @StateObject private var viewModel: ListingFormViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirm = false

    /// numberPadキーボードの価格TextFieldのフォーカス対象。キーボードツールバーの「完了」で
    /// nilにしてフォーカスを外す(numberPadにはReturnキーが無いため。ProfitAlertSettingsViewと同方式)。
    private enum Field: Hashable {
        case price
    }
    @FocusState private var focusedField: Field?

    init(item: PurchaseListItem) {
        _viewModel = StateObject(wrappedValue: ListingFormViewModel(item: item))
    }

    var body: some View {
        Form {
            Section("商品") {
                Text(viewModel.item.title ?? "(タイトル不明)")
                    .font(.subheadline)
                HStack {
                    Text("ASIN")
                    Spacer()
                    Text(viewModel.item.asin)
                        .foregroundColor(.secondary)
                }
            }

            restrictionSection

            // 制限あり・チェック中は入力欄と出品ボタンをロックする。
            // Form全体に.disabledを掛けると制限セクション内の「再チェック」ボタンやLinkまで
            // 無効化されるため、入力系Sectionへ個別に付与する。
            Section("出品内容") {
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
            .disabled(isFormLocked)

            Section("コンディション説明") {
                TextEditor(text: $viewModel.conditionNote)
                    .frame(minHeight: 100)
                Text("設定タブの「出品説明文テンプレート」を自動適用しています。この出品だけ個別に編集できます。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .disabled(isFormLocked)

            Section {
                Button {
                    showConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("出品する")
                                .fontWeight(.bold)
                        }
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("出品")
        .navigationBarTitleDisplayMode(.inline)
        // numberPadキーボードにはReturnキーが無く閉じる手段が無いため、キーボード上に「完了」を出す。
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
        // 出品は不可逆操作のため確認ダイアログ必須(spec)。
        .confirmationDialog(
            "この内容で出品しますか?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("出品する") {
                Task { await viewModel.submit() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(viewModel.condition.displayName) / ¥\(viewModel.price ?? 0) / 数量\(viewModel.quantity)\nSKU: \(viewModel.sku)")
        }
        .alert(item: $viewModel.resultAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    if alert.dismissesForm {
                        dismiss()
                    }
                }
            )
        }
        .task {
            await viewModel.onAppear()
        }
    }

    /// 制限あり・チェック中・チェック失敗時は入力欄と出品ボタンをロックする。
    private var isFormLocked: Bool {
        if case .allowed = viewModel.restrictionState { return false }
        return true
    }

    /// 出品制限チェックの状態表示。制限ありは理由と解除申請リンク(Seller Central)を案内する。
    @ViewBuilder
    private var restrictionSection: some View {
        switch viewModel.restrictionState {
        case .checking:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("出品制限を確認中…")
                        .foregroundColor(.secondary)
                }
            }
        case .allowed:
            EmptyView()
        case .restricted(let message, let approvalUrl):
            Section("出品制限があります") {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                if let approvalUrl, let url = URL(string: approvalUrl) {
                    Link("Seller Centralで解除申請する", destination: url)
                        .font(.footnote)
                }
                Text("解除申請はアプリからは行えません。Seller Centralでの手続き後に再度お試しください。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .checkFailed(let message):
            Section("制限チェックに失敗しました") {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                Button("再チェック") {
                    Task { await viewModel.checkRestrictions() }
                }
            }
        }
    }
}
