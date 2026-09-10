import Foundation

@main
struct HistoryChunkStorageTests {
    static func main() throws {
        try testChunksAndPages()
        try testLegacyFileIsIgnored()
        try testSearchUpdateAndDeleteAcrossChunks()
        try testMaximumCountTrimsOldestRecords()
        print("HistoryChunkStorage: chunking, paging, legacy isolation, search, mutation and trimming passed")
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sellerlens-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeItem(_ index: Int, title: String? = nil) -> ScanHistoryItem {
        let code = String(format: "490000000%04d", index)
        let result = SearchResult(
            codeType: .jan,
            asin: String(format: "ASIN%06d", index),
            title: title ?? "商品 \(index)",
            isbn13: nil,
            imageUrl: nil,
            salesRank: index,
            releaseDate: nil,
            modelNumber: nil,
            prices: nil,
            source: "keepa",
            offers: nil,
            profitInputs: nil,
            quota: nil,
            keepaDebug: nil
        )
        return ScanHistoryItem(
            id: UUID(),
            scannedAt: Date(timeIntervalSince1970: Double(index)),
            scannedCode: code,
            result: result
        )
    }

    private static func collectAll(_ storage: HistoryChunkStorage) throws -> [ScanHistoryItem] {
        var result: [ScanHistoryItem] = []
        var page = try storage.loadPage(limit: 100)
        result.append(contentsOf: page.items)
        while let cursor = page.nextCursor {
            page = try storage.loadPage(limit: 100, after: cursor)
            result.append(contentsOf: page.items)
        }
        return result
    }

    private static func testChunksAndPages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HistoryChunkStorage(directoryURL: directory, maxItems: 5000)
        for index in 0..<250 {
            try storage.append(makeItem(index))
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("chunk-") && $0.hasSuffix(".json") }
        precondition(files.count == 3, "250 records must use three chunks")

        let all = try collectAll(storage)
        precondition(all.count == 250)
        precondition(all.map { $0.salesRank ?? -1 } == Array(stride(from: 249, through: 0, by: -1)), "records must be newest first")
        precondition(Set(all.map { $0.id }).count == 250, "pages must not duplicate records")
    }

    private static func testLegacyFileIsIgnored() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let legacyURL = parent.appendingPathComponent("scan_history.json")
        try Data("this legacy file must never be decoded".utf8).write(to: legacyURL)

        let storage = HistoryChunkStorage(directoryURL: parent.appendingPathComponent("scan_history", isDirectory: true), maxItems: 5000)
        let page = try storage.loadPage(limit: 100)
        precondition(page.items.isEmpty, "legacy scan_history.json must be ignored")
        precondition(FileManager.default.fileExists(atPath: legacyURL.path), "legacy file must remain untouched")
    }

    private static func testSearchUpdateAndDeleteAcrossChunks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HistoryChunkStorage(directoryURL: directory, maxItems: 5000)
        var items: [ScanHistoryItem] = []
        for index in 0..<250 {
            let item = makeItem(index, title: index == 2 ? "old needle product" : "商品 (index)")
            items.append(item)
            try storage.append(item)
        }

        let matches = try storage.search(query: "needle")
        precondition(matches.count == 1 && matches[0].id == items[2].id, "search must inspect older chunks")

        try storage.update(id: items[2].id) { item in
            item.profitAlertTriggered = true
        }
        let updated = try storage.search(query: "needle")
        precondition(updated.first?.profitAlertTriggered == true, "update must reach an unloaded chunk")

        let removed = try storage.remove(ids: Set([items[2].id, items[101].id]))
        precondition(removed == 2)
        let matchesAfterDelete = try storage.search(query: "needle")
        precondition(matchesAfterDelete.isEmpty, "deleted records must not remain searchable")
        let allAfterDelete = try collectAll(storage)
        precondition(allAfterDelete.count == 248)
    }

    private static func testMaximumCountTrimsOldestRecords() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HistoryChunkStorage(directoryURL: directory, maxItems: 5000)
        var items: [ScanHistoryItem] = []
        for index in 0...5000 {
            let item = makeItem(index)
            items.append(item)
            try storage.append(item)
        }

        let all = try collectAll(storage)
        precondition(all.count == 5000, "storage must enforce the maximum count")
        precondition(!all.contains(where: { $0.id == items[0].id }), "oldest record must be trimmed")
        precondition(all.first?.id == items[5000].id)
    }
}
