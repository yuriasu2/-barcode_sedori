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

@MainActor
final class SearchTabViewModel: ObservableObject {
    @Published var rows: [SearchRow] = []
    @Published var scanMode: ScanMode = .barcode

    private let apiClient: APIClient
    private let historyStore: ScanHistoryStore

    init(apiClient: APIClient = .shared, historyStore: ScanHistoryStore = .shared) {
        self.apiClient = apiClient
        self.historyStore = historyStore
    }

    /// スキャンされたバーコード/OCR認識コードを処理する。
    /// 192/191始まりの除外やデデュープはScannerView側で完結しているため、
    /// ここに届いた時点でそのまま検索パイプラインへ流す。
    func handleScan(_ code: String) {
        insertLoadingRow(for: code)
        Task { await self.search(code: code) }
    }

    private func insertLoadingRow(for code: String) {
        let row = SearchRow(scannedCode: code, state: .loading)
        rows.insert(row, at: 0)
    }

    private func search(code: String) async {
        do {
            let result = try await apiClient.search(code: code)
            replaceRow(scannedCode: code, with: .loaded(result))

            if result.codeType != .unresolved {
                historyStore.add(ScanHistoryItem(scannedCode: code, result: result))
            }
        } catch {
            replaceRow(scannedCode: code, with: .failed(error.localizedDescription))
        }
    }

    private func replaceRow(scannedCode: String, with state: SearchRowState) {
        guard let index = rows.firstIndex(where: { $0.scannedCode == scannedCode && isLoading($0.state) }) else {
            // 該当するローディング行が見つからない場合は先頭に追加
            rows.insert(SearchRow(scannedCode: scannedCode, state: state), at: 0)
            return
        }
        rows[index].state = state
    }

    private func isLoading(_ state: SearchRowState) -> Bool {
        if case .loading = state { return true }
        return false
    }
}

struct SearchTabView: View {
    @StateObject private var viewModel = SearchTabViewModel()
    @State private var selectedResult: SearchResult?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScannerView(
                    onScan: { scanned in
                        viewModel.handleScan(scanned.code)
                    },
                    isOCRMode: viewModel.scanMode.isOCRMode
                )
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.height * 0.42)
                .clipped()

                modeToggle
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                resultList
            }
            .navigationTitle("検索")
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
            ProductDetailView(asin: asin, title: selectedResult.title)
        } else {
            EmptyView()
        }
    }

    private var modeToggle: some View {
        Picker("スキャンモード", selection: $viewModel.scanMode) {
            ForEach(ScanMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var resultList: some View {
        List {
            ForEach(viewModel.rows) { row in
                rowView(for: row)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if case .loaded(let result) = row.state, result.asin != nil {
                            selectedResult = result
                        }
                    }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func rowView(for row: SearchRow) -> some View {
        switch row.state {
        case .loading:
            LoadingResultRow(code: row.scannedCode)
        case .loaded(let result):
            SearchResultRow(result: result)
        case .failed(let message):
            FailedResultRow(code: row.scannedCode, message: message)
        }
    }
}

// MARK: - Rows

private struct LoadingResultRow: View {
    let code: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("検索中…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(code)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct FailedResultRow: View {
    let code: String
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.red)
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("取得失敗")
                    .font(.subheadline)
                    .foregroundColor(.red)
                Text(code)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SearchResultRow: View {
    let result: SearchResult

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
            .frame(width: 60, height: 60)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                if result.codeType == .unresolved {
                    Text("対応していないコードです")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                } else {
                    HStack(spacing: 6) {
                        Text(result.title ?? "(タイトル不明)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let isbn = result.isbn13 {
                            Text("ISBN: \(isbn)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let rank = result.salesRank {
                            Text("ランキング: \(rank)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    priceLine
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var priceLine: some View {
        HStack(spacing: 12) {
            priceBlock(label: "カート", price: result.prices?.cart, points: result.prices?.points?.cart)
            priceBlock(label: "新品", price: result.prices?.new, points: result.prices?.points?.new)
            priceBlock(label: "中古", price: result.prices?.used, points: result.prices?.points?.used)
        }
    }

    private func priceBlock(label: String, price: Int?, points: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            if let price {
                Text("¥\(price)")
                    .font(.caption)
                    .fontWeight(.semibold)
            } else {
                Text("-")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let points {
                Text("+\(points)pt")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
    }
}
