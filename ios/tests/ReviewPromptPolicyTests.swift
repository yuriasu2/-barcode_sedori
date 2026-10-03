import Foundation

// レビュー依頼の利用バー(検索10回・起動2日)を検証する単体テスト。
// ReviewPromptControllerはUserDefaultsを注入できるため、専用suiteで本番の値と分離する。
// 実行: swiftc -module-cache-path /tmp/sellerlens-swift-cache BarcodeSedori/Sources/Store/ReviewPromptController.swift tests/ReviewPromptPolicyTests.swift -o /tmp/rp && /tmp/rp

nonisolated(unsafe) var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
}

func makeController(searches: Int, days: Int) -> ReviewPromptController {
    let suite = "review-policy-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    // 日数は暦日が異なる起動でしか増えないため、カウンタを直接仕込む(実際のキーは内部定数)。
    defaults.set(searches, forKey: "review.searchCount")
    defaults.set(days, forKey: "review.activeDayCount")
    return ReviewPromptController(defaults: defaults)
}

@main
struct ReviewPromptPolicyTests {
    static func main() {
        // (a) 無料ユーザー: 検索10回・2日・仕入れ追加0 → 対象
        let a = makeController(searches: 10, days: 2)
        check(a.consumeEligibility(trigger: .launch), "10回/2日/仕入れ追加0で対象")
        // (d) 同一バージョンでの2回目は対象外
        check(!a.consumeEligibility(trigger: .launch), "同一バージョン2回目は対象外")
        // (b) 検索9回
        check(!makeController(searches: 9, days: 2).consumeEligibility(trigger: .launch), "検索9回は対象外")
        // (c) 起動1日
        check(!makeController(searches: 10, days: 1).consumeEligibility(trigger: .launch), "起動1日は対象外")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if failures != 0 { exit(1) }
    }
}
