import Foundation
import AppTrackingTransparency
import AVFoundation
import UIKit

/// ATT(App Tracking Transparency)要求のタイミングを管理するコントローラ(シングルトン)。
///
/// 初回起動時(カメラ許可が決まった直後)にAppleのATTダイアログを出す。
///
/// 経緯: 以前は「検索成功4回目」まで遅らせていたが、App Reviewで2回続けて「ATTの要求が
/// 見つからない」と却下された(審査メモの手順が読まれない)。またAppleの要件は「トラッキングに
/// 使える情報を集める前に要求すること」で、広告が読み込まれた後に要求する作りは弱かった。
/// そのため起動直後に出す方式へ変えた(2026-10)。事前説明ダイアログは5.1.1で却下されたため置かない。
///
/// 注意: アプリが前面(active)でないときに要求するとダイアログが出ないまま終わる。また他の
/// システムダイアログ(カメラ許可)と重なると出ないことがあるため、カメラ許可が決まってから
/// 少し待って要求する。
@MainActor
final class AttPromptController {
    static let shared = AttPromptController()

    /// 要求中の多重呼び出しを防ぐ(起動時とscenePhase変化・カメラ許可確定が重なるため)。
    private var isRequesting = false

    /// 起動時・前面復帰時・カメラ許可確定時に呼ぶ。条件を満たしていればATTを要求する。
    /// 許可の有無に関わらず広告は表示できる(未許可時は非パーソナライズ広告)。
    func requestIfNeeded() async {
        guard AdsConfig.enabled, !isRequesting else { return }
        // 既に許可/拒否済みなら二度と出さない(OSも1アプリ1回しか出さない)。
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        // カメラ許可ダイアログと重ならないよう、カメラの可否が決まるまで待つ
        // (カメラ許可確定時に再度呼ばれる)。
        guard AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined else { return }

        isRequesting = true
        defer { isRequesting = false }

        // 直前のダイアログが閉じ切ってから出すため少し待つ。
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard UIApplication.shared.applicationState == .active,
              ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }

        // ATTダイアログとレビュー依頼が続けて出ないよう、5分間レビュー依頼を抑制する。
        ReviewPromptController.shared.recordNegativeEvent()
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
