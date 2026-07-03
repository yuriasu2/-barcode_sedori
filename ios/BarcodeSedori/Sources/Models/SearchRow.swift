import Foundation

/// SearchTabViewの結果リストの1行を表す状態。
/// スキャン直後は`.loading`で挿入し、レスポンス到着後に`.loaded`/`.failed`へ置換する。
enum SearchRowState: Equatable {
    case loading
    case loaded(SearchResult)
    case failed(String)
}

struct SearchRow: Identifiable, Equatable {
    let id: UUID
    let scannedCode: String
    var state: SearchRowState

    init(id: UUID = UUID(), scannedCode: String, state: SearchRowState = .loading) {
        self.id = id
        self.scannedCode = scannedCode
        self.state = state
    }
}
