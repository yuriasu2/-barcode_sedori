import SwiftUI

@MainActor
final class ProductDetailViewModel: ObservableObject {
    @Published var offers: OffersResult?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let apiClient: APIClient
    let asin: String
    let source: String?
    /// CHANGES-v6.1.md: 商品タブ(履歴)から開いた場合はtrue。
    /// trueの場合、load()はAPI呼び出しを一切行わない(渡された保存済みデータのみで描画するモード)。
    let isStaticMode: Bool

    /// 通常モード(検索タブ経由): /api/offersを呼び出して表示する。
    init(asin: String, source: String? = nil, apiClient: APIClient = .shared) {
        self.asin = asin
        self.source = source
        self.apiClient = apiClient
        self.isStaticMode = false
    }

    /// 静的モード(商品タブ/履歴経由): 渡されたOffersResultのみで描画し、API呼び出しは一切行わない。
    init(asin: String, cachedOffers: OffersResult?, apiClient: APIClient = .shared) {
        self.asin = asin
        self.source = nil
        self.apiClient = apiClient
        self.isStaticMode = true
        self.offers = cachedOffers
    }

    func load() async {
        // 静的モード(履歴からの表示)ではAPIを再度呼び出さない。
        guard !isStaticMode else { return }
        isLoading = true
        errorMessage = nil
        do {
            offers = try await apiClient.offers(asin: asin, source: source)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct ProductDetailView: View {
    @StateObject private var viewModel: ProductDetailViewModel
    let title: String?
    /// 商品情報セクションの「JANコード」行に表示する値(isbn13 ?? スキャンコード)。
    let janCode: String?

    /// 通常モード(検索タブ経由): /api/offersを呼び出して表示する。
    init(asin: String, title: String?, source: String? = nil, janCode: String? = nil) {
        _viewModel = StateObject(wrappedValue: ProductDetailViewModel(asin: asin, source: source))
        self.title = title
        self.janCode = janCode
    }

    /// 静的モード(商品タブ/履歴経由): 保存済みのOffersResultのみで描画し、APIは一切呼ばない。
    init(asin: String, title: String?, cachedOffers: OffersResult?, janCode: String?) {
        _viewModel = StateObject(wrappedValue: ProductDetailViewModel(asin: asin, cachedOffers: cachedOffers))
        self.title = title
        self.janCode = janCode
    }

    var body: some View {
        List {
            productInfoSection

            if let offers = viewModel.offers {
                offersSection(title: "新品(\(offers.newCount ?? offers.new?.count ?? 0)件)", offers: offers.new ?? [])
                offersSection(title: "中古(\(offers.usedCount ?? offers.used?.count ?? 0)件)", offers: offers.used ?? [])
            } else if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            } else if viewModel.isStaticMode {
                // 静的モード(履歴)でoffersがnil = スキャン時点でoffersが未取得のまま履歴入りしたケース。
                // API呼び出しはしない仕様のため、その旨のみ表示する。
                Text("価格一覧は未取得です")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title ?? "商品詳細")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(RefreshableIfNeeded(isStaticMode: viewModel.isStaticMode) {
            await viewModel.load()
        })
        .task {
            // 静的モード(履歴経由)ではload()は即returnするだけの安全策として残すが、
            // 実質的にAPI呼び出しコードパスには入らない(load()内のguardで早期return)。
            if viewModel.offers == nil {
                await viewModel.load()
            }
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
                if let reference = viewModel.offers?.referencePrice {
                    Text("¥\(reference)")
                        .fontWeight(.semibold)
                } else {
                    Text("-")
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("発売日")
                Spacer()
                Text(viewModel.offers?.releaseDate ?? "-")
                    .foregroundColor(.secondary)
            }
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

/// 静的モード(履歴経由)では.refreshable自体を付けない(pull-to-refreshのグルグルだけ出て
/// 何も起きない見た目を避けるため)。通常モードでは従来通り.refreshableを付与する。
private struct RefreshableIfNeeded: ViewModifier {
    let isStaticMode: Bool
    let action: () async -> Void

    func body(content: Content) -> some View {
        if isStaticMode {
            content
        } else {
            content.refreshable {
                await action()
            }
        }
    }
}

private struct OfferRow: View {
    let offer: Offer

    var body: some View {
        HStack(alignment: .top) {
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

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("損益分岐点")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let breakEven = offer.breakEven {
                    Text("¥\(Int(breakEven.rounded()))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                } else {
                    Text("-")
                        .foregroundColor(.secondary)
                }
            }
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
