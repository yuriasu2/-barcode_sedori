import Foundation

/// AdMob広告の設定を集約する。テスト用IDを既定にし、公開前に本番IDへ差し替える。
enum AdsConfig {
    /// 広告表示のマスタースイッチ。問題時は false で全広告を無効化できる。
    static let enabled = true

    /// バナー広告ユニットID。
    /// 現在はGoogle公式の「テスト用」バナーID。公開前に自分のAdMob広告ユニットIDへ差し替えること。
    /// 参考: https://developers.google.com/admob/ios/test-ads
    static let bannerAdUnitID = "ca-app-pub-3940256099942544/2934735716"
}
