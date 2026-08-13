import SwiftUI
import UIKit

/// UIActivityViewController(共有シート)をSwiftUIから使うためのラッパー。
/// CSVファイル等を「ファイルに保存」「AirDrop」「メール送信」等に渡す用途。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPadではpopover形式で表示されるため、anchorViewが無いとクラッシュする。
        // .sheet経由での提示では通常不要だが、念のためルートViewを起点に設定しておく。
        if let popover = controller.popoverPresentationController {
            let rootView = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.rootViewController?.view
            popover.sourceView = rootView
            if let rootView {
                popover.sourceRect = CGRect(x: rootView.bounds.midX, y: rootView.bounds.midY, width: 0, height: 0)
            }
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
