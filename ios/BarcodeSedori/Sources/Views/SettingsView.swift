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

    // MARK: 無料枠クォータのリセット(開発者向け)

    #if DEBUG
    /// リセット結果を画面に一時表示するためのテキスト。
    @Published var quotaResetResultText: String?

    /// このデバイスの当日分の無料枠消費・広告付与をサーバー側で0に戻す。
    /// 再インストールしてもKeychain永続のDeviceIdentifierは変わらない(意図的な設計)ため、
    /// 検証中に枠を使い切ったときのリセット手段として用意している。
    /// 成功時はScanQuotaStoreへも即時反映し、他画面の残量表示をリロードなしで更新する。
    func resetQuota() async {
        do {
            let quota = try await apiClient.resetQuota()
            ScanQuotaStore.shared.apply(quota)
            quotaResetResultText = "リセットしました(残り\(quota.unitsRemaining ?? 0)回)"
        } catch {
            quotaResetResultText = "失敗しました: \(error.localizedDescription)"
        }
    }
    #endif
}

/// App Storeのレビューページへの直接リンク設定。
/// システムのレビュー依頼(requestReview)はAppleガイドライン上ボタンから明示的に
/// 呼び出してはいけないため、設定画面の「レビューを書く」行はここのURLへ直接ディープリンクする
/// (ReviewPromptController経由の自動依頼とは別の導線)。
private enum AppStoreReviewConfig {
    /// App StoreのアプリID(App Store Connectでアプリを登録すると採番される)。
    /// 2026-08-14にアプリ登録が完了したため設定済み。空の間は設定行ごと非表示になる仕様は
    /// そのまま残している(万一空に戻したときに壊れたリンクを出さないため)。
    static let appId = "6801570852"
}

/// お問い合わせフォームへの導線設定。
/// AppStoreReviewConfig.appIdと違いこのURLは既に存在し有効なため、行を隠す条件は無く常に表示する。
private enum SupportConfig {
    static let contactURL = "https://sellira.jp/contact/"
    static let noticesURL = "https://sellira.jp/sellerlens/news/"
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var entitlements = EntitlementStore.shared
    /// 設定値の唯一の真実。OAuthコールバックでの更新を画面に反映させるため直接監視する。
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showPaywall = false
    /// 検索履歴の全削除の確認アラート。取り消せない操作なので必ず確認を挟む。
    @State private var showHistoryDeleteConfirm = false
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
                            ReviewPromptController.shared.recordNegativeEvent()
                            Analytics.shared.capture(.paywallShown(trigger: .settingsUpgradeButton))
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

                linkSection

                searchSection

                listingSection

                Section("サポート") {
                    Button {
                        openNoticesPage()
                    } label: {
                        Text("お知らせ")
                    }

                    // App StoreのアプリIDが未設定(未リリース)の間は行ごと出さない。
                    if !AppStoreReviewConfig.appId.isEmpty {
                        Button {
                            openAppStoreReviewPage()
                        } label: {
                            Text("レビューを書く")
                        }
                    }

                    Button {
                        openSupportContactPage()
                    } label: {
                        Text("ご意見・お問い合わせ")
                    }
                }

                // 接続先サーバーの変更は開発用途のみ(ローカルサーバーへ向ける等)。本番ユーザーが
                // 誤って書き換えると接続不能になりサポート負荷になるだけなので、Releaseビルドには
                // セクションごと存在しない(下の「開発者向け」セクションと同じ方針)。
                // 既定値(SettingsStore.defaultServerURL)は本番の https://api.sellira.jp のため、
                // このセクションが無くても常に正しいサーバーへ接続される。
                #if DEBUG
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
                #endif

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

                    Button(role: .destructive) {
                        Task { await viewModel.resetQuota() }
                    } label: {
                        Text("無料枠クォータをリセット")
                    }

