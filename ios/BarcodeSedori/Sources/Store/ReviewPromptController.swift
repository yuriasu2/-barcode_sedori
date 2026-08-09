import Foundation

/// App Store レビュー依頼(SKStoreReviewController相当)を「満足度が高いと推測できる瞬間」に
/// 限定して出すためのポリシー・カウンタ管理。
///
/// 実際のダイアログ表示はこのクラスからは行わない。iOS 16+ の `@Environment(\.requestReview)`
/// を呼び出し側(SwiftUI View)で使う(UIWindowScene探索やiOS 18でのSKStoreReviewController
/// 非推奨化を避けられる、Appleが推奨する経路のため)。このクラスはUserDefaultsのカウンタを
/// 読み書きし、「今、依頼してよいか」を判定するだけ。
///
/// 重要な制約: アプリはレビューダイアログが実際に画面へ出たかどうかを検知できない
/// (最終的に出すかどうかはシステム側の裁量で、iOS側が既にAppleの回数上限に達していれば
/// 何も表示せず無音で終わる)。そのため「出した」ではなく「依頼した(requestReview()を呼んだ)」
/// ことだけを記録し、クールダウンや上限もすべて依頼の試行回数を基準に判定する。
///
/// `@MainActor` にも `ObservableObject` にもしない。PurchaseListStoreなどmain actor隔離
/// されていないStoreからも呼べる必要があるため、状態はUserDefaultsとプレーンなプロパティのみで持つ。
final class ReviewPromptController {
    static let shared = ReviewPromptController()

    /// レビュー依頼のトリガー種別。呼び出し元の記録用(現状ポリシーはトリガー種別で分岐しないが、
    /// 将来トリガーごとに条件を変える余地を残すため引数として残す)。
    enum Trigger {
        case bulkListingSuccess
        case launch
    }

    /// SettingsStore(利用者向け設定)とは別系統のキー。これらは内部カウンタであり
    /// 利用者が直接触る設定値ではないため混ぜない(PurchaseListStoreのSequenceKeysと同じ考え方)。
    private enum Keys {
        static let searchCount = "review.searchCount"
        static let purchaseAddCount = "review.purchaseAddCount"
        static let bulkListingSuccessCount = "review.bulkListingSuccessCount"
        static let activeDayCount = "review.activeDayCount"
        static let lastActiveDay = "review.lastActiveDay"
        static let requestHistory = "review.requestHistory"
        static let lastRequestedVersion = "review.lastRequestedVersion"
    }

    /// チューニング対象のポリシー定数。値を変えるときはここだけを見ればよいようにまとめる。
    private enum Policy {
        /// 利用バー: 累計検索回数。
        static let minSearchCount = 50
        /// 利用バー: 起動した日数(のべ日数ではなく異なる暦日の数)。
        static let minActiveDayCount = 3
        /// 利用バー: 仕入れリストへの累計追加件数(こちらかbulkListingSuccessCountのどちらかを満たせばよい)。
        static let minPurchaseAddCount = 5
        /// 利用バー: 一括出品が全件成功した累計回数(こちらかpurchaseAddCountのどちらかを満たせばよい)。
        static let minBulkListingSuccessCount = 1
        /// 直近のネガティブイベント(エラー・枠枯渇・ペイウォール・リワード広告)から
        /// この秒数以内は依頼しない。5分。
        static let negativeEventCooldownSeconds: TimeInterval = 5 * 60
        /// 前回の依頼からこの秒数が経つまで再依頼しない。120日。
        static let requestCooldownSeconds: TimeInterval = 120 * 24 * 60 * 60
        /// 直近365日以内の依頼回数がこの値未満のときのみ依頼できる。
        /// Apple自身のハード上限は3回/365日だが、その手前で意図的に止める。2回。
        static let maxRequestsPerYear = 2
        /// 依頼履歴を切り詰める・年間上限を数える対象期間。365日。
        static let yearWindowSeconds: TimeInterval = 365 * 24 * 60 * 60
    }

    /// 前回のネガティブイベント発生時刻。セッションをまたいで持ち越す意味が無い
    /// (前回セッションでの失敗を今回のセッションまで引きずってブロックし続けるのは過剰なため)
    /// ため、意図的に永続化しない。
    private var lastNegativeEventAt: Date?
    /// 起動トリガーのチェックを本セッションで既に行ったか。1セッション1回だけに絞るための
    /// フラグで、これも永続化しない(次回起動でまたfalseから始まってよい)。
    private var hasCheckedLaunchTriggerThisSession = false

    /// 複数のStoreから非同期に呼ばれ得るため、カウンタの読み書きを直列化する。
    private let lock = NSLock()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 記録

    /// 起動のたびに呼ぶ。暦日が変わっていたときだけactiveDayCountを進める
    /// (同じ日に何度起動しても2重加算しない)。
    func recordLaunch() {
        lock.lock()
        defer { lock.unlock() }
        let today = Self.dayString(from: Date())
        guard defaults.string(forKey: Keys.lastActiveDay) != today else { return }
        defaults.set(today, forKey: Keys.lastActiveDay)
        defaults.set(defaults.integer(forKey: Keys.activeDayCount) + 1, forKey: Keys.activeDayCount)
    }

