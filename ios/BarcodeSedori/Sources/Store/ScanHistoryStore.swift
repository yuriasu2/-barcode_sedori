import Foundation
import Combine

/// 「商品」タブに表示するスキャン履歴をファイル(Documents配下のJSON)に永続化する。
final class ScanHistoryStore: ObservableObject {
    static let shared = ScanHistoryStore()

    /// 保持する最大件数。超えたぶんは古い順(配列の末尾側)に削除する。
    ///
    /// この上限の主目的は保存コストの頭打ちにある。add()は1件追加のたびにsave()を呼び、
    /// 全件をエンコードしてファイル全体を書き直すため、件数に比例して重くなる。
    /// 実機での実測値: 1件=0.4KB/3.4ms、5,000件=2,487KB/39.8ms。上限が無いとこれが
    /// 際限なく伸びる(FREEMIUM-PLAN.md 4.2g)。
    ///
    /// 1日100件スキャンする使い方で約50日ぶんに相当する。
    static let maxItems = 5000

    @Published private(set) var items: [ScanHistoryItem] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        self.fileURL = (documents ?? fileManager.temporaryDirectory).appendingPathComponent("scan_history.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    func add(_ item: ScanHistoryItem) {
        items.insert(item, at: 0)
        trimToMaxItems()
        save()
    }

    /// 上限を超えたぶんを古い順に捨てる。itemsは新しいものを先頭へinsertしているため、
    /// 末尾側が古い。
    private func trimToMaxItems() {
        guard items.count > Self.maxItems else { return }
        items.removeLast(items.count - Self.maxItems)
    }

    /// 指定したidの履歴エントリを更新する(見つからなければ何もしない)。
    /// 検索タブで/api/search応答にオファーが同梱されていた場合、
    /// 該当履歴エントリにOffersResultを追記保存するために使用する。
    func update(id: UUID, transform: (inout ScanHistoryItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items[index]
        transform(&updated)
        items[index] = updated
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// 商品タブの選択モードでの一括削除用。
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    #if DEBUG
    /// 開発ビルド専用: 履歴をダミーデータで埋める。件数が増えたときの起動時デコード・
    /// スクロール・そして最大の関心事である「1スキャンあたりの保存コスト」を実機で
    /// 測るために用意している(FREEMIUM-PLAN.md 4.2g)。
    ///
    /// add()を件数ぶん呼ぶとsave()も件数ぶん走り、書き込み量がO(n^2)になって現実的な
    /// 時間で終わらない。ここではまとめて挿入し、保存は最後の1回だけにする。
    ///
    /// 生成する値は実データと同じ「形」にすることを優先している(桁数・文字数・URLの長さ)。
    /// ファイルサイズはこれらの長さでほぼ決まるため、中身がランダムでも測定結果は変わらない。
    /// ただしASINだけはGraphArchive側のダミーファイル名と揃えてある(下記参照)。
    /// offersResultはnil(Keepa経路相当)。SP-API連携時はここに出品者一覧が入るぶん更に大きくなる。
    /// @return 生成から保存完了までにかかった秒数。
    @discardableResult
    func seedDummyItems(count: Int) -> TimeInterval {
        let startedAt = Date()
        let titleSource = "吾輩は猫である名前はまだ無いどこで生れたか頓と見当がつかぬ何でも薄暗いじめじめした所でニャーニャー泣いて"
        var generated: [ScanHistoryItem] = []
        generated.reserveCapacity(count)

        for index in 0..<count {
            let isbn = Bool.random()
            // JAN/ISBNと同じ13桁。実データと桁数を揃える。
            let code = (isbn ? "978" : "4") + String((0..<(isbn ? 10 : 12)).map { _ in "0123456789".randomElement()! })
            // ASINだけはランダムにしない。GraphArchive.seedDummyFiles()が同じ規則
            // (DUMMY+5桁)でファイルを作るため、両方を生成すれば履歴の詳細画面で
            // ダミーのグラフが実際に表示され、永続化の動作を目視で確認できる。
            // 実在のASINと同じ10文字なので、ファイルサイズの測定には影響しない。
            let asin = String(format: "DUMMY%05d", index)
            // 実際の商品タイトルに近い長さ(20〜40文字程度)で切り出す。
            let titleLength = Int.random(in: 20...40)
            let title = String(titleSource.prefix(titleLength))
            // Amazonの商品画像URLと同じくらいの長さにする。
            let imageUrl = "https://images-na.ssl-images-amazon.com/images/I/" +
                String((0..<11).map { _ in "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()! }) + "._SL500_.jpg"

            let newPrice = Int.random(in: 300...9800)
            let usedPrice = Int.random(in: 100...max(101, newPrice))
            let prices = SearchPrices(
                cart: Bool.random() ? newPrice : nil,
                new: newPrice,
                used: usedPrice,
                points: SearchPoints(cart: Int.random(in: 0...200), new: Int.random(in: 0...200), used: 0)
            )
            let result = SearchResult(
                codeType: isbn ? .isbn : .jan,
                asin: asin,
                title: title,
                isbn13: isbn ? code : nil,
                imageUrl: imageUrl,
                salesRank: Int.random(in: 1...900_000),
                releaseDate: "2024-01-01",
                modelNumber: nil,
                prices: prices,
                source: "keepa",
                offers: nil,
                profitInputs: ProfitInputs(
                    listPrice: Int.random(in: 500...12_000),
                    // 商品詳細の出品者数フォールバックを確認できるよう実データ相当の値を入れる。
                    sellerCounts: ProfitInputs.ConditionCounts(
                        new: Int.random(in: 1...40),
                        used: Int.random(in: 1...60)
                    ),
                    breakEven: nil
                ),
                quota: nil,
                keepaDebug: nil
            )
            // 過去60日ぶんに散らす(日付での絞り込みも試せるようにするため)。
            let scannedAt = Date().addingTimeInterval(-Double(index) * 60 * 60 * 24 * 60 / Double(max(count, 1)))
            generated.append(
                ScanHistoryItem(
                    scannedAt: scannedAt,
                    scannedCode: code,
                    result: result,
                    offersResult: nil,
                    profitAlertTriggered: Bool.random() ? true : nil
                )
            )
        }

        items.insert(contentsOf: generated, at: 0)
        save()
        return Date().timeIntervalSince(startedAt)
    }
    #endif

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([ScanHistoryItem].self, from: data) {
            items = decoded
            // 上限を導入する前に保存されたファイルや、開発用のダミー生成で上限を超えている
            // 場合に備えて読み込み時にも切り詰める(次の保存で実ファイルへ反映される)。
            trimToMaxItems()
        }
    }

    private func save() {
        #if DEBUG
        // 書き込みコストの実測用。add()は1件追加のたびにこのsave()を呼び、全件を
        // エンコードしてファイル全体を書き直すため、件数に比例して重くなる
        // (FREEMIUM-PLAN.md 4.2g)。シミュレータはMacのSSDで動き速すぎて実態が出ないので、
        // 判断は必ず実機のログで行うこと。
        let startedAt = Date()
        #endif
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
        #if DEBUG
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        print(String(format: "[ScanHistoryStore] save: %d件 / %.1f KB / %.1f ms",
                     items.count, Double(data.count) / 1024, elapsedMs))
        #endif
    }
}
