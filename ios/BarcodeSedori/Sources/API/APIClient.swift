import Foundation

enum APIClientError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpError(status: Int, body: String)
    case decodingError(Error)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "サーバーURLが不正です。設定タブでURLを確認してください。"
        case .invalidResponse:
            return "サーバーからの応答が不正です。"
        case .httpError(let status, let body):
            return "サーバーエラー(\(status)): \(body)"
        case .decodingError(let error):
            return "応答の解析に失敗しました: \(error.localizedDescription)"
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

/// サーバーとの通信を担うクライアント。
/// API契約 (/api/search, /api/offers, /api/health) に対応する。
/// CHANGES-v2.mdによりインストアコード学習機能(/api/learn)は廃止された。
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session

        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    /// UserDefaultsに保存されたベースURLを取得する。
    private func baseURL() throws -> URL {
        let raw = SettingsStore.shared.serverURLString
        guard var components = URLComponents(string: raw) else {
            throw APIClientError.invalidBaseURL
        }
        // 末尾スラッシュを除去しておく(パス連結時の重複防止)
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        guard let url = components.url else {
            throw APIClientError.invalidBaseURL
        }
        return url
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        let base = try baseURL()
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidBaseURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIClientError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addSpApiHeadersIfNeeded(to: &request)
        return request
    }

    /// SP-API連携が有効(Toggle ON かつリフレッシュトークンが非空)であれば、リクエストにSP-API認証ヘッダーを付与する。
    /// clientId/clientSecretは常にサーバー側の.envを使うため送信しない。サーバーは受け取ったリフレッシュトークンで
    /// SP-APIを呼び出す(サーバーには保存しない)。
    private func addSpApiHeadersIfNeeded(to request: inout URLRequest) {
        let settings = SettingsStore.shared
        guard settings.isSpApiLinkUsable else { return }
        request.setValue(settings.spapiRefreshToken, forHTTPHeaderField: "X-Spapi-Refresh-Token")
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIClientError.underlying(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIClientError.httpError(status: httpResponse.statusCode, body: body)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decodingError(error)
        }
    }

    /// GET /api/search?code={13桁}
    func search(code: String) async throws -> SearchResult {
        let request = try makeRequest(path: "/api/search", queryItems: [URLQueryItem(name: "code", value: code)])
        return try await perform(request, as: SearchResult.self)
    }

    /// GET /api/offers?asin={ASIN}
    func offers(asin: String) async throws -> OffersResult {
        let request = try makeRequest(path: "/api/offers", queryItems: [URLQueryItem(name: "asin", value: asin)])
        return try await perform(request, as: OffersResult.self)
    }

    /// GET /api/spapi/test
    /// 設定画面の「接続テスト」ボタンから呼ばれる。ヘッダーのSP-API認証情報でサーバーが疎通確認を行う。
    /// サーバーは常にHTTP 200で { ok: Bool, message: String? } を返す設計のため、
    /// httpErrorになった場合(サーバー未起動等)はそのままエラーを投げる。
    func spapiTest() async throws -> SpApiTestResult {
        let request = try makeRequest(path: "/api/spapi/test")
        return try await perform(request, as: SpApiTestResult.self)
    }

    /// 接続テスト用。GET /api/health があれば利用し、失敗した場合は /api/search を軽く叩いて疎通確認する。
    func testConnection() async throws {
        do {
            let request = try makeRequest(path: "/api/health")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIClientError.invalidResponse
            }
            if (200...299).contains(httpResponse.statusCode) {
                return
            }
            _ = data
            throw APIClientError.httpError(status: httpResponse.statusCode, body: "")
        } catch {
            // /api/health が無い、またはエラーの場合は /api/search を軽く叩いて疎通確認する
            let request = try makeRequest(path: "/api/search", queryItems: [URLQueryItem(name: "code", value: "0000000000000")])
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIClientError.invalidResponse
            }
            // サーバーが応答しさえすれば疎通OKとみなす(4xx/5xxでもサーバーは生きている)
            if httpResponse.statusCode >= 200 {
                return
            }
            throw APIClientError.invalidResponse
        }
    }
}
