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
        skuSequenceDate: String? = nil
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
