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

    // 選択モードは自前の@Stateで管理する。履歴一覧はListの選択機能に依存せず、
    // 行タップでselectedIdsを更新する。
    @State private var isSelecting = false
    @State private var selectedIds = Set<UUID>()
    /// ヘッダーの検索BOXに入力中のクエリ(タイトル・JAN・日付「M/d」に部分一致)。
    @State private var searchQuery = ""
    /// 検索時だけ全チャンクから取得した結果。通常表示はhistoryStore.itemsのページを使う。
    @State private var searchResults: [ScanHistoryItem] = []
    @State private var isSearching = false
    @State private var showDeleteConfirm = false
    @State private var addResult: AddToPurchaseResult?

    /// 現在表示する履歴。空の検索時は最新ページから読み込んだ一覧、
    /// 検索時は全チャンクを走査した結果を使う。
    private var displayedItems: [ScanHistoryItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? historyStore.items : searchResults
    }

    var body: some View {
        NavigationView {
            Group {
                if historyStore.items.isEmpty && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        header

                        if isSearching {
                            ProgressView("検索中…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && displayedItems.isEmpty {
                            noSearchResults
                        } else {
                            historyList
                        }
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
        .task(id: searchQuery) {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                searchResults = []
                isSearching = false
                historyStore.resetToNewestPage()
                return
            }

            isSearching = true
            let results = await historyStore.search(query: query)
            guard !Task.isCancelled,
                  searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                return
            }
            searchResults = results
            isSearching = false
        }
    }

    /// 履歴行のタップ処理。選択モードでは選択状態を手動で切り替え、通常モードでは詳細を開く。
    private func handleRowTap(_ item: ScanHistoryItem) {
        if isSelecting {
            if selectedIds.contains(item.id) {
                selectedIds.remove(item.id)
            } else {
                selectedIds.insert(item.id)
            }
        } else if item.asin != nil {
            selectedItem = item
        }
    }

    /// iOS 16のListで画面外から先頭へ追加した履歴のセル内容が更新されないため、
    /// 履歴一覧はListのセル再利用経路を使わずLazyVStackで遅延表示する。
    private var historyList: some View {
        let items = displayedItems
        let lastItemID = items.last?.id

        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        if isSelecting {
                            Image(systemName: selectedIds.contains(item.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .font(.title3)
                                .foregroundColor(selectedIds.contains(item.id) ? .blue : .secondary)
                                .frame(width: 24)
                        }

                        HistoryRow(item: item)
                    }
                    .padding(.horizontal, isSelecting ? 12 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { handleRowTap(item) }
                    .onAppear {
                        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              item.id == lastItemID else { return }
                        _ = historyStore.loadMore()
                    }

                    if item.id != lastItemID {
                        Divider()
                            .padding(.leading, isSelecting ? 40 : 0)
                    }
                }
            }
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
            if !displayedItems.isEmpty {
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

            Button(selectedIds.count == displayedItems.count ? "全解除" : "すべて選択") {
                if selectedIds.count == displayedItems.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(displayedItems.map(\.id))
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
                    ReviewPromptController.shared.recordNegativeEvent()
                    Analytics.shared.capture(.paywallShown(trigger: .bulkAddToPurchaseListLock))
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
        let targets = displayedItems.filter { selectedIds.contains($0.id) }
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
                listPrice: item.listPrice,
                releaseDate: item.releaseDate,
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
                imageUrl: selectedItem.imageUrl,
                cachedOffers: selectedItem.offersResult,
                janCode: selectedItem.isbn13 ?? selectedItem.scannedCode,
                salesRank: selectedItem.salesRank,
                listPrice: selectedItem.listPrice,
                releaseDate: selectedItem.releaseDate,
                prices: selectedItem.prices,
                scannedAt: selectedItem.scannedAt,
                sellerCounts: selectedItem.sellerCounts
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

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("検索結果がありません")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// 新品の出品者数。オファー一覧(SP-API経路)にあればそれを優先し、無ければ
    /// 検索時に保存した出品者数(Keepa経路)へフォールバックする。
    /// 解決順は検索画面(SearchTabViewModel.newSellerCount)・商品詳細と揃えている。
    /// どちらも無ければnilで、その場合は人数を出さない(0人と誤表示しない)。
    private var newSellerCount: Int? {
        item.offersResult?.newCount ?? item.offersResult?.new?.count ?? item.sellerCounts?.new
    }

    /// 中古の出品者数。解決順はnewSellerCountと同じ。
    private var usedSellerCount: Int? {
        item.offersResult?.usedCount ?? item.offersResult?.used?.count ?? item.sellerCounts?.used
    }

    /// 価格表示へ出品者数を添える。取得できていなければ何も足さない。
    /// 一覧は1行に収める(lineLimit(1) + minimumScaleFactor)ため、商品詳細の
    /// 「出品者数N人」より短い「出品者N人」にして縮小を抑える。
    private static func withSellerCount(_ text: String, _ count: Int?) -> String {
        guard let count else { return text }
        return "\(text)(出品者\(count)人)"
    }

    /// 新品の表示文字列。Amazon本体が最安なら「新品(Ama):¥1430」と区別する。
    /// オファー未保存(Keepa経路など)は第1段階の簡易価格でフォールバックする。
    private var newPriceText: String? {
        if let offer = cheapestNewOffer, let landed = offer.landed {
            let label = offer.isAmazon == true ? "新品(Ama)" : "新品"
            return Self.withSellerCount("\(label):¥\(landed)", newSellerCount)
        }
        if let price = item.prices?.new {
            return Self.withSellerCount("新品:¥\(price)", newSellerCount)
        }
        return nil
    }

    /// 中古の表示文字列。コンディション名は出さない(出品者数を併記するようになり、
    /// 1行に収めると縮小が強くなりすぎるため。コンディションは商品詳細で確認できる)。
    private var usedPriceText: String? {
        if let offer = cheapestUsedOffer, let landed = offer.landed {
            return Self.withSellerCount("中古品:¥\(landed)", usedSellerCount)
        }
        if let price = item.prices?.used {
            return Self.withSellerCount("中古品:¥\(price)", usedSellerCount)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
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

                if let asin = item.asin {
                    HistoryRankMiniChart(asin: asin)
                        .id(item.id)
                }
            }
            .frame(width: 50)

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
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        // 検索タブの最新スキャン結果カード(LatestResultCardView)と同じ見せ方に揃える:
        // 発火時は文言・バッジを出さず緑の縁取りだけで示す(一覧の可読性を落とさないため)。
        // 線幅・角丸の値も検索タブと同一(3pt / cornerRadius 10)。
        // 縦横のpaddingを4→6・0→4へ広げているのは、この縁取りが行の端やセパレーターに
        // 詰まって見えないようにするための調整(既存の行の高さ・余白の見た目は大きく変えない範囲)。
        .overlay(
            item.profitAlertTriggered == true
                ? RoundedRectangle(cornerRadius: 10).stroke(Color.green, lineWidth: 3)
                : nil
        )
    }
}

/// 一覧では軸や数値を省き、保存済みランキングの形だけを示す。
private struct HistoryRankMiniChart: View {
    let asin: String
    @State private var segments: [[CGPoint]] = []
    @State private var isVisible = false

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for segment in segments {
                for (index, point) in segment.enumerated() {
                    let position = CGPoint(x: 1 + point.x * (size.width - 2),
                                           y: 1 + point.y * (size.height - 2))
                    if index == 0 { path.move(to: position) }
                    else { path.addLine(to: position) }
                }
            }
            context.stroke(path, with: .color(.green), lineWidth: 1)
        }
        .frame(width: 50, height: 24)
        .accessibilityLabel("直近1年間の保存済みランキング推移")
        .accessibilityHidden(segments.isEmpty)
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            segments = []
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            let end = Date()
            let start = Calendar.current.date(byAdding: .year, value: -1, to: end) ?? end
            let rows = await GraphArchive.yearlyRank(for: asin, endingAt: end)
            guard !Task.isCancelled, isVisible else { return }
            let values = rows.filter { $0[1] > 0 }.map { $0[1] }
            guard let low = values.min(), let high = values.max() else { return }
            let duration = max(1, end.timeIntervalSince(start))
            var result: [[CGPoint]] = []
            var current: [CGPoint] = []
            for row in rows {
                guard row[1] > 0 else {
                    if current.count > 1 { result.append(current) }
                    current = []
                    continue
                }
                // 詳細画面と同じく、順位の数値が大きいほど上に描く。
                current.append(CGPoint(x: (row[0] - start.timeIntervalSince1970) / duration,
                                       y: high == low ? 0.5 : 1 - (row[1] - low) / (high - low)))
            }
            if current.count > 1 { result.append(current) }
            segments = result
        }
    }
}
