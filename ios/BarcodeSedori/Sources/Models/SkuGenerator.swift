import Foundation

/// 出品SKUの自動生成: `AMLZ-YYYYMMDD-連番`(連番は日付ごとに1から、3桁ゼロ埋め)。
/// 連番の永続化はSettingsStore側で行い、ここは純粋関数のみ(swiftc単体検証のため)。
enum SkuGenerator {
    /// 日付部分(yyyyMMdd)。端末ローカルのタイムゾーン・グレゴリオ暦で固定フォーマット。
    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// SKU文字列を組み立てる。連番は3桁ゼロ埋め(1000以上はそのまま桁を伸ばす)。
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
}
