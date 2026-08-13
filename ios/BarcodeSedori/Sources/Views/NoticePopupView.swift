import SwiftUI

/// 障害告知・お知らせを表示するカード型ポップアップ。
/// SwiftUI標準の.alert()はデザインの自由度が低く「素っ気ない」印象になるため、
/// このアプリの他カード(OffersPanelView等)と同じグラデーション・角丸・影の
/// トーンに合わせたカスタムViewとして用意している。
struct NoticePopupView: View {
    let notice: ServerNotice
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    private var level: NoticeLevel { notice.displayLevel }

    var body: some View {
        ZStack {
            // 暗幕。タップでは閉じない(障害告知という重要な情報を、誤タップで
            // 読まずに消してしまう事故を防ぐため)。閉じる操作は下の「閉じる」ボタンのみに限定する。
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: level.iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [level.accentColor, level.accentColor.darkened(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )

                Text(notice.title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                // 長文でカードが画面外へはみ出さないよう、本文はスクロール枠に収める。
                ScrollView {
                    Text(notice.body)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: 240)

                if let urlString = notice.url, let url = URL(string: urlString) {
                    // URL行タップ時は閉じない。外部ブラウザから戻ってきたときに、
                    // ユーザーが告知内容をもう一度読み返せるようにするため。
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text(urlString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.footnote)
                        .foregroundColor(level.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onClose) {
                    Text("閉じる")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(level.accentColor)
                        )
                }
                .buttonStyle(.plain)
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
