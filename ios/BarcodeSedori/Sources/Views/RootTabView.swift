import SwiftUI

/// TabView: 検索 / 商品(スキャン履歴) / 仕入れ(プレースホルダ) / 設定
struct RootTabView: View {
    @ObservedObject private var nav = AppNavigation.shared
    /// Amazon連携シート用のViewModel。設定タブのSettingsViewが持つインスタンスとは別物だが、
    /// 接続テストの結果アラートはAmazonLinkSettingsView自身に付いているためこれで完結する。
    @StateObject private var amazonLinkViewModel = SettingsViewModel()

    var body: some View {
        TabView(selection: $nav.selectedTab) {
            SearchTabView(isActive: nav.selectedTab == 0)
                .tabItem {
                    Label("検索", systemImage: "barcode.viewfinder")
                }
                .tag(0)

            ProductsTabView()
                // タブバー直上に固定の広告枠(50pt)。中身が無ければ枠ごと出ない(AdSlotView側でEmptyView)。
                .safeAreaInset(edge: .bottom) {
                    AdSlotView(slotId: "products_bottom", fixedHeight: 50)
                }
                .tabItem {
                    Label("商品", systemImage: "shippingbox")
                }
                .tag(1)

            PurchaseTabView()
                .safeAreaInset(edge: .bottom) {
                    AdSlotView(slotId: "purchase_bottom", fixedHeight: 50)
                }
                .tabItem {
                    Label("仕入れ", systemImage: "cart")
                }
                .tag(2)

            // 設定タブの広告枠は画面上部に置くため、SettingsView内部(NavigationViewの中)で持つ。
            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
                .tag(3)
        }
        // タブバーの透過率(90%)はBarcodeSedoriApp.configureTabBarAppearance()で
        // UITabBarAppearance経由により設定済み(ここでtoolbarBackgroundを重ねると
        // 二重に色が乗って見た目がズレるため設定しない)。
        // Amazon連携画面。Pro案内・枠切れオーバーレイ・オファーロックなど、どの画面からでも
        // 同じ導線で開けるようTabViewの外側(=常に描画されている場所)から提示する。
        .sheet(isPresented: $nav.opensAmazonLink) {
            NavigationView {
                AmazonLinkSettingsView(viewModel: amazonLinkViewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { nav.opensAmazonLink = false }
                        }
                    }
            }
            .navigationViewStyle(.stack)
        }
        .task {
            // レビュー依頼の起動日数カウンタ。recordLaunchは暦日単位で冪等
            // (同日内に再描画等で複数回呼ばれても2重加算しない)なので毎回呼んでよい。
            ReviewPromptController.shared.recordLaunch()

            // 起動時にサーバー権威のお試し期限を最新化する(SettingsStore側のキャッシュ更新)。
            // 未連携ならメソッド内でガードされ何もしない。
            await SettingsStore.shared.refreshSpApiTrialStatusIfNeeded()
        }
    }
}
