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
    }
    let series: Series
}
