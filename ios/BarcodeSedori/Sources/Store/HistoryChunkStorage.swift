import Foundation

/// `ScanHistoryItem`を100件単位のJSONファイルへ保存する永続化層。
///
/// 旧形式の`scan_history.json`は意図的に参照しない。新形式のディレクトリだけを
/// 扱うことで、アップデート時に旧履歴を移行せず、そのまま残置できる。
final class HistoryChunkStorage {
    static let chunkSize = 100

    struct Page {
        let items: [ScanHistoryItem]
        /// 次に読むべき、より古い位置。チャンクが削除で疎になっていても
        /// チャンク内オフセットまで保持するため、記録の欠落を防げる。
        let nextCursor: Cursor?
        let totalCount: Int
    }

    struct Cursor: Equatable {
        let sequence: Int
        let offset: Int
    }

    private struct ChunkDescriptor {
        let sequence: Int
        let url: URL
    }

    private let fileManager: FileManager
    let directoryURL: URL
    private let maxItems: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedTotalCount: Int?

    init(
        directoryURL: URL,
        maxItems: Int = 5000,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.maxItems = max(1, maxItems)
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 指定ページを新しい順で読む。`cursor`がnilなら最新ページから読む。
    func loadPage(limit: Int = 100, after cursor: Cursor? = nil) throws -> Page {
        let pageLimit = max(1, limit)
        let descriptors = try chunkDescriptors(sortedDescending: true)
        let totalCount = try countValidItems(in: descriptors)
        cachedTotalCount = totalCount

        let candidates: [(descriptor: ChunkDescriptor, offset: Int)]
        if let cursor {
            candidates = descriptors.compactMap { descriptor in
                if descriptor.sequence > cursor.sequence { return nil }
                if descriptor.sequence == cursor.sequence {
                    return (descriptor, cursor.offset)
                }
                return (descriptor, 0)
            }
        } else {
            candidates = descriptors.map { ($0, 0) }
        }

        var pageItems: [ScanHistoryItem] = []
        var nextCursor: Cursor?

        for candidate in candidates {
            let descriptor = candidate.descriptor
            guard let chunkItems = try? readChunk(descriptor) else { continue }
            guard candidate.offset < chunkItems.count else { continue }

            let remaining = pageLimit - pageItems.count
            let end = min(chunkItems.count, candidate.offset + remaining)
            pageItems.append(contentsOf: chunkItems[candidate.offset..<end])

            if pageItems.count >= pageLimit {
                if end < chunkItems.count {
                    nextCursor = Cursor(sequence: descriptor.sequence, offset: end)
                } else {
                    nextCursor = descriptors
                        .first(where: { $0.sequence < descriptor.sequence })
                        .map { Cursor(sequence: $0.sequence, offset: 0) }
                }
                break
            }
        }

        return Page(
            items: pageItems,
            nextCursor: nextCursor,
            totalCount: totalCount
        )
    }

    /// すべての新形式チャンクを検索する。旧`scan_history.json`は検索対象にしない。
    func search(query: String) throws -> [ScanHistoryItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try allItems() }

        let lowerQuery = normalized.lowercased()
        let dateFormatter = Self.makeSearchDateFormatter()
        let descriptors = try chunkDescriptors(sortedDescending: true)
        var matches: [ScanHistoryItem] = []

        for descriptor in descriptors {
            guard let items = try? readChunk(descriptor) else { continue }
            matches.append(contentsOf: items.filter { item in
                if let title = item.title, title.lowercased().contains(lowerQuery) {
                    return true
                }
                let code = (item.isbn13 ?? item.scannedCode).lowercased()
                if code.contains(lowerQuery) {
                    return true
                }
                return dateFormatter.string(from: item.scannedAt).contains(normalized)
            })
        }
        return matches
    }

    /// 最新チャンクへ1件追加する。チャンク全体の再エンコードは最大100件に限定される。
    func append(_ item: ScanHistoryItem) throws {
        let descriptors = try chunkDescriptors(sortedDescending: true)
        let currentCount = try cachedCountOrCountValidItems(in: descriptors)

        if let newest = descriptors.first, let currentItems = try? readChunk(newest), currentItems.count < Self.chunkSize {
            var updated = currentItems
            updated.insert(item, at: 0)
            try writeChunk(updated, to: newest.url)
        } else {
            let nextSequence = (descriptors.map(\.sequence).max() ?? 0) + 1
            try writeChunk([item], to: chunkURL(sequence: nextSequence))
        }

        cachedTotalCount = currentCount + 1
        try trimOldestIfNeeded()
    }

    /// 指定IDの履歴を、現在未ロードの古いチャンクも含めて更新する。
    @discardableResult
    func update(id: UUID, transform: (inout ScanHistoryItem) -> Void) throws -> Bool {
        let descriptors = try chunkDescriptors(sortedDescending: true)
        for descriptor in descriptors {
            guard var items = try? readChunk(descriptor),
                  let index = items.firstIndex(where: { $0.id == id }) else { continue }
            var updated = items[index]
            transform(&updated)
            items[index] = updated
            try writeChunk(items, to: descriptor.url)
            return true
        }
        return false
    }

