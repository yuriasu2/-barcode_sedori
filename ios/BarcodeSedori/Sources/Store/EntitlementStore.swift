import Foundation
import StoreKit

/// フリーミアムのPro状態を一元管理するストア(StoreKit 2)。
/// 全てのゲートはこの `isPro` を単一の真実として参照する。
///
/// - 起動時に `start()` を呼び、Transaction監視・現在のエンタイトルメント反映・商品情報読込を行う。
/// - `isPro` は `Transaction.currentEntitlements` から算出する(サブスク有効かつ未失効)。
/// - APIClient(非メインアクター・同期)から参照できるよう、`isPro` を UserDefaults にミラーする
///   (`isProCachedKey`)。APIの利用資格はBillingClientで別途検証する。
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    /// Proサブスクのプロダクト識別子。App Store Connect / `.storekit` の productID と一致させること。
    static let proProductID = "jp.sellira.sellerlens.pro.monthly"

    /// APIClient(非メインアクター)が同期で読むためのミラー用UserDefaultsキー。
    /// APIClient側でも同じ文字列を参照する。
    static let isProCachedKey = "settings.isProCached"

    /// Proが有効か。ゲートはこれを参照する。
    @Published private(set) var isPro: Bool = UserDefaults.standard.bool(forKey: EntitlementStore.isProCachedKey)

    /// Proサブスク商品(価格・無料体験の表示に使う)。未ロード/未設定時は nil。
    @Published private(set) var product: Product?

    /// この購入者がサブスクの導入オファー(7日間無料)を受けられるか。
    /// StoreKitがApple ID単位・サブスクグループ単位で判定する(=同じグループで一度でも
    /// 導入オファーを使っていればfalse)。読み込み前・非対象時はfalseに倒す。
    ///
    /// かつて存在した「Amazon連携で7日間Proお試し」(SettingsStore.isSpApiTrialActive)は
    /// App Store審査のGuideline 5.6を受けて廃止し、無料体験はStoreKit標準の導入オファーへ
    /// 一本化した。そのため無料体験中も通常の課金者と同じく`isPro`がtrueになり、
    /// ゲートは`isPro`だけを見ればよい(旧`isProOrTrial`は不要になったので削除した)。
    @Published private(set) var isEligibleForIntroOffer = false
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var purchaseInProgress = false
    @Published private(set) var isPurchaseSyncPending = false
    /// 購入・復元の失敗時に表示する日本語メッセージ。表示後は呼び出し側でnilに戻すこと。
    @Published var lastActionErrorMessage: String?
    /// 商品情報読込(`loadProduct()`)の診断情報。原因切り分け用で、購入・復元用の
    /// `lastActionErrorMessage` とは用途が異なるため別プロパティにしている。
    /// 成功時は nil。空配列が返った場合は問い合わせた商品IDを、エラー発生時は
    /// `error.localizedDescription` を含める。
    @Published private(set) var productLoadDiagnostic: String?

    /// 「最初の7日間無料」のような無料体験の表示文言。
    /// 商品未取得・導入オファー未設定・この購入者が対象外のいずれかならnil(=何も出さない)。
    /// 期間はApp Store Connect側の設定を正として読み取る(アプリ側に日数を焼き込まない。
    /// ここを固定値にすると、後でオファーを14日に変えたときに表示だけ嘘になる)。
    var introOfferText: String? {
        guard isEligibleForIntroOffer,
              let offer = product?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        return "最初の\(Self.periodText(offer.period))無料"
    }

    /// サブスク期間を日本語にする(1週間は「7日間」と読み替える。App Store Connectで
    /// 7日間の無料体験を設定すると .week/1 として返るため、そのままだと「1週間無料」になり
    /// 審査メモや説明文の「7日間」と表記が揺れる)。
    private static func periodText(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: return "\(period.value)日間"
        case .week: return "\(period.value * 7)日間"
        case .month: return "\(period.value)か月間"
        case .year: return "\(period.value)年間"
        @unknown default: return "\(period.value)期間"
        }
    }

    private var updatesTask: Task<Void, Never>?

    #if DEBUG
    /// 開発ビルド専用のPro強制フラグ。シミュレータではStoreKitの実購入ができず
    /// Pro限定画面(利益アラート設定・出品フォーム等)を一切検証できないため、開発時のみ上書きできるようにする。
    /// `#if DEBUG` で囲っているためReleaseビルドには存在せず、消し忘れて出荷する事故は起きない。
    static let debugForceProKey = "settings.debugForcePro"

    /// 開発用トグルの現在値。オンにすると実際のエンタイトルメントに関わらずProとして扱う。
    var debugForcePro: Bool {
        get { UserDefaults.standard.bool(forKey: Self.debugForceProKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.debugForceProKey)
            // 即座に反映する(オフに戻したときは実エンタイトルメントで再評価)。
            if newValue {
                setIsPro(true)
            } else {
                Task { await refreshEntitlements() }
            }
        }
    }
    #endif

    private init() {}

    func serverSynchronizationCompleted() {
        isPurchaseSyncPending = false
        if lastActionErrorMessage == BillingClient.Pending().localizedDescription {
            lastActionErrorMessage = nil
        }
    }

    /// アプリ起動時に一度呼ぶ。
    func start() {
        if updatesTask == nil {
            updatesTask = listenForTransactions()
        }
        Task {
            await refreshEntitlements()
            await loadProduct()
        }
    }

    /// Pro商品情報を読み込む(価格・トライアルの表示用)。
    func loadProduct() async {
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            let products = try await Product.products(for: [Self.proProductID])
            product = products.first
            if let product {
                productLoadDiagnostic = nil
                // 適格性の判定はStoreKitへの問い合わせを伴うため、商品取得と同じ場所でまとめて行う。
                isEligibleForIntroOffer = await product.subscription?.isEligibleForIntroOffer ?? false
                #if DEBUG
                print("[EntitlementStore] loadProduct: productID=\(Self.proProductID) 取得数=\(products.count) 取得商品ID=\(product.id) 表示価格=\(product.displayPrice)")
                #endif
            } else {
                isEligibleForIntroOffer = false
                // Product.products(for:) は商品IDが存在しない場合でもエラーを投げず、
                // 空配列を返す。通信エラーと区別できるよう、商品IDを含めて記録する。
                //
                // 診断文言(商品ID込み)の生成自体を #if DEBUG で囲む。表示側(PaywallView)を
                // DEBUG限定にするだけでは、文字列リテラル自体はReleaseバイナリにも残ってしまうため、
                // 本番ユーザー向けの情報として不要な生の診断情報をバイナリに含めないよう、
                // ここで生成そのものを止める。
                #if DEBUG
                productLoadDiagnostic = "商品が見つかりません(問い合わせた商品ID: \(Self.proProductID))"
                print("[EntitlementStore] loadProduct: productID=\(Self.proProductID) 取得数=0(商品が見つかりません)")
                #endif
            }
        } catch {
            product = nil
            isEligibleForIntroOffer = false
            #if DEBUG
            productLoadDiagnostic = "商品情報の取得に失敗しました(問い合わせた商品ID: \(Self.proProductID)): \(error.localizedDescription)"
            print("[EntitlementStore] loadProduct: productID=\(Self.proProductID) エラー=\(error.localizedDescription)")
            #endif
        }
    }

    /// 現在有効なエンタイトルメントから `isPro` を再評価する。
    func refreshEntitlements() async {
        #if DEBUG
        // 開発用のPro強制がオンの間は実エンタイトルメントで上書きしない
        // (StoreKitの監視や起動時の再評価でfalseへ戻ってしまうのを防ぐ)。
        if debugForcePro {
            setIsPro(true)
            return
        }
        #endif

        var active = false
        var pending = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.proProductID, transaction.revocationDate == nil {
                active = true
                do {
                    _ = try await BillingClient.shared.synchronize(result.jwsRepresentation)
                    await transaction.finish()
                } catch {
                    pending = true
                }
            }
        }
        setIsPro(active)
        isPurchaseSyncPending = pending
        if !active { BillingClient.shared.clearAccess() }
    }

    /// 購入フロー。成功で isPro を更新し true を返す。キャンセル/保留/失敗は false。
    @discardableResult
    func purchase() async -> Bool {
        guard let product else { return false }
        purchaseInProgress = true
        lastActionErrorMessage = nil
        defer { purchaseInProgress = false }
        do {
            let accountToken = try await BillingClient.shared.appAccountToken()
            let result = try await product.purchase(options: [.appAccountToken(accountToken)])
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    setIsPro(transaction.revocationDate == nil)
                    do {
                        let serverPro = try await BillingClient.shared.synchronize(verification.jwsRepresentation)
                        await transaction.finish()
                        isPurchaseSyncPending = !serverPro
                    } catch {
                        // Remains unfinished in StoreKit and retries on launch/updates/API use.
                        isPurchaseSyncPending = true
                    }
                    if isPurchaseSyncPending {
                        lastActionErrorMessage = BillingClient.Pending().localizedDescription
                        return false
                    }
                    if isPro {
                        Analytics.shared.capture(.proPurchased)
                    }
                    return isPro
                }
                lastActionErrorMessage = "購入を完了できませんでした。通信環境をご確認のうえ再度お試しください。"
                return false
            case .userCancelled:
                // ユーザーキャンセルはエラー扱いにしない
                return false
            case .pending:
                lastActionErrorMessage = "購入は承認待ちです。完了後に自動で反映されます。"
                return false
            @unknown default:
                lastActionErrorMessage = "購入を完了できませんでした。通信環境をご確認のうえ再度お試しください。"
                return false
            }
        } catch {
            lastActionErrorMessage = "購入を完了できませんでした。通信環境をご確認のうえ再度お試しください。"
            return false
        }
    }

    /// 購入の復元。App Storeと同期後にエンタイトルメントを再評価する。
    @discardableResult
    func restore() async -> Bool {
        lastActionErrorMessage = nil
        do {
            try await AppStore.sync()
        } catch {
            // 同期に失敗しても currentEntitlements で判定を試みるが、失敗はユーザーに伝える
            lastActionErrorMessage = "復元を完了できませんでした。通信環境をご確認のうえ再度お試しください。"
        }
        await refreshEntitlements()
        if isPurchaseSyncPending {
            lastActionErrorMessage = BillingClient.Pending().localizedDescription
            return false
        } else if isPro {
            lastActionErrorMessage = nil
        }
        return isPro
    }

    private func setIsPro(_ value: Bool) {
        isPro = value
        // APIClientが同期で読めるようミラーする
        UserDefaults.standard.set(value, forKey: Self.isProCachedKey)
    }

    /// バックグラウンドで購読状態の変化(更新・失効・返金)を監視し、都度 isPro を再評価する。
    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == Self.proProductID else { continue }
                do {
                    _ = try await BillingClient.shared.synchronize(result.jwsRepresentation)
                    await transaction.finish()
                } catch { self?.isPurchaseSyncPending = true }
                await self?.refreshEntitlements()
            }
        }
    }
}
