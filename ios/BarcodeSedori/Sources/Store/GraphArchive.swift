import Foundation

/// 価格推移グラフ(GraphData)をASINごとの個別ファイルとして永続化する。
///
/// 【なぜ必要か】
/// 商品タブ(履歴)からの詳細表示はグラフをメモリキャッシュ
/// (PriceHistoryChartView)に頼っていたため、アプリを再起動するとグラフだけが消え、
/// 「グラフは検索時に取得してないため表示できません。」に変わっていた。履歴そのものは
/// 永続化されているのに、グラフだけ揮発するのは体験として一貫しない。
///
/// 【なぜ履歴JSONに同梱しないか】
/// ScanHistoryStoreは起動時に全件を1つの配列へデコードして常時保持する。グラフは1件
/// あたり数十KBあるため、同梱すると起動時のデコード時間とメモリが履歴の件数に比例して
/// 増え続ける。ASINごとの個別ファイルにして「開いたときだけ読む」形にすればその問題が無い。
///
/// 【置き場所】
/// Library/Application Support 配下。Cachesだと容量逼迫時にOSが予告なく削除するため、
/// 「履歴から見返せる」という機能の保証にならない(昨日は見られたのに今日は見られない、が起きる)。
/// 一方でiCloudバックアップからは除外する。取り直せるデータであり、利用者のバックアップ容量を
/// 圧迫させる理由が無いため。
enum GraphArchive {
    /// 保持する最大ファイル数。1件あたり実測30〜60KB程度のため、500件で概ね20〜30MB。
    /// 超過分は更新日時の古い順に削除する。
    static let maxFiles = 500

    /// 保存済みASINの索引。ディスクI/Oは非同期にしかできないが、呼び出し側(ProductDetailViewの
    /// body)は同期で「グラフを持っているか」を判定する必要があるため、ファイル名の集合だけを
    /// メモリに持つ。ASIN文字列のみなので500件でも数十KBにしかならない。
    private static var index: Set<String> = []
    private static var indexLoaded = false

    private static let directoryName = "graphs"

    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 保存先ディレクトリを用意する(初回のみ作成し、iCloudバックアップ対象から外す)。
    private static func ensureDirectory() -> URL? {
        guard var url = directoryURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            } catch {
                return nil
            }
        }
        return url
    }

    private static func fileURL(for asin: String) -> URL? {
        // ASINは英数字のみだが、万一の不正値でディレクトリを抜けられないよう明示的に弾く。
        guard !asin.isEmpty, !asin.contains("/"), !asin.contains(".") else { return nil }
        return ensureDirectory()?.appendingPathComponent("\(asin).json")
    }

    /// 起動時に一度だけ、保存済みASINの索引をディレクトリ一覧から作る。
    static func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let dir = ensureDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        index = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    /// このASINのグラフを保存しているか(同期・ディスクへは触らない)。
    static func hasData(for asin: String) -> Bool {
        loadIndexIfNeeded()
        return index.contains(asin)
    }

    /// 保存済みのグラフを読む。デコードに失敗したファイルは壊れているとみなして捨てる
    /// (アプリのバージョン間でGraphDataの形が変わった場合も同じ扱いにする)。
    static func data(for asin: String) -> GraphData? {
        guard hasData(for: asin), let url = fileURL(for: asin) else { return nil }
        guard let raw = try? Data(contentsOf: url) else {
            index.remove(asin)
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(GraphData.self, from: raw) else {
            try? FileManager.default.removeItem(at: url)
            index.remove(asin)
            return nil
        }
        return decoded
    }

    /// グラフを保存する。既存があれば上書きする。
    static func store(_ data: GraphData, for asin: String) {
        guard let url = fileURL(for: asin) else { return }
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        do {
            try encoded.write(to: url, options: .atomic)
            loadIndexIfNeeded()
            index.insert(asin)
            pruneIfNeeded()
        } catch {
            // 保存できなくても表示自体は続けられるため、失敗は無視する(次回また保存を試みる)。
        }
    }

    /// 上限を超えていたら更新日時の古い順に削除する。
    private static func pruneIfNeeded() {
        guard index.count > maxFiles, let dir = ensureDirectory() else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = urls.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        var removable = sorted.count - maxFiles
        for url in sorted where removable > 0 {
            try? FileManager.default.removeItem(at: url)
            index.remove(url.deletingPathExtension().lastPathComponent)
            removable -= 1
        }
    }

    /// 保存済みのグラフを全て削除する。検索履歴の全削除に合わせて呼ぶ
    /// (履歴が消えた後もグラフのファイルだけが残るのを防ぐ)。
    static func removeAll() {
        if let dir = directoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        index.removeAll()
        indexLoaded = false
    }
}
