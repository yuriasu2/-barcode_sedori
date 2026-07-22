# 仕入れリスト(Phase 1b)+アプリ内出品(Phase 2) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- 作成: 2026-07-22 / 計画: Fable5
- 対象スペック: `docs/superpowers/specs/2026-07-19-listing-and-profit-alert-design.md` の Phase 1b / Phase 2 節
- 状態: **計画済み・実装未着手**

**Goal:** 仕入れリスト(端末ローカル保存)を実体化し、Pro+SP-API連携ユーザーがアプリ内から自己発送(MFN)のオファー出品を完結できるようにする。

**Architecture:** iOSは既存のScanHistoryStoreと同方式(Documents配下JSON)でPurchaseListStoreを新設し、仕入れタブ→出品フォーム(ListingFormView)→サーバー新API(`GET /api/listings/restrictions` / `POST /api/listings`)の流れ。サーバーはBYOリフレッシュトークン(X-Spapi-Refresh-Token)でSellers APIからsellerIdを解決(トークンハッシュキーのインメモリキャッシュのみ許容)し、Listings Restrictions API / Listings Items API(putListingsItem)を呼ぶ。トークン・出品内容はサーバーに保存しない(DPP整合)。

**Tech Stack:** iOS 16.0+ / SwiftUI / StoreKit 2(既存EntitlementStore) / Cloudflare Workers互換のNode依存ゼロサーバー(MiniRouter) / node:test + globalなfetchモック

## 承認済みのspecからの逸脱(確定事項・再検討不要)

1. **「仕入れリストへ追加」ボタンの設置場所**: specでは商品詳細画面のみだが、商品詳細はSP-API経路のオファーパネルタップでしか開けず、Keepa経路ユーザーが到達できない。そのため**最新スキャン結果カード(SearchTabViewのLatestResultCardView)にも追加ボタンを置く**(Pro限定)。商品詳細画面にも置く(spec通り)。
2. sellerId解決: Listings Restrictions APIがsellerId必須のため、サーバーでSellers API `GET /sellers/v1/marketplaceParticipations` をBYOトークンで呼んでsellerIdを取得し、**トークンハッシュをキーにインメモリキャッシュする**(保存はこのキャッシュのみ許容)。
3. 出品フォームのコンディション選択はspec通り**中古4種(ほぼ新品/非常に良い/良い/可)のみ**。サーバー側の受理ホワイトリストは将来用に `new_new` も含む5種とする。

## ユーザーが実施する前提作業(コード実装より先。エージェントは実施不可)

出品制限確認のためのセラーID取得のロール(Sellers)は**取得済み**(ユーザー確認済み)。それを踏まえ、着手前に以下をユーザー自身がAmazon Developer Console / Seller Centralで行う:

1. **Developer Consoleでアプリに「Product Listing」ロールを追加する**(Sellersロールが未追加ならそれも)。
2. **本人アカウントの再認可(Re-Authorize)**: ロールを追加すると、**既存の連携済みユーザー全員が再認可必要**になる("anytime you add a role to your application")。現在は開発者本人の検証用連携のみのため影響は本人だけ。アプリの設定タブ→「連携を解除」→「SP-API認証を開始」で再連携し、新しいリフレッシュトークンを取得する。
3. 再認可後、設定タブの「接続テスト」で疎通を確認する。

上記が済むまで、Task 5以降の実機での結合確認(Task 10)は成功しない(実装・単体テストはモックで進められる)。

## Global Constraints

- iOS deployment target: **iOS 16.0+**。既存作法(NavigationView + .stack、シングルトンStore、@Published + didSetでUserDefaults永続化)に従う。
- コード内コメント・UI文言・コミットメッセージは**日本語**。既存ファイルのコメント様式(「なぜ」を書く)を踏襲。
- サーバーは**依存ゼロ構成を維持**(express等の追加禁止)。テストは `node:test` + `assert/strict`、実行は `cd server && npm test`。
- **Keepaトークン消費を1つも増やさない**(本計画の全タスクでKeepa APIは一切呼ばない)。
- **`/api/search` / `/api/offers` の既存レスポンス契約は不変**(フィールド追加・変更なし)。
- **リフレッシュトークン・出品内容をサーバーに保存しない**。許されるのはsellerIdのインメモリキャッシュ(キーはトークンのSHA256ハッシュ)のみ。
- マーケットプレイスIDは既存 `server/src/spapi/client.js` の `getMarketplaceId()`(env `MARKETPLACE_ID`、既定 `A1VC38T7YXB528`)を使う。ハードコード禁止。
- iOSにテストターゲットは無い。iOSタスクの完了条件は**xcodebuildビルド成功+シミュレータ起動+スクリーンショット確認**(メモリ`verify-ios-in-simulator`のとおり)。純粋関数はswiftc単体コンパイル+実行で検証する(ProfitAlertEvaluatorと同方式)。
  - ビルド: `cd "ios/BarcodeSedori" && xcodebuild -project BarcodeSedori.xcodeproj -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - シミュレータ: iPhone 17 UDID `4603FFE1-E015-44F2-AA19-5BA2942B5F26`
- 変更完了ごとに確認なしでコミットする(メモリ`auto-commit-after-changes`)。
- サーバーは手動デプロイ(pushだけでは反映されない。メモリ`server-deploy-is-manual`)。結合確認前にユーザーへデプロイを依頼する。

---

## Task 1: PurchaseListItem モデル + PurchaseListStore(iOS・Phase 1b)

**Files:**
- Create: `ios/BarcodeSedori/Sources/Models/PurchaseListItem.swift`
- Create: `ios/BarcodeSedori/Sources/Store/PurchaseListStore.swift`

**Interfaces:**
- Consumes: `SearchResult` / `OffersResult`(既存 `Models/SearchModels.swift` / `Models/OffersModels.swift`)
- Produces:
  - `struct PurchaseListItem: Codable, Equatable, Identifiable` — `id: UUID`, `addedAt: Date`, `asin: String`, `title: String?`, `imageUrl: String?`, `scannedCode: String?`, `isbn13: String?`, `salesRank: Int?`, `offersResult: OffersResult?`, `isListed: Bool`, `listedSku: String?`, `listedAt: Date?`
  - `final class PurchaseListStore: ObservableObject` — `static let shared`, `@Published private(set) var items: [PurchaseListItem]`, `func add(_:)`, `func remove(atOffsets:)`, `func markListed(id:sku:)`, `func contains(asin:) -> Bool`

- [ ] **Step 1: PurchaseListItem.swift を作成**

```swift
import Foundation

/// 「仕入れ」タブに表示する仕入れリストの1件(Phase 1b)。
/// 保存は端末ローカルのみ(スキャン履歴と同じDocuments配下JSON方式)。サーバーには置かない
/// (プライバシーポリシー「履歴は端末内のみ」と整合させるため)。
struct PurchaseListItem: Codable, Equatable, Identifiable {
    let id: UUID
    let addedAt: Date
    /// 出品対象のASIN。ASINが無い商品は仕入れリストに追加できない(追加ボタン自体を出さない)。
    let asin: String
    let title: String?
    let imageUrl: String?
    /// スキャンしたコード(検索カード経由)。商品詳細経由はjanCodeを入れる。表示用。
    let scannedCode: String?
    let isbn13: String?
    let salesRank: Int?
    /// 追加時点のオファー一覧スナップショット。出品フォームの初期価格(同コンディション最安landed)に使う。
    /// 追加時点で未取得ならnil(フォーム表示時に/api/offersで再取得するため出品は可能)。
    var offersResult: OffersResult?
    /// 出品済みフラグ(Phase 2)。putListingsItemがACCEPTEDで受理されたらtrueにする。
    var isListed: Bool
    /// 出品に使ったSKU(出品済みのときのみ)。
    var listedSku: String?
    /// 出品受理日時(出品済みのときのみ)。
    var listedAt: Date?

    init(
        id: UUID = UUID(),
        addedAt: Date = Date(),
        asin: String,
        title: String?,
        imageUrl: String?,
        scannedCode: String?,
        isbn13: String?,
        salesRank: Int?,
        offersResult: OffersResult? = nil,
        isListed: Bool = false,
        listedSku: String? = nil,
        listedAt: Date? = nil
    ) {
        self.id = id
        self.addedAt = addedAt
        self.asin = asin
        self.title = title
        self.imageUrl = imageUrl
        self.scannedCode = scannedCode
        self.isbn13 = isbn13
        self.salesRank = salesRank
        self.offersResult = offersResult
        self.isListed = isListed
        self.listedSku = listedSku
        self.listedAt = listedAt
    }

    /// 検索タブの最新結果カードから追加する場合のコンビニエンスinit。
    init(result: SearchResult, scannedCode: String?, offersResult: OffersResult?) {
        self.init(
            asin: result.asin ?? "",
            title: result.title,
            imageUrl: result.imageUrl,
            scannedCode: scannedCode,
            isbn13: result.isbn13,
            salesRank: result.salesRank,
            offersResult: offersResult
        )
    }
}
```

- [ ] **Step 2: PurchaseListStore.swift を作成(ScanHistoryStoreと同方式)**

```swift
import Foundation
import Combine

/// 「仕入れ」タブの仕入れリストをファイル(Documents配下のJSON)に永続化する。
/// ScanHistoryStoreと同じ方式(端末ローカルのみ・サーバー保存なし)。
final class PurchaseListStore: ObservableObject {
    static let shared = PurchaseListStore()

    @Published private(set) var items: [PurchaseListItem] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        self.fileURL = (documents ?? fileManager.temporaryDirectory).appendingPathComponent("purchase_list.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    func add(_ item: PurchaseListItem) {
        items.insert(item, at: 0)
        save()
    }

    /// スワイプ削除(ForEach.onDelete)用。
    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    /// 出品受理(ACCEPTED)時に呼ぶ。該当項目に出品済みマークとSKUを付ける。
    func markListed(id: UUID, sku: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isListed = true
        items[index].listedSku = sku
        items[index].listedAt = Date()
        save()
    }

