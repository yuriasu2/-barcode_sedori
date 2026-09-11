import Foundation

@main
struct GraphArchiveTests {
    static func main() throws {
        try testStorePublishesTheStoredASIN()
        print("GraphArchive: store notification passed")
    }

    private static func testStorePublishesTheStoredASIN() throws {
        let asin = "TEST\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let graph = try JSONDecoder().decode(
            GraphData.self,
            from: Data(#"{"series":{"amazon":[],"new":[],"used":[],"rank":[],"newCount":[],"usedCount":[],"collectibleCount":[]},"quota":null,"_keepaDebug":null}"#.utf8)
        )

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("graphs-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let notificationExpectation = NotificationExpectation()
        let observer = NotificationCenter.default.addObserver(
            forName: GraphArchive.didStoreNotification,
            object: nil,
            queue: nil
        ) { notification in
            notificationExpectation.asin = notification.userInfo?[GraphArchive.storedASINUserInfoKey] as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        GraphArchive.store(graph, for: asin)

        precondition(notificationExpectation.asin == asin,
                     "storing a graph must notify listeners of the stored ASIN")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(asin).json"))
    }
}

private final class NotificationExpectation {
    var asin: String?
}
