import SwiftUI

/// 「Keepa連携」画面。設定タブの旧「Keepa連携」セクション(APIキー入力+接続テスト)を
/// 1画面に集約したもの。AmazonLinkSettingsViewと同じ構成。SettingsViewからPro限定で
/// NavigationLinkして開く(無料時の鍵ボタンは従来通りSettingsView側でペイウォールを出す)。
///
/// viewModelはSettingsViewが保持するインスタンスをそのまま受け取る(新規に作らない)。
/// 接続テスト結果(connectionTestAlert)はAmazon連携の接続テストとも共有する@Published状態のため、
/// 別インスタンスを作るとテスト結果がここに届かなくなる。
struct KeepaLinkSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                SecureField("Keepa APIキー", text: $viewModel.keepaApiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                Text("自分のKeepaApiキーを設定するとグラフの取得が自分の枠で行われます。グラフの表示待ち時間がなく表示が早くなります。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                Button {
                    Task { await viewModel.testKeepaConnection() }
                } label: {
                    HStack {
                        Text("接続テスト")
                        Spacer()
                        if viewModel.isKeepaTesting {
                            ProgressView()
                        }
                    }
                }
                .disabled(
                    viewModel.isKeepaTesting
                        || settings.keepaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .navigationTitle("Keepa連携")
        // AmazonLinkSettingsViewと同じ理由: connectionTestAlertは共有@Publishedのため、
        // 表示先の画面ごとに.alert(item:)を付けないとこの画面での結果が出ない。
        .alert(item: $viewModel.connectionTestAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
