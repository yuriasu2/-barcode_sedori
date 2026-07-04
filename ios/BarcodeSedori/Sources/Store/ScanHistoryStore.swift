import Foundation
import Combine

/// 「商品」タブに表示するスキャン履歴をファイル(Documents配下のJSON)に永続化する。
final class ScanHistoryStore: ObservableObject {
    static let shared = ScanHistoryStore()

    @Published private(set) var items: [ScanHistoryItem] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        self.fileURL = (documents ?? fileManager.temporaryDirectory).appendingPathComponent("scan_history.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    func add(_ item: ScanHistoryItem) {
        items.insert(item, at: 0)
        save()
    }

    /// 指定したidの履歴エントリを更新する(見つからなければ何もしない)。
    /// CHANGES-v6.1.md: 検索タブで第2段階(offers)取得が完了した時点で、
    /// 該当履歴エントリにOffersResultを追記保存するために使用する。
    func update(id: UUID, transform: (inout ScanHistoryItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items[index]
        transform(&updated)
        items[index] = updated
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([ScanHistoryItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
