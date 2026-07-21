import Foundation
import Combine

/// 利益アラートの粗利・出品者数条件が参照する対象コンディション。
/// 条件ごとに別々のコンディションは持たず、この1つの共通設定を粗利・出品者数の両方が参照する(YAGNI)。
enum ProfitAlertCondition: String {
    case new
    case used
}

/// サーバーURLなどの設定値をUserDefaultsで永続化する。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let serverURL = "settings.serverURL"
        static let spapiLinkEnabled = "settings.spapiLinkEnabled"
        /// 旧: UserDefaultsに平文保存していたキー。現在はKeychainへ移行済み(初回起動時に自動移行して削除)。
        static let legacySpapiRefreshToken = "settings.spapiRefreshToken"
        static let renderSpApiEnabled = "settings.renderSpApiEnabled"

        // 利益アラート(Phase 1a)。既定は全条件OFFで既存ユーザーの挙動を変えない。
        static let profitAlertEnabled = "settings.profitAlert.enabled"
        static let profitAlertMarginEnabled = "settings.profitAlert.marginEnabled"
        static let profitAlertMarginThreshold = "settings.profitAlert.marginThreshold"
        static let profitAlertPurchaseCost = "settings.profitAlert.purchaseCost"
        static let profitAlertTargetCondition = "settings.profitAlert.targetCondition"
        static let profitAlertRankEnabled = "settings.profitAlert.rankEnabled"
        static let profitAlertRankThreshold = "settings.profitAlert.rankThreshold"
        static let profitAlertSellerCountEnabled = "settings.profitAlert.sellerCountEnabled"
        static let profitAlertSellerCountThreshold = "settings.profitAlert.sellerCountThreshold"
        static let profitAlertListPriceEnabled = "settings.profitAlert.listPriceEnabled"
        static let profitAlertHapticsEnabled = "settings.profitAlert.hapticsEnabled"
    }

    /// Keychain上のアカウント名(リフレッシュトークン用)。
    private static let keychainRefreshTokenAccount = "spapi.refreshToken"

    private let defaults: UserDefaults

    @Published var serverURLString: String {
        didSet {
            defaults.set(serverURLString, forKey: Keys.serverURL)
        }
    }

    /// SP-API連携(利用者自身のAmazon大口出品アカウントでの検索)を有効にするか
    @Published var spapiLinkEnabled: Bool {
        didSet {
            defaults.set(spapiLinkEnabled, forKey: Keys.spapiLinkEnabled)
        }
    }

    /// SP-API (LWA) リフレッシュトークン。
    /// 販売パートナーのセラーアカウントへのアクセス権を持つ機微情報のため、
    /// UserDefaults(平文)ではなくKeychainに保存する(AmazonのDPP要件)。
    @Published var spapiRefreshToken: String {
        didSet {
            KeychainStore.set(spapiRefreshToken, for: Self.keychainRefreshTokenAccount)
        }
    }

    /// サーバー(Render)側のSP-APIを使用するか。
    /// オフにするとリクエストにX-Disable-Spapiヘッダーを付与し、サーバーはSP-APIを一切使わずKeepaへフォールバックする。
    /// Keepaの動作確認をRender登録済みのSP-APIキーに邪魔されずに行うためのトグル。既定はオン。
    @Published var renderSpApiEnabled: Bool {
        didSet {
            defaults.set(renderSpApiEnabled, forKey: Keys.renderSpApiEnabled)
        }
    }

    // 利益アラート(Phase 1a)。既定は全てOFF。

    /// 利益アラート機能全体のマスタースイッチ。既定はOFF(未使用者に影響を与えない)。
    @Published var profitAlertEnabled: Bool {
        didSet {
            defaults.set(profitAlertEnabled, forKey: Keys.profitAlertEnabled)
        }
    }

    /// 粗利条件(breakEven − 仕入れ値 ≥ 閾値)を有効にするか
    @Published var profitAlertMarginEnabled: Bool {
        didSet {
            defaults.set(profitAlertMarginEnabled, forKey: Keys.profitAlertMarginEnabled)
        }
    }

    /// 粗利条件の閾値(円)
    @Published var profitAlertMarginThreshold: Int {
        didSet {
            defaults.set(profitAlertMarginThreshold, forKey: Keys.profitAlertMarginThreshold)
        }
    }

    /// 粗利計算に使う仕入れ値(円)
    @Published var profitAlertPurchaseCost: Int {
        didSet {
            defaults.set(profitAlertPurchaseCost, forKey: Keys.profitAlertPurchaseCost)
        }
    }

    /// 粗利・出品者数条件が参照する対象コンディション(新品/中古の共通設定)
    @Published var profitAlertTargetCondition: ProfitAlertCondition {
        didSet {
            defaults.set(profitAlertTargetCondition.rawValue, forKey: Keys.profitAlertTargetCondition)
        }
    }

    /// ランキング条件(salesRank ≤ 閾値)を有効にするか
    @Published var profitAlertRankEnabled: Bool {
        didSet {
            defaults.set(profitAlertRankEnabled, forKey: Keys.profitAlertRankEnabled)
        }
    }

    /// ランキング条件の閾値
    @Published var profitAlertRankThreshold: Int {
        didSet {
            defaults.set(profitAlertRankThreshold, forKey: Keys.profitAlertRankThreshold)
        }
    }

    /// 出品者数条件(sellerCounts[対象コンディション] ≤ 閾値)を有効にするか
    @Published var profitAlertSellerCountEnabled: Bool {
        didSet {
            defaults.set(profitAlertSellerCountEnabled, forKey: Keys.profitAlertSellerCountEnabled)
        }
    }

    /// 出品者数条件の閾値(人)
    @Published var profitAlertSellerCountThreshold: Int {
        didSet {
            defaults.set(profitAlertSellerCountThreshold, forKey: Keys.profitAlertSellerCountThreshold)
        }
    }

    /// 売値≥定価条件を有効にするか
    @Published var profitAlertListPriceEnabled: Bool {
        didSet {
            defaults.set(profitAlertListPriceEnabled, forKey: Keys.profitAlertListPriceEnabled)
        }
    }

    /// 利益アラート発火時にバイブレーションを鳴らすか。既定はtrue(現状の挙動=常に振動、を変えない)。
    @Published var profitAlertHapticsEnabled: Bool {
        didSet {
            defaults.set(profitAlertHapticsEnabled, forKey: Keys.profitAlertHapticsEnabled)
        }
    }

    /// 本番APIの既定URL(独自ドメイン)。
    /// Cloudflare Workers を指すが、DNSで切替可能なため将来サーバーを移してもアプリ更新は不要。
    static let defaultServerURL = "https://api.sellira.jp"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        self.spapiLinkEnabled = defaults.bool(forKey: Keys.spapiLinkEnabled)
        // 未設定時は既定でオン(サーバー側SP-APIを使う従来動作)にする。
        self.renderSpApiEnabled = (defaults.object(forKey: Keys.renderSpApiEnabled) as? Bool) ?? true

        // 利益アラート(Phase 1a)。未設定時は全条件OFF・既定値で読み込む(既存ユーザーの挙動は不変)。
        self.profitAlertEnabled = defaults.bool(forKey: Keys.profitAlertEnabled)
        self.profitAlertMarginEnabled = defaults.bool(forKey: Keys.profitAlertMarginEnabled)
        self.profitAlertMarginThreshold = (defaults.object(forKey: Keys.profitAlertMarginThreshold) as? Int) ?? 300
        self.profitAlertPurchaseCost = (defaults.object(forKey: Keys.profitAlertPurchaseCost) as? Int) ?? 0
        self.profitAlertTargetCondition = ProfitAlertCondition(
            rawValue: defaults.string(forKey: Keys.profitAlertTargetCondition) ?? ""
        ) ?? .used
        self.profitAlertRankEnabled = defaults.bool(forKey: Keys.profitAlertRankEnabled)
        self.profitAlertRankThreshold = (defaults.object(forKey: Keys.profitAlertRankThreshold) as? Int) ?? 100_000
        self.profitAlertSellerCountEnabled = defaults.bool(forKey: Keys.profitAlertSellerCountEnabled)
        self.profitAlertSellerCountThreshold = (defaults.object(forKey: Keys.profitAlertSellerCountThreshold) as? Int) ?? 10
        self.profitAlertListPriceEnabled = defaults.bool(forKey: Keys.profitAlertListPriceEnabled)
        self.profitAlertHapticsEnabled = (defaults.object(forKey: Keys.profitAlertHapticsEnabled) as? Bool) ?? true

        // リフレッシュトークンはKeychainから読む。
        // 旧バージョンでUserDefaultsに平文保存されていた場合は、ここでKeychainへ移行し平文を削除する。
        if let keychainToken = KeychainStore.get(Self.keychainRefreshTokenAccount) {
            self.spapiRefreshToken = keychainToken
        } else if let legacyToken = defaults.string(forKey: Keys.legacySpapiRefreshToken),
                  !legacyToken.isEmpty {
            self.spapiRefreshToken = legacyToken
            KeychainStore.set(legacyToken, for: Self.keychainRefreshTokenAccount)
            defaults.removeObject(forKey: Keys.legacySpapiRefreshToken)
        } else {
            self.spapiRefreshToken = ""
            // 空文字のまま残っている旧キーも掃除しておく。
            defaults.removeObject(forKey: Keys.legacySpapiRefreshToken)
        }
    }

    /// SP-API連携が利用可能か(有効かつリフレッシュトークンが非空)
    var isSpApiLinkUsable: Bool {
        spapiLinkEnabled
            && !spapiRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
