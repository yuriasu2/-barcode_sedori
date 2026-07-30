import SwiftUI
import UIKit
import GoogleMobileAds

/// AdMob広告をSwiftUIに埋め込むラッパー(Google Mobile Ads SDK v11系 / GAD API)。
/// サーバー管理型広告(AdSlotView)から広告ユニットIDを渡して使う。
/// サイズは固定サイズ(banner/largeBanner/mediumRectangle)か、画面幅から高さを算出するadaptiveから選ぶ。
struct BannerAdView: UIViewRepresentable {
    enum Size {
        case banner            // 320x50
        case largeBanner       // 320x100
        case mediumRectangle   // 300x250
        /// 画面幅からSDKが高さを算出する可変サイズ。下部固定枠(50pt)では使用しない
        /// (50ptを超える結果になり得るため。サーバー側の運用ルールでも下部枠には配信しない)。
        case adaptive

        var gadSize: GADAdSize {
            switch self {
            case .banner: return GADAdSizeBanner
            case .largeBanner: return GADAdSizeLargeBanner
            case .mediumRectangle: return GADAdSizeMediumRectangle
            case .adaptive:
                return GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(UIScreen.main.bounds.width)
            }
        }

        /// SwiftUI側で確保する高さ(pt)。adaptiveも読み込み前に同期算出できるためレイアウトが跳ねない。
        var height: CGFloat {
            switch self {
            case .banner: return 50
            case .largeBanner: return 100
            case .mediumRectangle: return 250
            case .adaptive: return gadSize.size.height
            }
        }
    }

    /// 表示する広告のユニットID(サーバー配信設定から渡される)。
    let unitId: String
    var size: Size = .largeBanner

    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(adSize: size.gadSize)
        banner.adUnitID = unitId
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
