import Foundation

/// 認証セッションの完了URL専用。通常のonOpenURLからは使用しない。
struct SpApiAuthorizationCallback {
    let refreshToken: String
    let sellerId: String

    init?(url: URL) {
        guard url.scheme == "barcodesedori", url.host == "spapi-auth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let tokens = items.filter { $0.name == "refresh_token" }
        let sellers = items.filter { $0.name == "selling_partner_id" }
        guard tokens.count == 1, sellers.count == 1,
              let token = tokens.first?.value, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let seller = sellers.first?.value, !seller.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        refreshToken = token
        sellerId = seller
    }
}
