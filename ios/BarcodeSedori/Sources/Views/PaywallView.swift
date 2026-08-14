import SwiftUI
import StoreKit

/// 課金画面に必須のリンク先。
///
/// Appleのガイドライン3.1.2により、自動更新サブスクリプションを扱うアプリは
/// 「利用規約(EULA)」と「プライバシーポリシー」への機能するリンクを**アプリ内に**
/// 持たなければ審査を通過できない(App Store Connectのメタデータ側だけでは不足)。
private enum LegalConfig {
    /// Apple提供の標準EULA。自前の規約を用意しない場合はこれを提示すればよい
    /// (App Store Connectで独自EULAを設定した場合はそのURLへ差し替えること)。
    static let termsOfUseURL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

    /// 自社のプライバシーポリシー。**リリース前にsellira.jp側でページを公開すること**
    /// (未公開のままだとリンク切れで審査に落ちる。企画書の「公開前 必須TODO」参照)。
    static let privacyPolicyURL = "https://sellira.jp/privacy/"
}

/// 課金訴求(ペイウォール)画面。各ゲート(OCR・グラフ・オファー・日次上限)からsheetで提示する。
/// 価格・トライアルは可能なら StoreKit の Product から取得し、未ロード時は既定文言でフォールバックする。
struct PaywallView: View {
    @ObservedObject private var entitlements = EntitlementStore.shared
    @Environment(\.dismiss) private var dismiss
    /// 利用規約・プライバシーポリシーをアプリ内ブラウザで開くための対象。
    @State private var browserTarget: BrowserTarget?

    /// 価格表示。Productがあればローカライズ済み価格、無ければ既定(¥1,980/月)。
    private var priceText: String {
        if let product = entitlements.product {
            return "\(product.displayPrice) / 月"
        }
        return "¥1,980 / 月"
    }

    /// トライアル表示。Productの導入オファー(無料期間)があればそれ、無ければ既定(3日間無料)。
    private var trialText: String {
        if let offer = entitlements.product?.subscription?.introductoryOffer,
           offer.paymentMode == .freeTrial {
            let unit: String
            switch offer.period.unit {
            case .day: unit = "日間"
            case .week: unit = "週間"
            case .month: unit = "か月"
            case .year: unit = "年間"
            @unknown default: unit = "日間"
            }
            return "最初の\(offer.period.value)\(unit)は無料"
        }
        return "最初の3日間は無料"
    }

    // クールダウン(5秒/1秒)はプランではなくSP-API連携の有無で決まるため、訴求には含めない。
    private let proFeatures: [String] = [
        "スキャン・検索が無制限(無料は1日5回まで)",
        "OCR(ISBN/JAN文字認識)スキャンが無制限",
        "Keepa価格推移グラフが無制限",
        "オファー一覧(送料込・最安順)をフル表示",
        "広告なし",
        "仕入れリスト・利益アラートが使い放題",
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("セラーレンズ Pro")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("すべての機能を制限なく、広告なしで。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(proFeatures, id: \.self) { feature in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(feature)
                                    .font(.subheadline)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    VStack(spacing: 4) {
                        Text(priceText)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(trialText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        Task {
                            let ok = await entitlements.purchase()
                            if ok { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if entitlements.purchaseInProgress {
                                ProgressView().tint(.white)
                            } else {
                                Text("Proを始める")
                                    .fontWeight(.bold)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(entitlements.purchaseInProgress || entitlements.product == nil)

                    // 購入前に試したい人の受け皿。Amazon連携すれば7日間Pro機能を試せるため、
                    // 課金ボタンの直下から設定タブのAmazon連携画面まで一気に運ぶ。
                    Button {
                        // この画面自体がシートなので、閉じ切ってから次のシートを出す。
                        // 解除アニメーション中に別のシートを提示するとiOSが黙って無視する。
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            AppNavigation.shared.opensAmazonLink = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gift.fill")
                            Text("Amazon連携で7日間無料体験")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(12)
                    }

                    Button {
                        Task {
                            let ok = await entitlements.restore()
                            if ok { dismiss() }
                        }
                    } label: {
                        Text("購入を復元")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }

                    Text("サブスクリプションは期間終了の24時間前までに解約しない限り自動更新されます。解約は設定 > Apple ID > サブスクリプションから行えます。")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // ガイドライン3.1.2により、この2つのリンクは課金画面に必須。
                    // 外部ブラウザではなくアプリ内ブラウザで開き、読んだあとそのまま購入へ戻れるようにする。
                    HStack(spacing: 16) {
                        Button("利用規約") {
                            openLegalPage(LegalConfig.termsOfUseURL)
                        }
                        Button("プライバシーポリシー") {
                            openLegalPage(LegalConfig.privacyPolicyURL)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption2)

                    if entitlements.product == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("※ 商品情報を読み込めませんでした。ネットワーク接続、またはStoreKit設定をご確認ください。")
                                .font(.caption2)
                                .foregroundColor(.orange)

                            if entitlements.isLoadingProduct {
                                HStack(spacing: 6) {
                                    ProgressView()
                                    Text("読み込み中…")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button("再読み込み") {
                                    Task { await entitlements.loadProduct() }
                                }
                                .font(.caption2)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $browserTarget) { target in
            SafariView(url: target.url)
        }
        .task {
            // 画面表示のたびに、商品未取得なら再取得を試みる(起動時取得が失敗したままでも購入不能にしない)
            if entitlements.product == nil && !entitlements.isLoadingProduct {
                await entitlements.loadProduct()
            }
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { entitlements.lastActionErrorMessage != nil },
                set: { newValue in
                    if !newValue { entitlements.lastActionErrorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { entitlements.lastActionErrorMessage = nil }
        } message: {
            Text(entitlements.lastActionErrorMessage ?? "")
        }
    }

    /// 利用規約・プライバシーポリシーをアプリ内ブラウザで開く。
    private func openLegalPage(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        browserTarget = BrowserTarget(url: url)
    }
}
