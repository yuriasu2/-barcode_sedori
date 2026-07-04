import SwiftUI

/// スキャンモードの見た目トグル。CHANGES-v2.md:
/// 「バーコード / インストアコード」トグル → 「バーコード / OCR」トグルに変更。
enum ScanMode: String, CaseIterable, Identifiable {
    case barcode = "バーコード"
    case ocr = "OCR"

    var id: String { rawValue }

    /// ScannerViewへ渡すisOCRModeフラグ
    var isOCRMode: Bool { self == .ocr }
}

/// CHANGES-v6.md: 検索タブ全面刷新。
/// リスト表示をやめ、最新1件のスキャン結果カード+オファーパネル+Keepaグラフの単一状態に置き換える。
@MainActor
final class SearchTabViewModel: ObservableObject {
    @Published var scanMode: ScanMode = .barcode

    /// 最新のスキャン/検索結果(第1段階: /api/search)
    @Published var latestResult: SearchResult?
    /// 最新にスキャンされたコード文字列(カード内のコード表示に使う)
    @Published var latestScannedCode: String?
    /// 検索中(第1段階)フラグ
    @Published var isSearching = false
    /// 検索(第1段階)失敗時のエラーメッセージ
    @Published var searchErrorMessage: String?

    /// オファー(第2段階: /api/offers)結果
    @Published var offersResult: OffersResult?
    /// オファー読み込み中フラグ
    @Published var isLoadingOffers = false

    private let apiClient: APIClient
    private let historyStore: ScanHistoryStore

    init(apiClient: APIClient = .shared, historyStore: ScanHistoryStore = .shared) {
        self.apiClient = apiClient
        self.historyStore = historyStore
    }

    /// スキャンされたバーコード/OCR認識コード、または検索バーから入力されたコードを処理する。
    /// 192/191始まりの除外やデデュープはScannerView側で完結しているため、
    /// ここに届いた時点でそのまま検索パイプラインへ流す。
    func handleScan(_ code: String) {
        // 新しいスキャンが来たらカード・パネル・グラフ用の状態を全てリセットしてから再取得する。
        isSearching = true
        searchErrorMessage = nil
        latestScannedCode = code
        latestResult = nil
        offersResult = nil
        isLoadingOffers = false

        Task { await self.search(code: code) }
    }

    private func search(code: String) async {
        do {
            let result = try await apiClient.search(code: code)
            latestResult = result
            isSearching = false

            if result.codeType != .unresolved {
                historyStore.add(ScanHistoryItem(scannedCode: code, result: result))
            }

            if let asin = result.asin, !asin.isEmpty {
                await loadOffers(asin: asin, source: result.source)
            }
        } catch {
            isSearching = false
            searchErrorMessage = error.localizedDescription
        }
    }

    private func loadOffers(asin: String, source: String?) async {
        isLoadingOffers = true
        do {
            offersResult = try await apiClient.offers(asin: asin, source: source)
        } catch {
            // オファー取得失敗はカード自体の表示を妨げないよう致命的エラーにしない。
            offersResult = nil
            print("オファー取得に失敗しました: \(error.localizedDescription)")
        }
        isLoadingOffers = false
    }
}

struct SearchTabView: View {
    @StateObject private var viewModel = SearchTabViewModel()
    @State private var selectedResult: SearchResult?
    @State private var searchBarText: String = ""
    @State private var showsKeywordUnsupportedAlert = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ScannerView(
                        onScan: { scanned in
                            viewModel.handleScan(scanned.code)
                        },
                        isOCRMode: viewModel.scanMode.isOCRMode
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.35)
                    .clipped()

                    modeToggle
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                    latestResultCard
                        .padding(.horizontal)
                        .padding(.top, 4)

                    offersPanels
                        .padding(.horizontal)
                        .padding(.top, 12)

