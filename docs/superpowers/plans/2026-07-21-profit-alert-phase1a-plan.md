# 利益アラート Phase 1a 実装計画

- 作成: 2026-07-21 / 計画: Fable5
- 対象スペック: `docs/superpowers/specs/2026-07-19-listing-and-profit-alert-design.md`（Phase 1a 改定版）
- 状態: **計画済み・実装未着手**

## 前提（確定事項、再検討不要）

- Pro限定。スキャン結果表示時に、ONにした条件を**すべて満たしたら（AND）**結果カードを強調表示（緑バナー＋ハプティクス）。
- 経路方針:
  - SP-API連携中（`SettingsStore.isSpApiLinkUsable`）はSP-APIの値のみ使用。Keepa併用なし。
  - Keepa経路は `/api/search` 第1段階（`getProduct({code})`、`offers`なし）のみ。**追加トークン消費ゼロが絶対条件**。
- Keepaの `stats.current` で追加取得するのは `[4] LISTPRICE`（定価）と `[11] COUNT_NEW` / `[12] COUNT_USED`（出品者数）。
  いずれも `isExtraData=false` でoffers不要（調査済み）。`[19]〜[22]` の中古細分価格はoffers必須のため使わない
  → Keepa経路のコンディションは新品/中古の2区分のみ。
- 定価はSP-APIでは実質取得不可（`attributes.list_price` は書籍等で欠落しがち）→ SP-API経路は定価条件を常にスキップ。
- 手数料は既存計算を再利用: `breakEven = 売値 − 手数料` が両経路で計算済み（Keepa: `routes.js` の
  `computeBreakEven`、SP-API: `getMyFeesEstimatesBatch` + `pricing.fallbackFees`）。
  **粗利 = breakEven − 仕入れ値** で算出する。

---

## 1. サーバー: /api/search レスポンス契約の拡張（profitInputs）

既存方針「**両経路でキーの有無をブレさせない。取れない項目は明示的に null**」
（`brand`/`dimensionsMm`/`weightG` で確立済み）に従い、`/api/search` レスポンスのトップレベルに
`profitInputs` を追加する。両経路とも必ず同じキー構成で返す。

```jsonc
"profitInputs": {
  // 定価(円)。Keepa: stats.current[4]。SP-API経路・取得不可時はnull。
  "listPrice": 2200,
  // 出品者数。Keepa: current[11]/[12]。SP-API: Summary.TotalOfferCount。取れない側はnull。
  "sellerCounts": { "new": 3, "used": 12 },
  // 手数料控除後の売値(= breakEven)。小数あり得る。売値が取れない側はnull。
  "breakEven": { "new": 1780.5, "used": 950.2 }
}
```

- `unresolved` / `catalog_not_found` 等の早期returnでは既存フィールド群と同様 `profitInputs: null` を追加する
  （キー自体は常に存在させる）。
- 判定そのものはクライアント側で行う（閾値は端末設定のため）。サーバーは素材だけ返す。
- `profitInputs` の付与に追加のKeepaトークン・SP-API呼び出しは一切発生しない（既存レスポンスの読み替えのみ）。
  そのため無料/Proでの出し分けはしない（判定はiOS側でProゲート）。

### 1-1. Keepa経路（`server/src/keepa/client.js` + `routes.js handleSearchViaKeepa`）

- `CSV_TYPE` に `COUNT_NEW: 11` / `COUNT_USED: 12` を追加（LISTPRICE: 4 は定義済み・未使用）。
  冒頭のドキュメントコメント（stats.currentインデックス一覧）にも追記する。
- `mapProductToSearchResult` を拡張し、`listPrice`（`normalizePrice(current[4])`）と
  `sellerCounts`（`normalizePrice(current[11])` / `normalizePrice(current[12])`。-1→null、0は有効値）を返す。
- `buildOffersResponseViaKeepa` 内のローカル関数 `computeBreakEven` を、`routes.js` モジュールレベルの
  `computeKeepaBreakEven(product, landed)` に共通化する（`referralFeePercent` / `fbaFees.pickAndPackFee` が
  あれば実計算、無ければ `pricing.fallbackFees` の書籍フォールバック15%+80円。挙動は現状と同一）。
  これら手数料フィールドはProduct本体の属性でoffersパラメータ不要。第1段階応答に無い場合も
  フォールバックが効くため取得可否に依存しない。
