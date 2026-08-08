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
        configureTabBarAppearance()
        configureListAppearance()
    }

    /// iOS 15以降、見出しの無いセクションの上にも`sectionHeaderTopPadding`(既定約28pt)が
    /// 自動で入り、Form/Listの先頭がナビゲーションバーから不自然に離れて見える。
    /// 商品詳細(ScrollView、上余白12pt)と仕入れ内容(Form)の上余白を揃えるため0にする。
    /// アプリ全体のForm/Listに効くが、設定タブなども同様に詰まるだけで意図した挙動。
    private func configureListAppearance() {
        UITableView.appearance().sectionHeaderTopPadding = 0
    }

    /// タブバーの背景を透過率90%(不透明度10%)にする。
    /// SwiftUIの`.toolbarBackground(color, for:)`だけでは、iOS標準のぼかし素材
    /// (UIBlurEffect相当)が指定色の上から重なって描画され、色の不透明度を下げても
    /// 見た目上あまり透けなかった。UITabBarAppearanceで`backgroundEffect`を明示的に
    /// nilにしてぼかし素材自体を外し、`backgroundColor`の不透明度だけで透過を制御する。
    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.1)

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(entitlements)
                .task {
                    // 起動時にPro状態(StoreKit)を初期化・監視開始する。
                    entitlements.start()
                    // 起動時にサーバー管理型広告設定を取得する(キャッシュ即反映→裏で更新)。
                    AdsConfigStore.shared.start()
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
            #if DEBUG
            .task {
                applyDebugLaunchArguments()
            }
            #endif
            .alert("SP-API連携が完了しました", isPresented: $showSpApiLinkedAlert) {
                Button("OK", role: .cancel) {}
            }
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

        guard url.host == "spapi-auth" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        guard let refreshToken = items.first(where: { $0.name == "refresh_token" })?.value,
              !refreshToken.isEmpty else { return }
        SettingsStore.shared.spapiRefreshToken = refreshToken
        SettingsStore.shared.spapiLinkEnabled = true
        // selling_partner_id(公開の出品者ID)。Sellers APIからは取得不可能なため、
        // この認可コールバックで受け取れた場合のみ保存する(空なら保存しない=既存値を維持)。
        if let sellerId = items.first(where: { $0.name == "selling_partner_id" })?.value,
           !sellerId.isEmpty {
            SettingsStore.shared.spapiSellerId = sellerId
        }
        showSpApiLinkedAlert = true
    }

    #if DEBUG
    /// 開発ビルド専用: 起動引数で指定された初期状態を適用する。
    /// URLスキーム(debug-search等)はiOSが「"アマレンズ"で開きますか?」の確認ダイアログを出しタップが必要になるため、
    /// タップ注入が使えない環境ではこちらを使う(起動引数は`-key value`形式でUserDefaultsから読める。
    /// NSArgumentDomainのため永続化されず、その起動限りで消える)。
    ///   xcrun simctl launch booted com.example.barcodesedori -debugForcePro YES -debugSearchCode 9784566034600
    ///   xcrun simctl launch booted com.example.barcodesedori -debugTab 2
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
