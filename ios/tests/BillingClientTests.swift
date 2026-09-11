// Standalone macOS test executable. URLProtocol and these stores prevent all real
// Apple traffic and Keychain writes. Compile only with BillingClient.swift.
import Foundation

enum KeychainStore {
    static var values: [String: String] = [:]
    static var failWrites = false
    static func get(_ key: String) -> String? { values[key] }
    @discardableResult static func set(_ value: String, for key: String) -> Bool {
        if failWrites { return false }
        values[key] = value; return true
    }
    @discardableResult static func delete(_ key: String) -> Bool { values[key] = nil; return true }
}
final class SettingsStore {
    static let shared = SettingsStore()
    var serverURLString = "https://billing.test"
}
@MainActor final class EntitlementStore {
    static let shared = EntitlementStore()
    static let proProductID = "jp.sellira.sellerlens.pro.monthly"
    func serverSynchronizationCompleted() {}
}
final class BillingProtocol: URLProtocol {
    static var respond: (URLRequest) -> (Int, [String: Any]) = { _ in fatalError("unexpected request") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct BillingClientTests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BillingProtocol.self]
        let transport = URLSession(configuration: config)
        let client = BillingClient(session: transport)
        let uuid = "5D1E9D81-986F-42C1-B123-063A874DE102"
        var sessionCalls = 0
        BillingProtocol.respond = { request in
            precondition(request.url!.path == "/api/billing/session")
            sessionCalls += 1
            return (200, ["session": "server-session", "appAccountToken": uuid])
        }
        async let one = client.appAccountToken()
        async let two = client.appAccountToken()
        let pair = try await (one, two)
        precondition(pair.0 == pair.1 && sessionCalls == 1, "session creation must coalesce")
        var verifyCalls = 0
        BillingProtocol.respond = { request in
            precondition(request.url!.path == "/api/billing/verify")
            precondition(request.value(forHTTPHeaderField: "X-Billing-Session") == "server-session")
            verifyCalls += 1
            return (200, ["pro": true, "accessToken": "verified-access", "refreshToken": "refresh", "expiresAt": Date().timeIntervalSince1970 * 1000 + 120000])
        }
        let purchased = try await client.synchronize("storekit-proof")
        precondition(purchased && verifyCalls == 1)
        BillingProtocol.respond = { _ in fatalError("fresh access must not fetch") }
        let headers = try await client.authorization()
        precondition(headers["Authorization"] == "Bearer verified-access")
        precondition(headers["X-Billing-Session"] == "server-session")
        BillingProtocol.respond = { _ in (503, ["error": "billing_unavailable"]) }
        do { _ = try await client.authorization(force: true); fatalError("outage must remain pending") }
        catch is BillingClient.Pending {}
        precondition(!KeychainStore.values.isEmpty, "outage must retain retry credentials")
        var refreshCalls = 0
        BillingProtocol.respond = { request in
            precondition(request.url!.path == "/api/billing/refresh")
            refreshCalls += 1
            return (200, ["pro": false, "accessToken": NSNull(), "refreshToken": "refresh", "expiresAt": 0])
        }
        let revoked = try await client.authorization(force: true)
        precondition(revoked.isEmpty && refreshCalls == 1, "revocation must remove API access")
        BillingProtocol.respond = { _ in (400, ["error": "invalid_purchase", "message": "SECRET-PURCHASE-DATA"]) }
        do { _ = try await client.synchronize("private-proof"); fatalError("invalid proof must fail") }
        catch {
            #if DEBUG
            precondition(error.localizedDescription.contains("HTTP 400"), "verification diagnostics must identify HTTP status")
            precondition(error.localizedDescription.contains("invalid_purchase"))
            #else
            precondition(!error.localizedDescription.contains("HTTP 400"))
            #endif
            precondition(!error.localizedDescription.contains("SECRET-PURCHASE-DATA"))
            precondition(!error.localizedDescription.contains("private-proof"))
        }
        KeychainStore.failWrites = true
        BillingProtocol.respond = { _ in (200, ["pro": true, "accessToken": "new", "refreshToken": "refresh", "expiresAt": 123]) }
        do { _ = try await client.synchronize("proof"); fatalError("Keychain failure must not acknowledge delivery") }
        catch is BillingClient.Pending {}
        print("BillingClient: session coalescing, synchronization, cached access, outage, revocation, persistence failure passed")
    }
}
