import Foundation

/// スキャン(カメラ/OCR)と手入力検索で共有する「最後に検索した時刻」。
///
/// カメラ側(ScannerContainerView.emit)と手入力側(SearchTabView.startSearch)が
/// それぞれ独立した最終検索時刻を持つと、「スキャン直後に手入力」「手入力直後にスキャン」で
/// 相手のクールダウンをすり抜けられ、7秒制限が実質的に無効化されてしまう。
/// 両経路がこの1箇所を読み書きすることで、どちらで検索してもタイマーが共有・継続される。
///
/// メインスレッド専用。カメラのメタデータdelegateはmainキュー指定、OCRはmainへdispatch済み、
/// SwiftUIのstartSearchもmainのため、ロックは不要。
final class SearchCooldownStore {
    static let shared = SearchCooldownStore()

    private var lastSearchAt: Date?

    private init() {}

    /// クールダウンの残り秒数。0なら検索を実行してよい。
    /// 表示用に切り上げるため、残りがわずかでも最低1秒として返す(「あと0秒」を出さない)。
    func remainingSeconds(cooldown: TimeInterval, now: Date = Date()) -> Int {
        guard let lastSearchAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastSearchAt)
        guard elapsed < cooldown else { return 0 }
        return max(1, Int(ceil(cooldown - elapsed)))
    }

    /// 検索を実行した時刻として記録する(クールダウンの起点)。
    func markSearched(at date: Date = Date()) {
        lastSearchAt = date
    }
}
