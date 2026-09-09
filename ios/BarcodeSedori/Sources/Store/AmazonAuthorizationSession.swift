import AuthenticationServices
import SwiftUI

/// セッションと表示元ウィンドウを認可終了まで保持する。
@MainActor
final class AmazonAuthorizationSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isRunning = false
    @Published var message: String?
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    func start(serverURL: String) {
        guard !isRunning else { return }
        guard let url = URL(string: "\(serverURL)/oauth/login"), url.scheme == "https",
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else {
            message = "Amazon連携を開始できませんでした。画面を開き直してお試しください。"
            return
        }
        anchor = window
        let authentication = ASWebAuthenticationSession(url: url, callbackURLScheme: "barcodesedori") { [weak self] url, error in
            Task { @MainActor [weak self] in
                self?.complete(url: url, error: error)
            }
        }
        authentication.presentationContextProvider = self
        session = authentication
        isRunning = true
        if !authentication.start() {
            session = nil
            anchor = nil
            isRunning = false
            message = "Amazon連携を開始できませんでした。もう一度お試しください。"
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // start()で確保し、認可完了まで保持する。任意の別ウィンドウへは切り替えない。
        anchor!
    }

    private func complete(url: URL?, error: Error?) {
        session = nil
        anchor = nil
        isRunning = false
        if let error = error {
            if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin { return }
            message = "Amazon連携に失敗しました。もう一度お試しください。"
            return
        }
        guard let url = url, let callback = SpApiAuthorizationCallback(url: url) else {
            message = "Amazonからの認可結果を確認できませんでした。もう一度お試しください。"
            return
        }
        SettingsStore.shared.spapiRefreshToken = callback.refreshToken
        SettingsStore.shared.spapiSellerId = callback.sellerId
        SettingsStore.shared.spapiLinkEnabled = true
        Analytics.shared.capture(.amazonLinkCompleted)
        message = "SP-API連携が完了しました。"
    }
}
