import Foundation

/// AdMob広告の設定を集約する。
/// 広告の中身(バナーユニットID等)はサーバー管理型に移行したため AdsConfigStore/AdSlotView 経由になる
/// (AdModels.swift / AdsConfigStore.swift)。ここにはアプリ全体のマスタースイッチのみ残す。
enum AdsConfig {
    /// 広告表示のマスタースイッチ。問題時は false で全広告(AdMob・自社バナーとも)を無効化できる。
    static let enabled = true
}
