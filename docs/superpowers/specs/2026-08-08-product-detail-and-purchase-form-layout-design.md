# 商品詳細・仕入れ内容画面のレイアウト刷新 設計書

作成日: 2026-08-08 / ステータス: 設計承認済み・実装未着手

## 1. 目的

商品詳細画面と仕入れ内容画面を、ユーザー提示のモックに合わせる。

- 両画面の上部を「サムネイル+タイトル」と「2列×3行の情報グリッド」に統一する
- 情報グリッドに **ASIN** を出す(JANの無い商品でも識別できるようにする)
- 商品詳細のオファーカードの下に、**リンクボタンを9種すべて**横一列で並べる
- 仕入れ内容画面の**キャンセルボタンを編集時のみ消す**

## 2. 調査で判明したこと(設計の前提)

**ASINによる出品は既に実装済みで、今回は変更しない。**

- スキャン時点で`ScanHistoryItem.asin`にASINを保持している
- 仕入れリストへの追加は`guard let asin = result.asin, !asin.isEmpty`でガードされており、**ASINが取れない商品はそもそも追加できない**(`SearchTabView.swift:753`)
- `PurchaseListItem.asin`は非Optionalの`String`
- 出品は`BulkListingViewModel`が`asin: item.asin`で送信している

したがって「JANの無い商品でもASINで出品する」は既に成立している。今回必要なのは**ASINを画面に表示すること**だけ。

**リンクボタンの幅は可変。** `ResultCardActionButtons`のボタンは`.frame(maxWidth: .infinity)`で全幅を等分し、高さのみ34pt固定(`SearchTabView.swift:1183-1184`)。9個並べても見切れないが、iPhone SE(375pt)では1個あたり約33ptまで細くなる。iOSの推奨タップ領域44ptは下回るため、押しにくさは残る。

## 3. 決定事項

| 論点 | 決定 | 理由 |
|---|---|---|
| ヘッダーと情報グリッド | **共通部品として1つ作り2画面から使う** | 見た目が同一。個別実装だと片方だけ直し忘れてズレる |
| リンクボタンの種類 | **仕入れを含む9種すべて** | ユーザー指示 |
| 既存の「仕入れリストに追加」ボタン | **削除する** | リンクボタンに仕入れが含まれ、同じ機能が2つ並ぶため |
| 設定「表示するボタンを4つ選ぶ」 | **検索画面のみに適用** | スキャン中はよく使うものだけ、じっくり見る詳細では全部、という使い分け |
| キャンセルボタン | **編集時のみ消す** | 編集は画面遷移で戻る「‹」があり二重。新規追加はシートなので消すと閉じる手段が下スワイプだけになる |
| 参考価格・発売日 | `PurchaseListItem`に**任意項目として追加** | 仕入れ内容画面に表示するため。既存の保存済み項目は`-`表示 |

## 4. 変更点

### 4.1 共通部品(新規ファイル)

`ios/BarcodeSedori/Sources/Views/ProductSummaryHeader.swift`

商品のサムネイル・タイトル・識別情報をまとめて表示する部品。商品詳細と仕入れ内容の両方から使う。

**引数:**

| 引数 | 型 | 用途 |
|---|---|---|
| `imageUrl` | `String?` | サムネイル。無ければプレースホルダ |
| `title` | `String?` | 商品名。無ければ「(タイトル不明)」 |
| `jan` | `String?` | JAN欄。`isbn13 ?? scannedCode`を呼び出し側で解決して渡す |
| `asin` | `String?` | ASIN欄 |
| `salesRank` | `Int?` | ランク欄。3桁区切り+「位」。nilは「圏外」 |
| `listPrice` | `Int?` | 参考価格欄。3桁区切り+「¥」 |
| `releaseDate` | `String?` | 発売日欄。ISO文字列(`2025-06-17`)を`2025/6/17`へ整形 |
| `dateLabel` | `String` | 右下セルのラベル。商品詳細は「検索日」、仕入れ内容は「追加日」 |
| `date` | `Date?` | 右下セルの値。`2025/6/17`形式 |

