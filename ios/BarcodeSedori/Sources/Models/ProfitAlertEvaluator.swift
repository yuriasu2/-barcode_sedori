import Foundation

/// 利益アラートの判定(純関数)。設定スナップショットとSearchResultだけを見る。
/// UIKit/Combine非依存にして判定表を単体で検証可能に保ち、Phase 1b以降の再利用にも備える
/// (ViewModel直書きにしない理由)。
struct ProfitAlertEvaluator {
    struct Verdict: Equatable {
        let isTriggered: Bool
        /// 表示用の粗利(円)。粗利条件OFFや算出不能時はnil。
        let grossMargin: Double?
    }

    /// 判定に使う設定値のスナップショット。SettingsStoreから都度組み立てて渡す。
    struct Settings {
        /// 利益アラート機能全体のマスタースイッチ。falseなら他条件を見ずに非発火とする。
        let enabled: Bool
        let marginEnabled: Bool
        let marginThreshold: Int
        let purchaseCost: Int
        let targetCondition: ProfitAlertCondition
        let rankEnabled: Bool
        let rankThreshold: Int
        let sellerCountEnabled: Bool
        let sellerCountNewThreshold: Int
        let sellerCountUsedThreshold: Int
        let listPriceEnabled: Bool
    }

    /// 判定はAND。ONの条件がデータ欠落で判定できない場合は不成立=非発火(安全側)。
    /// ただし定価条件のみ、listPrice==nilならスキップして他条件で判定する
    /// (定価条件のみONでlistPrice==nilの場合は、判定した条件が0個になるため非発火とする)。
    static func evaluate(result: SearchResult, settings: Settings) -> Verdict {
        // マスタースイッチがOFFなら他条件を見ずに非発火。
        guard settings.enabled else { return Verdict(isTriggered: false, grossMargin: nil) }

        // 粗利(表示用にも使うため、条件のON/OFFに関わらず算出できるなら算出しておく)。
        let grossMargin = computeGrossMargin(result: result, settings: settings)

        var evaluatedConditionCount = 0
        var allSatisfied = true

        if settings.marginEnabled {
            evaluatedConditionCount += 1
            if let grossMargin, grossMargin >= Double(settings.marginThreshold) {
                // 成立
            } else {
                allSatisfied = false
            }
        }

        if settings.rankEnabled {
            evaluatedConditionCount += 1
            if let salesRank = result.salesRank, salesRank <= settings.rankThreshold {
                // 成立
            } else {
                allSatisfied = false
            }
        }

        if settings.sellerCountEnabled {
            // 閾値が1以上の側だけを判定対象にする(0は「判定しない」)。新品・中古とも0ならこの条件は評価対象に数えない。
            let newActive = settings.sellerCountNewThreshold >= 1
            let usedActive = settings.sellerCountUsedThreshold >= 1
            if newActive || usedActive {
                evaluatedConditionCount += 1
                if newActive {
                    if let newCount = sellerCount(result: result, condition: .new),
                       newCount <= settings.sellerCountNewThreshold {
                        // 成立
                    } else {
                        allSatisfied = false
                    }
                }
                if usedActive {
                    if let usedCount = sellerCount(result: result, condition: .used),
                       usedCount <= settings.sellerCountUsedThreshold {
                        // 成立
                    } else {
                        allSatisfied = false
                    }
                }
            }
        }

        if settings.listPriceEnabled {
            if let listPrice = result.profitInputs?.listPrice {
                evaluatedConditionCount += 1
                if let sellPrice = sellPrice(result: result, condition: settings.targetCondition),
                   sellPrice >= listPrice {
                    // 成立
                } else {
                    allSatisfied = false
                }
            }
            // listPrice==nilはスキップ(この条件は評価対象に数えない)。
        }

        // 全条件OFF、または定価条件のみONでlistPrice==nil(評価できた条件が0個)は非発火。
        let isTriggered = evaluatedConditionCount > 0 && allSatisfied
        return Verdict(isTriggered: isTriggered, grossMargin: grossMargin)
    }

    /// 粗利 = breakEven[対象コンディション] − 仕入れ値。breakEvenが取れなければnil。
    private static func computeGrossMargin(result: SearchResult, settings: Settings) -> Double? {
        guard let breakEven = breakEven(result: result, condition: settings.targetCondition) else {
            return nil
        }
        return breakEven - Double(settings.purchaseCost)
    }

    private static func breakEven(result: SearchResult, condition: ProfitAlertCondition) -> Double? {
        guard let breakEven = result.profitInputs?.breakEven else { return nil }
        switch condition {
        case .new: return breakEven.new
        case .used: return breakEven.used
        case .both:
            // bothは新品・中古のうち有利な方(高い方)で判定する。両方取れれば大きい方、片方だけならその値、どちらも無ければnil。
            return maxOfAvailable(breakEven.new, breakEven.used)
        }
    }

    /// 出品者数は対象コンディションPickerとは独立に新品/中古それぞれの閾値で判定するため、
    /// 呼び出し側は常に.new/.usedを明示して渡す(.bothは来ない)。
    private static func sellerCount(result: SearchResult, condition: ProfitAlertCondition) -> Int? {
        guard let sellerCounts = result.profitInputs?.sellerCounts else { return nil }
        switch condition {
        case .new: return sellerCounts.new
        case .used: return sellerCounts.used
        case .both: return nil
        }
    }

    /// 定価条件が参照する売値。既存の簡易価格(prices.new/used)を使う。
    private static func sellPrice(result: SearchResult, condition: ProfitAlertCondition) -> Int? {
        guard let prices = result.prices else { return nil }
        switch condition {
        case .new: return prices.new
        case .used: return prices.used
        case .both:
            // bothは新品・中古のうち有利な方(高い方)で判定する。両方取れれば大きい方、片方だけならその値、どちらも無ければnil。
            return maxOfAvailable(prices.new, prices.used)
        }
    }

    /// 2つのオプショナル値のうち、取得できた方の最大値を返す。両方nilならnil。
    private static func maxOfAvailable<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}
