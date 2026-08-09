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

    /// Amazon連携画面をシートで開くか。RootTabViewが監視して提示する。
    ///
    /// 「設定タブへ切り替えてNavigationLink(isActive:)で押し込む」方式は取らない。
    /// TabViewは表示していないタブの中身を描画しておらず、切替直後にisActiveを立てても
    /// リンクがまだ存在せず遷移を取りこぼすため(設定タブに着くだけで止まる)。
    /// シートならタブの描画状態に依存せず、どの画面からでも確実に開ける。
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
