import Foundation
import UIKit
import GoogleMobileAds

/// リワード広告(視聴で無料枠+5)の読み込み・表示を担うマネージャ(Google Mobile Ads SDK v11系 / GAD API)。
///
/// 付与の流れ:
///   1. アプリが `serverSideVerificationOptions.customRewardString` に identifierForVendor を入れて広告を表示
///   2. 視聴完了するとGoogleのサーバーが `GET /api/admob/ssv?...&custom_data=<identifierForVendor>` を叩く
///   3. サーバーが署名検証に成功した時点で当該デバイスの枠が+5される
/// アプリからサーバーへ「広告を見た」と申告する経路は無い(自己申告は信頼しない設計)。
/// そのため視聴完了後は `ScanQuotaStore.waitForAdGrant()` で /api/quota をポーリングして反映を待つ。
@MainActor
final class RewardedAdManager: ObservableObject {
    static let shared = RewardedAdManager()

    /// AdsConfigStoreから引くリワード広告枠のスロットID。
    private static let slotId = "rewarded_scan"
    /// Google公式のテスト用リワード広告ユニットID(サーバー設定が無い場合のフォールバック)。
    /// 本番ユニットIDはサーバーの /api/ads で配信し、アプリ更新なしで差し替えられるようにする。
    private static let fallbackUnitId = "ca-app-pub-3940256099942544/1712485313"

    /// 広告を読み込み中か(ボタンのスピナー表示用)。
    @Published private(set) var isLoading = false
    /// 広告を全画面表示中か。
    @Published private(set) var isPresenting = false
    /// 表示可能な広告を保持済みか。
    @Published private(set) var isReady = false
    /// 直近の `show(from:)` が実際に広告の表示まで到達したか。
    /// falseで返ったときに「準備できなかった(在庫なし・読み込み失敗)」と
    /// 「ユーザーが途中で閉じた」を呼び出し側が区別し、後者では警告を出さないために使う。
    private(set) var lastAttemptDidPresent = false

    /// 読み込み済みで未表示の広告。1つの広告インスタンスは1回しか表示できないため、表示時にnilへ戻す。
    private var loadedAd: GADRewardedAd?
    /// 進行中の読み込みタスク。先読みと表示要求が重なったときに同じ結果を共有するために保持する。
    private var loadTask: Task<GADRewardedAd?, Never>?
    /// 進行中の読み込みの識別子(Taskは値型で同一性比較できないためトークンで代用する)。
    private var loadToken: UUID?
    /// 表示中デリゲートの強参照。`fullScreenContentDelegate` はweakのため、
    /// ここで保持しないと表示中に解放されてdismissを検知できなくなる。
    private var presentationHandler: RewardedPresentationHandler?

    /// SSVの付与先を特定するデバイス識別子。APIClientがサーバーへ送る `X-Device-Id` と
    /// 同じ値でなければ、SSVが届いても別デバイスの枠に加算されてしまうため、
    /// 双方ともDeviceIdentifier(Keychain永続UUID)を唯一の出所とする。
    private var deviceId: String { DeviceIdentifier.current }

    /// リワード広告を出してよい状態か。AdsConfig.enabled(全広告のマスタースイッチ)を尊重する。
    var isEnabled: Bool { AdsConfig.enabled && FreemiumFlags.rewardedAdsEnabled }

    /// 表示に使う広告ユニットIDを解決する。
    ///   1. サーバー配信設定(/api/ads)のスロット `rewarded_scan` がadmob型ならそのunitId。
    ///      アプリ更新なしでユニットIDを差し替え・停止できるようにするため最優先で使う。
    ///   2. 未配信ならGoogle公式のテストユニットIDへフォールバックする(開発中に必ず在庫が返るため)。
    private var resolvedUnitId: String {
        if case .admob(let slot)? = AdsConfigStore.shared.slots[Self.slotId] {
            return slot.unitId
        }
        return Self.fallbackUnitId
    }

    /// 広告を先読みしておく(枠切れオーバーレイが出る前に呼ぶ想定)。
    /// 失敗しても何も通知しない。実際に必要になった時点で `show(from:)` が再読み込みを試みる。
    func preload() {
        guard isEnabled, !isLoading, !isPresenting, loadedAd == nil else { return }
        Task { await loadIfNeeded() }
    }

