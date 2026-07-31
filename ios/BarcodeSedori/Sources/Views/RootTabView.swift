import SwiftUI

/// TabView: 検索 / 商品(スキャン履歴) / 仕入れ(プレースホルダ) / 設定
struct RootTabView: View {
    @ObservedObject private var nav = AppNavigation.shared

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
        // タブバーの背景を透過率90%(不透明度10%)にし、裏のコンテンツが透けて見えるようにする。
        // アイコン/ラベル自体は不透明のまま(.opacity()をTabViewへ直接かけると
        // タブの中身ごと薄くなってしまうため、背景だけをtoolbarBackgroundで差し替える)。
        // toolbarBackgroundVisibility(iOS18+)はデプロイターゲット(iOS16)で使えないため、
        // .toolbarBackground(color, for:)に不透明色以外を渡すだけで表示は有効になる。
        .toolbarBackground(Color(.systemBackground).opacity(0.1), for: .tabBar)
    }
}
