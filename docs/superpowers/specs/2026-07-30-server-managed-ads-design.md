# サーバー管理型 広告配信システム 設計書

- 作成: 2026-07-30 / 起案: ユーザー要望
- 状態: **実装済み**(2026-07-30)
- 対象: iOSアプリ + サーバー(Cloudflare Workers)

## 目的

広告の中身(AdMob/アフィリエイト/ASP)と配置をサーバーで一元管理し、
**アプリ更新なし・サーバーデプロイなし**で広告の追加・差し替え・停止をできるようにする。
AdMobを基盤に、せどりの文脈に合う場所へアフィリエイト導線を混ぜるハイブリッド構成。

## 決定事項(ユーザー指示)

| 論点 | 決定 |
|---|---|
| 広告枠 | 検索タブ(グラフ位置・無料のみ) + 商品/仕入れ/設定タブの下部固定枠 |
| **Proへの表示** | **Proは全枠で広告なし**(2026-07-30に方針変更。当初は下部枠をProにも出す予定だった) |
| 設定タブ | 大タイトル「設定」を削除し、広告枠を置く |
| 管理方法 | サーバー(Cloudflare KV)で枠ごとに配信内容を管理 |
| Amazonアソシエイト | 見送り(アプリ審査必須+価格キャッシュ24時間制限がKeepaグラフと両立しない) |

## Proの「広告なし」表記について(経緯)

一時「Proにも下部枠を表示する」方針だったため、ペイウォールの
「広告なし」「すべての機能を制限なく、広告なしで。」を実態に合わせて書き換えた。
その後 **Proは全枠で広告なし** に戻したため、これらの文言も元に戻してある
(PaywallView / SearchTabViewの誘導文とも「広告なし」「広告削除」表記が正)。

方針を再び変える場合は、**ペイウォール文言の同時修正が必須**(虚偽表示になるため)。

## 1. 広告枠(スロット)の定義

| slot id | 場所 | 対象 | 高さ |
|---|---|---|---|
| `search_ad` | 検索タブ・グラフの位置 | 無料のみ(Proはグラフ表示) | 広告に従う |
| `products_bottom` | 商品タブ下部(タブバー直上) | 無料のみ | 広告に従う |
| `purchase_bottom` | 仕入れタブ下部 | 無料のみ | 広告に従う |
| `settings_bottom` | **設定タブ上部**(大タイトルを外した位置) | 無料のみ | 広告に従う |

- **Proは全枠で非表示**。アプリ側で一律に止めるため、サーバーのaudience指定に関わらず出ない
- **AdMobはどの枠でもアダプティブバナー**で描画する(サーバーのsize指定は使わない)。
  高さは端末幅から同期算出されるため枠ごとの決め打ちが不要で、同一端末では常に同じ高さになり
  タブ切替でレイアウトが跳ねない。自社バナー(custom)のみ枠側で高さを固定する
- 1画面に広告は1枠まで(AdMobポリシー: 誤タップ誘発・広告の出所が紛らわしい配置の回避)
- 設定タブは大タイトル「設定」(navigationTitle)を削除し、その位置に広告枠を置く
  (商品/仕入れタブで大タイトルを消した先例に合わせる)。
  設定タブの枠だけは `safeAreaInset(edge: .top)` を **NavigationViewの内側(Form)** に付ける。
  外側に付けるとForm側の余白計算に反映されず、先頭セクションの見出しが枠の下に潜り込む

## 2. サーバー API

### GET /api/ads

認証不要(広告設定に秘匿情報を含めない)。応答例:

```json
{
  "version": 3,
  "slots": {
    "search_ad": {
      "type": "admob",
      "unitId": "ca-app-pub-xxxx/yyyy",
      "size": "mediumRectangle",
      "audience": "free"
    },
    "products_bottom": {
      "type": "custom",
      "id": "rakuten-books-202608",
      "imageUrl": "https://api.sellira.jp/ads/rakuten-books.png",
      "linkUrl": "https://hb.afl.rakuten.co.jp/...",
      "width": 320, "height": 50, "fit": "native",
      "audience": "all"
    },
    "purchase_bottom": { "type": "admob", "unitId": "...", "size": "adaptive", "audience": "free" },
    "settings_bottom": null
  }
}
```

契約:

- `type`: `"admob"` | `"custom"`。スロットが `null` なら枠ごと非表示
- `size`(admob): 契約上は `"adaptive"` | `"banner"` | `"largeBanner"` | `"mediumRectangle"` を
  受け付けるが、**アプリは常にアダプティブで描画するため現在この指定は無視する**
  (将来固定サイズへ戻せるよう契約には残す)
- `custom`: 画像実寸(`width`/`height`)をサーバーが申告。`fit: "native"`=実寸中央寄せ(既定・推奨)、
  `"fill"`=幅いっぱい(高解像度素材があるときのみ)
