import Foundation

/// 「商品」タブに表示するスキャン履歴の1件。
/// 検索結果(SearchResult)にスキャン時刻とスキャンしたコードそのものを付与して保存する。
struct ScanHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let scannedAt: Date
    let scannedCode: String
    let codeType: CodeType
    let asin: String?
    let title: String?
    let isbn13: String?
    let imageUrl: String?
    let salesRank: Int?
    let prices: SearchPrices?

    init(
        id: UUID = UUID(),
        scannedAt: Date = Date(),
        scannedCode: String,
        result: SearchResult
    ) {
        self.id = id
        self.scannedAt = scannedAt
        self.scannedCode = scannedCode
        self.codeType = result.codeType
        self.asin = result.asin
        self.title = result.title
        self.isbn13 = result.isbn13
        self.imageUrl = result.imageUrl
        self.salesRank = result.salesRank
        self.prices = result.prices
    }
}
