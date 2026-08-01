import SwiftUI
import UIKit
import AudioToolbox

/// スキャンモードの見た目トグル。CHANGES-v2.md:
/// 「バーコード / インストアコード」トグル → 「バーコード / OCR」トグルに変更。
enum ScanMode: String, CaseIterable, Identifiable {
    case barcode = "バーコード"
    case ocr = "OCR"

    var id: String { rawValue }

    /// ScannerViewへ渡すisOCRModeフラグ
    var isOCRMode: Bool { self == .ocr }
}

/// 価格推移グラフの期間切替セグメント(1ヶ月/3ヶ月/1年/全期間)。初期値は3ヶ月。
/// rawValueは「今日からの日数」で、0は全期間(履歴データ全点を使う)を表す特別値。
enum GraphRange: Int, CaseIterable, Identifiable {
    case oneMonth = 30
    case threeMonths = 90
    case oneYear = 365
    case all = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneMonth: return "1ヶ月"
        case .threeMonths: return "3ヶ月"
        case .oneYear: return "1年"
        case .all: return "全期間"
        }
    }
}

/// CHANGES-v6.md: 検索タブ全面刷新。
/// リスト表示をやめ、最新1件のスキャン結果カード+オファーパネル+Keepaグラフの単一状態に置き換える。
@MainActor
final class SearchTabViewModel: ObservableObject {
    @Published var scanMode: ScanMode = .barcode

    /// 最新のスキャン/検索結果(/api/search)
    @Published var latestResult: SearchResult?
    /// 最新にスキャンされたコード文字列(カード内のコード表示に使う)
    @Published var latestScannedCode: String?
    /// 検索中フラグ
    @Published var isSearching = false
    /// 検索失敗時のエラーメッセージ
    @Published var searchErrorMessage: String?

    /// SP-API経路のとき/api/search応答に同梱されるオファー一覧。Keepa経路ではnil。
    @Published var offersResult: OffersResult?
    /// オファー読み込み中フラグ
    @Published var isLoadingOffers = false
    /// フリーミアム: 無料プラン&Keepa経路でオファーがPro限定ロックされている状態。
    /// このときは実データを取得せず、パネルにぼかしダミー+鍵を表示する。
    @Published var offersLocked = false

    /// 利益アラートの判定結果。Proかつ検索成功時のみ評価する。未評価/非Proはnil。
    @Published var profitAlertVerdict: ProfitAlertEvaluator.Verdict?

    private let apiClient: APIClient
    private let historyStore: ScanHistoryStore

    /// 直近history追加したエントリのid。オファー同梱時にこのidの履歴を更新するために保持する。
    private var pendingHistoryItemId: UUID?

    init(apiClient: APIClient = .shared, historyStore: ScanHistoryStore = .shared) {
        self.apiClient = apiClient
        self.historyStore = historyStore
    }

    /// 新品の出品者数。offersResult(SP-API経路)にあればそれを優先し、
    /// 無ければKeepa第1段階で取得済みのprofitInputs.sellerCounts.newにフォールバックする。
    /// どちらも取得できなければnil(呼び出し側は人数を出さず「新品」だけ表示し、0人と誤表示しない)。
    var newSellerCount: Int? {
        offersResult?.newCount ?? offersResult?.new?.count ?? latestResult?.profitInputs?.sellerCounts?.new
    }

    /// 中古の出品者数。解決順はnewSellerCountと同じ(offersResult → profitInputs.sellerCounts.used → nil)。
    var usedSellerCount: Int? {
        offersResult?.usedCount ?? offersResult?.used?.count ?? latestResult?.profitInputs?.sellerCounts?.used
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
        profitAlertVerdict = nil

        Task { await self.search(code: code) }
    }

    private func search(code: String) async {
        do {
            let result = try await apiClient.search(code: code)
            latestResult = result
            isSearching = false
            // 無料枠ユニットの残量をローカルへ反映する(Pro・SP-API連携済みはquota==nilで何もしない)。
            ScanQuotaStore.shared.apply(result.quota)

            // 利益アラートはPro限定(無料は設定が残っていても発火しない二重ゲート)。
            if EntitlementStore.shared.isPro {
                let verdict = ProfitAlertEvaluator.evaluate(result: result, settings: Self.profitAlertSettings())
                profitAlertVerdict = verdict
                if verdict.isTriggered && SettingsStore.shared.profitAlertHapticsEnabled {
                    // 再描画で多重発火させないよう、判定確定時にここで1回だけ鳴らす。
                    // バイブ設定がOFFのときは緑バナー・縁取り(profitAlertVerdict)は変えず振動のみ止める。
                    Self.fireProfitAlertHaptics()
                }
            }

            if result.codeType != .unresolved {
                let historyItem = ScanHistoryItem(scannedCode: code, result: result)
                pendingHistoryItemId = historyItem.id
                historyStore.add(historyItem)
            }

            // オファー一覧はSP-API連携時のみ表示する(/api/searchに同梱)。
            // Keepa経路(SP-API未接続)は無料/Proとも実取得せずロック表示にする
            // (Keepaの個別オファー取得はトークン消費が大きいため行わず、Amazon連携を促す)。
            if let embedded = result.offers {
                offersResult = embedded
                isLoadingOffers = false
                if let pendingHistoryItemId {
                    historyStore.update(id: pendingHistoryItemId) { item in
                        item.offersResult = embedded
                    }
                }
            } else if result.asin != nil {
                offersLocked = true
            }
        } catch {
            isSearching = false
            // 無料枠ユニット上限超過(429・quota_exceeded)。quotaを反映すればisQuotaExhaustedが
            // trueになりQuotaPaywallOverlayが自動的に表示されるため、ここでは
            // searchErrorMessageを設定しない(同じ内容の赤文字が二重に出るのを避けるため)。
            if case APIClientError.quotaExceeded(let quota, _) = error {
                ScanQuotaStore.shared.apply(quota)
            } else if case APIClientError.httpError(let status, _) = error, status == 429 {
                // quota_exceeded形式でない429(旧サーバー互換)のフォールバック。
                // こちらはquotaを受け取れずオーバーレイが自動では出ないため、文言で案内する。
                searchErrorMessage = "本日の無料スキャン上限に達しました。Proにアップグレードすると無制限に使えます。"
            } else {
                searchErrorMessage = error.localizedDescription
            }
        }
    }

