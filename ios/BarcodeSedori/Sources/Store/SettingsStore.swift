import Foundation
import Combine

/// サーバーURLなどの設定値をUserDefaultsで永続化する。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let serverURL = "settings.serverURL"
        static let spapiLinkEnabled = "settings.spapiLinkEnabled"
        static let spapiRefreshToken = "settings.spapiRefreshToken"
    }

    private let defaults: UserDefaults

    @Published var serverURLString: String {
        didSet {
            defaults.set(serverURLString, forKey: Keys.serverURL)
        }
    }

    /// SP-API連携(利用者自身のAmazon大口出品アカウントでの検索)を有効にするか
    @Published var spapiLinkEnabled: Bool {
        didSet {
            defaults.set(spapiLinkEnabled, forKey: Keys.spapiLinkEnabled)
        }
    }

    /// SP-API (LWA) リフレッシュトークン
    @Published var spapiRefreshToken: String {
        didSet {
            defaults.set(spapiRefreshToken, forKey: Keys.spapiRefreshToken)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = defaults.string(forKey: Keys.serverURL) ?? "http://192.168.1.10:3000"
        self.spapiLinkEnabled = defaults.bool(forKey: Keys.spapiLinkEnabled)
        self.spapiRefreshToken = defaults.string(forKey: Keys.spapiRefreshToken) ?? ""
    }

    /// SP-API連携が利用可能か(有効かつリフレッシュトークンが非空)
    var isSpApiLinkUsable: Bool {
        spapiLinkEnabled
            && !spapiRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
