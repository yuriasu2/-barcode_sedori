import CoreGraphics

@main
struct AdaptiveBannerLayoutTests {
    static func main() {
        precondition(AdaptiveBannerLayout.width(from: 320) == 320)
        precondition(AdaptiveBannerLayout.width(from: 414) == 414)
        precondition(AdaptiveBannerLayout.width(from: 0) == 1)
        precondition(AdaptiveBannerLayout.width(from: -.infinity) == 1)
        precondition(AdaptiveBannerLayout.width(from: .nan) == 1)
        print("Adaptive banner layout: available width normalization passed")
    }
}
