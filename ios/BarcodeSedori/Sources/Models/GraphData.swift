import Foundation

/// GET /api/graph-data の応答(Pro限定)。価格推移をサーバーから履歴データとして受け取り、
/// 端末側でSwift Chartsに描画する(旧KeepaグラフのようなKeepa側画像レンダリングは使わない)。
/// 各要素は [unix秒, 値]。値-1は「データなし」を表し、線を切る箇所として扱う。
struct GraphData: Codable, Equatable {
    struct Series: Codable, Equatable {
        let amazon: [[Double]]
        let new: [[Double]]
        let used: [[Double]]
        let rank: [[Double]]
        /// 新品/中古/コレクター出品者数の推移。サーバーは手動デプロイのため、
        /// 追加直後は旧レスポンス(このキーを含まない)がまだ返る可能性がある。
        /// AdsResponse.affiliatesと同じくdecodeIfPresent ?? []でデコード失敗を防ぐ。
        let newCount: [[Double]]
        let usedCount: [[Double]]
        let collectibleCount: [[Double]]

        private enum CodingKeys: String, CodingKey {
            case amazon, new, used, rank, newCount, usedCount, collectibleCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            amazon = try container.decode([[Double]].self, forKey: .amazon)
            new = try container.decode([[Double]].self, forKey: .new)
            used = try container.decode([[Double]].self, forKey: .used)
            rank = try container.decode([[Double]].self, forKey: .rank)
            newCount = try container.decodeIfPresent([[Double]].self, forKey: .newCount) ?? []
            usedCount = try container.decodeIfPresent([[Double]].self, forKey: .usedCount) ?? []
            collectibleCount = try container.decodeIfPresent([[Double]].self, forKey: .collectibleCount) ?? []
        }
    }
    let series: Series
    /// 無料枠ユニットの残量。非Proに付く(キャッシュヒット時は消費なし)。Pro・SP-API連携済みには付かない。
    let quota: QuotaInfo?
}
