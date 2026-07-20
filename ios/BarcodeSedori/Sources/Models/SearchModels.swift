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

/// 商品の梱包寸法(mm)。Keepaの packageLength/Width/Height から取得。
/// 一部の値のみ取得できるケースがあるため各値はオプショナル。
struct DimensionsMm: Codable, Equatable {
    let length: Int?
    let width: Int?
    let height: Int?
}

/// GET /api/search?code= レスポンス
struct SearchResult: Codable, Equatable {
    let codeType: CodeType
    let asin: String?
    let title: String?
    let isbn13: String?
    let imageUrl: String?
    let salesRank: Int?
    /// ブランド名(Keepa経路のみ取得可)。SP-API経路や旧サーバーではnil。
    let brand: String?
    /// 梱包寸法(mm)。Keepa経路のみ取得可。SP-API経路や旧サーバーではnil。
    let dimensionsMm: DimensionsMm?
    /// 梱包重量(g)。Keepa経路のみ取得可。SP-API経路や旧サーバーではnil。
    let weightG: Int?
    let prices: SearchPrices?
    /// オファー取得元("spapi"等)。CHANGES-v6.mdで追加。旧サーバー互換のためオプショナル。
    let source: String?
    /// SP-API経路は第1段階(/api/search)応答にオファー一覧を同梱する(2段階ロード廃止)。
    /// Keepa経路や旧サーバーではnil(その場合は従来どおり第2段階/api/offersで取得)。
    let offers: OffersResult?
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
