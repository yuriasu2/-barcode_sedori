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

/// CHANGES-v6.1.md: Keepaグラフの期間切替セグメント(90日/1年/3年)。初期値は90日。
enum GraphRange: Int, CaseIterable, Identifiable {
    case ninetyDays = 90
    case oneYear = 365
    case threeYears = 1095

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .ninetyDays: return "90日"
        case .oneYear: return "1年"
        case .threeYears: return "3年"
        }
    }
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
    /// フリーミアム: 無料プラン&Keepa経路でオファーがPro限定ロックされている状態。
    /// このときは実データを取得せず、パネルにぼかしダミー+鍵を表示する。
    @Published var offersLocked = false

    private let apiClient: APIClient
    private let historyStore: ScanHistoryStore

    /// 直近history追加したエントリのid。第2段階(offers)完了時にこのidの履歴を更新するために保持する。
    private var pendingHistoryItemId: UUID?

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
        offersLocked = false
        pendingHistoryItemId = nil

        Task { await self.search(code: code) }
    }

    private func search(code: String) async {
        do {
            let result = try await apiClient.search(code: code)
            latestResult = result
            isSearching = false

            if result.codeType != .unresolved {
                let historyItem = ScanHistoryItem(scannedCode: code, result: result)
                pendingHistoryItemId = historyItem.id
                historyStore.add(historyItem)
            }

            // SP-APIは第1段階応答にオファーを同梱するため、第2段階(/api/offers)の通信はしない。
            // Keepa経路(offersがnil)は従来どおり第2段階で取得する。
            if let embedded = result.offers {
                offersResult = embedded
                isLoadingOffers = false
                if let pendingHistoryItemId {
                    historyStore.update(id: pendingHistoryItemId) { item in
                        item.offersResult = embedded
                    }
                }
            } else if let asin = result.asin, !asin.isEmpty {
                // Keepa経路(SP-API未接続)のオファーはPro限定(サーバーも無料は403)。
                // 無料プランは実取得せずロック表示にする。Proのみ第2段階を取得する。
                if EntitlementStore.shared.isPro {
                    await loadOffers(asin: asin, source: result.source)
                } else {
                    offersLocked = true
                }
            }
        } catch {
            isSearching = false
            searchErrorMessage = error.localizedDescription
        }
    }

    private func loadOffers(asin: String, source: String?) async {
        isLoadingOffers = true
        do {
            let offers = try await apiClient.offers(asin: asin, source: source)
            offersResult = offers

            // CHANGES-v6.1.md: 第2段階(offers)取得完了時点で、該当履歴エントリを更新して保存する。
            if let pendingHistoryItemId {
                historyStore.update(id: pendingHistoryItemId) { item in
                    item.offersResult = offers
                }
            }
        } catch {
            // オファー取得失敗はカード自体の表示を妨げないよう致命的エラーにしない。
            offersResult = nil
            print("オファー取得に失敗しました: \(error.localizedDescription)")
        }
        isLoadingOffers = false
    }
}

struct SearchTabView: View {
    /// 検索タブが選択中(表示中)かどうか。falseのときはScannerViewへ渡してカメラセッションを停止させる。
    let isActive: Bool
    @StateObject private var viewModel = SearchTabViewModel()
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var selectedResult: SearchResult?
    @State private var searchBarText: String = ""
    @State private var showsKeywordUnsupportedAlert = false
    /// フリーミアム: 各ゲート(OCR/オファー/グラフ/日次上限)から提示するペイウォール。
    @State private var showPaywall = false
    /// CHANGES-v6.1.md: Keepaグラフの期間切替。初期値は90日。
    @State private var selectedGraphRange: GraphRange = .ninetyDays

