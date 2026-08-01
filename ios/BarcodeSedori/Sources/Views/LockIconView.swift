import SwiftUI

/// Pro限定機能を示す共通の鍵アイコン(Assets.xcassets/LockIcon)。
/// フルカラー画像のため.foregroundColorでは色が変わらない(SF Symbol "lock.fill"の代替として統一)。
struct LockIconView: View {
    var size: CGFloat = 16

    var body: some View {
        Image("LockIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
