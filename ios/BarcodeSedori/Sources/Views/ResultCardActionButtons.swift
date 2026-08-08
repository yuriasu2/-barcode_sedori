import SwiftUI

// MARK: - リンクボタン列(検索結果カード / 商品詳細で共有)

/// 1列横並びのリンクボタン列。検索結果カードと商品詳細で共有する。
/// 表示する種類は`kinds`で受け取る(検索カードは設定で選んだ4つ、商品詳細は9種すべて)。
/// 「仕入れ」= 仕入れフォームを開く(Pro限定・ASINあり)。それ以外は各サービスの検索/商品ページを
/// アプリ内ブラウザで開く(いずれも無料でも使え、検索キーワードが必要)。
struct ResultCardActionButtons: View {
    let result: SearchResult
    /// 表示候補のボタン種別(順序を保つ)。この中から`showsButton`を満たすものだけ並ぶ。
    let kinds: [LinkButtonKind]
    let isPro: Bool
    let isInPurchaseList: Bool
    let onAddToPurchaseList: () -> Void
    let onLockedPurchaseTap: () -> Void
    /// 外部リンクタップ時の処理。親側でアプリ内ブラウザ(SafariView)のシートを開く。
    let onOpenLink: (URL) -> Void

    /// 表示ボタンの選択・型番検索設定を直接参照する。
    @ObservedObject private var settings = SettingsStore.shared
    /// 楽天アフィリエイトID等、サーバー管理のアフィリエイト設定を直接参照する
    /// (利用者ごとの値ではなくアプリ運営者の収益設定のためSettingsStoreではなくこちら)。
    @ObservedObject private var adsConfig = AdsConfigStore.shared

    // ISBN・ランキングの2行(テキスト列)と高さを揃え、オファーパネルとの間の余白を無くす。
    private let buttonSize: CGFloat = 34

    /// 設定で選ばれている4つのうち、実際に表示条件を満たすものだけを順序維持で並べる
    /// (条件を満たさないボタンは並びから抜ける。既存の挙動と同じ)。
    private var visibleButtons: [LinkButtonKind] {
        kinds.filter(showsButton)
    }

    private func showsButton(_ kind: LinkButtonKind) -> Bool {
        switch kind {
        case .purchase, .amazon, .keepa:
            // ASINが無いと仕入れフォーム・Amazon商品ページ・Keepa商品ページのどれも開けない。
            return result.asin != nil
        case .mercari, .kakaku, .rakuten, .yahooShopping, .yahooAuction, .rakuma:
            // 検索キーワード(型番 or タイトル)が無ければ検索リンクを組み立てられない。
            return searchKeyword != nil
        }
    }