**レイアウト:** サムネイル+タイトルのヘッダー行の下に、2列×3行のグリッド。

| | |
|---|---|
| JAN | ASIN |
| ランク | 参考価格 |
| 発売日 | (dateLabel) |

値が無いセルは`-`を表示する。ラベルは小さめ・グレー、値は通常サイズ。日付・数値の整形ロジック(`releaseDateInputFormatter` / `releaseDateOutputFormatter` / `groupedNumberFormatter`)は現在`ProductDetailView`にあるものをこの部品へ移す。

**Formの中で使うときの注意:** 仕入れ内容画面は`Form`なので、`Section`に入れると行の余白と背景が付いてカードに見えない。`.listRowInsets(EdgeInsets())`と`.listRowBackground(Color.clear)`を付けて、部品自身の背景・角丸をそのまま出す。

### 4.2 リンクボタンの共通化(ファイル移動)

`ResultCardActionButtons`は現在`SearchTabView.swift`内の`private struct`で、他画面から使えない。**新規ファイル`ios/BarcodeSedori/Sources/Views/ResultCardActionButtons.swift`へ移し、`private`を外す**(同一モジュール内なのでアクセス修飾子なし=internalでよい)。

あわせて、表示するボタンの決め方を引数で切り替えられるようにする。

- 新しい引数 `kinds: [LinkButtonKind]` を追加する
- 検索画面は `settings.linkButtons`(設定で選んだ4つ)を渡す — 従来と同じ挙動
- 商品詳細は `LinkButtonKind.allCases`(9種すべて)を渡す

現在の`visibleButtons`は`settings.linkButtons.filter(showsButton)`で、`showsButton`による表示条件(ASINが無ければ仕入れ/Amazon/Keepaを出さない、検索キーワードが無ければ各モールを出さない)はそのまま活かす。つまり`kinds.filter(showsButton)`に変えるだけ。

### 4.3 商品詳細画面(`ProductDetailView.swift`)

**並び順**(上から):

1. `ProductSummaryHeader`(現在の`headerCard` + `infoCard`を置き換え)
2. オファーカード(新品/中古) — 変更なし
3. **リンクボタン9種**(新規)
4. グラフ — 変更なし

**削除するもの:** `addToPurchaseButton`(専用の「仕入れリストに追加」ボタン)。リンクボタンの仕入れが同じ役割を担う。ただし**タップ時の処理(`purchaseFormDraft`の生成、非Proのペイウォール表示)はリンクボタンのコールバックへ引き継ぐ**ので、`@State private var purchaseFormDraft`と`showPaywall`、シート提示はそのまま残す。

**追加する引数:**

- `asin: String?` — 現在は`init`で受け取ってViewModelへ渡すだけで、表示用のプロパティとして保持していない。グリッドに出すため`let asin: String?`を追加する
- `scannedAt: Date?` — 「検索日」に出す。呼び出し側は次のとおり
  - `ProductsTabView`: `selectedItem.scannedAt`(履歴の保存値)
  - `SearchTabView`: 検索直後の遷移なので`Date()`(=今日)

**ファイル冒頭のコメント修正:** 現在「リンクボタン(仕/a/m/楽 等)は置かない(ユーザー指示 2026-08-02)」と書かれている。今回の指示で覆るため、日付付きで置き換える。

### 4.4 仕入れ内容画面(`PurchaseFormView.swift`)

**`Section("商品")`を置き換える。** 現在はタイトル・JANコード・ランキングが縦に並び、最後に`restrictionRow`がある。これを次の構成にする。

1. `ProductSummaryHeader`(`dateLabel: "追加日"`)
2. `restrictionRow`(出品制限の警告) — 変更なし