- `audience`: `"all"` | `"free"`。**現在アプリはProに一切広告を出さないため判定に使っていない**
  (無料ユーザー内での出し分けに使えるよう契約には残す)
- `id`(custom): 計測用の広告識別子

### 配信在庫の管理

- 設定本体は **Cloudflare KV** に置く(`ADS_CONFIG` キーにJSON)。差し替えは
  `wrangler kv key put` 一発で、**サーバーのデプロイも不要**
- KV未設定時は全スロット `null` を返す(=広告なし。安全側)
- Workerは60秒程度メモリキャッシュしてKV読み取り回数を抑える
- バナー画像は当面 R2 か静的ファイルとしてWorkerから配信(`/ads/*.png`)。
  外部URL(ASPのサーバー)直参照でもよいが、リンク切れ時に枠が壊れるため自前配信を推奨

### POST /api/ads/event (計測)

```json
{ "slot": "products_bottom", "adId": "rakuten-books-202608", "kind": "impression" | "click" }
```

- 個人情報・端末IDは送らない(集計は日次×広告ID×種別のカウントのみ)
- 保存先はKV(日付キーのカウンタ)。当面はこれで足り、伸びたらAnalytics Engineへ移行
- AdMob枠の計測はAdMob管理画面があるため送らない(customのみ)

## 3. iOS実装

### AdSlotView(共通ビュー・新規)

- 入力: slot id。サーバー設定(キャッシュ済み)から該当スロットを引いて描画:
  - `admob` → 既存BannerAdViewを拡張(adaptive対応・unitIdを引数化)
  - `custom` → AsyncImageで画像表示、タップでSafariView(アプリ内ブラウザ)、表示時/タップ時に計測送信
  - スロットなし/取得失敗/**Pro** → EmptyView(高さも取らない)
- AdMobはアダプティブの算出高さ、customは枠側の指定高さで確保する

### AdsConfigStore(新規)

- 起動時に `/api/ads` を1回取得してメモリ+UserDefaultsにキャッシュ
  (次回起動はキャッシュ即表示→裏で更新。取得失敗時はキャッシュ、それも無ければ広告なし)
- 現在の `AdsConfig.bannerAdUnitID` 定数(テスト用ID直書き)はこのストア経由に置き換える

### 配置

- RootTabView: 商品/仕入れ/設定の各タブに `.safeAreaInset(edge: .bottom)` で
  下部枠を挿入(タブバーの直上に固定)。検索タブには入れない
- SettingsView: `.navigationTitle("設定")` を削除し、商品/仕入れタブと同じくナビバー非表示化
- SearchTabView: 既存 `freeAdArea` を `AdSlotView(slot: "search_ad")` ベースに置き換え
  (ペイウォール誘導文は残すが文言修正。Pro判定で枠自体を出さない現行構造は維持)
- PaywallView/SearchTabView: 「広告なし」系の文言を上記⚠️のとおり修正

## 4. アフィリエイト方針(広告在庫の中身)

| 種類 | 扱い |
|---|---|
| 楽天アフィリエイト | customスロットに配信。結果カードへの「楽」ボタン追加は**見送り**(ユーザー判断 2026-07-30) |
| ASP案件(クレカ・会計ソフト・古物商など) | customスロットに配信 |
| AdMob | 埋め草。無料ユーザーのみ(Proは全枠非表示) |
| Amazonアソシエイト | 見送り |

## やらないこと(YAGNI)

- HTML/JSバナー(WebView広告)。画像素材のみ
- A/Bテスト・出し分けロジック(audience以外)。必要になったらversionフィールドで拡張
- 広告の管理画面。当面はKVを直接編集
- 検索タブ下部への第2枠(1画面1枠の原則)
- 結果カードの「楽」ボタン(2026-07-30に一度実装したが削除。楽天導線はcustomスロットで賄う)

## 実装順序

1. サーバー `/api/ads` + KV + 計測エンドポイント + テスト
2. iOS AdsConfigStore + AdSlotView + BannerAdViewのadaptive/unitId対応
3. 広告枠4つ + 設定タブのタイトル削除 + ペイウォール文言修正
4. 運用: KVに広告在庫を投入、ASP案件の獲得

## 検証方針

- サーバー: /api/ads の契約・KV未設定時の安全応答・計測カウントのテスト
- iOS: Debug/Releaseビルド。シミュレータで
  (a) 無料: 4枠すべて表示 (b) **Pro: 全枠非表示(高さも取らない)**
  (c) 開発用Proトグルの切替で即座に出/消が切り替わる (d) KV空で全枠非表示・レイアウト崩れなし
  (e) customバナーのタップでアプリ内ブラウザが開き、クリックが計測される
- AdMobはテストユニットIDで表示確認(本番IDは公開前チェックリストで差し替え)
