import Foundation

/// GET /api/notice が返す告知1件(サーバー管理の障害・お知らせ告知)。
/// idは既読管理(同じ告知を二度出さない)に使うため必須。urlは省略され得る
/// (キー自体が無い、またはnull)ため、Optionalとして扱う。
struct ServerNotice: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let body: String
    let url: String?
}

/// GET /api/notice の応答全体。noticeがnilなら現在表示すべき告知が無いことを表す。
struct NoticeResponse: Codable {
    let notice: ServerNotice?
}
