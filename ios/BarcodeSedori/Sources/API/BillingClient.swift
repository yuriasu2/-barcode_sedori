import Foundation
import StoreKit

/// Server API credentials are independent from StoreKit's local UI entitlement.
/// Only the credential bundle is persisted; unfinished StoreKit transactions retain retry work.
@MainActor
final class BillingClient {
    static let shared = BillingClient()
    private let transport: URLSession
    init(session: URLSession = .shared) { transport = session }
    private struct Credentials: Codable {
        var session: String
        var appAccountToken: UUID
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Double = 0
    }
    private struct SessionReply: Decodable { let session: String; let appAccountToken: UUID }
    private struct Reply: Decodable {
        let pro: Bool
        let accessToken: String?
        let refreshToken: String
        let expiresAt: Double
    }
    struct Pending: LocalizedError {
        var diagnostic: String? = nil
        var errorDescription: String? {
            let message = "購入状態を確認しています。再購入は不要です。通信環境をご確認のうえ、しばらくしてから再度お試しください。"
            #if DEBUG
            if let diagnostic { return message + "\n検証情報: " + diagnostic }
            #endif
            return message
        }
    }
    private var task: Task<[String: String], Error>?
    private var sessionTask: Task<Credentials, Error>?
    private var storageKey: String { "billing.credentials.v1." + SettingsStore.shared.serverURLString }
    private func load() -> Credentials? {
        guard let raw = KeychainStore.get(storageKey), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    private func save(_ value: Credentials) throws {
        let raw = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        guard KeychainStore.set(raw, for: storageKey) else { throw Pending() }
    }
    private func post<T: Decodable>(_ path: String, body: [String: String], session: String? = nil) async throws -> T {
        guard let base = URL(string: SettingsStore.shared.serverURLString) else { throw Pending() }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(session, forHTTPHeaderField: "X-Billing-Session")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch let error as URLError { throw Pending(diagnostic: "通信エラー \(error.code.rawValue)") }
        guard let http = response as? HTTPURLResponse else { throw Pending() }
        if http.statusCode == 401 {
            // Expired/rotated session: a fresh StoreKit proof is required to restore access.
            KeychainStore.delete(storageKey)
        }
        guard http.statusCode == 200 else {
            // Never include response messages, headers, credentials or purchase proofs.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = body?["error"] as? String ?? ""
            let allowed = ["invalid_purchase", "purchase_not_found", "invalid_environment", "billing_unavailable", "billing_unauthorized", "billing_rate_limited"]
            let detail = allowed.contains(code) ? " / " + code : ""
            throw Pending(diagnostic: "\(path) HTTP \(http.statusCode)\(detail)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func credentials() async throws -> Credentials {
        if let current = load() { return current }
        if let sessionTask { return try await sessionTask.value }
        let work = Task { @MainActor in
            let result: SessionReply = try await self.post("/api/billing/session", body: [:])
            let value = Credentials(session: result.session, appAccountToken: result.appAccountToken)
            try self.save(value)
            return value
        }
        sessionTask = work
        defer { sessionTask = nil }
        return try await work.value
    }
    func appAccountToken() async throws -> UUID { try await credentials().appAccountToken }

    /// Called with StoreKit-verified JWS, including revocations from Transaction.updates.
    func synchronize(_ signedTransaction: String) async throws -> Bool {
        var value = try await credentials()
        let result: Reply = try await post("/api/billing/verify", body: ["signedTransaction": signedTransaction], session: value.session)
        value.accessToken = result.accessToken
        value.refreshToken = result.refreshToken
        value.expiresAt = result.expiresAt
        try save(value)
        EntitlementStore.shared.serverSynchronizationCompleted()
        return result.pro
    }
    func clearAccess() {
        guard var value = load() else { return }
        value.accessToken = nil; value.refreshToken = nil; value.expiresAt = 0
        try? save(value)
    }
    func authorization(force: Bool = false) async throws -> [String: String] {
        if let task { return try await task.value }
        let work = Task { @MainActor in try await self.obtainAuthorization(force: force) }
        task = work
        defer { task = nil }
        return try await work.value
    }
    private func obtainAuthorization(force: Bool) async throws -> [String: String] {
        if !force, let value = load(), let token = value.accessToken,
           value.expiresAt > Date().timeIntervalSince1970 * 1000 + 30000 {
            return ["Authorization": "Bearer " + token, "X-Billing-Session": value.session]
        }
        if var value = load(), let refresh = value.refreshToken {
            do {
                let result: Reply = try await post("/api/billing/refresh", body: ["refreshToken": refresh], session: value.session)
                value.accessToken = result.accessToken; value.refreshToken = result.refreshToken; value.expiresAt = result.expiresAt
                try save(value)
                EntitlementStore.shared.serverSynchronizationCompleted()
                if let token = result.accessToken {
                    return ["Authorization": "Bearer " + token, "X-Billing-Session": value.session]
                }
                return [:]
            } catch {
                // A revoked/expired session can be rebuilt using Apple's verified proof.
                if load() != nil { throw Pending() }
            }
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == EntitlementStore.proProductID,
                  transaction.revocationDate == nil else { continue }
            do {
                _ = try await synchronize(result.jwsRepresentation)
                if let value = load(), let token = value.accessToken {
                    return ["Authorization": "Bearer " + token, "X-Billing-Session": value.session]
                }
                return [:]
            } catch { throw Pending() }
        }
        return [:]
    }
}
