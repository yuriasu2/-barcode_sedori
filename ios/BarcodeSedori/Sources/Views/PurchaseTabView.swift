import SwiftUI

/// 「仕入れ」タブ: 仕入れリストの一覧・スワイプ削除・出品済みマーク。
/// 行タップ(非選択モード時)で仕入れフォーム(PurchaseFormView・編集モード)を開く
/// (誰でも編集可。単品の「出品する」導線は無い)。
/// 選択モード(EditButton)での一括削除・一括コンディション変更・一括出品を持つ。
/// 仕入れタブ上部の表示切替。出品済みは作業対象から外れるため既定は「未出品」。
enum ListTab: String, CaseIterable, Identifiable {
    case unlisted = "未出品"
    case listed = "出品済み"

    var id: String { rawValue }
}

struct PurchaseTabView: View {
    @ObservedObject private var store = PurchaseListStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var bulkListingViewModel = BulkListingViewModel()

    // 注意: @Environment(\.editMode)はList(selection:)の実際の編集状態と同期しない事象を確認したため
    // (EditButtonの見た目・Listの選択UIは変化するのに環境値の読み取りがfalseのままになる)、
    // 選択モードは自前の@Stateで管理し、Listへは.environment(\.editMode:)で明示的に反映する。
    @State private var isSelecting = false
    @State private var selectedIds = Set<UUID>()
    /// 一覧の表示切替(未出品 / 出品済み)。
    @State private var selectedTab: ListTab = .unlisted
    @State private var showDeleteConfirm = false
    @State private var showListingConfirm = false

    /// 現在のタブに表示する商品。選択・全選択・削除もこの範囲だけを対象にする。
    private var visibleItems: [PurchaseListItem] {
        switch selectedTab {
        case .unlisted: return store.items.filter { !$0.isListed }
        case .listed: return store.items.filter { $0.isListed }
        }
    }

    /// 一括出品の導線を出してよいか(単品出品フォームと同じゲート)。
    private var canBulkList: Bool {
        entitlements.isPro && settings.isListingReady
    }

