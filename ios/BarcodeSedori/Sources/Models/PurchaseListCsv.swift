import Foundation

/// 仕入れリストのCSV書き出し(自分用のデータ出力: Excel等での仕入れ管理・経理向け)。
/// Amazonへアップロードする在庫ファイル形式ではないため、Amazon固有の列仕様には合わせない。
/// テストしやすいよう、文字列生成のみを純粋関数として持つ(ファイルI/Oは呼び出し側で行う)。
enum PurchaseListCsv {
    /// CSVの列見出し(この順序)。
    static let header: [String] = [
        "仕入れ日", "商品名", "ASIN", "JAN/ISBN", "コンディション",
        "出品価格", "数量", "SKU", "配送方法",
        "仕入れ価格", "配送料", "発送費用", "仕入先", "メモ",
        "出品状況", "出品日"
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    /// 渡された順序のまま(呼び出し側で画面表示順に並べ替え済みの前提)CSV文字列を生成する。
    ///
    /// 利益(出品価格 - 仕入れ価格 等)の列はあえて作らない。販売手数料がPurchaseListItemに
    /// 保存されておらず正確な利益を算出できないため。出品価格・仕入れ価格は出力しているので、
    /// 必要であればExcel側で計算してもらう。
    ///
    /// 改行はExcelとの互換性のためCRLF("\r\n")を使う。BOMはこの文字列には含めない
    /// (呼び出し側でファイル書き出し時にUTF-8 BOMを付与すること。BOMが無いとWindows版Excelで
    /// 日本語が文字化けするため)。
    static func makeCsv(items: [PurchaseListItem]) -> String {
        var lines: [String] = [header.map(escape).joined(separator: ",")]

        for item in items {
            let fields: [String] = [
                dateFormatter.string(from: item.purchaseDate ?? item.addedAt),
                item.title ?? "",
                item.asin,
                item.isbn13 ?? item.scannedCode ?? "",
                item.condition?.displayName ?? "",
                item.price.map(String.init) ?? "",
                item.quantity.map(String.init) ?? "",
                item.sku ?? "",
                fulfillmentText(item.useFba),
                item.purchasePrice.map(String.init) ?? "",
                item.shippingIncome.map(String.init) ?? "",
                item.shippingCost.map(String.init) ?? "",
                item.supplier ?? "",
                item.memo ?? "",
                item.isListed ? "出品済み" : "未出品",
                item.listedAt.map(dateFormatter.string(from:)) ?? ""
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        return lines.joined(separator: "\r\n")
    }

    private static func fulfillmentText(_ useFba: Bool?) -> String {
        switch useFba {
        case .some(true): return "FBA"
        case .some(false): return "自己発送"
        case .none: return ""
        }
    }

    /// CSVエスケープ: `,` `"` 改行のいずれかを含む場合はダブルクォートで囲み、
    /// 値中のダブルクォートは""に二重化する。
    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
