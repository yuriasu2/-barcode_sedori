import Foundation
import AppTrackingTransparency

/// ATT(App Tracking Transparency)要求のタイミングを管理するコントローラ(シングルトン)。
///
/// 起動直後にATTを求めると、アプリの価値を体験する前で拒否されやすい。しかもAppleのATT
/// ダイアログは一度拒否されるとアプリ内から二度と出せない(OSが記憶する)ため、
/// 「ユーザーがある程度アプリを使い、価値を感じ始めたタイミング」(検索成功4回目)まで遅らせる。
///
/// 以前はATTの直前に独自の事前説明ダイアログ(「次へ」「あとで」)を挟んでいたが、App Review(5.1.1)で
/// 「あとで」による先送りが許可への誘導とみなされ却下された(2026-10)。「あとで」を消すと事前説明は
/// ATTダイアログ自身の説明文(NSUserTrackingUsageDescription)と同じ内容を繰り返すだけになるため、
/// 事前説明ごと廃止し、Appleのダイアログを直接出す。
///
/// ReviewPromptControllerと同じ書き方に揃える(@MainActor final class、static let shared、
/// UserDefaults永続化、チューニング定数はPolicyへ集約)。
@MainActor
final class AttPromptController {
    static let shared = AttPromptController()

    /// SettingsStore/ReviewPromptControllerとは別系統のキー。
    /// スキャン回数はReviewPromptController.Keys.searchCount(レビュー依頼用)と
    /// 用途が異なる(ATTは閾値4回でごく早期に判定したい)ため、共用せず専用キーを持つ。
    private enum Keys {
        static let scanCount = "att.scanCount"
    }

    /// チューニング対象のポリシー定数。値を変えるときはここだけを見ればよいようにまとめる。
    private enum Policy {
        /// ATTを要求してよくなる最低スキャン成功回数。
        static let minScanCountToRequest = 4
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 検索(スキャン)が成功するたびに呼ぶ。カウントを+1し、条件を満たせばATTを要求する。
    func recordScanSucceeded() {
        defaults.set(defaults.integer(forKey: Keys.scanCount) + 1, forKey: Keys.scanCount)
        requestIfNeeded()
    }

    /// 条件をすべて満たしていればAppleのATTダイアログを要求する。
    /// 許可の有無に関わらず広告は表示できる(未許可時は非パーソナライズ広告)。
    private func requestIfNeeded() {
        guard AdsConfig.enabled else { return }

        // 既に許可/拒否済みなら二度と出さない(未回答のときのみ判定する)。
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }

        guard defaults.integer(forKey: Keys.scanCount) >= Policy.minScanCountToRequest else { return }

        // ATTダイアログとレビュー依頼が続けて出ないよう、5分間レビュー依頼を抑制する。
        ReviewPromptController.shared.recordNegativeEvent()
        ATTrackingManager.requestTrackingAuthorization { _ in }
    }
}
