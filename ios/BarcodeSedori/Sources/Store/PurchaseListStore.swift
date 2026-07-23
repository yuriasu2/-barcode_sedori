import Foundation
import Combine

/// 「仕入れ」タブの仕入れリストをファイル(Documents配下のJSON)に永続化する。
/// ScanHistoryStoreと同じ方式(端末ローカルのみ・サーバー保存なし)。
final class PurchaseListStore: ObservableObject {
    static let shared = PurchaseListStore()

    /// SKU枝番の日次連番。仕入れリストに追加した順に採番し、追加日が変わったらリセットする
    /// (出品日基準の設定タブskuLastDate/skuLastSequenceとは別系統のキー)。
    private enum SequenceKeys {
        static let lastDate = "purchaseList.skuSeqLastDate"
        static let lastSequence = "purchaseList.skuSeqLastSequence"
    }

    @Published private(set) var items: [PurchaseListItem] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let defaults: UserDefaults

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        self.fileURL = (documents ?? fileManager.temporaryDirectory).appendingPathComponent("purchase_list.json")
        self.defaults = defaults

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    /// 仕入れリストに追加する。SKU枝番はここで採番して焼き込む(追加順・追加日基準)。
    func add(_ item: PurchaseListItem) {
        var item = item
        item.skuSequenceDate = SkuGenerator.dateString(from: item.addedAt)
        item.skuSequence = nextSequence(for: item.addedAt)
        items.insert(item, at: 0)
        save()
    }

    /// 旧データ(採番導入前に追加された項目)にSKU枝番が無い場合に遅延採番する。
    /// 採番日は「採番した日」(=このメソッドを呼んだ日。仕様上、追加日が既に失われているため)。
    /// 採番済みなら何もしない(冪等)。
    @discardableResult
    func assignSkuSequenceIfNeeded(id: UUID, now: Date = Date()) -> PurchaseListItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if items[index].skuSequence != nil {
            return items[index]
        }
        items[index].skuSequenceDate = SkuGenerator.dateString(from: now)
        items[index].skuSequence = nextSequence(for: now)
        save()
        return items[index]
    }

    /// SKU枝番の日次連番を進めて返す(追加順=単調増加。削除しても詰めない)。
    private func nextSequence(for date: Date) -> Int {
        let today = SkuGenerator.dateString(from: date)
        let lastDate = defaults.string(forKey: SequenceKeys.lastDate)
        let lastSequence = defaults.integer(forKey: SequenceKeys.lastSequence)
        let sequence = SkuGenerator.nextSequence(
            lastDateString: lastDate,
            lastSequence: lastSequence,
            todayString: today
        )
        defaults.set(today, forKey: SequenceKeys.lastDate)
        defaults.set(sequence, forKey: SequenceKeys.lastSequence)
        return sequence
    }

    /// スワイプ削除(ForEach.onDelete)用。
    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    /// 出品受理(ACCEPTED)時に呼ぶ。該当項目に出品済みマークとSKUを付ける。
    func markListed(id: UUID, sku: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isListed = true
        items[index].listedSku = sku
        items[index].listedAt = Date()
        save()
    }

    /// 同一ASINが既にリストにあるか(追加ボタンの「追加済み」表示に使う)。
    func contains(asin: String) -> Bool {
        items.contains { $0.asin == asin }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([PurchaseListItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
