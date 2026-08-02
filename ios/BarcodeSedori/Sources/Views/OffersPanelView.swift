import SwiftUI

// MARK: - オファーパネル(新品/中古の価格一覧カード)
//
// 元は SearchTabView.swift 内の private struct だったが、商品詳細画面(ProductDetailView)でも
// 検索画面と同じ見た目のパネルを使うため共有部品として切り出した。挙動・見た目は変えていない。

struct OffersPanelView: View {
    let title: String
    let color: Color
    let offers: [Offer]
    let isLoading: Bool
    /// フリーミアム: 無料&Keepa経路でオファーがPro限定ロック中か。trueなら実データを出さず
    /// ぼかしダミー+鍵を表示する(簡易価格は表示する)。
    let isLocked: Bool
    /// /api/search応答の簡易価格。オファー一覧(SP-API経路のみ)が無い/取得0件のときの
    /// 仮表示にのみ使う。オファーが取得できたら下のオファー一覧で上書きする。
    let simplePrice: Int?
    /// 簡易価格行のラベル("新品"/"中古")。
    let simpleLabel: String
    /// 送料が実データで返る経路か(SP-API経路のみtrue)。送料0を「送料無料」と表示してよいかの判定に使う。
    let isShippingKnown: Bool

    /// ロック時に表示するぼかしダミーのオファー行(コンディション, ダミー価格)。実データではない。
    private static let dummyOffers: [(String, String)] = [
        ("新品", "¥1,480"),
        ("非常に良い", "¥1,280"),
        ("良い", "¥980"),
    ]

    /// landed(送料込)昇順に並べたオファー。landedが無ければprice、いずれも無ければ末尾。
    private var sortedOffers: [Offer] {
        offers.sorted { lhs, rhs in
            (lhs.landed ?? lhs.price ?? Int.max) < (rhs.landed ?? rhs.price ?? Int.max)
        }
    }

    /// オファー取得前の仮表示に使う簡易価格行。
    @ViewBuilder
    private var simplePriceRow: some View {
        if let simplePrice {
            HStack(spacing: 4) {
                Text(simpleLabel)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("¥\(simplePrice)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// ロック時のぼかしダミーオファー + 鍵オーバーレイ(タップはパネルのonTapGestureでペイウォールへ)。
    private var lockedOffersTeaser: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<Self.dummyOffers.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(Self.dummyOffers[i].0)
                            .font(.caption2)
                            .foregroundColor(.white)
                        Text(Self.dummyOffers[i].1)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .blur(radius: 4)
            .accessibilityHidden(true)

            VStack(spacing: 2) {
                LockIconView(size: 18)
                Text("設定→Amazon連携で表示")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                // ヘッダー帯はベタ塗りをやめ、グラデーション背景の上に半透明白を重ねて
                // 本体との区切りを柔らかく見せる。
                .background(Color.white.opacity(0.16))

            VStack(alignment: .leading, spacing: 4) {
                if isLocked {
                    // 無料&Keepa: 簡易価格は見せ、オファー一覧はぼかしダミー+鍵でロック(タップでペイウォール)。
                    simplePriceRow
                    lockedOffersTeaser
                } else if !offers.isEmpty {
                    // オファー取得済み(SP-API経路。/api/searchに同梱): 送料込・最安値順・コンディション付きで
                    // 上から並べる。簡易価格はここで上書きされる。
                    // 全件を出すとカードが縦に伸びてしまうため、5件分の高さに収めて中でスクロールさせる
                    // (6件目以降もパネル内スクロールで見られる)。
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedOffers) { offer in
                                HStack(spacing: 4) {
                                    // Amazon本体の在庫は「新品(Ama)」と表示して区別する。
                                    Text(offer.panelConditionLabel)
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    // 価格は送料込み。送料があれば「¥1200(送257)」と内訳を添える。
                                    Text(offer.panelPriceLabel(shippingKnown: isShippingKnown))
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                        }
                    }
                    // 1行あたり約20pt(caption+spacing4)として5件分。オファーが5件以下なら
                    // その分だけの高さに収まり余白は出ない。
                    .frame(maxHeight: CGFloat(min(sortedOffers.count, 5)) * 20)
                } else if isLoading {
                    // オファー読込中: 簡易価格を仮表示しつつスピナー(オファー到着で上書き)。
                    // 現在は/api/searchが同期でオファーを返す(ロック時を除く)ため、実質到達しない。
                    simplePriceRow
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 8)
                        Spacer()
                    }
                } else {
                    // 取得完了だがオファー0件: 簡易価格があれば表示、無ければ空表示。
                    if simplePrice != nil {
                        simplePriceRow
                    } else {
                        Text("オファーがありません")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
            }
            .padding(8)
        }
        // ベタ塗り(opacity 0.85)から、同系色の斜めグラデーション+淡い色付きシャドウへ。
        // 白文字はそのままなのでライト/ダークどちらのモードでも成立する。
        .background(
            LinearGradient(
                colors: [color, color.darkened(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(14)
        .shadow(color: color.opacity(0.35), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - モダン配色ヘルパー

extension Color {
    /// 明度を下げた色を返す(グラデーションの終端用)。
    /// iOS16対応のためColor.mix(iOS18+)は使わず、HSB分解で明度のみ落とす。
    func darkened(_ amount: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: h, saturation: s, brightness: max(0, b - amount), opacity: a)
    }
}

/// 検索画面・商品詳細で共通の「新品=青」パネル色(#3B82F6)。
enum OffersPanelColors {
    static let newBlue = Color(red: 0.23, green: 0.51, blue: 0.96)
    /// 「中古=オレンジ」パネル色(#F97316)。
    static let usedOrange = Color(red: 0.98, green: 0.45, blue: 0.09)
}
