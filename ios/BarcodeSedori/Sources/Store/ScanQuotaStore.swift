import Foundation

/// 無料プランの1日あたりスキャン回数(=検索回数)を制限するストア(既定100件/日)。
/// 日付が変わればカウントをリセットする(デバイスのローカル日付基準)。
/// Pro は無制限のため呼び出し側で対象外にする。
final class ScanQuotaStore {
    static let shared = ScanQuotaStore()

    /// 無料プランの1日上限。
    static let freeDailyLimit = 100
    /// 無料プランでOCR読み取りを試せる1日上限(お試し枠)。
    static let freeOcrDailyLimit = 3

    private enum Keys {
        static let date = "scanQuota.date"   // "yyyy-MM-dd"
        static let count = "scanQuota.count"
        static let ocrDate = "scanQuota.ocrDate"
        static let ocrCount = "scanQuota.ocrCount"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// 今日の使用回数(日付が変わっていれば0)。
    var todayCount: Int {
        guard defaults.string(forKey: Keys.date) == todayString() else { return 0 }
        return defaults.integer(forKey: Keys.count)
    }

    /// 今日まだスキャン可能か(無料プラン用)。
    var canScanToday: Bool {
        todayCount < Self.freeDailyLimit
    }

    /// スキャンを1件記録する。上限内なら記録してtrue、上限到達済みならfalse(記録しない)。
    @discardableResult
    func registerScanIfAllowed() -> Bool {
        let today = todayString()
        let currentDate = defaults.string(forKey: Keys.date)
        var count = (currentDate == today) ? defaults.integer(forKey: Keys.count) : 0
        guard count < Self.freeDailyLimit else { return false }
        count += 1
        defaults.set(today, forKey: Keys.date)
        defaults.set(count, forKey: Keys.count)
        return true
    }

    // MARK: - OCR お試し枠(無料は1日 freeOcrDailyLimit 回まで)

    /// 今日のOCR使用回数(日付が変わっていれば0)。
    var ocrUsesToday: Int {
        guard defaults.string(forKey: Keys.ocrDate) == todayString() else { return 0 }
        return defaults.integer(forKey: Keys.ocrCount)
    }

    /// 今日まだ無料でOCRを使えるか。
    var canUseOcrToday: Bool {
        ocrUsesToday < Self.freeOcrDailyLimit
    }

    /// OCR読み取りを1件記録する。上限内なら記録してtrue、上限到達済みならfalse(記録しない)。
    @discardableResult
    func registerOcrUseIfAllowed() -> Bool {
        let today = todayString()
        let currentDate = defaults.string(forKey: Keys.ocrDate)
        var count = (currentDate == today) ? defaults.integer(forKey: Keys.ocrCount) : 0
        guard count < Self.freeOcrDailyLimit else { return false }
        count += 1
        defaults.set(today, forKey: Keys.ocrDate)
        defaults.set(count, forKey: Keys.ocrCount)
        return true
    }
}
