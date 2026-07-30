import SwiftUI
import Charts

/// 価格推移グラフ1本分の点。時刻と値(円 or ランキング位)。
private struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

/// -1(データなし)で分割した1本の連続区間。series識別子ごとに独立した折れ線として描画することで、
/// データなし区間をまたいで線が繋がらないようにする。
private struct ChartSegment: Identifiable {
    let id: String
    let color: Color
    let points: [ChartPoint]
}

/// 価格推移グラフ(Pro専用)。旧来のKeepaサーバー画像描画をやめ、
/// /api/graph-data で取得した履歴データをSwift Chartsで自前描画する。
/// 上段=価格(Amazon/新品/中古)、下段=ランキングの2段構成(iOS16 Chartsには2軸が無いため)。
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

    /// 上段(170)+間隔(4)+下段(70)。ロード中/失敗時もこの高さを確保してレイアウトが跳ねないようにする。
    private static let reservedHeight: CGFloat = 170 + 4 + 70

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
        let amazonSegments = segments(from: data.series.amazon, seriesId: "amazon", color: .orange, now: now)
        let newSegments = segments(from: data.series.new, seriesId: "new", color: .blue, now: now)
        // 中古は黒だが、ダークモードでは.primary(白系)に自動追従させる。
        let usedSegments = segments(from: data.series.used, seriesId: "used", color: .primary, now: now)
        let rankSegments = segments(from: data.series.rank, seriesId: "rank", color: .green, now: now)
        let priceSegments = amazonSegments + newSegments + usedSegments
        let domain = xDomain(data: data, now: now)

        if priceSegments.isEmpty && rankSegments.isEmpty {
            Text("履歴データがありません")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.reservedHeight)
        } else {
            VStack(spacing: 4) {
                // 点が0個の系列(価格 or ランキングまるごと)は描かない。
                if !priceSegments.isEmpty {
                    // ランキング段が無いときだけ価格段にx軸ラベルを出す。
                    priceChart(segments: priceSegments, domain: domain, showsXAxisLabels: rankSegments.isEmpty)
                }
                if !rankSegments.isEmpty {
                    rankChart(segments: rankSegments, domain: domain)
                }
            }
        }
    }

    @ViewBuilder
    private func priceChart(segments: [ChartSegment], domain: ClosedRange<Date>, showsXAxisLabels: Bool) -> some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("時刻", point.time),
                        y: .value("価格", point.value),
                        series: .value("系列", segment.id)
                    )
                    .foregroundStyle(segment.color)
                    .interpolationMethod(.stepEnd)
                }
            }
        }
        // 凡例は既存のgraphLegend(親側の自前描画)を使うため、Charts標準の凡例は隠す。
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                if showsXAxisLabels, let date = value.as(Date.self) {
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
        }
        .frame(height: 170)
    }

    @ViewBuilder
    private func rankChart(segments: [ChartSegment], domain: ClosedRange<Date>) -> some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("時刻", point.time),
                        y: .value("ランキング", point.value),
                        series: .value("系列", segment.id)
                    )
                    .foregroundStyle(segment.color)
                    .interpolationMethod(.stepEnd)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartXAxis {
            // 下段は常にx軸ラベルを出す(上段と同じ範囲を共有)。
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
                    if let rank = value.as(Double.self) {
                        Text(Self.formatRank(rank))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 70)
    }

    // MARK: - データ加工

    /// 生の[[時刻, 値]]を期間でフィルタし、-1(データなし)で分割した区間の配列にする。
    private func segments(from raw: [[Double]], seriesId: String, color: Color, now: Date) -> [ChartSegment] {
        let points = filteredPoints(raw: raw, now: now)
        guard !points.isEmpty else { return [] }

        var result: [ChartSegment] = []
        var current: [ChartPoint] = []
        var index = 0
        for (time, value) in points {
            if value == -1 {
                if !current.isEmpty {
                    result.append(ChartSegment(id: "\(seriesId)-\(index)", color: color, points: current))
                    index += 1
                    current = []
                }
                continue
            }
            current.append(ChartPoint(time: time, value: value))
        }
        if !current.isEmpty {
            result.append(ChartSegment(id: "\(seriesId)-\(index)", color: color, points: current))
        }
        return result
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

    /// 上下2段で共有するx軸の範囲。期間指定時は「今日からrange日前〜今日」、
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
