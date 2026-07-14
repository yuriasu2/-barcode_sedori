import SwiftUI
import GoogleMobileAds
import AppTrackingTransparency

@main
struct BarcodeSedoriApp: App {
    @StateObject private var entitlements = EntitlementStore.shared

    init() {
        // AdMob(Google Mobile Ads)を初期化する。
        if AdsConfig.enabled {
            GADMobileAds.sharedInstance().start(completionHandler: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(entitlements)
                .task {
                    // 起動時にPro状態(StoreKit)を初期化・監視開始する。
                    entitlements.start()
                    await requestTrackingIfNeeded()
                }
        }
    }

    /// ATT(トラッキング許可)を要求する。起動直後は他のシステムダイアログと競合しやすいため少し待つ。
    /// 許可の有無に関わらず広告は表示できる(未許可時は非パーソナライズ広告)。
    private func requestTrackingIfNeeded() async {
        guard AdsConfig.enabled else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            ATTrackingManager.requestTrackingAuthorization { _ in }
        }
    }
}

/// アプリのルートコンテナ。SP-API OAuthのディープリンク(barcodesedori://spapi-auth)を
/// 受け取ってSettingsStoreに反映し、完了アラートを表示する薄いラッパー。
private struct RootContainerView: View {
    @State private var showSpApiLinkedAlert = false

    var body: some View {
        RootTabView()
            .onOpenURL { url in
                handle(url: url)
            }
            .alert("SP-API連携が完了しました", isPresented: $showSpApiLinkedAlert) {
                Button("OK", role: .cancel) {}
            }
    }

    private func handle(url: URL) {
        guard url.scheme == "barcodesedori", url.host == "spapi-auth" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        guard let refreshToken = items.first(where: { $0.name == "refresh_token" })?.value,
              !refreshToken.isEmpty else { return }
        SettingsStore.shared.spapiRefreshToken = refreshToken
        SettingsStore.shared.spapiLinkEnabled = true
        showSpApiLinkedAlert = true
    }
}
