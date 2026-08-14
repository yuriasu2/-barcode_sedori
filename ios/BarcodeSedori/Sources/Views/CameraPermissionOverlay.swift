import SwiftUI

/// カメラへのアクセス許可が無い(拒否/制限)場合に、カメラ映像の上に重ねて出す案内オーバーレイ。
/// QuotaPaywallOverlayと同じ様式(暗い背景・フォント・ボタンの見た目)に揃える。
struct CameraPermissionOverlay: View {
    /// 「設定を開く」タップ時の処理。
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            // カメラ映像を隠す暗い背景。
            Color.black.opacity(0.75)

            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .foregroundColor(.white)

                Text("カメラへのアクセスを許可してください")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("バーコードをスキャンするためにカメラを使用します。設定アプリから許可できます。")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)

                Button(action: onOpenSettings) {
                    HStack(spacing: 10) {
                        Image(systemName: "gear")
                        Text("設定を開く")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }
}
