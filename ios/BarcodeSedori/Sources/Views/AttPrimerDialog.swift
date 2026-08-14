import SwiftUI

/// ATT(トラッキング許可)要求の事前説明ダイアログ(画面中央のカード型)。
/// ListingConfirmDialogと同じ様式(CenteredDialogContainer)に揃える。
struct AttPrimerDialog: View {
    let onProceed: () -> Void
    let onPostpone: () -> Void

    var body: some View {
        // 暗幕タップは「あとで」扱いにする(誤タップでシステムダイアログへ進んでしまわないように)。
        CenteredDialogContainer(onBackgroundTap: onPostpone) {
            Image(systemName: "hand.raised.fill")
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

            Text("広告について")
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("許可すると、あなたに関係のある広告が表示されやすくなります。無関係な広告が減り、アプリを無料で使い続けられます。個人を特定する情報の取得はありません。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 重要: このボタンのラベルは必ず「次へ」にすること。「許可する」にすると、
            // 実際にはこの後にAppleのシステムダイアログ(ATT)が別途出てそこで初めて可否を選ぶため、
            // 「許可する」ボタンを押した時点で許可されたかのようにユーザーを誤認させるダークパターンになり、
            // App Store審査でリジェクトされ得る。
            Button(action: onProceed) {
                Text("次へ")
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

            Button(action: onPostpone) {
                Text("あとで")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }
}
