import Foundation

/// SKUフォーマットの部品。設定画面で並べ替え、JSON(Codable)でUserDefaultsに保存する。
/// 年月日は「仕入れリストに追加した日付」を表す(出品日ではない)。枝番が追加日基準の
/// ため、日付を出品日にすると「昨日追加の005」と「今日追加の005」を同日に出品した場合に
/// 同一SKUが生成され既存出品を上書きする事故が起きるため(計画で確定済みの帰結)。
enum SkuComponent: Codable, Equatable {
    case year4        // 追加日の年4桁 "2026"
    case year2        // 追加日の年2桁 "26"
    case month        // 追加日の月2桁 "07"
    case day          // 追加日の日2桁 "23"
    case productCode  // ASINがあればASIN、無ければJAN
    case text(String) // 自由文字(A-Za-z0-9._- のみ)
    case sequence     // 日次枝番(3桁ゼロ埋め)。自動付与ではなく部品として任意の位置に置ける
    case quantity     // 数量(ゼロ埋めなし)

    // 注意: Identifiableは意図的に付けない。同じ部品を複数置ける(例: 区切り"-"を2箇所)ため
    // 内容ベースのIDは必ず重複し、ForEach/.onMoveが誤動作する。一覧表示は位置(offset)をIDにすること。

    /// 部品追加メニューや一覧表示用のラベル。
    var displayName: String {
        switch self {
        case .year4: return "年(4桁)"
        case .year2: return "年(2桁)"
        case .month: return "月"
        case .day: return "日"
        case .productCode: return "商品コード"
        case .text: return "自由文字"
        case .sequence: return "枝番"
        case .quantity: return "数量"
        }
    }
}

/// 出品SKUの自動生成。部品(SkuComponent)を並べた書式で組み立てる純粋関数。
/// 枝番(.sequence)は自動付与ではなく部品の一つであり、フォーマットに含めなければ出力に現れない。
/// 連番の永続化はPurchaseListStore側で行い、ここは純粋関数のみ(swiftc単体検証のため)。
enum SkuGenerator {
    /// 日付部分(yyyyMMdd)。端末ローカルのタイムゾーン・グレゴリオ暦で固定フォーマット。
    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// 旧形式との互換用。`AMLZ-YYYYMMDD-連番`(連番は3桁ゼロ埋め)を組み立てる。
    static func make(dateString: String, sequence: Int) -> String {
        String(format: "AMLZ-%@-%03d", dateString, sequence)
    }

    /// 次の連番を計算する。日付が変わったら1にリセット、同日なら+1。
    static func nextSequence(lastDateString: String?, lastSequence: Int, todayString: String) -> Int {
        if lastDateString == todayString {
            return lastSequence + 1
        }
        return 1
    }

    /// 部品列からSKU文字列を組み立てる。枝番(.sequence)・数量(.quantity)も部品の一つであり、
    /// フォーマットに含めない限り出力には現れない(自動付与は行わない)。
    /// 区切りが欲しい場合は自由文字部品で"-"などを置ける。
    /// 40文字(サーバー制約 `/^[A-Za-z0-9._-]{1,40}$/`)を超えても切り詰めず、そのまま返す
    /// (設定画面側で警告表示する方針。送信時はサーバーが400で弾く)。
    static func build(
        components: [SkuComponent],
        addedDate: Date,
        asin: String?,
        jan: String?,
        sequence: Int,
        quantity: Int
    ) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: addedDate)
        let month = calendar.component(.month, from: addedDate)
        let day = calendar.component(.day, from: addedDate)

        return components.map { component -> String in
            switch component {
            case .year4:
                return String(format: "%04d", year)
            case .year2:
                return String(format: "%02d", year % 100)
            case .month:
                return String(format: "%02d", month)
            case .day:
                return String(format: "%02d", day)
            case .productCode:
                // asinはPurchaseListItem側が非Optional(空文字あり得る)のため、空文字も「無し」として扱い
                // JANへフォールバックする(?? だけだと空文字がそのまま採用されてしまう)。
                if let asin, !asin.isEmpty {
                    return asin
                }
                return jan ?? ""
            case .text(let value):
                return value
            case .sequence:
                return String(format: "%03d", sequence)
            case .quantity:
                return String(quantity)
            }
        }.joined()
    }
}