- `handleSearchViaKeepa` で `profitInputs` を組み立てる:
  - `breakEven.new` = `prices.new` があれば `computeKeepaBreakEven(product, prices.new)`、無ければnull。
  - `breakEven.used` も同様。stats最安値は送料不明のためlandedとみなす（第2段階statsフォールバックと同じ扱い）。

### 1-2. SP-API経路（`routes.js handleSearchViaSpApi` + `spapi/pricing.js`）

- `pricing.extractOffersSummary` の戻り値に `totalOfferCount`（`payload.Summary.TotalOfferCount`。
  無ければ `offers.length`、payloadなしはnull）を追加する。
- `handleSearchViaSpApi` で、既に組み立て済みの `offers` ペイロード（各オファーに `breakEven` 付き）から
  `profitInputs` を導出するヘルパー `buildProfitInputs(newSummary, usedSummary, offersPayload)` を追加:
  - `listPrice`: 常に null（実質取得不可）。
  - `sellerCounts`: `newSummary.totalOfferCount` / `usedSummary.totalOfferCount`。
  - `breakEven.new` / `.used`: 各バケットで `landed` 最安のオファーの `breakEven`（手数料計算の二重実装を避け、
    `buildSpApiOffersPayload` の結果を再利用する）。オファー0件はnull。

### 1-3. サーバーテスト（`server/test`）

- `keepa.test.js`: `mapProductToSearchResult` の listPrice / sellerCounts（値あり・-1・欠落配列）を追加。
- 新規または `pricing.test.js` 追記: `extractOffersSummary` の `totalOfferCount`。
- ルートレベル: 両経路の `/api/search` 応答に `profitInputs` キーが常に存在すること
  （キーパリティ、unresolved時のnull含む）をfetchモックで検証。

---

## 2. iOS: 設定モデル（SettingsStore）

`SettingsStore` に以下を追加する。既存の `Keys` enum / `@Published var + didSet` / `init` 読み込みの作法に合わせる。
数値はすべて円の整数。**既定は全条件OFF**（既存ユーザーの挙動を変えないため）。

| プロパティ | UserDefaultsキー | 型 | 既定値 |
|---|---|---|---|
| `profitAlertMarginEnabled` | `settings.profitAlert.marginEnabled` | Bool | false |
| `profitAlertMarginThreshold` | `settings.profitAlert.marginThreshold` | Int | 300 |
| `profitAlertPurchaseCost` | `settings.profitAlert.purchaseCost` | Int | 0 |
| `profitAlertTargetCondition` | `settings.profitAlert.targetCondition` | String("new"/"used") | "used" |
| `profitAlertRankEnabled` | `settings.profitAlert.rankEnabled` | Bool | false |
| `profitAlertRankThreshold` | `settings.profitAlert.rankThreshold` | Int | 100000 |
| `profitAlertSellerCountEnabled` | `settings.profitAlert.sellerCountEnabled` | Bool | false |
| `profitAlertSellerCountThreshold` | `settings.profitAlert.sellerCountThreshold` | Int | 10 |
| `profitAlertListPriceEnabled` | `settings.profitAlert.listPriceEnabled` | Bool | false |

- `profitAlertTargetCondition` は `enum ProfitAlertCondition: String { case new, used }` として定義し、
  rawValueで保存する（不正値読込は `.used` フォールバック）。**粗利の売値と出品者数の両方**がこの
  コンディションを参照する（条件ごとに別々のコンディションは持たない=YAGNI）。
- マスタートグルは設けない。**全条件OFF = 機能無効**とする。

### iOSモデル（`SearchModels.swift`）

`SearchResult` に `profitInputs` を追加。旧サーバー互換のため全てオプショナル
（`brand` 等と同じコメント様式で「旧サーバーではnil」と明記する）。

```swift
/// /api/search の利益アラート用素材。旧サーバーではキーごと無いためnil。
struct ProfitInputs: Codable, Equatable {
    let listPrice: Int?
    let sellerCounts: ConditionCounts?
    let breakEven: ConditionBreakEven?

    struct ConditionCounts: Codable, Equatable {
        let new: Int?
        let used: Int?
    }
    /// breakEvenはサーバーが小数で返すためDouble(OffersModels.Offer.breakEvenと同じ理由)。
    struct ConditionBreakEven: Codable, Equatable {
        let new: Double?
        let used: Double?
    }
}
```

