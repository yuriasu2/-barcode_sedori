import SwiftUI
import Charts
import Foundation

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

/// データ範囲から「切りの良い」目盛り間隔と軸範囲を求める(Keepa風の自動スケール)。
/// step候補は 1/2/5 × 10^n。domainはstepの倍数へ内外に丸める(下限も0固定にせずデータへ追従させる)。
private struct NiceScale {
    let domainMin: Double
    let domainMax: Double
    let ticks: [Double]

    init(dataMin: Double, dataMax: Double, targetTicks: Int = 5) {
        var lo = dataMin
        var hi = dataMax
        if lo == hi {
            // 横一直線(全点同値)は±5%(最低±1)広げてから計算する。
            let pad = max(abs(lo) * 0.05, 1)
            lo -= pad
            hi += pad
        }

        let rawStep = (hi - lo) / Double(targetTicks)
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let step: Double
        if normalized < 1.5 {
            step = 1 * magnitude
        } else if normalized < 3 {
            step = 2 * magnitude
        } else if normalized < 7 {
            step = 5 * magnitude
        } else {
            step = 10 * magnitude
        }

        let niceMin = max(0, (lo / step).rounded(.down) * step)
        let niceMax = (hi / step).rounded(.up) * step
        domainMin = niceMin
        domainMax = niceMax

        var generatedTicks: [Double] = []
        var v = niceMin
        // 浮動小数誤差でticksが1本欠けたり増えたりしないよう微小許容を入れる。
        while v <= niceMax + step * 0.001 {
            generatedTicks.append(v)
            v += step
        }
        ticks = generatedTicks
    }
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
    /// - 価格が1系列以上あるとき: 価格は実値のままプロットし、y domainは表示中データからNiceScaleで
    ///   算出した[priceDomainMin, priceDomainMax](Keepaのように下限もデータへ追従、ただし負にはしない)。
    ///   ランキングがあれば、ランキング側も別途NiceScaleでdomainを求め、
    ///   `plotted = (rank - rankDomainMin) / (rankDomainMax - rankDomainMin) * (priceDomainMax - priceDomainMin) + priceDomainMin`
    ///   で価格domainへ線形正規化してから同じChartに重ねる。右側の軸はrankScaleのticks(切りの良い
    ///   ランキング値)を同じ式でプロット座標へ変換した位置に置き、ラベルは逆変換
    ///   `rank = (plotted - priceDomainMin) / (priceDomainMax - priceDomainMin) * (rankDomainMax - rankDomainMin) + rankDomainMin`
    ///   で元のランキング値に戻して表示する。
    /// - 価格が1つも無くランキングだけがあるとき: ランキングを実値のままNiceScaleでdomain・ticksを求め、
    ///   右軸のみを表示する(左軸は出さない)。
    @ViewBuilder
    private func combinedChart(
        priceSeries: [ChartSeries],
        rankSeries: ChartSeries?,
        domain: ClosedRange<Date>
    ) -> some View {
        if !priceSeries.isEmpty {
            let priceValues = priceSeries.flatMap { $0.points }.map { $0.value }
            let priceScale = NiceScale(dataMin: priceValues.min() ?? 0, dataMax: priceValues.max() ?? 1)
            let priceDomainMin = priceScale.domainMin
            let priceDomainMax = priceScale.domainMax

            let rankValues = rankSeries?.points.map { $0.value } ?? []
            let rankScale: NiceScale? = rankValues.isEmpty
                ? nil
                : NiceScale(dataMin: rankValues.min() ?? 0, dataMax: rankValues.max() ?? 1)

            // ランキングを価格domainへ線形正規化(0除算回避のためrankDomainMax<=rankDomainMinなら
            // 正規化できない=右軸自体を出さない)。
            let normalizedRank: ChartSeries? = rankSeries.flatMap { rs -> ChartSeries? in
                guard let rankScale, rankScale.domainMax > rankScale.domainMin else { return nil }
                let points = rs.points.map { point -> ChartPoint in
                    let normalized = (point.value - rankScale.domainMin)
                        / (rankScale.domainMax - rankScale.domainMin)
                        * (priceDomainMax - priceDomainMin) + priceDomainMin
                    return ChartPoint(time: point.time, value: normalized)
                }
                return ChartSeries(id: rs.id, color: rs.color, points: points)
            }
            // 右軸の目盛り位置。rankScale.ticks(切りの良いランキング値)を同じ正規化式で
            // プロット座標へ変換しておく(ラベルは描画時に逆変換で元のランキング値へ戻す)。
            let rankAxisPositions: [Double] = {
                guard let rankScale, rankScale.domainMax > rankScale.domainMin else { return [] }
                return rankScale.ticks.map { tick in
                    (tick - rankScale.domainMin) / (rankScale.domainMax - rankScale.domainMin)
                        * (priceDomainMax - priceDomainMin) + priceDomainMin
                }
            }()

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
            .chartYScale(domain: priceDomainMin...priceDomainMax)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel { Text(Self.axisDateFormatter.string(from: date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: priceScale.ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let yen = value.as(Double.self) {
                            Text(Self.formatYen(yen))
                                .font(.system(size: 9))
                        }
                    }
                }
                if let rankScale, !rankAxisPositions.isEmpty {
                    // 右軸(ランキング)は見かけ上の軸。目盛り位置はrankScale.ticksを正規化式で
                    // プロット座標へ変換した値なので、ラベルは逆変換で元のランキング値に戻して表示する。
                    // 左と目盛り数が揃わずグリッド線が二重になるとうるさいため、グリッド線は出さずラベルのみ描く。
                    AxisMarks(position: .trailing, values: rankAxisPositions) { value in
                        AxisValueLabel {
                            if let plotted = value.as(Double.self) {
                                let rank = (plotted - priceDomainMin) / (priceDomainMax - priceDomainMin)
                                    * (rankScale.domainMax - rankScale.domainMin) + rankScale.domainMin
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
            let rankValues = rankSeries.points.map { $0.value }
            let rankScale = NiceScale(dataMin: rankValues.min() ?? 0, dataMax: rankValues.max() ?? 1)

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
            .chartYScale(domain: rankScale.domainMin...rankScale.domainMax)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel { Text(Self.axisDateFormatter.string(from: date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: rankScale.ticks) { value in
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
