import Foundation

/// サーバー管理型広告配信の設定ストア(シングルトン)。
/// 起動時に /api/ads を取得してメモリ+UserDefaultsにキャッシュする。次回起動はキャッシュを
/// 即座に反映してから裏で再取得し、取得失敗時はキャッシュ(それも無ければ空=広告なし)を使う。
@MainActor
final class AdsConfigStore: ObservableObject {
    static let shared = AdsConfigStore()

    /// slot id → 設定。取得前/失敗時かつキャッシュも無い場合は空(広告なし。安全側)。
    @Published private(set) var slots: [String: AdSlot] = [:]

    private static let cacheKey = "ads.configCache"

    /// impression計測を同一広告IDにつきセッション内1回までに間引くための既送信集合。
    private var sentImpressionAdIds = Set<String>()

    private let apiClient: APIClient
    private let defaults: UserDefaults

    init(apiClient: APIClient = .shared, defaults: UserDefaults = .standard) {
        self.apiClient = apiClient
        self.defaults = defaults
    }

    /// アプリ起動時に一度呼ぶ。
    func start() {
        loadCache()
        Task { await refresh() }
    }

    /// UserDefaultsのキャッシュを読み込み即座に反映する(無ければ何もしない)。
    private func loadCache() {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let response = try? JSONDecoder().decode(AdsResponse.self, from: data) else { return }
        apply(response)
    }

    /// サーバーから最新の広告設定を取得して反映・キャッシュする。失敗時はキャッシュ済みの状態を維持する。
    func refresh() async {
        do {
            let response = try await apiClient.fetchAds()
            apply(response)
            if let data = try? JSONEncoder().encode(response) {
                defaults.set(data, forKey: Self.cacheKey)
            }
        } catch {
            // 取得失敗時はloadCache()で反映済みの内容(無ければ空)をそのまま使う。
        }
    }

    private func apply(_ response: AdsResponse) {
        slots = response.slots.compactMapValues { $0 }
    }

    /// 広告の表示/クリックを計測送信する(fire-and-forget、失敗は無視)。
    /// impressionは同一広告IDにつきセッション内1回までに間引く(タブ再表示のたびの重複計測を防ぐ)。
    func sendEvent(slot: String, adId: String, kind: String) {
        if kind == "impression" {
            guard !sentImpressionAdIds.contains(adId) else { return }
            sentImpressionAdIds.insert(adId)
        }
        Task {
            try? await apiClient.sendAdEvent(slot: slot, adId: adId, kind: kind)
        }
    }
}