                    keepaGraph
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .alert("キーワード検索は今後対応予定です", isPresented: $showsKeywordUnsupportedAlert) {
                Button("OK", role: .cancel) {}
            }
            .background {
                NavigationLink(
                    destination: destinationView,
                    isActive: Binding(
                        get: { selectedResult != nil },
                        set: { if !$0 { selectedResult = nil } }
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
        if let selectedResult, let asin = selectedResult.asin {
            ProductDetailView(asin: asin, title: selectedResult.title, source: selectedResult.source)
        } else {
            EmptyView()
        }
    }

    // MARK: - 検索バー

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("商品名、JANコードで検索", text: $searchBarText)
                .textFieldStyle(.plain)
                .onSubmit {
                    submitSearchBarText()
                }
                .submitLabel(.search)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    /// 数字のみかつ10桁または13桁ならコード検索(/api/search)、それ以外はキーワード非対応アラート。
    private func submitSearchBarText() {
        let trimmed = searchBarText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isDigitsOnly = trimmed.allSatisfy { $0.isNumber }
        let isValidLength = trimmed.count == 10 || trimmed.count == 13

        if isDigitsOnly && isValidLength {
            viewModel.handleScan(trimmed)
        } else {
            showsKeywordUnsupportedAlert = true
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach(ScanMode.allCases) { mode in
                let isSelected = viewModel.scanMode == mode
                Button {
                    viewModel.scanMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(isSelected ? .white : .accentColor)
                        .background(isSelected ? Color.accentColor : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
    }

    // MARK: - 最新スキャン結果カード

    @ViewBuilder
    private var latestResultCard: some View {
        if viewModel.isSearching {
            HStack {
                Spacer()
                ProgressView("検索中…")
                Spacer()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        } else if let result = viewModel.latestResult {
            LatestResultCardView(result: result, scannedCode: viewModel.latestScannedCode ?? "")
        } else if let errorMessage = viewModel.searchErrorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(.red)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
        } else {
            EmptyView()
        }
    }

    // MARK: - オファーパネル

    @ViewBuilder
    private var offersPanels: some View {
        if viewModel.latestResult != nil {
            HStack(alignment: .top, spacing: 12) {
                OffersPanelView(
                    title: "新品(出品者数\(viewModel.offersResult?.newCount ?? viewModel.offersResult?.new?.count ?? 0)人)",
                    color: Color(red: 0.13, green: 0.59, blue: 0.95),
                    offers: viewModel.offersResult?.new ?? [],
                    isLoading: viewModel.isLoadingOffers
                )
                .onTapGesture { handlePanelTap() }

                OffersPanelView(
                    title: "中古(出品者数\(viewModel.offersResult?.usedCount ?? viewModel.offersResult?.used?.count ?? 0)人)",
                    color: Color(red: 1.0, green: 0.60, blue: 0.0),
                    offers: viewModel.offersResult?.used ?? [],
                    isLoading: viewModel.isLoadingOffers
                )
                .onTapGesture { handlePanelTap() }
            }
        }
    }

    /// source=spapiのときのみ商品詳細画面へ遷移する。
    private func handlePanelTap() {
        guard let result = viewModel.latestResult, result.asin != nil else { return }
        guard result.source == "spapi" else { return }
        selectedResult = result
    }

    // MARK: - Keepaグラフ

    @ViewBuilder
    private var keepaGraph: some View {
        if let asin = viewModel.latestResult?.asin, let url = APIClient.shared.graphURL(asin: asin) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .cornerRadius(10)
                case .failure:
                    EmptyView()
                case .empty:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(height: 80)
                @unknown default:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - 最新スキャン結果カード View

private struct LatestResultCardView: View {
    let result: SearchResult
    let scannedCode: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: result.imageUrl.flatMap(URL.init(string:))) { phase in
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
            .frame(width: 80, height: 80)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 6) {
                if result.codeType == .unresolved {
                    Text("対応していないコードです")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                } else {
                    Text(result.title ?? "(タイトル不明)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(scannedCode)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let rank = result.salesRank {
                    Text("ランキング: \(rank)位")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

// MARK: - オファーパネル View

private struct OffersPanelView: View {
    let title: String
    let color: Color
    let offers: [Offer]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color)

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 16)
                    Spacer()
                }
            } else if offers.isEmpty {
                Text("オファーがありません")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(offers.prefix(5)) { offer in
                        HStack(spacing: 4) {
                            Text(offer.conditionDisplayName)
                                .font(.caption2)
                                .foregroundColor(.white)
                            if let price = offer.price {
                                Text("¥\(price)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else {
                                Text("-")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(color.opacity(0.85))
        .cornerRadius(10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
