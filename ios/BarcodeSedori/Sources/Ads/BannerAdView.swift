import SwiftUI
import UIKit
import GoogleMobileAds

/// AdMob広告をSwiftUIに埋め込むラッパー(Google Mobile Ads SDK v11系 / GAD API)。
/// 無料プランのグラフ枠に表示する。読み込み失敗時はGADBannerViewが空表示になる。
/// サイズは標準バナー(320x50)か中サイズ長方形(300x250)から選ぶ。
struct BannerAdView: UIViewRepresentable {
    enum Size {
        case banner            // 320x50
        case mediumRectangle   // 300x250

        var gadSize: GADAdSize {
            switch self {
            case .banner: return GADAdSizeBanner
            case .mediumRectangle: return GADAdSizeMediumRectangle
            }
        }

        /// SwiftUI側で確保する高さ(pt)。
        var height: CGFloat {
            switch self {
            case .banner: return 50
            case .mediumRectangle: return 250
            }
        }
    }

    var size: Size = .mediumRectangle

    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(adSize: size.gadSize)
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
