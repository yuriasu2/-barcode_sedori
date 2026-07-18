import Foundation
import Security

/// Keychainへの読み書きを行う薄いラッパー。
///
/// SP-APIのリフレッシュトークンは、販売パートナー本人のセラーアカウントへのアクセス権を持つ
/// 機微情報であり、Amazonのデータ保護ポリシー(DPP)で保存時暗号化が求められる。
/// UserDefaults(平文plist・バックアップにも平文で載る)ではこの要件を満たせないため、
/// ハードウェア暗号で保護されるKeychainに保存する。
///
/// 属性:
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
///   端末ロック解除中のみアクセス可能(APIは前面利用時のみ叩くため十分)。
///   ThisDeviceOnly により、バックアップ復元や別端末への移行で持ち出されない。
/// - Synchronizable は設定しない(iCloud Keychainで他端末へ同期させない)。
enum KeychainStore {
    /// Keychain項目のサービス名(バンドルIDに紐づける)。
    private static let service: String = Bundle.main.bundleIdentifier ?? "com.example.barcodesedori"

    /// 値を保存する。空文字を渡した場合は削除として扱う。
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { return delete(account) }
        guard let data = value.data(using: .utf8) else { return false }

        // 既存を削除してから追加する。
        // SecItemUpdate→失敗時にSecItemAddという順序だと、Updateが想定外のエラー
        // (署名不備によるerrSecMissingEntitlement等)を返したときに追加まで到達せず
        // 保存が黙って失敗するため、単純で確実な削除→追加にする。
        delete(account)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// 値を取得する。存在しない場合はnil。
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// 値を削除する。
    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