                    if let quotaResetResultText = viewModel.quotaResetResultText {
                        Text(quotaResetResultText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Text("このデバイスの本日分のスキャン消費・広告視聴付与をサーバー側で0に戻します。DeviceIdentifierはKeychain永続のため、アプリを削除・再インストールしても無料枠はリセットされません(意図的な設計)。検証中に枠を使い切ったときはこのボタンを使ってください。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                #endif
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

    // MARK: - 利益アラート

    /// 利益アラート設定セクション。無料は鍵行のみでタップでペイウォール、Proは専用画面への導線1行のみ。
    /// セクション見出しは付けない(旧「利益アラート」だと、中の行/画面自体の名称
    /// 「アラート設定」と表記が混在していた。見出しをそちらに揃えると行と同じ文字が
    /// 二重表示されるため、見出し自体を無くしリンクの文言だけで示す)。
    @ViewBuilder
    /// 「検索」セクション: リンクボタン設定・アラート設定・バイブレーションをまとめる。
    /// 検索タブの挙動に関わる設定を1箇所に集約する(以前は別々のSectionだった)。
    private var searchSection: some View {
        Section("検索") {
            NavigationLink("リンクボタン設定") {
                LinkButtonSettingsView()
            }

            if entitlements.isPro {
                NavigationLink("アラート設定") {
                    ProfitAlertSettingsView()
                }
            } else {
                Button {
                    ReviewPromptController.shared.recordNegativeEvent()
                    Analytics.shared.capture(.paywallShown(trigger: .profitAlertLock))
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

            // スキャン成功時の一瞬の振動(ScannerView.emit)。利益アラートの振動とは別設定で、
            // 誰でも(無料でも)発生するため常にここに出す。
            Toggle("バイブレーション", isOn: $settings.scanSuccessHapticsEnabled)

            Button(role: .destructive) {
                showHistoryDeleteConfirm = true
            } label: {
                Text("検索履歴を削除")
            }
            // アラートはボタン自身に付ける。SettingsViewの外側には接続テスト用の
            // .alert(item:)が既にあり、同一階層に重ねると片方が出なくなる制限があるため
            // (viewModel.connectionTestAlertのコメント参照)、階層を分けて回避する。
            .alert("検索履歴を削除しますか？", isPresented: $showHistoryDeleteConfirm) {
                Button("削除する", role: .destructive) {
                    ScanHistoryStore.shared.clear()
                    // 履歴に紐づく保存済みグラフも消す。履歴が無いのにグラフのファイルだけ
                    // 残しても参照されず、容量を占めるだけになるため。
                    GraphArchive.removeAll()
                    PriceHistoryChartView.clearMemoryCache()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("商品タブの検索履歴をすべて削除します。保存されている価格推移グラフも削除されます。この操作は取り消せません。")
            }
        }
    }

    // MARK: - 連携

    /// 「連携」セクション: Amazon連携・Keepa連携をまとめる。どちらも外部サービスとの
    /// 連携設定であり、以前は離れた場所に別々のSectionとして置かれていた。
    private var linkSection: some View {
        Section("連携") {
            NavigationLink("Amazon連携") {
                AmazonLinkSettingsView(viewModel: viewModel)
            }

            // Keepa BYOキー(グラフ無制限に直結する)はPro限定。
            if entitlements.isPro {
                NavigationLink("Keepa連携") {
                    KeepaLinkSettingsView(viewModel: viewModel)
                }
            } else {
                Button {
                    ReviewPromptController.shared.recordNegativeEvent()
                    Analytics.shared.capture(.paywallShown(trigger: .keepaLinkLock))
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
                    Analytics.shared.capture(.paywallShown(trigger: .listingLock))
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

    /// 「お知らせ」ボタンから、お知らせ一覧ページを開く。中身はWebサイト側で管理するため
    /// アプリ側に自前画面は作らず、お問い合わせフォームと同じくSafariView(アプリ内ブラウザ)で開く。
    /// お問い合わせと違い診断情報のクエリは不要(単純にURLを開くだけ)。
    private func openNoticesPage() {
        guard let url = URL(string: SupportConfig.noticesURL) else { return }
        browserTarget = BrowserTarget(url: url)
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

        let plan = entitlements.isPro ? "pro" : "free"

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