    /// 利益アラート発火時の振動。タプティック(Impact/Notification)ではスキャン時の振動と
    /// 体感が区別できなかったため、旧来の長いシステムバイブ(約0.5秒)を2回鳴らす。
    /// 長さの指定はiOS側でできず固定。0.7秒間隔を空けることで2回が明確に分離して感じられる。
    private static func fireProfitAlertHaptics() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// SettingsStoreの現在値からProfitAlertEvaluator.Settingsスナップショットを組み立てる。
    private static func profitAlertSettings() -> ProfitAlertEvaluator.Settings {
        let settings = SettingsStore.shared
        return ProfitAlertEvaluator.Settings(
            enabled: settings.profitAlertEnabled,
            marginEnabled: settings.profitAlertMarginEnabled,
            marginThreshold: settings.profitAlertMarginThreshold,
            purchaseCost: settings.profitAlertPurchaseCost,
            targetCondition: settings.profitAlertTargetCondition,
            rankEnabled: settings.profitAlertRankEnabled,
            rankThreshold: settings.profitAlertRankThreshold,
            sellerCountEnabled: settings.profitAlertSellerCountEnabled,
            sellerCountNewThreshold: settings.profitAlertSellerCountNewThreshold,
            sellerCountUsedThreshold: settings.profitAlertSellerCountUsedThreshold,
            listPriceEnabled: settings.profitAlertListPriceEnabled
        )
    }
}

/// リワード広告フローの結果通知(alert表示用)。タイトルと本文をまとめて差し替えるために型で持つ。
private struct RewardedAdAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct SearchTabView: View {
    /// 検索タブが選択中(表示中)かどうか。falseのときはScannerViewへ渡してカメラセッションを停止させる。
    let isActive: Bool
    @StateObject private var viewModel = SearchTabViewModel()
    @ObservedObject private var entitlements = EntitlementStore.shared
    /// 仕入れリスト(Phase 1b)。「追加済み」表示の再描画のため監視する。
    @ObservedObject private var purchaseList = PurchaseListStore.shared
    /// 無料枠ユニット(Phase B)のローカルミラー。サーバー応答のたびに是正される。
    @ObservedObject private var quota = ScanQuotaStore.shared
    /// SP-API連携状態(isSpApiLinkUsable)の変化でゲート判定を再評価するため監視する。
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedResult: SearchResult?
    @State private var searchBarText: String = ""
    @State private var showsInvalidCodeAlert = false
    /// フリーミアム: 各ゲート(オファー等)から提示するペイウォール。
    @State private var showPaywall = false
    /// OCRのお試し枠(1日5回)を使い切った際のポップアップ(スキャン時・モード切替タップ時とも共通)。
    @State private var showOcrLimitAlert = false
    /// 「仕入れリストへ追加」タップで開く仕入れフォーム(新規追加モード)の下書き。
    /// 保存(緑チェック)されるまでPurchaseListStoreへは登録しない。
    @State private var purchaseFormDraft: PurchaseListItem?
    /// アクションボタン(a/m/価)で開くアプリ内ブラウザの対象URL(nilならシート非表示)。
    @State private var browserTarget: BrowserTarget?
    /// タブ状態。開発用ディープリンク(debug-search)で流し込まれた検索コードを受け取るため監視する。
    @ObservedObject private var navigation = AppNavigation.shared
    /// 価格推移グラフの期間切替。初期値は3ヶ月。
    @State private var selectedGraphRange: GraphRange = .threeMonths
    /// リワード広告(Phase C)。ロード/表示中フラグの変化でボタンを更新するため監視する。
    @ObservedObject private var rewardedAds = RewardedAdManager.shared
    /// リワード広告の表示〜枠の反映待ちが進行中か。二重起動を防ぎ、UIへ「反映中…」を出すために持つ。
    @State private var isProcessingRewardedAd = false
    /// リワード広告フローの結果通知(準備失敗・反映待ちタイムアウト)。
    @State private var rewardedAdAlert: RewardedAdAlert?

