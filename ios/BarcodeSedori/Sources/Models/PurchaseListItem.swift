import Foundation

/// 「仕入れ」タブに表示する仕入れリストの1件(Phase 1b)。
/// 保存は端末ローカルのみ(スキャン履歴と同じDocuments配下JSON方式)。サーバーには置かない
/// (プライバシーポリシー「履歴は端末内のみ」と整合させるため)。
struct PurchaseListItem: Codable, Equatable, Identifiable {
    let id: UUID
    let addedAt: Date
    /// 出品対象のASIN。ASINが無い商品は仕入れリストに追加できない(追加ボタン自体を出さない)。
    let asin: String
    let title: String?
    let imageUrl: String?
    /// スキャンしたコード(検索カード経由)。商品詳細経由はjanCodeを入れる。表示用。
    let scannedCode: String?
    let isbn13: String?
    let salesRank: Int?
    /// 追加時点のオファー一覧スナップショット。出品フォームの初期価格(同コンディション最安landed)に使う。
    /// 追加時点で未取得ならnil(フォーム表示時に/api/offersで再取得するため出品は可能)。
    var offersResult: OffersResult?
    /// 出品済みフラグ(Phase 2)。putListingsItemがACCEPTEDで受理されたらtrueにする。
    var isListed: Bool
    /// 出品に使ったSKU(出品済みのときのみ)。
    var listedSku: String?
    /// 出品受理日時(出品済みのときのみ)。
    var listedAt: Date?
    /// SKU枝番(仕入れリストに追加した順に採番。追加日が変わったら1にリセット、削除しても詰めない)。
    /// 旧データ(採番導入前に追加された項目)はnilのまま残り、出品フォーム表示時に遅延採番する。
    var skuSequence: Int?
    /// 採番した日(yyyyMMdd)。skuSequenceとセットで永続化する(採番のやり直し防止用)。
    var skuSequenceDate: String?
    /// 出品コンディション(仕入れタブの一括変更・仕入れフォームの初期値に使う)。
    /// 旧データ(導入前に追加された項目)はnilのまま残る。未設定時の既定は`.usedGood`(良い)。
    var condition: ListingConditionType?
    /// 仕入れフォーム(PurchaseFormView)で保存した価格(円)。未保存(旧データ含む)はnil。
    /// 一括出品はこの値をそのまま使い、nilの商品は失敗リストへ回す(価格の再取得はしない)。
    var price: Int?
    /// 仕入れフォームで保存した数量。未保存(旧データ含む)はnil(一括出品時は1として扱う)。
    var quantity: Int?
    /// 仕入れフォームで保存したコンディション説明文。未保存(旧データ含む)はnil
    /// (一括出品時はコンディションに応じたテンプレートを都度適用する)。
    var conditionNote: String?
    /// 仕入れフォームで保存したSKU。未保存(旧データ含む)はnil(一括出品時は従来経路で生成する)。
    var sku: String?
    /// FBA出品するか。nil=設定タブのデフォルト値(purchaseUseFbaDefault)を採用する扱い
    /// (旧データもnilのため、設定変更時にまとめて追従する)。
    var useFba: Bool?
    /// 仕入れ価格(円)。未保存(旧データ含む)はnil。利益セクションの入力値で、priceとは別枠
    /// (priceは出品価格)。
    var purchasePrice: Int?
    /// 配送料(円)。未保存(旧データ含む)はnil(利益セクション表示時は設定の配送料デフォルトを使う)。
    var shippingCost: Int?
    /// 仕入れ日。未保存(旧データ含む)はnil=addedAt(追加日)を仕入れ日として扱う。
    var purchaseDate: Date?
    /// 仕入先名(自由文字列。設定タブの仕入先リストから選ぶが、リストから削除されても保存値は残る)。
    var supplier: String?
    /// 自分用の内部メモ(出品には使わない)。
    var memo: String?

    init(
        id: UUID = UUID(),
        addedAt: Date = Date(),
        asin: String,
        title: String?,
        imageUrl: String?,
        scannedCode: String?,
        isbn13: String?,
        salesRank: Int?,
        offersResult: OffersResult? = nil,
        isListed: Bool = false,
        listedSku: String? = nil,
        listedAt: Date? = nil,
        skuSequence: Int? = nil,
        skuSequenceDate: String? = nil,
        condition: ListingConditionType? = nil,
        price: Int? = nil,
        quantity: Int? = nil,
        conditionNote: String? = nil,
        sku: String? = nil,
        useFba: Bool? = nil,
        purchasePrice: Int? = nil,
        shippingCost: Int? = nil,
        purchaseDate: Date? = nil,
        supplier: String? = nil,
        memo: String? = nil
    ) {
        self.id = id
        self.addedAt = addedAt
        self.asin = asin
        self.title = title
        self.imageUrl = imageUrl
        self.scannedCode = scannedCode
        self.isbn13 = isbn13
        self.salesRank = salesRank
        self.offersResult = offersResult
        self.isListed = isListed
        self.listedSku = listedSku
        self.listedAt = listedAt
        self.skuSequence = skuSequence
        self.skuSequenceDate = skuSequenceDate
        self.condition = condition
        self.price = price
        self.quantity = quantity
        self.conditionNote = conditionNote
        self.sku = sku
        self.useFba = useFba
        self.purchasePrice = purchasePrice
        self.shippingCost = shippingCost
        self.purchaseDate = purchaseDate
        self.supplier = supplier
        self.memo = memo
    }

    /// 検索タブの最新結果カードから追加する場合のコンビニエンスinit。
    init(result: SearchResult, scannedCode: String?, offersResult: OffersResult?) {
        self.init(
            asin: result.asin ?? "",
            title: result.title,
            imageUrl: result.imageUrl,
            scannedCode: scannedCode,
            isbn13: result.isbn13,
            salesRank: result.salesRank,
            offersResult: offersResult
        )
    }
}
