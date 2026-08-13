import Foundation

/// サーバー管理型の障害告知・お知らせを取得し、まだ見せていなければポップアップ表示用に保持するストア(シングルトン)。
///
/// AdsConfigStoreと違い、起動時のUserDefaultsキャッシュ復元は意図的に行わない。告知は
/// 「今まさにサーバーが伝えたい最新状態」だけに意味があり、例えば「Keepa障害中」という
/// 古い告知をキャッシュから即座に復活表示してしまうと、既に復旧した後の起動でも
/// (次の refresh() が終わるまでの一瞬とはいえ)誤って表示され得る。既読管理はUserDefaultsで
/// 永続化するが、告知本文そのものはキャッシュしない。
@MainActor
final class NoticeStore: ObservableObject {
    static let shared = NoticeStore()

    /// 表示すべき告知。無ければnil。取得失敗時や既読済みのときもnilのまま。
    @Published private(set) var pending: ServerNotice?

    /// 既読(表示済み)にした告知のid。UserDefaultsキー命名はReviewPromptController/AdsConfigStoreに合わせる。
    private static let shownIdKey = "notice.lastShownId"

    /// 告知の「表示」だけを遅らせる待機時間。起動直後は他のシステムダイアログ(ATT等)と
    /// 競合するため間を空ける(SearchTabViewのレビュー依頼が2.5秒待つのと同じ理由)。
    /// 「取得」自体はこの待機の影響を受けない(refresh()参照)。
    private static let presentationDelayNanoseconds: UInt64 = 2_000_000_000

    /// 本セッションで既にrefresh()を開始したか。1セッション1回に絞るためのフラグ
    /// (ReviewPromptController.hasCheckedLaunchTriggerThisSessionと同じ考え方で、永続化しない)。
    private var hasStarted = false

    private let apiClient: APIClient
    private let defaults: UserDefaults

    init(apiClient: APIClient = .shared, defaults: UserDefaults = .standard) {
        self.apiClient = apiClient
        self.defaults = defaults
    }

    /// アプリ起動時に一度呼ぶ。二重起動防止のため2回目以降は何もしない。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await refresh() }
    }

    /// サーバーから最新の告知を取得する。取得失敗時はアプリの動作を妨げないよう何もしない
    /// (pendingはnilのまま、または前回の値を保持したままにはせずnilを維持する)。
    /// 取得できた告知が既読済みのidと同じなら、同じ告知を二度出さないよう何もしない。
    func refresh() async {
        guard let notice = try? await apiClient.fetchNotice() else { return }
        guard notice.id != defaults.string(forKey: Self.shownIdKey) else { return }

        // 障害を知らせた直後にレビュー依頼を出さないよう、既存のネガティブイベント抑制
        // (5分クールダウン)を流用する。表示を待ってから呼んだのでは、SearchTabViewが
        // 起動2.5秒後に行うレビュー判定に間に合わないため、取得できた時点で先に抑制する。
        ReviewPromptController.shared.recordNegativeEvent()

        // 表示だけ遅らせる。起動直後は他のシステムダイアログ(ATT等)と競合するため
        // (SearchTabViewのレビュー依頼が2.5秒待つのと同じ理由)。
        try? await Task.sleep(nanoseconds: Self.presentationDelayNanoseconds)
        pending = notice
    }

    /// アラートを閉じたときに呼ぶ。表示した告知のidを既読として保存し、pendingを消す。
    func markShown() {
        guard let notice = pending else { return }
        defaults.set(notice.id, forKey: Self.shownIdKey)
        pending = nil
    }
}