    /// 同一ASINが既にリストにあるか(追加ボタンの「追加済み」表示に使う)。
    func contains(asin: String) -> Bool {
        items.contains { $0.asin == asin }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([PurchaseListItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 3: ビルドして成功を確認**

Run: `cd "ios/BarcodeSedori" && xcodebuild -project BarcodeSedori.xcodeproj -scheme BarcodeSedori -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`(project.ymlはSources配下を自動取り込みするXcodeGen構成。ビルドが新ファイルを認識しない場合のみ `xcodegen generate` を実行)

- [ ] **Step 4: コミット**

```bash
git add ios/BarcodeSedori/Sources/Models/PurchaseListItem.swift ios/BarcodeSedori/Sources/Store/PurchaseListStore.swift
git commit -m "仕入れリストのモデルとローカル永続化ストアを追加(Phase 1b)"
```

---

## Task 2: PurchaseTabView 実体化(iOS・Phase 1b)

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/PurchaseTabView.swift`(全面置き換え)

**Interfaces:**
- Consumes: `PurchaseListStore.shared`(Task 1) / `EntitlementStore.shared.isPro`
- Produces: 仕入れタブの一覧UI。Task 9がこのファイルに「出品」導線を追記する(この時点では出品ボタンなし)。

- [ ] **Step 1: PurchaseTabView.swift を置き換え**

```swift
import SwiftUI

/// 「仕入れ」タブ(Phase 1b): 仕入れリストの一覧・スワイプ削除・出品済みマーク。
/// 「出品」導線(Pro+SP-API連携時のみ)はPhase 2(ListingFormView)で追加する。
struct PurchaseTabView: View {
    @ObservedObject private var store = PurchaseListStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared

    var body: some View {
        NavigationView {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("仕入れ")
        }
        .navigationViewStyle(.stack)
    }

    /// リストが空のときの案内。追加ボタンの場所(検索結果カード)へ誘導する。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cart.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("仕入れリストは空です")
                .foregroundColor(.secondary)
            Text("検索タブのスキャン結果カードから追加できます(Pro)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var listContent: some View {
        List {
            ForEach(store.items) { item in
                PurchaseListRow(item: item)
            }
            .onDelete { offsets in
                store.remove(atOffsets: offsets)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// 仕入れリストの1行。サムネイル+タイトル+追加日+出品済みバッジ。
struct PurchaseListRow: View {
    let item: PurchaseListItem

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: item.imageUrl.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Image(systemName: "photo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    Color.clear
                }
            }
            .frame(width: 56, height: 56)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "(タイトル不明)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: item.addedAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let rank = item.salesRank {
                        Text("ランク: \(rank)位")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if item.isListed {
                    // 出品受理済みマーク(Phase 2: markListedで付与される)。
                    Label("出品済み", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: ビルド+シミュレータ確認**

Run: ビルドコマンド(Global Constraints記載) → `xcrun simctl boot 4603FFE1-E015-44F2-AA19-5BA2942B5F26`(既起動ならスキップ) → install → `xcrun simctl launch 4603FFE1-E015-44F2-AA19-5BA2942B5F26 com.example.barcodesedori` → 仕入れタブを開いたスクリーンショットを撮って目視。
Expected: 空状態の案内が表示される(この時点ではリストは空)。

- [ ] **Step 3: コミット**

```bash
git add ios/BarcodeSedori/Sources/Views/PurchaseTabView.swift
git commit -m "仕入れタブを実体化(一覧・スワイプ削除・出品済みマーク)"
```

---

## Task 3: 「仕入れリストへ追加」ボタン(検索結果カード+商品詳細、Pro限定)

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Views/SearchTabView.swift`(`latestResultCard` の呼び出しと `LatestResultCardView`)
- Modify: `ios/BarcodeSedori/Sources/Views/ProductDetailView.swift`(商品情報セクションに追加ボタン)

**Interfaces:**
- Consumes: `PurchaseListStore.shared.add(_:)` / `.contains(asin:)`(Task 1)、`PurchaseListItem(result:scannedCode:offersResult:)`
- Produces: なし(UIのみ)

- [ ] **Step 1: SearchTabView — LatestResultCardViewに追加ボタンを付ける**

`LatestResultCardView` にプロパティを2つ追加し、呼び出し側から渡す。

呼び出し側(`latestResultCard` 内の `LatestResultCardView(...)`)を以下に変更:

```swift
        } else if let result = viewModel.latestResult {
            LatestResultCardView(
                result: result,
                scannedCode: viewModel.latestScannedCode ?? "",
                profitVerdict: viewModel.profitAlertVerdict,
                isPro: entitlements.isPro,
                isInPurchaseList: result.asin.map { purchaseList.contains(asin: $0) } ?? false,
                onAddToPurchaseList: {
                    guard let asin = result.asin, !asin.isEmpty else { return }
                    purchaseList.add(PurchaseListItem(
                        result: result,
                        scannedCode: viewModel.latestScannedCode,
                        offersResult: viewModel.offersResult
                    ))
                }
            )
        } else if let errorMessage = viewModel.searchErrorMessage {
```

`SearchTabView` のプロパティ群(`@ObservedObject private var entitlements` の直後)に追加:

```swift
    /// 仕入れリスト(Phase 1b)。「追加済み」表示の再描画のため監視する。
    @ObservedObject private var purchaseList = PurchaseListStore.shared
```

`LatestResultCardView` のプロパティに追加(`let isPro: Bool` の直後):

```swift
    /// 仕入れリストに追加済みか(追加済みならボタンを無効化して「追加済み」表示)。
    let isInPurchaseList: Bool
    /// 「仕入れリストへ追加」タップ時の処理。Pro限定表示のため非Proでは使われない。
    let onAddToPurchaseList: () -> Void
```

`LatestResultCardView.body` の `VStack` 内、`cardContent` の直後に追加:

```swift
            // 仕入れリストへ追加(Pro限定・ASINがある場合のみ)。
            // specでは商品詳細画面だが、Keepa経路ユーザーは商品詳細に到達できないため
            // 最新スキャン結果カードにも置く(承認済み逸脱)。
            if isPro && result.asin != nil && result.codeType != .unresolved {
                addToPurchaseListButton
            }
```

`LatestResultCardView` に computed property を追加(`profitAlertBanner` の直後):

```swift
    /// 「仕入れリストへ追加」ボタン。追加済みはチェックマーク+無効化。
    private var addToPurchaseListButton: some View {
        Button {
            onAddToPurchaseList()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isInPurchaseList ? "checkmark.circle.fill" : "cart.badge.plus")
                Text(isInPurchaseList ? "仕入れリストに追加済み" : "仕入れリストへ追加")
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(isInPurchaseList ? .secondary : .white)
            .background(isInPurchaseList ? Color(.secondarySystemBackground) : Color.accentColor)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isInPurchaseList)
    }
```

- [ ] **Step 2: ProductDetailView — 商品情報セクションに追加ボタン(Pro限定)**

`ProductDetailView` にプロパティを追加(`let janCode: String?` の直後):

```swift
    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var purchaseList = PurchaseListStore.shared
```

`productInfoSection` の `Section("商品情報") { ... }` 末尾(発売日行の直後)に追加:

```swift
            // 仕入れリストへ追加(Pro限定・spec Phase 1b)。
            // 商品詳細は画像URLを保持していないためimageUrlはnil(仕入れタブではプレースホルダ表示)。
            if entitlements.isPro {
                Button {
                    purchaseList.add(PurchaseListItem(
                        asin: viewModel.asin,
                        title: title,
                        imageUrl: nil,
                        scannedCode: janCode,
                        isbn13: nil,
                        salesRank: nil,
                        offersResult: viewModel.offers
                    ))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: purchaseList.contains(asin: viewModel.asin) ? "checkmark.circle.fill" : "cart.badge.plus")
                        Text(purchaseList.contains(asin: viewModel.asin) ? "仕入れリストに追加済み" : "仕入れリストへ追加")
                    }
                }
                .disabled(purchaseList.contains(asin: viewModel.asin))
            }
```

- [ ] **Step 3: ビルド+シミュレータ確認**

Run: ビルド→起動→検索バーに実在ISBN(例: 9784873119045)を入力して検索→結果カードに「仕入れリストへ追加」が出ることを確認→タップ→「追加済み」表示→仕入れタブに行が出ることをスクリーンショットで確認。無料プラン相当ではボタンが出ないこと(EntitlementStoreはStoreKit依存のため、シミュレータでの無料/Pro切替は`.storekit`のサブスク購入/解約で行う)。
Expected: 追加→仕入れタブ反映→スワイプ削除が動作。カメラ非依存(検索バー入力)で確認可能。

- [ ] **Step 4: コミット**

```bash
git add ios/BarcodeSedori/Sources/Views/SearchTabView.swift ios/BarcodeSedori/Sources/Views/ProductDetailView.swift
git commit -m "仕入れリストへ追加ボタンを結果カードと商品詳細に追加(Pro限定)"
```

---

## Task 4: サーバー sellerId解決モジュール(sellers.js)— TDD

**Files:**
- Create: `server/src/spapi/sellers.js`
- Test: `server/test/sellers.test.js`

**Interfaces:**
- Consumes: `callSpApi({ method, path, query, body, credentials })` / `getMarketplaceId()`(`server/src/spapi/client.js`)、`LruCache`(`server/src/cache.js`)
- Produces:
  - `async function resolveSellerId(credentials) -> Promise<string>`(解決失敗はErrorをthrow)
  - `function extractSellerId(response, marketplaceId) -> string|null`(純粋関数・テスト用にexport)
  - `function clearCache()`(テスト用)

- [ ] **Step 1: 失敗するテストを書く(server/test/sellers.test.js)**

```js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

async function withEnv(vars, fn) {
  const saved = {};
  for (const key of Object.keys(vars)) {
    saved[key] = process.env[key];
    if (vars[key] === undefined) delete process.env[key];
    else process.env[key] = vars[key];
  }
  try {
    return await fn();
  } finally {
    for (const key of Object.keys(saved)) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

function freshSellers() {
  delete require.cache[require.resolve('../src/spapi/sellers')];
  return require('../src/spapi/sellers');
}

// --- extractSellerId 単体 ---

test('extractSellerId: 対象マーケットプレイスのsellerIdを返す(トップレベルsellerId形式)', () => {
  const sellers = freshSellers();
  const response = {
    payload: [
      { sellerId: 'SELLER_US', marketplace: { id: 'ATVPDKIKX0DER' }, participation: { isParticipating: true } },
      { sellerId: 'SELLER_JP', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
    ],
  };
  assert.equal(sellers.extractSellerId(response, 'A1VC38T7YXB528'), 'SELLER_JP');
});

test('extractSellerId: participation配下にsellerIdがある形式にも対応する', () => {
  const sellers = freshSellers();
  const response = {
    payload: [
      { marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true, sellerId: 'SELLER_JP2' } },
    ],
  };
  assert.equal(sellers.extractSellerId(response, 'A1VC38T7YXB528'), 'SELLER_JP2');
});

test('extractSellerId: 対象マーケットプレイスが無ければ先頭エントリで代替、payloadが空/欠落はnull', () => {
  const sellers = freshSellers();
  const response = {
    payload: [{ sellerId: 'SELLER_ONLY', marketplace: { id: 'OTHER' }, participation: {} }],
  };
  assert.equal(sellers.extractSellerId(response, 'A1VC38T7YXB528'), 'SELLER_ONLY');
  assert.equal(sellers.extractSellerId({ payload: [] }, 'A1VC38T7YXB528'), null);
  assert.equal(sellers.extractSellerId({}, 'A1VC38T7YXB528'), null);
  assert.equal(sellers.extractSellerId(null, 'A1VC38T7YXB528'), null);
});

// --- resolveSellerId(fetchモック + キャッシュ) ---

test('resolveSellerId: Sellers APIからsellerIdを解決し、同一トークンの2回目はキャッシュで返す(fetch回数増えない)', async () => {
  await withEnv({ LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' }, async () => {
    const sellers = freshSellers();
    const originalFetch = global.fetch;
    let tokenCalls = 0;
    let apiCalls = 0;
    global.fetch = async (url) => {
      const u = String(url);
      if (u.includes('api.amazon.com/auth/o2/token')) {
        tokenCalls += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({ access_token: 'at-1', expires_in: 3600 }),
          text: async () => '',
          headers: { get: () => null },
        };
      }
      if (u.includes('/sellers/v1/marketplaceParticipations')) {
        apiCalls += 1;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            payload: [
              { sellerId: 'A3EXAMPLE', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
            ],
          }),
          text: async () => '',
          headers: { get: () => null },
        };
      }
      throw new Error(`unexpected fetch: ${u}`);
    };
    try {
      const credentials = { clientId: 'cid', clientSecret: 'sec', refreshToken: 'rt-cache-test' };
      const first = await sellers.resolveSellerId(credentials);
      const second = await sellers.resolveSellerId(credentials);
      assert.equal(first, 'A3EXAMPLE');
      assert.equal(second, 'A3EXAMPLE');
      assert.equal(apiCalls, 1); // 2回目はキャッシュ
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('resolveSellerId: sellerIdが応答から取れない場合はエラーをthrowする', async () => {
  await withEnv({ LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' }, async () => {
    const sellers = freshSellers();
    const originalFetch = global.fetch;
    global.fetch = async (url) => {
      const u = String(url);
      if (u.includes('api.amazon.com/auth/o2/token')) {
        return {
          ok: true, status: 200,
          json: async () => ({ access_token: 'at-2', expires_in: 3600 }),
          text: async () => '', headers: { get: () => null },
        };
      }
      return {
        ok: true, status: 200,
        json: async () => ({ payload: [] }),
        text: async () => '', headers: { get: () => null },
      };
    };
    try {
      await assert.rejects(
        () => sellers.resolveSellerId({ clientId: 'cid', clientSecret: 'sec', refreshToken: 'rt-empty' }),
        /seller_id_not_found/
      );
    } finally {
      global.fetch = originalFetch;
    }
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd server && node --test test/sellers.test.js`
Expected: FAIL(`Cannot find module '../src/spapi/sellers'`)

- [ ] **Step 3: sellers.js を実装**

```js
'use strict';

/**
 * Sellers API (getMarketplaceParticipations) による sellerId 解決 + インメモリキャッシュ。
 *
 * Listings Restrictions API / Listings Items API は sellerId が必須だが、
 * アプリはBYOリフレッシュトークンしか持たないため、サーバーがSellers APIで解決する。
 * DPP整合のため保存はインメモリキャッシュのみ(キーはリフレッシュトークンのSHA256ハッシュ。
 * トークン本体をキーにも値にも保持しない)。プロセス再起動で消える揮発キャッシュで良い
 * (sellerIdは不変のため再取得コストはSellers API 1回のみ)。
 */

const crypto = require('crypto');

const { callSpApi, getMarketplaceId } = require('./client');
const { LruCache } = require('../cache');

// sellerIdは実質不変のため長め(24時間)にキャッシュする。
const SELLER_ID_TTL_MS = 24 * 60 * 60 * 1000;
const sellerIdCache = new LruCache({ ttlMs: SELLER_ID_TTL_MS, maxSize: 500 });

/**
 * リフレッシュトークンからキャッシュキー(SHA256ハッシュ先頭16文字)を導出する。
 * トークン本体をキャッシュキーに含めないための一方向ハッシュ。
 */
function tokenHashKey(refreshToken) {
  return crypto.createHash('sha256').update(String(refreshToken)).digest('hex').slice(0, 16);
}

/**
 * getMarketplaceParticipations応答からsellerIdを抽出する(純粋関数)。
 * 応答形状の揺れに備え、トップレベル sellerId と participation.sellerId の両方を見る。
 * 対象マーケットプレイスのエントリを優先し、無ければ先頭エントリで代替する。
 * 取れなければnull。
 * @param {object|null} response Sellers APIレスポンス
 * @param {string} marketplaceId
 * @returns {string|null}
 */
function extractSellerId(response, marketplaceId) {
  const payload = (response && response.payload) || [];
  if (!Array.isArray(payload) || !payload.length) return null;
  const entry =
    payload.find((p) => p && p.marketplace && p.marketplace.id === marketplaceId) || payload[0];
  if (!entry) return null;
  const sellerId =
    entry.sellerId || (entry.participation && entry.participation.sellerId) || null;
  return typeof sellerId === 'string' && sellerId ? sellerId : null;
}

/**
 * BYO認証情報からsellerIdを解決する。キャッシュヒット時はSellers APIを呼ばない。
 * @param {{clientId:string, clientSecret:string, refreshToken:string}} credentials
 * @returns {Promise<string>}
 */
async function resolveSellerId(credentials) {
  const key = tokenHashKey(credentials.refreshToken);
  const cached = sellerIdCache.get(key);
  if (cached) return cached;

  const response = await callSpApi({
    method: 'GET',
    path: '/sellers/v1/marketplaceParticipations',
    credentials,
  });

  const sellerId = extractSellerId(response, getMarketplaceId());
  if (!sellerId) {
    const err = new Error('seller_id_not_found: Sellers API応答からsellerIdを取得できませんでした。Sellersロールの追加と再認可を確認してください。');
    err.code = 'seller_id_not_found';
    throw err;
  }

  sellerIdCache.set(key, sellerId);
  return sellerId;
}

/** テスト用: キャッシュをクリアする。 */
function clearCache() {
  sellerIdCache.map.clear();
}

module.exports = { resolveSellerId, extractSellerId, clearCache, tokenHashKey };
```

- [ ] **Step 4: テストがパスすることを確認**

Run: `cd server && node --test test/sellers.test.js`
Expected: PASS(5 tests)

- [ ] **Step 5: 既存テスト全体も通ることを確認してコミット**

Run: `cd server && npm test`
Expected: 全テストPASS

```bash
git add server/src/spapi/sellers.js server/test/sellers.test.js
git commit -m "Sellers APIによるsellerId解決とトークンハッシュキーのインメモリキャッシュを追加"
```

---

## Task 5: サーバー GET /api/listings/restrictions — TDD

**Files:**
- Create: `server/src/spapi/listings.js`
- Modify: `server/src/routes.js`(requireとルート追加)
- Test: `server/test/listings-routes.test.js`

**Interfaces:**
- Consumes: `resolveSellerId(credentials)`(Task 4)、既存 `isProRequest` / `resolveSpApiCredentials`、`callSpApi` / `getMarketplaceId`
- Produces:
  - `listings.getListingsRestrictions({ asin, sellerId, conditionType, credentials }) -> Promise<object>`(SP-API生応答)
  - `listings.putListingsItem({ sellerId, sku, body, credentials }) -> Promise<object>`(Task 6で使用)
  - HTTP: `GET /api/listings/restrictions?asin=&condition=` → 200 `{ restricted: boolean, message: string|null, approvalUrl: string|null }`
  - routes.js内ヘルパー: `requireProByoCredentials(req, res) -> credentials|null`、`summarizeRestrictions(response) -> {restricted, message, approvalUrl}`、`LISTING_CONDITION_TYPES`(Task 6でも使用)

- [ ] **Step 1: 失敗するテストを書く(server/test/listings-routes.test.js)**

```js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

async function withEnv(vars, fn) {
  const saved = {};
  for (const key of Object.keys(vars)) {
    saved[key] = process.env[key];
    if (vars[key] === undefined) delete process.env[key];
    else process.env[key] = vars[key];
  }
  try {
    return await fn();
  } finally {
    for (const key of Object.keys(saved)) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

function freshRoutes() {
  delete require.cache[require.resolve('../src/routes')];
  delete require.cache[require.resolve('../src/spapi/listings')];
  delete require.cache[require.resolve('../src/spapi/sellers')];
  delete require.cache[require.resolve('../src/deviceRateLimit')];
  return require('../src/routes');
}

function createMockRes() {
  return {
    statusCode: 200,
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

const ENV = { LWA_CLIENT_ID: 'cid', LWA_CLIENT_SECRET: 'sec' };

/**
 * LWAトークン + Sellers API + Listings系APIをまとめてモックするfetch。
 * handlers: { restrictions(url), putItem(url, init) } を上書き可能。
 */
function mockFetch(handlers = {}) {
  return async (url, init) => {
    const u = String(url);
    const ok = (jsonBody) => ({
      ok: true,
      status: 200,
      json: async () => jsonBody,
      text: async () => JSON.stringify(jsonBody),
      headers: { get: () => null },
    });
    if (u.includes('api.amazon.com/auth/o2/token')) {
      return ok({ access_token: 'at', expires_in: 3600 });
    }
    if (u.includes('/sellers/v1/marketplaceParticipations')) {
      return ok({
        payload: [
          { sellerId: 'SELLER123', marketplace: { id: 'A1VC38T7YXB528' }, participation: { isParticipating: true } },
        ],
      });
    }
    if (u.includes('/listings/2021-08-01/restrictions')) {
      return handlers.restrictions ? handlers.restrictions(u, ok) : ok({ restrictions: [] });
    }
    if (u.includes('/listings/2021-08-01/items/')) {
      return handlers.putItem ? handlers.putItem(u, init, ok) : ok({ status: 'ACCEPTED', submissionId: 'sub-1', issues: [] });
    }
    throw new Error(`unexpected fetch: ${u}`);
  };
}

// --- ゲート ---

test('restrictions: 無料は403 plan_required', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'plan_required');
});

test('restrictions: ProでもX-Spapi-Refresh-Tokenが無ければ403 spapi_link_required(.envトークンにフォールバックしない)', async () => {
  await withEnv({ ...ENV, LWA_REFRESH_TOKEN: 'env-rt' }, async () => {
    const routes = freshRoutes();
    const res = createMockRes();
    const route = routes.match('GET', '/api/listings/restrictions');
    await route.handler(
      { query: { asin: 'B000TEST', condition: 'used_good' }, headers: { 'x-app-plan': 'pro' } },
      res
    );
    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error, 'spapi_link_required');
  });
});

test('restrictions: asin欠落は400', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: {}, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 400);
});

// --- 正常系 ---

test('restrictions: 制限なしは restricted:false', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch();
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/listings/restrictions');
      await route.handler(
        {
          query: { asin: 'B000TEST', condition: 'used_good' },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-norestrict' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.body, { restricted: false, message: null, approvalUrl: null });
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('restrictions: 制限ありは理由メッセージと解除申請リンクを返し、リクエストURLにsellerId/conditionTypeが入る', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let requestedUrl = null;
    global.fetch = mockFetch({
      restrictions: (u, ok) => {
        requestedUrl = u;
        return ok({
          restrictions: [
            {
              marketplaceId: 'A1VC38T7YXB528',
              conditionType: 'used_good',
              reasons: [
                {
                  reasonCode: 'APPROVAL_REQUIRED',
                  message: 'この商品の出品には承認が必要です。',
                  links: [
                    { resource: 'https://sellercentral.amazon.co.jp/approval', verb: 'GET', title: 'Request Approval', type: 'text/html' },
                  ],
                },
              ],
            },
          ],
        });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('GET', '/api/listings/restrictions');
      await route.handler(
        {
          query: { asin: 'B000TEST', condition: 'used_good' },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-restricted' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.restricted, true);
      assert.equal(res.body.message, 'この商品の出品には承認が必要です。');
      assert.equal(res.body.approvalUrl, 'https://sellercentral.amazon.co.jp/approval');
      assert.ok(requestedUrl.includes('sellerId=SELLER123'));
      assert.ok(requestedUrl.includes('conditionType=used_good'));
      assert.ok(requestedUrl.includes('asin=B000TEST'));
      assert.ok(requestedUrl.includes('marketplaceIds=A1VC38T7YXB528'));
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('restrictions: condition不正値は400', async () => {
  const routes = freshRoutes();
  const res = createMockRes();
  const route = routes.match('GET', '/api/listings/restrictions');
  await route.handler(
    { query: { asin: 'B000TEST', condition: 'brand_new' }, headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' } },
    res
  );
  assert.equal(res.statusCode, 400);
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd server && node --test test/listings-routes.test.js`
Expected: FAIL(`Cannot find module '../src/spapi/listings'` またはルート未定義で `route.handler` がTypeError)

- [ ] **Step 3: listings.js を実装**

```js
'use strict';

/**
 * Listings Restrictions API / Listings Items API (2021-08-01) の薄い呼び出し層。
 * ロジック(ゲート・整形)はroutes.js側に置き、ここはSP-API呼び出しのみ担当する。
 */

const { callSpApi, getMarketplaceId } = require('./client');

/**
 * 出品制限を取得する。
 * GET /listings/2021-08-01/restrictions?asin=&sellerId=&marketplaceIds=&conditionType=
 * @param {{asin:string, sellerId:string, conditionType:string, credentials:object}} params
 * @returns {Promise<object>} SP-API生応答({ restrictions: [...] })
 */
async function getListingsRestrictions({ asin, sellerId, conditionType, credentials }) {
  return callSpApi({
    method: 'GET',
    path: '/listings/2021-08-01/restrictions',
    query: {
      asin,
      sellerId,
      marketplaceIds: getMarketplaceId(),
      conditionType,
    },
    credentials,
  });
}

/**
 * オファー出品(既存ASINへの相乗り)。
 * PUT /listings/2021-08-01/items/{sellerId}/{sku}?marketplaceIds=
 * @param {{sellerId:string, sku:string, body:object, credentials:object}} params
 * @returns {Promise<object>} SP-API生応答({ status, submissionId, issues })
 */
async function putListingsItem({ sellerId, sku, body, credentials }) {
  return callSpApi({
    method: 'PUT',
    path: `/listings/2021-08-01/items/${encodeURIComponent(sellerId)}/${encodeURIComponent(sku)}`,
    query: { marketplaceIds: getMarketplaceId() },
    body,
    credentials,
  });
}

module.exports = { getListingsRestrictions, putListingsItem };
```

- [ ] **Step 4: routes.js にゲートヘルパーとルートを追加**

requireブロック(`const deviceRateLimit = ...` の直後)に追加:

```js
const sellers = require('./spapi/sellers');
const listings = require('./spapi/listings');
```

定数(`const PLAN_REQUIRED_MESSAGE = ...` の直後)に追加:

```js
const SPAPI_LINK_REQUIRED_MESSAGE = '出品にはSP-API連携が必要です。設定タブでAmazon連携を行ってください。';

/**
 * 出品系APIが受理するconditionType(Listings Items APIのcondition_type値)。
 * アプリの出品フォームは中古4種のみだが、サーバーは将来用にnew_newも受理する。
 */
const LISTING_CONDITION_TYPES = [
  'new_new',
  'used_like_new',
  'used_very_good',
  'used_good',
  'used_acceptable',
];
```

`isProRequest` 定義の後にヘルパー2つを追加:

```js
/**
 * 出品系API共通ゲート: Pro + BYOトークン(X-Spapi-Refresh-Token)必須。
 * .envのLWA_REFRESH_TOKENにはフォールバックしない(他人のsellerで出品してしまう事故防止)。
 * 通過時はcredentialsを返し、弾いた場合はresへ403/503を書き込んでnullを返す。
 */
function requireProByoCredentials(req, res) {
  if (!isProRequest(req.headers)) {
    res.status(403).json({ error: 'plan_required', message: PLAN_REQUIRED_MESSAGE });
    return null;
  }
  const headerToken =
    req.headers && (req.headers['x-spapi-refresh-token'] || req.headers['X-Spapi-Refresh-Token']);
  if (!headerToken) {
    res.status(403).json({ error: 'spapi_link_required', message: SPAPI_LINK_REQUIRED_MESSAGE });
    return null;
  }
  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    // clientId/clientSecret未設定(サーバー構成不備)またはX-Disable-Spapi。
    res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
    return null;
  }
  return credentials;
}

/**
 * Listings Restrictions API応答をアプリ向けに要約する。
 * restrictionsが1件でもあれば制限あり。理由メッセージは全件を改行連結し、
 * 解除申請リンクは最初に見つかったlinks[].resourceを使う。
 */
function summarizeRestrictions(response) {
  const restrictions = (response && response.restrictions) || [];
  if (!Array.isArray(restrictions) || !restrictions.length) {
    return { restricted: false, message: null, approvalUrl: null };
  }
  const reasons = restrictions.flatMap((r) => (r && r.reasons) || []);
  const messages = reasons.map((r) => r && r.message).filter(Boolean);
  const links = reasons.flatMap((r) => (r && r.links) || []);
  const firstLink = links.find((l) => l && l.resource);
  return {
    restricted: true,
    message: messages.length ? messages.join('\n') : '出品制限があります。',
    approvalUrl: firstLink ? firstLink.resource : null,
  };
}
```

ルート(`router.get('/api/spapi/test', ...)` の直前)に追加:

```js
// GET /api/listings/restrictions?asin=&condition= — 出品制限の事前チェック(Pro+BYOトークン必須)
router.get('/api/listings/restrictions', async (req, res) => {
  const credentials = requireProByoCredentials(req, res);
  if (!credentials) return;

  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }
  const condition = String(req.query.condition || '').trim();
  if (!LISTING_CONDITION_TYPES.includes(condition)) {
    return res.status(400).json({ error: 'invalid_condition', message: `conditionは ${LISTING_CONDITION_TYPES.join(' / ')} のいずれかを指定してください` });
  }

  try {
    const sellerId = await sellers.resolveSellerId(credentials);
    const response = await listings.getListingsRestrictions({
      asin,
      sellerId,
      conditionType: condition,
      credentials,
    });
    res.json(summarizeRestrictions(response));
  } catch (err) {
    console.error(`[listings:restrictions] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'restrictions_failed', message: err.message });
  }
});
```

ファイル末尾のテスト用exportに追加:

```js
// テスト用途に出品系ヘルパーを公開する。
router.summarizeRestrictions = summarizeRestrictions;
router.LISTING_CONDITION_TYPES = LISTING_CONDITION_TYPES;
```

- [ ] **Step 5: テストがパスすることを確認**

Run: `cd server && node --test test/listings-routes.test.js`
Expected: PASS(6 tests)

- [ ] **Step 6: 既存テスト全体も通ることを確認してコミット**

Run: `cd server && npm test`
Expected: 全テストPASS

```bash
git add server/src/spapi/listings.js server/src/routes.js server/test/listings-routes.test.js
git commit -m "出品制限チェックAPI GET /api/listings/restrictions を追加(Pro+BYOトークン必須)"
```

---

## Task 6: サーバー POST /api/listings(putListingsItem)— TDD

**Files:**
- Modify: `server/src/routes.js`(ルート追加+ボディ組み立てヘルパー)
- Test: `server/test/listings-routes.test.js`(追記)

**Interfaces:**
- Consumes: `requireProByoCredentials` / `LISTING_CONDITION_TYPES`(Task 5)、`sellers.resolveSellerId`(Task 4)、`listings.putListingsItem`(Task 5)、`spapiClient.getMarketplaceId()`
- Produces:
  - HTTP: `POST /api/listings` body `{ asin, sku, conditionType, price, quantity, conditionNote }` → 200 `{ status: "ACCEPTED"|"INVALID", submissionId: string|null, issues: array }`(SP-API応答をそのまま透過。issuesの日本語化はしない)
  - routes.js内ヘルパー: `buildListingItemBody(input, marketplaceId) -> object`、`validateListingInput(body) -> {ok:true, value}|{ok:false, message}`(テスト用export)

- [ ] **Step 1: 失敗するテストを追記(listings-routes.test.js末尾)**

```js
// --- POST /api/listings ---

test('listings POST: 無料は403 plan_required、Proでもトークン無しは403 spapi_link_required', async () => {
  const routes = freshRoutes();
  const route = routes.match('POST', '/api/listings');

  const res1 = createMockRes();
  await route.handler({ body: {}, headers: { 'x-spapi-refresh-token': 'rt' } }, res1);
  assert.equal(res1.statusCode, 403);
  assert.equal(res1.body.error, 'plan_required');

  const res2 = createMockRes();
  await route.handler({ body: {}, headers: { 'x-app-plan': 'pro' } }, res2);
  assert.equal(res2.statusCode, 403);
  assert.equal(res2.body.error, 'spapi_link_required');
});

test('listings POST: 入力バリデーション(asin欠落/価格0以下/数量0以下/SKU不正/conditionType不正は400)', async () => {
  const routes = freshRoutes();
  const route = routes.match('POST', '/api/listings');
  const headers = { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt' };
  const valid = {
    asin: 'B000TEST',
    sku: 'AMLZ-20260722-001',
    conditionType: 'used_good',
    price: 1500,
    quantity: 1,
    conditionNote: '状態良好です。',
  };

  for (const broken of [
    { ...valid, asin: '' },
    { ...valid, price: 0 },
    { ...valid, price: 1500.5 },
    { ...valid, quantity: 0 },
    { ...valid, sku: 'bad sku with spaces' },
    { ...valid, conditionType: 'poor' },
  ]) {
    const res = createMockRes();
    await route.handler({ body: broken, headers }, res);
    assert.equal(res.statusCode, 400, JSON.stringify(broken));
  }
});

test('listings POST: putListingsItemへ正しいURL/ボディで送り、ACCEPTED応答を透過する', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    let putUrl = null;
    let putBody = null;
    global.fetch = mockFetch({
      putItem: (u, init, ok) => {
        putUrl = u;
        putBody = JSON.parse(init.body);
        return ok({ sku: 'AMLZ-20260722-001', status: 'ACCEPTED', submissionId: 'sub-99', issues: [] });
      },
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260722-001',
            conditionType: 'used_good',
            price: 1500,
            quantity: 1,
            conditionNote: '書き込みはありません。',
          },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-put' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.status, 'ACCEPTED');
      assert.equal(res.body.submissionId, 'sub-99');
      assert.deepEqual(res.body.issues, []);

      // PUT URL: sellerId + SKU + marketplaceIds
      assert.ok(putUrl.includes('/listings/2021-08-01/items/SELLER123/AMLZ-20260722-001'));
      assert.ok(putUrl.includes('marketplaceIds=A1VC38T7YXB528'));

      // ボディ: productType/requirements/attributes(spec準拠)
      assert.equal(putBody.productType, 'PRODUCT');
      assert.equal(putBody.requirements, 'LISTING_OFFER_ONLY');
      const attrs = putBody.attributes;
      assert.deepEqual(attrs.merchant_suggested_asin, [{ value: 'B000TEST', marketplace_id: 'A1VC38T7YXB528' }]);
      assert.deepEqual(attrs.condition_type, [{ value: 'used_good', marketplace_id: 'A1VC38T7YXB528' }]);
      assert.deepEqual(attrs.condition_note, [
        { language_tag: 'ja_JP', value: '書き込みはありません。', marketplace_id: 'A1VC38T7YXB528' },
      ]);
      assert.deepEqual(attrs.purchasable_offer, [
        {
          currency: 'JPY',
          marketplace_id: 'A1VC38T7YXB528',
          our_price: [{ schedule: [{ value_with_tax: 1500 }] }],
        },
      ]);
      assert.deepEqual(attrs.fulfillment_availability, [
        { fulfillment_channel_code: 'DEFAULT', quantity: 1 },
      ]);
    } finally {
      global.fetch = originalFetch;
    }
  });
});

test('listings POST: INVALID応答(issues付き)もそのまま透過する(日本語化しない)', async () => {
  await withEnv(ENV, async () => {
    const routes = freshRoutes();
    const originalFetch = global.fetch;
    global.fetch = mockFetch({
      putItem: (u, init, ok) =>
        ok({
          sku: 'AMLZ-20260722-002',
          status: 'INVALID',
          submissionId: 'sub-bad',
          issues: [{ code: '90220', message: 'Value is invalid for purchasable_offer.', severity: 'ERROR', attributeNames: ['purchasable_offer'] }],
        }),
    });
    try {
      const res = createMockRes();
      const route = routes.match('POST', '/api/listings');
      await route.handler(
        {
          body: {
            asin: 'B000TEST',
            sku: 'AMLZ-20260722-002',
            conditionType: 'used_acceptable',
            price: 800,
            quantity: 1,
            conditionNote: '',
          },
          headers: { 'x-app-plan': 'pro', 'x-spapi-refresh-token': 'rt-invalid' },
        },
        res
      );
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.status, 'INVALID');
      assert.equal(res.body.issues[0].message, 'Value is invalid for purchasable_offer.');
      // conditionNoteが空文字のときはcondition_note属性自体を送らない
    } finally {
      global.fetch = originalFetch;
    }
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd server && node --test test/listings-routes.test.js`
Expected: 追記4テストがFAIL(`route`がundefined)

- [ ] **Step 3: routes.js にバリデーション・ボディ組み立て・ルートを実装**

`summarizeRestrictions` の直後に追加:

```js
// SKUの許容形式: 英数字とハイフン・ドット・アンダースコア、1〜40文字(Amazonの一般的なSKU制約に合わせる)。
const SKU_PATTERN = /^[A-Za-z0-9._-]{1,40}$/;

/**
 * POST /api/listings の入力を検証する。
 * @param {object} body リクエストボディ
 * @returns {{ok:true, value:object}|{ok:false, message:string}}
 */
function validateListingInput(body) {
  const asin = String((body && body.asin) || '').trim();
  const sku = String((body && body.sku) || '').trim();
  const conditionType = String((body && body.conditionType) || '').trim();
  const price = body && body.price;
  const quantity = body && body.quantity;
  const conditionNote = String((body && body.conditionNote) || '');

  if (!asin) return { ok: false, message: 'asinは必須です' };
  if (!SKU_PATTERN.test(sku)) return { ok: false, message: 'skuは英数字と-._の1〜40文字で指定してください' };
  if (!LISTING_CONDITION_TYPES.includes(conditionType)) {
    return { ok: false, message: `conditionTypeは ${LISTING_CONDITION_TYPES.join(' / ')} のいずれかを指定してください` };
  }
  if (!Number.isInteger(price) || price <= 0) return { ok: false, message: 'priceは1以上の整数(円)で指定してください' };
  if (!Number.isInteger(quantity) || quantity <= 0) return { ok: false, message: 'quantityは1以上の整数で指定してください' };

  return { ok: true, value: { asin, sku, conditionType, price, quantity, conditionNote } };
}

/**
 * putListingsItemのリクエストボディを組み立てる(spec準拠・PRODUCT/LISTING_OFFER_ONLY固定)。
 * conditionNoteが空のときはcondition_note属性自体を含めない。
 * @param {{asin:string, conditionType:string, price:number, quantity:number, conditionNote:string}} input
 * @param {string} marketplaceId
 */
function buildListingItemBody(input, marketplaceId) {
  const attributes = {
    merchant_suggested_asin: [{ value: input.asin, marketplace_id: marketplaceId }],
    condition_type: [{ value: input.conditionType, marketplace_id: marketplaceId }],
    purchasable_offer: [
      {
        currency: 'JPY',
        marketplace_id: marketplaceId,
        our_price: [{ schedule: [{ value_with_tax: input.price }] }],
      },
    ],
    fulfillment_availability: [
      { fulfillment_channel_code: 'DEFAULT', quantity: input.quantity },
    ],
  };
  if (input.conditionNote) {
    attributes.condition_note = [
      { language_tag: 'ja_JP', value: input.conditionNote, marketplace_id: marketplaceId },
    ];
  }
  return {
    productType: 'PRODUCT',
    requirements: 'LISTING_OFFER_ONLY',
    attributes,
  };
}
```

`router.get('/api/listings/restrictions', ...)` の直後にルートを追加:

```js
// POST /api/listings — オファー出品(putListingsItem)。Pro+BYOトークン必須。
// トークン・出品内容はサーバーに保存しない(DPP整合)。応答のstatus/issuesはそのまま透過する。
router.post('/api/listings', async (req, res) => {
  const credentials = requireProByoCredentials(req, res);
  if (!credentials) return;

  const validated = validateListingInput(req.body);
  if (!validated.ok) {
    return res.status(400).json({ error: 'invalid_request', message: validated.message });
  }
  const input = validated.value;

  try {
    const sellerId = await sellers.resolveSellerId(credentials);
    const spapiClient = require('./spapi/client');
    const body = buildListingItemBody(input, spapiClient.getMarketplaceId());
    const response = await listings.putListingsItem({
      sellerId,
      sku: input.sku,
      body,
      credentials,
    });
    res.json({
      status: (response && response.status) || null,
      submissionId: (response && response.submissionId) || null,
      issues: (response && response.issues) || [],
    });
  } catch (err) {
    console.error(`[listings:put] asin=${input.asin} sku=${input.sku} failed:`, err.message);
    res.status(502).json({ error: 'listing_failed', message: err.message });
  }
});
```

テスト用exportに追記:

```js
router.validateListingInput = validateListingInput;
router.buildListingItemBody = buildListingItemBody;
```

注: ハンドラ内の `const spapiClient = require('./spapi/client');` は実装時にファイル先頭のrequireブロック(`const listings = ...` の直後)へ `const spapiClient = require('./spapi/client');` として置き、ルート内では `spapiClient.getMarketplaceId()` だけを呼ぶ(ハンドラ内requireを残さない)。

- [ ] **Step 4: テストがパスすることを確認**

Run: `cd server && node --test test/listings-routes.test.js`
Expected: PASS(10 tests)

- [ ] **Step 5: 既存テスト全体も通ることを確認してコミット**

Run: `cd server && npm test`
Expected: 全テストPASS

```bash
git add server/src/routes.js server/test/listings-routes.test.js
git commit -m "オファー出品API POST /api/listings を追加(putListingsItem透過・保存なし)"
```

---

## Task 7: iOS 出品モデル + APIClient拡張

**Files:**
- Create: `ios/BarcodeSedori/Sources/Models/ListingModels.swift`
- Modify: `ios/BarcodeSedori/Sources/API/APIClient.swift`

**Interfaces:**
- Consumes: サーバー契約(Task 5/6): `GET /api/listings/restrictions?asin=&condition=` → `{restricted, message, approvalUrl}` / `POST /api/listings` → `{status, submissionId, issues}`。既存 `makeRequest` / `perform`(X-App-Plan / X-Spapi-Refresh-Token付与済み)
- Produces:
  - `enum ListingConditionType: String, CaseIterable, Identifiable, Codable` — `usedLikeNew="used_like_new"` / `usedVeryGood="used_very_good"` / `usedGood="used_good"` / `usedAcceptable="used_acceptable"`、`displayName: String`、`offerConditionCode: String`
  - `ListingModels.suggestedPrice(offers:condition:) -> Int?`(純粋関数)
  - `struct ListingRestrictionsResult: Codable, Equatable` — `restricted: Bool`, `message: String?`, `approvalUrl: String?`
  - `struct ListingSubmissionRequest: Codable` — `asin/sku/conditionType: String`, `price/quantity: Int`, `conditionNote: String`
  - `struct ListingSubmissionResult: Codable, Equatable` — `status: String?`, `submissionId: String?`, `issues: [ListingIssue]?`, `var isAccepted: Bool`, `var issuesText: String`
  - `APIClient.listingsRestrictions(asin:condition:) async throws -> ListingRestrictionsResult`
  - `APIClient.submitListing(_:) async throws -> ListingSubmissionResult`

- [ ] **Step 1: ListingModels.swift を作成**

```swift
import Foundation

/// 出品フォームのコンディション(Listings Items APIのcondition_type値)。
/// specにより出品フォームは中古4種のみ(新品出品は対象外)。サーバー側は将来用にnew_newも受理する。
enum ListingConditionType: String, CaseIterable, Identifiable, Codable {
    case usedLikeNew = "used_like_new"
    case usedVeryGood = "used_very_good"
    case usedGood = "used_good"
    case usedAcceptable = "used_acceptable"

    var id: String { rawValue }

    /// 画面表示名(オファー一覧のconditionDisplayNameと同じ語彙)。
    var displayName: String {
        switch self {
        case .usedLikeNew: return "ほぼ新品"
        case .usedVeryGood: return "非常に良い"
        case .usedGood: return "良い"
        case .usedAcceptable: return "可"
        }
    }

    /// /api/offers のOffer.condition正規化コードとの対応(初期価格の同コンディション検索に使う)。
    var offerConditionCode: String {
        switch self {
        case .usedLikeNew: return "like_new"
        case .usedVeryGood: return "very_good"
        case .usedGood: return "good"
        case .usedAcceptable: return "acceptable"
        }
    }
}

/// 出品まわりの純粋ロジック(swiftc単体コンパイルで検証可能なようViewから分離)。
enum ListingModels {
    /// 出品価格の初期値: 同コンディション最安値(送料込みlanded)。
    /// 同コンディションのオファーが無い場合は中古全体の最安landed、それも無ければnil。
    static func suggestedPrice(offers: OffersResult?, condition: ListingConditionType) -> Int? {
        let used = offers?.used ?? []
        let sameCondition = used
            .filter { $0.condition == condition.offerConditionCode }
            .compactMap { $0.landed }
        if let lowest = sameCondition.min() {
            return lowest
        }
        return used.compactMap { $0.landed }.min()
    }
}

/// GET /api/listings/restrictions レスポンス。
struct ListingRestrictionsResult: Codable, Equatable {
    let restricted: Bool
    let message: String?
    /// Seller Centralの解除申請ページURL(制限ありでリンクが取れた場合のみ)。
    let approvalUrl: String?
}

/// POST /api/listings リクエストボディ。
struct ListingSubmissionRequest: Codable {
    let asin: String
    let sku: String
    let conditionType: String
    let price: Int
    let quantity: Int
    let conditionNote: String
}

/// POST /api/listings レスポンス(SP-API putListingsItem応答の透過)。
struct ListingSubmissionResult: Codable, Equatable {
    let status: String?
    let submissionId: String?
    let issues: [ListingIssue]?

    struct ListingIssue: Codable, Equatable {
        let code: String?
        let message: String?
        let severity: String?
        let attributeNames: [String]?
    }

    /// 出品が受理されたか(非同期反映のため「受理」であって「完了」ではない)。
    var isAccepted: Bool {
        status?.uppercased() == "ACCEPTED"
    }

    /// INVALID時にそのまま表示するissues本文(日本語化はしない方針)。
    var issuesText: String {
        let messages = (issues ?? []).compactMap { $0.message }
        return messages.isEmpty ? "出品が受理されませんでした(status: \(status ?? "不明"))" : messages.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: 純粋関数をswiftcで検証(ProfitAlertEvaluatorと同方式)**

検証用mainをスクラッチパッドに作成(プロジェクトには含めない):

```swift
// /private/tmp/claude-501/.../scratchpad/listing_models_check/main.swift
// suggestedPriceの検証: 同コンディション最安 / フォールバック / 空
let offers = OffersResult(
    source: "spapi", referencePrice: nil, newCount: 1, usedCount: 3, releaseDate: nil,
    new: [Offer(condition: "new", price: 2000, shipping: 0, landed: 2000, isBuyBox: false, sameCount: nil, breakEven: nil)],
    used: [
        Offer(condition: "good", price: 1000, shipping: 250, landed: 1250, isBuyBox: false, sameCount: nil, breakEven: nil),
        Offer(condition: "good", price: 900, shipping: 350, landed: 1250, isBuyBox: false, sameCount: nil, breakEven: nil),
        Offer(condition: "very_good", price: 1400, shipping: 0, landed: 1400, isBuyBox: false, sameCount: nil, breakEven: nil),
    ]
)
assert(ListingModels.suggestedPrice(offers: offers, condition: .usedGood) == 1250)
assert(ListingModels.suggestedPrice(offers: offers, condition: .usedVeryGood) == 1400)
// 同コンディション無し -> 中古全体の最安landedへフォールバック
assert(ListingModels.suggestedPrice(offers: offers, condition: .usedLikeNew) == 1250)
assert(ListingModels.suggestedPrice(offers: nil, condition: .usedGood) == nil)
assert(ListingConditionType.usedLikeNew.offerConditionCode == "like_new")
print("ListingModels checks passed")
```

Run:
```bash
SCRATCH="/private/tmp/claude-501/-Users-yuyads-Claude-Projects-----------1-/f11eff75-7dfd-471d-bbf3-c346acd99574/scratchpad/listing_models_check"
mkdir -p "$SCRATCH"
# 上記main.swiftを$SCRATCHに書いたうえで:
swiftc -o "$SCRATCH/check" \
  "ios/BarcodeSedori/Sources/Models/OffersModels.swift" \
  "ios/BarcodeSedori/Sources/Models/ListingModels.swift" \
  "$SCRATCH/main.swift" && "$SCRATCH/check"
```
Expected: `ListingModels checks passed`(検証後、main.swiftはコミットに含めない)

- [ ] **Step 3: APIClient に出品系メソッドとPOST対応を追加**

`APIClient` の `makeRequest` の直後にPOSTヘルパーを追加:

```swift
    /// JSONボディ付きPOSTリクエストを作る。ヘッダー類(X-App-Plan / X-Device-Id /
    /// X-Spapi-Refresh-Token)はmakeRequestと同一の付与ロジックを通す。
    private func makePostRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw APIClientError.underlying(error)
        }
        return request
    }
```

`spapiTest()` の直前にAPIメソッド2つを追加:

```swift
    /// GET /api/listings/restrictions?asin=&condition=
    /// 出品フォーム表示時の出品制限チェック(Pro+SP-API連携必須。サーバー側403ゲートあり)。
    func listingsRestrictions(asin: String, condition: String) async throws -> ListingRestrictionsResult {
        let request = try makeRequest(path: "/api/listings/restrictions", queryItems: [
            URLQueryItem(name: "asin", value: asin),
            URLQueryItem(name: "condition", value: condition),
        ])
        return try await perform(request, as: ListingRestrictionsResult.self)
    }

    /// POST /api/listings — オファー出品(putListingsItem)。
    /// 出品は非同期受理のため、ACCEPTEDでも反映まで数分かかる。
    func submitListing(_ payload: ListingSubmissionRequest) async throws -> ListingSubmissionResult {
        let request = try makePostRequest(path: "/api/listings", body: payload)
        return try await perform(request, as: ListingSubmissionResult.self)
    }
```

- [ ] **Step 4: ビルドして成功を確認**

Run: ビルドコマンド(Global Constraints記載)
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: コミット**

```bash
git add ios/BarcodeSedori/Sources/Models/ListingModels.swift ios/BarcodeSedori/Sources/API/APIClient.swift
git commit -m "出品モデルとAPIClientの出品制限チェック・出品送信メソッドを追加"
```

---

## Task 8: コンディション別説明文テンプレート(SettingsStore + 設定画面)

**Files:**
- Modify: `ios/BarcodeSedori/Sources/Store/SettingsStore.swift`
- Create: `ios/BarcodeSedori/Sources/Views/ListingTemplateSettingsView.swift`
- Modify: `ios/BarcodeSedori/Sources/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ListingConditionType`(Task 7)、既存の `Keys` enum / `@Published + didSet` 作法、`ProfitAlertSettingsView` の分離画面方式
- Produces:
  - `SettingsStore.listingTemplateLikeNew / listingTemplateVeryGood / listingTemplateGood / listingTemplateAcceptable: String`(@Published)
  - `SettingsStore.listingTemplate(for condition: ListingConditionType) -> String`
  - `struct ListingTemplateSettingsView: View`

- [ ] **Step 1: SettingsStore にテンプレート4種を追加**

`Keys` enum に追加(`profitAlertHapticsEnabled` の直後):

```swift
        // 出品(Phase 2): コンディション別説明文テンプレート。
        static let listingTemplateLikeNew = "settings.listing.template.likeNew"
        static let listingTemplateVeryGood = "settings.listing.template.veryGood"
        static let listingTemplateGood = "settings.listing.template.good"
        static let listingTemplateAcceptable = "settings.listing.template.acceptable"
```

既定値定数をクラス内(`static let defaultServerURL` の直前)に追加:

```swift
    // 出品説明文テンプレートの既定値(設定画面・出品フォームで編集可)。
    static let defaultListingTemplateLikeNew =
        "使用感がほとんど無い美品です。目立った傷・汚れはありません。丁寧に梱包して自己発送でお届けします。"
    static let defaultListingTemplateVeryGood =
        "使用感は少なく良好な状態です。目立つ傷・汚れはありません。丁寧に梱包してお届けします。"
    static let defaultListingTemplateGood =
        "通常の使用感がありますが、問題なくお使いいただけます。検品のうえ丁寧に梱包してお届けします。"
    static let defaultListingTemplateAcceptable =
        "使用感・傷みがありますが、使用には支障ありません。状態をご了承のうえご購入ください。"
```

@Publishedプロパティを追加(`profitAlertHapticsEnabled` の直後):

```swift
    // 出品(Phase 2): コンディション別説明文テンプレート。

    /// 出品説明文テンプレート(ほぼ新品)
    @Published var listingTemplateLikeNew: String {
        didSet {
            defaults.set(listingTemplateLikeNew, forKey: Keys.listingTemplateLikeNew)
        }
    }

    /// 出品説明文テンプレート(非常に良い)
    @Published var listingTemplateVeryGood: String {
        didSet {
            defaults.set(listingTemplateVeryGood, forKey: Keys.listingTemplateVeryGood)
        }
    }

    /// 出品説明文テンプレート(良い)
    @Published var listingTemplateGood: String {
        didSet {
            defaults.set(listingTemplateGood, forKey: Keys.listingTemplateGood)
        }
    }

    /// 出品説明文テンプレート(可)
    @Published var listingTemplateAcceptable: String {
        didSet {
            defaults.set(listingTemplateAcceptable, forKey: Keys.listingTemplateAcceptable)
        }
    }
```

`init` に読み込みを追加(`profitAlertHapticsEnabled` 読み込みの直後):

```swift
        // 出品説明文テンプレート(Phase 2)。未設定時は既定文で読み込む。
        self.listingTemplateLikeNew =
            defaults.string(forKey: Keys.listingTemplateLikeNew) ?? Self.defaultListingTemplateLikeNew
        self.listingTemplateVeryGood =
            defaults.string(forKey: Keys.listingTemplateVeryGood) ?? Self.defaultListingTemplateVeryGood
        self.listingTemplateGood =
            defaults.string(forKey: Keys.listingTemplateGood) ?? Self.defaultListingTemplateGood
        self.listingTemplateAcceptable =
            defaults.string(forKey: Keys.listingTemplateAcceptable) ?? Self.defaultListingTemplateAcceptable
```

クラス末尾(`isSpApiLinkUsable` の直後)にアクセサを追加:

```swift
    /// 出品フォームがコンディション選択に応じて自動適用するテンプレート本文を返す。
    func listingTemplate(for condition: ListingConditionType) -> String {
        switch condition {
        case .usedLikeNew: return listingTemplateLikeNew
        case .usedVeryGood: return listingTemplateVeryGood
        case .usedGood: return listingTemplateGood
        case .usedAcceptable: return listingTemplateAcceptable
        }
    }
```

- [ ] **Step 2: ListingTemplateSettingsView.swift を作成**

```swift
import SwiftUI

/// 出品説明文テンプレートの編集画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// ProfitAlertSettingsViewと同じ分離画面方式。コンディション4種それぞれのテンプレートを編集できる。
struct ListingTemplateSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("ほぼ新品") {
                TextEditor(text: $settings.listingTemplateLikeNew)
                    .frame(minHeight: 80)
            }
            Section("非常に良い") {
                TextEditor(text: $settings.listingTemplateVeryGood)
                    .frame(minHeight: 80)
            }
            Section("良い") {
                TextEditor(text: $settings.listingTemplateGood)
                    .frame(minHeight: 80)
            }
            Section("可") {
                TextEditor(text: $settings.listingTemplateAcceptable)
                    .frame(minHeight: 80)
            }
            Section {
                Text("出品フォームでコンディションを選ぶと、対応するテンプレートが説明文に自動入力されます(出品ごとに個別編集もできます)。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("出品説明文テンプレート")
    }
}
```

- [ ] **Step 3: SettingsView に「出品」セクションを追加**

`profitAlertSection` の直後(bodyの `Form` 内では `profitAlertSection` 行の直下)に `listingSection` を挿入し、computed propertyを追加(`profitAlertSection` の直後):

```swift
    // MARK: - 出品

    /// 出品設定セクション。無料は鍵行のみでタップでペイウォール(profitAlertSectionと同じ作法)。
    @ViewBuilder
    private var listingSection: some View {
        Section("出品") {
            if entitlements.isPro {
                NavigationLink("出品説明文テンプレート") {
                    ListingTemplateSettingsView()
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
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
```

body内の変更:

```swift
                profitAlertSection

                listingSection
```

- [ ] **Step 4: ビルド+シミュレータ確認**

Run: ビルド→起動→設定タブ→「出品説明文テンプレート」→テンプレを編集→アプリ再起動(`xcrun simctl terminate` → `launch`)→編集内容が保持されていることをスクリーンショット確認。
Expected: 4種のテンプレ編集UI表示・永続化OK。無料プランでは鍵行になる。

- [ ] **Step 5: コミット**

```bash
git add ios/BarcodeSedori/Sources/Store/SettingsStore.swift ios/BarcodeSedori/Sources/Views/ListingTemplateSettingsView.swift ios/BarcodeSedori/Sources/Views/SettingsView.swift
git commit -m "コンディション別出品説明文テンプレートの保存と設定画面を追加(Pro限定)"
```

---

## Task 9: SKU生成 + ListingFormView + 仕入れタブの出品導線

**Files:**
- Create: `ios/BarcodeSedori/Sources/Models/SkuGenerator.swift`
- Create: `ios/BarcodeSedori/Sources/Views/ListingFormView.swift`
- Modify: `ios/BarcodeSedori/Sources/Store/SettingsStore.swift`(SKU連番の永続化)
- Modify: `ios/BarcodeSedori/Sources/Views/PurchaseTabView.swift`(出品導線)

**Interfaces:**
- Consumes: `APIClient.listingsRestrictions(asin:condition:)` / `.submitListing(_:)`(Task 7)、`APIClient.offers(asin:source:)`(既存)、`SettingsStore.listingTemplate(for:)`(Task 8)、`PurchaseListStore.markListed(id:sku:)`(Task 1)、`ListingConditionType` / `ListingModels.suggestedPrice(offers:condition:)`(Task 7)、`SettingsStore.isSpApiLinkUsable` / `EntitlementStore.isPro`
- Produces:
  - `enum SkuGenerator` — `static func dateString(from date: Date) -> String`(yyyyMMdd)、`static func make(dateString: String, sequence: Int) -> String`(`AMLZ-YYYYMMDD-NNN`)、`static func nextSequence(lastDateString: String?, lastSequence: Int, todayString: String) -> Int`
  - `SettingsStore.nextListingSku(now: Date = Date()) -> String`(連番を進めて永続化)
  - `struct ListingFormView: View`(`init(item: PurchaseListItem)`)

- [ ] **Step 1: SkuGenerator.swift を作成(純粋関数)**

```swift
import Foundation

/// 出品SKUの自動生成: `AMLZ-YYYYMMDD-連番`(連番は日付ごとに1から、3桁ゼロ埋め)。
/// 連番の永続化はSettingsStore側で行い、ここは純粋関数のみ(swiftc単体検証のため)。
enum SkuGenerator {
    /// 日付部分(yyyyMMdd)。端末ローカルのタイムゾーン・グレゴリオ暦で固定フォーマット。
    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// SKU文字列を組み立てる。連番は3桁ゼロ埋め(1000以上はそのまま桁を伸ばす)。
    static func make(dateString: String, sequence: Int) -> String {
        String(format: "AMLZ-%@-%03d", dateString, sequence)
    }

    /// 次の連番を計算する。日付が変わったら1にリセット、同日なら+1。
    static func nextSequence(lastDateString: String?, lastSequence: Int, todayString: String) -> Int {
        if lastDateString == todayString {
            return lastSequence + 1
        }
        return 1
    }
}
```

- [ ] **Step 2: swiftcで検証**

検証用main(スクラッチパッド、コミットしない):

```swift
assert(SkuGenerator.make(dateString: "20260722", sequence: 1) == "AMLZ-20260722-001")
assert(SkuGenerator.make(dateString: "20260722", sequence: 12) == "AMLZ-20260722-012")
assert(SkuGenerator.make(dateString: "20260722", sequence: 1000) == "AMLZ-20260722-1000")
assert(SkuGenerator.nextSequence(lastDateString: "20260722", lastSequence: 3, todayString: "20260722") == 4)
assert(SkuGenerator.nextSequence(lastDateString: "20260721", lastSequence: 9, todayString: "20260722") == 1)
assert(SkuGenerator.nextSequence(lastDateString: nil, lastSequence: 0, todayString: "20260722") == 1)
print("SkuGenerator checks passed")
```

Run:
```bash
SCRATCH="/private/tmp/claude-501/-Users-yuyads-Claude-Projects-----------1-/f11eff75-7dfd-471d-bbf3-c346acd99574/scratchpad/sku_check"
mkdir -p "$SCRATCH"
swiftc -o "$SCRATCH/check" \
  "ios/BarcodeSedori/Sources/Models/SkuGenerator.swift" \
  "$SCRATCH/main.swift" && "$SCRATCH/check"
```
Expected: `SkuGenerator checks passed`

- [ ] **Step 3: SettingsStore にSKU連番の永続化を追加**

`Keys` に追加(`listingTemplateAcceptable` の直後):

```swift
        // 出品SKUの日次連番(AMLZ-YYYYMMDD-NNN)。
        static let listingSkuLastDate = "settings.listing.skuLastDate"
        static let listingSkuLastSequence = "settings.listing.skuLastSequence"
```

`listingTemplate(for:)` の直後にメソッドを追加:

```swift
    /// 次の出品SKUを発行する(呼ぶたびに連番を進めて永続化する)。
    /// 形式: AMLZ-YYYYMMDD-連番(日付ごとに001から)。ユーザーがフォームで編集した場合も
    /// 連番は消費済みでよい(重複防止を優先。putListingsItemは同一SKU再実行で上書きされる)。
    func nextListingSku(now: Date = Date()) -> String {
        let today = SkuGenerator.dateString(from: now)
        let lastDate = defaults.string(forKey: Keys.listingSkuLastDate)
        let lastSequence = defaults.integer(forKey: Keys.listingSkuLastSequence)
        let sequence = SkuGenerator.nextSequence(
            lastDateString: lastDate,
            lastSequence: lastSequence,
            todayString: today
        )
        defaults.set(today, forKey: Keys.listingSkuLastDate)
        defaults.set(sequence, forKey: Keys.listingSkuLastSequence)
        return SkuGenerator.make(dateString: today, sequence: sequence)
    }
```

- [ ] **Step 4: ListingFormView.swift を作成**

```swift
import SwiftUI

/// 出品フォーム(Phase 2)。仕入れタブの「出品」から開く(Pro+SP-API連携時のみ導線が出る)。
/// フロー: 表示時に出品制限チェック(制限ありなら入力不可+解除案内)→
/// /api/offersで最新価格を再取得して初期価格を更新→確認ダイアログ→POST /api/listings。
@MainActor
final class ListingFormViewModel: ObservableObject {
    /// 出品制限チェックの状態。
    enum RestrictionState: Equatable {
        case checking
        case allowed
        case restricted(message: String, approvalUrl: String?)
        case checkFailed(String)
    }

    @Published var condition: ListingConditionType = .usedVeryGood {
        didSet {
            // コンディション変更でテンプレートを再適用し、制限も再チェックする
            // (制限はconditionType単位で変わり得るため)。
            conditionNote = settings.listingTemplate(for: condition)
            applySuggestedPrice()
            Task { await checkRestrictions() }
        }
    }
    @Published var price: Int?
    @Published var sku: String = ""
    @Published var conditionNote: String = ""
    @Published var quantity: Int = 1
    @Published var restrictionState: RestrictionState = .checking
    @Published var isSubmitting = false
    /// 出品結果アラート(受理成功/エラー本文)。
    @Published var resultAlert: ResultAlert?

    struct ResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// trueなら閉じるときにフォームも閉じる(受理成功時)。
        let dismissesForm: Bool
    }

    let item: PurchaseListItem
    /// 表示時に/api/offersで再取得した最新オファー。取得前はitem.offersResult(追加時スナップショット)。
    private var latestOffers: OffersResult?

    private let apiClient: APIClient
    private let settings: SettingsStore
    private let purchaseList: PurchaseListStore

    init(
        item: PurchaseListItem,
        apiClient: APIClient = .shared,
        settings: SettingsStore = .shared,
        purchaseList: PurchaseListStore = .shared
    ) {
        self.item = item
        self.apiClient = apiClient
        self.settings = settings
        self.purchaseList = purchaseList
        self.latestOffers = item.offersResult
        // didSetはinit中に走らないため初期値を明示的に組み立てる。
        self.conditionNote = settings.listingTemplate(for: .usedVeryGood)
        self.sku = settings.nextListingSku()
        self.price = ListingModels.suggestedPrice(offers: item.offersResult, condition: .usedVeryGood)
    }

    /// 画面表示時: 制限チェックと最新オファー再取得を並行実行する。
    func onAppear() async {
        async let restrictions: Void = checkRestrictions()
        async let offers: Void = refreshOffers()
        _ = await (restrictions, offers)
    }

    func checkRestrictions() async {
        restrictionState = .checking
        do {
            let result = try await apiClient.listingsRestrictions(
                asin: item.asin,
                condition: condition.rawValue
            )
            if result.restricted {
                restrictionState = .restricted(
                    message: result.message ?? "出品制限があります。",
                    approvalUrl: result.approvalUrl
                )
            } else {
                restrictionState = .allowed
            }
        } catch {
            restrictionState = .checkFailed(error.localizedDescription)
        }
    }

    /// 最新オファーを再取得して初期価格を更新する(出品はSP-API連携必須のためsource=spapi固定)。
    /// 失敗時は追加時スナップショットの価格のまま(フォーム入力は可能)。
    private func refreshOffers() async {
        if let refreshed = try? await apiClient.offers(asin: item.asin, source: "spapi") {
            latestOffers = refreshed
            applySuggestedPrice()
        }
    }

    private func applySuggestedPrice() {
        if let suggested = ListingModels.suggestedPrice(offers: latestOffers, condition: condition) {
            price = suggested
        }
    }

    var canSubmit: Bool {
        guard case .allowed = restrictionState else { return false }
        guard let price, price > 0 else { return false }
        return !sku.trimmingCharacters(in: .whitespaces).isEmpty && quantity > 0 && !isSubmitting
    }

    func submit() async {
        guard let price else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await apiClient.submitListing(ListingSubmissionRequest(
                asin: item.asin,
                sku: sku.trimmingCharacters(in: .whitespaces),
                conditionType: condition.rawValue,
                price: price,
                quantity: quantity,
                conditionNote: conditionNote
            ))
            if result.isAccepted {
                purchaseList.markListed(id: item.id, sku: sku)
                resultAlert = ResultAlert(
                    title: "出品を受け付けました",
                    message: "反映まで数分かかります。",
                    dismissesForm: true
                )
            } else {
                // INVALID等: issuesの本文をそのまま表示(日本語化しない)。フォームに留まりリトライ可能。
                resultAlert = ResultAlert(title: "出品できませんでした", message: result.issuesText, dismissesForm: false)
            }
        } catch {
            // 価格不正・制限・トークン失効等: サーバーのエラー本文をそのまま表示してリトライ可能。
            resultAlert = ResultAlert(title: "出品に失敗しました", message: error.localizedDescription, dismissesForm: false)
        }
    }
}

struct ListingFormView: View {
    @StateObject private var viewModel: ListingFormViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirm = false

    init(item: PurchaseListItem) {
        _viewModel = StateObject(wrappedValue: ListingFormViewModel(item: item))
    }

    var body: some View {
        Form {
            Section("商品") {
                Text(viewModel.item.title ?? "(タイトル不明)")
                    .font(.subheadline)
                HStack {
                    Text("ASIN")
                    Spacer()
                    Text(viewModel.item.asin)
                        .foregroundColor(.secondary)
                }
            }

            restrictionSection

            // 制限あり・チェック中は入力欄と出品ボタンをロックする。
            // Form全体に.disabledを掛けると制限セクション内の「再チェック」ボタンやLinkまで
            // 無効化されるため、入力系Sectionへ個別に付与する。
            Section("出品内容") {
                Picker("コンディション", selection: $viewModel.condition) {
                    ForEach(ListingConditionType.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }

                HStack {
                    Text("価格(円)")
                    Spacer()
                    TextField("価格", value: $viewModel.price, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }

                HStack {
                    Text("SKU")
                    Spacer()
                    TextField("SKU", text: $viewModel.sku)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                }

                Stepper("数量: \(viewModel.quantity)", value: $viewModel.quantity, in: 1...99)
            }
            .disabled(isFormLocked)

            Section("コンディション説明") {
                TextEditor(text: $viewModel.conditionNote)
                    .frame(minHeight: 100)
                Text("設定タブの「出品説明文テンプレート」を自動適用しています。この出品だけ個別に編集できます。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .disabled(isFormLocked)

            Section {
                Button {
                    showConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("出品する")
                                .fontWeight(.bold)
                        }
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("出品")
        .navigationBarTitleDisplayMode(.inline)
        // 出品は不可逆操作のため確認ダイアログ必須(spec)。
        .confirmationDialog(
            "この内容で出品しますか?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("出品する") {
                Task { await viewModel.submit() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(viewModel.condition.displayName) / ¥\(viewModel.price ?? 0) / 数量\(viewModel.quantity)\nSKU: \(viewModel.sku)")
        }
        .alert(item: $viewModel.resultAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    if alert.dismissesForm {
                        dismiss()
                    }
                }
            )
        }
        .task {
            await viewModel.onAppear()
        }
    }

    /// 制限あり・チェック中・チェック失敗時は入力欄と出品ボタンをロックする。
    private var isFormLocked: Bool {
        if case .allowed = viewModel.restrictionState { return false }
        return true
    }

    /// 出品制限チェックの状態表示。制限ありは理由と解除申請リンク(Seller Central)を案内する。
    @ViewBuilder
    private var restrictionSection: some View {
        switch viewModel.restrictionState {
        case .checking:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("出品制限を確認中…")
                        .foregroundColor(.secondary)
                }
            }
        case .allowed:
            EmptyView()
        case .restricted(let message, let approvalUrl):
            Section("出品制限があります") {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                if let approvalUrl, let url = URL(string: approvalUrl) {
                    Link("Seller Centralで解除申請する", destination: url)
                        .font(.footnote)
                }
                Text("解除申請はアプリからは行えません。Seller Centralでの手続き後に再度お試しください。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .checkFailed(let message):
            Section("制限チェックに失敗しました") {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                Button("再チェック") {
                    Task { await viewModel.checkRestrictions() }
                }
            }
        }
    }
}
```

- [ ] **Step 5: PurchaseTabView に出品導線を追加**

`PurchaseTabView` にプロパティを追加(`entitlements` の直後):

```swift
    @ObservedObject private var settings = SettingsStore.shared
```

`listContent` の `ForEach` を以下に変更(出品導線はPro+SP-API連携時のみ・未出品のみ):

```swift
            ForEach(store.items) { item in
                if entitlements.isPro && settings.isSpApiLinkUsable && !item.isListed {
                    NavigationLink {
                        ListingFormView(item: item)
                    } label: {
                        PurchaseListRow(item: item)
                    }
                } else {
                    PurchaseListRow(item: item)
                }
            }
```

`emptyState` の案内文はそのまま。さらにリスト上部への注意書きとして、`listContent` の `List` 先頭に以下Sectionを追加(SP-API未連携のProユーザー向け):

```swift
            if entitlements.isPro && !settings.isSpApiLinkUsable {
                Section {
                    Text("出品するには設定タブでAmazon連携(SP-API)が必要です。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
```

- [ ] **Step 6: ビルド+シミュレータ確認**

Run: ビルド→起動→(Pro+SP-API連携済みトークン設定済みの状態で)検索バーからISBN検索→仕入れリストへ追加→仕入れタブ→行タップ→出品フォームが開き、制限チェック表示→SKU初期値が`AMLZ-YYYYMMDD-001`形式→コンディション切替で説明文テンプレが入れ替わることをスクリーンショット確認。
Expected: フォーム表示・入力・確認ダイアログまで動作。サーバー未デプロイ環境では制限チェックが `checkFailed` になるのが正常(その場合の再チェックボタン表示も確認)。実出品はTask 10で行う。

- [ ] **Step 7: コミット**

```bash
git add ios/BarcodeSedori/Sources/Models/SkuGenerator.swift ios/BarcodeSedori/Sources/Views/ListingFormView.swift ios/BarcodeSedori/Sources/Store/SettingsStore.swift ios/BarcodeSedori/Sources/Views/PurchaseTabView.swift
git commit -m "出品フォーム(制限チェック・SKU自動生成・テンプレ適用・確認ダイアログ)と仕入れタブの出品導線を追加"
```

---

## Task 10: 結合確認(ユーザー実施を含む)

**Files:** 変更なし(確認のみ)

- [ ] **Step 1: サーバーのデプロイをユーザーに依頼**

サーバーは手動デプロイ(メモリ`server-deploy-is-manual`)。`cd server && npm test` が全緑であることを再確認したうえで、ユーザーにデプロイを依頼する。

- [ ] **Step 2: 前提作業の完了確認**

「ユーザーが実施する前提作業」(Product Listing / Sellersロール追加+再認可)が完了しているかユーザーに確認する。未完了なら以降は保留。

- [ ] **Step 3: 実機での結合確認(ユーザー実施)**

以下をユーザーに依頼する(spec「テスト方針」準拠):

1. 実機(またはネットワーク到達可能なシミュレータ)で、Pro+SP-API連携済み状態で仕入れリスト→出品フォーム→安全な検証用ASINを**実出品**する(価格は市場より十分高くして誤販売を防ぐ)。
2. 「出品を受け付けました。反映まで数分かかります」表示と、仕入れタブの「出品済み」マークを確認する。
3. Seller Centralで出品が反映されたことを確認後、**即時削除**する。
4. 出品制限のあるASIN(取扱制限のあるブランド品等)で、フォームが入力不可になり解除申請リンクが案内されることを確認する。
5. 無料プラン/SP-API未連携での導線非表示(出品ボタンが出ない・設定の出品行が鍵)を確認する。

- [ ] **Step 4: 結果を記録してコミット(必要なら)**

確認で見つかった不具合は本計画のタスクに戻って修正する。問題なければ完了。

---

## Self-Review(計画完成後に必ず実施)

保存・コミット前に以下を自分でチェックする:

1. **Spec網羅**: Phase 1b(追加ボタン/仕入れタブ実体化/ローカル保存のみ)→Task 1〜3。Phase 2(フォーム項目5点/制限チェック→入力不可+解除案内/確認ダイアログ/BYO putListingsItem/非同期受理メッセージ+出品済みマーク/サーバーAPI2本+403ゲート/エラー本文そのまま表示+リトライ/同一SKU上書き)→Task 4〜9。テスト方針(実出品→即削除・制限ASIN確認)→Task 10。やらないこと(FBA/新規ASIN/相場監視/サーバー保存)に抵触するタスクが無いこと。
2. **プレースホルダ検索**: 「TBD」「TODO」「適切に」「同様に」「後で」が計画書に残っていないこと(コード片は全て実文)。
3. **型整合**: `PurchaseListItem`のフィールド名(Task 1)とTask 3/9での参照、`ListingConditionType.rawValue`(iOS)と`LISTING_CONDITION_TYPES`(サーバー)の値一致、`ListingRestrictionsResult`(iOS)と`summarizeRestrictions`戻り値(サーバー)のキー一致(`restricted`/`message`/`approvalUrl`)、`ListingSubmissionRequest`のキー(iOS)と`validateListingInput`(サーバー)の一致(`asin`/`sku`/`conditionType`/`price`/`quantity`/`conditionNote`)、`resolveSellerId`/`markListed(id:sku:)`等のシグネチャがタスク間で一致していること。

問題を見つけたらその場で修正する(再レビュー不要)。
