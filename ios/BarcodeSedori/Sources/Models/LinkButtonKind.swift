import SwiftUI

/// 結果カードのリンクボタン種別。設定画面(LinkButtonSettingsView)で表示する4つを選べるようにするため、
/// ハードコードだった4ボタン(仕/a/m/価)を8種類の選択式に拡張する(2026-08 リンクボタン拡張)。
enum LinkButtonKind: String, CaseIterable, Identifiable, Codable {
    case purchase
    case amazon
    case mercari
    case kakaku
    case rakuten
    case yahooShopping
    case yahooAuction
    case rakuma

    var id: String { rawValue }

    /// ボタンに表示する短いラベル(1〜2文字)。
    var label: String {
        switch self {
        case .purchase: return "仕"
        case .amazon: return "a"
        case .mercari: return "m"
        case .kakaku: return "価"
        case .rakuten: return "楽"
        case .yahooShopping: return "Y"
        case .yahooAuction: return "オク"
        case .rakuma: return "ラ"
        }
    }

    /// 設定画面(LinkButtonSettingsView)で表示する名前。
    var displayName: String {
        switch self {
        case .purchase: return "仕入れリストへ追加"
        case .amazon: return "Amazon"
        case .mercari: return "メルカリ"
        case .kakaku: return "価格.com"
        case .rakuten: return "楽天市場"
        case .yahooShopping: return "Yahoo!ショッピング"
        case .yahooAuction: return "ヤフオク"
        case .rakuma: return "ラクマ"
        }
    }

    /// ボタンの基調色(既存の作法に合わせグラデーション+シャドウで使う)。
    var color: Color {
        switch self {
        case .purchase:
            // 新品パネルと同系のモダンブルー(#3B82F6)。既存のまま。
            return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .amazon:
            // Amazonブランドのオレンジ(#FF9900)。既存のまま。
            return Color(red: 1.0, green: 0.60, blue: 0.0)
        case .mercari:
            // メルカリの赤に寄せたモダンレッド(#EF4444)。既存のまま。
            return Color(red: 0.94, green: 0.27, blue: 0.27)
        case .kakaku:
            // 価格.comの紺に寄せたモダンインディゴ(#6366F1)。既存のまま。
            return Color(red: 0.39, green: 0.40, blue: 0.95)
        case .rakuten:
            // 楽天の赤。
            return Color(red: 0.75, green: 0.13, blue: 0.13)
        case .yahooShopping:
            // Yahoo!ショッピングの朱色。メルカリの赤と被らないよう朱寄りに調整。
            return Color(red: 0.98, green: 0.30, blue: 0.11)
        case .yahooAuction:
            // ヤフオクの青。
            return Color(red: 0.20, green: 0.44, blue: 0.85)
        case .rakuma:
            // ラクマの緑。
            return Color(red: 0.15, green: 0.68, blue: 0.55)
        }
    }
}
