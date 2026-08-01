import SwiftUI
import Charts
import Foundation

/// 価格推移グラフ1本分の点。時刻と値(円 or ランキング位、プロット用に正規化される前の値)。
private struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

/// 1系列の中の連続した1区間(セグメント)。-1(データなし)の位置で系列を分割した結果で、
/// セグメントごとに独立したChart描画(series)として扱うことで、区間をまたいで線をつながないようにする。
private struct ChartSegment: Identifiable {
    let id: String
    let points: [ChartPoint]
}

/// 1系列分の折れ線データ。-1(データなし)の前後でChartSegmentに分割済みで、
/// forward-fillや右端(現在時刻)までの延長は行わない。データが無い区間はそのまま線が途切れる。
private struct ChartSeries: Identifiable {
    let id: String
    let color: Color
    let segments: [ChartSegment]

    /// 全セグメントを通した点(y domainの算出などセグメントを区別しない集計に使う)。
    var allPoints: [ChartPoint] { segments.flatMap { $0.points } }
}

/// データ範囲から「切りの良い」目盛り間隔と軸範囲を求める(Keepa風の自動スケール)。
/// step候補は 1/2/5 × 10^n を昇順に並べたもの(2.5は使わない)。domainはstepの倍数へ
/// 内外に丸める(下限も0固定にせずデータへ追従させる)。区間数(ticks.count - 1)が
/// targetTicksを超える場合は、超えなくなるまでstep候補を1段ずつ上げて再計算する
/// (Y軸の段数をtargetTicks以下に揃えるため)。
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

        let maxRegions = max(targetTicks, 1)
        let rawStep = (hi - lo) / Double(maxRegions)
        let magnitudeExponent = Int(floor(log10(rawStep)))
        let normalized = rawStep / pow(10, Double(magnitudeExponent))

        // step候補: [1, 2, 5] × 10^n を昇順に並べた列。indexを1つ進めるごとに
        // 1→2→5→(桁上げして)1→2→5…と大きくなっていく。
        let multipliers: [Double] = [1, 2, 5]
        func step(at index: Int) -> Double {
            let exponent = magnitudeExponent + index / multipliers.count
            let multiplier = multipliers[index % multipliers.count]
            return multiplier * pow(10, Double(exponent))
        }

        var candidateIndex: Int
        if normalized < 1.5 {
            candidateIndex = 0
        } else if normalized < 3 {
            candidateIndex = 1
        } else if normalized < 7 {
            candidateIndex = 2
        } else {
            candidateIndex = 3
        }

        var currentStep = step(at: candidateIndex)
        var niceMin = max(0, (lo / currentStep).rounded(.down) * currentStep)
        var niceMax = (hi / currentStep).rounded(.up) * currentStep
        var regionCount = Int(((niceMax - niceMin) / currentStep).rounded())

        // 区間数がtargetTicksを超えている間は、超えなくなるまで次のstep候補へ進める。
        while regionCount > maxRegions {
            candidateIndex += 1
            currentStep = step(at: candidateIndex)
            niceMin = max(0, (lo / currentStep).rounded(.down) * currentStep)
            niceMax = (hi / currentStep).rounded(.up) * currentStep
            regionCount = Int(((niceMax - niceMin) / currentStep).rounded())
        }

        domainMin = niceMin
        domainMax = niceMax

        var generatedTicks: [Double] = []
        var v = niceMin
        // 浮動小数誤差でticksが1本欠けたり増えたりしないよう微小許容を入れる。
        while v <= niceMax + currentStep * 0.001 {
            generatedTicks.append(v)
            v += currentStep
        }
        ticks = generatedTicks
    }
}

/// 価格軸の区間数に合わせて「ちょうどregions区間」に収まるランキング軸を作る。
/// stepは1/2/5×10^nの切りの良い値から、domainMin(データ最小値をstepへ切り下げ)+regions*stepが
/// データ最大値以上になる最小のものを選ぶ。こうすると右軸の目盛りが
/// 価格軸のグリッド線(横線)とちょうど同じ高さに1対1で載る。
private struct AlignedRankScale {
    let domainMin: Double
    let domainMax: Double
    /// 目盛りのランキング値(domainMinからstep刻みでregions+1個)。
    let ticks: [Double]