    /// 指定IDの履歴を削除する。チャンクの詰め直しは行わない。
    @discardableResult
    func remove(ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let descriptors = try chunkDescriptors(sortedDescending: true)
        let existingCount = try cachedCountOrCountValidItems(in: descriptors)
        var removedCount = 0

        for descriptor in descriptors {
            guard var items = try? readChunk(descriptor) else { continue }
            let before = items.count
            items.removeAll { ids.contains($0.id) }
            guard items.count != before else { continue }

            removedCount += before - items.count
            if items.isEmpty {
                try fileManager.removeItem(at: descriptor.url)
            } else {
                try writeChunk(items, to: descriptor.url)
            }
        }

        cachedTotalCount = max(0, existingCount - removedCount)
        return removedCount
    }

    /// 新形式の履歴だけを削除する。旧`scan_history.json`は触らない。
    func clear() throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        cachedTotalCount = 0
    }

    #if DEBUG
    /// 開発用ダミー生成のため、既存の新形式履歴へまとめて挿入する。
    /// 引数は新しい順に並んでいる前提で、通常の追加と同じ順序を保つ。
    func replace(withNewestFirst items: [ScanHistoryItem]) throws {
        try clear()
        let limited = Array(items.prefix(maxItems))
        guard !limited.isEmpty else { return }
        try ensureDirectory()

        let chunks = stride(from: 0, to: limited.count, by: Self.chunkSize).map { offset in
            Array(limited[offset..<min(offset + Self.chunkSize, limited.count)])
        }
        let chunkCount = chunks.count
        for (index, chunk) in chunks.enumerated() {
            let sequence = chunkCount - index
            try writeChunk(chunk, to: chunkURL(sequence: sequence))
        }
        cachedTotalCount = limited.count
    }
    #endif

    func allItems() throws -> [ScanHistoryItem] {
        let descriptors = try chunkDescriptors(sortedDescending: true)
        var result: [ScanHistoryItem] = []
        for descriptor in descriptors {
            if let items = try? readChunk(descriptor) {
                result.append(contentsOf: items)
            }
        }
        cachedTotalCount = result.count
        return result
    }

    private func cachedCountOrCountValidItems(in descriptors: [ChunkDescriptor]) throws -> Int {
        if let cachedTotalCount { return cachedTotalCount }
        let count = try countValidItems(in: descriptors)
        cachedTotalCount = count
        return count
    }

    private func countValidItems(in descriptors: [ChunkDescriptor]) throws -> Int {
        var count = 0
        for descriptor in descriptors {
            if let items = try? readChunk(descriptor) {
                count += items.count
            }
        }
        return count
    }

    private func trimOldestIfNeeded() throws {
        guard let total = cachedTotalCount, total > maxItems else { return }

        var remaining = total - maxItems
        while remaining > 0 {
            let descriptors = try chunkDescriptors(sortedDescending: false)
            guard let oldest = descriptors.first(where: { descriptor in
                guard let items = try? readChunk(descriptor) else { return false }
                return !items.isEmpty
            }) else { break }

            guard var items = try? readChunk(oldest), !items.isEmpty else { break }
            items.removeLast()
            if items.isEmpty {
                try fileManager.removeItem(at: oldest.url)
            } else {
                try writeChunk(items, to: oldest.url)
            }
            remaining -= 1
            cachedTotalCount = max(0, (cachedTotalCount ?? 0) - 1)
        }
    }

    private func chunkDescriptors(sortedDescending: Bool) throws -> [ChunkDescriptor] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let descriptors = urls.compactMap { url -> ChunkDescriptor? in
            let name = url.lastPathComponent
            guard name.hasPrefix("chunk-"), name.hasSuffix(".json") else { return nil }
            let number = name.dropFirst("chunk-".count).dropLast(".json".count)
            guard let sequence = Int(number), sequence > 0 else { return nil }
            return ChunkDescriptor(sequence: sequence, url: url)
        }
        return descriptors.sorted {
            sortedDescending ? $0.sequence > $1.sequence : $0.sequence < $1.sequence
        }
    }

    private func chunkURL(sequence: Int) -> URL {
        directoryURL.appendingPathComponent(String(format: "chunk-%08d.json", sequence))
    }

    private func readChunk(_ descriptor: ChunkDescriptor) throws -> [ScanHistoryItem] {
        let data = try Data(contentsOf: descriptor.url)
        return try decoder.decode([ScanHistoryItem].self, from: data)
    }

    private func writeChunk(_ items: [ScanHistoryItem], to url: URL) throws {
        try ensureDirectory()
        let data = try encoder.encode(items)
        try data.write(to: url, options: .atomic)
    }

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func makeSearchDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }
}
