import SwiftUI

/// 画面中央にカードを出すダイアログの共通外枠(暗幕+カード)。
/// NoticePopupView(告知ポップアップ)とListingConfirmDialog(出品確認)で見た目を
/// 揃えるために切り出した。中身は呼び出し側が渡す。
struct CenteredDialogContainer<Content: View>: View {
    /// 暗幕をタップしたときの動作。nilなら暗幕タップでは閉じない
    /// (誤タップで消えては困る通知向け)。閉じてよい確認ダイアログではクロージャを渡す。
    var onBackgroundTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    onBackgroundTap?()
                }

            VStack(spacing: 16) {
                content()
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
            )
            .padding(.horizontal, 32)
        }
    }
}