    init?(dataMin: Double, dataMax: Double, regions: Int) {
        guard regions >= 1 else { return nil }
        var lo = dataMin
        var hi = dataMax
        if lo == hi {
            // 横一直線(全点同値)は±5%(最低±1)広げてから計算する。
            let pad = max(abs(lo) * 0.05, 1)
            lo = max(0, lo - pad)
            hi += pad
        }

        // step候補を小さい方から試し、regions区間で収まる最初の値を採用する。
        let multipliers: [Double] = [1, 2, 5]
        let startExponent = Int(floor(log10(max((hi - lo) / Double(regions), 1)))) - 1
        var chosen: (min: Double, step: Double)?
        outer: for exponent in startExponent...(startExponent + 12) {
            for multiplier in multipliers {
                let step = multiplier * pow(10, Double(exponent))
                let base = max(0, (lo / step).rounded(.down) * step)
                if base + step * Double(regions) >= hi {
                    chosen = (base, step)
                    break outer
                }
            }
        }
        guard let chosen else { return nil }

        domainMin = chosen.min
        domainMax = chosen.min + chosen.step * Double(regions)
        ticks = (0...regions).map { chosen.min + chosen.step * Double($0) }
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

    /// 価格とランキングを重ねた1段構成の高さ。チャート本体もこの値を使う。
    /// ロード中/失敗時も同じ高さを確保してレイアウトが跳ねないようにする。
    private static let reservedHeight: CGFloat = 140

    /// SP-API連携済みのとき、取得前に置く静止待ち時間(秒)。
    /// 連携済みの検索はトークン消費ゼロだが、グラフは新商品1件につきKeepaトークンを
    /// 1個消費する。高速連続スキャン中に商品ごとへ自動取得が走るとトークンが数分で
    /// 枯れるため、「結果が5秒画面に留まった(=ユーザーが関心を持って手を止めた)」
    /// 商品だけ取得する。次のスキャンでasinが変われば.task(id:)が待機中のタスクを
    /// キャンセルするので、流し読みした商品では消費が発生しない。
    /// 未連携はグラフデータが検索(history:1)に同梱されサーバーキャッシュ済み=追加消費
    /// ゼロのため、待たせる意味がなく即時取得する。
    private static let linkedFetchDelaySeconds: UInt64 = 5

    var body: some View {
        Group {
            if let graphData {
                chartsBody(data: graphData)
            } else if loadFailed {
                failureView
            } else {
                // 静止待ちの間もこの読み込み中表示(スピナー)が出る。
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

        // 連携済みは5秒静止するまで取得しない(理由はlinkedFetchDelaySecondsのコメント参照)。
        // Task.sleepはビューが消えるか別asinへ切り替わるとCancellationErrorを投げるため、
        // その場合はここで終了し取得は走らない(=トークン消費なし)。
        if SettingsStore.shared.isSpApiLinkUsable {
            do {
                try await Task.sleep(nanoseconds: Self.linkedFetchDelaySeconds * 1_000_000_000)
            } catch {
                return
            }
        }

        do {
            let data = try await APIClient.shared.graphData(asin: asin)
            Self.dataCache[asin] = data
            graphData = data
            // 無料枠ユニットの残量をローカルへ反映する(Pro・SP-API連携済みはquota==nilで何もしない)。
            ScanQuotaStore.shared.apply(data.quota)
        } catch {
            // 無料枠ユニット上限超過(429・quota_exceeded)も含め、失敗時は共通のfailureView
            // (エラー表示+タップで再読込)にする。クラッシュや無限ローディングにはならない。
            // quotaは反映しておき、検索タブのグラフ枠がfreeAdAreaへ即座に切り替わるようにする。
            if case APIClientError.quotaExceeded(let quota, _) = error {
                ScanQuotaStore.shared.apply(quota)
            }
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
    ///   ランキングがあれば、AlignedRankScaleで「価格軸とちょうど同じ区間数×切りの良いstep」の
    ///   domainを求め、`plotted = (rank - rankDomainMin) / (rankDomainMax - rankDomainMin) * (priceDomainMax - priceDomainMin) + priceDomainMin`
    ///   で価格domainへ線形正規化してから同じChartに重ねる。右側の軸の目盛り位置は価格軸のticksと
    ///   同一(=横線と同じ高さ)で、ラベルはindexで対応するランキング値を表示する。
    /// - 価格が1つも無くランキングだけがあるとき: ランキングを実値のままNiceScaleでdomain・ticksを求め、
    ///   右軸のみを表示する(左軸は出さない)。
    ///
    /// 各系列は-1(データなし)の位置で分割済みのChartSegmentごとに独立したseriesとして描画するため、
    /// データが途切れた区間は線がつながらない。Amazon系列のみ、線の下をchartYScaleの下限まで
    /// 薄いオレンジで塗るAreaMarkを追加してKeepaの見た目に寄せる。
    @ViewBuilder
    private func combinedChart(
        priceSeries: [ChartSeries],
        rankSeries: ChartSeries?,
        domain: ClosedRange<Date>
    ) -> some View {
        if !priceSeries.isEmpty {
            let priceValues = priceSeries.flatMap { $0.allPoints }.map { $0.value }
            let priceScale = NiceScale(dataMin: priceValues.min() ?? 0, dataMax: priceValues.max() ?? 1)
            let priceDomainMin = priceScale.domainMin
            let priceDomainMax = priceScale.domainMax
            let priceRegionCount = priceScale.ticks.count - 1

            let rankValues = rankSeries?.allPoints.map { $0.value } ?? []
            let rankScale: AlignedRankScale? = rankValues.isEmpty
                ? nil
                : AlignedRankScale(
                    dataMin: rankValues.min() ?? 0,
                    dataMax: rankValues.max() ?? 1,
                    regions: priceRegionCount
                )

            // ランキングを価格domainへ線形正規化(0除算回避のためrankDomainMax<=rankDomainMinなら
            // 正規化できない=右軸自体を出さない)。セグメント構成はそのまま、値だけ変換する。
            let normalizedRank: ChartSeries? = rankSeries.flatMap { rs -> ChartSeries? in
                guard let rankScale, rankScale.domainMax > rankScale.domainMin else { return nil }
                let segments = rs.segments.map { segment -> ChartSegment in
                    let points = segment.points.map { point -> ChartPoint in
                        let normalized = (point.value - rankScale.domainMin)
                            / (rankScale.domainMax - rankScale.domainMin)
                            * (priceDomainMax - priceDomainMin) + priceDomainMin
                        return ChartPoint(time: point.time, value: normalized)
                    }
                    return ChartSegment(id: segment.id, points: points)
                }
                return ChartSeries(id: rs.id, color: rs.color, segments: segments)
            }
            // 右軸の目盛り位置は価格軸のticksそのもの(横線と同じ高さ)。
            // AlignedRankScaleのticksは価格ticksとindexで1対1に対応する。
            let rankAxisPositions: [Double] = rankScale != nil ? priceScale.ticks : []

            Chart {
                ForEach(priceSeries) { s in
                    ForEach(s.segments) { segment in
                        if s.id == "amazon" {
                            // Amazon本体価格のみ、線の下をチャート下端(priceDomainMin)まで
                            // 薄いオレンジで塗ってKeepa風の見た目にする。
                            ForEach(segment.points) { point in
                                AreaMark(
                                    x: .value("時刻", point.time),
                                    yStart: .value("下限", priceDomainMin),
                                    yEnd: .value("価格", point.value),
                                    series: .value("系列", segment.id)
                                )
                                .foregroundStyle(Color.orange.opacity(0.15))
                                .interpolationMethod(.stepEnd)
                            }
                        }
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("時刻", point.time),
                                y: .value("価格", point.value),
                                series: .value("系列", segment.id)
                            )
                            .foregroundStyle(s.color)
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                }
                if let normalizedRank {
                    ForEach(normalizedRank.segments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("時刻", point.time),
                                y: .value("ランキング(正規化)", point.value),
                                series: .value("系列", segment.id)
                            )
                            .foregroundStyle(normalizedRank.color)
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        }
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
                    AxisTick()
                    AxisValueLabel(centered: false) {
                        if let date = value.as(Date.self) {
                            Text(Self.axisDateFormatter.string(from: date))
                        }
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
                    // 右軸(ランキング)は見かけ上の軸。目盛り位置は価格軸のticksと同一なので
                    // 横線と必ず一致する。ラベルはindexで対応するランキング値(切りの良い値)を表示する。
                    AxisMarks(position: .trailing, values: rankAxisPositions) { value in
                        AxisValueLabel {
                            if value.index < rankScale.ticks.count {
                                Text(Self.formatRank(rankScale.ticks[value.index]))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
            }
            .frame(height: Self.reservedHeight)
        } else if let rankSeries {
            // 価格系列が全て空: ランキングを実値のままプロットし、右軸のみ表示する(左軸なし)。
            let rankValues = rankSeries.allPoints.map { $0.value }
            let rankScale = NiceScale(dataMin: rankValues.min() ?? 0, dataMax: rankValues.max() ?? 1)

            Chart {
                ForEach(rankSeries.segments) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("時刻", point.time),
                            y: .value("ランキング", point.value),
                            series: .value("系列", segment.id)
                        )
                        .foregroundStyle(rankSeries.color)
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: domain)
            .chartYScale(domain: rankScale.domainMin...rankScale.domainMax)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(centered: false) {
                        if let date = value.as(Date.self) {
                            Text(Self.axisDateFormatter.string(from: date))
                        }
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
            .frame(height: Self.reservedHeight)
        }
    }

    // MARK: - データ加工

    /// 生の[[時刻, 値]]を期間でフィルタし、-1(データなし)の位置でChartSegmentに分割する。
    /// forward-fillはせず、-1は「線を引かない区間」としてそのまま扱う。先頭から連続する-1
    /// (直前に有効値が無いもの)はどのセグメントにも含めず捨てる。
    private func series(from raw: [[Double]], seriesId: String, color: Color, now: Date) -> ChartSeries? {
        let points = filteredPoints(raw: raw, now: now)
        guard !points.isEmpty else { return nil }

        var segments: [ChartSegment] = []
        var current: [ChartPoint] = []
        var segmentIndex = 0
        for (time, value) in points {
            if value == -1 {
                guard !current.isEmpty else { continue }
                segments.append(ChartSegment(id: "\(seriesId)-\(segmentIndex)", points: current))
                segmentIndex += 1
                current = []
            } else {
                current.append(ChartPoint(time: time, value: value))
            }
        }
        if !current.isEmpty {
            segments.append(ChartSegment(id: "\(seriesId)-\(segmentIndex)", points: current))
        }
        guard !segments.isEmpty else { return nil }
        return ChartSeries(id: seriesId, color: color, segments: segments)
    }

    /// 期間フィルタ。全期間(range.rawValue==0)はそのまま全点。それ以外は
    /// 「今日からrange日前」以降の点に絞り、窓開始直前に有効値(-1でない値)があれば
    /// その値を窓の先頭時刻にクランプして先頭へ足す(ステップ線が左端の時刻から途切れず
    /// 始まるように)。窓開始直前が-1(データなし)しか無い場合は何も足さない。
    private func filteredPoints(raw: [[Double]], now: Date) -> [(Date, Double)] {
        let points: [(Date, Double)] = raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (Date(timeIntervalSince1970: pair[0]), pair[1])
        }
        guard range.rawValue > 0 else { return points }

        let windowStart = now.addingTimeInterval(-Double(range.rawValue) * 86400)
        var windowed = points.filter { $0.0 >= windowStart }
        if let lastValidBefore = points.last(where: { $0.0 < windowStart && $0.1 != -1 }) {
            windowed.insert((windowStart, lastValidBefore.1), at: 0)
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