**キャンセルボタン:** `.cancellationAction`のツールバー項目を、**新規追加(`.add`)モードのときだけ**出す。編集(`.edit`)モードでは画面遷移の戻る「‹」があるため二重になる。

判定には`mode`を使う。`PurchaseFormViewModel`に次を追加する(既存の`shippingToDisplay`が同じ`switch mode`を使っているのと同じ作法)。

```swift
/// 新規追加モードか。キャンセルボタンの表示条件に使う。
/// 編集モードは画面遷移(NavigationLink)で開くため戻る「‹」があり、キャンセルは二重になる。
/// 新規追加はシート表示で、消すと下スワイプ以外に閉じる手段が無くなるため残す。
var showsCancelButton: Bool {
    if case .add = mode { return true }
    return false
}
```

### 4.5 データモデル(`PurchaseListItem.swift`)

参考価格と発売日を持っていないため追加する。

```swift
/// 定価(税込・円)。仕入れ内容画面の「参考価格」に出す。追加時に検索結果から引き継ぐ。
var listPrice: Int?
/// 発売日(ISO日付文字列、例 "2025-06-17")。仕入れ内容画面の「発売日」に出す。
var releaseDate: String?
```

- どちらも任意。既に保存済みの項目には無いので、読み込み時は`nil`となり画面では`-`と表示される
- `init(result:scannedCode:offersResult:)`(SearchResult由来の初期化)で引き継ぐ。**取り出し方が2つで異なる点に注意**:
  - 発売日は`result.releaseDate`(`SearchResult`直下にある)
  - 参考価格は`result.profitInputs?.listPrice`(**`SearchResult`直下には無い**。`ProfitInputs`の中。`ProfitAlertEvaluator.swift:86`と同じ取り出し方)
- メンバーワイズ`init`にも既定値`nil`付きで追加し、既存の呼び出し側を壊さない

`PurchaseFormViewModel`には、これらをグリッドへ渡すための読み出しを追加する(`title` / `asin` / `janCode` / `salesRank`と同じ作法で`mode`から取り出す)。

## 5. 変更しない範囲

- **ASINの取得・保存・出品**(§2のとおり既に実装済み)
- オファーカード、グラフ、出品内容・利益セクションの中身
- 検索画面の結果カード(リンクボタンは従来どおり設定で選んだ4つ)
- サーバー側(変更なし。デプロイ不要)

## 6. 検証

iOSにテストターゲットが無いため、ビルド成功と手動確認で検証する。

**ビルド**

```bash
xcodebuild -project "ios/BarcodeSedori/BarcodeSedori.xcodeproj" -scheme BarcodeSedori \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

**新規ファイルを2つ追加するため、ビルド前に`cd ios/BarcodeSedori && xcodegen generate`を実行すること。** 忘れると「Build input file cannot be found」で落ちる。

**手動確認項目**

1. 商品詳細に「JAN / ASIN / ランク / 参考価格 / 発売日 / 検索日」の6セルが出る。値の無いものは`-`
2. 商品詳細のオファーカードの下にリンクボタンが9種並び、見切れない(iPhone SEで確認)
3. 商品詳細から専用の「仕入れリストに追加」ボタンが消えている
4. リンクボタンの仕入れをタップすると、従来と同じく仕入れフォームがシートで開く
5. 非Proでリンクボタンの仕入れをタップするとペイウォールが出る
6. 検索画面の結果カードは従来どおり設定で選んだ4つのまま
7. 仕入れ内容(新規追加)に同じ6セルが出て、右下が「追加日」になっている。**キャンセルボタンがある**
8. 仕入れ内容(編集・仕入れタブから)でも同じ6セルが出る。**キャンセルボタンが無く、戻る「‹」だけ**
9. アップデート前に保存した仕入れ項目を開くと、参考価格と発売日が`-`になる(それ以外は従来どおり)
10. 新しく仕入れリストへ追加した項目には、参考価格と発売日が入っている
