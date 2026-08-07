import Foundation

/// 送料設定で登録する名前付きの金額(配送料・発送費用で共用)。
///
/// 名前を後から変えられないのは、行のタップを「選択」に使っているため
/// (名前編集も同じタップに乗せると操作が衝突する)。変えたい場合は削除して追加し直す。
/// 金額だけは運送会社の値上げに追随できるよう、その場で編集できる。
struct ShippingPreset: Codable, Equatable, Identifiable {
    /// 選択状態(SettingsStoreのselectedId)が指す先。名前を識別子にすると
    /// 同名を許した瞬間に選択が壊れるため、独立したIDを持たせる。
    let id: UUID
    let name: String
    var amount: Int
}
