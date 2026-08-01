import SwiftUI

/// 「商品」タブ: これまでにスキャンした履歴の一覧。
/// CHANGES-v6.1.md: 履歴タップ時はスキャン時に取得済みのデータ(SearchResult + OffersResult)のみで
/// 詳細画面を描画し、APIを再度呼び出さない。そのため選択状態はASIN文字列ではなくScanHistoryItem全体を保持する。
struct ProductsTabView: View {
    @ObservedObject private var historyStore = ScanHistoryStore.shared
    @ObservedObject private var purchaseListStore = PurchaseListStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var selectedItem: ScanHistoryItem?
    /// 非Proが仕入れへの一括追加(鍵バッジ付き)をタップしたときに表示するペイウォール。
    @State private var showPaywall = false

    // 注意: @Environment(\.editMode)はList(selection:)の実際の編集状態と同期しない事象を確認したため
    // (EditButtonの見た目・Listの選択UIは変化するのに環境値の読み取りがfalseのままになる)、
    // 選択モードは自前の@Stateで管理し、Listへは.environment(\.editMode:)で明示的に反映する。
    @State private var isSelecting = false
    @State private var selectedIds = Set<UUID>()
    /// ヘッダーの検索BOXに入力中のクエリ(タイトル・JAN・日付「M/d」に部分一致)。
    @State private var searchQuery = ""
    @State private var showDeleteConfirm = false
    @State private var addResult: AddToPurchaseResult?

    /// 検索フィルタでの日付一致判定用(M/d形式)。行表示のdateFormatter(M/d HH:mm)とは別に用意する。
    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    /// 検索クエリに一致する履歴だけを残す(タイトル・JAN・日付「M/d」の部分一致・大文字小文字無視)。
    /// クエリが空なら全件。選択・全選択・削除・仕入れへの追加もこの表示中の集合だけを対象にする。
    private var filteredItems: [ScanHistoryItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return historyStore.items }
        let lowerQuery = query.lowercased()
        return historyStore.items.filter { item in
            if let title = item.title, title.lowercased().contains(lowerQuery) {
                return true
            }
            let jan = item.isbn13 ?? item.scannedCode
            if jan.lowercased().contains(lowerQuery) {
                return true
            }
            let dateText = Self.searchDateFormatter.string(from: item.scannedAt)
            return dateText.contains(query)
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if historyStore.items.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        header

                        List(selection: $selectedIds) {
                            ForEach(filteredItems) { item in
                                if isSelecting {
                                    HistoryRow(item: item)
                                } else {
                                    HistoryRow(item: item)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if item.asin != nil {
                                                selectedItem = item
                                            }
                                        }
                                }
                            }
                        }
                        .listStyle(.plain)
                        // isSelecting@Stateをこの階層のeditMode環境値へ明示的に反映する(自前トグルのため)。
                        // Listの複数選択チェックマークUIはこの環境値がactiveのときのみ表示される。
                        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // 選択モード中はTabViewのタブバーを隠す。隠さないと(このiOSのタブバー統合デザインでは)
            // オプション行の両端ボタンがタブ項目のヒットテスト領域と重なり、タップがタブ切替に
            // 奪われて押せなくなる事象を確認したための対策(仕入れタブと同じ対策)。
            .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
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
        .confirmationDialog(
            "選択した\(selectedIds.count)件を削除しますか?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                historyStore.remove(ids: selectedIds)
                selectedIds.removeAll()
                // 選択モードを終了する(addSelectedToPurchaseList()と同じ後処理)。
                // これを忘れると、全件削除でリストが空になった際にemptyStateへ切り替わり、
                // isSelecting=trueのままタブバーが隠れた(.toolbar(isSelecting ? .hidden : ...))
                // 状態で戻る手段が無くなり操作不能になる不具合があった。
                isSelecting = false
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(item: $addResult) { result in
            Alert(
                title: Text("追加が完了しました"),
                message: Text(result.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    /// 通常モードは検索BOX+選択ボタン、選択モードはオプション行に切り替わる。
    @ViewBuilder
    private var header: some View {
        if isSelecting {
            selectionOptionsRow
        } else {
            searchRow
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            searchField
            if !filteredItems.isEmpty {
                Button("選択") {
                    isSelecting = true
                }
                .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("タイトル、月/日、JANで検索", text: $searchQuery)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    /// 選択モードのオプション行。戻る+すべて選択を左、アクション(削除・仕入れに追加)を右に置く。
    private var selectionOptionsRow: some View {
        HStack(spacing: 16) {
            Button {
                isSelecting = false
                selectedIds.removeAll()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .foregroundColor(.blue)

            Button(selectedIds.count == filteredItems.count ? "全解除" : "すべて選択") {
                if selectedIds.count == filteredItems.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(filteredItems.map(\.id))
                }
            }
            .foregroundColor(.blue)

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .foregroundColor(selectedIds.isEmpty ? .gray : .red)
            .disabled(selectedIds.isEmpty)

            // 仕入れへの一括追加(Pro限定)。無料はボタンを隠さず、鍵バッジを重ねて
            // タップ時にペイウォールを開く(選択済み件数はある前提で機能の存在を知らせる)。
            Button {
                if entitlements.isPro {
                    addSelectedToPurchaseList()
                } else {
                    showPaywall = true
                }
            } label: {
                Image(systemName: "cart.badge.plus")
                    .overlay(alignment: .topTrailing) {
                        if !entitlements.isPro {
                            LockIconView(size: 12)
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .foregroundColor(selectedIds.isEmpty ? .gray : .blue)
            .disabled(entitlements.isPro && selectedIds.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 選択中の履歴を仕入れリストへ追加する。ASINが無い項目・既に同じASINが仕入れリストに
    /// 登録済みの項目はスキップする。終了後はアラートで件数を知らせ、選択モードを終了する。
    private func addSelectedToPurchaseList() {
        let targets = filteredItems.filter { selectedIds.contains($0.id) }
        var addedCount = 0
        var skippedCount = 0
        for item in targets {
            guard let asin = item.asin, !purchaseListStore.contains(asin: asin) else {
                skippedCount += 1
                continue
            }
            purchaseListStore.add(PurchaseListItem(
                asin: asin,
                title: item.title,
                imageUrl: item.imageUrl,
                scannedCode: item.scannedCode,
                isbn13: item.isbn13,
                salesRank: item.salesRank,
                offersResult: item.offersResult
            ))
            addedCount += 1
        }
        addResult = AddToPurchaseResult(addedCount: addedCount, skippedCount: skippedCount)
        isSelecting = false
        selectedIds.removeAll()
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

/// 仕入れリストへの一括追加結果アラート用。
private struct AddToPurchaseResult: Identifiable {
    let id = UUID()
    let addedCount: Int
    let skippedCount: Int

    /// アラート本文: 「N件を仕入れリストへ追加しました」+スキップがあれば理由を添える。
    var message: String {
        var text = "\(addedCount)件を仕入れリストへ追加しました"
        if skippedCount > 0 {
            text += "\n(\(skippedCount)件は追加済み/ASINなしのためスキップ)"
        }
        return text
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
