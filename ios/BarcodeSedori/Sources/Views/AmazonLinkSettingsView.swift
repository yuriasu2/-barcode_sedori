import SwiftUI
import UIKit

/// 「Amazon連携」画面。設定タブの旧「SP-API連携」セクションを1画面に集約したもの。
/// SettingsViewからNavigationLinkで遷移する。
///
/// viewModelはSettingsViewが保持するインスタンスをそのまま受け取る(新規に作らない)。
/// 接続テスト結果(connectionTestAlert)はSettingsViewの「Keepa連携」の接続テストとも共有する
/// @Published状態のため、別インスタンスを作るとテスト結果がここに届かなくなる。
struct AmazonLinkSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Text("Amazon大口契約のセラーアカウントでログインしてアクセス許可をすると、連携完了になります。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        openOAuthLogin()
                    } label: {
                        // Amazon公式のLogin with Amazonボタン素材。ブランド規約があるため
                        // 自前で似せたボタンを描かず、配布された画像をそのまま使う。
                        // 現在の素材は195x46pxの等倍(1x)版しか無いため、Retinaでは拡大されて
                        // 少し甘く見える。気になる場合は同素材の高解像度版を@2x/@3xとして追加する。
                        Image("LoginWithAmazon")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 44)
                    }
                    // Formの行にButtonを置くと行全体がタップに反応してしまうため、
                    // 画像部分だけを反応させる(送料設定のゴミ箱ボタンと同じ理由)。
                    .buttonStyle(.borderless)

                    // 連携状態はボタンの右隣に出す。押す対象と現在の状態を横に並べることで、
                    // 「押す前/押した後」がひと目で分かるようにする。
                    Text(settings.isSpApiLinkUsable ? "連携済み" : "未連携")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(settings.isSpApiLinkUsable ? .blue : .secondary)

                    Spacer(minLength: 0)
                }

                // 連携中のときだけ出す。未連携で押せても消すものが無く、意味が無いため。
                if settings.isSpApiLinkUsable {
                    Button(role: .destructive) {
                        // 端末に保持しているリフレッシュトークン(Keychain)を空にする。
                        // これでisSpApiLinkUsableがfalseになり未連携状態へ戻る。
                        // 出品者IDは消さない: 再連携時に選択アカウントが変われば認可コールバックが
                        // 上書きするため、こちらで先に消すと旧認可のまま再連携した利用者が
                        // 出品者ID未取得になり出品系APIを使えなくなる。
                        viewModel.spapiRefreshToken = ""
                    } label: {
                        Text("連携を解除")
                    }
                }

                Button {
                    Task { await viewModel.testSpApiConnection() }
                } label: {
                    HStack {
                        Text("接続テスト")
                        Spacer()
                        if viewModel.isSpApiTesting {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isSpApiTesting)
            }

            Section("連携特典") {
                benefitBlock(
                    icon: "bolt.fill",
                    iconColor: .orange,
                    title: "高速バーコードスキャンが無制限",
                    detail: "連携するだけで、1日のスキャン制限がなくなり、高速でスキャン結果が表示され、価格の一覧も見れます。"
                ) {
                    EmptyView()
                }

                benefitBlock(
                    icon: "gift.fill",
                    iconColor: .pink,
                    title: "7日間、Proの機能をお試し",
                    detail: "連携した日から7日間、下記の機能を無料でお使いいただけます。"
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.trialBenefits, id: \.self) { benefit in
                            // alignment: .topでアイコンと複数行のテキストの1行目を揃える。
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.footnote)
                                    .foregroundColor(.green)
                                Text(benefit)
                                    .font(.subheadline)
                                    // HStackは中身を必要最小限の幅に詰めようとするため、
                                    // 何も指定しないとTextが折り返さず右端で切れてしまう。
                                    // 明示的に幅いっぱいまで伸ばして折り返させる。
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .navigationTitle("Amazon連携")
        // SettingsView側の「Keepa連携」接続テストとconnectionTestAlertを共有しているが、
        // 表示先はその時点で画面に出ているビュー側のみになるため、ここにも同じ.alert(item:)を
        // 付けないとこの画面からの接続テスト結果が出ない(過去に別画面へ付け忘れて
        // アラートが出なくなった不具合と同じ種類のため、SettingsViewと揃えて必ず付ける)。
        .alert(item: $viewModel.connectionTestAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// お試し期間中に使えるようになるPro機能。文言はこの1箇所だけを直せばよいようにまとめる。
    private static let trialBenefits = [
        "出品可否の表示",
        "アプリからの出品",
        "OCR(値札の文字読み取り)",
        "利益アラート",
    ]

    /// 連携特典の1ブロック。アイコン+見出し+説明の並びを2つの特典で共通化する。
    /// 追加の内容(お試し機能の一覧など)は`extra`に渡す。
    private func benefitBlock<Extra: View>(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                Text(title)
                    .fontWeight(.semibold)
                    // titleも同じ理由(HStackが中身に合わせて縮む)で明示的に幅を伸ばす。
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            extra()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ログインボタンから、サーバーの /oauth/login をSafari(外部ブラウザ)で開く。
    /// SettingsView.openOAuthLogin()から移設(SP-API連携セクションがこの画面に統合されたため)。
    private func openOAuthLogin() {
        guard let url = URL(string: "\(viewModel.serverURLString)/oauth/login") else { return }
        UIApplication.shared.open(url)
    }
}
