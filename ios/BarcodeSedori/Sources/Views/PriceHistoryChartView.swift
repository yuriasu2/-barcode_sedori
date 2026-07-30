import SwiftUI
import Charts

/// 価格推移グラフ1本分の点。時刻と値(円 or ランキング位、プロット用に正規化される前の値)。
private struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

/// 1系列分の連続した折れ線データ。-1(データなし)はforward-fillで直前値に置き換え済みで、
/// 右端(現在時刻)まで最後の値の点を追加済みのため、系列内で線が途切れることはない。
private struct ChartSeries: Identifiable {
    let id: String
    let color: Color
    let points: [ChartPoint]
}

/// 価格推移グラフ(Pro専用)。旧来のKeepaサーバー画像描画をやめ、
/// /api/graph-data で取得した履歴データをSwift Chartsで自前描画する。
///
/// Keepaと同じ見た目に寄せるため、価格(Amazon/新品/中古)とランキングを1つのチャートに重ねる。
/// iOS16のSwift Chartsは2軸を持てないため、ランキングの値を価格のy domainへ線形変換してプロットし、
/// 右側にランキング用の見かけ上の軸を追加する「正規化方式」で実装している(詳細はcombinedChart内のコメント参照)。
struct PriceHistoryChartView: View {
    let asin: String
    let range: GraphRange

    @State private var graphData: GraphData?
    @State private var loadFailed = false
    /// タップでの再読込を`.task(id:)`に伝えるためのカウンタ(idに含めて再実行させる)。
    @State private var retryToken = 0

    /// asinをキーにしたセッション内キャッシュ。期間切替は通信を伴わずこのデータをフィルタするだけ
    /// (Keepaトークンの追加消費ゼロ)。同じasinの再取得も避ける(アプリ終了で破棄)。
    static var dataCache: [String: GraphData] = [:]

    /// 価格とランキングを重ねた1段構成。ロード中/失敗時もこの高さを確保してレイアウトが跳ねないようにする。
    private static let reservedHeight: CGFloat = 200

    var body: some View {
        Group {
            if let graphData {
                chartsBody(data: graphData)
            } else if loadFailed {
                failureView
            } else {
                loadingView
            }
        }
        .task(id: "\(asin)-\(retryToken)") {
            await load()
        }
    }

