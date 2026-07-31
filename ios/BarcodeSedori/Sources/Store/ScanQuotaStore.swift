import Foundation

/// 無料枠ユニットモデル(Phase B)。サーバー(/api/search, /api/graph-data, /api/quota)が
/// 管理する1日あたりのユニット残量をミラーし、UIの即時判定(通信を待たずにゲートを出す)に使う。
/// 実際の消費可否・上限判定はサーバー側が最終的な真実であり、このストアはあくまで楽観的な
/// ローカルミラー。サーバー応答が来るたびに `apply(_:)` で是正する。
///
/// 日付境界はデバイスのローカルタイムゾーン基準(既存の `todayString()` 方式を踏襲)。
/// サーバーはUTC基準のため深夜前後でズレることがあるが、次のサーバー応答(apply)で
/// 常に是正されるため許容する。
@MainActor
final class ScanQuotaStore: ObservableObject {
    static let shared = ScanQuotaStore()

    /// 無料プランの1日あたり基礎ユニット数。
    static let baseDailyUnits = 5
    /// 無料プランでOCR読み取りを試せる1日上限(お試し枠、ユニットとは別枠)。
    static let freeOcrDailyLimit = 5

    private enum Keys {
        static let date = "scanQuota.date"   // "yyyy-MM-dd"
        static let unitsRemaining = "scanQuota.unitsRemaining"
        static let baseRemaining = "scanQuota.baseRemaining"
        static let adAvailable = "scanQuota.adAvailable"
        static let capReached = "scanQuota.capReached"
        static let ocrDate = "scanQuota.ocrDate"
        static let ocrCount = "scanQuota.ocrCount"
    }

    private let defaults: UserDefaults

    /// 本日の残ユニット数(検索・グラフ取得ミス時に消費される)。
    @Published private(set) var unitsRemaining: Int
    /// 本日の基礎枠残数(広告等での加算前の素の残量。表示用)。
    @Published private(set) var baseRemaining: Int
    /// 本日まだ広告視聴による加算枠が残っているか。
    @Published private(set) var adAvailable: Bool
    /// 本日の上限(基礎+広告加算)に到達済みか。
    @Published private(set) var capReached: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let today = Self.todayString()
        if defaults.string(forKey: Keys.date) == today {
            self.unitsRemaining = (defaults.object(forKey: Keys.unitsRemaining) as? Int) ?? Self.baseDailyUnits
            self.baseRemaining = (defaults.object(forKey: Keys.baseRemaining) as? Int) ?? Self.baseDailyUnits
            self.adAvailable = (defaults.object(forKey: Keys.adAvailable) as? Bool) ?? true
            self.capReached = defaults.bool(forKey: Keys.capReached)
        } else {
            // 日付が変わっていれば初期値(基礎枠フル)にリセットする。
            self.unitsRemaining = Self.baseDailyUnits
            self.baseRemaining = Self.baseDailyUnits
            self.adAvailable = true
            self.capReached = false
        }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// 日付が変わっていればローカルの残量を基礎枠フルへリセットする。
    /// 実際の残量はサーバー応答(apply)で追って是正される。
    func resetForNewDayIfNeeded() {
        let today = Self.todayString()
        guard defaults.string(forKey: Keys.date) != today else { return }
        unitsRemaining = Self.baseDailyUnits
        baseRemaining = Self.baseDailyUnits
        adAvailable = true
        capReached = false
        persist(date: today)
    }

    /// 今日まだ検索/グラフ取得を試せるか(ローカルミラーでの即時判定)。
    var canScanToday: Bool {
        unitsRemaining > 0
    }

    /// サーバー応答に含まれるquotaをローカルへ反映する。
    /// - `quota` が nil、または `unknown == true` のときは何もしない(サーバー障害時にローカル残量を維持するため)。
    /// - `unlimited == true`(Pro等)のときも何もしない(このストアは無料枠専用のミラーのため)。
    func apply(_ quota: QuotaInfo?) {
        guard let quota, quota.unknown != true, quota.unlimited != true else { return }

        resetForNewDayIfNeeded()

        if let unitsRemaining = quota.unitsRemaining {
            self.unitsRemaining = unitsRemaining
        }
        if let baseRemaining = quota.baseRemaining {
            self.baseRemaining = baseRemaining
        }
        if let adAvailable = quota.adAvailable {
            self.adAvailable = adAvailable
        }
        if let capReached = quota.capReached {
            self.capReached = capReached
        }
        persist(date: Self.todayString())
    }

    /// 楽観的にユニットを1消費する(サーバー応答を待たずUIへ即時反映するため)。0未満にはしない。
    /// サーバー応答が届き次第 `apply(_:)` で正確な値に是正される。
    func consumeLocally() {
        resetForNewDayIfNeeded()
        unitsRemaining = max(0, unitsRemaining - 1)
        baseRemaining = max(0, baseRemaining - 1)
        persist(date: Self.todayString())
    }

    private func persist(date: String) {
        defaults.set(date, forKey: Keys.date)
        defaults.set(unitsRemaining, forKey: Keys.unitsRemaining)
        defaults.set(baseRemaining, forKey: Keys.baseRemaining)
        defaults.set(adAvailable, forKey: Keys.adAvailable)
        defaults.set(capReached, forKey: Keys.capReached)
    }

    // MARK: - OCR お試し枠(無料は1日 freeOcrDailyLimit 回まで、ユニットとは別枠)
    //
    // SP-API連携済みユーザーは検索でユニットを消費しないため、ユニット残量では
    // OCRの利用回数を制限できない。そのためOCRは独立したカウンタで管理する。

    /// 今日のOCR使用回数(日付が変わっていれば0)。
    var ocrUsesToday: Int {
        guard defaults.string(forKey: Keys.ocrDate) == Self.todayString() else { return 0 }
        return defaults.integer(forKey: Keys.ocrCount)
    }

    /// 今日まだ無料でOCRを使えるか。
    var canUseOcrToday: Bool {
        ocrUsesToday < Self.freeOcrDailyLimit
    }

    /// OCR読み取りを1件記録する。上限内なら記録してtrue、上限到達済みならfalse(記録しない)。
    @discardableResult
    func registerOcrUseIfAllowed() -> Bool {
        let today = Self.todayString()
        let currentDate = defaults.string(forKey: Keys.ocrDate)
        var count = (currentDate == today) ? defaults.integer(forKey: Keys.ocrCount) : 0
        guard count < Self.freeOcrDailyLimit else { return false }
        count += 1
        defaults.set(today, forKey: Keys.ocrDate)
        defaults.set(count, forKey: Keys.ocrCount)
        return true
    }
}
