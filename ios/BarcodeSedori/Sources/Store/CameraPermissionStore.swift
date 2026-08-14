import Foundation
import AVFoundation
import UIKit

/// カメラ(AVCaptureDevice)へのアクセス許可状態を監視するストア(シングルトン)。
/// NoticeStore/AttPromptControllerと同じ書き方(@MainActor final class、static let shared)に揃える。
///
/// 許可状態そのものはOSが保持しているため、このストアはキャッシュを持たず、
/// refresh()の呼び出しごとにAVCaptureDeviceへ問い合わせて@Publishedへ反映するだけの薄いラッパー。
/// 設定アプリで許可を変更してアプリへ戻ってきたときに最新化する必要があるため、
/// 呼び出し側(SearchTabView)がScenePhaseが.activeになったタイミングでrefresh()を呼ぶ。
@MainActor
final class CameraPermissionStore: ObservableObject {
    static let shared = CameraPermissionStore()

    /// 現在のカメラ許可状態。
    @Published private(set) var status: AVAuthorizationStatus

    init() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// 現在の許可状態を再取得してstatusへ反映する。
    func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// 設定アプリの本アプリ設定画面を開く。
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
