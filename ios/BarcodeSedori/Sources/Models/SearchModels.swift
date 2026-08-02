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

/// GET /api/search の利益アラート用素材。旧サーバーではキーごと無いためnil。
struct ProfitInputs: Codable, Equatable {
    let listPrice: Int?
    let sellerCounts: ConditionCounts?
    let breakEven: ConditionBreakEven?

    struct ConditionCounts: Codable, Equatable {
        let new: Int?
        let used: Int?
    }
    /// breakEvenはサーバーが小数で返すためDouble(OffersModels.Offer.breakEvenと同じ理由)。
    struct ConditionBreakEven: Codable, Equatable {
        let new: Double?
        let used: Double?
    }
}

/// GET /api/search?code= レスポンス
struct SearchResult: Codable, Equatable {
    let codeType: CodeType
    let asin: String?
    let title: String?
    let isbn13: String?
    let imageUrl: String?
    let salesRank: Int?
    /// 発売日(ISO日付文字列、例:"2019-05-30")。整形はアプリ側で行う。旧サーバー互換のためオプショナル。
    let releaseDate: String?
    /// 型番(SP-API経路のみ取得可能。Keepa経路は常にnil)。書籍には型番が無いためnilになる。
    /// リンクボタンの「型番で検索する」設定時のキーワードに使う(nilならタイトルへフォールバック)。
    let modelNumber: String?
    let prices: SearchPrices?
    /// オファー取得元("spapi"等)。CHANGES-v6.mdで追加。旧サーバー互換のためオプショナル。
    let source: String?
    /// SP-API経路は/api/search応答にオファー一覧を同梱する(別リクエストでの再取得はしない設計)。
    /// Keepa経路や旧サーバーではnil(オファーは取得されず、検索タブはロック表示にする)。
    let offers: OffersResult?
    /// 利益アラート判定用の素材(定価・出品者数・breakEven)。旧サーバーではキーごと無いためnil。
    let profitInputs: ProfitInputs?
    /// 無料枠ユニットの残量。Pro・SP-API連携済みには付かない(nil)。
    let quota: QuotaInfo?
}

/// 無料枠ユニットモデル(Phase B)の残量情報。/api/search・/api/graph-data・/api/quota が返す。
/// サーバーが状況により形の異なるJSONを返し得るため、全フィールドをOptionalにしておく。
struct QuotaInfo: Codable, Equatable {
    let unitsRemaining: Int?
    let baseRemaining: Int?
    let unitsUsed: Int?
    let adGrantsToday: Int?
    let adAvailable: Bool?
    let capReached: Bool?
    let limit: Int?
    /// Pro・deviceId無し等、無制限のとき true。
    let unlimited: Bool?
    /// サーバー障害等で残量が不明のとき true。この場合クライアントはローカルの残量を維持する。
    let unknown: Bool?
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

/// GET /api/keepa-test レスポンス(利用者自身のKeepa APIキーの疎通確認)。
struct KeepaTestResult: Codable, Equatable {
    let ok: Bool
    let tokensLeft: Int?
    let message: String?
}
