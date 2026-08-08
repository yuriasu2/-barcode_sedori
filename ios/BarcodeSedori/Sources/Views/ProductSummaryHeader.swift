import SwiftUI

/// 商品のサムネイル・タイトルと、JAN/ASIN/ランク/参考価格/発売日/日付の6項目をまとめて出す部品。
/// 商品詳細画面と仕入れ内容画面で見た目を揃えるため、両方からこれを使う
/// (別々に書くと片方だけ直し忘れてズレるため)。
///
/// 右下のセルだけ画面によってラベルが変わる(商品詳細は「検索日」、仕入れ内容は「追加日」)ので、
/// ラベルと値を引数で受け取る。
///
/// **Formの中で使うときの注意**: 行の余白と背景が付いてカードに見えなくなるため、
/// `.listRowInsets(EdgeInsets())` と `.listRowBackground(Color.clear)` を必ず付けること。
struct ProductSummaryHeader: View {
    let imageUrl: String?
    let title: String?
    /// JAN欄に出す値。呼び出し側で `isbn13 ?? スキャンコード` を解決して渡す。
    let jan: String?
    let asin: String?
    let salesRank: Int?
    /// 定価(税込・円)。「参考価格」欄に出す。
    let listPrice: Int?
    /// 発売日(ISO日付文字列、例 "2025-06-17")。表示時に "2025/6/17" へ整形する。
    let releaseDate: String?
    /// 右下セルのラベル。「検索日」または「追加日」。
    let dateLabel: String
    let date: Date?

    /// 発売日のパース用(サーバーはSP-APIの "2019-05-30" 等のISO日付文字列をそのまま返す)。
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 日付の表示用(例: "2025/6/17")。
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    /// 数値の3桁区切り用(ランク・参考価格)。
    private static let groupedNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func groupedNumber(_ value: Int) -> String {
        groupedNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var rankText: String {
        salesRank.map { "\(Self.groupedNumber($0))位" } ?? "圏外"
    }

    private var listPriceText: String {
        listPrice.map { "¥\(Self.groupedNumber($0))" } ?? "-"
    }

    private var releaseDateText: String {
        guard let releaseDate, let parsed = Self.isoDateFormatter.date(from: releaseDate) else { return "-" }
        return Self.displayDateFormatter.string(from: parsed)
    }

    private var dateText: String {
        guard let date else { return "-" }
        return Self.displayDateFormatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            productImage
                .frame(width: 88, height: 88)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

            Text(title ?? "(タイトル不明)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    /// 商品画像。URLが無い/読み込み失敗時はプレースホルダ
    /// (URLなしでAsyncImageを使うとempty phaseでスピナーが回り続けるため先に分岐する)。
    @ViewBuilder
    private var productImage: some View {
        if let url = imageUrl.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    imagePlaceholder
                case .empty:
                    ProgressView()
                @unknown default:
                    Color.clear
                }
            }
        } else {
            imagePlaceholder
        }
    }

    private var imagePlaceholder: some View {
        Image(systemName: "photo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.secondary)
            .padding(24)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            gridRow(leftLabel: "JAN", leftValue: jan ?? "-", rightLabel: "ASIN", rightValue: asin ?? "-")
            Divider()
            gridRow(leftLabel: "ランク", leftValue: rankText, rightLabel: "参考価格", rightValue: listPriceText)
            Divider()
            gridRow(leftLabel: "発売日", leftValue: releaseDateText, rightLabel: dateLabel, rightValue: dateText)
        }
    }

    private func gridRow(leftLabel: String, leftValue: String, rightLabel: String, rightValue: String) -> some View {
        HStack(spacing: 0) {
            gridCell(label: leftLabel, value: leftValue)
            Divider()
            gridCell(label: rightLabel, value: rightValue)
        }
        // 行の高さは文字の実寸任せにせず整数で固定する。実寸任せだと行の高さが小数になり、
        // 区切り線が画素の境界からずれてアンチエイリアスで2画素に跨る行が出るため、
        // 特定の線(JAN/ASINの下など)だけ僅かに太く見えてしまう。
        // 併せて、セル間の縦線もこの高さいっぱいに伸びる。
        .frame(height: Self.gridRowHeight)
    }

    /// 情報グリッド1行の高さ(整数)。区切り線を画素境界に揃えるために固定する。
    private static let gridRowHeight: CGFloat = 36

    private func gridCell(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.footnote)
                .fontWeight(.medium)
                .monospacedDigit()
                // ASINやJANは桁が多く、狭いセルでは折り返さず縮めて1行に収める。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // 縦の余白は付けない(行の高さはgridRowHeightで固定し、内容は上下中央に置く)。
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }
}
