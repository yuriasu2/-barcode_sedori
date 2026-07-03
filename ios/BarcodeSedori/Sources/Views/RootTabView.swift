import SwiftUI

/// TabView: 検索 / 商品(スキャン履歴) / 仕入れ(プレースホルダ) / 設定
struct RootTabView: View {
    var body: some View {
        TabView {
            SearchTabView()
                .tabItem {
                    Label("検索", systemImage: "barcode.viewfinder")
                }

            ProductsTabView()
                .tabItem {
                    Label("商品", systemImage: "shippingbox")
                }

            PurchaseTabView()
                .tabItem {
                    Label("仕入れ", systemImage: "cart")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
    }
}