    var body: some View {
        NavigationView {
            Group {
                if entitlements.isPro {
                    // Pro: 従来どおりスクロール可能。実グラフを表示。
                    ScrollView {
                        VStack(spacing: 0) {
                            topContent
                            keepaGraph
                                .padding(.horizontal)
                        }
                    }
                } else {
                    // 無料: スクロール無効の1画面固定。下の余白を広告で埋める。
                    VStack(spacing: 0) {
                        topContent
                        freeAdArea
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    // 高さが縮んでも中央寄せで上に上がらないよう、常に上詰めで固定する。
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            // 検索バーは safeAreaInset で上部に固定する。キーボードは下部safe areaなので
            // 上部insetは影響を受けず、結果表示中でも検索バーが動かない(最も確実な固定方法)。
            .safeAreaInset(edge: .top, spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .background(Color(.systemBackground))
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            // navigationBarHiddenだけだと上部に余白が残ることがあるため、ツールバー自体を隠して詰める。
            .toolbar(.hidden, for: .navigationBar)
            .alert("キーワード検索は今後対応予定です", isPresented: $showsKeywordUnsupportedAlert) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
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
        // キーボード表示でレイアウトが上へ押し上げられ、上部の検索バーが画面外へ消えるのを防ぐ。
        // NavigationView自体に付けないと(Group等の内側では)効かないことがある。
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Pro/無料で共通の中身(カメラ・モード切替・結果カード・オファーパネル)。
    /// 検索バーは固定ヘッダーとして body 側に置くためここには含めない。
    @ViewBuilder
    private var topContent: some View {
        ScannerView(
            onScan: { scanned in
                // フリーミアム: 無料プランは1日100件まで。上限超過でペイウォール。
                if entitlements.isPro || ScanQuotaStore.shared.registerScanIfAllowed() {
                    viewModel.handleScan(scanned.code)
                } else {
                    showPaywall = true
                }
            },
            isOCRMode: viewModel.scanMode.isOCRMode,
            isActive: isActive,
            emitCooldown: entitlements.isPro ? 1.0 : 5.0
        )
        .frame(maxWidth: .infinity)
        .frame(height: UIScreen.main.bounds.height * 0.35)
        .clipped()

        modeToggle
            .padding(.horizontal)

        latestResultCard
            .padding(.horizontal)

        offersPanels
            .padding(.horizontal)
    }

    /// 無料プラン用: 鍵アイコン+Pro案内 と、余白を埋める広告。上詰めでオファー直下に配置する。
    private var freeAdArea: some View {
        VStack(spacing: 8) {
            Button {
                showPaywall = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("広告削除とKeepaグラフ表示はProで")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)

            if AdsConfig.enabled {
                BannerAdView(size: .largeBanner)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        if let selectedResult, let asin = selectedResult.asin {
            ProductDetailView(
                asin: asin,
                title: selectedResult.title,
                source: selectedResult.source,
                janCode: selectedResult.isbn13 ?? viewModel.latestScannedCode
            )
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
                // フリーミアム: OCRはPro限定。無料はロック表示し、タップでペイウォール。
                let isLocked = (mode == .ocr && !entitlements.isPro)
                Button {
                    if isLocked {
                        showPaywall = true
                    } else {
                        viewModel.scanMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.rawValue)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .background(isSelected ? Color.accentColor : Color.clear)
                    // 透明背景(Color.clear)だと文字部分しか反応しないため、セル全体を当たり判定にする。
                    .contentShape(Rectangle())
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
                    isLoading: viewModel.isLoadingOffers,
                    isLocked: viewModel.offersLocked,
                    simplePrice: viewModel.latestResult?.prices?.new,
                    simpleLabel: "新品"
                )
                .onTapGesture { handlePanelTap() }

                OffersPanelView(
                    title: "中古(出品者数\(viewModel.offersResult?.usedCount ?? viewModel.offersResult?.used?.count ?? 0)人)",
                    color: Color(red: 1.0, green: 0.60, blue: 0.0),
                    offers: viewModel.offersResult?.used ?? [],
                    isLoading: viewModel.isLoadingOffers,
                    isLocked: viewModel.offersLocked,
                    simplePrice: viewModel.latestResult?.prices?.used,
                    simpleLabel: "中古"
                )
                .onTapGesture { handlePanelTap() }
            }
        }
    }

    /// オファーパネルのタップ処理。
    /// - ロック中(無料&Keepa)はペイウォールを開く。
    /// - それ以外は source=spapi のときのみ商品詳細画面へ遷移する。
    private func handlePanelTap() {
        if viewModel.offersLocked {
            showPaywall = true
            return
        }
        guard let result = viewModel.latestResult, result.asin != nil else { return }
        guard result.source == "spapi" else { return }
        selectedResult = result
    }

    // MARK: - Keepaグラフ

    /// Keepa価格推移グラフ(Pro専用。無料は body 側で freeAdArea を表示する)。
    @ViewBuilder
    private var keepaGraph: some View {
        if let asin = viewModel.latestResult?.asin,
           let url = APIClient.shared.graphURL(asin: asin, range: selectedGraphRange.rawValue) {
            VStack(spacing: 8) {
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
                // urlが変わるたびにAsyncImageを再生成させ、期間切替時に確実に再ロードする。
                .id(url)

                graphRangeSegment
            }
        }
    }

    /// グラフ画像の直下に置く期間切替セグメント(90日/1年/3年)。
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
        // CHANGES-v6.1.md: カードの上下余白を0にし、薄灰色の囲み枠(background/cornerRadius)を削除。
        // 左右は現状維持(呼び出し元のScrollView側で.padding(.horizontal)を付与)。
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
    }
}

// MARK: - オファーパネル View

private struct OffersPanelView: View {
    let title: String
    let color: Color
    let offers: [Offer]
    let isLoading: Bool
    /// フリーミアム: 無料&Keepa経路でオファーがPro限定ロック中か。trueなら実データを出さず
    /// ぼかしダミー+鍵を表示する(簡易価格は表示する)。
    let isLocked: Bool
    /// 第1段階(/api/search)の簡易価格。オファー取得前(Keepa第2段階の読込中や取得0件)の
    /// 仮表示にのみ使う。オファーが取得できたら下のオファー一覧で上書きする。
    let simplePrice: Int?
    /// 簡易価格行のラベル("新品"/"中古")。
    let simpleLabel: String

    /// ロック時に表示するぼかしダミーのオファー行(コンディション, ダミー価格)。実データではない。
    private static let dummyOffers: [(String, String)] = [
        ("新品", "¥1,480"),
        ("非常に良い", "¥1,280"),
        ("良い", "¥980"),
    ]

    /// landed(送料込)昇順に並べたオファー。landedが無ければprice、いずれも無ければ末尾。
    private var sortedOffers: [Offer] {
        offers.sorted { lhs, rhs in
            (lhs.landed ?? lhs.price ?? Int.max) < (rhs.landed ?? rhs.price ?? Int.max)
        }
    }

    /// オファー取得前の仮表示に使う簡易価格行。
    @ViewBuilder
    private var simplePriceRow: some View {
        if let simplePrice {
            HStack(spacing: 4) {
                Text(simpleLabel)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("¥\(simplePrice)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// ロック時のぼかしダミーオファー + 鍵オーバーレイ(タップはパネルのonTapGestureでペイウォールへ)。
    private var lockedOffersTeaser: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<Self.dummyOffers.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(Self.dummyOffers[i].0)
                            .font(.caption2)
                            .foregroundColor(.white)
                        Text(Self.dummyOffers[i].1)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .blur(radius: 4)
            .accessibilityHidden(true)

            VStack(spacing: 2) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.white)
                Text("Proで表示")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
        }
    }

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

            VStack(alignment: .leading, spacing: 4) {
                if isLocked {
                    // 無料&Keepa: 簡易価格は見せ、オファー一覧はぼかしダミー+鍵でロック(タップでペイウォール)。
                    simplePriceRow
                    lockedOffersTeaser
                } else if !offers.isEmpty {
                    // オファー取得済み(SP-API一括 / Keepa第2段階): 送料込・最安値順・コンディション付きで
                    // 上から並べる。第1段階の簡易価格はここで上書きされる。
                    ForEach(sortedOffers.prefix(5)) { offer in
                        HStack(spacing: 4) {
                            Text(offer.conditionDisplayName)
                                .font(.caption2)
                                .foregroundColor(.white)
                            if let landed = offer.landed {
                                Text("¥\(landed)")
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
                } else if isLoading {
                    // Keepa第2段階の読込中: 簡易価格を仮表示しつつスピナー(オファー到着で上書き)。
                    simplePriceRow
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 8)
                        Spacer()
                    }
                } else {
                    // 取得完了だがオファー0件: 簡易価格があれば表示、無ければ空表示。
                    if simplePrice != nil {
                        simplePriceRow
                    } else {
                        Text("オファーがありません")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
            }
            .padding(8)
        }
        .background(color.opacity(0.85))
        .cornerRadius(10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
