import Foundation

/// GET /api/offers?asin=&source= の個別オファー(新品/中古共通)。CHANGES-v6.md新契約。
/// conditionは表示用文字列ではなく正規化コード("new"|"like_new"|"very_good"|"good"|"acceptable")が入る。
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

/// GET /api/offers?asin=&source= レスポンス(CHANGES-v6.md新契約)。
/// 例:
/// {
///   "source": "keepa",
///   "referencePrice": 1700,
///   "newCount": 6, "usedCount": 6,
///   "new":  [ {"price":1500,"shipping":0,"landed":1500,"condition":"new","isBuyBox":false,"breakEven":1230} ],
///   "used": [ {"price":1200,"shipping":350,"landed":1550,"condition":"good"} ]
/// }
struct OffersResult: Codable, Equatable {
    let source: String?
    let referencePrice: Int?
    let newCount: Int?
    let usedCount: Int?
    /// 新契約のJSON例には存在しないが、既存の発売日表示のためオプショナルのまま維持する。
    let releaseDate: String?
    let new: [Offer]?
    let used: [Offer]?
}

/// condition正規化コード → 表示名の変換。
extension Offer {
    /// "new"→新品 / "like_new"→ほぼ新品 / "very_good"→非常に良い / "good"→良い / "acceptable"→可。
    /// 未知の値が来た場合は元の文字列をそのまま返す(クラッシュ厳禁のためフォールバック)。
    var conditionDisplayName: String {
        guard let condition else { return "" }
        switch condition {
        case "new":
            return "新品"
        case "like_new":
            return "ほぼ新品"
        case "very_good":
            return "非常に良い"
        case "good":
            return "良い"
        case "acceptable":
            return "可"
        default:
            return condition
        }
    }
}
