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
        // 楽天(赤背景)とラクマ(グレー背景)はどちらも"R"だが、背景色で区別できる。
        case .rakuten: return "R"
        case .yahooShopping: return "Y!"
        // ヤフオクは文字ではなくオークションハンマーのアイコンで示す(iconSystemName)。
        // この文字列は音声読み上げ等のフォールバック用に残す。
        case .yahooAuction: return "オク"
        case .rakuma: return "R"
        }
    }

    /// ボタン面に表示するSFシンボル名。nilなら`label`の文字を表示する。
    /// ヤフオクのみ、ブランドを想起しやすいオークションハンマーのアイコンを使う。
    var iconSystemName: String? {
        switch self {
        case .yahooAuction: return "hammer.fill"
        default: return nil
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
        case .rakuten:
            // 楽天の赤(白文字の"R"を載せる)。
            return Color(red: 0.75, green: 0.13, blue: 0.13)
        case .kakaku, .yahooShopping, .yahooAuction, .rakuma:
            // 価格.com/Yahoo!ショッピング/ヤフオク/ラクマは共通のグレー地に、
            // ブランド色の文字・アイコンを載せて区別する(ユーザー指示 2026-08-02)。
            return Self.neutralGray
        }
    }

    /// グレー背景ボタンの地色(#E5E7EB相当)。ライト/ダークどちらでも
    /// 上に載る濃いブランド色の文字が読めるよう、固定の明るいグレーにする
    /// (色付きボタンと同じく、ボタン自体を独立した面として扱う)。
    private static let neutralGray = Color(red: 0.898, green: 0.906, blue: 0.922)

    /// ボタン面のラベル(文字/アイコン)の色。
    /// 濃い地色のボタンは白、グレー地のボタンはブランド色を載せる。
    var labelColor: Color {
        switch self {
        case .purchase, .amazon, .mercari, .rakuten:
            return .white
        case .kakaku, .rakuma:
            // 価格.com・ラクマは青文字(#1D4ED8)。
            return Color(red: 0.114, green: 0.306, blue: 0.847)
        case .yahooShopping:
            // Yahoo! JAPANの赤(#E60033)。
            return Color(red: 0.902, green: 0.0, blue: 0.2)
        case .yahooAuction:
            // オークションハンマーはヤフオクのオレンジ(#EA6A0A)。
            return Color(red: 0.918, green: 0.416, blue: 0.039)
        }
    }
}
