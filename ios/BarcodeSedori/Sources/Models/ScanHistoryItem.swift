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
    /// CHANGES-v6.1.md: 検索タブで第2段階(/api/offers)取得が完了した時点で保存されるオファー一覧。
    /// 商品タブ(履歴)からの詳細表示はAPIを再度呼ばず、この保存済みデータのみで描画する。
    /// 旧形式で保存された履歴データにはこのキーが存在しないため、Optionalにして後方互換を保つ
    /// (自動合成のDecodableはOptionalプロパティのキー欠如を許容するため、旧データも履歴が消えずに読める)。
    var offersResult: OffersResult?

    init(
        id: UUID = UUID(),
        scannedAt: Date = Date(),
        scannedCode: String,
        result: SearchResult,
        offersResult: OffersResult? = nil
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
        self.offersResult = offersResult
    }
}
