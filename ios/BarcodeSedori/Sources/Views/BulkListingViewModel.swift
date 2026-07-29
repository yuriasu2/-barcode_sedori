import Foundation

/// 仕入れタブの選択モードから複数商品をまとめて出品するためのViewModel(Phase 2b)。
/// 選択商品を直列で1件ずつ処理し、1件の失敗で全体を止めない(PurchaseFormViewModelと同じ
/// APIClient/SettingsStore/PurchaseListStoreの作法に合わせる)。
/// 仕入れフローの再設計により、価格の再取得(/api/offers・suggestedPrice)は行わない。
/// 仕入れフォームで保存済みの price/quantity/conditionNote/sku をそのまま使い、
/// priceが未保存の商品は失敗リストへ回して次の商品へ続行する。
@MainActor
final class BulkListingViewModel: ObservableObject {
    struct FailureEntry: Identifiable {
        let id = UUID()
        let title: String
        let reason: String
    }

    struct ResultAlert: Identifiable {
        let id = UUID()
        let successCount: Int
        let failures: [FailureEntry]

        /// アラート本文: 「成功X件・失敗Y件」+失敗理由の一覧(商品タイトル: 理由)。
        var summaryText: String {
            var lines = ["成功\(successCount)件・失敗\(failures.count)件"]
            if !failures.isEmpty {
                lines.append("")
                lines.append(contentsOf: failures.map { "\($0.title): \($0.reason)" })
            }
            return lines.joined(separator: "\n")
        }
    }

    @Published var isRunning = false
    @Published var progressCurrent = 0
    @Published var progressTotal = 0
    @Published var resultAlert: ResultAlert?

    private let apiClient: APIClient
    private let settings: SettingsStore
    private let purchaseList: PurchaseListStore

    init(
        apiClient: APIClient = .shared,
        settings: SettingsStore = .shared,
        purchaseList: PurchaseListStore = .shared
    ) {
        self.apiClient = apiClient
        self.settings = settings
        self.purchaseList = purchaseList
    }

    /// 選択された商品IDを直列で処理する。二重実行防止(isRunning中は何もしない)。
    func run(itemIds: [UUID]) async {
        guard !isRunning else { return }
        isRunning = true
        progressCurrent = 0
        progressTotal = itemIds.count
        defer { isRunning = false }

        var successCount = 0
        var failures: [FailureEntry] = []
        // この実行内で実際に出品を試みたSKUの集合(同時出品どうしの重複検知用)。
        var usedSkus: Set<String> = []

        for id in itemIds {
            progressCurrent += 1

            guard let item = purchaseList.items.first(where: { $0.id == id }) else { continue }
            // 出品済みはスキップ(失敗扱いにしない)。
            if item.isListed { continue }

            let title = item.title ?? item.asin
            // アイテムに保存されたコンディション。未設定時の既定は「良い」。
            let condition = item.condition ?? .usedGood

            do {
                let restriction = try await apiClient.listingsRestrictions(
                    asin: item.asin,
                    condition: condition.rawValue
                )
                if restriction.restricted {
                    failures.append(FailureEntry(title: title, reason: restriction.message ?? "出品制限があります。"))
                    continue
                }
            } catch {
                failures.append(FailureEntry(title: title, reason: "出品制限チェックに失敗しました: \(error.localizedDescription)"))
                continue
            }

            // 価格はフォームで保存済みの値をそのまま使う(再取得はしない)。未設定なら出品せず
            // 仕入れフォームでの設定を促して次の商品へ続行する。
            guard let price = item.price, price > 0 else {
                failures.append(FailureEntry(
                    title: title,
                    reason: "価格が未設定です。商品をタップして仕入れフォームで設定してください。"
                ))
                continue
            }

            // SKU・数量・コンディション説明文もフォームで保存済みの値をそのまま使う。
            // SKUのみ、旧データ(採番導入前)への遅延採番を先に済ませてからフォールバックする。
            let numberedItem = purchaseList.assignSkuSequenceIfNeeded(id: item.id) ?? item
            let sku = numberedItem.sku ?? settings.listingSku(for: numberedItem)

            // SKU重複チェック。出品APIはSKUが既存と重複していても新規出品にならず既存の出品を
            // 上書きしてしまう(エラーにならない)ため、settings.preventDuplicateSkuが有効な間は
            // 出品を試みる前に検知し、該当商品は出品せず次の商品へ続行する。
            if settings.preventDuplicateSku {
                if usedSkus.contains(sku) {
                    failures.append(FailureEntry(
                        title: title,
                        reason: "SKUが重複しています(同時に出品する他の商品と同じSKU)"
                    ))
                    continue
                }
                if purchaseList.items.contains(where: { $0.id != item.id && $0.isListed && $0.listedSku == sku }) {
                    failures.append(FailureEntry(
                        title: title,
                        reason: "SKUが重複しています(出品済みの商品と同じSKU)"
                    ))
                    continue
                }
            }

            let conditionNote = numberedItem.conditionNote ?? settings.listingTemplate(for: condition)
            let quantity = numberedItem.quantity ?? 1
            // FBA利用はアイテムの保存値優先、未保存(旧データ含む)は設定タブのデフォルトに従う。
            let fulfillmentChannel = (item.useFba ?? settings.purchaseUseFbaDefault) ? "AMAZON_JP" : "DEFAULT"

            // 実際に出品を試みる分だけ「使用済みSKU」として記録する。
            usedSkus.insert(sku)

            do {
                let result = try await apiClient.submitListing(ListingSubmissionRequest(
                    asin: item.asin,
                    sku: sku,
                    conditionType: condition.rawValue,
                    price: price,
                    quantity: quantity,
                    conditionNote: conditionNote,
                    fulfillmentChannel: fulfillmentChannel
                ))
                if result.isAccepted {
                    purchaseList.markListed(id: item.id, sku: sku)
                    successCount += 1
                } else {
                    // INVALID等: 理由を記録して次の商品へ続行する。
                    failures.append(FailureEntry(title: title, reason: result.issuesText))
                }
            } catch {
                failures.append(FailureEntry(title: title, reason: error.localizedDescription))
            }
        }

        resultAlert = ResultAlert(successCount: successCount, failures: failures)
    }
}
