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

    /// 設定タブを開いた直後にAmazon連携画面まで自動で進めるか。
    /// Pro案内(PaywallView)の「Amazon連携で7日間無料体験」から使う。設定タブへ切り替えるだけでは
    /// 利用者が連携項目を探すことになるため、目的の画面まで一気に運ぶ。
    /// SettingsView側のNavigationLink(isActive:)がこれを監視し、画面を閉じるとfalseに戻る。
    @Published var opensAmazonLink = false

    #if DEBUG
    /// 開発ビルド専用: ディープリンクから流し込まれた検索コード。
    /// シミュレータではタップ・文字入力の注入が使えない環境があり画面遷移を自動化できないため、
    /// `barcodesedori://debug-search?code=9784566034600` で検索を発火できるようにする。
    /// SearchTabViewがこれを監視して検索を実行し、消費後にnilへ戻す。
    /// `#if DEBUG` で囲っているためReleaseビルドには存在しない。
    @Published var pendingDebugSearchCode: String?
    #endif

    private init() {}
}
