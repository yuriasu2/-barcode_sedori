import SwiftUI

/// 「仕入れ」タブ: プレースホルダ(DESIGN.md記載の通り、将来実装予定)。
struct PurchaseTabView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Image(systemName: "cart.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("仕入れ機能は準備中です")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("仕入れ")
        }
        .navigationViewStyle(.stack)
    }
}