    var body: some View {
        NavigationView {
            // 全体を1つのScrollViewにする(検索バーも中に含める)。ScrollViewがキーボード回避を
            // 適切に処理するため、結果表示中にキーボードを出しても検索バーが画面外へ消えない。
            ScrollView {
                VStack(spacing: 0) {
                    searchBar

                    topContent

                    // 非Proはユニット残があればグラフを表示する(サーバーが429を返せば次回検索で
                    // quotaが是正され、この分岐がfreeAdAreaへ切り替わる)。
                    if entitlements.isPro || quota.canScanToday {
                        keepaGraph
                    } else {
                        freeAdArea
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            // navigationBarHiddenだけだと上部に余白が残ることがあるため、ツールバー自体を隠して詰める。
            .toolbar(.hidden, for: .navigationBar)
            .alert("入力が間違っています。10桁or13桁で入力してください。", isPresented: $showsInvalidCodeAlert) {
                Button("OK", role: .cancel) {}
            }
            .alert("OCR機能を無制限に使うにはProにアップグレードしてください。", isPresented: $showOcrLimitAlert) {
                Button("アップグレード") { showPaywall = true }
                Button("閉じる", role: .cancel) {}
            }
            // 無料枠を使い切った瞬間にOCRモードのままだと、カメラ停止後もOCRトグルが選択された
            // 見た目のまま残ってしまうため、枠切れになったらバーコードモードへ強制的に戻す。
            .onChange(of: isQuotaExhausted) { exhausted in
                if exhausted && viewModel.scanMode == .ocr {
                    viewModel.scanMode = .barcode
                }
            }
            // 残りが少なくなった時点で広告を先読みしておく。枠切れオーバーレイが出てから
            // 読み込むと「動画を見てスキャン+5回」をタップしてから数秒待たされるため。
            .onChange(of: quota.unitsRemaining) { remaining in
                if !isSearchUnlimited && remaining <= 1 && showsRewardedAdOption {
                    rewardedAds.preload()
                }
            }
            .alert(
                rewardedAdAlert?.title ?? "",
                isPresented: Binding(
                    get: { rewardedAdAlert != nil },
                    set: { if !$0 { rewardedAdAlert = nil } }
                ),
                presenting: rewardedAdAlert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(item: $purchaseFormDraft) { draft in
                NavigationView {
                    PurchaseFormView(mode: .add(draft: draft))
                }
            }
            // 外部リンク(a/m/価)はアプリ内ブラウザ(SFSafariViewController)で開く。
            .sheet(item: $browserTarget) { target in
                SafariView(url: target.url)
                    .ignoresSafeArea()
            }
            // 開発ビルド専用: barcodesedori://debug-search?code=... で流し込まれたコードを検索する
            // (シミュレータでタップ・文字入力の注入が効かない環境向けの検証用ルート)。
            #if DEBUG
            .onReceive(navigation.$pendingDebugSearchCode.compactMap { $0 }) { code in
                navigation.pendingDebugSearchCode = nil
                startSearch(code)
            }
            #endif
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

    /// 検索(=Keepa消費)が無制限か。Proと、SP-API連携済み(自分のAPI枠を使うためサーバーはユニットを消費しない)。
    private var isSearchUnlimited: Bool { entitlements.isPro || settings.isSpApiLinkUsable }
    /// 無料枠を使い切っており、これ以上スキャンできないか。
    private var isQuotaExhausted: Bool { !isSearchUnlimited && !quota.canScanToday }
    /// リワード広告(動画を見て+5回)の導線を出してよいか。
    /// AdsConfig.enabled(全広告のマスタースイッチ)も尊重するため RewardedAdManager.isEnabled を経由する。
    private var showsRewardedAdOption: Bool {
        rewardedAds.isEnabled && quota.adAvailable && !quota.capReached
    }

    /// Pro/無料で共通の中身(カメラ・モード切替・結果カード・オファーパネル)。
    /// 検索バーは固定ヘッダーとして body 側に置くためここには含めない。
    /// カメラセッションを動かすか。検索タブ表示中でも、前面にシートが出ている間や
    /// 商品詳細へ遷移している間、無料枠を使い切っている間は止める
    /// (カメラが見えていない時にバッテリーと発熱を消費しないため)。
    private var isScannerActive: Bool {
        isActive
            && purchaseFormDraft == nil
            && browserTarget == nil
            && selectedResult == nil
            && !showPaywall
            && !isQuotaExhausted
    }

    @ViewBuilder
    private var topContent: some View {
        ScannerView(
            onScan: { scanned in
                // OCRモードの無料お試し枠(1日5回)。超過でOCR専用ポップアップ。
                if viewModel.scanMode.isOCRMode && !entitlements.isPro
                    && !ScanQuotaStore.shared.registerOcrUseIfAllowed() {
                    showOcrLimitAlert = true
                    return
                }
                startSearch(scanned.code)
            },
            isOCRMode: viewModel.scanMode.isOCRMode,
            isActive: isScannerActive,
            emitCooldown: entitlements.isPro ? 1.0 : 5.0
        )
        .frame(maxWidth: .infinity)
        .frame(height: UIScreen.main.bounds.height * 0.35)
        .clipped()
        // バーコード/OCR切替はカメラ映像の中(下端)に重ねる。
        .overlay(alignment: .bottom) {
            modeToggle
        }
        // 無料枠切れのときはカメラ映像の上に枠切れオーバーレイを重ねる(カメラ自体はisScannerActiveで停止済み)。
        .overlay {
            if isQuotaExhausted {
                QuotaPaywallOverlay(
                    showsAdOption: showsRewardedAdOption,
                    showsSpApiOption: !settings.isSpApiLinkUsable,
                    isProcessingAd: isProcessingRewardedAd,
                    onUpgradeTap: { showPaywall = true },
                    onWatchAdTap: { startRewardedAdFlow() },
                    onSpApiLinkTap: { AppNavigation.shared.selectedTab = AppNavigation.settingsTab }
                )
            }
        }

        latestResultCard

        offersPanels
    }

    /// スキャン(カメラ/OCR)・手入力検索の共通ゲート。無料枠ユニットの残量を確認し、
    /// 残っていればローカルミラーを楽観的に1消費してから検索を実行する。
    /// 枠切れのときはペイウォールを提示する。枠切れ中はカメラが止まる(isScannerActive)ため
    /// ここに枠切れで到達するのは手入力検索の経路だが、黙って無反応にすると
    /// 「検索できない理由」が分からないため必ず理由を示す。
    private func startSearch(_ code: String) {
        guard isSearchUnlimited || quota.canScanToday else {
            showPaywall = true
            return
        }
        if !isSearchUnlimited {
            quota.consumeLocally()
        }
        viewModel.handleScan(code)
    }

    /// リワード広告フロー(枠切れオーバーレイの「動画を見てスキャン+5回」/グラフ枠の「動画を見てグラフを見る」の共通処理)。
    /// 広告を表示し、報酬獲得できたらサーバー側の枠加算(+5)が届くまで待つ。
    ///
    /// 加算はGoogle→サーバーのSSVコールバックで非同期に行われるため、視聴直後は未反映のことがある。
    /// そのため「+5されました」とは即断せず、`waitForAdGrant()` が実際の増加を確認するまで「反映中…」を出す。
    /// 反映されると unitsRemaining > 0 になり、isQuotaExhausted が false になってオーバーレイは自動的に消える。
    private func startRewardedAdFlow() {
        guard !isProcessingRewardedAd else { return }
        isProcessingRewardedAd = true

        Task { @MainActor in
            let manager = RewardedAdManager.shared
            let earnedReward = await manager.show(from: RewardedAdManager.topViewController())

            guard earnedReward else {
                isProcessingRewardedAd = false
                // 表示まで到達していたなら「ユーザーが途中で閉じた」意図的な中断なので何も出さない。
                if !manager.lastAttemptDidPresent {
                    rewardedAdAlert = RewardedAdAlert(
                        title: "広告を準備できませんでした",
                        message: "しばらくしてからお試しください。"
                    )
                }
                return
            }

            let granted = await quota.waitForAdGrant()
            isProcessingRewardedAd = false
            if !granted {
                rewardedAdAlert = RewardedAdAlert(
                    title: "反映に時間がかかっています",
                    message: "しばらくしてからお試しください。付与はサーバーに届き次第、自動的に反映されます。"
                )
            }
        }
    }

    /// 無料プラン用: 状況に応じた案内 と、余白を埋める広告。上詰めでオファー直下に配置する。
    /// Proではないがユニット残がある間はkeepaGraphを表示するため、ここに来るのは
    /// 「非Pro・グラフ表示に使うユニットを使い切った」場合のみ。
    ///
    /// グラフ専用の案内(枠切れ文言・「動画を見てグラフを見る」)はSP-API連携済みのときだけ出す。
    /// 未連携の場合は同じユニットをスキャンでも消費するため、枠が尽きた時点でカメラ上に
    /// 枠切れオーバーレイ(Pro/動画を見てスキャン+5回/Amazon連携)が既に出ている。
    /// そこへほぼ同じ内容の導線を重ねても画面が混むだけなので、広告バナーのみにする。
    private var freeAdArea: some View {
        VStack(spacing: 8) {
            AdSlotView(slotId: "search_ad")

            if settings.isSpApiLinkUsable {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        LockIconView(size: 16)
                        Text("本日のグラフ表示枠を使い切りました。Proなら無制限")
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

                // リワード広告で枠を増やせば、グラフ表示に使うユニットが復活する。
                if showsRewardedAdOption {
                    Button {
                        startRewardedAdFlow()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.rectangle.fill")
                            Text(isProcessingRewardedAd ? "反映中…" : "動画を見てグラフを見る")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessingRewardedAd)
                }
            }
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        if let selectedResult, let asin = selectedResult.asin {
            // 検索時に取得済みのオファーをそのまま渡す(別リクエストでの再取得はしない)。
            ProductDetailView(
                asin: asin,
                title: selectedResult.title,
                cachedOffers: viewModel.offersResult,
                janCode: selectedResult.isbn13 ?? viewModel.latestScannedCode,
                listPrice: selectedResult.profitInputs?.listPrice,
                releaseDate: selectedResult.releaseDate
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
            TextField("ISBN、JANコードで検索", text: $searchBarText)
                .textFieldStyle(.plain)
                // 数字レイアウトで開く。numberPadだとReturnキーが無く onSubmit で検索できなくなり、
                // ISBN-10のチェック文字"X"も打てなくなるため numbersAndPunctuation を使う。
                .keyboardType(.numbersAndPunctuation)
                .onSubmit {
                    submitSearchBarText()
                }
                .submitLabel(.search)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    /// 数字のみ13桁ならそのままコード検索(/api/search)。10桁はISBN-10として検証し、
    /// 有効なら978プレフィックス付きの13桁(ISBN-13)へ変換してから検索する
    /// (OCR経路の ISBN10Validator と同じ変換方式に揃える)。それ以外は入力不正アラート。
    private func submitSearchBarText() {
        let trimmed = searchBarText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.count == 13, trimmed.allSatisfy({ $0.isNumber }) {
            startSearch(trimmed)
            return
        }

        // ISBN-10はチェック文字が"X"になり得るため大文字化してから検証する。
        let upper = trimmed.uppercased()
        if upper.count == 10, ISBN10Validator.isValid(upper) {
            startSearch(ISBN10Validator.toIsbn13(upper))
            return
        }

        showsInvalidCodeAlert = true
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach(ScanMode.allCases) { mode in
                let isSelected = viewModel.scanMode == mode
                // フリーミアム: OCRは無料でも1日5回まで試せる。使い切ると鍵表示→タップでOCR専用ポップアップ。
                let ocrExhausted = (mode == .ocr && !entitlements.isPro && !ScanQuotaStore.shared.canUseOcrToday)
                Button {
                    if ocrExhausted {
                        showOcrLimitAlert = true
                    } else {
                        viewModel.scanMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.rawValue)
                        if ocrExhausted {
                            LockIconView(size: 11)
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    // カメラ映像に重ねるため文字は常に白。選択中の側だけ白枠で囲んで示す。
                    .foregroundColor(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white, lineWidth: isSelected ? 1.5 : 0)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    )
                    // 透明背景だと文字部分しか反応しないため、セル全体を当たり判定にする。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // カメラの上に置く行全体は暗め透過にして映像と区別する。
        .background(Color.black.opacity(0.35))
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
            LatestResultCardView(
                result: result,
                scannedCode: viewModel.latestScannedCode ?? "",
                profitVerdict: viewModel.profitAlertVerdict,
                isPro: entitlements.isPro,
                isInPurchaseList: result.asin.map { purchaseList.contains(asin: $0) } ?? false,
                onAddToPurchaseList: {
                    guard let asin = result.asin, !asin.isEmpty else { return }
                    // まだ仕入れリストへは登録せず、仕入れフォームの下書きとしてシート表示する。
                    // 保存(緑チェック)で初めてPurchaseListStoreへ追加される。
                    purchaseFormDraft = PurchaseListItem(
                        result: result,
                        scannedCode: viewModel.latestScannedCode,
                        offersResult: viewModel.offersResult
                    )
                },
                onLockedPurchaseTap: {
                    showPaywall = true
                },
                onOpenLink: { url in
                    browserTarget = BrowserTarget(url: url)
                }
            )
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

    /// パネルタイトルを組み立てる。出品者数が取得できていれば併記し、無ければ人数部分を出さない
    /// (0人と誤表示しないため。viewModel.newSellerCount/usedSellerCountがnilを返すケースに対応)。
    private func offersPanelTitle(base: String, sellerCount: Int?) -> String {
        guard let sellerCount else { return base }
        return "\(base)(出品者数\(sellerCount)人)"
    }

    @ViewBuilder
    private var offersPanels: some View {
        if viewModel.latestResult != nil {
            HStack(alignment: .top, spacing: 12) {
                OffersPanelView(
                    title: offersPanelTitle(base: "新品", sellerCount: viewModel.newSellerCount),
                    // モダンなブルー(#3B82F6)。「新品=青」の意味は従来から維持。
                    color: Color(red: 0.23, green: 0.51, blue: 0.96),
                    offers: viewModel.offersResult?.new ?? [],
                    isLoading: viewModel.isLoadingOffers,
                    isLocked: viewModel.offersLocked,
                    simplePrice: viewModel.latestResult?.prices?.new,
                    simpleLabel: "新品",
                    isShippingKnown: viewModel.offersResult?.source == "spapi"
                )
                .onTapGesture { handlePanelTap() }

                OffersPanelView(
                    title: offersPanelTitle(base: "中古", sellerCount: viewModel.usedSellerCount),
                    // モダンなオレンジ(#F97316)。「中古=オレンジ」の意味は従来から維持。
                    color: Color(red: 0.98, green: 0.45, blue: 0.09),
                    offers: viewModel.offersResult?.used ?? [],
                    isLoading: viewModel.isLoadingOffers,
                    isLocked: viewModel.offersLocked,
                    simplePrice: viewModel.latestResult?.prices?.used,
                    simpleLabel: "中古",
                    isShippingKnown: viewModel.offersResult?.source == "spapi"
                )
                .onTapGesture { handlePanelTap() }
            }
        }
    }

    /// オファーパネルのタップ処理。
    /// - ロック中(SP-API未接続)は設定タブ(Amazon連携)へ誘導する。
    /// - それ以外は source=spapi のときのみ商品詳細画面へ遷移する。
    private func handlePanelTap() {
        if viewModel.offersLocked {
            // オファーはSP-API連携で解放されるため、設定タブへ誘導する。
            AppNavigation.shared.selectedTab = AppNavigation.settingsTab
            return
        }
        guard let result = viewModel.latestResult, result.asin != nil else { return }
        guard result.source == "spapi" else { return }
        selectedResult = result
    }

    // MARK: - Keepaグラフ

    /// 価格推移グラフ(Pro専用。無料は body 側で freeAdArea を表示する)。
    @ViewBuilder
    private var keepaGraph: some View {
        if let asin = viewModel.latestResult?.asin {
            VStack(spacing: 6) {
                // オファーパネルとの重なりを避けるための余白。
                Spacer().frame(height: 10)
                // サーバーから履歴データ(/api/graph-data)を取得し、端末側でSwift Chartsに描画する。
                // チャートは全幅、凡例は下に1列で自前描画する。
                PriceHistoryChartView(asin: asin, range: selectedGraphRange)
                graphLegend
                graphRangeSegment
            }
        }
    }

    /// グラフの凡例。チャートの線の色に合わせた点と短いラベルをグラフ下に1列・中央寄せで並べる。
    private var graphLegend: some View {
        HStack(spacing: 16) {
            legendItem(color: .green, label: "ランキング")
            legendItem(color: .orange, label: "Amazon")
            legendItem(color: .blue, label: "新品")
            legendItem(color: .primary, label: "中古")
        }
        .frame(maxWidth: .infinity)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// グラフの直下に置く期間切替セグメント(1ヶ月/3ヶ月/1年/全期間)。
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
    /// 利益アラートの判定結果。発火時のみ緑バナー・縁取りを出す。非Pro/未評価はnil。
    let profitVerdict: ProfitAlertEvaluator.Verdict?
    /// 「仕」ボタンの表示可否(Pro限定)。依存は呼び出し元から引数で渡す(View内でEntitlementStoreを直接触らない)。
    let isPro: Bool
    /// 仕入れリストに追加済みか(追加済みならボタンを無効化して「追加済み」表示)。
    let isInPurchaseList: Bool
    /// 「仕入れリストへ追加」タップ時の処理(Pro)。
    let onAddToPurchaseList: () -> Void
    /// 「仕」ボタンタップ時の処理(非Pro。鍵バッジ付きボタンからペイウォールを開く)。
    let onLockedPurchaseTap: () -> Void
    /// 外部リンク(a/m/価)タップ時の処理。親側でアプリ内ブラウザ(SafariView)のシートを開く。
    let onOpenLink: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profitVerdict?.isTriggered == true {
                profitAlertBanner
            }

            cardContent
        }
        // カードは現在囲み枠なしのため、発火時のみ縁取りを付けて視認差を大きくする。
        .overlay(
            profitVerdict?.isTriggered == true
                ? RoundedRectangle(cornerRadius: 10).stroke(Color.green, lineWidth: 2)
                : nil
        )
    }

    /// 発火時のみ表示する緑バナー行(「利益条件クリア」+粗利があれば併記)。
    private var profitAlertBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text("利益条件クリア")
            if let grossMargin = profitVerdict?.grossMargin {
                Text("粗利 ¥\(Int(grossMargin))")
            }
        }
        .font(.caption)
        .fontWeight(.bold)
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.green)
        .cornerRadius(8)
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            // 画像URLが無い(見つからない商品等)場合、AsyncImageはempty phaseのまま
            // スピナーが永久に回り続けるため、URL有無で先に分岐してプレースホルダを出す。
            if let imageUrl = result.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: imageUrl) { phase in
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
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.secondary)
                    .padding(20)
                    .frame(width: 80, height: 80)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 6) {
                if result.codeType == .unresolved {
                    // コード形式非対応もカタログ未収載もここに来るが、カメラはEAN-13しか
                    // 読まないため実態はほぼ「商品が見つからない」。文言もそれに合わせる。
                    Text("見つかりません")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                } else {
                    Text(result.title ?? "(タイトル不明)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }

                // ISBN・ランキング列の右横に、アクションボタンを1列の横並びで置く。
                // ISBN/ランク側は自然幅(fixedSize)、ボタン側は残り幅を等分するため
                // 余白0でも4つが必ず収まる。
                // unresolvedカードはボタン全体を非表示(見つからない商品にリンクを出す意味が無いため)。
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "barcode.viewfinder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(scannedCode)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // 「ランク」の文字は商品タブと同じ折れ線グラフアイコンで表す。
                        // ランキングが取得できない商品は非表示にせず「圏外」と明示する
                        // (表示が無いと取得漏れなのか圏外なのか区別がつかないため)。
                        HStack(spacing: 6) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(result.salesRank.map { "\($0)位" } ?? "ランキング圏外")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    if result.codeType != .unresolved {
                        ResultCardActionButtons(
                            result: result,
                            isPro: isPro,
                            isInPurchaseList: isInPurchaseList,
                            onAddToPurchaseList: onAddToPurchaseList,
                            onLockedPurchaseTap: onLockedPurchaseTap,
                            onOpenLink: onOpenLink
                        )
                    }
                }
            }
        }
        // CHANGES-v6.1.md: カードの上下余白を0にし、薄灰色の囲み枠(background/cornerRadius)を削除。
        // 左右は現状維持(呼び出し元のScrollView側で.padding(.horizontal)を付与)。
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
    }
}

// MARK: - 結果カードのアクションボタングリッド(仕/a/m/価)

/// カード右側に置くアクションボタン列(1列横並び)。
/// 「仕」= 仕入れフォームを開く(Pro限定・ASINあり)。「a」= Amazon商品ページ、
/// 「m」= メルカリ検索、「価」= 価格.com検索(いずれも無料でも使え、タイトルが必要)。
/// unresolvedカードでは呼び出し元(LatestResultCardView)が非表示にする。
private struct ResultCardActionButtons: View {
    let result: SearchResult
    let isPro: Bool
    let isInPurchaseList: Bool
    let onAddToPurchaseList: () -> Void
    let onLockedPurchaseTap: () -> Void
    /// 外部リンク(a/m/価)タップ時の処理。親側でアプリ内ブラウザ(SafariView)のシートを開く。
    let onOpenLink: (URL) -> Void

    // ISBN・ランキングの2行(テキスト列)と高さを揃え、オファーパネルとの間の余白を無くす。
    private let buttonSize: CGFloat = 34

    /// 仕入れボタンを表示するか(ASINがあれば無料でも表示する。非Proは鍵バッジ付きにして
    /// タップ時にペイウォールを開く。ボタン自体を隠すと機能の存在に気付けないため、
    /// 「見えるが鍵がかかっている」形にする)。
    private var showsPurchaseButton: Bool {
        result.asin != nil
    }

    private var showsAmazonButton: Bool {
        result.asin != nil
    }

    private var showsMercariButton: Bool {
        result.title != nil
    }

    private var showsKakakuButton: Bool {
        result.title != nil
    }

    var body: some View {
        // ボタンを1列に横並びにする(ユーザー指示 2026-07-25)。無料ユーザーは「仕」だけ抜けて並ぶ。
        // 各ボタンは幅可変(maxWidth: .infinity)で全幅を等分するため、余白0でも見切れない。
        HStack(spacing: 6) {
            if showsPurchaseButton {
                actionButton(
                    label: "仕",
                    // 新品パネルと同系のモダンブルー(#3B82F6)。
                    color: Color(red: 0.23, green: 0.51, blue: 0.96),
                    isDisabled: isPro && isInPurchaseList,
                    systemOverlayImage: isPro && isInPurchaseList ? "checkmark" : nil,
                    showsLockBadge: !isPro,
                    action: isPro ? onAddToPurchaseList : onLockedPurchaseTap
                )
            }
            if showsAmazonButton {
                // Amazonブランドのオレンジ(#FF9900)。
                actionButton(label: "a", color: Color(red: 1.0, green: 0.60, blue: 0.0), action: openAmazon)
            }
            if showsMercariButton {
                // メルカリの赤に寄せたモダンレッド(#EF4444)。
                actionButton(label: "m", color: Color(red: 0.94, green: 0.27, blue: 0.27), action: openMercari)
            }
            if showsKakakuButton {
                // 価格.comの紺に寄せたモダンインディゴ(#6366F1)。
                actionButton(label: "価", color: Color(red: 0.39, green: 0.40, blue: 0.95), action: openKakaku)
            }
        }
    }

    /// 1個のボタンを描画する。追加済み(isInPurchaseList)のときはチェックマークに差し替えて無効化する。
    /// showsLockBadge:trueのときは右上に小さな鍵アイコンを重ね、Pro限定であることを示す
    /// (ボタン自体は隠さず押せる状態のまま。タップ時の遷移先はaction側で切り替える)。
    @ViewBuilder
    private func actionButton(
        label: String,
        color: Color,
        isDisabled: Bool = false,
        systemOverlayImage: String? = nil,
        showsLockBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 12)
                // ベタ塗りから同系色の斜めグラデーション+淡い色付きシャドウへ(パネルと同じ作法)。
                .fill(
                    isDisabled
                        ? AnyShapeStyle(Color.secondary)
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [color, color.darkened(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: isDisabled ? .clear : color.opacity(0.35), radius: 4, x: 0, y: 2)
                // 幅は全幅を等分(maxWidth: .infinity)、高さのみ固定して正方形風に見せる。
                .frame(maxWidth: .infinity)
                .frame(height: buttonSize)
                .overlay {
                    if let systemOverlayImage {
                        Image(systemName: systemOverlayImage)
                            .font(.headline)
                            .foregroundColor(.white)
                    } else {
                        // 「仕」「価」(CJK)と「a」「m」(ラテン文字)は同じポイント数だと
                        // ラテン文字が小さく見えるため、1バイト文字だけ大きめのサイズにして
                        // 見かけの大きさを揃える。
                        Text(label)
                            .font(.system(size: label.allSatisfy { $0.isASCII } ? 20 : 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showsLockBadge {
                        LockIconView(size: 13)
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    /// 商品名をURLクエリ用にエンコードする(全文。副題・シリーズ括弧も含む)。
    private func encodedTitle() -> String? {
        guard let title = result.title else { return nil }
        return title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    /// 商品名をShift_JISのパーセントエンコードに変換する(価格.com専用)。
    /// 価格.comの検索URLはShift_JIS前提のためUTF-8エンコードだと文字化け/404になる
    /// (実リクエストで確認済み)。Shift_JISに無い文字は損失変換で近似する。
    private func shiftJISEncodedTitle() -> String? {
        guard let title = result.title,
              let data = title.data(using: .shiftJIS, allowLossyConversion: true) else { return nil }
        return data.map { byte -> String in
            // RFC 3986のunreserved(英数字と-._~)のみ素通しし、他は%XXにする。
            let isUnreserved =
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x2E
                || byte == 0x5F || byte == 0x7E
            return isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    /// Amazonの出品者一覧(すべての出品を表示)を開く。商品ページではなく相場が一覧できる
    /// aod=1 のページへ直接飛ばす(せどりでは出品者と価格の一覧を見たいため)。
    private func openAmazon() {
        guard let asin = result.asin,
              let url = URL(string: "https://www.amazon.co.jp/dp/\(asin)/ref=olp-opf-redir?aod=1") else { return }
        onOpenLink(url)
    }

    private func openMercari() {
        guard let encoded = encodedTitle(),
              let url = URL(string: "https://jp.mercari.com/search?keyword=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openKakaku() {
        guard let encoded = shiftJISEncodedTitle(),
              let url = URL(string: "https://kakaku.com/search_results/\(encoded)/") else { return }
        onOpenLink(url)
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
    /// /api/search応答の簡易価格。オファー一覧(SP-API経路のみ)が無い/取得0件のときの
    /// 仮表示にのみ使う。オファーが取得できたら下のオファー一覧で上書きする。
    let simplePrice: Int?
    /// 簡易価格行のラベル("新品"/"中古")。
    let simpleLabel: String
    /// 送料が実データで返る経路か(SP-API経路のみtrue)。送料0を「送料無料」と表示してよいかの判定に使う。
    let isShippingKnown: Bool

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
                LockIconView(size: 18)
                Text("設定→Amazon連携で表示")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
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
                // ヘッダー帯はベタ塗りをやめ、グラデーション背景の上に半透明白を重ねて
                // 本体との区切りを柔らかく見せる。
                .background(Color.white.opacity(0.16))

            VStack(alignment: .leading, spacing: 4) {
                if isLocked {
                    // 無料&Keepa: 簡易価格は見せ、オファー一覧はぼかしダミー+鍵でロック(タップでペイウォール)。
                    simplePriceRow
                    lockedOffersTeaser
                } else if !offers.isEmpty {
                    // オファー取得済み(SP-API経路。/api/searchに同梱): 送料込・最安値順・コンディション付きで
                    // 上から並べる。簡易価格はここで上書きされる。
                    // 全件を出すとカードが縦に伸びてしまうため、5件分の高さに収めて中でスクロールさせる
                    // (6件目以降もパネル内スクロールで見られる)。
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedOffers) { offer in
                                HStack(spacing: 4) {
                                    // Amazon本体の在庫は「新品(Ama)」と表示して区別する。
                                    Text(offer.panelConditionLabel)
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    // 価格は送料込み。送料があれば「¥1200(送257)」と内訳を添える。
                                    Text(offer.panelPriceLabel(shippingKnown: isShippingKnown))
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                        }
                    }
                    // 1行あたり約20pt(caption+spacing4)として5件分。オファーが5件以下なら
                    // その分だけの高さに収まり余白は出ない。
                    .frame(maxHeight: CGFloat(min(sortedOffers.count, 5)) * 20)
                } else if isLoading {
                    // オファー読込中: 簡易価格を仮表示しつつスピナー(オファー到着で上書き)。
                    // 現在は/api/searchが同期でオファーを返す(ロック時を除く)ため、実質到達しない。
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
        // ベタ塗り(opacity 0.85)から、同系色の斜めグラデーション+淡い色付きシャドウへ。
        // 白文字はそのままなのでライト/ダークどちらのモードでも成立する。
        .background(
            LinearGradient(
                colors: [color, color.darkened(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(14)
        .shadow(color: color.opacity(0.35), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - モダン配色ヘルパー

private extension Color {
    /// 明度を下げた色を返す(グラデーションの終端用)。
    /// iOS16対応のためColor.mix(iOS18+)は使わず、HSB分解で明度のみ落とす。
    func darkened(_ amount: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: h, saturation: s, brightness: max(0, b - amount), opacity: a)
    }
}
