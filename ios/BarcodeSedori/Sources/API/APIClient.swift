import Foundation
import UIKit

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
    /// 端末識別子(identifierForVendor)。サーバー側の無料デバイス日次バックストップに使う。
    /// 端末ごとに安定・アンインストールでリセットされるランダムUUID(PIIではない)。
    private let deviceId: String? = UIDevice.current.identifierForVendor?.uuidString

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
        addDeviceHeader(to: &request)
        addSpApiHeadersIfNeeded(to: &request)
        return request
    }

    /// JSONボディ付きPOSTリクエストを作る。ヘッダー類(X-App-Plan / X-Device-Id /
    /// X-Spapi-Refresh-Token / X-Spapi-Seller-Id)はmakeRequestと同一の付与ロジックを通す。
    private func makePostRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw APIClientError.underlying(error)
        }
        return request
    }

    /// 端末識別子ヘッダー(X-Device-Id)を付与する。サーバー側の無料デバイス日次バックストップ用。
    private func addDeviceHeader(to request: inout URLRequest) {
        if let deviceId {
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
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

        // 利用者自身の連携(BYO)が有効なら、そのリフレッシュトークンを常に送る。
        // 未連携のときは何も付けない(サーバーはKeepa経路へフォールバックする)。
        guard settings.isSpApiLinkUsable else { return }

        request.setValue(settings.spapiRefreshToken, forHTTPHeaderField: "X-Spapi-Refresh-Token")
        // sellerId(出品系APIが必須とするIDで、Sellers APIからは取得不可能なためOAuth認可時に
        // 受け取った値をここで送る)。未取得(旧認可のまま)の場合は付与しない。
        let sellerId = settings.spapiSellerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sellerId.isEmpty {
            request.setValue(sellerId, forHTTPHeaderField: "X-Spapi-Seller-Id")
        }
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

    /// GET /api/graph-data?asin={ASIN}
    /// 価格・ランキングの履歴データ(Pro限定)。端末側でSwift Chartsに描画するため、
    /// 旧/api/graphのようなKeepa側レンダリング画像ではなく生データを受け取る。
    func graphData(asin: String) async throws -> GraphData {
        let request = try makeRequest(path: "/api/graph-data", queryItems: [URLQueryItem(name: "asin", value: asin)])
        return try await perform(request, as: GraphData.self)
    }

    /// GET /api/listings/restrictions?asin=&condition=
    /// 出品フォーム表示時の出品制限チェック(Pro+SP-API連携必須。サーバー側403ゲートあり)。
    func listingsRestrictions(asin: String, condition: String) async throws -> ListingRestrictionsResult {
        let request = try makeRequest(path: "/api/listings/restrictions", queryItems: [
            URLQueryItem(name: "asin", value: asin),
            URLQueryItem(name: "condition", value: condition),
        ])
        return try await perform(request, as: ListingRestrictionsResult.self)
    }

    /// GET /api/fees-estimate?asin=&price=&fba=(1|0)&shipping=
    /// 仕入れフォームの利益セクションが使う手数料見積り(Pro+SP-API連携必須。サーバー側403ゲートあり)。
    /// fbaはIsAmazonFulfilledに連動する(true=FBA手数料込み、false=自己発送)。
    /// shippingは購入者が支払う配送料(円。0以上の整数)。Amazonの販売手数料は
    /// 「出品価格+配送料」に対して課されるため、手数料計算の基礎として渡す。
    func feesEstimate(asin: String, price: Int, fba: Bool, shipping: Int) async throws -> FeesEstimateResult {
        let request = try makeRequest(path: "/api/fees-estimate", queryItems: [
            URLQueryItem(name: "asin", value: asin),
            URLQueryItem(name: "price", value: String(price)),
            URLQueryItem(name: "fba", value: fba ? "1" : "0"),
            URLQueryItem(name: "shipping", value: String(shipping)),
        ])
        return try await perform(request, as: FeesEstimateResult.self)
    }

    /// POST /api/listings — オファー出品(putListingsItem)。
    /// 出品は非同期受理のため、ACCEPTEDでも反映まで数分かかる。
    func submitListing(_ payload: ListingSubmissionRequest) async throws -> ListingSubmissionResult {
        let request = try makePostRequest(path: "/api/listings", body: payload)
        return try await perform(request, as: ListingSubmissionResult.self)
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
