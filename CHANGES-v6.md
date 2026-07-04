# 改修仕様 v6 — 検索画面UI刷新 + Keepa API統合 (2026-07-04)

目的:
1. SP-API未連携ユーザー(小口出品者等)でも使えるよう、Keepa APIをデータソースとして追加
2. 検索画面をAmacode風UIに刷新: スキャン→即基本情報カード表示→同一画面に新品/中古オファー一覧(青/オレンジ2カラムパネル)→Keepa価格グラフ

## データ取得の2段階フロー(共通)

**第1段階(スキャン直後・最速表示)**: 商品画像 / タイトル / ISBN・JAN / ランキング / 新品最安値 / 中古最安値
- SP-API連携済み(X-Spapi-Refresh-Tokenヘッダーあり or .envにLWA_REFRESH_TOKEN): 既存のSP-API経路
- 未連携: Keepa product リクエスト(**offersなし=1トークン**)で取得
**第2段階(カード表示後に自動追加取得)**: 出品者数と各セラーの価格一覧
- SP-API: 既存 /api/offers (getItemOffers)
- Keepa: product リクエストに offers=20 を付けて再取得(+6トークン)
**グラフ**: KEEPA_API_KEYがサーバーにあれば、ソースを問わずKeepaグラフ画像を表示

## サーバー実装

### 環境変数 (.env.example追記)
```
KEEPA_API_KEY=           # Keepa APIキー(任意。未設定ならKeepa経路とグラフは無効)
```

