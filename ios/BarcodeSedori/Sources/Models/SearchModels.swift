import Foundation

/// バーコード種別。サーバーが自動判定して返す。CHANGES-v2.mdによりインストア系分類は廃止。
enum CodeType: String, Codable, Equatable {
    case isbn
    case jan
    case unresolved

    /// 商品バーコード(ISBN/JAN)として確定しているか
    var isProductCode: Bool {
        switch self {
        case .isbn, .jan:
            return true
        case .unresolved:
            return false
        }
    }
}

/// GET /api/search?code= のポイント情報
struct SearchPoints: Codable, Equatable {
    let cart: Int?
    let new: Int?
    let used: Int?
}

/// GET /api/search?code= の価格情報
struct SearchPrices: Codable, Equatable {
    let cart: Int?
    let new: Int?
    let used: Int?
    let points: SearchPoints?
}

/// GET /api/search?code= レスポンス
struct SearchResult: Codable, Equatable {
    let codeType: CodeType
    let asin: String?
    let title: String?
    let isbn13: String?
    let imageUrl: String?
    let salesRank: Int?
    let prices: SearchPrices?
    /// オファー取得元("spapi"等)。CHANGES-v6.mdで追加。旧サーバー互換のためオプショナル。
    let source: String?
}

/// サーバーエラーレスポンス(想定: {"error": "..."} 形式にも対応できるよう緩めに定義)
struct APIErrorResponse: Codable {
    let error: String?
    let message: String?
}

/// GET /api/spapi/test レスポンス
struct SpApiTestResult: Codable, Equatable {
    let ok: Bool
    let message: String?
}
