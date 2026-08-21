import SwiftUI

/// TabView: 検索 / 商品(スキャン履歴) / 仕入れ(プレースホルダ) / 設定
struct RootTabView: View {
    @ObservedObject private var nav = AppNavigation.shared
    /// Amazon連携シート用のViewModel。設定タブのSettingsViewが持つインスタンスとは別物だが、
    /// 接続テストの結果アラートはAmazonLinkSettingsView自身に付いているためこれで完結する。
    @StateObject private var amazonLinkViewModel = SettingsViewModel()
    /// 障害告知・お知らせポップアップの表示状態。
    @ObservedObject private var noticeStore = NoticeStore.shared

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
                    Label("履歴", systemImage: "shippingbox")
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
        // タブバーの外観(不透明)はBarcodeSedoriApp.configureTabBarAppearance()で設定済み
        // (ここでtoolbarBackgroundを重ねると二重に色が乗って見た目がズレるため設定しない)。
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

            // 障害告知は即座に取得を開始する(表示の遅延はNoticeStore.refresh()側で行う)。
            // 取得を遅らせるとレビュー抑制(recordNegativeEvent)がSearchTabViewの2.5秒後の
            // 判定に間に合わなくなるため、取得自体は待たない。
            NoticeStore.shared.start()
        }
        // NoticeStore.pendingはprivate(set)のため、$noticeStore.pendingで直接バインドできない。
        // 読み取りはpendingから、閉じる操作はNoticePopupViewのonCloseに渡すmarkShown()の
        // 1箇所のみに集約する。
        .overlay {
            if let notice = noticeStore.pending {
                NoticePopupView(notice: notice) {
                    NoticeStore.shared.markShown()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: noticeStore.pending)
    }
}
