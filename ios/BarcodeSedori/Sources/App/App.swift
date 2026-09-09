import SwiftUI
import GoogleMobileAds

@main
struct BarcodeSedoriApp: App {
    @StateObject private var entitlements = EntitlementStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // AdMob(Google Mobile Ads)を初期化する。
        if AdsConfig.enabled {
            GADMobileAds.sharedInstance().start(completionHandler: nil)
        }
        configureTabBarAppearance()
    }

    /// タブバーの背景を不透明にする。
    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(entitlements)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await entitlements.refreshEntitlements() } }
                }
                .task {
                    // 起動時にPro状態(StoreKit)を初期化・監視開始する。
                    entitlements.start()
                    // 起動時にサーバー管理型広告設定を取得する(キャッシュ即反映→裏で更新)。
                    AdsConfigStore.shared.start()
                    // 行動ログ計測(PostHog)。APIキー未設定の間は内部で何もしない。
                    Analytics.shared.start()
                    Analytics.shared.capture(.appLaunched)
                }
        }
    }
}

/// OAuthの結果はAmazonAuthorizationSessionだけで受信する。
/// 通常のディープリンクは開発用の画面操作にのみ使用する。
private struct RootContainerView: View {

    var body: some View {
        RootTabView()
            .onOpenURL { url in
                handle(url: url)
            }
            #if DEBUG
            .task {
                applyDebugLaunchArguments()
            }
            #endif
    }

    private func handle(url: URL) {
        guard url.scheme == "barcodesedori" else { return }

        #if DEBUG
        // 開発ビルド専用のディープリンク。シミュレータではタップ・文字入力の注入が効かない環境が
        // あり画面操作を自動化できないため、コマンドから画面遷移・検索を起こせるようにする。
        //   xcrun simctl openurl booted "barcodesedori://debug-search?code=9784566034600"
        //   xcrun simctl openurl booted "barcodesedori://debug-tab?index=2"
        // `#if DEBUG` で囲っているためReleaseビルドには存在しない。
        if handleDebugURL(url) { return }
        #endif

        // 外部から直接渡されたspapi-authでは連携情報を更新しない。
    }

    #if DEBUG
    /// 開発ビルド専用: 起動引数で指定された初期状態を適用する。
    /// URLスキーム(debug-search等)はiOSが「"セラーレンズ"で開きますか?」の確認ダイアログを出しタップが必要になるため、
    /// タップ注入が使えない環境ではこちらを使う(起動引数は`-key value`形式でUserDefaultsから読める。
    /// NSArgumentDomainのため永続化されず、その起動限りで消える)。
    ///   xcrun simctl launch booted jp.sellira.sellerlens -debugForcePro YES -debugSearchCode 9784566034600
    ///   xcrun simctl launch booted jp.sellira.sellerlens -debugTab 2
    private func applyDebugLaunchArguments() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "debugForcePro") != nil {
            EntitlementStore.shared.debugForcePro = defaults.bool(forKey: "debugForcePro")
        }
        // 起動引数の値は文字列として入るため、as? Int ではなく integer(forKey:) で数値化する。
        if defaults.object(forKey: "debugTab") != nil {
            let tab = defaults.integer(forKey: "debugTab")
            if (0...3).contains(tab) {
                AppNavigation.shared.selectedTab = tab
            }
        }
        if let code = defaults.string(forKey: "debugSearchCode"), !code.isEmpty {
            AppNavigation.shared.selectedTab = 0
            AppNavigation.shared.pendingDebugSearchCode = code
        }
    }

    /// 開発ビルド専用ディープリンクを処理する。処理したらtrueを返す(通常のリンク処理へ進ませない)。
    /// - `barcodesedori://debug-search?code=<10桁or13桁>`: 検索タブへ移動して検索を実行する
    /// - `barcodesedori://debug-tab?index=<0-3>`: タブを切り替える(0=検索/1=商品/2=仕入れ/3=設定)
    /// - `barcodesedori://debug-pro?on=<1|0>`: Pro強制フラグを切り替える
    private func handleDebugURL(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch url.host {
        case "debug-search":
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return true }
            AppNavigation.shared.selectedTab = 0
            AppNavigation.shared.pendingDebugSearchCode = code
            return true
        case "debug-tab":
            if let index = items.first(where: { $0.name == "index" })?.value.flatMap(Int.init),
               (0...3).contains(index) {
                AppNavigation.shared.selectedTab = index
            }
            return true
        case "debug-pro":
            let on = items.first(where: { $0.name == "on" })?.value != "0"
            EntitlementStore.shared.debugForcePro = on
            return true
        default:
            return false
        }
    }
    #endif
}
