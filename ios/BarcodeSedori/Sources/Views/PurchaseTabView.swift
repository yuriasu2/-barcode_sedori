import SwiftUI

/// 「仕入れ」タブ(Phase 1b): 仕入れリストの一覧・スワイプ削除・出品済みマーク。
/// 「出品」導線(Pro+SP-API連携時のみ・未出品行のみ)はPhase 2(ListingFormView)で追加済み。
struct PurchaseTabView: View {
    @ObservedObject private var store = PurchaseListStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationView {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("仕入れ")
        }
        .navigationViewStyle(.stack)
    }

    /// リストが空のときの案内。追加ボタンの場所(検索結果カード)へ誘導する。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cart.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("仕入れリストは空です")
                .foregroundColor(.secondary)
            Text("検索タブのスキャン結果カードから追加できます(Pro)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var listContent: some View {
        List {
            if entitlements.isPro && !settings.isSpApiLinkUsable {
                Section {
                    Text("出品するには設定タブでAmazon連携(SP-API)が必要です。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(store.items) { item in
                if entitlements.isPro && settings.isSpApiLinkUsable && !item.isListed {
                    NavigationLink {
                        ListingFormView(item: item)
                    } label: {
                        PurchaseListRow(item: item)
                    }
                } else {
                    PurchaseListRow(item: item)
                }
            }
            .onDelete { offsets in
                store.remove(atOffsets: offsets)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// 仕入れリストの1行。サムネイル+タイトル+追加日+出品済みバッジ。
struct PurchaseListRow: View {
    let item: PurchaseListItem

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: item.imageUrl.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Image(systemName: "photo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    Color.clear
                }
            }
            .frame(width: 56, height: 56)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "(タイトル不明)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: item.addedAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let rank = item.salesRank {
                        Text("ランク: \(rank)位")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if item.isListed {
                    // 出品受理済みマーク(Phase 2: markListedで付与される)。
                    Label("出品済み", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