    /// 検索キーワードの決定ルール。型番優先設定がONかつ型番が非空ならそれを使い、
    /// それ以外(OFF、または型番の無い商品=書籍など)はタイトルにフォールバックする。
    /// 型番が無いカテゴリでリンクボタンごと使えなくなるのを避けるための自動フォールバック。
    private var searchKeyword: String? {
        if settings.linkSearchByModelNumber,
           let modelNumber = result.modelNumber,
           !modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return modelNumber
        }
        return result.title
    }

    var body: some View {
        // ボタンを1列に横並びにする(ユーザー指示 2026-07-25)。表示条件を満たさない種類は抜けて並ぶ。
        // 各ボタンは幅可変(maxWidth: .infinity)で全幅を等分するため、余白0でも見切れない。
        HStack(spacing: 6) {
            ForEach(visibleButtons) { kind in
                buttonView(for: kind)
            }
        }
    }

    @ViewBuilder
    private func buttonView(for kind: LinkButtonKind) -> some View {
        switch kind {
        case .purchase:
            actionButton(
                label: kind.label,
                color: kind.color,
                labelColor: kind.labelColor,
                isDisabled: isPro && isInPurchaseList,
                // 追加済みはチェックマーク、通常は仕入れタブと同じカゴのアイコン。
                systemOverlayImage: isPro && isInPurchaseList ? "checkmark" : kind.iconSystemName,
                accessibilityLabel: kind.displayName,
                showsLockBadge: !isPro,
                action: isPro ? onAddToPurchaseList : onLockedPurchaseTap
            )
        default:
            actionButton(
                label: kind.label,
                color: kind.color,
                labelColor: kind.labelColor,
                labelFontScale: kind.labelFontScale,
                labelFontWeight: kind.labelFontWeight,
                labelFontDesign: kind.labelFontDesign,
                systemOverlayImage: kind.iconSystemName,
                accessibilityLabel: kind.displayName,
                action: { open(kind) }
            )
        }
    }

    /// 1個のボタンを描画する。追加済み(isInPurchaseList)のときはチェックマークに差し替えて無効化する。
    /// showsLockBadge:trueのときは右上に小さな鍵アイコンを重ね、Pro限定であることを示す
    /// (ボタン自体は隠さず押せる状態のまま。タップ時の遷移先はaction側で切り替える)。
    @ViewBuilder
    private func actionButton(
        label: String,
        color: Color,
        labelColor: Color = .white,
        labelFontScale: CGFloat = 1.0,
        labelFontWeight: Font.Weight = .bold,
        labelFontDesign: Font.Design = .default,
        isDisabled: Bool = false,
        systemOverlayImage: String? = nil,
        accessibilityLabel: String? = nil,
        showsLockBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 12)
                // ベタ塗りから同系色の斜めグラデーション+淡い色付きシャドウへ(パネルと同じ作法)。
                .fill(
                    isDisabled
                        ? AnyShapeStyle(Color.secondary)
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [color, color.darkened(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: isDisabled ? .clear : color.opacity(0.35), radius: 4, x: 0, y: 2)
                // 幅は全幅を等分(maxWidth: .infinity)、高さのみ固定して正方形風に見せる。
                .frame(maxWidth: .infinity)
                .frame(height: buttonSize)
                .overlay {
                    if let systemOverlayImage {
                        Image(systemName: systemOverlayImage)
                            .font(.headline)
                            .foregroundColor(labelColor)
                    } else {
                        LinkButtonGlyphLabel(
                            text: label,
                            size: fontSize(for: label) * labelFontScale,
                            weight: labelFontWeight,
                            design: labelFontDesign,
                            color: labelColor
                        )
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showsLockBadge {
                        LockIconView(size: 13)
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // アイコン表示のボタン(ヤフオク)は記号だけでは何のボタンか読み上げられないため、
        // サービス名を読み上げラベルにする。
        .accessibilityLabel(accessibilityLabel ?? label)
    }

    /// ラベルの文字種・文字数に応じてフォントサイズを調整する。
    /// 「仕」「価」「楽」「ラ」等の1文字CJKと「a」「Y」等の1文字ASCIIは同じポイント数だと
    /// ASCIIの方が小さく見えるため、ASCIIだけ大きめ(20pt)にして見かけの大きさを揃える
    /// (既存の作法)。「オク」のような2文字CJKラベルはそのまま15ptだとボタン幅に収まらず
    /// 見切れるおそれがあるため、さらに小さい11ptにしたうえでminimumScaleFactorも併用して
    /// 狭い端末幅でも確実に収まるようにする。
    private func fontSize(for label: String) -> CGFloat {
        if label.allSatisfy({ $0.isASCII }) { return 20 }
        if label.count >= 2 { return 11 }
        return 15
    }

    /// 検索キーワードをURLクエリ用にエンコードする(全文)。
    private func encodedKeyword() -> String? {
        guard let keyword = searchKeyword else { return nil }
        return keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    /// 検索キーワードをShift_JISのパーセントエンコードに変換する(価格.com専用)。
    /// 価格.comの検索URLはShift_JIS前提のためUTF-8エンコードだと文字化け/404になる
    /// (実リクエストで確認済み)。Shift_JISに無い文字は損失変換で近似する。
    private func shiftJISEncodedKeyword() -> String? {
        guard let keyword = searchKeyword,
              let data = keyword.data(using: .shiftJIS, allowLossyConversion: true) else { return nil }
        return Self.strictPercentEncoded(bytes: data)
    }

    /// RFC 3986のunreserved文字(英数字と-._~)のみ素通しし、他は%XXにする厳密なパーセントエンコード。
    /// バイト列を直接エンコードするため、Shift_JIS(価格.com)にも楽天アフィリエイトURLの
    /// 丸ごとエンコード(`:`や`/`も含める)にも共通で使える。
    private static func strictPercentEncoded<S: Sequence>(bytes: S) -> String where S.Element == UInt8 {
        bytes.map { byte -> String in
            let isUnreserved =
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x2E
                || byte == 0x5F || byte == 0x7E
            return isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    /// 文字列全体(URL全体など)をRFC3986 unreserved文字以外パーセントエンコードする。
    /// `.urlHostAllowed`等のCharacterSetベースのエンコードは`:`や`/`を素通ししてしまい、
    /// 楽天アフィリエイトのpc/mパラメータ(URL全体をエンコードして渡す仕様)には使えないため、
    /// UTF-8バイト列を直接エンコードするこちらを使う。
    private static func strictPercentEncoded(string: String) -> String {
        strictPercentEncoded(bytes: Array(string.utf8))
    }

    private func open(_ kind: LinkButtonKind) {
        switch kind {
        case .purchase:
            // buttonView側で個別処理するためここには来ない。
            break
        case .amazon:
            openAmazon()
        case .mercari:
            openMercari()
        case .kakaku:
            openKakaku()
        case .rakuten:
            openRakuten()
        case .yahooShopping:
            openYahooShopping()
        case .yahooAuction:
            openYahooAuction()
        case .rakuma:
            openRakuma()
        case .keepa:
            openKeepa()
        }
    }

    /// Amazonの出品者一覧(すべての出品を表示)を開く。商品ページではなく相場が一覧できる
    /// aod=1 のページへ直接飛ばす(せどりでは出品者と価格の一覧を見たいため)。
    private func openAmazon() {
        guard let asin = result.asin,
              let url = URL(string: "https://www.amazon.co.jp/dp/\(asin)/ref=olp-opf-redir?aod=1") else { return }
        onOpenLink(url)
    }

    private func openMercari() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://jp.mercari.com/search?keyword=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openKakaku() {
        guard let encoded = shiftJISEncodedKeyword(),
              let url = URL(string: "https://kakaku.com/search_results/\(encoded)/") else { return }
        onOpenLink(url)
    }

    /// 楽天市場検索を開く。サーバー配信のアフィリエイトID設定済みなら楽天アフィリエイトリンクで
    /// ラップする(IDはアプリ運営者の収益設定のためAdsConfigStore=/api/adsから取得する。
    /// 利用者が設定画面で入力する項目ではない)。
    private func openRakuten() {
        guard let encoded = encodedKeyword() else { return }
        let searchURLString = "https://search.rakuten.co.jp/search/mall/\(encoded)/"

        let affiliateId = (adsConfig.affiliates["rakuten"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURLString: String
        if affiliateId.isEmpty {
            finalURLString = searchURLString
        } else {
            // 楽天アフィリエイトの仕様: pc=PC用遷移先URL、m=モバイル用遷移先URLをそれぞれ
            // URLエンコードして渡す(PC/モバイル別々のURLを指定できる仕組みだが、ここでは
            // 同じ楽天検索URLを両方に渡す)。値はURL全体(`:`や`/`含む)をエンコードする必要が
            // あるため、.urlHostAllowed等ではなく上のstrictPercentEncoded(string:)を使う。
            let encodedTarget = Self.strictPercentEncoded(string: searchURLString)
            finalURLString = "https://hb.afl.rakuten.co.jp/hgc/\(affiliateId)/?pc=\(encodedTarget)&m=\(encodedTarget)"
        }
        guard let url = URL(string: finalURLString) else { return }
        onOpenLink(url)
    }

    /// Yahoo!ショッピング検索を開く。アフィリエイトは利用者側にIDが無いため未対応
    /// (将来対応する場合はここに楽天と同様のラップ処理を追加する)。
    private func openYahooShopping() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://shopping.yahoo.co.jp/search?p=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openYahooAuction() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://auctions.yahoo.co.jp/search/search?p=\(encoded)") else { return }
        onOpenLink(url)
    }

    private func openRakuma() {
        guard let encoded = encodedKeyword(),
              let url = URL(string: "https://fril.jp/s?query=\(encoded)") else { return }
        onOpenLink(url)
    }

    /// Keepaの該当商品ページを開く。domain=5はamazon.co.jpのロケールID
    /// (server/src/keepa/client.js の JP_DOMAIN_ID と同じ値。Keepa公式のURL規約
    /// `https://keepa.com/#!product/{domain}-{ASIN}` に準拠)。
    private func openKeepa() {
        guard let asin = result.asin,
              let url = URL(string: "https://keepa.com/#!product/5-\(asin)") else { return }
        onOpenLink(url)
    }
}
