import SwiftUI

/// 仕入れリストCSV書き出しの確認ダイアログ(画面中央のカード型)。
/// ListingConfirmDialog(出品確認)と同じ様式・構造に揃える。
struct CsvExportConfirmDialog: View {
    let count: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // 確認ダイアログなので、暗幕タップはキャンセル扱いにする(外側タップで閉じられるのが自然)。
        CenteredDialogContainer(onBackgroundTap: onCancel) {
            Image(systemName: "tablecells")
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

            Text("CSVファイルの作成")
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("選択した\(count)件をCSVファイルに書き出します。\nExcelなどの表計算ソフトで開けます。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onConfirm) {
                Text("作成する")
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
