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


    /// SP-API/Keepa共通の接続テスト結果アラート。
    /// SwiftUIは同一ビューに複数の.alert(item:)を重ねると片方(内側)が表示されなくなる制限が
    /// あるため、以前はspapiTestAlert/keepaTestAlertを別々に持っていたが1つに統合した。
    @Published var connectionTestAlert: ConnectionTestAlert?

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
                connectionTestAlert = ConnectionTestAlert(title: "接続成功", message: "SP-APIに接続できました。")
            } else {
                connectionTestAlert = ConnectionTestAlert(
                    title: "接続失敗",
                    message: result.message ?? "SP-APIへの接続に失敗しました。"
                )
            }
        } catch {
            connectionTestAlert = ConnectionTestAlert(title: "接続失敗", message: error.localizedDescription)
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
                connectionTestAlert = ConnectionTestAlert(title: "接続成功", message: tokensMessage)
            } else {
                connectionTestAlert = ConnectionTestAlert(
                    title: "接続失敗",
                    message: result.message ?? "Keepaへの接続に失敗しました。"
                )
            }
        } catch {
            connectionTestAlert = ConnectionTestAlert(title: "接続失敗", message: error.localizedDescription)
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
                    + " 消費レート\(snapshot.consumeRatePerMin)/分 補充\(snapshot.refillPerMin)/分"
            } else {
                demoSeedResultText = "適用しました(スナップショットは取得できませんでした)"
            }
        } catch {
            demoSeedResultText = "失敗しました: \(error.localizedDescription)"
        }
    }

}

/// App Storeのレビューページへの直接リンク設定。
/// システムのレビュー依頼(requestReview)はAppleガイドライン上ボタンから明示的に
/// 呼び出してはいけないため、設定画面の「レビューを書く」行はここのURLへ直接ディープリンクする
/// (ReviewPromptController経由の自動依頼とは別の導線)。
private enum AppStoreReviewConfig {
    /// App StoreのアプリID。このアプリは未リリースでIDがまだ存在しないため空文字のまま。
    /// リリース前に実際のIDを設定すること。空の間は設定行ごと非表示になる(壊れたリンクを出さないため)。
    static let appId = ""
}

