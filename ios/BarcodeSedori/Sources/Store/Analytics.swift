import Foundation
import PostHog

// ============================================================================
// 【重要】Amazon Data Protection Policy(DPP)遵守のための制約
// ============================================================================
// このアプリはAmazon SP-APIを利用しており、Amazon由来のデータをPostHogのような
// 第三者へ送信するとDPP違反になる(SP-APIの出品審査が進行中でもある)。
// 以下は絶対にPostHogへ送ってはならない:
//   - selling_partner_id / 出品者ID、SP-APIリフレッシュトークン、Keepa APIキー
//   - スキャンしたJAN/ISBN/ASINコード、商品タイトル
//   - 価格・粗利益・ランキング・SKU・数量・出品内容
//   - 仕入れリスト/スキャン履歴に由来する情報
//
// 送ってよいのは「何が起きたか」という行動の事実(どのイベントが、どの画面で、
// 何回、どのアプリ/OSバージョンで)だけ。
//
// この制約は「気をつける」ではなく構造で守る: 呼び出し側に渡せるのは
// Event という閉じたenumのケースだけで、その連想値も安全なスカラー/enumに限る
// (例: 検索経路を表す source enum、件数を表す Int)。任意の文字列・辞書を
// 受け取る `capture(String, [String: Any])` のような汎用APIは外部に一切公開しない。
// 将来の変更でうっかりASINやタイトルを差し込めないようにするための設計。
//
// `import PostHog` はこのファイルにのみ書く(ベンダーの差し替え・撤去を1ファイルで完結させるため)。
// ============================================================================

/// PostHogプロジェクトの接続設定。
private enum AnalyticsConfig {
    /// PostHogプロジェクトのAPIキー。**未設定(空)の間は初期化も送信も一切行わない**。
    static let apiKey = ""
    /// プロジェクトを作成したリージョンに合わせること(USなら https://us.i.posthog.com)。
    static let host = "https://eu.i.posthog.com"
}

/// アプリ全体で計測してよい行動イベント。連想値はすべて安全なスカラー/enumのみ
/// (ファイル冒頭のDPP制約コメント参照)。
enum AnalyticsEvent {
    /// スキャン/検索の入力経路。
    enum SearchSource: String {
        case barcode
        case ocr
        case manual
    }

    /// 検索失敗の分類。生のエラー文字列(識別子を含み得る)は絶対に使わない。
    enum SearchFailureReason: String {
        case quotaExceeded = "quota_exceeded"
        case keepaBusy = "keepa_busy"
        case network
        case other
    }

    /// ペイウォール表示のトリガー(どの導線から出たか)。
    enum PaywallTrigger: String {
        case settingsUpgradeButton = "settings_upgrade_button"
        case profitAlertLock = "profit_alert_lock"
        case keepaLinkLock = "keepa_link_lock"
        case listingLock = "listing_lock"
        case ocrLimitAlert = "ocr_limit_alert"
        case scanQuotaOverlay = "scan_quota_overlay"
        case searchQuotaGuard = "search_quota_guard"
        case graphQuotaExhausted = "graph_quota_exhausted"
        case purchaseListLock = "purchase_list_lock"
        case bulkAddToPurchaseListLock = "bulk_add_to_purchase_list_lock"
    }

    case appLaunched
    case searchSucceeded(source: SearchSource)
    case searchFailed(reason: SearchFailureReason)
    case purchaseListAdded
    case bulkListingSucceeded(count: Int)
    case paywallShown(trigger: PaywallTrigger)
    case proPurchased
    case amazonLinkCompleted
    case rewardedAdWatched
    case quotaExhausted

    /// PostHogへ送るイベント名(snake_case)。
    fileprivate var name: String {
        switch self {
        case .appLaunched: return "app_launched"
        case .searchSucceeded: return "search_succeeded"
        case .searchFailed: return "search_failed"
        case .purchaseListAdded: return "purchase_list_added"
        case .bulkListingSucceeded: return "bulk_listing_succeeded"
        case .paywallShown: return "paywall_shown"
        case .proPurchased: return "pro_purchased"
        case .amazonLinkCompleted: return "amazon_link_completed"
        case .rewardedAdWatched: return "rewarded_ad_watched"
        case .quotaExhausted: return "quota_exhausted"
        }
    }

    /// PostHogへ送るプロパティ。安全なスカラー値のみを詰める。
    fileprivate var properties: [String: Any]? {
        switch self {
        case .searchSucceeded(let source):
            return ["source": source.rawValue]
        case .searchFailed(let reason):
            return ["reason": reason.rawValue]
        case .bulkListingSucceeded(let count):
            return ["count": count]
        case .paywallShown(let trigger):
            return ["trigger": trigger.rawValue]
        case .appLaunched, .purchaseListAdded, .proPurchased, .amazonLinkCompleted,
             .rewardedAdWatched, .quotaExhausted:
            return nil
        }
    }
}

/// PostHogラッパー。`import PostHog` はこのファイルにのみ書く。
/// APIキー未設定(開発中の既定状態)では初期化も送信も一切行わない(フェイルクローズ)。
final class Analytics {
    static let shared = Analytics()

    private var isEnabled = false

    private init() {}

    /// 起動時に一度だけ呼ぶ。APIキーが空の間は何もしない。
    func start() {
        guard !AnalyticsConfig.apiKey.isEmpty else { return }

        let config = PostHogConfig(apiKey: AnalyticsConfig.apiKey, host: AnalyticsConfig.host)
        // セッションリプレイは画面を録画するため、上のDPPコメントにある通り
        // Amazon由来のデータ(ASIN・価格・出品情報等)がそのまま映り込んでしまう。
        // 行動ログのみを送る方針のため必ず無効化する。
        config.sessionReplay = false
        // SwiftUIではUIHostingControllerとしてしか画面遷移を検知できず、タブ名等の
        // 意味のある画面名は取れないため自動収集は無意味。有効化しない。
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = true

        PostHogSDK.shared.setup(config)
        isEnabled = true
    }

    /// 行動イベントを送信する。closed enumのみ受け取り、任意の文字列/辞書は受け付けない
    /// (ファイル冒頭のDPP制約コメント参照)。APIキー未設定時は何もしない。
    ///
    /// distinct_idは意図的に設定しない。PostHogの自動生成する匿名IDに任せることで、
    /// 端末のdeviceId(Amazon連携の記録と紐づく識別子)と分析データを突き合わせられない
    /// ようにするため。
    func capture(_ event: AnalyticsEvent) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }
}
