import SwiftUI

/// 「仕入れ」タブ(Phase 1b): 仕入れリストの一覧・スワイプ削除・出品済みマーク。
/// 「出品」導線(Pro+SP-API連携時のみ・未出品行のみ)はPhase 2(ListingFormView)で追加済み。
/// 選択モード(EditButton)での一括削除・一括コンディション変更・一括出品(Phase 2b)を持つ。
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
    @State private var showDeleteConfirm = false
    @State private var showListingConfirm = false

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
                    listContent
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
            "選択\(selectedIds.count)件を出品します。価格は各商品の同コンディション最安値になります。",
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
                Button(selectedIds.count == store.items.count ? "全解除" : "全選択") {
                    if selectedIds.count == store.items.count {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(store.items.map(\.id))
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
                ForEach(store.items) { item in
                    if !isSelecting && entitlements.isPro && settings.isListingReady && !item.isListed {
                        NavigationLink {
                            ListingFormView(item: item)
                        } label: {
                            PurchaseListRow(item: item)
                        }
                    } else {
                        PurchaseListRow(item: item)
                    }
                }
                .onDelete { offsets in
                    store.remove(atOffsets: offsets)
                }
            }
        }
        .listStyle(.insetGrouped)
        // isSelecting@Stateをこの階層のeditMode環境値へ明示的に反映する(自前トグルのため)。
        // Listの複数選択チェックマークUIはこの環境値がactiveのときのみ表示される。
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
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

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: item.addedAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let rank = item.salesRank {
                        Text("ランク: \(rank)位")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    // コンディション(未設定時は既定の「良い」を表示。保存値そのものは変えない)。
                    Text((item.condition ?? .usedGood).displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if item.isListed {
                        // 出品受理済みマーク(Phase 2: markListedで付与される)。
                        Label("出品済み", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
