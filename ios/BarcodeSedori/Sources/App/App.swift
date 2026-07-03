import SwiftUI

@main
struct BarcodeSedoriApp: App {
    var body: some Scene {
        WindowGroup {
            RootContainerView()
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
