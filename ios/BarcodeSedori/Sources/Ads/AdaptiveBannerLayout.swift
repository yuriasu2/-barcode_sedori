import CoreGraphics

/// アダプティブバナーへ渡す広告枠幅を正規化する。
/// SwiftUIのレイアウト確定前に得られる0/非有限値をSDKへ渡さないための境界処理。
enum AdaptiveBannerLayout {
    static func width(from availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite else { return 1 }
        return max(1, availableWidth)
    }
}
