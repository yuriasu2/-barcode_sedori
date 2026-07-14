import SwiftUI
import UIKit
import GoogleMobileAds

/// AdMobバナー広告をSwiftUIに埋め込むラッパー(Google Mobile Ads SDK v11系 / GAD API)。
/// 無料プランのグラフ枠に表示する。読み込み失敗時はGADBannerViewが空表示になる。
/// 標準バナー(320x50)固定でサイズを予測可能にする(呼び出し側は frame(height: 50))。
struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(adSize: GADAdSizeBanner)
        banner.adUnitID = AdsConfig.bannerAdUnitID
        banner.rootViewController = Self.rootViewController()
        banner.load(GADRequest())
        return banner
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {
        if uiView.rootViewController == nil {
            uiView.rootViewController = Self.rootViewController()
        }
    }

    /// バナーの rootViewController に使う、最前面シーンのルートVCを取得する。
    private static func rootViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow?.rootViewController
    }
}
