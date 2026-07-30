import Foundation
import CoreGraphics

/// GET /api/ads の応答全体(サーバー管理型広告配信システム)。
/// slotsの値はnullがあり得る(その枠は非表示)ため、辞書の値はOptionalにしてそのままデコードする。
struct AdsResponse: Codable, Equatable {
    let version: Int
    let slots: [String: AdSlot?]
}

/// 広告のProへの表示可否。サーバー側で枠ごと・広告ごとに制御できる
/// (「Proは自社バナーのみ」等の方針転換をアプリ更新なしで行うため)。
enum AdAudience: String, Codable {
    case all
    case free
}

/// 広告枠1件の設定。typeフィールドでadmob/customを判別する。
enum AdSlot: Codable, Equatable {
    case admob(AdMobSlot)
    case custom(CustomAdSlot)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "admob":
            self = .admob(try AdMobSlot(from: decoder))
        case "custom":
            self = .custom(try CustomAdSlot(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "未知の広告type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .admob(let slot): try slot.encode(to: encoder)
        case .custom(let slot): try slot.encode(to: encoder)
        }
    }

    /// この広告をProの端末に表示してよいか("all"なら常にtrue、"free"なら無料ユーザーのみtrue)。
    func isVisible(isPro: Bool) -> Bool {
        switch self {
        case .admob(let slot): return slot.audience == .all || !isPro
        case .custom(let slot): return slot.audience == .all || !isPro
        }
    }
}

/// AdMobバナー枠。
struct AdMobSlot: Codable, Equatable {
    /// バナーサイズ。adaptiveは画面幅からSDKが高さを算出するため下部固定枠では使用禁止
    /// (50ptを超える結果になり得る。サーバー側の運用ルール)。
    enum SizeKind: String, Codable {
        case adaptive
        case banner
        case largeBanner
        case mediumRectangle
    }

    let unitId: String
    let size: SizeKind
    let audience: AdAudience
}

/// 自社/ASPのカスタム画像バナー枠。
struct CustomAdSlot: Codable, Equatable {
    /// native=画像実寸(width/height)で中央寄せ、fill=幅いっぱいでアスペクト維持。
    enum Fit: String, Codable {
        case native
        case fill
    }

    /// 計測用の広告識別子。
    let id: String
    let imageUrl: String
    let linkUrl: String
    let width: CGFloat
    let height: CGFloat
    let fit: Fit
    let audience: AdAudience
}
