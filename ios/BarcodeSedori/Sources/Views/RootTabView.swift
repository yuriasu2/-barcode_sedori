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
                .tabItem {
                    Label("商品", systemImage: "shippingbox")
                }
                .tag(1)

            PurchaseTabView()
                .tabItem {
                    Label("仕入れ", systemImage: "cart")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
                .tag(3)
        }
    }
}
