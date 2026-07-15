import SwiftUI

/// アプリ全体のタブ選択状態。
/// オファーロックのタップから設定タブ(Amazon連携)へ誘導する等、
/// 画面をまたいでタブを切り替えるために使う。
/// タブ番号: 0=検索 / 1=商品 / 2=仕入れ / 3=設定。
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var selectedTab = 0

    /// 設定タブのタグ。
    static let settingsTab = 3

    private init() {}
}
