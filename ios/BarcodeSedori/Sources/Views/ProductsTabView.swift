import SwiftUI

/// 「商品」タブ: これまでにスキャンした履歴の一覧。
/// CHANGES-v6.1.md: 履歴タップ時はスキャン時に取得済みのデータ(SearchResult + OffersResult)のみで
/// 詳細画面を描画し、APIを再度呼び出さない。そのため選択状態はASIN文字列ではなくScanHistoryItem全体を保持する。
struct ProductsTabView: View {
    @ObservedObject private var historyStore = ScanHistoryStore.shared
    @State private var selectedItem: ScanHistoryItem?

    var body: some View {
        NavigationView {
            Group {
                if historyStore.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(historyStore.items) { item in
                            HistoryRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if item.asin != nil {
                                        selectedItem = item
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("商品")
            .toolbar {
                if !historyStore.items.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("クリア") {
                            historyStore.clear()
                        }
                    }
                }
            }
            .background {
                NavigationLink(
                    destination: destinationView,
                    isActive: Binding(
                        get: { selectedItem != nil },
                        set: { if !$0 { selectedItem = nil } }
                    ),
                    label: { EmptyView() }
                )
                .hidden()
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var destinationView: some View {
        if let selectedItem, let asin = selectedItem.asin {
            // 静的モード: スキャン時に保存済みのOffersResultのみで描画し、APIは一切呼ばない。
            // JANコードは isbn13 ?? スキャンコード。
            ProductDetailView(
                asin: asin,
                title: selectedItem.title,
                cachedOffers: selectedItem.offersResult,
                janCode: selectedItem.isbn13 ?? selectedItem.scannedCode
            )
        } else {
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("スキャン履歴はまだありません")
                .foregroundColor(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let item: ScanHistoryItem

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
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
            .frame(width: 50, height: 50)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? item.scannedCode)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(Self.dateFormatter.string(from: item.scannedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let cart = item.prices?.cart {
                Text("¥\(cart)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 4)
    }
}
