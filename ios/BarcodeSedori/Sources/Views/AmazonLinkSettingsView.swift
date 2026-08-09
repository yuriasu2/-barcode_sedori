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
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                if settings.isSpApiLinkUsable {
                    Text("連携済み")
                        .foregroundColor(.blue)
                }

                Text("再連携する場合は上のリンクからお願いします。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("""
                Amazon連携で高速バーコードスキャンが無制限でご利用いただけます。
                連携後7日間、下記のProプランの機能をお試しいただけます。
                ・出品可否の表示
                ・出品機能の利用
                ・OCR機能
                ・アラート機能
                """)
                .font(.footnote)
                .foregroundColor(.secondary)
            }

            Section {
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

    /// ログインボタンから、サーバーの /oauth/login をSafari(外部ブラウザ)で開く。
    /// SettingsView.openOAuthLogin()から移設(SP-API連携セクションがこの画面に統合されたため)。
    private func openOAuthLogin() {
        guard let url = URL(string: "\(viewModel.serverURLString)/oauth/login") else { return }
        UIApplication.shared.open(url)
    }
}
