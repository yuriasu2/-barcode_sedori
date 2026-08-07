import Foundation

/// 出品フォームのコンディション(Listings Items APIのcondition_type値)。
/// 新品+中古4種の5種類(ユーザー指示により新品も選択可能)。
enum ListingConditionType: String, CaseIterable, Identifiable, Codable {
    case newNew = "new_new"
    case usedLikeNew = "used_like_new"
    case usedVeryGood = "used_very_good"
    case usedGood = "used_good"
    case usedAcceptable = "used_acceptable"

    var id: String { rawValue }

    /// 新品コンディションか(初期価格・出品者数の参照バケットの切替に使う)。
    var isNew: Bool { self == .newNew }

    /// 画面表示名(オファー一覧のconditionDisplayNameと同じ語彙)。
    var displayName: String {
        switch self {
        case .newNew: return "新品"
        case .usedLikeNew: return "ほぼ新品"
        case .usedVeryGood: return "非常に良い"
        case .usedGood: return "良い"
        case .usedAcceptable: return "可"
        }
    }

    /// OffersModels.Offer.condition正規化コードとの対応(初期価格の同コンディション検索に使う)。
    var offerConditionCode: String {
        switch self {
        case .newNew: return "new"
        case .usedLikeNew: return "like_new"
        case .usedVeryGood: return "very_good"
        case .usedGood: return "good"
        case .usedAcceptable: return "acceptable"
        }
    }
}

/// 出品まわりの純粋ロジック(swiftc単体コンパイルで検証可能なようViewから分離)。
enum ListingModels {
    /// 仕入れフォームの価格初期値: 新品/中古の2区分(バケット)だけで選ぶ最安値(送料込みlanded)。
    /// コンディションが新品なら新品バケット全体の最安landed、中古系4種なら中古バケット全体の
    /// 最安landedを返す(同コンディション細分での絞り込みはしない)。オファーが無ければnil。
    static func bucketLowestPrice(offers: OffersResult?, condition: ListingConditionType) -> Int? {
        let bucket = (condition.isNew ? offers?.new : offers?.used) ?? []
        return bucket.compactMap { $0.landed }.min()
    }

    /// 仕入れフォームの出品価格に自動入力する額。
    ///
    /// 自己発送では購入者が払う総額が「出品価格 + 配送料」になるため、競合の最安値
    /// (landed = 商品代 + 送料)と総額で並ぶには自分の配送料を引いた額を出す必要がある。
    /// この差し引きは設定「配送料を引いた最安値自動入力」がオンのときだけ行う(既定オフ)。
    /// - Parameters:
    ///   - shippingIncome: 差し引く配送料。**FBA利用時は0を渡すこと**(Amazonが配送するため
    ///     出品者に配送料収入が無く、引くと実際より安い価格で出品してしまう)。
    ///   - subtractShipping: 設定トグルのオン/オフ。
    /// - Returns: 最安値が取れなければnil(従来どおり空欄のまま)。
    static func autoFillListingPrice(
        offers: OffersResult?,
        condition: ListingConditionType,
        shippingIncome: Int,
        subtractShipping: Bool
    ) -> Int? {
        guard let lowest = bucketLowestPrice(offers: offers, condition: condition) else { return nil }
        guard subtractShipping, shippingIncome > 0 else { return lowest }
        // 0円・負値はAmazonへ出品できず保存時のバリデーションでも弾かれるため、1円を下限にする。
        return max(1, lowest - shippingIncome)
    }
}

/// GET /api/listings/restrictions レスポンス。
struct ListingRestrictionsResult: Codable, Equatable {
    let restricted: Bool
    let message: String?
    /// Seller Centralの解除申請ページURL(制限ありでリンクが取れた場合のみ)。
    let approvalUrl: String?
}

/// POST /api/listings リクエストボディ。
struct ListingSubmissionRequest: Codable {
    let asin: String
    let sku: String
    let conditionType: String
    let price: Int
    let quantity: Int
    let conditionNote: String
    /// 'DEFAULT'(自己発送)| 'AMAZON_JP'(FBA)。省略時サーバー側はDEFAULT扱いだが、
    /// 一括出品(BulkListingViewModel)は常に明示的に送る。
    let fulfillmentChannel: String
}

/// POST /api/listings レスポンス(SP-API putListingsItem応答の透過)。
struct ListingSubmissionResult: Codable, Equatable {
    let status: String?
    let submissionId: String?
    let issues: [ListingIssue]?

    struct ListingIssue: Codable, Equatable {
        let code: String?
        let message: String?
        let severity: String?
        let attributeNames: [String]?
    }

    /// 出品が受理されたか(非同期反映のため「受理」であって「完了」ではない)。
    var isAccepted: Bool {
        status?.uppercased() == "ACCEPTED"
    }

    /// INVALID時にそのまま表示するissues本文(日本語化はしない方針)。
    var issuesText: String {
        let messages = (issues ?? []).compactMap { $0.message }
        return messages.isEmpty ? "出品が受理されませんでした(status: \(status ?? "不明"))" : messages.joined(separator: "\n")
    }
}

/// GET /api/fees-estimate レスポンス。仕入れフォームの利益セクションが使う手数料内訳。
/// 金額はすべて整数円(サーバー側で四捨五入済み)。
struct FeesEstimateResult: Codable, Equatable {
    /// 手数料の内訳1行(販売手数料・カテゴリ成約料・消費税・FBA手数料など)。
    struct FeeLine: Codable, Equatable {
        /// 種別コード(referral/closing/tax/fba/other)。表示の出し分け・アイコン選択に使う。
        let type: String
        /// 画面表示名(サーバー側で日本語化済み)。
        let label: String
        let amount: Int
    }

    /// 手数料合計額(円)。
    let total: Int
    let breakdown: [FeeLine]
}
