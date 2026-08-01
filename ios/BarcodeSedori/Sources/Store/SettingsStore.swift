import Foundation
import Combine

/// 利益アラートの粗利・出品者数条件が参照する対象コンディション。
/// 条件ごとに別々のコンディションは持たず、この1つの共通設定を粗利・出品者数の両方が参照する(YAGNI)。
enum ProfitAlertCondition: String {
    case new
    case used
    /// 新品・中古のうち有利な方(高い方)で判定する(旧データ互換のため既存rawValueは変更しない)。
    case both
}

/// サーバーURLなどの設定値をUserDefaultsで永続化する。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let serverURL = "settings.serverURL"
        static let spapiLinkEnabled = "settings.spapiLinkEnabled"
        /// 旧: UserDefaultsに平文保存していたキー。現在はKeychainへ移行済み(初回起動時に自動移行して削除)。
        static let legacySpapiRefreshToken = "settings.spapiRefreshToken"
        /// OAuth認可コールバックのselling_partner_id(公開の出品者ID)。
        /// リフレッシュトークンと異なり機密度が低いためKeychainではなくUserDefaultsに保存する。
        static let spapiSellerId = "settings.spapiSellerId"

        // 利益アラート(Phase 1a)。既定は全条件OFFで既存ユーザーの挙動を変えない。
        static let profitAlertEnabled = "settings.profitAlert.enabled"
        static let profitAlertMarginEnabled = "settings.profitAlert.marginEnabled"
        static let profitAlertMarginThreshold = "settings.profitAlert.marginThreshold"
        static let profitAlertPurchaseCost = "settings.profitAlert.purchaseCost"
        static let profitAlertTargetCondition = "settings.profitAlert.targetCondition"
        static let profitAlertRankEnabled = "settings.profitAlert.rankEnabled"
        static let profitAlertRankThreshold = "settings.profitAlert.rankThreshold"
        static let profitAlertSellerCountEnabled = "settings.profitAlert.sellerCountEnabled"
        /// 新品用の出品者数閾値。旧キーをそのまま流用する(既存ユーザーの設定を引き継ぐため)。
        static let profitAlertSellerCountNewThreshold = "settings.profitAlert.sellerCountThreshold"
        static let profitAlertSellerCountUsedThreshold = "settings.profitAlert.sellerCountUsedThreshold"
        static let profitAlertListPriceEnabled = "settings.profitAlert.listPriceEnabled"
        static let profitAlertHapticsEnabled = "settings.profitAlert.hapticsEnabled"

        // 出品(Phase 2): コンディション別説明文テンプレート。
        static let listingTemplateNew = "settings.listing.template.new"
        static let listingTemplateLikeNew = "settings.listing.template.likeNew"
        static let listingTemplateVeryGood = "settings.listing.template.veryGood"
        static let listingTemplateGood = "settings.listing.template.good"
        static let listingTemplateAcceptable = "settings.listing.template.acceptable"

        // 出品SKUフォーマット(部品列。JSONエンコードして保存)。
        static let listingSkuFormat = "settings.listing.skuFormat"

        /// SKU重複時の出品を防ぐか(一括出品時にSKU重複を検知して弾く)。既定true。
        static let preventDuplicateSku = "settings.preventDuplicateSku"

        // 仕入れフォーム(PurchaseFormView): 直近保存したコンディション(新規追加時の初期値に使う)。
        static let listingLastCondition = "settings.listing.lastCondition"

        // リンクボタン(検索タブの結果カード。2026-08 拡張)。
        /// 表示する4つのリンクボタン種別(順序も保持)。JSONエンコードして保存する。
        static let linkButtons = "settings.linkButtons"
        /// リンク検索を型番優先にするか。既定false(タイトル優先)。
        static let linkSearchByModelNumber = "settings.linkSearchByModelNumber"

        // 仕入れ設定(PurchaseSettingsView): フォームのFBA・配送料デフォルトと仕入先リスト。
        static let purchaseUseFbaDefault = "purchase.useFbaDefault"
        /// 発送費用(自分が払う発送コスト)のデフォルト。キー名は導入時の「配送料」のまま流用する
        /// (意味は元々こちら)。
        static let purchaseShippingCostDefault = "purchase.shippingDefault"
        /// 配送料(購入者が支払い自分に入金される額)のデフォルト。
        static let purchaseShippingIncomeDefault = "purchase.shippingIncomeDefault"
        static let purchaseSuppliers = "purchase.suppliers"
        static let purchaseLastSupplier = "purchase.lastSupplier"
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

    /// SP-API出品者ID(selling_partner_id)。OAuth認可コールバックでAmazonから受け取る公開ID。
    /// Sellers APIからは取得不可能(応答にsellerId相当のフィールドが無い)なため、認可時に一度だけ
    /// 受け取ってここに保持し、出品系APIリクエストのヘッダー(X-Spapi-Seller-Id)で送る。
    @Published var spapiSellerId: String {
        didSet {
            defaults.set(spapiSellerId, forKey: Keys.spapiSellerId)
        }
    }


    // リンクボタン(検索タブの結果カード。2026-08 拡張)。

    /// 結果カードに表示する4つのリンクボタン(順序も保持)。既定は仕入れ/Amazon/メルカリ/楽天市場。
    @Published var linkButtons: [LinkButtonKind] {
        didSet {
            guard let data = try? JSONEncoder().encode(linkButtons) else { return }
            defaults.set(data, forKey: Keys.linkButtons)
        }
    }

    /// リンク検索のキーワードを型番優先にするか。既定false(タイトル優先)。
    /// trueでも型番が無い商品(書籍など)は自動的にタイトルへフォールバックする。
    @Published var linkSearchByModelNumber: Bool {
        didSet {
            defaults.set(linkSearchByModelNumber, forKey: Keys.linkSearchByModelNumber)
        }
    }

    /// リンクボタンの既定表示4つ(仕入れ/Amazon/メルカリ/楽天市場)。
    static let defaultLinkButtons: [LinkButtonKind] = [.purchase, .amazon, .mercari, .rakuten]

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

    /// 出品者数条件の閾値・新品(人)
    @Published var profitAlertSellerCountNewThreshold: Int {
        didSet {
            defaults.set(profitAlertSellerCountNewThreshold, forKey: Keys.profitAlertSellerCountNewThreshold)
        }
    }

    /// 出品者数条件の閾値・中古(人)
    @Published var profitAlertSellerCountUsedThreshold: Int {
        didSet {
            defaults.set(profitAlertSellerCountUsedThreshold, forKey: Keys.profitAlertSellerCountUsedThreshold)
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

    // 出品(Phase 2): コンディション別説明文テンプレート。

    /// 出品説明文テンプレート(新品)
    @Published var listingTemplateNew: String {
        didSet {
            defaults.set(listingTemplateNew, forKey: Keys.listingTemplateNew)
        }
    }

    /// 出品説明文テンプレート(ほぼ新品)
    @Published var listingTemplateLikeNew: String {
        didSet {
            defaults.set(listingTemplateLikeNew, forKey: Keys.listingTemplateLikeNew)
        }
    }

    /// 出品説明文テンプレート(非常に良い)
    @Published var listingTemplateVeryGood: String {
        didSet {
            defaults.set(listingTemplateVeryGood, forKey: Keys.listingTemplateVeryGood)
        }
    }

    /// 出品説明文テンプレート(良い)
    @Published var listingTemplateGood: String {
        didSet {
            defaults.set(listingTemplateGood, forKey: Keys.listingTemplateGood)
        }
    }

    /// 出品説明文テンプレート(可)
    @Published var listingTemplateAcceptable: String {
        didSet {
            defaults.set(listingTemplateAcceptable, forKey: Keys.listingTemplateAcceptable)
        }
    }

    /// 出品SKUフォーマット(部品列)。並べ替え画面(SkuFormatSettingsView)で編集する。
    /// JSONエンコードしてUserDefaultsに保存し、読めない/未設定時は既定フォーマットに戻す。
    @Published var listingSkuFormat: [SkuComponent] {
        didSet {
            guard let data = try? JSONEncoder().encode(listingSkuFormat) else { return }
            defaults.set(data, forKey: Keys.listingSkuFormat)
        }
    }

    /// 既定のSKUフォーマット。従来の `AMLZ-YYYYMMDD-連番` と同じ見た目になる並び
    /// (枝番は自動付与ではなく部品として含めている)。
    static let defaultListingSkuFormat: [SkuComponent] = [.text("AMLZ-"), .year4, .month, .day, .sequence]

    /// SKU重複時の出品を防ぐか。既定true(オフにすると重複時に既存出品が上書きされる)。
    @Published var preventDuplicateSku: Bool {
        didSet {
            defaults.set(preventDuplicateSku, forKey: Keys.preventDuplicateSku)
        }
    }

    /// 仕入れフォームで直近保存したコンディション(新規追加時の初期値に使う)。
    /// 一度も保存していなければnil(この場合フォーム側が`.usedVeryGood`を既定値として使う)。
    @Published var lastListingCondition: ListingConditionType? {
        didSet {
            if let lastListingCondition {
                defaults.set(lastListingCondition.rawValue, forKey: Keys.listingLastCondition)
            } else {
                defaults.removeObject(forKey: Keys.listingLastCondition)
            }
        }
    }

    // 仕入れ設定(PurchaseSettingsView)。

    /// 仕入れフォームのFBA利用トグルの既定値。商品ごとに変更できる(PurchaseListItem.useFba)。既定OFF。
    @Published var purchaseUseFbaDefault: Bool {
        didSet {
            defaults.set(purchaseUseFbaDefault, forKey: Keys.purchaseUseFbaDefault)
        }
    }

    /// 仕入れフォームの発送費用(円。自分が払う発送コスト)の初期値。既定0円。
    @Published var purchaseShippingCostDefault: Int {
        didSet {
            defaults.set(purchaseShippingCostDefault, forKey: Keys.purchaseShippingCostDefault)
        }
    }

    /// 仕入れフォームの配送料(円。購入者が支払い自分に入金される額)の初期値。既定0円。
    @Published var purchaseShippingIncomeDefault: Int {
        didSet {
            defaults.set(purchaseShippingIncomeDefault, forKey: Keys.purchaseShippingIncomeDefault)
        }
    }

    /// 登録済み仕入先リスト(追加順)。仕入れフォームの仕入先Pickerの選択肢に使う。
    @Published var purchaseSuppliers: [String] {
        didSet {
            defaults.set(purchaseSuppliers, forKey: Keys.purchaseSuppliers)
        }
    }

    /// 仕入れフォームで最後に選んだ仕入先(新規追加時の初期値に使う。lastListingConditionと同方式)。
    /// 一度も選んでいなければnil(この場合フォーム側は「未選択」を既定値として使う)。
    @Published var purchaseLastSupplier: String? {
        didSet {
            if let purchaseLastSupplier {
                defaults.set(purchaseLastSupplier, forKey: Keys.purchaseLastSupplier)
            } else {
                defaults.removeObject(forKey: Keys.purchaseLastSupplier)
            }
        }
    }

    // 出品説明文テンプレートの既定値(設定画面・出品フォームで編集可)。
    static let defaultListingTemplateNew =
        "新品・未使用品です。丁寧に梱包してお届けします。"
    static let defaultListingTemplateLikeNew =
        "使用感がほとんど無い美品です。目立った傷・汚れはありません。丁寧に梱包してお届けします。"
    static let defaultListingTemplateVeryGood =
        "使用感は少なく良好な状態です。目立つ傷・汚れはありません。丁寧に梱包してお届けします。"
    static let defaultListingTemplateGood =
        "通常の使用感がありますが、問題なくお使いいただけます。検品のうえ丁寧に梱包してお届けします。"
    static let defaultListingTemplateAcceptable =
        "使用感・傷みがありますが、使用には支障ありません。状態をご了承のうえご購入ください。"

    /// 本番APIの既定URL(独自ドメイン)。
    /// Cloudflare Workers を指すが、DNSで切替可能なため将来サーバーを移してもアプリ更新は不要。
    static let defaultServerURL = "https://api.sellira.jp"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        self.spapiLinkEnabled = defaults.bool(forKey: Keys.spapiLinkEnabled)
        self.spapiSellerId = defaults.string(forKey: Keys.spapiSellerId) ?? ""

        // リンクボタン。未設定/デコード失敗時は既定4つ(仕入れ/Amazon/メルカリ/楽天市場)で読み込む。
        if let data = defaults.data(forKey: Keys.linkButtons),
           let decoded = try? JSONDecoder().decode([LinkButtonKind].self, from: data) {
            self.linkButtons = decoded
        } else {
            self.linkButtons = Self.defaultLinkButtons
        }
        self.linkSearchByModelNumber = defaults.bool(forKey: Keys.linkSearchByModelNumber)

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
        self.profitAlertSellerCountNewThreshold = (defaults.object(forKey: Keys.profitAlertSellerCountNewThreshold) as? Int) ?? 10
        self.profitAlertSellerCountUsedThreshold = (defaults.object(forKey: Keys.profitAlertSellerCountUsedThreshold) as? Int) ?? 10
        self.profitAlertListPriceEnabled = defaults.bool(forKey: Keys.profitAlertListPriceEnabled)
        self.profitAlertHapticsEnabled = (defaults.object(forKey: Keys.profitAlertHapticsEnabled) as? Bool) ?? true

        // 出品説明文テンプレート(Phase 2)。未設定時は既定文で読み込む。
        self.listingTemplateNew =
            defaults.string(forKey: Keys.listingTemplateNew) ?? Self.defaultListingTemplateNew
        self.listingTemplateLikeNew =
            defaults.string(forKey: Keys.listingTemplateLikeNew) ?? Self.defaultListingTemplateLikeNew
        self.listingTemplateVeryGood =
            defaults.string(forKey: Keys.listingTemplateVeryGood) ?? Self.defaultListingTemplateVeryGood
        self.listingTemplateGood =
            defaults.string(forKey: Keys.listingTemplateGood) ?? Self.defaultListingTemplateGood
        self.listingTemplateAcceptable =
            defaults.string(forKey: Keys.listingTemplateAcceptable) ?? Self.defaultListingTemplateAcceptable

        // 出品SKUフォーマット。未設定/デコード失敗時は既定フォーマット(従来と同じ見た目)で読み込む。
        if let data = defaults.data(forKey: Keys.listingSkuFormat),
           let decoded = try? JSONDecoder().decode([SkuComponent].self, from: data) {
            self.listingSkuFormat = decoded
        } else {
            self.listingSkuFormat = Self.defaultListingSkuFormat
        }

        // SKU重複時の出品を防ぐか。未設定時は既定true(重複防止を有効にしておく)。
        self.preventDuplicateSku = (defaults.object(forKey: Keys.preventDuplicateSku) as? Bool) ?? true

        // 仕入れフォームの直近コンディション。未設定(一度も保存していない)ならnilのまま。
        self.lastListingCondition = defaults.string(forKey: Keys.listingLastCondition)
            .flatMap(ListingConditionType.init(rawValue:))

        // 仕入れ設定(PurchaseSettingsView)。未設定時は既定値(FBA OFF・配送料/発送費用0円・仕入先リスト空)で読み込む。
        self.purchaseUseFbaDefault = defaults.bool(forKey: Keys.purchaseUseFbaDefault)
        self.purchaseShippingCostDefault = (defaults.object(forKey: Keys.purchaseShippingCostDefault) as? Int) ?? 0
        self.purchaseShippingIncomeDefault = (defaults.object(forKey: Keys.purchaseShippingIncomeDefault) as? Int) ?? 0
        self.purchaseSuppliers = defaults.stringArray(forKey: Keys.purchaseSuppliers) ?? []
        self.purchaseLastSupplier = defaults.string(forKey: Keys.purchaseLastSupplier)

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

    /// 出品導線を表示してよいか(SP-API連携が利用可能、かつsellerIdも取得済み)。
    /// sellerIdはOAuth再認可時のコールバックでのみ取得できるため、旧認可のまま
    /// (連携済みだがsellerId未取得)のユーザーはfalseとなり出品導線を出さない。
    var isListingReady: Bool {
        isSpApiLinkUsable
            && !spapiSellerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 出品フォームがコンディション選択に応じて自動適用するテンプレート本文を返す。
    func listingTemplate(for condition: ListingConditionType) -> String {
        switch condition {
        case .newNew: return listingTemplateNew
        case .usedLikeNew: return listingTemplateLikeNew
        case .usedVeryGood: return listingTemplateVeryGood
        case .usedGood: return listingTemplateGood
        case .usedAcceptable: return listingTemplateAcceptable
        }
    }

    /// 仕入れリスト項目の出品SKUを組み立てる。年月日は「仕入れリストに追加した日付」、
    /// 枝番は追加時(または旧データは遅延採番時)に確定済みの値をそのまま使う。
    /// 枝番が未採番(skuSequenceがnil)の場合は呼び出し側(PurchaseFormViewModel等)が
    /// PurchaseListStore.assignSkuSequenceIfNeededで先に採番してから呼ぶこと。
    func listingSku(for item: PurchaseListItem) -> String {
        SkuGenerator.build(
            components: listingSkuFormat,
            addedDate: item.addedAt,
            asin: item.asin,
            jan: item.scannedCode,
            sequence: item.skuSequence ?? 1,
            quantity: item.quantity ?? 1
        )
    }
}
