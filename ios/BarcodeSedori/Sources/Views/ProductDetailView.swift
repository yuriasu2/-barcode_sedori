import SwiftUI

@MainActor
final class ProductDetailViewModel: ObservableObject {
    @Published var offers: OffersResult?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let apiClient: APIClient
    let asin: String
    let source: String?

    init(asin: String, source: String? = nil, apiClient: APIClient = .shared) {
        self.asin = asin
        self.source = source
        self.apiClient = apiClient
    }

    func load() async {
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

    init(asin: String, title: String?, source: String? = nil) {
        _viewModel = StateObject(wrappedValue: ProductDetailViewModel(asin: asin, source: source))
        self.title = title
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
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title ?? "商品詳細")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.load()
        }
        .task {
            if viewModel.offers == nil {
                await viewModel.load()
            }
        }
    }

    private var productInfoSection: some View {
        Section("商品情報") {
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
                    Text("¥\(breakEven)")
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
