# セッション引き継ぎ（2026-07-21 時点）

アプリ名: **アマレンズ**（旧「バーコードせどり」）。Amazonセラー向けの仕入れリサーチiPhoneアプリ。

## 関連リポジトリ

| 対象 | 場所 | デプロイ |
|---|---|---|
| iOSアプリ＋サーバー | このディレクトリ / `yuriasu2/-barcode_sedori` | サーバーは**手動** `cd server && npx wrangler deploy` |
| LP(sellira.jp) | `~/Claude/Projects/sellira-site` / `yuriasu2/sellira-site` | push→Cloudflare Pages が自動 |

両リポジトリとも作業ツリーはクリーン・push済み。

## 直近の作業（完了済み）

**検索結果ヘッダーにブランド・サイズ・重量を追加**（コミット `c3556b1`〜`e6fce57`）

Keepaの `/product` レスポンスに元から含まれる `brand` / `packageLength|Width|Height` / `packageWeight` を表示。追加のAPI呼び出し・トークン消費はなし。表示は次の形。

```
9784566034600      ブランド：評論社
ランク: 264,671位   サイズ：25.2x18x1.4 cm　440g
```

- 寸法・重量の「データなし」はKeepaでは `0` または `-1`。既存の `normalizePrice` は0を通すため、`normalizeDimension`（0以下→null）を新設した。
- SP-API経路にはこれらの情報が無いため明示的に `null` を返し、キーの有無をブレさせない。
- レイアウト調整の経緯: HStack末尾の `Spacer` がテキストから横幅を奪い `minimumScaleFactor` の自動縮小を誘発していたため削除済み。**最終的な見た目はユーザーが実機で確認中**（未確認のまま）。

## 次にやること（優先度順）

### 1. Amazon 販売パートナーアプリストアの掲載申請

Solution Provider Portal のフォームを記入中。記入案は `APPSTORE-LISTING-DRAFT.md`（※対応商品を書籍→全商品へ広げた最新版は下記）。

- 製品URL: `https://sellira.jp/amalens/` ／ サポートURL: `https://sellira.jp/support/`
- サポートEメール: `saastids2025@gmail.com` ／ 電話は**空欄推奨**（Amazonがテスト架電する可能性）
- 出品カテゴリー: `商品調査およびスカウト`／機能: `商品調査およびスカウト`＋`分析とレポート`
- **サポートするプログラムは未選択**（下記の課題2があるためFBA/MFNどちらにもチェックしない）
- 価格設定モデルは「無料」を選び、説明欄でProプラン（月額1980円・3日間無料体験）を明記
- ロゴは `design/amalens-logo-1024.png` を詳細ページ用・カテゴリタイル用の両方に使う（要件は「最小」300/220なので1024でよい）
- フォーム内は半角の `" ' & < > $` が使用不可

掲載内容は**実装済み機能のみ**とする方針。出品機能などは完成後に Edit Listing で追記する（公開後も編集可能・編集中も掲載は公開継続、と公式で確認済み）。

### 2. 【要対応】損益分岐点がFBA固定になっている

`server/src/spapi/pricing.js` の `IsAmazonFulfilled: true` がハードコードで、切り替え手段がない。一方で設計上の出品機能は**自己発送(MFN)のみ**なので、自己発送セラーには実態と合わない損益分岐点が出る。設定でFBA/自己発送を切り替えるのが本筋（`IsAmazonFulfilled` を設定値から渡すだけで実装は軽い）。

### 3. 出品機能・利益アラートの実装

設計書: `docs/superpowers/specs/2026-07-19-listing-and-profit-alert-design.md`（**設計承認済み・実装未着手**）

- Phase 1: 利益アラート（損益分岐点が閾値以上で強調）＋仕入れリスト
- Phase 2: アプリ内出品（自己発送のみ、Listings Items API）
- Product Listing ロールは承認済み。ただし**アプリにロールを追加すると既存の連携ユーザー全員が再認可必要**になるため、Phase 2着手時にまとめて行う。

### 4. リリース前に必ず消すもの

- 設定画面の開発者向けトグル「サーバー側SP-APIを使用する」
- SP-APIリフレッシュトークンの手入力欄（DisclosureGroup内）
- AdMobのテストID → 本番IDへ差し替え、SKAdNetwork全リスト追加
- バンドルID `com.example.barcodesedori` の変更
- 掲載承認後: `server/src/oauth.js` の `version=beta` を外す

### 5. 保留中

- Keepaトークン枯渇対策（`KEEPA-TOKEN-PLAN.md` Phase 1）— ユーザー指示で保留中
- Render の削除（Cloudflare移行済み。`LWA_REFRESH_TOKEN` が残っているので消す）

## 作業ルール（プロジェクト固有）

- 変更完了ごとに確認なしでコミットする
- iOS変更は毎回ビルド＋シミュレータで確認（ただし今回のように「検証は自分でやる」と言われたらビルドのみ）
- 要件定義・計画・レビューはFable5、設計相談・複雑なバグ調査はOpus、実装・単純作業はSonnetのサブエージェントへ委任、質問への回答はSonnet
