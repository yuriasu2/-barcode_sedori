import SwiftUI
import UIKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var connectionState: ConnectionState = .idle

    // MARK: SP-API連携
    //
    // 設定値は SettingsStore(シングルトン) を唯一の真実として直接読み書きする。
    // ViewModel側に@Publishedのコピーを持つと、OAuthコールバックで
    // SettingsStore が更新されても古い値を保持し続け、didSetで巻き戻してしまう
    // (連携済みなのにヘッダーが送られない不具合の原因になっていた)。

    /// サーバーURL。
    var serverURLString: String {
        get { settingsStore.serverURLString }
        set { settingsStore.serverURLString = newValue }
    }

    /// 自分のSP-APIを使用するか。
    var spapiLinkEnabled: Bool {
        get { settingsStore.spapiLinkEnabled }
        set { settingsStore.spapiLinkEnabled = newValue }
    }

    /// SP-API リフレッシュトークン。
    var spapiRefreshToken: String {
        get { settingsStore.spapiRefreshToken }
        set { settingsStore.spapiRefreshToken = newValue }
    }

    /// サーバー側SP-APIを使うか。オフでKeepa動作確認用にSP-APIを読み込ませない。
    var renderSpApiEnabled: Bool {
        get { settingsStore.renderSpApiEnabled }
        set { settingsStore.renderSpApiEnabled = newValue }
    }

    @Published var spapiTestAlert: SpApiTestAlert?

    struct SpApiTestAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum ConnectionState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private let settingsStore: SettingsStore
    private let apiClient: APIClient

    init(settingsStore: SettingsStore = .shared, apiClient: APIClient = .shared) {
        self.settingsStore = settingsStore
        self.apiClient = apiClient
    }

    func testConnection() async {
        connectionState = .testing
        do {
            try await apiClient.testConnection()
            connectionState = .success
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    var isSpApiTesting: Bool {
        if case .testingSpApi = spapiTestState { return true }
        return false
    }

    @Published var spapiTestState: SpApiConnectionState = .idle

    enum SpApiConnectionState: Equatable {
        case idle
        case testingSpApi
    }

    func testSpApiConnection() async {
        spapiTestState = .testingSpApi
        do {
            let result = try await apiClient.spapiTest()
            if result.ok {
                spapiTestAlert = SpApiTestAlert(title: "接続成功", message: "SP-APIに接続できました。")
            } else {
                spapiTestAlert = SpApiTestAlert(
                    title: "接続失敗",
                    message: result.message ?? "SP-APIへの接続に失敗しました。"
                )
            }
        } catch {
            spapiTestAlert = SpApiTestAlert(title: "接続失敗", message: error.localizedDescription)
        }
        spapiTestState = .idle
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var entitlements = EntitlementStore.shared
    /// 設定値の唯一の真実。OAuthコールバックでの更新を画面に反映させるため直接監視する。
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showPaywall = false

    var body: some View {
        NavigationView {
            Form {
                Section("プラン") {
                    HStack {
                        Text("現在のプラン")
                        Spacer()
                        if entitlements.isPro {
                            Label("Pro", systemImage: "checkmark.seal.fill")
                                .foregroundColor(.green)
                        } else {
                            Text("無料")
                                .foregroundColor(.secondary)
                        }
                    }

                    if !entitlements.isPro {
                        Button {
                            showPaywall = true
                        } label: {
                            Text("Proにアップグレード")
                        }
                        Button {
                            Task { await entitlements.restore() }
                        } label: {
                            Text("購入を復元")
                        }
                    }
                }

                Section("サーバー設定") {
                    TextField(SettingsStore.defaultServerURL, text: $viewModel.serverURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    Button {
                        Task { await viewModel.testConnection() }
                    } label: {
                        HStack {
                            Text("接続テスト")
                            Spacer()
                            statusView
                        }
                    }
                    .disabled(viewModel.connectionState == .testing)
                }

                if case .failure(let message) = viewModel.connectionState {
                    Section("エラー詳細") {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Text("通常は変更不要です(既定: \(SettingsStore.defaultServerURL))。開発時にローカルサーバーへ向ける場合のみ変更してください。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("開発者向け") {
                    Toggle("Render側SP-APIを使用する", isOn: $viewModel.renderSpApiEnabled)
                    Text("オフにするとサーバーのSP-APIを読み込まず、Keepaのみで価格を取得します。Keepaの動作確認用の一時トグルです。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("SP-API連携") {
                    Toggle("自分のSP-APIを使用する", isOn: $viewModel.spapiLinkEnabled)

                    if viewModel.spapiRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            openOAuthLogin()
                        } label: {
                            Text("SP-API認証を開始")
                        }
                    } else {
                        HStack {
                            Label("連携済み", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Spacer()
                        }
                        Button(role: .destructive) {
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

                    DisclosureGroup("詳細設定") {
                        SecureField("リフレッシュトークン(手動入力)", text: $viewModel.spapiRefreshToken)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    Text("「SP-API認証を開始」をタップするとAmazonのログイン・承認画面が開き、完了すると自動でこのアプリに戻ります。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("設定")
            .alert(item: $viewModel.spapiTestAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.connectionState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    /// 「SP-API認証を開始」ボタンから、サーバーの /oauth/login をSafari(外部ブラウザ)で開く。
    private func openOAuthLogin() {
        guard let url = URL(string: "\(viewModel.serverURLString)/oauth/login") else { return }
        UIApplication.shared.open(url)
    }
}