### src/keepa/client.js (新規・依存ゼロ)
Keepa API (https://api.keepa.com) クライアント。実装前にWebSearch/web_fetchで
公式ドキュメント(keepa.com/#!discuss/t/product-object 等)を確認し、フィールド仕様を検証すること。
- 日本のdomain ID: **5** (amazon.co.jp)
- `getProduct({ code | asin, offers })`: GET /product?key=&domain=5&(code=JAN/ISBN13|asin=)&stats=90&history=0(&offers=20)
  - 価格は日本円の整数(-1=データなし)
  - stats.current 配列: index 0=Amazon本体価格, 1=新品最安(送料込みは stats.buyBoxPrice等と別), 2=中古最安, 3=売れ筋ランキング, 18=BuyBox(要buybox。今回は不要なら省略可)
  - 画像: imagesCSV の先頭 → `https://images-na.ssl-images-amazon.com/images/I/{name}`
  - タイトル: title / コード: eanList・asin
  - offers指定時: offers配列。各offerの現在価格は offerCSV の末尾(価格,送料のペア履歴)から取得。
    condition (int): 1=New, 2=Used-LikeNew(ほぼ新品), 3=Used-VeryGood(非常に良い), 4=Used-Good(良い), 5=Used-Acceptable(可) ※実装時に公式定義を確認して正確に
    lastSeenが古い(24h超)オファーは除外してよい
- トークン枯渇(HTTP 429 / tokensLeft<0)時は `{error:'keepa_tokens_exhausted'}` を返しHTTP 503にマップ

### /api/search 変更 (routes.js)
1. SP-API認証情報が解決できる → 既存SP-API経路(変更なし)、レスポンスに `source:"spapi"` 追加
2. 解決できない かつ KEEPA_API_KEY あり → Keepa第1段階(offersなし)で同じJSON契約にマッピング:
   `{codeType, asin, title, isbn13, imageUrl, salesRank, prices:{cart:null,new,used,points:{...null}}, source:"keepa"}`
   (KeepaのcartはBuyBox追加トークンが要るため第1段階ではnull)
3. どちらも無い → 従来どおり503 spapi_credentials_missing(メッセージは「SP-API連携またはサーバーのKeepa設定が必要です」に変更)

### /api/offers 変更
クエリ: `asin=&source=spapi|keepa`(未指定はspapi)。レスポンス契約を統一:
```json
{
  "source": "keepa",
  "referencePrice": 1700,
  "newCount": 6, "usedCount": 6,
  "new":  [ {"price":1500,"shipping":0,"landed":1500,"condition":"new","isBuyBox":false,"breakEven":1230} ],
  "used": [ {"price":1200,"shipping":350,"landed":1550,"condition":"good", ...} ]
}
```
- condition文字列: "new" | "like_new" | "very_good" | "good" | "acceptable"
- spapi経路: 既存実装を契約に合わせて整形(conditionはSubConditionから変換)。breakEven既存ロジック維持
- keepa経路: offers=20で取得しマッピング。breakEvenはKeepa productの referralFeePercent と fbaFees(pickAndPackFee) が取れれば `landed - landed*referralFee% - 成約料80(書籍のみ) - FBA手数料` の近似計算、取れなければ書籍フォールバック(15%+80円)
- newCount/usedCount: オファー配列の件数(Keepaは stats.offerCountFBA等でなくoffers配列から数える)

### GET /api/graph?asin= (新規)
Keepaグラフ画像のプロキシ(APIキーをアプリに晒さないため必須):
- KEEPA_API_KEY未設定なら404
- `https://api.keepa.com/graphimage?key=&domain=5&asin=&salesrank=1&amazon=1&new=1&used=1&range=90&width=1000&height=400` をfetchし image/png をそのまま返す
- サーバー内メモリキャッシュ1時間(LruCache流用、Buffer保存)

### テスト (test/keepa.test.js 新規)
- Keepaモックレスポンス→search契約へのマッピング(価格-1→null、画像URL組み立て)
- offerCSV末尾からの価格+送料抽出、condition変換
- /api/offersの統一契約(spapi/keepa両モック)
- graphプロキシのキー未設定404

## iOS実装 (検索タブ全面刷新)

### レイアウト(上から、参考スクリーンショット準拠)
1. **検索バー**: 「商品名、JANコードで検索」プレースホルダのTextField。数字のみ(10/13桁)ならコード検索として/api/searchへ。それ以外のキーワードは今回は非対応(「キーワード検索は今後対応予定です」アラート)
2. **カメラプレビュー**(既存ScannerView、高さは画面の約35%)
3. **バーコード/OCRトグル**(既存)
4. **最新スキャン結果カード**(リストではなく最新1件を表示。履歴は既存の商品タブが担う):
   - 左: 商品画像(AsyncImage) + 「本」バッジ(codeTypeがisbnのとき)
   - タイトル(2行) / コード表示(バーコードアイコン+数字) / ランキング: n位
5. **オファーパネル(横並び2カラム)**: 
   - 左: 青背景(#2196F3系) ヘッダー「新品(出品者数n人)」、行=コンディション名+価格(太字白文字)。最大7行
   - 右: オレンジ背景(#FF9800系) ヘッダー「中古(出品者数n人)」、同様
   - 条件表示名: new→新品 / like_new→ほぼ新品 / very_good→非常に良い / good→良い / acceptable→可
   - 読み込み中はパネル内にProgressView。タップで既存のProductDetailView(損益分岐点画面)へ遷移(source=spapiのときのみ)
6. **Keepaグラフ**: AsyncImageで `{サーバーURL}/api/graph?asin=` を表示(404なら非表示)。横幅いっぱい、角丸
### 挙動
- スキャン/コード検索 → /api/search(第1段階)→ カード即表示 → 自動で /api/offers?asin=&source= を取得しパネル充填 → グラフはAsyncImageが並行ロード
- 新しいスキャンが来たらカード・パネル・グラフを差し替え
- SearchModels: SearchResultに `source: String?` 追加。OffersModelsを新契約(source/newCount/usedCount/condition文字列)に更新
- 既存のスキャン履歴保存(ScanHistoryStore)は維持

## 注意
- KEEPA_API_KEYは購入後にRender/ローカル.envに設定(未設定でも従来動作を壊さない)
- Keepaの実フィールド名・condition定数・トークンコストは実装時にWeb上の公式ドキュメントで必ず裏取りし、相違があればこの仕様より公式を優先
- DESIGN.md/CHANGES-*.mdは編集禁止。README更新は可
