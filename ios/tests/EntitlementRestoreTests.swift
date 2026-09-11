// Compile with the real EntitlementStore.swift. These module-local substitutes
// isolate StoreKit, server traffic, analytics and UserDefaults from the machine.
import Foundation

final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}
enum AppStore { static func sync() async throws {} }
enum Proof {
    case verified(Transaction), unverified
    var jwsRepresentation: String { "verified-test-proof" }
}
struct Transaction {
    var productID: String { "jp.sellira.sellerlens.pro.monthly" }
    var revocationDate: Date? { nil }
    static var latestValue: Proof?
    static var currentEntitlementsValue: Proof?
    static var finishes = 0
    static var currentEntitlements: AsyncStream<Proof> {
        AsyncStream { continuation in
            if let currentEntitlementsValue { continuation.yield(currentEntitlementsValue) }
            continuation.finish()
        }
    }
    static var updates: AsyncStream<Proof> { AsyncStream { $0.finish() } }
    static func latest(for product: String) async -> Proof? { latestValue }
    func finish() async { Self.finishes += 1 }
}
@MainActor final class BillingClient {
    static let shared = BillingClient()
    struct Pending: LocalizedError {
        var errorDescription: String? { "購入状態を確認しています。再購入は不要です。" }
    }
    var result: Result<Bool, Error> = .success(false)
    var calls = 0
    func synchronize(_ proof: String) async throws -> Bool { calls += 1; return try result.get() }
    func appAccountToken() async throws -> UUID { UUID() }
    func clearAccess() {}
}
final class Analytics {
    static let shared = Analytics()
    enum Event { case proPurchased }
    func capture(_ event: Event) {}
}
@main struct EntitlementRestoreTests {
    @MainActor static func main() async {
        let store = EntitlementStore.shared
        let billing = BillingClient.shared
        Transaction.latestValue = nil
        let missing = await store.restore()
        precondition(!missing && store.restoreStatusMessage != nil, "no purchase must produce feedback")
        precondition(billing.calls == 0 && !store.restoreInProgress)

        Transaction.latestValue = .unverified
        let unverified = await store.restore()
        precondition(!unverified && store.lastActionErrorMessage != nil)
        precondition(billing.calls == 0 && Transaction.finishes == 0, "unverified proof must never be sent or finished")

        Transaction.latestValue = .verified(Transaction())
        billing.result = .failure(BillingClient.Pending())
        let failed = await store.restore()
        precondition(!failed && store.isPurchaseSyncPending && store.lastActionErrorMessage != nil)
        precondition(billing.calls == 1 && Transaction.finishes == 0, "server failure must preserve the unfinished purchase")

        billing.result = .success(false)
        let expired = await store.restore()
        precondition(!expired && !store.isPro && !store.isPurchaseSyncPending)
        precondition(store.restoreStatusMessage?.contains("有効なPro契約はありません") == true)
        precondition(billing.calls == 2 && Transaction.finishes == 1, "expired proof must still reach server verification")

        billing.result = .success(true)
        let restored = await store.restore()
        precondition(restored && store.isPro && !store.isPurchaseSyncPending)
        precondition(store.restoreStatusMessage == "購入を復元しました。")
        precondition(billing.calls == 3 && Transaction.finishes == 2 && !store.restoreInProgress)

        // StoreKitがactiveでも、サーバーがpro:falseを返した場合はPro状態を
        // キャッシュし続けず、次のAPIリクエストを無料扱いにしない。
        Transaction.currentEntitlementsValue = .verified(Transaction())
        billing.result = .success(false)
        await store.refreshEntitlements()
        precondition(!store.isPro && !store.isPurchaseSyncPending)
        precondition(billing.calls == 4 && Transaction.finishes == 3)
        print("Entitlement restore: missing, unverified, outage, expired and active purchase cases passed")
    }
}
