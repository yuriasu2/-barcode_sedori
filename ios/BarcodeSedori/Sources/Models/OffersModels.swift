import Foundation

/// GET /api/offers?asin= の個別オファー(新品/中古共通)
struct Offer: Codable, Equatable, Identifiable {
    let condition: String?
    let price: Int?
    let shipping: Int?
    let landed: Int?
    let isBuyBox: Bool?
    let sameCount: Int?
    let breakEven: Int?

    // レスポンスにIDは無いため、内容から安定した合成IDを作る
    var id: String {
        [
            condition ?? "",
            String(price ?? -1),
            String(shipping ?? -1),
            String(landed ?? -1),
            String(isBuyBox ?? false),
            String(sameCount ?? -1),
            String(breakEven ?? -1)
        ].joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case condition, price, shipping, landed, isBuyBox, sameCount, breakEven
    }
}

/// GET /api/offers?asin= レスポンス
struct OffersResult: Codable, Equatable {
    let referencePrice: Int?
    let releaseDate: String?
    let new: [Offer]?
    let used: [Offer]?
}
