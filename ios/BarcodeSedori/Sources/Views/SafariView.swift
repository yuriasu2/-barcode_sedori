import SwiftUI
import SafariServices

/// アプリ内ブラウザ(SFSafariViewController)のSwiftUIラッパー。
/// 検索結果カードの外部リンク(Amazon/メルカリ/価格.com)をアプリから離れずに開くために使う。
/// WKWebViewと違いページ内容へ一切干渉できないシステム標準UIのため、
/// 各サイトの規約リスクは外部Safariで開くのと同等に扱える。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// .sheet(item:)で使うためのIdentifiableなURLラッパー。
struct BrowserTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
