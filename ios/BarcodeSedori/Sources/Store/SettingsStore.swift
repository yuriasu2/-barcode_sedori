import Foundation
import Combine

/// サーバーURLなどの設定値をUserDefaultsで永続化する。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let serverURL = "settings.serverURL"
        static let spapiLinkEnabled = "settings.spapiLinkEnabled"
        /// 旧: UserDefaultsに平文保存していたキー。現在はKeychainへ移行済み(初回起動時に自動移行して削除)。
        static let legacySpapiRefreshToken = "settings.spapiRefreshToken"
        static let renderSpApiEnabled = "settings.renderSpApiEnabled"
    }

    /// Keychain上のアカウント名(リフレッシュトークン用)。
    private static let keychainRefreshTokenAccount = "spapi.refreshToken"

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

    /// SP-API (LWA) リフレッシュトークン。
    /// 販売パートナーのセラーアカウントへのアクセス権を持つ機微情報のため、
    /// UserDefaults(平文)ではなくKeychainに保存する(AmazonのDPP要件)。
    @Published var spapiRefreshToken: String {
        didSet {
            KeychainStore.set(spapiRefreshToken, for: Self.keychainRefreshTokenAccount)
        }
    }

    /// サーバー(Render)側のSP-APIを使用するか。
    /// オフにするとリクエストにX-Disable-Spapiヘッダーを付与し、サーバーはSP-APIを一切使わずKeepaへフォールバックする。
    /// Keepaの動作確認をRender登録済みのSP-APIキーに邪魔されずに行うためのトグル。既定はオン。
    @Published var renderSpApiEnabled: Bool {
        didSet {
            defaults.set(renderSpApiEnabled, forKey: Keys.renderSpApiEnabled)
        }
    }

    /// 本番APIの既定URL(独自ドメイン)。
    /// Cloudflare Workers を指すが、DNSで切替可能なため将来サーバーを移してもアプリ更新は不要。
    static let defaultServerURL = "https://api.sellira.jp"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        self.spapiLinkEnabled = defaults.bool(forKey: Keys.spapiLinkEnabled)
        // 未設定時は既定でオン(サーバー側SP-APIを使う従来動作)にする。
        self.renderSpApiEnabled = (defaults.object(forKey: Keys.renderSpApiEnabled) as? Bool) ?? true

        // リフレッシュトークンはKeychainから読む。
        // 旧バージョンでUserDefaultsに平文保存されていた場合は、ここでKeychainへ移行し平文を削除する。
        if let keychainToken = KeychainStore.get(Self.keychainRefreshTokenAccount) {
            self.spapiRefreshToken = keychainToken
        } else if let legacyToken = defaults.string(forKey: Keys.legacySpapiRefreshToken),
                  !legacyToken.isEmpty {
            self.spapiRefreshToken = legacyToken
            KeychainStore.set(legacyToken, for: Self.keychainRefreshTokenAccount)
            defaults.removeObject(forKey: Keys.legacySpapiRefreshToken)
        } else {
            self.spapiRefreshToken = ""
            // 空文字のまま残っている旧キーも掃除しておく。
            defaults.removeObject(forKey: Keys.legacySpapiRefreshToken)
        }
    }

    /// SP-API連携が利用可能か(有効かつリフレッシュトークンが非空)
    var isSpApiLinkUsable: Bool {
        spapiLinkEnabled
            && !spapiRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
