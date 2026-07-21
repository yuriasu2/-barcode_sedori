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
        let marginEnabled: Bool
        let marginThreshold: Int
        let purchaseCost: Int
        let targetCondition: ProfitAlertCondition
        let rankEnabled: Bool
        let rankThreshold: Int
        let sellerCountEnabled: Bool
        let sellerCountThreshold: Int
        let listPriceEnabled: Bool
    }

    /// 判定はAND。ONの条件がデータ欠落で判定できない場合は不成立=非発火(安全側)。
    /// ただし定価条件のみ、listPrice==nilならスキップして他条件で判定する
    /// (定価条件のみONでlistPrice==nilの場合は、判定した条件が0個になるため非発火とする)。
    static func evaluate(result: SearchResult, settings: Settings) -> Verdict {
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
            evaluatedConditionCount += 1
            if let sellerCount = sellerCount(result: result, condition: settings.targetCondition),
               sellerCount <= settings.sellerCountThreshold {
                // 成立
            } else {
                allSatisfied = false
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
        }
    }

    private static func sellerCount(result: SearchResult, condition: ProfitAlertCondition) -> Int? {
        guard let sellerCounts = result.profitInputs?.sellerCounts else { return nil }
        switch condition {
        case .new: return sellerCounts.new
        case .used: return sellerCounts.used
        }
    }

    /// 定価条件が参照する売値。既存の簡易価格(prices.new/used)を使う。
    private static func sellPrice(result: SearchResult, condition: ProfitAlertCondition) -> Int? {
        guard let prices = result.prices else { return nil }
        switch condition {
        case .new: return prices.new
        case .used: return prices.used
        }
    }
}