---

## 3. 判定ロジックの置き場所と仕様

新規ファイル `ios/BarcodeSedori/Sources/Models/ProfitAlertEvaluator.swift` に**純粋な判定型**として置く
（ViewModel直書きにしない理由: UIKit/Combine非依存にして判定表を単体で検証可能に保ち、
Phase 1b以降の再利用にも備える）。

```swift
/// 利益アラートの判定(純関数)。設定スナップショットとSearchResultだけを見る。
struct ProfitAlertEvaluator {
    struct Verdict: Equatable {
        let isTriggered: Bool
        /// 表示用の粗利(円)。粗利条件OFFや算出不能時はnil。
        let grossMargin: Double?
    }
    static func evaluate(result: SearchResult, settings: /* 設定値のスナップショットstruct */) -> Verdict
}
```

判定規則（AND。**ONの条件がデータ不足で判定できない場合は不成立=非発火**が原則。安全側に倒す）:

| 条件 | 成立 | データ欠落時 |
|---|---|---|
| 粗利 | `profitInputs.breakEven[対象コンディション] − 仕入れ値 ≥ 閾値` | 不成立 |
| ランキング | `salesRank ≤ 閾値` | 不成立 |
| 出品者数 | `sellerCounts[対象コンディション] ≤ 閾値` | 不成立 |
| 売値≥定価 | `売値(prices[対象コンディション]) ≥ listPrice` | **listPrice==nilのみスキップ**(他条件で判定)。売値nilは不成立 |

- 全条件OFF → 非発火。
- **定価条件のみONで listPrice==nil**（スキップの結果、判定した条件が0個）→ 非発火とする。
- SearchTabViewModel側: `@Published var profitAlertVerdict: ProfitAlertEvaluator.Verdict?` を追加。
  `handleScan` でリセットし、`search(code:)` 成功時に `EntitlementStore.shared.isPro` のときだけ評価する。
  発火時に `UINotificationFeedbackGenerator().notificationOccurred(.success)` を1回だけ鳴らす
  （既存 `ScannerView` のハプティクス作法と同じAPI）。

### 境界条件のテスト観点（シミュレータ確認時に閾値を動かして必ず踏む）

| ケース | 期待 |
|---|---|
| 粗利 == 閾値 | 発火（「以上」） |
| 粗利 == 閾値−1円 | 非発火 |
| salesRank == 閾値 | 発火（「以内」） |
| salesRank == 閾値+1 | 非発火 |
| 出品者数 == 閾値 | 発火（「以下」） |
| 出品者数 == 閾値+1 | 非発火 |
| 売値 == 定価 | 発火（「以上」） |
| 定価条件ON・listPrice==nil・他条件成立 | 発火（定価だけスキップ） |
| 定価条件のみON・listPrice==nil | 非発火 |
| ON条件のbreakEven/sellerCounts==nil（旧サーバー） | 非発火 |
| 全条件OFF | 非発火 |
| 無料ユーザー・条件成立 | 非発火（評価自体しない） |

---

## 4. 強調表示UI（緑バナー＋ハプティクス）

`SearchTabView.swift` の `LatestResultCardView` を拡張する:

- `LatestResultCardView` に `let profitVerdict: ProfitAlertEvaluator.Verdict?` を追加し、
  発火時のみカード上部に緑バナー行を出す:
  - `HStack`: `checkmark.circle.fill` + 「利益条件クリア」＋ `grossMargin` があれば「粗利 ¥xxx」
    （`.font(.caption).fontWeight(.bold).foregroundColor(.white)`、背景 `Color.green`、`cornerRadius(8)`）。
- あわせてカード全体を `overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green, lineWidth: 2))` で縁取る
  （カードは現在囲み枠なしのため、発火時のみ枠を付けると視認差が大きい）。
- ハプティクスはViewではなくViewModel（判定確定時）で1回。再描画で多重発火させない。

## 5. Proゲート

