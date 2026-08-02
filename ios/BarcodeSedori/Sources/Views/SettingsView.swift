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

    /// 利用者自身のKeepa APIキー(BYO)。
    var keepaApiKey: String {
        get { settingsStore.keepaApiKey }
        set { settingsStore.keepaApiKey = newValue }
    }


    @Published var spapiTestAlert: ConnectionTestAlert?
    /// Keepa接続テストの結果アラート。SP-APIと同じ汎用アラート型(ConnectionTestAlert)を使い回す
    /// (見た目・作法が完全に同じなため型を分ける理由が無い)。
    @Published var keepaTestAlert: ConnectionTestAlert?

    /// 接続テスト結果アラート(タイトル+本文)。旧SpApiTestAlertから汎用化し、
    /// SP-API/Keepaの両方の接続テストで使い回す。
    struct ConnectionTestAlert: Identifiable {
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
                spapiTestAlert = ConnectionTestAlert(title: "接続成功", message: "SP-APIに接続できました。")
            } else {
                spapiTestAlert = ConnectionTestAlert(
                    title: "接続失敗",
                    message: result.message ?? "SP-APIへの接続に失敗しました。"
                )
            }
        } catch {
            spapiTestAlert = ConnectionTestAlert(title: "接続失敗", message: error.localizedDescription)
        }
        spapiTestState = .idle
    }

    // MARK: Keepa連携

    var isKeepaTesting: Bool {
        if case .testingKeepa = keepaTestState { return true }
        return false
    }

    @Published var keepaTestState: KeepaConnectionState = .idle

    enum KeepaConnectionState: Equatable {
        case idle
        case testingKeepa
    }

    /// Keepa APIキーの接続テスト。testSpApiConnectionと同じ作法(state切替→API呼び出し→結果アラート)。
    func testKeepaConnection() async {
        keepaTestState = .testingKeepa
        do {
            let result = try await apiClient.keepaTest()
            if result.ok {
                let tokensMessage = result.tokensLeft.map { "残トークン数: \($0)" } ?? "Keepaに接続できました。"
                keepaTestAlert = ConnectionTestAlert(title: "接続成功", message: tokensMessage)
            } else {
                keepaTestAlert = ConnectionTestAlert(
                    title: "接続失敗",
                    message: result.message ?? "Keepaへの接続に失敗しました。"
                )
            }
        } catch {
            keepaTestAlert = ConnectionTestAlert(title: "接続失敗", message: error.localizedDescription)
        }
        keepaTestState = .idle
    }

    // MARK: Keepaスロットルのデモモード(開発者向け)

    /// デモ状態の適用結果(成功時はスナップショットの整形文字列、失敗時はエラー文言)を
    /// 画面に一時表示するためのテキスト。
    @Published var demoSeedResultText: String?

    /// 入力欄の文字列(空なら未指定=そのパラメータはサーバーへ送らない)をDoubleへ変換し、
    /// POST /api/keepa-throttle-demo/seed を呼ぶ。tokens/ratePerMinの少なくとも一方が
    /// 数値変換できればよい(両方空はサーバー側で400になるが、ここでは弾かずそのまま送る)。
    /// refillPerMinは補充レート(トークン/分)。空欄なら未指定のまま送り、サーバー側の既定
    /// (0固定=自然回復しない)に任せる。
    func seedKeepaThrottleDemo(tokensText: String, ratePerMinText: String, refillPerMinText: String) async {
        let tokens = Double(tokensText.trimmingCharacters(in: .whitespaces))
        let ratePerMin = Double(ratePerMinText.trimmingCharacters(in: .whitespaces))
        let refillPerMin = Double(refillPerMinText.trimmingCharacters(in: .whitespaces))
        do {
            let result = try await apiClient.seedKeepaThrottleDemo(
                tokens: tokens,
                ratePerMin: ratePerMin,
                refillPerMin: refillPerMin
            )
            if let snapshot = result.snapshot {
                demoSeedResultText = "適用しました: 残量\(snapshot.tokensEstimate)/\(snapshot.capacity)"
                    + " 消費レート\(snapshot.consumeRatePerMin)/分 補充\(snapshot.refillPerMin)/分 キュー\(snapshot.queueLength)/\(snapshot.depth)"
            } else {
                demoSeedResultText = "適用しました(スナップショットは取得できませんでした)"
            }
        } catch {
            demoSeedResultText = "失敗しました: \(error.localizedDescription)"
        }
    }

    /// 「同時リクエストをテスト」1件分の表示用データ。完了した順にprobeResultsへappendしていく。
    struct ProbeResultRow: Identifiable {
        let id = UUID()
        let label: String
        let priority: String
        /// 成功時はKeepaThrottleProbeResult、失敗時(通信エラー等)はエラー文言。
        let outcome: Result<KeepaThrottleProbeResult, Error>

        var displayText: String {
            switch outcome {
            case .success(let result):
                let icon = result.allowed ? "✅" : "❌"
                let statusText = result.allowed ? "許可" : "拒否(\(result.reason ?? "不明"))"
                return "\(icon) \(label)  \(priority)  \(statusText)  waited=\(result.waitedMs)ms"
            case .failure(let error):
                return "⚠️ \(label)  \(priority)  エラー: \(error.localizedDescription)"
            }
        }
    }

    /// Pro/freeの複数リクエストを同時発火し、'demo'インスタンスのスロットル判定だけを見る
    /// (実Keepaは呼ばない)。完了した順にprobeResultsへappendすることで、Proが先に通る様子・
    /// 補充で順に許可されていく様子を画面上で確認できるようにする。
    @Published var probeResults: [ProbeResultRow] = []
    @Published var isProbing = false

    func runConcurrentKeepaThrottleProbe() async {
        probeResults = []
        isProbing = true
        defer { isProbing = false }

        let requests: [(String, String)] = [
            ("free-1", "free"), ("free-2", "free"), ("free-3", "free"),
            ("pro-1", "pro"), ("pro-2", "pro"),
        ]

        await withTaskGroup(of: (String, String, Result<KeepaThrottleProbeResult, Error>).self) { group in
            for (label, priority) in requests {
                group.addTask {
                    do {
                        let result = try await self.apiClient.probeKeepaThrottleDemo(priority: priority)
                        return (label, priority, .success(result))
                    } catch {
                        return (label, priority, .failure(error))
                    }
                }
            }
            for await (label, priority, outcome) in group {
                probeResults.append(ProbeResultRow(label: label, priority: priority, outcome: outcome))
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var entitlements = EntitlementStore.shared
    /// 設定値の唯一の真実。OAuthコールバックでの更新を画面に反映させるため直接監視する。
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showPaywall = false
    #if DEBUG
    /// 開発用Pro強制トグルの表示state(実体はEntitlementStore側のUserDefaults)。
    @State private var debugForcePro = EntitlementStore.shared.debugForcePro
    /// Keepaスロットルのデモモード用入力欄(残りトークン数・消費レート・補充レート)。文字列で保持しDouble変換する。
    @State private var demoTokensText = ""
    @State private var demoRatePerMinText = ""
    @State private var demoRefillPerMinText = ""
    #endif

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

                profitAlertSection

                linkButtonSection

                listingSection

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

                // 開発ビルド専用。シミュレータではStoreKitの実購入ができずPro限定画面を検証できないため、
                // 強制的にProとして扱えるようにする。Releaseビルドにはセクションごと存在しない。
                #if DEBUG
                Section("開発者向け") {
                    Toggle("【開発用】Proとして扱う", isOn: $debugForcePro)
                        .onChange(of: debugForcePro) { newValue in
                            entitlements.debugForcePro = newValue
                        }
                    Toggle("Keepaスロットルのデバッグ表示", isOn: $settings.keepaThrottleDebugEnabled)

                    Toggle("Keepaデモインスタンスを使う", isOn: $settings.keepaThrottleDemoEnabled)

                    TextField("残りトークン数", text: $demoTokensText)
                        .keyboardType(.decimalPad)

                    TextField("消費レート(件/分)", text: $demoRatePerMinText)
                        .keyboardType(.decimalPad)

                    TextField("補充レート(トークン/分)", text: $demoRefillPerMinText)
                        .keyboardType(.decimalPad)

                    Button {
                        Task {
                            await viewModel.seedKeepaThrottleDemo(
                                tokensText: demoTokensText,
                                ratePerMinText: demoRatePerMinText,
                                refillPerMinText: demoRefillPerMinText
                            )
                        }
                    } label: {
                        Text("デモ状態を適用")
                    }

                    if let demoSeedResultText = viewModel.demoSeedResultText {
                        Text(demoSeedResultText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Text("デモ専用の隔離されたインスタンスに値を注入します。本番の共有Keepaキーを使う他の利用者には一切影響しません。注入した値やブレーキ・キューの挙動を確認するには、上の「デバッグ表示」も合わせてONにしてください。補充レートを指定すると、時間経過で残量が実際に回復していく様子を観察できます(未指定時は従来通り固定されたままです)。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button {
                        Task { await viewModel.runConcurrentKeepaThrottleProbe() }
                    } label: {
                        HStack {
                            Text("同時リクエストをテスト")
                            if viewModel.isProbing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isProbing)

                    ForEach(viewModel.probeResults) { row in
                        Text(row.displayText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Text("Pro2件・Free3件を同時に発火し、実Keepaを呼ばずに'demo'インスタンスのスロットル判定だけを試します。完了した順に上から表示されるため、Proが優先して通る様子や、補充で順に許可されていく様子を確認できます。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                #endif

                keepaLinkSection

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
            // 大タイトル「設定」は削除し、その分を画面上部の広告枠に充てる
            // (商品/仕入れタブでナビバーを隠した先例に合わせる)。
            // safeAreaInsetはNavigationViewの内側(Form)に付ける。外側に付けると
            // Form側の余白計算に反映されず、先頭セクションの見出しが枠の下に潜り込む。
            .safeAreaInset(edge: .top) {
                AdSlotView(slotId: "settings_bottom", fixedHeight: 50)
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert(item: $viewModel.spapiTestAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(item: $viewModel.keepaTestAlert) { alert in
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

    // MARK: - 利益アラート

    /// 利益アラート設定セクション。無料は鍵行のみでタップでペイウォール、Proは専用画面への導線1行のみ。
    /// セクション見出しは付けない(旧「利益アラート」だと、中の行/画面自体の名称
    /// 「アラート設定」と表記が混在していた。見出しをそちらに揃えると行と同じ文字が
    /// 二重表示されるため、見出し自体を無くしリンクの文言だけで示す)。
    @ViewBuilder
    private var profitAlertSection: some View {
        Section {
            if entitlements.isPro {
                NavigationLink("アラート設定") {
                    ProfitAlertSettingsView()
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        LockIconView(size: 16)
                        Text("利益アラートはProで")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Keepa連携

    /// 利用者自身のKeepa APIキー(BYO)設定セクション。無料は鍵行のみでタップでペイウォール
    /// (profitAlertSectionと全く同じ作法)。Proではグラフ取得の消費先を自分の枠に切り替えられる。
    @ViewBuilder
    private var keepaLinkSection: some View {
        Section("Keepa連携") {
            if entitlements.isPro {
                SecureField("Keepa APIキー", text: $viewModel.keepaApiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

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
                .disabled(viewModel.isKeepaTesting || settings.keepaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("自分のKeepa APIキーを設定すると、グラフ取得が自分の枠で行われます。Amazon連携時のグラフ表示待ち時間(5秒)も無くなります。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        LockIconView(size: 16)
                        Text("Keepa連携はProで")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - リンクボタン

    /// リンクボタン設定セクション。無料でも使える機能のためPro限定にしない
    /// (profitAlertSection/listingSectionと違い鍵行を出さない)。
    private var linkButtonSection: some View {
        Section("リンクボタン") {
            NavigationLink("表示するボタンを選ぶ") {
                LinkButtonSettingsView()
            }

            Toggle("型番で検索する", isOn: $settings.linkSearchByModelNumber)
            Text("オフのときは商品名で検索します。型番が無い商品(書籍など)は自動的に商品名で検索します。")
                .font(.footnote)
                .foregroundColor(.secondary)
            // 楽天アフィリエイトIDはアプリ運営者の収益に結びつくものであり利用者が入力する項目
            // ではないため、サーバー管理(AdsConfigStore経由)に一本化した。設定画面には出さない。
        }
    }

    // MARK: - 出品

    /// 出品設定セクション。無料は鍵行のみでタップでペイウォール(profitAlertSectionと同じ作法)。
    @ViewBuilder
    private var listingSection: some View {
        Section("出品") {
            if entitlements.isPro {
                NavigationLink("出品説明文テンプレート") {
                    ListingTemplateSettingsView()
                }
                NavigationLink("SKUフォーマット") {
                    SkuFormatSettingsView()
                }
                // 仕入れフォームのデフォルト値。商品ごとにフォーム側で変更できる。
                Toggle("FBAを利用", isOn: $settings.purchaseUseFbaDefault)
                NavigationLink("利益計算用送料") {
                    ShippingSettingsView()
                }
                NavigationLink("仕入先") {
                    PurchaseSettingsView()
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        LockIconView(size: 16)
                        Text("アプリ内出品はProで")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
        }
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
