import Foundation
import Combine

/// 「仕入れ」タブの仕入れリストをファイル(Documents配下のJSON)に永続化する。
/// ScanHistoryStoreと同じ方式(端末ローカルのみ・サーバー保存なし)。
final class PurchaseListStore: ObservableObject {
    static let shared = PurchaseListStore()

    @Published private(set) var items: [PurchaseListItem] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        self.fileURL = (documents ?? fileManager.temporaryDirectory).appendingPathComponent("purchase_list.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    func add(_ item: PurchaseListItem) {
        items.insert(item, at: 0)
        save()
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
