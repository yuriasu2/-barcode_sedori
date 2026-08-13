import SwiftUI

/// 一括出品の確認ダイアログ(画面中央のカード型)。
/// 以前は.confirmationDialogで画面下からのアクションシートだったが、
/// 重要な操作の確認なので視線の中心に出す。見た目はNoticePopupViewと同じ様式に揃える。
struct ListingConfirmDialog: View {
    let count: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // 確認ダイアログなので、暗幕タップはキャンセル扱いにする(外側タップで閉じられるのが自然)。
        CenteredDialogContainer(onBackgroundTap: onCancel) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [OffersPanelColors.newBlue, OffersPanelColors.newBlue.darkened(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )

            Text("出品の確認")
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("選択した\(count)件を出品します。\n各商品の仕入れフォームで保存した価格・数量で出品します。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onConfirm) {
                Text("出品する")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(OffersPanelColors.newBlue)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text("キャンセル")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }
}
