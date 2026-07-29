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
                janCode: selectedItem.isbn13 ?? selectedItem.scannedCode,
                listPrice: selectedItem.listPrice,
                releaseDate: selectedItem.releaseDate
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

    /// 検索日の表記(例: 7/26 13:05)。年は省略して1行に収める。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    /// 表示するJANコード(ISBN-13があればそれ、無ければスキャンしたコード)。
    private var janCode: String {
        item.isbn13 ?? item.scannedCode
    }

    /// 新品の最安オファー(送料込みlandedの昇順)。保存済みオファーが無ければnil。
    private var cheapestNewOffer: Offer? {
        (item.offersResult?.new ?? []).min { ($0.landed ?? Int.max) < ($1.landed ?? Int.max) }
    }

    /// 中古の最安オファー(送料込みlandedの昇順)。保存済みオファーが無ければnil。
    private var cheapestUsedOffer: Offer? {
        (item.offersResult?.used ?? []).min { ($0.landed ?? Int.max) < ($1.landed ?? Int.max) }
    }

    /// 新品の表示文字列。Amazon本体が最安なら「新品(Ama):¥1430」と区別する。
    /// オファー未保存(Keepa経路など)は第1段階の簡易価格でフォールバックする。
    private var newPriceText: String? {
        if let offer = cheapestNewOffer, let landed = offer.landed {
            let label = offer.isAmazon == true ? "新品(Ama)" : "新品"
            return "\(label):¥\(landed)"
        }
        if let price = item.prices?.new {
            return "新品:¥\(price)"
        }
        return nil
    }

    /// 中古の表示文字列。コンディション名を添える(例: 「中古品:良い ¥640」)。
    private var usedPriceText: String? {
        if let offer = cheapestUsedOffer, let landed = offer.landed {
            let condition = offer.conditionDisplayName
            return condition.isEmpty ? "中古品:¥\(landed)" : "中古品:\(condition) ¥\(landed)"
        }
        if let price = item.prices?.used {
            return "中古品:¥\(price)"
        }
        return nil
    }

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

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.scannedCode)
                    .font(.subheadline)
                    .lineLimit(2)

                // 1行目: 検索日 / JAN / ランク。
                // JANは検索タブの結果カードと同じbarcode.viewfinder、ランクは折れ線グラフアイコンで表す。
                HStack(spacing: 8) {
                    Text("検索日:\(Self.dateFormatter.string(from: item.scannedAt))")

                    HStack(spacing: 3) {
                        Image(systemName: "barcode.viewfinder")
                        Text(janCode)
                    }

                    if let rank = item.salesRank {
                        HStack(spacing: 3) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                            Text("\(rank)位")
                        }
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                // 2行目: 新品最安 / 中古最安(いずれも取得できたものだけ出す)
                if newPriceText != nil || usedPriceText != nil {
                    HStack(spacing: 10) {
                        if let newPriceText {
                            Text(newPriceText)
                        }
                        if let usedPriceText {
                            Text(usedPriceText)
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