    /// リワード広告を表示し、報酬獲得(onUserEarnedReward)まで到達したらtrueを返す。
    /// キャンセル・表示失敗・在庫なしのときは静かにfalseを返す(呼び出し側がユーザーへ案内する)。
    /// - Parameter viewController: 表示元のVC。nilならSDKが最前面のVCから表示する。
    func show(from viewController: UIViewController?) async -> Bool {
        lastAttemptDidPresent = false
        guard isEnabled, !isPresenting else { return false }
        // DeviceIdentifierは常に値を返すため、旧来の「識別子がnilなら広告を出さない」ガードは不要。

        guard let ad = await loadIfNeeded() else { return false }
        // 1広告インスタンスは1回しか表示できないため、保持を解いてから表示する。
        loadedAd = nil
        isReady = false

        // SSVのcustom_dataにデバイス識別子を載せる。表示前に必ず設定する必要がある。
        let options = GADServerSideVerificationOptions()
        options.customRewardString = deviceId
        ad.serverSideVerificationOptions = options

        isPresenting = true
        let earnedReward = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let handler = RewardedPresentationHandler(continuation: continuation)
            presentationHandler = handler
            ad.fullScreenContentDelegate = handler
            ad.present(fromRootViewController: viewController) {
                // 報酬獲得。ただしここでは確定させず、広告が閉じた時点でまとめて結果を返す
                // (閉じる前に呼ばれるため、先にtrueを返すとUIが広告の下で進んでしまう)。
                handler.markRewardEarned()
            }
        }
        // 表示到達の判定はpresent()呼び出しの前ではなく、デリゲートの結果で行う。
        // present()が失敗(didFailToPresentFullScreenContentWithError)したのに「表示した」と
        // 扱うと、呼び出し側が「ユーザーが自分で閉じた」と誤認して何も案内せず、
        // ボタンを押したのに無反応という状態になるため。
        lastAttemptDidPresent = !(presentationHandler?.presentationFailed ?? true)
        presentationHandler = nil
        isPresenting = false

        // 次回のために裏で読み込んでおく(連続視聴時の待ち時間を無くすため)。
        preload()
        return earnedReward
    }

    /// 広告の表示元にする最前面のViewController。SwiftUIにはVCの概念が無いため、
    /// 前面シーンのルートVCからpresent中のVCを辿って最前面を返す
    /// (シート表示中でも確実に広告を出せるようにするため)。
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// 保持済みの広告があればそれを返し、無ければ読み込む。読み込めなければnil。
    /// 先読み(preload)が進行中にタップされた場合は、二重ロードせずその完了を待つ
    /// (即座に失敗扱いにすると「広告を準備できませんでした」を無用に出してしまうため)。
    @discardableResult
    private func loadIfNeeded() async -> GADRewardedAd? {
        if let loadedAd { return loadedAd }
        guard isEnabled else { return nil }

        let task: Task<GADRewardedAd?, Never>
        let token: UUID
        if let loadTask, let loadToken {
            task = loadTask
            token = loadToken
        } else {
            isLoading = true
            let unitId = resolvedUnitId
            task = Task { await Self.load(unitId: unitId) }
            token = UUID()
            loadTask = task
            loadToken = token
        }

        let ad = await task.value
        // 完了後の反映は先に再開した側が1度だけ行う。後から再開した側は loadedAd を読み直すため、
        // 既に表示へ回収済み(nil)の広告を二重に表示してしまうことがない。
        if loadToken == token {
            loadTask = nil
            loadToken = nil
            isLoading = false
            loadedAd = ad
            isReady = ad != nil
        }
        return loadedAd
    }

    /// GADRewardedAdの読み込みをasyncへ橋渡しする。失敗(在庫なし・ネットワークエラー)はnil。
    private static func load(unitId: String) async -> GADRewardedAd? {
        await withCheckedContinuation { (continuation: CheckedContinuation<GADRewardedAd?, Never>) in
            GADRewardedAd.load(withAdUnitID: unitId, request: GADRequest()) { ad, error in
                continuation.resume(returning: error == nil ? ad : nil)
            }
        }
    }
}

/// 全画面広告の「報酬獲得したか」「閉じたか」をasyncへ橋渡しするデリゲート。
/// 表示中はRewardedAdManagerが強参照する(GADのdelegateプロパティはweakのため)。
private final class RewardedPresentationHandler: NSObject, GADFullScreenContentDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var earnedReward = false
    /// 全画面表示自体に失敗したか。呼び出し側が「準備できなかった」と
    /// 「ユーザーが自分で閉じた」を区別するために使う。
    private(set) var presentationFailed = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// 報酬獲得コールバック(広告が閉じる前に呼ばれる)を記録しておく。
    func markRewardEarned() {
        earnedReward = true
    }

    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        presentationFailed = true
        finish()
    }

    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        finish()
    }

    /// 結果を一度だけ返す(失敗と閉じるが両方来ても継続を二重再開しない)。
    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: earnedReward)
    }
}
