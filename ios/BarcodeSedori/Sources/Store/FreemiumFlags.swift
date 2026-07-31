import Foundation

/// フリーミアム機能の段階的リリース用フラグ。
enum FreemiumFlags {
    /// リワード広告(Phase C: 「動画を見て+5回」「動画を見てグラフを見る」)が実装済みか。
    /// false の間はリワード広告関連のUI(ボタン等)を一切出さない
    /// (ボタンだけ先に出して押しても何も起きない状態を避けるため)。
    /// なお、これがtrueでも AdsConfig.enabled(全広告のマスタースイッチ)がfalseなら出さない
    /// (判定は RewardedAdManager.isEnabled に集約している)。
    static let rewardedAdsEnabled = true
}
