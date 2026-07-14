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
        addPlanHeader(to: &request)
        addSpApiHeadersIfNeeded(to: &request)
        return request
    }

    /// フリーミアム: 自己申告のプランヘッダー(X-App-Plan)を付与する。
    /// Pro状態は EntitlementStore(メインアクター)が UserDefaults にミラーした値を同期で読む。
    /// キーは EntitlementStore.isProCachedKey と一致させること。
    private func addPlanHeader(to request: inout URLRequest) {
        let isPro = UserDefaults.standard.bool(forKey: "settings.isProCached")
        request.setValue(isPro ? "pro" : "free", forHTTPHeaderField: "X-App-Plan")
    }

    /// SP-API連携が有効(Toggle ON かつリフレッシュトークンが非空)であれば、リクエストにSP-API認証ヘッダーを付与する。
    /// clientId/clientSecretは常にサーバー側の.envを使うため送信しない。サーバーは受け取ったリフレッシュトークンで
    /// SP-APIを呼び出す(サーバーには保存しない)。
    private func addSpApiHeadersIfNeeded(to request: inout URLRequest) {
        let settings = SettingsStore.shared

        // Render側SP-APIが無効なら、サーバーにSP-APIを一切使わせない指示ヘッダーを付与して即return。
        // (サーバーは.env/ヘッダーのSP-API認証を無視しKeepaへフォールバックする)
        guard settings.renderSpApiEnabled else {
            request.setValue("1", forHTTPHeaderField: "X-Disable-Spapi")
            return
        }

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

    /// GET /api/offers?asin={ASIN}&source={source}
    /// sourceが非nilならクエリに追加する。nilの場合はクエリ自体を付けない。
    func offers(asin: String, source: String?) async throws -> OffersResult {
        var queryItems = [URLQueryItem(name: "asin", value: asin)]
        if let source {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }
        let request = try makeRequest(path: "/api/offers", queryItems: queryItems)
        return try await perform(request, as: OffersResult.self)
    }

    /// Keepaグラフ画像のURL({サーバーURL}/api/graph?asin=&range=)を組み立てる。
    /// AsyncImageに直接渡せるよう throws にはせず、失敗時は nil を返す。
    /// - Parameter range: グラフ期間(日数)。省略時は90(サーバー側デフォルトと同じ)。
    func graphURL(asin: String, range: Int = 90) -> URL? {
        do {
            let base = try baseURL()
            guard var components = URLComponents(url: base.appendingPathComponent("/api/graph"), resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.queryItems = [
                URLQueryItem(name: "asin", value: asin),
                URLQueryItem(name: "range", value: String(range)),
            ]
            return components.url
        } catch {
            return nil
        }
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