/// お問い合わせフォームへの導線設定。
/// AppStoreReviewConfig.appIdと違いこのURLは既に存在し有効なため、行を隠す条件は無く常に表示する。
private enum SupportConfig {
    static let contactURL = "https://sellira.jp/contact/"
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var entitlements = EntitlementStore.shared
    /// 設定値の唯一の真実。OAuthコールバックでの更新を画面に反映させるため直接監視する。
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showPaywall = false
    /// アプリ内ブラウザ(SafariView)で開く対象。お問い合わせフォームをアプリ内で開くために使う。
    @State private var browserTarget: BrowserTarget?
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
                        // ここは実際の課金状態(isPro)のみを反映する。お試し中でも「無料」のまま表示し、
                        // お試しの案内はこの下のtrialStatusRowで別出しする。
                        if entitlements.isPro {
                            Label("Pro", systemImage: "checkmark.seal.fill")
                                .foregroundColor(.green)
                        } else {
                            Text("無料")
                                .foregroundColor(.secondary)
                        }
                    }

                    trialStatusRow

                    // アップグレード導線も実際の課金状態で出し分ける(お試し中でも未課金なら出す)。
                    if !entitlements.isPro {
                        Button {
                            ReviewPromptController.shared.recordNegativeEvent()
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

                    // App StoreのアプリIDが未設定(未リリース)の間は行ごと出さない。
                    if !AppStoreReviewConfig.appId.isEmpty {
                        Button {
                            openAppStoreReviewPage()
                        } label: {
                            Text("レビューを書く")
                        }
                    }
                }

                Section("サポート") {
                    Button {
                        openSupportContactPage()
                    } label: {
                        Text("ご意見・お問い合わせ")
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

                    Text("デモ専用の隔離されたインスタンスに値を注入します。本番の共有Keepaキーを使う他の利用者には一切影響しません。注入した値やブレーキの挙動を確認するには、上の「デバッグ表示」も合わせてONにしてください。補充レートを指定すると、時間経過で残量が実際に回復していく様子を観察できます(未指定時は従来通り固定されたままです)。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                #endif

                keepaLinkSection

                Section {
                    NavigationLink("Amazon連携") {
                        AmazonLinkSettingsView(viewModel: viewModel)
                    }
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
            .alert(item: $viewModel.connectionTestAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            // ProductDetailView/SearchTabViewと同様、.sheet(item:)と.sheet(isPresented:)を
            // 別々のmodifierとして重ねる(SwiftUIはこの重ね方に対応している。片方の内側に
            // ネストする必要は無い)。
            .sheet(item: $browserTarget) { target in
                SafariView(url: target.url)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - プラン(お試し表示)

    /// Amazon連携特典の7日間お試し中に表示する行。課金済み(isPro)なら出さない
    /// (課金しているのにわざわざ「お試し中」と案内する必要は無いため)。
    @ViewBuilder
    private var trialStatusRow: some View {
        if !entitlements.isPro, settings.isSpApiTrialActive, let remainingDays = spapiTrialRemainingDays {
            HStack {
                Image(systemName: "gift.fill")
                    .foregroundColor(.orange)
                Text("Amazon連携特典: Pro機能お試し中(残り\(remainingDays)日)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// お試し残り日数。端数日も「残り1日」と読めるよう切り上げる。
    /// サーバーから取得済みの期限キャッシュが無い、または既に期限切れならnil(この場合は行自体を出さない)。
    private var spapiTrialRemainingDays: Int? {
        guard let expiresAt = settings.spapiTrialExpiresAt else { return nil }
        let remainingSeconds = expiresAt.timeIntervalSinceNow
        guard remainingSeconds > 0 else { return nil }
        return Int(ceil(remainingSeconds / 86400))
    }

    // MARK: - 利益アラート

    /// 利益アラート設定セクション。無料は鍵行のみでタップでペイウォール、Proは専用画面への導線1行のみ。
    /// セクション見出しは付けない(旧「利益アラート」だと、中の行/画面自体の名称
    /// 「アラート設定」と表記が混在していた。見出しをそちらに揃えると行と同じ文字が
    /// 二重表示されるため、見出し自体を無くしリンクの文言だけで示す)。
    @ViewBuilder
    private var profitAlertSection: some View {
        Section {
            if entitlements.isProOrTrial {
                NavigationLink("アラート設定") {
                    ProfitAlertSettingsView()
                }
            } else {
                Button {
                    ReviewPromptController.shared.recordNegativeEvent()
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
            // Keepa BYOキーはグラフ無制限に直結し、7日間お試しの対象外(仕様上isProのみ許可)のため
            // isProOrTrialにはしない。
            if entitlements.isPro {
                NavigationLink("Keepa連携") {
                    KeepaLinkSettingsView(viewModel: viewModel)
                }
            } else {
                Button {
                    ReviewPromptController.shared.recordNegativeEvent()
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
            if entitlements.isProOrTrial {
                NavigationLink("出品説明文テンプレート") {
                    ListingTemplateSettingsView()
                }
                NavigationLink("SKUフォーマット") {
                    SkuFormatSettingsView()
                }
                // 仕入れフォームのデフォルト値。商品ごとにフォーム側で変更できる。
                Toggle("FBAを利用", isOn: $settings.purchaseUseFbaDefault)
                Toggle("配送料を引いた最安値自動入力", isOn: $settings.purchaseSubtractShippingFromLowest)
                Text("出品価格に、最安値から「送料設定」の配送料を引いた額を自動入力します。FBA利用時は配送料を引きません。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                NavigationLink("送料設定") {
                    ShippingSettingsView()
                }
                NavigationLink("仕入先") {
                    PurchaseSettingsView()
                }
            } else {
                Button {
                    ReviewPromptController.shared.recordNegativeEvent()
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

    /// 「レビューを書く」ボタンから、App Storeのレビュー投稿ページを直接開く。
    /// システムのレビュー依頼(requestReview)をボタンから呼ぶのはAppleガイドライン違反のため、
    /// あくまで外部リンクとして開く(SP-API認証と同じ作法)。
    private func openAppStoreReviewPage() {
        guard !AppStoreReviewConfig.appId.isEmpty,
              let url = URL(string: "https://apps.apple.com/app/id\(AppStoreReviewConfig.appId)?action=write-review")
        else { return }
        UIApplication.shared.open(url)
    }

    /// 「ご意見・お問い合わせ」ボタンから、診断情報付きのお問い合わせフォームを開く。
    /// SP-API認証・レビューの外部リンクと違いUIApplication.shared.openではなくSafariView
    /// (アプリ内ブラウザ)で開く。送信後に利用者がアプリへ戻ってこられるようにするため。
    private func openSupportContactPage() {
        guard let url = supportContactURL() else { return }
        browserTarget = BrowserTarget(url: url)
    }

    /// お問い合わせフォームのURLを診断情報のクエリパラメータ付きで組み立てる。
    ///
    /// 個人情報保護のための制約: ここには環境・状態に関する非個人情報のみを含めること。
    /// デバイスID/IDFA/IDFV、Amazon出品者ID、Keepa APIキー、SP-APIリフレッシュトークン、
    /// メールアドレスなど、利用者やデバイスを特定できる識別子は将来も絶対に追加しないこと。
    private func supportContactURL() -> URL? {
        guard var components = URLComponents(string: SupportConfig.contactURL) else { return nil }

        let plan: String
        if entitlements.isPro {
            plan = "pro"
        } else if settings.isSpApiTrialActive {
            plan = "trial"
        } else {
            plan = "free"
        }

        components.queryItems = [
            URLQueryItem(name: "app_version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
            URLQueryItem(name: "build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""),
            URLQueryItem(name: "os", value: UIDevice.current.systemVersion),
            URLQueryItem(name: "device", value: Self.deviceModelIdentifier()),
            URLQueryItem(name: "plan", value: plan),
            URLQueryItem(name: "spapi", value: settings.isSpApiLinkUsable ? "linked" : "unlinked"),
        ]
        return components.url
    }

    /// 機種の識別子(例: "iPhone16,2")を取得する。
    /// システムからは「iPhone 15 Pro」のようなマーケティング名は取得できないため、
    /// 機種識別子をそのまま送る。マーケティング名への変換には対応表の保守が必要になるため、
    /// ここでは意図的に行わない。
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }
}
