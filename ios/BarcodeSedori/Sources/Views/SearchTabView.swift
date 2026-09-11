import SwiftUI
import UIKit
import AudioToolbox
import StoreKit

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
    static let quotaFallbackMessage = "本日の無料スキャン上限に達しました。Proにアップグレードすると無制限に使えます。"

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
    /// 直近の検索が無料枠ユニット上限超過(429・quota_exceeded)で拒否されたか。
    ///
    /// グラフ表示の可否判定に「次のスキャンができるか」(ScanQuotaStore.canScanToday=
    /// unitsRemaining>0)を使うと、スキャン開始時点で楽観的に1減らすconsumeLocally()の影響で、
    /// ちょうど無料枠を使い切る最後の1回(例: 1日5回のうち5回目)は「検索自体は許可され結果も
    /// 返ってきているのに、その時点でunitsRemainingが0のためグラフだけ非表示になる」という
    /// ズレが起きる。「今回の検索結果が枠切れで拒否されたかどうか」はunitsRemainingという
    /// 未来向きの値ではなく、この検索自体の成否で判定する必要があるため専用フラグを持つ。
    @Published var lastSearchQuotaExceeded = false

    /// 今回の検索に対するグラフ取得(/api/graph-data)が枠切れで拒否されたか。
    /// lastSearchQuotaExceededとは別に持つ必要がある: Amazon連携済みの無料ユーザーは
    /// 検索がSP-API経路になり無料枠を消費しない(=検索は成功する)一方、グラフは常に
    /// Keepa経路で枠を消費するため、「検索は成功したがグラフだけ枠切れ」が起こりうる。
    /// このフラグが無いと、その状態でグラフ枠に「グラフを一時的に取得できません」という
    /// 誤った案内(再読込しても直らない)が出てしまう。
    @Published var lastGraphQuotaExceeded = false

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

    /// 購入前に表示した無料枠エラーだけを、Pro化した時点で消す。
    /// ネットワークエラーなど別の失敗表示は購入操作だけでは隠さない。
    func clearQuotaFallbackAfterProActivation() {
        guard lastSearchQuotaExceeded || searchErrorMessage == Self.quotaFallbackMessage else { return }
        searchErrorMessage = nil
        lastSearchQuotaExceeded = false
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
    func handleScan(_ code: String, source: AnalyticsEvent.SearchSource) {
        // 新しいスキャンが来たらカード・パネル・グラフ用の状態を全てリセットしてから再取得する。
        isSearching = true
        searchErrorMessage = nil
        keepaBusyMessage = nil
        lastSearchQuotaExceeded = false
        lastGraphQuotaExceeded = false
        latestScannedCode = code
        latestResult = nil
        offersResult = nil
        isLoadingOffers = false
        offersLocked = false
        pendingHistoryItemId = nil
        profitAlertVerdict = nil
        isListingRestricted = false

        Task { await self.search(code: code, source: source) }
    }

    private func search(code: String, source: AnalyticsEvent.SearchSource) async {
        do {
            let result = try await apiClient.search(code: code)
            latestResult = result
            isSearching = false
            ReviewPromptController.shared.recordSearchSucceeded()
            // ATT(トラッキング許可)事前説明の表示要否を判定する(4回スキャンしたら候補になる)。
            AttPromptController.shared.recordScanSucceeded()
            // 検索経路(バーコード/OCR/手入力)のみを送る。コード自体・商品名は送らない(DPP制約)。
            Analytics.shared.capture(.searchSucceeded(source: source))
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
                // profitAlertVerdictはhandleScan冒頭でnilにリセット済みなので、非Proのときはnilのまま
                // (=「判定していない」)になる。falseにしてしまうと「判定して該当しなかった」と
                // 区別できなくなるため、isTriggeredの値をそのまま(nilを保ったまま)渡す。
                let historyItem = ScanHistoryItem(
                    scannedCode: code,
                    result: result,
                    profitAlertTriggered: profitAlertVerdict?.isTriggered
                )
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
            // 検索失敗はエラー種別を問わずネガティブイベントとして記録する(レビュー依頼の抑制用)。
            ReviewPromptController.shared.recordNegativeEvent()
            // 無料枠ユニット上限超過(429・quota_exceeded)。quotaを反映すればisQuotaExhaustedが
            // trueになりQuotaPaywallOverlayが自動的に表示されるため、ここでは
            // searchErrorMessageを設定しない(同じ内容の赤文字が二重に出るのを避けるため)。
            if case APIClientError.keepaBusy(let message) = error {
                // 混雑は専用カード(再試行+SP-API/Keepaキー誘導)で表示する。
                // searchErrorMessage(赤文字の汎用エラー)には流さない。
                keepaBusyMessage = message ?? "混み合っているので時間を空けてお試しください。"
                Analytics.shared.capture(.searchFailed(reason: .keepaBusy))
            } else if case APIClientError.quotaExceeded(let quota, _) = error {
                ScanQuotaStore.shared.apply(quota)
                lastSearchQuotaExceeded = true
                Analytics.shared.capture(.searchFailed(reason: .quotaExceeded))
            } else if case APIClientError.httpError(let status, _) = error, status == 429 {
                // quota_exceeded形式でない429(旧サーバー互換)のフォールバック。
                // こちらはquotaを受け取れずオーバーレイが自動では出ないため、文言で案内する。
                searchErrorMessage = Self.quotaFallbackMessage
                lastSearchQuotaExceeded = true
                Analytics.shared.capture(.searchFailed(reason: .network))
            } else {
                // error.localizedDescriptionには識別子が含まれ得るため、Analyticsへは分類名のみ送る。
                searchErrorMessage = error.localizedDescription
                Analytics.shared.capture(.searchFailed(reason: .other))
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
    /// OCRの無料枠(1日5回)を使い切った際のポップアップ(スキャン時・モード切替タップ時とも共通)。
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
    /// App Storeレビュー依頼(起動トリガー)。iOS 16+のApple推奨経路で、呼び出すと
    /// システムが自らの裁量で表示するかどうかを決める(必ず出るわけではない)。
    @Environment(\.requestReview) private var requestReview
    /// ATT(トラッキング許可)事前説明ダイアログの表示状態。
    @ObservedObject private var attPrompt = AttPromptController.shared
    /// カメラへのアクセス許可状態。未許可時の案内オーバーレイの表示可否に使う。
    @ObservedObject private var cameraPermission = CameraPermissionStore.shared
    /// 設定アプリから戻ってきたときにカメラ許可状態を再取得するため監視する。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            // 全体を1つのScrollViewにする(検索バーも中に含める)。ScrollViewがキーボード回避を
            // 適切に処理するため、結果表示中にキーボードを出しても検索バーが画面外へ消えない。
            // 広告バナーはこのScrollViewの外(下)に置き、スクロール位置に関わらず画面下部に
            // 固定表示する(連携済み/未連携どちらのユーザーでも同じ位置に固定する)。
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        searchBar

                        topContent

                        if showsGraph {
                            keepaGraph
                        } else {
                            freeAdArea
                        }
                    }
                }

                // 検索広告バナー。ScrollViewの外に置くことで画面下部に固定し、スクロールしても
                // 流れない(非Pro全員が対象。他の広告枠と同じく、7日間お試し中も広告は隠さない
                // =isProのみで判定)。枠切れ時のfreeAdAreaにも同じスロットIDの広告を出すと
                // 二重表示になるため、ここへ集約した(freeAdArea側からはAdSlotViewを取り除いてある)。
                if !entitlements.isPro {
                    AdSlotView(slotId: "search_ad")
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
                Button("アップグレード") {
                    ReviewPromptController.shared.recordNegativeEvent()
                    Analytics.shared.capture(.paywallShown(trigger: .ocrLimitAlert))
                    showPaywall = true
                }
                Button("閉じる", role: .cancel) {}
            }
            // 無料枠を使い切った瞬間にOCRモードのままだと、カメラ停止後もOCRトグルが選択された
            // 見た目のまま残ってしまうため、枠切れになったらバーコードモードへ強制的に戻す。
            .onChange(of: isQuotaExhausted) { exhausted in
                if exhausted && viewModel.scanMode == .ocr {
                    viewModel.scanMode = .barcode
                }
            }
            // 購入前の429表示が画面に残っていても、Pro化した時点で無料枠の案内を消す。
            // 次の検索が429になった場合はsearch()が新しいエラーとして表示する。
            .onChange(of: entitlements.isPro) { isPro in
                if isPro {
                    viewModel.clearQuotaFallbackAfterProActivation()
                }
            }
            // 残りが少なくなった時点で広告を先読みしておく。枠切れオーバーレイが出てから
            // 読み込むと「動画を見てスキャンを続ける」をタップしてから数秒待たされるため。
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
                // デバッグ専用の注入経路(実ユーザーには発生しない)。分類上は手入力扱いにする。
                startSearch(code, source: .manual)
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
        // ATT事前説明ダイアログ。告知ポップアップ(RootTabView/NoticePopupView)と同じ
        // 「.overlay { if ... } + .transition(.opacity) + .animation(...)」の流儀に揃える。
        .overlay {
            if attPrompt.isShowingPrimer {
                AttPrimerDialog(
                    onProceed: { attPrompt.proceedToSystemPrompt() },
                    onPostpone: { attPrompt.postpone() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: attPrompt.isShowingPrimer)
        // ATTの事前説明とレビュー依頼が同時に出ると最悪なので、事前説明が表示された瞬間に
        // ネガティブイベントとして記録し、5分間はレビュー依頼を抑制する
        // (NoticeStore.refresh()が告知ポップアップに対して行っているのと同じ手法)。
        .onChange(of: attPrompt.isShowingPrimer) { isShowing in
            if isShowing {
                ReviewPromptController.shared.recordNegativeEvent()
            }
        }
        // レビュー依頼(起動トリガー)。無料/Keepa-BYOユーザーはSP-API連携が要る一括出品
        // トリガーに届かないため、この起動トリガーだけが唯一のレビュー依頼経路になる。
        .task {
            await checkLaunchReviewTriggerIfNeeded()
        }
        // 設定アプリでカメラ許可を変更してアプリへ戻ってきたとき、案内オーバーレイを
        // 即座に消す(または出す)ためにアクティブ復帰のたびに最新状態を取り直す。
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                CameraPermissionStore.shared.refresh()
            }
        }
    }

    /// 起動のたびに1回だけ、少し待ってから「今アイドル状態か」を再確認してレビュー依頼を検討する。
    /// 2.5秒待つのは起動直後の他ダイアログ(ATT等)と競合しないための間。
    /// 待っている間にスキャン・検索が始まっていたら、ユーザーの作業に割り込まないよう何もしない。
    private func checkLaunchReviewTriggerIfNeeded() async {
        guard ReviewPromptController.shared.shouldCheckLaunchTrigger() else { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard !viewModel.isSearching, viewModel.latestResult == nil else { return }
        guard ReviewPromptController.shared.consumeEligibility(trigger: .launch) else { return }
        requestReview()
    }

    /// 検索(=Keepa消費)が無制限か。Proと、SP-API連携済み(自分のAPI枠を使うためサーバーはユニットを消費しない)。
    /// スキャン枠はサーバー側がX-App-Planで判定するためisPro自体は広げないが、連携済みなら
    /// settings.isSpApiLinkUsableの方で既に無制限になるため、お試し中のユーザーも実質困らない。
    private var isSearchUnlimited: Bool { entitlements.isPro || settings.isSpApiLinkUsable }
    /// 無料枠を使い切っており、これ以上スキャンできないか。
    ///
    /// 検索中(isSearching)は判定しない。startSearchが開始時にconsumeLocally()で楽観的に
    /// 1減らすため、最後の1回(例: 5回目)を始めた瞬間にunitsRemainingが0になる。ところが
    /// サーバーがキャッシュから返した場合は枠を消費しないので、応答が届くと残量が元に戻る。
    /// その結果「本日の無料スキャンを使い切りました」が一瞬だけ出て消える。既にスキャン済みの
    /// 商品を読み直したときに実際に発生した(サーバーのキャッシュに当たるため)。
    ///
    /// 検索中に伏せても取りこぼしは無い。枠が本当に尽きている状態での次のスキャンは
    /// startSearchの冒頭で弾かれ、isSearchingがtrueにならないため。
    ///
    /// この値はオーバーレイの表示だけでなくカメラの停止(isScannerActive)と
    /// OCRモードの強制解除(.onChange)にも使われており、一瞬の誤検知はそれらも巻き添えにする。
    private var isQuotaExhausted: Bool {
        !isSearchUnlimited && !quota.canScanToday && !viewModel.isSearching
    }

    /// グラフ枠(keepaGraph)を出してよいか。falseならPro案内(freeAdArea)へ差し替える。
    ///
    /// 「今回の検索が枠切れで拒否されたか」(lastSearchQuotaExceeded)で判定するのが基本。
    /// quota.canScanToday(=次のスキャンができるか)を使うと、consumeLocally()の楽観的先行減算に
    /// より、無料枠を使い切る最後の1回(例: 5回目)は検索自体は成功しているのに
    /// unitsRemainingが0になっているためグラフだけ消える(実際に発生した不具合。
    /// 詳細はlastSearchQuotaExceededのコメント参照)。
    ///
    /// グラフ取得側の枠切れ(lastGraphQuotaExceeded)も同じ扱いにする。連携済みの無料ユーザーは
    /// 検索がSP-API経路で枠を消費せず成功するため、検索の結果だけで判定するとグラフだけが
    /// 枠切れになった状態を拾えない(詳細はlastGraphQuotaExceededのコメント参照)。
    private var showsGraph: Bool {
        if entitlements.isPro { return true }
        if viewModel.lastSearchQuotaExceeded || viewModel.lastGraphQuotaExceeded { return false }
        return canRequestGraph
    }

    /// グラフ取得(/api/graph-data)のリクエストを出してよいか。
    ///
    /// 枠切れ後もリクエストを出すと、サーバーのキャッシュに当たったときだけグラフが表示される。
    /// 枠を使い切っているのに商品によって出たり出なかったりするのは挙動として分かりにくいので、
    /// 消費が発生し得る状態では要求自体を送らない。
    ///
    /// 未連携(Keepa経路)を残量で止めない理由: この場合サーバーは検索時のKeepa応答から
    /// グラフ用データを先に作ってキャッシュへ入れている(routes.jsのgraphDataCache先入れ)ため、
    /// 直前の検索に対応するグラフは追加消費なしで返る。ここで残量を見て止めると、枠を使い切る
    /// 最後の1回でグラフだけ消える上記の不具合を作り直すことになる。なお枠を使い切った後の
    /// 次の検索は検索自体が拒否され、そもそもこの分岐へ来ない。
    /// 自前Keepaキーはここでは考慮しない。X-Keepa-Keyヘッダーが付くのはProのときだけで
    /// (APIClient.addKeepaKeyHeaderIfNeeded)、この判定はshowsGraphがisProを先に返すため
    /// 非Proの経路でしか呼ばれない。つまりキーが設定されていても共有Keepaキー=無料枠を消費する。
    private var canRequestGraph: Bool {
        // 端末に取得済みのデータがあるASINは通信せずに描画できる
        // (PriceHistoryChartView.load()がキャッシュヒットで即return)。既に自分の枠で
        // 取得済みのものなので、枠の残量に関わらず見せてよい。ProductDetailViewも
        // 同じキャッシュの有無で表示可否を決めている。
        if let asin = viewModel.latestResult?.asin,
           PriceHistoryChartView.cachedData(for: asin) != nil {
            return true
        }
        // Amazon連携済みは検索が枠を消費しない分、グラフ取得だけが枠を消費する。
        // 残量が無ければ結果はサーバーのキャッシュ次第になるため、要求を出さずPro案内へ倒す。
        if settings.isSpApiLinkUsable { return quota.canScanToday }
        return true
    }
    /// リワード広告(動画を見てスキャンを続ける)の導線を出してよいか。
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
                // OCRモードの無料お試し枠(1日5回)。超過でOCR専用ポップアップ。Amazon連携のお試し中は無制限。
                if viewModel.scanMode.isOCRMode && !entitlements.isPro
                    && !ScanQuotaStore.shared.registerOcrUseIfAllowed() {
                    showOcrLimitAlert = true
                    return
                }
                startSearch(scanned.code, source: viewModel.scanMode.isOCRMode ? .ocr : .barcode)
            },
            isOCRMode: viewModel.scanMode.isOCRMode,
            isActive: isScannerActive,
            // クールダウンの判定根拠は searchCooldown / consumesSharedKeepaToken のドキュメントを参照。
            emitCooldown: searchCooldown,
            cooldownNotice: cooldownNotice,
            cooldownHint: searchCooldownHint
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
                    onUpgradeTap: {
                        ReviewPromptController.shared.recordNegativeEvent()
                        Analytics.shared.capture(.paywallShown(trigger: .scanQuotaOverlay))
                        showPaywall = true
                    },
                    onWatchAdTap: { startRewardedAdFlow() },
                    onSpApiLinkTap: { AppNavigation.shared.opensAmazonLink = true }
                )
            }
        }
        // カメラ許可の案内。次の2条件をすべて満たすときだけ出す。
        // ①isQuotaExhausted == false: 枠切れが優先。枠切れ中はカメラ許可を得てもスキャンできず、
        //   「設定で許可して戻ってきたのにスキャンできない」という混乱を招くため、その場で解決できる
        //   行動を示す枠切れ側の案内(動画視聴・Pro案内)を優先する。
        // ②status が .denied または .restricted: .notDetermined のときはiOSが
        //   AVCaptureDeviceInput生成時(ScannerView.configureSessionIfNeeded)に自動でシステム
        //   ダイアログを出すため、自前の案内を重ねると二重表示になる。
        // .restrictedは設定アプリで解除できない場合があるが、何が起きているか分からないよりは
        // よいため案内自体は出す。
        .overlay {
            if !isQuotaExhausted
                && (cameraPermission.status == .denied || cameraPermission.status == .restricted) {
                CameraPermissionOverlay(
                    onOpenSettings: { CameraPermissionStore.shared.openSettings() }
                )
            }
        }

        latestResultCard

        offersPanels
    }

    /// スキャン・手入力で共通のクールダウン秒数。
    /// 長め(7秒)にするのは「共有Keepaキーのトークンを1回の検索ごとに1個消費する」場合だけ。
    /// SP-API連携済み(Keepa経路を通らない)と、自前Keepaキー利用者(自分の枠を消費する)は
    /// 共有トークンを消費しないため、重複読み取り防止程度(1秒)でよい。
    private var searchCooldown: TimeInterval { consumesSharedKeepaToken ? 7.0 : 1.0 }

    /// 「あと◯秒」に添える一文。長い方(7秒)のときだけ出す。
    /// 7秒は共有Keepaキーのトークン(全利用者で1つのバケット)を1検索1個消費するための
    /// 間隔であって、プランによる出し惜しみではない。Amazon連携すると検索経路が
    /// 利用者自身のAmazon枠に変わり、共有キーを使わなくなるので1秒で済む。
    /// この理由と解消手段を出さないと、特にPro(課金済み・お試し中)の利用者には
    /// 「お金を払っているのに遅い」としか映らないため必ず添える。
    private var searchCooldownHint: String? {
        consumesSharedKeepaToken ? "Amazon連携で待ち時間が1秒になります" : nil
    }

    /// この端末の検索が共有Keepaキーのトークンを消費するか。
    /// 自前キーの条件はAPIClient.addKeepaKeyHeaderIfNeededと一致させること
    /// (Proかつキーが非空のときだけX-Keepa-Keyを送るため、無料プランではキーを
    /// 設定していても共有トークンを消費する)。BYOキーはお試し対象外のためここもisProのまま。
    private var consumesSharedKeepaToken: Bool {
        if settings.isSpApiLinkUsable { return false }
        if entitlements.isPro && settings.isKeepaKeyUsable { return false }
        return true
    }

    /// スキャン(カメラ/OCR)・手入力検索の共通ゲート。無料枠ユニットの残量を確認し、
    /// 残っていればローカルミラーを楽観的に1消費してから検索を実行する。
    /// 枠切れのときはペイウォールを提示する。枠切れ中はカメラが止まる(isScannerActive)ため
    /// ここに枠切れで到達するのは手入力検索の経路だが、黙って無反応にすると
    /// 「検索できない理由」が分からないため必ず理由を示す。
    ///
    /// クールダウンの起点(最後に検索した時刻)はカメラ側と共有する(SearchCooldownStore)。
    /// 経路ごとに別々のタイマーを持つと「スキャン直後に手入力」ですり抜けられるため。
    /// 弾いたときはカメラ上の「あと◯秒」オーバーレイで伝える(スキャン時と同じ見せ方)。
    private func startSearch(_ code: String, source: AnalyticsEvent.SearchSource) {
        guard isSearchUnlimited || quota.canScanToday else {
            ReviewPromptController.shared.recordNegativeEvent()
            Analytics.shared.capture(.quotaExhausted)
            Analytics.shared.capture(.paywallShown(trigger: .searchQuotaGuard))
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
        viewModel.handleScan(code, source: source)
    }

    /// リワード広告フロー(枠切れオーバーレイの「動画を見てスキャンを続ける」/グラフ枠の「動画を見てグラフを見る」の共通処理)。
    /// 広告を表示し、報酬獲得できたらサーバー側の枠加算(+5)が届くまで待つ。
    ///
    /// 加算はGoogle→サーバーのSSVコールバックで非同期に行われるため、視聴直後は未反映のことがある。
    /// そのため「+5されました」とは即断せず、`waitForAdGrant()` が実際の増加を確認するまで「反映中…」を出す。
    /// 反映されると unitsRemaining > 0 になり、isQuotaExhausted が false になってオーバーレイは自動的に消える。
    private func startRewardedAdFlow() {
        guard !isProcessingRewardedAd else { return }
        // 広告を見ないと先に進めない=枠が尽きている状態なので、ネガティブイベントとして記録する。
        ReviewPromptController.shared.recordNegativeEvent()
        Analytics.shared.capture(.rewardedAdWatched)
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
    /// グラフ専用の案内(枠切れ文言・「動画を見てグラフを見る」)は、Amazon未連携の無料ユーザーには
    /// 出さない。この場合はスキャン自体が止まりカメラ上に枠切れオーバーレイ
    /// (Pro/動画を見てスキャンを続ける/Amazon連携)が既に出ており、ここにほぼ同じ内容の導線を
    /// 重ねると同じ案内が2箇所に並んで煩雑になるため。
    /// 連携済み・お試し中はスキャン自体は無制限でグラフ枠だけが尽きる状態になり得るため、
    /// カメラ側のオーバーレイと重複しない。その場合は引き続きここで案内する。
    private var freeAdArea: some View {
        VStack(spacing: 8) {
            // 広告バナー(AdSlotView)はbody側で常時表示するようになったため、ここには置かない
            // (二重表示を避けるため)。ここに残すのは枠切れ時のPro案内のみ。

            if showsGraphQuotaGuidance {
                // 「動画を見てグラフを見る」(リワード広告でグラフ枠を延長する導線)は廃止した。
                // グラフ枠が尽きたらPro案内のみを出す。回数はサーバーが /api/quota で返す
                // 設定値(KVのquota-limits)から組み立てるため、KVを書き換えれば文言も追従する
                // (未取得時はScanQuotaStoreの既定値5でフォールバック)。
                Button {
                    ReviewPromptController.shared.recordNegativeEvent()
                    Analytics.shared.capture(.paywallShown(trigger: .graphQuotaExhausted))
                    showPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        LockIconView(size: 16)
                        Text("グラフの表示は1日\(quota.baseDailyUnitsToday)回まで。Proなら無制限")
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
            }
        }
    }

    /// グラフ枠切れの案内(枠切れ文言・「動画を見てグラフを見る」)を出してよいか。
    /// Amazon未連携の無料ユーザーはスキャン自体が止まりカメラ上の枠切れオーバーレイと
    /// 内容が重複するため出さない(freeAdAreaのコメント参照)。
    private var showsGraphQuotaGuidance: Bool {
        entitlements.isPro || settings.isSpApiLinkUsable
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
                    // 直前の検索経路の分類は保持していないため、実質手入力に近い明示的な再試行として扱う。
                    viewModel.handleScan(code, source: .manual)
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
                    AppNavigation.shared.opensAmazonLink = true
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
                prices: selectedResult.prices,
                // 検索直後の遷移なので「検索日」は今日。
                scannedAt: Date(),
                sellerCounts: selectedResult.profitInputs?.sellerCounts
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
            startSearch(trimmed, source: .manual)
            return
        }

        // ISBN-10はチェック文字が"X"になり得るため大文字化してから検証する。
        let upper = trimmed.uppercased()
        if upper.count == 10, ISBN10Validator.isValid(upper) {
            startSearch(ISBN10Validator.toIsbn13(upper), source: .manual)
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
                    ReviewPromptController.shared.recordNegativeEvent()
                    Analytics.shared.capture(.paywallShown(trigger: .purchaseListLock))
                    showPaywall = true
                },
                onOpenLink: { url in
                    browserTarget = BrowserTarget(url: url)
                }
            )
            #if DEBUG
            if settings.keepaThrottleDebugEnabled, let debug = viewModel.latestResult?.keepaDebug {
                keepaDebugView(debug)
            }
            #endif
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

    #if DEBUG
    /// Keepaスロットルのデバッグ表示(開発者向け。設定でONかつX-Keepa-Debug応答があるときだけ出す)。
    private func keepaDebugView(_ debug: KeepaDebugInfo) -> some View {
        let snapshotText = debug.snapshot.map {
            "残量≈\($0.tokensEstimate) 消費\($0.consumeRatePerMin)/分 補充\($0.refillPerMin)/分"
        } ?? "スナップショット無し"
        return Text("[Keepa Debug] bypass=\(debug.bypass ?? "-") 待ち\(debug.waitedMs)ms allowed=\(debug.allowed) reason=\(debug.reason ?? "-") \(snapshotText)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
    }
    #endif

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
            // オファーはSP-API連携で解放されるため、Amazon連携画面へ誘導する。
            AppNavigation.shared.opensAmazonLink = true
            return
        }
        guard let result = viewModel.latestResult, result.asin != nil else { return }
        guard result.source == "spapi" else { return }
        selectedResult = result
    }

    // MARK: - Keepaグラフ

    /// 価格推移グラフ。無料枠が残っていれば無料でも表示する(枠切れ時は body 側で
    /// freeAdArea に切り替わる。判定はlastSearchQuotaExceeded参照)。
    @ViewBuilder
    private var keepaGraph: some View {
        if let asin = viewModel.latestResult?.asin {
            VStack(spacing: 6) {
                // オファーパネルとの重なりを避けるための余白。
                Spacer().frame(height: 10)
                // サーバーから履歴データ(/api/graph-data)を取得し、端末側でSwift Chartsに描画する。
                // チャート本体・凡例(メイン/出品者数とも)はPriceHistoryChartView側で描画する。
                PriceHistoryChartView(asin: asin, range: selectedGraphRange) {
                    viewModel.lastGraphQuotaExceeded = true
                }
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

    @ObservedObject private var settings = SettingsStore.shared

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
                            // 検索カードは設定で選んだ4つのまま(スキャン中はよく使うものだけ出す)。
                            kinds: settings.linkButtons,
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
