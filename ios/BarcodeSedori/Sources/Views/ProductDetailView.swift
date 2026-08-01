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

struct ProductDetailView: View {
    @StateObject private var viewModel: ProductDetailViewModel
    let title: String?
    /// 商品情報セクションの「JANコード」行に表示する値(isbn13 ?? スキャンコード)。
    let janCode: String?
    /// 定価(税込・円)。「参考価格」欄に表示する(値の意味は定価=メーカー希望小売価格)。
    let listPrice: Int?
    /// 発売日(ISO日付文字列、例:"2019-05-30")。表示時に「2019/5/30」形式へ整形する。
    let releaseDate: String?
    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var purchaseList = PurchaseListStore.shared
    /// 「仕入れリストへ追加」タップで開く仕入れフォーム(新規追加モード)の下書き。
    /// 保存(緑チェック)されるまでPurchaseListStoreへは登録しない。
    @State private var purchaseFormDraft: PurchaseListItem?
    /// 非Proが「仕入れリストへ追加」(鍵バッジ付き)をタップしたときに表示するペイウォール。
    @State private var showPaywall = false

    /// 発売日のパース用(サーバーはSP-APIの"2019-05-30"等のISO日付文字列をそのまま返す)。
    private static let releaseDateInputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 発売日の表示用(例: "2019/5/30")。
    private static let releaseDateOutputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    /// 発売日の表示文字列。パースできない/nilなら"-"。
    private var releaseDateText: String {
        guard let releaseDate, let date = Self.releaseDateInputFormatter.date(from: releaseDate) else {
            return "-"
        }
        return Self.releaseDateOutputFormatter.string(from: date)
    }

    /// 取得済みのOffersResultのみで描画する(APIは呼ばない)。
    init(asin: String, title: String?, cachedOffers: OffersResult?, janCode: String?, listPrice: Int?, releaseDate: String?) {
        _viewModel = StateObject(wrappedValue: ProductDetailViewModel(asin: asin, cachedOffers: cachedOffers))
        self.title = title
        self.janCode = janCode
        self.listPrice = listPrice
        self.releaseDate = releaseDate
    }

    var body: some View {
        List {
            productInfoSection

            if let offers = viewModel.offers {
                offersSection(title: "新品(\(offers.newCount ?? offers.new?.count ?? 0)件)", offers: offers.new ?? [])
                offersSection(title: "中古(\(offers.usedCount ?? offers.used?.count ?? 0)件)", offers: offers.used ?? [])
            } else {
                // offersがnil = スキャン時点でオファーが未取得だったケース(Keepa経路など)。
                // 再取得はしない仕様のため、その旨のみ表示する。
                Text("価格一覧は未取得です")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title ?? "商品詳細")
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

    private var productInfoSection: some View {
        Section("商品情報") {
            HStack {
                Text("JANコード")
                Spacer()
                Text(janCode ?? "-")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("参考価格")
                Spacer()
                if let listPrice {
                    Text("¥\(listPrice)")
                        .fontWeight(.semibold)
                } else {
                    Text("-")
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("発売日")
                Spacer()
                Text(releaseDateText)
                    .foregroundColor(.secondary)
            }

            // 仕入れリストへ追加。無料でもボタンは表示し、非Proは鍵バッジ付きでタップ時に
            // ペイウォールを開く(ボタンごと隠すと機能の存在に気付けないため)。
            // 商品詳細は画像URLを保持していないためimageUrlはnil(仕入れタブではプレースホルダ表示)。
            Button {
                if entitlements.isPro {
                    // まだ仕入れリストへは登録せず、仕入れフォームの下書きとしてシート表示する。
                    // 保存(緑チェック)で初めてPurchaseListStoreへ追加される。
                    purchaseFormDraft = PurchaseListItem(
                        asin: viewModel.asin,
                        title: title,
                        imageUrl: nil,
                        scannedCode: janCode,
                        isbn13: nil,
                        salesRank: nil,
                        offersResult: viewModel.offers
                    )
                } else {
                    showPaywall = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: purchaseList.contains(asin: viewModel.asin) ? "checkmark.circle.fill" : "cart.badge.plus")
                    Text(purchaseList.contains(asin: viewModel.asin) ? "仕入れリストに追加済み" : "仕入れリストへ追加")
                    if !entitlements.isPro {
                        LockIconView(size: 14)
                    }
                }
            }
            .disabled(entitlements.isPro && purchaseList.contains(asin: viewModel.asin))
        }
    }

    private func offersSection(title: String, offers: [Offer]) -> some View {
        Section(title) {
            if offers.isEmpty {
                Text("オファーがありません")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            } else {
                ForEach(offers) { offer in
                    OfferRow(offer: offer)
                }
            }
        }
    }
}

private struct OfferRow: View {
    let offer: Offer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if offer.condition != nil {
                    Text(offer.conditionDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(4)
                }
                if offer.isBuyBox == true {
                    Text("カート")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(4)
                }
                if let sameCount = offer.sameCount, sameCount > 0 {
                    Text("同(\(sameCount)件)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(4)
                }
            }

            priceDetail
        }
        .padding(.vertical, 4)
    }

    private var priceDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let price = offer.price {
                    Text("価格: ¥\(price)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let shipping = offer.shipping {
                    Text("送料: ¥\(shipping)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let landed = offer.landed {
                Text("¥\(landed)")
                    .font(.title3)
                    .fontWeight(.bold)
            }
        }
    }
}