    private func load() async {
        if let cached = Self.dataCache[asin] {
            graphData = cached
            loadFailed = false
            return
        }
        graphData = nil
        loadFailed = false
        do {
            let data = try await APIClient.shared.graphData(asin: asin)
            Self.dataCache[asin] = data
            graphData = data
        } catch {
            loadFailed = true
        }
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: Self.reservedHeight)
    }

    private var failureView: some View {
        VStack(spacing: 4) {
            Text("グラフを一時的に取得できません")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("タップして再読み込み")
                .font(.caption2)
                .foregroundColor(.accentColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.reservedHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            retryToken += 1
        }
    }

    // MARK: - チャート本体

    @ViewBuilder
    private func chartsBody(data: GraphData) -> some View {
        let now = Date()
        let domain = xDomain(data: data, now: now)
        let amazon = series(from: data.series.amazon, seriesId: "amazon", color: .orange, now: now)
        let newSeries = series(from: data.series.new, seriesId: "new", color: .blue, now: now)
        // 中古は黒だが、ダークモードでは.primary(白系)に自動追従させる。
        let used = series(from: data.series.used, seriesId: "used", color: .primary, now: now)
        let rank = series(from: data.series.rank, seriesId: "rank", color: .green, now: now)
        let priceSeries = [amazon, newSeries, used].compactMap { $0 }

        if priceSeries.isEmpty && rank == nil {
            Text("履歴データがありません")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.reservedHeight)
        } else {
            combinedChart(priceSeries: priceSeries, rankSeries: rank, domain: domain)
        }
    }

    /// 価格とランキングを1つのChartに重ねて描画する。
    ///
    /// - 価格が1系列以上あるとき: 価格は実値のままプロットし、y domainを[0, priceDomainMax]とする。
    ///   ランキングがあれば `plottedY = rank / maxRank * priceDomainMax` で価格domainへ正規化してから
    ///   同じChartに重ねる。右側の軸は見かけ上の目盛りで、目盛り位置の値vを
    ///   `rank = v / priceDomainMax * maxRank` で逆変換してランキング表記に直す。
    /// - 価格が1つも無くランキングだけがあるとき: ランキングを実値のままプロットし、
    ///   右軸のみを表示する(左軸は出さない)。
    @ViewBuilder
    private func combinedChart(
        priceSeries: [ChartSeries],
        rankSeries: ChartSeries?,
        domain: ClosedRange<Date>
    ) -> some View {
        if !priceSeries.isEmpty {
            let priceMax = priceSeries.flatMap { $0.points }.map { $0.value }.max() ?? 0
            let priceDomainMax = max(priceMax * 1.05, 1)
            let maxRank = rankSeries?.points.map { $0.value }.max() ?? 0
            // ランキングを価格domainへ正規化(0除算回避のためmaxRank<=0なら正規化せず実値のまま=右軸は出さない)。
            let normalizedRank: ChartSeries? = rankSeries.flatMap { rs -> ChartSeries? in
                guard maxRank > 0 else { return nil }
                let points = rs.points.map { ChartPoint(time: $0.time, value: $0.value / maxRank * priceDomainMax) }
                return ChartSeries(id: rs.id, color: rs.color, points: points)
            }

            Chart {
                ForEach(priceSeries) { s in
                    ForEach(s.points) { point in
                        LineMark(
                            x: .value("時刻", point.time),
                            y: .value("価格", point.value),
                            series: .value("系列", s.id)
                        )
                        .foregroundStyle(s.color)
                        .interpolationMethod(.stepEnd)
                    }
                }
                if let normalizedRank {
                    ForEach(normalizedRank.points) { point in
                        LineMark(
                            x: .value("時刻", point.time),
                            y: .value("ランキング(正規化)", point.value),
                            series: .value("系列", normalizedRank.id)
                        )
                        .foregroundStyle(normalizedRank.color)
                        .interpolationMethod(.stepEnd)
                    }
                }
            }
            // 凡例は既存のgraphLegend(親側の自前描画)を使うため、Charts標準の凡例は隠す。
            .chartLegend(.hidden)
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...priceDomainMax)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel { Text(Self.axisDateFormatter.string(from: date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let yen = value.as(Double.self) {
                            Text(Self.formatYen(yen))
                                .font(.system(size: 9))
                        }
                    }
                }
                if normalizedRank != nil {
                    // 右軸(ランキング)は見かけ上の軸。目盛り位置vは価格domain上の値なので、
                    // 正規化の逆変換 rank = v / priceDomainMax * maxRank で実際の順位に戻して表示する。
                    // 左と目盛り数が揃わずグリッド線が二重になるとうるさいため、グリッド線は出さずラベルのみ描く。
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            if let plotted = value.as(Double.self) {
                                let rank = plotted / priceDomainMax * maxRank
                                Text(Self.formatRank(rank))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
            }
            .frame(height: 200)
        } else if let rankSeries {
            // 価格系列が全て空: ランキングを実値のままプロットし、右軸のみ表示する(左軸なし)。
            let rankMax = rankSeries.points.map { $0.value }.max() ?? 0
            let rankDomainMax = max(rankMax * 1.05, 1)

            Chart {
                ForEach(rankSeries.points) { point in
                    LineMark(
                        x: .value("時刻", point.time),
                        y: .value("ランキング", point.value),
                        series: .value("系列", rankSeries.id)
                    )
                    .foregroundStyle(rankSeries.color)
                    .interpolationMethod(.stepEnd)
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...rankDomainMax)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel { Text(Self.axisDateFormatter.string(from: date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let rank = value.as(Double.self) {
                            Text(Self.formatRank(rank))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 200)
        }
    }

    // MARK: - データ加工

    /// 生の[[時刻, 値]]を期間でフィルタし、-1(データなし)をforward-fill(直前の有効値で埋める)して
    /// 1本の連続系列にする。先頭から連続する-1(直前値が無い)は捨てる。
    /// 最後に、最終点の後ろへ「現在時刻(=窓の右端。全期間表示でも常に現在時刻)で最後の値」の点を追加し、
    /// .stepEndの線が右端まで水平に伸びて途切れないようにする。
    private func series(from raw: [[Double]], seriesId: String, color: Color, now: Date) -> ChartSeries? {
        let points = filteredPoints(raw: raw, now: now)
        guard !points.isEmpty else { return nil }

        var filled: [ChartPoint] = []
        var lastValid: Double?
        for (time, value) in points {
            if value == -1 {
                guard let lastValid else { continue }
                filled.append(ChartPoint(time: time, value: lastValid))
            } else {
                lastValid = value
                filled.append(ChartPoint(time: time, value: value))
            }
        }
        guard let last = filled.last else { return nil }

        if last.time < now {
            filled.append(ChartPoint(time: now, value: last.value))
        }
        return ChartSeries(id: seriesId, color: color, points: filled)
    }

    /// 期間フィルタ。全期間(range.rawValue==0)はそのまま全点。それ以外は
    /// 「今日からrange日前」以降の点に絞り、窓の直前の最後の点を窓の先頭時刻にクランプして
    /// 先頭へ足す(ステップ線が左端の時刻から途切れず始まるように)。
    private func filteredPoints(raw: [[Double]], now: Date) -> [(Date, Double)] {
        let points: [(Date, Double)] = raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (Date(timeIntervalSince1970: pair[0]), pair[1])
        }
        guard range.rawValue > 0 else { return points }

        let windowStart = now.addingTimeInterval(-Double(range.rawValue) * 86400)
        var windowed = points.filter { $0.0 >= windowStart }
        if let lastBefore = points.last(where: { $0.0 < windowStart }) {
            windowed.insert((windowStart, lastBefore.1), at: 0)
        }
        return windowed
    }

    /// チャートで共有するx軸の範囲。期間指定時は「今日からrange日前〜今日」、
    /// 全期間時は全系列を通した最古〜最新の時刻を使う。
    private func xDomain(data: GraphData, now: Date) -> ClosedRange<Date> {
        if range.rawValue > 0 {
            let start = now.addingTimeInterval(-Double(range.rawValue) * 86400)
            return start...now
        }
        let allRaw = data.series.amazon + data.series.new + data.series.used + data.series.rank
        let times = allRaw.compactMap { pair -> Date? in
            guard pair.count == 2 else { return nil }
            return Date(timeIntervalSince1970: pair[0])
        }
        guard let minTime = times.min(), let maxTime = times.max(), minTime < maxTime else {
            return now.addingTimeInterval(-86400)...now
        }
        return minTime...maxTime
    }

    // MARK: - 軸表記フォーマット

    private static let axisDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    /// 価格の軸ラベルを「¥1,000」風に整形する。
    private static func formatYen(_ value: Double) -> String {
        let intValue = Int(value.rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let numberString = formatter.string(from: NSNumber(value: intValue)) ?? "\(intValue)"
        return "¥\(numberString)"
    }

    /// ランキングの軸ラベルを「10万」風に短く整形する(1万未満はそのまま数字)。
    private static func formatRank(_ value: Double) -> String {
        let intValue = Int(value.rounded())
        guard intValue >= 10000 else { return "\(intValue)" }
        let man = Double(intValue) / 10000
        if abs(man - man.rounded()) < 0.05 {
            return "\(Int(man.rounded()))万"
        }
        return String(format: "%.1f万", man)
    }
}
