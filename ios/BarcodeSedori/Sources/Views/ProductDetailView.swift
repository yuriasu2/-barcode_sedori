import SwiftUI

@MainActor
final class ProductDetailViewModel: ObservableObject {
    @Published var offers: OffersResult?

    let asin: String

    /// 検索タブ・商品タブ(履歴)のどちらから開いても、取得済みのOffersResultのみで描画する。
    /// 検索時に/api/searchへ同梱されたオファーが手元にあるため、別リクエストでの再取得はしない
    /// (旧第2段階/api/offersエンドポイントは撤去済み。無駄なAmazonへのリクエストと待ち時間を無くす)。
    init(asin: String, cachedOffers: OffersResult?) {
        self.asin = asin
        self.offers = cachedOffers
    }
}

/// 商品詳細画面。検索画面の結果カードと同じコンパクトな構成
/// (画像+タイトル → 情報行 → 新品/中古パネル → グラフ)で表示する。
/// リンクボタン(仕/a/m/楽 等)は置かない(ユーザー指示 2026-08-02)。
struct ProductDetailView: View {
    @StateObject private var viewModel: ProductDetailViewModel
    /// ASIN。情報グリッドの「ASIN」欄に出す(JANの無い商品でも識別できるようにするため)。
    let asin: String?
    let title: String?
    /// 商品画像URL(検索結果/履歴の保存値)。無ければプレースホルダを出す。
    let imageUrl: String?
    /// 商品情報の「JANコード」行に表示する値(isbn13 ?? スキャンコード)。
    let janCode: String?
    /// ランキング(salesRank)。「ランキング 〇〇位」行に表示する。
    let salesRank: Int?
    /// 定価(税込・円)。「参考価格」欄に表示する(値の意味は定価=メーカー希望小売価格)。
    let listPrice: Int?
    /// 発売日(ISO日付文字列、例:"2019-05-30")。表示時に「2019/5/30」形式へ整形する。
    let releaseDate: String?
    /// /api/searchの簡易価格(新品/中古の最安値)。オファー未取得時のパネル仮表示に使う。
    let prices: SearchPrices?
    /// 検索日(履歴の`scannedAt`)。情報グリッドの右下セルに出す。
    let scannedAt: Date?

    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var purchaseList = PurchaseListStore.shared
    /// 「仕入れリストへ追加」タップで開く仕入れフォーム(新規追加モード)の下書き。
    /// 保存(緑チェック)されるまでPurchaseListStoreへは登録しない。
    @State private var purchaseFormDraft: PurchaseListItem?
    /// 非Proが「仕入れリストへ追加」(鍵バッジ付き)をタップしたときに表示するペイウォール。
    @State private var showPaywall = false
    /// グラフの期間切替(検索画面と同じセグメント)。
    @State private var selectedGraphRange: GraphRange = .threeMonths

