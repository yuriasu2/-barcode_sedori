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

    /// /api/offers のOffer.condition正規化コードとの対応(初期価格の同コンディション検索に使う)。
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
    /// 出品価格の初期値: 同コンディション最安値(送料込みlanded)。
    /// 同コンディションのオファーが無い場合は同バケット(新品なら新品全体/中古なら中古全体)の
    /// 最安landedへフォールバックし、それも無ければnil。
    static func suggestedPrice(offers: OffersResult?, condition: ListingConditionType) -> Int? {
        // 新品コンディションは新品オファー、そうでなければ中古オファーを参照する。
        let bucket = (condition.isNew ? offers?.new : offers?.used) ?? []
        let sameCondition = bucket
            .filter { $0.condition == condition.offerConditionCode }
            .compactMap { $0.landed }
        if let lowest = sameCondition.min() {
            return lowest
        }
        return bucket.compactMap { $0.landed }.min()
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
