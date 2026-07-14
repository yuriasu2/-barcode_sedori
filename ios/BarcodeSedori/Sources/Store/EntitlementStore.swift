import Foundation
import StoreKit

/// フリーミアムのPro状態を一元管理するストア(StoreKit 2)。
/// 全てのゲートはこの `isPro` を単一の真実として参照する。
///
/// - 起動時に `start()` を呼び、Transaction監視・現在のエンタイトルメント反映・商品情報読込を行う。
/// - `isPro` は `Transaction.currentEntitlements` から算出する(サブスク有効かつ未失効)。
/// - APIClient(非メインアクター・同期)から参照できるよう、`isPro` を UserDefaults にミラーする
///   (`isProCachedKey`)。ネットワークヘッダー `X-App-Plan` の付与に使う。
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    /// Proサブスクのプロダクト識別子。App Store Connect / `.storekit` の productID と一致させること。
    static let proProductID = "com.example.barcodesedori.pro.monthly"

    /// APIClient(非メインアクター)が同期で読むためのミラー用UserDefaultsキー。
    /// APIClient側でも同じ文字列を参照する。
    static let isProCachedKey = "settings.isProCached"

    /// Proが有効か。ゲートはこれを参照する。
    @Published private(set) var isPro: Bool = UserDefaults.standard.bool(forKey: EntitlementStore.isProCachedKey)
    /// Proサブスク商品(価格・トライアル表示に使う)。未ロード/未設定時は nil。
    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var purchaseInProgress = false

    private var updatesTask: Task<Void, Never>?

    private init() {}

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
        } catch {
            product = nil
        }
    }

    /// 現在有効なエンタイトルメントから `isPro` を再評価する。
    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.proProductID, transaction.revocationDate == nil {
                active = true
            }
        }
        setIsPro(active)
    }

    /// 購入フロー。成功で isPro を更新し true を返す。キャンセル/保留/失敗は false。
    @discardableResult
    func purchase() async -> Bool {
        guard let product else { return false }
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                    return isPro
                }
                return false
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    /// 購入の復元。App Storeと同期後にエンタイトルメントを再評価する。
    @discardableResult
    func restore() async -> Bool {
        do {
            try await AppStore.sync()
        } catch {
            // 同期に失敗しても currentEntitlements で判定を試みる
        }
        await refreshEntitlements()
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
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }
}