    /// 取得済みのOffersResultのみで描画する(APIは呼ばない)。
    init(
        asin: String,
        title: String?,
        imageUrl: String?,
        cachedOffers: OffersResult?,
        janCode: String?,
        salesRank: Int?,
        listPrice: Int?,
        releaseDate: String?,
        prices: SearchPrices?,
        scannedAt: Date?
    ) {
        _viewModel = StateObject(wrappedValue: ProductDetailViewModel(asin: asin, cachedOffers: cachedOffers))
        self.asin = asin
        self.title = title
        self.imageUrl = imageUrl
        self.janCode = janCode
        self.salesRank = salesRank
        self.listPrice = listPrice
        self.releaseDate = releaseDate
        self.prices = prices
        self.scannedAt = scannedAt
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ProductSummaryHeader(
                    imageUrl: imageUrl,
                    title: title,
                    jan: janCode,
                    asin: asin,
                    salesRank: salesRank,
                    listPrice: listPrice,
                    releaseDate: releaseDate,
                    dateLabel: "検索日",
                    date: scannedAt
                )
                offersPanels
                addToPurchaseButton
                graphSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("商品詳細")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $purchaseFormDraft) { draft in
            NavigationView {
                PurchaseFormView(mode: .add(draft: draft))
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - オファーパネル(検索画面と同じ見た目)

    /// パネルタイトル。出品者数が取得できていれば併記する(検索画面と同じ書式)。
    private func panelTitle(base: String, sellerCount: Int?) -> String {
        guard let sellerCount else { return base }
        return "\(base)(出品者数\(sellerCount)人)"
    }

    private var offersPanels: some View {
        HStack(alignment: .top, spacing: 12) {
            OffersPanelView(
                title: panelTitle(
                    base: "新品",
                    sellerCount: viewModel.offers?.newCount ?? viewModel.offers?.new?.count
                ),
                color: OffersPanelColors.newBlue,
                offers: viewModel.offers?.new ?? [],
                isLoading: false,
                // オファー未保存(Keepa経路の検索履歴など)は検索画面と同じロック表示
                // (簡易価格+ぼかしダミー。Amazon連携で見られることの案内を兼ねる)。
                isLocked: viewModel.offers == nil,
                simplePrice: prices?.new,
                simpleLabel: "新品",
                isShippingKnown: viewModel.offers?.source == "spapi"
            )

            OffersPanelView(
                title: panelTitle(
                    base: "中古",
                    sellerCount: viewModel.offers?.usedCount ?? viewModel.offers?.used?.count
                ),
                color: OffersPanelColors.usedOrange,
                offers: viewModel.offers?.used ?? [],
                isLoading: false,
                isLocked: viewModel.offers == nil,
                simplePrice: prices?.used,
                simpleLabel: "中古",
                isShippingKnown: viewModel.offers?.source == "spapi"
            )
        }
    }

    // MARK: - 仕入れリストへ追加

    /// 仕入れリストへ追加。無料でもボタンは表示し、非Proは鍵バッジ付きでタップ時に
    /// ペイウォールを開く(ボタンごと隠すと機能の存在に気付けないため)。
    private var addToPurchaseButton: some View {
        Button {
            if entitlements.isPro {
                // まだ仕入れリストへは登録せず、仕入れフォームの下書きとしてシート表示する。
                // 保存(緑チェック)で初めてPurchaseListStoreへ追加される。
                purchaseFormDraft = PurchaseListItem(
                    asin: viewModel.asin,
                    title: title,
                    imageUrl: imageUrl,
                    scannedCode: janCode,
                    isbn13: nil,
                    salesRank: salesRank,
                    offersResult: viewModel.offers
                )
            } else {
                showPaywall = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isInPurchaseList ? "checkmark.circle.fill" : "cart.badge.plus")
                Text(isInPurchaseList ? "仕入れリストに追加済み" : "仕入れリストへ追加")
                    .fontWeight(.semibold)
                if !entitlements.isPro {
                    LockIconView(size: 14)
                }
            }
            .font(.subheadline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                // 検索画面の「仕」ボタンと同じ青系。追加済みはグレーにして押せないことを示す。
                isInPurchaseList
                    ? AnyShapeStyle(Color.gray.opacity(0.55))
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [OffersPanelColors.newBlue, OffersPanelColors.newBlue.darkened(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(entitlements.isPro && isInPurchaseList)
    }

    private var isInPurchaseList: Bool {
        purchaseList.contains(asin: viewModel.asin)
    }

    // MARK: - 価格推移グラフ

    /// 価格推移グラフ。検索時に取得したセッション内キャッシュがあるときだけ、
    /// 検索画面と同じチャート(+凡例+期間切替)をそのまま表示する。
    /// キャッシュが無い場合は再取得せず案内のみ出す(Keepaトークンを追加消費しないため)。
    @ViewBuilder
    private var graphSection: some View {
        if PriceHistoryChartView.dataCache[viewModel.asin] != nil {
            VStack(spacing: 6) {
                // キャッシュ済みのためPriceHistoryChartViewは通信せず即描画される。
                // チャート本体・凡例(メイン/出品者数とも)はPriceHistoryChartView側で描画する。
                PriceHistoryChartView(asin: viewModel.asin, range: selectedGraphRange)
                graphRangeSegment
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
        } else {
            Text("グラフは検索時に取得してないため表示できません。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(14)
        }
    }

    /// グラフ直下の期間切替セグメント(検索画面と同じ)。期間切替はキャッシュ済みデータの
    /// フィルタのみで通信は発生しない。
    private var graphRangeSegment: some View {
        HStack(spacing: 0) {
            ForEach(GraphRange.allCases) { range in
                let isSelected = selectedGraphRange == range
                Button {
                    selectedGraphRange = range
                } label: {
                    Text(range.label)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(isSelected ? .white : .accentColor)
                        .background(isSelected ? Color.accentColor : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 1)
        )
    }
}