    /// 検索(/api/search)が成功するたびに呼ぶ。
    func recordSearchSucceeded() {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: Keys.searchCount) + 1, forKey: Keys.searchCount)
    }

    /// 仕入れリストへ追加するたびに呼ぶ(検索タブ・商品タブ一括追加・仕入れフォームの3経路共通)。
    func recordPurchaseListAdd() {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: Keys.purchaseAddCount) + 1, forKey: Keys.purchaseAddCount)
    }

    /// 一括出品が全件成功したときに呼ぶ(一部でも失敗を含む場合は呼ばない)。
    func recordBulkListingSuccess() {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: Keys.bulkListingSuccessCount) + 1, forKey: Keys.bulkListingSuccessCount)
    }

    /// ネガティブイベント(エラー・枠枯渇・ペイウォール表示・リワード広告視聴)の発生時に呼ぶ。
    /// 満足度が下がっている可能性がある瞬間にレビューを求めないためのブレーキ。
    func recordNegativeEvent() {
        lock.lock()
        defer { lock.unlock() }
        lastNegativeEventAt = Date()
    }

    /// 起動トリガー(launch)のチェックを行ってよいか。1セッションにつき最初の1回だけtrueを返し、
    /// 以降は同じセッション中ずっとfalseを返す(呼び出し側でのガード用)。
    func shouldCheckLaunchTrigger() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasCheckedLaunchTriggerThisSession else { return false }
        hasCheckedLaunchTriggerThisSession = true
        return true
    }

    // MARK: - 判定

    /// レビュー依頼を今出してよいかを判定する、このクラスの中核ロジック。
    /// 条件を全て満たすときだけtrueを返し、その場でアトミックに「依頼した」ことを記録する
    /// (依頼履歴へ現在時刻を追加し、依頼バージョンを更新する)。
    /// 1つでも満たさなければfalseを返し、何も記録しない。
    ///
    /// 呼び出し側はtrueが返ったときだけ`@Environment(\.requestReview)`を呼ぶこと。
    func consumeEligibility(trigger: Trigger) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        // 1. 利用バー: ある程度アプリを使い込んでいることが確認できて初めて依頼する。
        let searchCount = defaults.integer(forKey: Keys.searchCount)
        let activeDayCount = defaults.integer(forKey: Keys.activeDayCount)
        let purchaseAddCount = defaults.integer(forKey: Keys.purchaseAddCount)
        let bulkListingSuccessCount = defaults.integer(forKey: Keys.bulkListingSuccessCount)
        guard searchCount >= Policy.minSearchCount,
              activeDayCount >= Policy.minActiveDayCount,
              (purchaseAddCount >= Policy.minPurchaseAddCount
                || bulkListingSuccessCount >= Policy.minBulkListingSuccessCount)
        else {
            return false
        }

        // 2. 直近にネガティブイベントが起きていないこと。
        if let lastNegativeEventAt, now.timeIntervalSince(lastNegativeEventAt) < Policy.negativeEventCooldownSeconds {
            return false
        }

        var history = loadRequestHistory()

        // 3. クールダウン: 前回の依頼から十分に間が空いていること。
        if let lastRequestedAt = history.max(), now.timeIntervalSince(Date(timeIntervalSince1970: lastRequestedAt)) < Policy.requestCooldownSeconds {
            return false
        }

        // 4. 年間上限: 直近365日以内の依頼回数がまだ上限未満であること。
        let yearWindowStart = now.addingTimeInterval(-Policy.yearWindowSeconds)
        let requestsInTrailingYear = history.filter { Date(timeIntervalSince1970: $0) >= yearWindowStart }.count
        guard requestsInTrailingYear < Policy.maxRequestsPerYear else { return false }

        // 5. バージョン上限: 同一バージョン内で2度依頼しない。
        let currentVersion = Self.currentAppVersion()
        if defaults.string(forKey: Keys.lastRequestedVersion) == currentVersion {
            return false
        }

        // 全条件を満たした: ここで「依頼した」ことをアトミックに記録する。
        history.append(now.timeIntervalSince1970)
        saveRequestHistory(prune(history: history, now: now))
        defaults.set(currentVersion, forKey: Keys.lastRequestedVersion)

        return true
    }

    // MARK: - 内部ヘルパー

    private func loadRequestHistory() -> [Double] {
        (defaults.array(forKey: Keys.requestHistory) as? [Double]) ?? []
    }

    private func saveRequestHistory(_ history: [Double]) {
        defaults.set(history, forKey: Keys.requestHistory)
    }

    /// 直近365日(yearWindowSeconds)より古いエントリを取り除く。無限に増え続けないようにするため、
    /// 書き込みのたびに行う。
    private func prune(history: [Double], now: Date) -> [Double] {
        let windowStart = now.addingTimeInterval(-Policy.yearWindowSeconds)
        return history.filter { Date(timeIntervalSince1970: $0) >= windowStart }
    }

    /// 端末ローカルのタイムゾーン・グレゴリオ暦での日付文字列(yyyy-MM-dd)。
    /// ScanQuotaStoreのtodayString()と同じ作法。
    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
