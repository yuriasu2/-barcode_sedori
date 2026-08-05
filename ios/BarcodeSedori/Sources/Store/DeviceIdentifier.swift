import Foundation
import UIKit

/// サーバーの無料枠クォータ(deviceQuota)が使う端末識別子。
///
/// 以前は `UIDevice.current.identifierForVendor` を各所で直接参照していたが、
/// 次の2つの理由でKeychain永続のUUIDへ移行した。
/// 1. IDFVはnilを返し得る。サーバー側がdeviceId必須(無ければ400)になったため、
///    nilのままだとその端末は検索できなくなる。
/// 2. IDFVは同一ベンダーのアプリを全て削除するとリセットされる。Keychainはアプリ削除後も
///    残るため、無料枠の意図しないリセットが起きにくい。
///
/// 値はランダムUUIDでPIIではない。
///
/// **重要**: APIClient(`X-Device-Id`)とRewardedAdManager(AdMob SSVの
/// `customRewardString`)は必ずこの同じ値を使うこと。異なる値を使うと広告視聴の付与先が
/// 検索で消費する枠と別デバイス扱いになり、視聴しても枠が増えない。
enum DeviceIdentifier {
    /// Keychainのアカウント名。KeychainStoreのservice(バンドルID)配下で一意であればよい。
    private static let keychainAccount = "device.identifier"

    /// 端末識別子。初回はIDFV(取れなければ新規UUID)をKeychainへ保存し、以後はそれを返す。
    ///
    /// `static let` にしているのはプロセス内で一度だけ解決するため。Keychainへの書き込みに
    /// 失敗した場合でもプロセスが生きている間は同じ値を返し続ける(呼び出しのたびに別の
    /// UUIDを生成して送ってしまうと、無料枠を毎回リセットできることになる)。
    static let current: String = resolve()

    private static func resolve() -> String {
        if let stored = KeychainStore.get(keychainAccount), !stored.isEmpty {
            return stored
        }
        // 初回のみ。既存ユーザーの枠を引き継げるようIDFVを優先し、取れない端末だけ新規UUIDにする。
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        _ = KeychainStore.set(generated, for: keychainAccount)
        return generated
    }
}
