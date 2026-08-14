import Foundation
import AppTrackingTransparency

/// ATT(App Tracking Transparency)要求のタイミングと、事前説明ダイアログ(AttPrimerDialog)の
/// 表示可否を管理するコントローラ(シングルトン)。
///
/// 起動直後にATTを求めると、アプリの価値を体験する前で拒否されやすい。しかもAppleのATT
/// ダイアログは一度拒否されるとアプリ内から二度と出せない(OSが記憶する)ため、
/// 「ユーザーがある程度アプリを使い、価値を感じ始めたタイミング」まで要求そのものを遅らせ、
/// さらにその直前に「なぜ許可を求めるか」を平易な言葉で説明する事前ダイアログ(プライマー)を
/// 挟むことでオプトイン率を上げる狙い。
///
/// ReviewPromptControllerと同じ書き方に揃える(@MainActor final class、static let shared、
/// UserDefaults永続化、チューニング定数はPolicyへ集約)。
@MainActor
final class AttPromptController: ObservableObject {
    static let shared = AttPromptController()

    /// 事前説明ダイアログ(AttPrimerDialog)を表示中か。
    @Published private(set) var isShowingPrimer = false

    /// SettingsStore/ReviewPromptControllerとは別系統のキー。
    /// スキャン回数はReviewPromptController.Keys.searchCount(レビュー依頼用、閾値50)と
    /// 用途が異なる(ATTは閾値4回でごく早期に判定したい)ため、共用せず専用キーを持つ。
    private enum Keys {
        static let scanCount = "att.scanCount"
        /// 「あとで」を選んだ回数。
        static let postponeCount = "att.postponeCount"
        /// 直近に事前説明を表示した時点のscanCount。再表示までの間隔を測るために保持する。
        static let lastPrimerShownScanCount = "att.lastPrimerShownScanCount"
    }

    /// チューニング対象のポリシー定数。値を変えるときはここだけを見ればよいようにまとめる。
    private enum Policy {
        /// 事前説明を出してよくなる最低スキャン成功回数。
        static let minScanCountToShow = 4
        /// 「あとで」を選べる回数の上限。これを超えたら二度と出さない。
        /// ATTはユーザーが一度でも拒否すると(システムダイアログ側で)アプリ内から二度と
        /// 出せなくなる上、事前説明自体をしつこく出すのはユーザー体験を損ない、
        /// App Storeガイドライン(過度な許可要求の繰り返し)上も好ましくないため、
        /// 控えめに2回で打ち止めにする。
        static let maxPostponeCount = 2
        /// 「あとで」を選んだ直後にすぐ次のスキャンで再表示すると煩わしいため、
        /// 前回表示時のscanCountからこの回数分スキャンするまでは再表示しない。
        static let minScansBetweenPrimerShows = 4
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 記録

    /// 検索(スキャン)が成功するたびに呼ぶ。カウントを+1し、条件を満たせば事前説明を表示する。
    func recordScanSucceeded() {
        defaults.set(defaults.integer(forKey: Keys.scanCount) + 1, forKey: Keys.scanCount)
        evaluateShouldShowPrimer()
    }

    // MARK: - 判定

    /// 表示条件をすべて満たしていれば isShowingPrimer を true にする。
    private func evaluateShouldShowPrimer() {
        guard AdsConfig.enabled else { return }

        // 既に許可/拒否済みなら二度と出さない(未回答のときのみ判定する)。
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }

        let scanCount = defaults.integer(forKey: Keys.scanCount)
        guard scanCount >= Policy.minScanCountToShow else { return }

        // 「あとで」の上限に達していたら出さない。
        guard defaults.integer(forKey: Keys.postponeCount) < Policy.maxPostponeCount else { return }

        // 前回表示からのスキャン間隔が十分空いていなければ出さない。
        let lastShownScanCount = defaults.integer(forKey: Keys.lastPrimerShownScanCount)
        if lastShownScanCount > 0, scanCount - lastShownScanCount < Policy.minScansBetweenPrimerShows {
            return
        }

        defaults.set(scanCount, forKey: Keys.lastPrimerShownScanCount)
        isShowingPrimer = true
    }

    // MARK: - 事前説明ダイアログからの操作

    /// 事前説明の「次へ」。ダイアログを閉じ、Appleのシステムダイアログ(ATT)を要求する。
    /// 許可の有無に関わらず広告は表示できる(未許可時は非パーソナライズ広告)。
    func proceedToSystemPrompt() {
        isShowingPrimer = false
        ATTrackingManager.requestTrackingAuthorization { _ in }
    }

    /// 事前説明の「あとで」。ダイアログを閉じ、回数を記録する(上限に達したら以後表示しない)。
    func postpone() {
        isShowingPrimer = false
        defaults.set(defaults.integer(forKey: Keys.postponeCount) + 1, forKey: Keys.postponeCount)
    }
}
