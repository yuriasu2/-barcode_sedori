import SwiftUI

/// サーバー管理型広告枠の共通ビュー。AdsConfigStoreから該当スロットを引いて描画する。
/// スロットが無い/audience不一致(free限定広告をProの端末で開いた場合)/マスタースイッチOFFの
/// いずれかに該当するときはEmptyView(高さも取らない)。
struct AdSlotView: View {
    let slotId: String
    /// 下部固定枠(50pt)など、高さを固定したい場合に指定する。未指定なら広告種別の自然な高さに従う。
    var fixedHeight: CGFloat?

    @ObservedObject private var store = AdsConfigStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    /// customスロットのタップで開くアプリ内ブラウザの対象URL(既存SearchTabViewと同じ作法)。
    @State private var browserTarget: BrowserTarget?

    var body: some View {
        Group {
            if AdsConfig.enabled, let slot = store.slots[slotId], slot.isVisible(isPro: entitlements.isPro) {
                content(for: slot)
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func content(for slot: AdSlot) -> some View {
        switch slot {
        case .admob(let admob):
            let size = BannerAdView.Size(admob.size)
            BannerAdView(unitId: admob.unitId, size: size)
                .frame(height: fixedHeight ?? size.height)
                .frame(maxWidth: .infinity)
        case .custom(let custom):
            customAdView(custom)
        }
    }

    @ViewBuilder
    private func customAdView(_ custom: CustomAdSlot) -> some View {
        if let imageUrl = URL(string: custom.imageUrl) {
            Button {
                store.sendEvent(slot: slotId, adId: custom.id, kind: "click")
                if let linkUrl = URL(string: custom.linkUrl) {
                    browserTarget = BrowserTarget(url: linkUrl)
                }
            } label: {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    default:
                        // 読み込み中/失敗時は透明のままにする(下部固定枠が崩れないよう空表示に留める)。
                        Color.clear
                    }
                }
                .frame(
                    width: custom.fit == .native ? custom.width : nil,
                    height: fixedHeight ?? custom.height
                )
                .frame(maxWidth: custom.fit == .fill ? .infinity : nil)
            }
            .buttonStyle(.plain)
            .onAppear {
                store.sendEvent(slot: slotId, adId: custom.id, kind: "impression")
            }
            .sheet(item: $browserTarget) { target in
                SafariView(url: target.url)
                    .ignoresSafeArea()
            }
        }
    }
}

private extension BannerAdView.Size {
    /// AdMobSlot.SizeKind(サーバー配信設定)からBannerAdView.Sizeへ変換する。
    init(_ kind: AdMobSlot.SizeKind) {
        switch kind {
        case .adaptive: self = .adaptive
        case .banner: self = .banner
        case .largeBanner: self = .largeBanner
        case .mediumRectangle: self = .mediumRectangle
        }
    }
}