- **設定画面**: `SettingsView` の「プラン」セクション直下に `Section("利益アラート")` を追加。
  - Proのとき: 各条件のToggle＋閾値入力（`TextField(value:format:.number)` + `.keyboardType(.numberPad)`）、
    コンディションPicker（新品/中古）、仕入れ値入力、定価条件Toggle、説明文（`.footnote`）。
  - 無料のとき: 検索タブ `freeAdArea` と同じ作法で `lock.fill` ＋「利益アラートはProで」行のみ表示し、
    タップで `showPaywall = true`（既存 `.sheet(isPresented:) { PaywallView() }` を流用）。設定値には触らせない。
- **判定側**: `SearchTabViewModel` で `isPro` のときのみ評価（無料は設定が残っていても発火しない二重ゲート）。
- **サーバー**: `profitInputs` は追加コストゼロのためゲートしない（判定材料を返すだけ。既存の
  自己申告 `X-App-Plan` 方式とも整合）。

---

## 6. 実装ステップ（各ステップ単独でビルド・確認可能な単位）

| # | 内容 | 完了条件 |
|---|---|---|
| 1 | サーバー: `keepa/client.js` に `CSV_TYPE.COUNT_NEW/COUNT_USED` 追加、`mapProductToSearchResult` に listPrice/sellerCounts 追加、`keepa.test.js` 追記 | `cd server && npm test` 全緑 |
| 2 | サーバー: `computeKeepaBreakEven` 共通化、`extractOffersSummary` に totalOfferCount、両経路に `profitInputs` 付与、テスト追記 | `npm test` 全緑＋ローカル起動しKeepa/SP-API両経路の `/api/search` を実コードでcurlし、`profitInputs` キーパリティを目視 |
| 3 | iOS: `SearchModels.swift` に `ProfitInputs` 追加（デコードのみ、UI未接続） | iOSビルド成功＋シミュレータで既存のスキャン表示に退行なし |
| 4 | iOS: `SettingsStore` 拡張＋`SettingsView` の利益アラート設定セクション＋無料Paywallゲート | シミュレータで設定変更→アプリ再起動後も保持、無料切替でPaywall表示をスクショ確認 |
| 5 | iOS: `ProfitAlertEvaluator` 新規＋`SearchTabViewModel` 判定＋緑バナー/縁取り＋ハプティクス | シミュレータで実スキャン値に対し閾値を上下させ、§3の境界表（一致/未満/超過）を確認しスクショ |
| 6 | 互換確認と仕上げ: 旧サーバー相当（`profitInputs` 無し応答）での非発火確認、スペックのリンク整合、コミット | 手元サーバーを1コミット前で起動して新アプリが正常動作（アラート非発火・表示退行なし） |

- 各ステップ完了ごとに自動コミット（プロジェクト標準ルール）。サーバーは手動デプロイのため、
  ステップ2完了後もデプロイするまで本番には反映されない点に注意（Keepaキーもローカルに無い →
  Keepa経路のローカル確認はfetchモックのテストとステージング/本番デプロイ後の実機確認で補う）。

## 7. 後方互換の注意点

- **旧サーバー × 新アプリ**: `profitInputs` キーが無い → `SearchResult.profitInputs == nil` →
  粗利・出品者数・定価条件は判定不能で非発火（ランキング条件のみONなら `salesRank` で判定可能）。
  クラッシュ・表示退行なし。
- **新サーバー × 旧アプリ**: 追加キーはCodableが無視するため影響なし。`/api/offers` 契約は変更しない。
- **旧保存データ**: 追加する設定キーは未設定→既定値（全条件OFF）で読み込むため、既存ユーザーの挙動は不変。
  既存キーの移行処理は不要。
- **キャッシュ**: `searchCache` はインメモリのためデプロイで消える。旧形式キャッシュ残留の考慮は不要。
- **Keepaトークン**: 本機能で `/api/search`（第1段階1トークン）以外のKeepa呼び出しを一切増やさないこと。
  `offers` パラメータを付ける変更はレビューで必ず却下する。

## 8. やらないこと（YAGNI）

- 条件ごとの個別コンディション選択（対象コンディションは1つの共通設定）
- Keepa経路の中古細分（ほぼ新品/非常に良い/良い/可）判定（offers必須のため）
- サーバー側での閾値判定・プッシュ通知・相場監視
- SP-APIの `attributes.list_price` 取得の試行（実質取得不可として扱う）
