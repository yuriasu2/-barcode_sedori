import Foundation
import Combine

/// 「商品」タブに表示するスキャン履歴を100件単位のチャンクへ永続化するストア。
///
/// 旧形式のDocuments/scan_history.jsonはアップデート後も残るが、ここからは一切読まない。
/// 新形式はHistoryChunkStorageが管理するDocuments/scan_history/だけを使用する。
final class ScanHistoryStore: ObservableObject {
    static let shared = ScanHistoryStore()

    /// 保持する最大件数。超えたぶんは最も古いチャンクから削除する。
    static let maxItems = 5000

    /// 履歴画面に現在ロードされているページだけを公開する。
    @Published private(set) var items: [ScanHistoryItem] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false

    private let storage: HistoryChunkStorage
    private var nextCursor: HistoryChunkStorage.Cursor?

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = documents.appendingPathComponent("scan_history", isDirectory: true)
        self.storage = HistoryChunkStorage(
            directoryURL: directoryURL,
            maxItems: Self.maxItems,
            fileManager: fileManager
        )
        loadInitialPage()
    }

    /// 新しい履歴を先頭へ追加し、一覧を最新ページから読み直す。
    func add(_ item: ScanHistoryItem) {
        do {
            try storage.append(item)
            loadInitialPage()
        } catch {
            reportStorageError("add", error)
        }
    }

    /// 履歴を更新する。現在のページ外にあるレコードもチャンクを走査して更新する。
    func update(id: UUID, transform: (inout ScanHistoryItem) -> Void) {
        do {
            if try storage.update(id: id, transform: transform) {
                loadInitialPage()
            }
        } catch {
            reportStorageError("update", error)
        }
    }

    /// 新形式の履歴を全削除する。旧scan_history.jsonは削除しない。
    func clear() {
        do {
            try storage.clear()
            items = []
            totalCount = 0
            hasMore = false
            nextCursor = nil
        } catch {
            reportStorageError("clear", error)
        }
    }

    /// 商品タブの選択モードでの一括削除用。未ロードの古いチャンクも対象にする。
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        do {
            _ = try storage.remove(ids: ids)
            loadInitialPage()
        } catch {
            reportStorageError("remove", error)
        }
    }

    /// 商品タブが最後の表示行へ到達したとき、次の古いページを追加する。
    @discardableResult
    func loadMore() -> Bool {
        guard !isLoadingMore, let nextCursor else { return false }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try storage.loadPage(limit: HistoryChunkStorage.chunkSize, after: nextCursor)
            items.append(contentsOf: page.items)
            totalCount = page.totalCount
            self.nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            return !page.items.isEmpty
        } catch {
            reportStorageError("loadMore", error)
            return false
        }
    }

    /// 検索を新形式の全チャンクへ実行する。JSONの読み込みはメインスレッド外で行う。
    func search(query: String) async -> [ScanHistoryItem] {
        let directoryURL = storage.directoryURL
        let maxItems = Self.maxItems
        return await Task.detached(priority: .userInitiated) {
            let storage = HistoryChunkStorage(directoryURL: directoryURL, maxItems: maxItems)
            return (try? storage.search(query: query)) ?? []
        }.value
    }

    /// 検索解除時に一覧を最新ページへ戻す。
    func resetToNewestPage() {
        loadInitialPage()
    }

    private func loadInitialPage() {
        do {
            let page = try storage.loadPage(limit: HistoryChunkStorage.chunkSize)
            items = page.items
            totalCount = page.totalCount
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            items = []
            totalCount = 0
            nextCursor = nil
            hasMore = false
            reportStorageError("load", error)
        }
    }

    private func reportStorageError(_ operation: String, _ error: Error) {
        #if DEBUG
        print("[ScanHistoryStore] \(operation) failed: \(error.localizedDescription)")
        #endif
    }

    #if DEBUG
    /// 開発ビルド専用: 新形式の履歴をダミーデータで埋める。
    /// 生成したダミーは既存の新形式履歴より新しいものとして扱う。
    @discardableResult
    func seedDummyItems(count: Int) -> TimeInterval {
        let startedAt = Date()
        let titleSource = "吾輩は猫である名前はまだ無いどこで生れたか頓と見当がつかぬ何でも薄暗いじめじめした所でニャーニャー泣いて"
        var generated: [ScanHistoryItem] = []
        generated.reserveCapacity(count)

        for index in 0..<count {
            let isbn = Bool.random()
            let code = (isbn ? "978" : "4") + String((0..<(isbn ? 10 : 12)).map { _ in "0123456789".randomElement()! })
            let asin = String(format: "DUMMY%05d", index)
            let titleLength = Int.random(in: 20...40)
            let title = String(titleSource.prefix(titleLength))
            let imageUrl = "https://images-na.ssl-images-amazon.com/images/I/" +
                String((0..<11).map { _ in "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()! }) + "._SL500_.jpg"

            let newPrice = Int.random(in: 300...9800)
            let usedPrice = Int.random(in: 100...max(101, newPrice))
            let prices = SearchPrices(
                cart: Bool.random() ? newPrice : nil,
                new: newPrice,
                used: usedPrice,
                points: SearchPoints(cart: Int.random(in: 0...200), new: Int.random(in: 0...200), used: 0)
            )
            let result = SearchResult(
                codeType: isbn ? .isbn : .jan,
                asin: asin,
                title: title,
                isbn13: isbn ? code : nil,
                imageUrl: imageUrl,
                salesRank: Int.random(in: 1...900_000),
                releaseDate: "2024-01-01",
                modelNumber: nil,
                prices: prices,
                source: "keepa",
                offers: nil,
                profitInputs: ProfitInputs(
                    listPrice: Int.random(in: 500...12_000),
                    sellerCounts: ProfitInputs.ConditionCounts(
                        new: Int.random(in: 1...40),
                        used: Int.random(in: 1...60)
                    ),
                    breakEven: nil
                ),
                quota: nil,
                keepaDebug: nil
            )
            let scannedAt = Date().addingTimeInterval(-Double(index) * 60 * 60 * 24 * 60 / Double(max(count, 1)))
            generated.append(
                ScanHistoryItem(
                    scannedAt: scannedAt,
                    scannedCode: code,
                    result: result,
                    offersResult: nil,
                    profitAlertTriggered: Bool.random() ? true : nil
                )
            )
        }

        do {
            let existing = (try? storage.allItems()) ?? []
            try storage.replace(withNewestFirst: generated + existing)
            loadInitialPage()
        } catch {
            reportStorageError("seedDummyItems", error)
        }
        return Date().timeIntervalSince(startedAt)
    }
    #endif
}