    var body: some View {
        NavigationView {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        // タブ切替。切り替えると選択内容は対象外になるため解除する。
                        Picker("表示", selection: $selectedTab) {
                            ForEach(ListTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .onChange(of: selectedTab) { _ in
                            selectedIds.removeAll()
                        }

                        listContent
                    }
                }
            }
            .navigationTitle("仕入れ")
            .toolbar { toolbarContent }
            .overlay { progressOverlay }
            // 選択モード中はTabViewのタブバーを隠す。隠さないと(このiOSのタブバー統合デザインでは)
            // .bottomBarツールバーの両端ボタンがタブ項目のヒットテスト領域と重なり、
            // タップがタブ切替に奪われて押せなくなる事象を確認したための対策。
            .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
        }
        .navigationViewStyle(.stack)
        .confirmationDialog(
            "選択した\(selectedIds.count)件を削除しますか?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                store.remove(ids: selectedIds)
                selectedIds.removeAll()
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog(
            "選択\(selectedIds.count)件を出品します。各商品の仕入れフォームで保存した価格・数量で出品します。",
            isPresented: $showListingConfirm,
            titleVisibility: .visible
        ) {
            Button("出品する") {
                let ids = Array(selectedIds)
                Task {
                    await bulkListingViewModel.run(itemIds: ids)
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(item: $bulkListingViewModel.resultAlert) { alert in
            Alert(
                title: Text("出品が完了しました"),
                message: Text(alert.summaryText),
                dismissButton: .default(Text("OK")) {
                    selectedIds.removeAll()
                }
            )
        }
    }

    // 注意: ToolbarItem/ToolbarItemGroupをトップレベルの`if`で条件分岐すると、
    // 一部のplacement(.navigationBarLeadingで確認済み)でSwiftUIが描画しない事象を確認したため、
    // ToolbarItem自体は常に存在させ、中身(ラベル・ボタン)側を`if`で出し分ける形に統一する。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if !store.items.isEmpty {
                // 注意: @Environment(\.editMode)がList(selection:)の実編集状態と同期しない事象を
                // 確認したため、標準EditButton()は使わず自前のisSelecting@Stateで切り替える。
                Button(isSelecting ? "完了" : "選択") {
                    isSelecting.toggle()
                    if !isSelecting {
                        selectedIds.removeAll()
                    }
                }
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelecting {
                Button(selectedIds.count == visibleItems.count ? "全解除" : "全選択") {
                    if selectedIds.count == visibleItems.count {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(visibleItems.map(\.id))
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if isSelecting && !selectedIds.isEmpty {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(bulkListingViewModel.isRunning)

                Spacer()

                Menu {
                    ForEach(ListingConditionType.allCases) { condition in
                        Button(condition.displayName) {
                            store.updateCondition(ids: selectedIds, condition: condition)
                        }
                    }
                } label: {
                    Label("コンディション", systemImage: "tag")
                }
                .disabled(bulkListingViewModel.isRunning)

                if canBulkList {
                    Spacer()
                    Button {
                        showListingConfirm = true
                    } label: {
                        Label("出品", systemImage: "shippingbox")
                    }
                    .disabled(bulkListingViewModel.isRunning)
                }
            }
        }
    }

    /// 一括出品処理中のオーバーレイ(「出品中 i/N」)。二重実行防止のためタップも吸収する。
    @ViewBuilder
    private var progressOverlay: some View {
        if bulkListingViewModel.isRunning {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("出品中 \(bulkListingViewModel.progressCurrent)/\(bulkListingViewModel.progressTotal)")
                        .foregroundColor(.primary)
                }
                .padding(24)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(radius: 8)
            }
        }
    }

    /// リストが空のときの案内。追加ボタンの場所(検索結果カード)へ誘導する。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cart.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("仕入れリストは空です")
                .foregroundColor(.secondary)
            Text("検索タブのスキャン結果カードから追加できます(Pro)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var listContent: some View {
        List(selection: $selectedIds) {
            if entitlements.isPro && !settings.isSpApiLinkUsable {
                Section {
                    Text("出品するには設定タブでAmazon連携(SP-API)が必要です。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if entitlements.isPro && settings.isSpApiLinkUsable && !settings.isListingReady {
                // 連携済みだがsellerId未取得(旧認可のまま)のケース。
                // Sellers APIからは取得不可能なため、再認可でOAuthコールバックのselling_partner_idを
                // 取得し直してもらう必要がある。
                Section {
                    Text("出品にはAmazon連携のやり直しが必要です(設定タブ→Amazon連携)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                if visibleItems.isEmpty {
                    Text(selectedTab == .unlisted ? "未出品の商品はありません" : "出品済みの商品はありません")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    purchaseRows(for: visibleItems)
                }
            }
        }
        .listStyle(.insetGrouped)
        // isSelecting@Stateをこの階層のeditMode環境値へ明示的に反映する(自前トグルのため)。
        // Listの複数選択チェックマークUIはこの環境値がactiveのときのみ表示される。
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    /// 未出品/出品済みの各セクションで共通の行組み立て。
    /// 注意: セクション分割によりForEachのoffsetsは渡された配列(フィルタ後)基準になり、
    /// store.items全体の添字とはずれる。そのためonDeleteはoffsetsをそのまま
    /// store.remove(atOffsets:)へは渡さず、フィルタ後配列からidを引いてstore.remove(ids:)で消す。
    @ViewBuilder
    private func purchaseRows(for items: [PurchaseListItem]) -> some View {
        ForEach(items) { item in
            // 行タップでの編集は誰でも可(Pro/SP-API連携の状態やisListedに関わらず開ける)。
            // 選択モード中はタップが選択操作に使われるため遷移させない。
            if !isSelecting {
                NavigationLink {
                    PurchaseFormView(mode: .edit(item: item))
                } label: {
                    PurchaseListRow(item: item)
                }
            } else {
                PurchaseListRow(item: item)
            }
        }
        .onDelete { offsets in
            let ids = Set(offsets.map { items[$0].id })
            store.remove(ids: ids)
        }
    }
}

/// 仕入れリストの1行。サムネイル+タイトル+追加日+コンディション+出品済みバッジ。
struct PurchaseListRow: View {
    let item: PurchaseListItem

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    /// 表示するJANコード(ISBN-13があればそれ、無ければスキャンしたコード)。
    private var janCode: String {
        item.isbn13 ?? item.scannedCode ?? "-"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
            .frame(width: 56, height: 56)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "(タイトル不明)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                // 仕入れ日 / JAN / ランク。商品タブの履歴行と同じ表記に揃える
                // (JANはbarcode.viewfinder、ランクは折れ線グラフアイコン)。
                HStack(spacing: 8) {
                    Text("仕入れ日:\(Self.dateFormatter.string(from: item.purchaseDate ?? item.addedAt))")

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

                // コンディション / 出品価格 / 数量。価格は仕入れ価格と区別できるよう「出品価格:」を添える。
                HStack(spacing: 8) {
                    // コンディション(未設定時は既定の「良い」を表示。保存値そのものは変えない)。
                    Text((item.condition ?? .usedGood).displayName)
                        .foregroundColor(.secondary)

                    // 仕入れフォームで保存済みの価格(あれば表示)。
                    if let price = item.price {
                        Text("出品価格:¥\(price)")
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }

                    Text("数量:\(item.quantity ?? 1)")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                if let sku = item.sku ?? item.listedSku {
                    Text("SKU:\(sku)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
