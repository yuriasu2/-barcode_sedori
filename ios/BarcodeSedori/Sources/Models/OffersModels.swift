import Foundation

/// GET /api/offers?asin=&source= の個別オファー(新品/中古共通)。CHANGES-v6.md新契約。
/// conditionは表示用文字列ではなく正規化コード("new"|"like_new"|"very_good"|"good"|"acceptable")が入る。
struct Offer: Codable, Equatable, Identifiable {
    let condition: String?
    let price: Int?
    let shipping: Int?
    let landed: Int?
    let isBuyBox: Bool?
    /// Amazon本体の在庫か(サーバーがセラーIDで判定)。旧サーバーではキーが無いためnil。
    let isAmazon: Bool?
    let sameCount: Int?
    /// 損益分岐点。サーバー(Keepa経路)は小数(例: 5822.3)で返すためDoubleで受ける。
    /// Int?にすると小数のデコードに失敗し、オファー全体のデコードが落ちてstage-2が表示されなくなる。
    let breakEven: Double?

    // レスポンスにIDは無いため、内容から安定した合成IDを作る
    var id: String {
        [
            condition ?? "",
            String(price ?? -1),
            String(shipping ?? -1),
            String(landed ?? -1),
            String(isBuyBox ?? false),
            String(isAmazon ?? false),
            String(sameCount ?? -1),
            String(breakEven ?? -1)  // Double。id用途のため書式は問わない

        ].joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case condition, price, shipping, landed, isBuyBox, isAmazon, sameCount, breakEven
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
    /// オファーパネルの行に出すコンディション名。
    /// Amazon本体の在庫は「新品(Ama)」と表記して他の出品者と区別する。
    var panelConditionLabel: String {
        if isAmazon == true {
            return "\(conditionDisplayName)(Ama)"
        }
        return conditionDisplayName
    }

    /// パネルの価格表記。価格は送料込み(landed)で、送料があれば括弧で内訳を添える。
    /// 例: 送料257円なら「¥1200(送257)」、送料無料なら「¥1200」。landedが無ければ"-"。
    var panelPriceLabel: String {
        guard let landed else { return "-" }
        if let shipping, shipping > 0 {
            return "¥\(landed)(送\(shipping))"
        }
        return "¥\(landed)"
    }

    /// "new"→新品 / "like_new"→ほぼ新品 / "very_good"→非常に良い / "good"→良い / "acceptable"→可。
    /// 未知の値が来た場合は元の文字列をそのまま返す(クラッシュ厳禁のためフォールバック)。
    var conditionDisplayName: String {
        guard let condition else { return "" }
        switch condition {
        case "new":
            return "新品"
        case "like_new":
            return "ほぼ新"
        case "very_good":
            return "非良い"
        case "good":
            return "良い"
        case "acceptable":
            return "可"
        case "used":
            return "中古"
        default:
            return condition
        }
    }
}
