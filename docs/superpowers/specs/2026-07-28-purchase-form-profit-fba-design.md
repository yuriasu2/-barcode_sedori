# 仕入れフォーム拡張(利益表示・FBA・仕入れ情報) 設計書

- 作成: 2026-07-28 / 起案: ユーザー要望
- 状態: **ユーザー承認済み・実装着手**
- 対象: iOSアプリ + サーバー(Cloudflare Workers)

## 目的

仕入れフォーム上で粗利益をその場で確認できるようにし、仕入れ判断の質を上げる。
あわせてFBA出品の第一段階(FBA SKU作成)と、仕入れ記録(日付・仕入先・メモ)を追加する。

## 決定事項(ユーザー確認済み)

| 論点 | 決定 |
|---|---|
| FBAチェックの場所 | 設定(デフォルト値) + フォーム(商品ごと切替)の両方 |
| 粗利益の式 | 出品価格 − 仕入れ価格 − 手数料 − 配送料 |
| 手数料の計算 | SP-API手数料見積りAPIで実額取得(未連携Proは概算フォールバック) |
| メモの用途 | 自分用の内部メモ(出品には使わない) |

## 1. 設定側 — 新画面「仕入れ設定」

設定タブ「出品」セクションに NavigationLink「仕入れ設定」を追加(Pro限定・既存の出品系と同じ作法)。
新画面 `PurchaseSettingsView` の内容:

- **FBAを利用**(トグル) — フォームのデフォルト値。既定OFF
- **配送料デフォルト**(円・numberPad) — フォームの配送料初期値。既定0円
- **仕入先の管理** — 文字列リストの追加・削除(スワイプ削除)。並びは追加順

SettingsStore追加キー:

- `purchase.useFbaDefault: Bool`(既定false)
- `purchase.shippingDefault: Int`(既定0)
- `purchase.suppliers: [String]`(既定空)
- `purchase.lastSupplier: String?`(フォームで最後に選んだ仕入先。lastListingConditionと同方式)

## 2. 仕入れフォームの拡張

セクション構成(上から):

1. 商品(既存のまま)
2. 出品制限(既存のまま)
3. 仕入れ内容: コンディション / **出品価格(円)**(既存「価格(円)」を改名) / SKU / 数量 / **FBAを利用**(トグル)
4. **利益**(新設):

   | 行 | 表示 | 色 | 入力 |
   |---|---|---|---|
   | 出品価格 | 仕入れ内容の出品価格を反映 | 標準 | 表示のみ |
   | 仕入れ価格 | | 赤 | 入力可(numberPad) |
   | 手数料 | 合計額。タップで内訳展開 | 赤 | 表示のみ |
   | 配送料 | 初期値=設定の配送料デフォルト | 赤 | 入力可(numberPad) |
   | 粗利益 | 出品価格−仕入れ価格−手数料−配送料 | 青・太字 | 表示のみ |

   - 手数料行はDisclosureGroupで展開し、**販売手数料 / カテゴリ成約料 / 消費税 / FBA手数料**を表示。
     FBAトグルOFF時はFBA手数料行を出さない
   - 概算フォールバック時は「(概算)」を手数料行に付記
   - 出品価格・仕入れ価格が未入力の間、粗利益は「—」表示
5. **仕入れ情報**(新設): 仕入れ日(DatePicker・日付のみ・既定=追加日) / 仕入先(Picker: 「未選択」+登録済みリスト、既定=前回選択) / メモ(TextField・自分用)
6. コンディション説明(既存のまま)

FBAトグルの初期値: 新規追加=設定のデフォルト、編集=保存値(旧データは設定のデフォルト)。

## 3. 手数料の取得

### サーバー: 新エンドポイント `GET /api/fees-estimate`

- クエリ: `asin`(必須) / `price`(必須・整数円) / `fba`(`1`|`0`、既定`0`)
- ゲート: `requireProByoCredentials`(Pro + BYOトークン + sellerId)
- 実装: 既存 `pricing.getMyFeesEstimatesBatch` を1件で呼び、`IsAmazonFulfilled` を `fba` に連動
- レスポンス:

```json
{
  "total": 680,
  "breakdown": [
    { "type": "referral", "label": "販売手数料", "amount": 270 },
    { "type": "closing", "label": "カテゴリ成約料", "amount": 80 },
    { "type": "tax", "label": "消費税", "amount": 62 },
    { "type": "fba", "label": "FBA手数料", "amount": 268 }
  ]
}
```

- FeeDetailListのFeeTypeをマッピング(ReferralFee→referral / VariableClosingFee等→closing / FBAFees系→fba)。
  未知のFeeTypeは`other`として金額を落とさず含める
- 消費税: FeeDetailListのTaxAmount合計。全て0の場合は手数料小計の10%を概算として返し、totalにも含める
  (実応答での挙動は実装時に実データで検証し、コメントに記録する)
- 手数料はSKU非依存・出品内容を含まないためDPP上の懸念なし。ログにSKU等は出さない(従来方針)
- キャッシュ: なし(価格ごとに変わるため。BYO枠なので共有コストもない)

### iOS: 取得タイミングとフォールバック

- 取得トリガー: フォーム表示時 / 出品価格変更時(0.5sデバウンス) / FBAトグル切替時
- 制限チェックと同じ連番ガードで古い応答を破棄
- **SP-API未連携のPro**: 通信せずアプリ内概算 = 販売手数料15% + 成約料80円 + 消費税(小計の10%)。
  FBA手数料は算出不可のため、FBAトグルON時は内訳に「FBA手数料: 連携が必要」と表示し合計に含めない。
  手数料行に「(概算)」付記
- 取得失敗時: 概算フォールバックに切り替え「(概算)」表示

## 4. FBA出品への反映(Phase 2拡張)

- サーバー `buildListingItemBody` に `fulfillmentChannel`('DEFAULT'|'AMAZON_JP')入力を追加:
  - `DEFAULT`(自己発送): 従来通り `{ fulfillment_channel_code: 'DEFAULT', quantity }`
  - `AMAZON_JP`(FBA): `{ fulfillment_channel_code: 'AMAZON_JP' }` **quantityは送らない**
    (FBA在庫は納品で決まる。納品プラン作成はスコープ外=セラーセントラルで行う)
- `/api/listings/items` のバリデーションに `fulfillmentChannel` を追加(省略時DEFAULT)
- iOS一括出品(BulkListingViewModel): 各商品の `useFba` からfulfillmentChannelを同梱

## 5. データモデル(PurchaseListItem追加フィールド)

全てOptionalで旧データ互換(既存JSONデコードを壊さない):

- `useFba: Bool?` — FBA出品するか。nil=設定デフォルト扱い
- `purchasePrice: Int?` — 仕入れ価格(円)
- `shippingCost: Int?` — 配送料(円)
- `purchaseDate: Date?` — 仕入れ日。nil=addedAt扱い
- `supplier: String?` — 仕入先名(自由文字列。リストから削除されても保存値は残す)
- `memo: String?` — 内部メモ

手数料・粗利益は**保存しない**(表示のたびに計算)。

## やらないこと(YAGNI)

- FBA納品プラン連携(Fulfillment Inbound API) — 需要確定後の第二段階
- 仕入れタブ一覧への粗利益表示(要望があれば別途)
- 手数料のサーバーキャッシュ
- 仕入先の編集・並べ替え(追加・削除のみ)

## 検証方針

- サーバー: fees-estimateの単体テスト(FeeDetailListマッピング・fba分岐・ゲート)、
  listingsのfulfillmentChannel分岐テスト。全テスト緑
- iOS: Debug/Releaseビルド成功。シミュレータで
  仕入れ設定(FBA/配送料/仕入先登録)→フォームで利益セクション表示・内訳展開・粗利益計算・
  仕入れ情報入力→保存→再編集で値が残ることをスクリーンショット確認
- 本番SP-APIでfees-estimateの実応答(消費税の返り方)を確認してからデプロイ
