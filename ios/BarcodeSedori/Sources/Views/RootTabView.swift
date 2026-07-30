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

            SettingsView()
                .safeAreaInset(edge: .bottom) {
                    AdSlotView(slotId: "settings_bottom", fixedHeight: 50)
                }
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
                .tag(3)
        }
    }
}
