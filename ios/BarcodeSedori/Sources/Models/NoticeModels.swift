import SwiftUI

/// GET /api/notice が返す告知1件(サーバー管理の障害・お知らせ告知)。
/// idは既読管理(同じ告知を二度出さない)に使うため必須。urlは省略され得る
/// (キー自体が無い、またはnull)ため、Optionalとして扱う。levelも同様に
/// 旧サーバー応答(未実装時)ではキーが無いためOptionalとして扱う。
struct ServerNotice: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let body: String
    let url: String?
    let level: String?
}

/// GET /api/notice の応答全体。noticeがnilなら現在表示すべき告知が無いことを表す。
struct NoticeResponse: Codable {
    let notice: ServerNotice?
}

extension ServerNotice {
    /// 告知の種類。未知の値・未指定は穏やかな .info に倒す(単なるお知らせが
    /// 警告表示になってユーザーを不必要に不安にさせるのを避けるため)。
    var displayLevel: NoticeLevel {
        level == "warning" ? .warning : .info
    }
}

enum NoticeLevel {
    case info
    case warning

    /// カード上部のアイコンに使うSFSymbol名。
    var iconName: String {
        switch self {
        case .info: return "megaphone.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    /// アイコン背景・URL行の文字色に使うアクセント色。既存のOffersPanelColorsを再利用する。
    var accentColor: Color {
        switch self {
        case .info: return OffersPanelColors.newBlue
        case .warning: return OffersPanelColors.usedOrange
        }
    }
}
