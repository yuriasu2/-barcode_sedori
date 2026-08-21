import SwiftUI

/// 無料枠ユニット(Phase B)を使い切った際に、カメラ映像の上に重ねて出す枠切れオーバーレイ。
/// SearchTabViewが肥大化しないよう切り出したView。
struct QuotaPaywallOverlay: View {
    /// 「動画を見てスキャンを続ける」を出すか(FreemiumFlags.rewardedAdsEnabled && quota.adAvailable && !capReached)。
    let showsAdOption: Bool
    /// 「Amazon連携でスキャン無制限」を出すか(!settings.isSpApiLinkUsable)。
    let showsSpApiOption: Bool
    /// リワード広告の表示中/枠の反映待ち中か。二重タップを防ぎ、進行状況を示すために使う。
    var isProcessingAd: Bool = false
    /// 「①Proにアップグレード」タップ時の処理。
    let onUpgradeTap: () -> Void
    /// 「②動画を見てスキャンを続ける」タップ時の処理。
    let onWatchAdTap: () -> Void
    /// 「③Amazon連携でスキャン無制限」タップ時の処理。
    let onSpApiLinkTap: () -> Void

    var body: some View {
        ZStack {
            // カメラ映像を隠す暗い背景。
            Color.black.opacity(0.75)

            VStack(spacing: 14) {
                Text("本日の無料スキャンを使い切りました")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    // ①常に最上段・強調表示。
                    optionButton(
                        title: "Proにアップグレード",
                        subtitle: "スキャン・OCR・グラフすべて無制限",
                        systemImage: "star.fill",
                        isEmphasized: true,
                        action: onUpgradeTap
                    )

                    if showsAdOption {
                        optionButton(
                            // 反映待ちの間は何が起きているか分からず再タップされやすいため、文言で状態を示す。
                            // 付与される回数はサーバー側のKV(quota-limits)で変更できるため、
                            // 文言に数値を入れない(入れると変更のたびにアプリ更新が必要になる)。
                            title: isProcessingAd ? "反映中…" : "動画を見てスキャンを続ける",
                            subtitle: isProcessingAd ? "枠の反映を待っています" : nil,
                            systemImage: "play.rectangle.fill",
                            isEmphasized: false,
                            action: onWatchAdTap
                        )
                        .disabled(isProcessingAd)
                    }

                    if showsSpApiOption {
                        optionButton(
                            title: "Amazon連携でスキャン無制限",
                            // 連携すると検索がお客様自身のAmazon枠で行われ、共有の価格取得枠を
                            // 使わなくなる。回数制限も待ち時間もその制約から来ているので、
                            // 特典ではなく仕組みとして説明する(審査Guideline 5.6対応)。
                            subtitle: "検索がご自身のAmazon枠になり、待ち時間も1秒になります。",
                            systemImage: "link",
                            isEmphasized: false,
                            action: onSpApiLinkTap
                        )
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func optionButton(
        title: String,
        subtitle: String?,
        systemImage: String,
        isEmphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(isEmphasized ? .white.opacity(0.85) : .secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .foregroundColor(isEmphasized ? .white : .primary)
            .background(isEmphasized ? Color.accentColor : Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
