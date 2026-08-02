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
    /// Keepa混雑(keepa_busy)時の文言。セット時は専用の混雑カード(再試行+誘導)を出す。
    /// searchErrorMessage(汎用エラー)とは排他(どちらか一方のみセットされる)。
    @Published var keepaBusyMessage: String?

    /// SP-API経路のとき/api/search応答に同梱されるオファー一覧。Keepa経路ではnil。
    @Published var offersResult: OffersResult?
    /// オファー読み込み中フラグ
    @Published var isLoadingOffers = false
    /// フリーミアム: 無料プラン&Keepa経路でオファーがPro限定ロックされている状態。
    /// このときは実データを取得せず、パネルにぼかしダミー+鍵を表示する。
    @Published var offersLocked = false

    /// 利益アラートの判定結果。Proかつ検索成功時のみ評価する。未評価/非Proはnil。
    @Published var profitAlertVerdict: ProfitAlertEvaluator.Verdict?

    /// 出品制限(出品許可申請が必要か)の判定結果。trueのときだけカードに警告バッジを出す。
    /// Pro+SP-API連携(sellerIdまで取得済み)でなければチェック自体を行わずfalseのまま。
    @Published var isListingRestricted = false

    private let apiClient: APIClient
    private let historyStore: ScanHistoryStore

    /// 直近history追加したエントリのid。オファー同梱時にこのidの履歴を更新するために保持する。
    private var pendingHistoryItemId: UUID?

    /// 出品制限チェックの実行連番。完了時に最新でなければ結果を捨てる(連続スキャン時の順序ずれ対策)。
    private var restrictionCheckSequence = 0

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
        keepaBusyMessage = nil
        latestScannedCode = code
        latestResult = nil
        offersResult = nil
        isLoadingOffers = false
        offersLocked = false
        pendingHistoryItemId = nil
        profitAlertVerdict = nil
        isListingRestricted = false

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

            startListingRestrictionCheck(asin: result.asin)

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
            if case APIClientError.keepaBusy(let message) = error {
                // 混雑は専用カード(再試行+SP-API/Keepaキー誘導)で表示する。
                // searchErrorMessage(赤文字の汎用エラー)には流さない。
                keepaBusyMessage = message ?? "混み合っているので時間を空けてお試しください。"
            } else if case APIClientError.quotaExceeded(let quota, _) = error {
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

    /// 出品制限チェックを開始する。Pro+SP-API連携済み(sellerId取得済み)のときだけAPIを呼ぶ。
    /// 未連携・無料プラン・ASIN不明のときは何もしない(バッジは出ない)。
    ///
    /// コンディションは仕入れフォームで直近使ったもの(未使用なら新品)で問い合わせる。
    /// 出品可否はコンディション単位で決まるため、実際に出品する状態で判定するのが最も実態に近い。
    ///
    /// 連続スキャンで古い結果が新しい結果を上書きしないよう、PurchaseFormViewと同じ連番ガードを使う。
    private func startListingRestrictionCheck(asin: String?) {
        guard let asin,
              EntitlementStore.shared.isPro,
              SettingsStore.shared.isListingReady else { return }

        restrictionCheckSequence += 1
        let sequence = restrictionCheckSequence
        let condition = SettingsStore.shared.lastListingCondition ?? .newNew

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.apiClient.listingsRestrictions(
                    asin: asin,
                    condition: condition.rawValue
                )
                guard sequence == self.restrictionCheckSequence else { return }
                self.isListingRestricted = result.restricted
            } catch {
                // チェックに失敗したときは「制限あり」と誤表示しない(バッジを出さない)。
                guard sequence == self.restrictionCheckSequence else { return }
                self.isListingRestricted = false
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
    /// 手入力検索がクールダウンで弾かれたことをScannerViewへ伝えるための通知。
    /// カメラのスキャンと同じ「あと◯秒」オーバーレイで見せるため、専用のポップアップは出さない。
    @State private var cooldownNotice: ScannerView.CooldownNotice?
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
            // クールダウンはプランではなく「連携の有無」で決める。未連携の検索はProでも
            // Keepaトークンを1回1個消費するため、高速連続スキャンを許すと数分でトークンが
            // 枯れてしまう。連携済み(SP-API経路=消費ゼロ)のみ高速スキャンを許可する。
            emitCooldown: searchCooldown,
            cooldownNotice: cooldownNotice
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

    /// スキャン・手入力で共通のクールダウン秒数。未連携は検索1回ごとにKeepaトークンを
    /// 1個消費するため長め(7秒)、連携済み(SP-API経路=消費ゼロ)は重複読み取り防止程度(1秒)。
    private var searchCooldown: TimeInterval { settings.isSpApiLinkUsable ? 1.0 : 7.0 }

    /// スキャン(カメラ/OCR)・手入力検索の共通ゲート。無料枠ユニットの残量を確認し、
    /// 残っていればローカルミラーを楽観的に1消費してから検索を実行する。
    /// 枠切れのときはペイウォールを提示する。枠切れ中はカメラが止まる(isScannerActive)ため
    /// ここに枠切れで到達するのは手入力検索の経路だが、黙って無反応にすると
    /// 「検索できない理由」が分からないため必ず理由を示す。
    ///
    /// クールダウンの起点(最後に検索した時刻)はカメラ側と共有する(SearchCooldownStore)。
    /// 経路ごとに別々のタイマーを持つと「スキャン直後に手入力」ですり抜けられるため。
    /// 弾いたときはカメラ上の「あと◯秒」オーバーレイで伝える(スキャン時と同じ見せ方)。
    private func startSearch(_ code: String) {
        guard isSearchUnlimited || quota.canScanToday else {
            showPaywall = true
            return
        }
        let remaining = SearchCooldownStore.shared.remainingSeconds(cooldown: searchCooldown)
        if remaining > 0 {
            cooldownNotice = ScannerView.CooldownNotice(id: UUID(), remaining: remaining)
            return
        }
        SearchCooldownStore.shared.markSearched()
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

    /// Keepa混雑(keepa_busy)時のカード。再試行と、混雑を回避できる連携への誘導を出す
    /// (混雑を連携・課金の入口に変える。設計書§2.3)。
    private func keepaBusyCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Button {
                // 再スキャン不要で同じコードを再検索する。startSearch(カメラ用クールダウン)は
                // 通さない(混雑待ちからの再試行にスキャン間隔の制限を重ねる意味が無いため)。
                if let code = viewModel.latestScannedCode {
                    viewModel.handleScan(code)
                }
            } label: {
                Label("再試行", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)

            // 誘導: 未連携ならSP-API連携、Pro(連携済み)でBYOキー未設定ならKeepaキー設定。
            if !settings.isSpApiLinkUsable {
                Button {
                    AppNavigation.shared.selectedTab = AppNavigation.settingsTab
                } label: {
                    Text("Amazon連携なら自分の枠で待たずに検索できます →")
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else if entitlements.isPro && !settings.isKeepaKeyUsable {
                Button {
                    AppNavigation.shared.selectedTab = AppNavigation.settingsTab
                } label: {
                    Text("Keepa APIキーを設定するとグラフも自分の枠で取得できます →")
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var destinationView: some View {
        if let selectedResult, let asin = selectedResult.asin {
            // 検索時に取得済みのオファーをそのまま渡す(別リクエストでの再取得はしない)。
            ProductDetailView(
                asin: asin,
                title: selectedResult.title,
                imageUrl: selectedResult.imageUrl,
                cachedOffers: viewModel.offersResult,
                janCode: selectedResult.isbn13 ?? viewModel.latestScannedCode,
                salesRank: selectedResult.salesRank,
                listPrice: selectedResult.profitInputs?.listPrice,
                releaseDate: selectedResult.releaseDate,
                prices: selectedResult.prices
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
                isListingRestricted: viewModel.isListingRestricted,
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
        } else if let busyMessage = viewModel.keepaBusyMessage {
            keepaBusyCard(message: busyMessage)
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
                    color: OffersPanelColors.newBlue,
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
                    color: OffersPanelColors.usedOrange,
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
                // チャート本体・凡例(メイン/出品者数とも)はPriceHistoryChartView側で描画する。
                PriceHistoryChartView(asin: asin, range: selectedGraphRange)
                graphRangeSegment
            }
        }
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
    /// 利益アラートの判定結果。発火時のみ緑の縁取りを出す。非Pro/未評価はnil。
    let profitVerdict: ProfitAlertEvaluator.Verdict?
    /// 出品制限あり(出品許可申請が必要)。trueのときタイトル右に警告バッジを出す。
    let isListingRestricted: Bool
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
        cardContent
            // 発火時は文言を出さず緑の縁取りだけで示す(ユーザー指示 2026-08-02)。
            // 線幅は従来2ptの1.5倍=3pt。
            .overlay(
                profitVerdict?.isTriggered == true
                    ? RoundedRectangle(cornerRadius: 10).stroke(Color.green, lineWidth: 3)
                    : nil
            )
    }

    /// 出品制限あり(出品許可申請が必要)を示す警告バッジ。警告マークの下に「出品制限」を置く。
    private var listingRestrictedBadge: some View {
        VStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
            Text("出品制限")
                .font(.system(size: 10))
                .fontWeight(.bold)
        }
        .foregroundColor(.orange)
        // 発火時の緑の縁取りに文字が接触しないよう右に少し逃がす。
        .padding(.trailing, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("出品制限あり。出品許可申請が必要です")
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
                    // 出品制限バッジはタイトル右上に置く。タイトルは残り幅で折り返すため
                    // バッジ側を自然幅(fixedSize)にして、タイトルが伸びても押し出されないようにする。
                    HStack(alignment: .top, spacing: 6) {
                        Text(result.title ?? "(タイトル不明)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if isListingRestricted {
                            listingRestrictedBadge
                                .fixedSize()
                        }
                    }
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

// MARK: - 結果カードのアクションボタングリッド(設定で選んだ4種)

/// カード右側に置くアクションボタン列(1列横並び)。表示する4種類は設定
/// (SettingsStore.linkButtons)で選べる(既定: 仕入れ/Amazon/メルカリ/楽天市場)。
/// 「仕入れ」= 仕入れフォームを開く(Pro限定・ASINあり)。それ以外は各サービスの検索/商品ページを
/// アプリ内ブラウザで開く(いずれも無料でも使え、検索キーワードが必要)。
/// unresolvedカードでは呼び出し元(LatestResultCardView)が非表示にする。
private struct ResultCardActionButtons: View {
    let result: SearchResult
    let isPro: Bool
    let isInPurchaseList: Bool
    let onAddToPurchaseList: () -> Void
    let onLockedPurchaseTap: () -> Void
    /// 外部リンクタップ時の処理。親側でアプリ内ブラウザ(SafariView)のシートを開く。
    let onOpenLink: (URL) -> Void

    /// 表示ボタンの選択・型番検索設定を直接参照する。
    @ObservedObject private var settings = SettingsStore.shared
    /// 楽天アフィリエイトID等、サーバー管理のアフィリエイト設定を直接参照する
    /// (利用者ごとの値ではなくアプリ運営者の収益設定のためSettingsStoreではなくこちら)。
    @ObservedObject private var adsConfig = AdsConfigStore.shared

    // ISBN・ランキングの2行(テキスト列)と高さを揃え、オファーパネルとの間の余白を無くす。
    private let buttonSize: CGFloat = 34

    /// 設定で選ばれている4つのうち、実際に表示条件を満たすものだけを順序維持で並べる
    /// (条件を満たさないボタンは並びから抜ける。既存の挙動と同じ)。
    private var visibleButtons: [LinkButtonKind] {
        settings.linkButtons.filter(showsButton)
    }

    private func showsButton(_ kind: LinkButtonKind) -> Bool {
        switch kind {
        case .purchase, .amazon, .keepa:
            // ASINが無いと仕入れフォーム・Amazon商品ページ・Keepa商品ページのどれも開けない。
            return result.asin != nil
        case .mercari, .kakaku, .rakuten, .yahooShopping, .yahooAuction, .rakuma:
            // 検索キーワード(型番 or タイトル)が無ければ検索リンクを組み立てられない。
            return searchKeyword != nil
        }
    }

    /// 検索キーワードの決定ルール。型番優先設定がONかつ型番が非空ならそれを使い、
    /// それ以外(OFF、または型番の無い商品=書籍など)はタイトルにフォールバックする。
    /// 型番が無いカテゴリでリンクボタンごと使えなくなるのを避けるための自動フォールバック。
    private var searchKeyword: String? {
        if settings.linkSearchByModelNumber,
           let modelNumber = result.modelNumber,
           !modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return modelNumber
        }
        return result.title
    }

    var body: some View {
        // ボタンを1列に横並びにする(ユーザー指示 2026-07-25)。表示条件を満たさない種類は抜けて並ぶ。
        // 各ボタンは幅可変(maxWidth: .infinity)で全幅を等分するため、余白0でも見切れない。
        HStack(spacing: 6) {
            ForEach(visibleButtons) { kind in
                buttonView(for: kind)
            }
        }
    }

    @ViewBuilder
    private func buttonView(for kind: LinkButtonKind) -> some View {
        switch kind {
        case .purchase:
            actionButton(
                label: kind.label,
                color: kind.color,
                labelColor: kind.labelColor,
                isDisabled: isPro && isInPurchaseList,
                // 追加済みはチェックマーク、通常は仕入れタブと同じカゴのアイコン。
                systemOverlayImage: isPro && isInPurchaseList ? "checkmark" : kind.iconSystemName,
                accessibilityLabel: kind.displayName,
                showsLockBadge: !isPro,
                action: isPro ? onAddToPurchaseList : onLockedPurchaseTap
            )
        default:
            actionButton(
                label: kind.label,
                color: kind.color,
                labelColor: kind.labelColor,
                labelFontScale: kind.labelFontScale,
                labelFontWeight: kind.labelFontWeight,
                labelFontDesign: kind.labelFontDesign,
                systemOverlayImage: kind.iconSystemName,
                accessibilityLabel: kind.displayName,
                action: { open(kind) }
            )
        }
    }

    /// 1個のボタンを描画する。追加済み(isInPurchaseList)のときはチェックマークに差し替えて無効化する。
    /// showsLockBadge:trueのときは右上に小さな鍵アイコンを重ね、Pro限定であることを示す
    /// (ボタン自体は隠さず押せる状態のまま。タップ時の遷移先はaction側で切り替える)。
    @ViewBuilder
    private func actionButton(
        label: String,
        color: Color,
        labelColor: Color = .white,
        labelFontScale: CGFloat = 1.0,
        labelFontWeight: Font.Weight = .bold,
        labelFontDesign: Font.Design = .default,
        isDisabled: Bool = false,
        systemOverlayImage: String? = nil,
        accessibilityLabel: String? = nil,
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
                            .foregroundColor(labelColor)
                    } else {
                        LinkButtonGlyphLabel(
                            text: label,
                            size: fontSize(for: label) * labelFontScale,
                            weight: labelFontWeight,
                            design: labelFontDesign,
                            color: labelColor
                        )
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
        // アイコン表示のボタン(ヤフオク)は記号だけでは何のボタンか読み上げられないため、
        // サービス名を読み上げラベルにする。
        .accessibilityLabel(accessibilityLabel ?? label)
    }

    /// ラベルの文字種・文字数に応じてフォントサイズを調整する。
    /// 「仕」「価」「楽」「ラ」等の1文字CJKと「a」「Y」等の1文字ASCIIは同じポイント数だと
    /// ASCIIの方が小さく見えるため、ASCIIだけ大きめ(20pt)にして見かけの大きさを揃える
    /// (既存の作法)。「オク」のような2文字CJKラベルはそのまま15ptだとボタン幅に収まらず
    /// 見切れるおそれがあるため、さらに小さい11ptにしたうえでminimumScaleFactorも併用して
    /// 狭い端末幅でも確実に収まるようにする。
    private func fontSize(for label: String) -> CGFloat {
        if label.allSatisfy({ $0.isASCII }) { return 20 }
        if label.count >= 2 { return 11 }
        return 15
    }

    /// 検索キーワードをURLクエリ用にエンコードする(全文)。
    private func encodedKeyword() -> String? {
        guard let keyword = searchKeyword else { return nil }
        return keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    /// 検索キーワードをShift_JISのパーセントエンコードに変換する(価格.com専用)。
    /// 価格.comの検索URLはShift_JIS前提のためUTF-8エンコードだと文字化け/404になる
    /// (実リクエストで確認済み)。Shift_JISに無い文字は損失変換で近似する。
    private func shiftJISEncodedKeyword() -> String? {
        guard let keyword = searchKeyword,
              let data = keyword.data(using: .shiftJIS, allowLossyConversion: true) else { return nil }
        return Self.strictPercentEncoded(bytes: data)
    }

    /// RFC 3986のunreserved文字(英数字と-._~)のみ素通しし、他は%XXにする厳密なパーセントエンコード。
    /// バイト列を直接エンコードするため、Shift_JIS(価格.com)にも楽天アフィリエイトURLの
    /// 丸ごとエンコード(`:`や`/`も含める)にも共通で使える。
    private static func strictPercentEncoded<S: Sequence>(bytes: S) -> String where S.Element == UInt8 {
        bytes.map { byte -> String in
            let isUnreserved =
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x2E
                || byte == 0x5F || byte == 0x7E
            return isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    /// 文字列全体(URL全体など)をRFC3986 unreserved文字以外パーセントエンコードする。
    /// `.urlHostAllowed`等のCharacterSetベースのエンコードは`:`や`/`を素通ししてしまい、
    /// 楽天アフィリエイトのpc/mパラメータ(URL全体をエンコードして渡す仕様)には使えないため、
    /// UTF-8バイト列を直接エンコードするこちらを使う。
    private static func strictPercentEncoded(string: String) -> String {
        strictPercentEncoded(bytes: Array(string.utf8))
    }

    private func open(_ kind: LinkButtonKind) {
        switch kind {
        case .purchase:
            // buttonView側で個別処理するためここには来ない。
            break
        case .amazon:
            openAmazon()
        case .mercari:
            openMercari()
        case .kakaku:
            openKakaku()
        case .rakuten:
            openRakuten()
        case .yahooShopping:
            openYahooShopping()
        case .yahooAuction:
            openYahooAuction()
        case .rakuma:
            openRakuma()
        case .keepa:
            openKeepa()
        }
    }

    /// Amazonの出品者一覧(すべての出品を表示)を開く。商品ページではなく相場が一覧できる
    /// aod=1 のページへ直接飛ばす(せどりでは出品者と価格の一覧を見たいため)。
    private func openAmazon() {
        guard let asin = result.asin,
              let url = URL(string: "https://www.amazon.co.jp/dp/\(asin)/ref=olp-opf-redir?aod=1") else { return }
        onOpenLink(url)
    }

    private func openMercari() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://jp.mercari.com/search?keyword=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openKakaku() {
        guard let encoded = shiftJISEncodedKeyword(),
              let url = URL(string: "https://kakaku.com/search_results/\(encoded)/") else { return }
        onOpenLink(url)
    }

    /// 楽天市場検索を開く。サーバー配信のアフィリエイトID設定済みなら楽天アフィリエイトリンクで
    /// ラップする(IDはアプリ運営者の収益設定のためAdsConfigStore=/api/adsから取得する。
    /// 利用者が設定画面で入力する項目ではない)。
    private func openRakuten() {
        guard let encoded = encodedKeyword() else { return }
        let searchURLString = "https://search.rakuten.co.jp/search/mall/\(encoded)/"

        let affiliateId = (adsConfig.affiliates["rakuten"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURLString: String
        if affiliateId.isEmpty {
            finalURLString = searchURLString
        } else {
            // 楽天アフィリエイトの仕様: pc=PC用遷移先URL、m=モバイル用遷移先URLをそれぞれ
            // URLエンコードして渡す(PC/モバイル別々のURLを指定できる仕組みだが、ここでは
            // 同じ楽天検索URLを両方に渡す)。値はURL全体(`:`や`/`含む)をエンコードする必要が
            // あるため、.urlHostAllowed等ではなく上のstrictPercentEncoded(string:)を使う。
            let encodedTarget = Self.strictPercentEncoded(string: searchURLString)
            finalURLString = "https://hb.afl.rakuten.co.jp/hgc/\(affiliateId)/?pc=\(encodedTarget)&m=\(encodedTarget)"
        }
        guard let url = URL(string: finalURLString) else { return }
        onOpenLink(url)
    }

    /// Yahoo!ショッピング検索を開く。アフィリエイトは利用者側にIDが無いため未対応
    /// (将来対応する場合はここに楽天と同様のラップ処理を追加する)。
    private func openYahooShopping() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://shopping.yahoo.co.jp/search?p=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openYahooAuction() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://auctions.yahoo.co.jp/search/search?p=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openRakuma() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://fril.jp/s?query=\(encoded)") else { return }
        onOpenLink(url)
    }

    /// Keepaの該当商品ページを開く。domain=5はamazon.co.jpのロケールID
    /// (server/src/keepa/client.js の JP_DOMAIN_ID と同じ値。Keepa公式のURL規約
    /// `https://keepa.com/#!product/{domain}-{ASIN}` に準拠)。
    private func openKeepa() {
        guard let asin = result.asin,
              let url = URL(string: "https://keepa.com/#!product/5-\(asin)") else { return }
        onOpenLink(url)
    }
}
