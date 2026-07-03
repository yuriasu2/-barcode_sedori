# バーコードせどり

商品バーコード(ISBN/JAN)をスキャンし、
Amazon SP-API経由でカート価格・新品価格・中古最安値を即時表示するiOSアプリ+ローカルサーバー。
OCRモードでは書影・カバーの印字テキストからISBN/JANを読み取って検索できる。

設計の詳細は [DESIGN.md](DESIGN.md) を参照。

## セットアップ手順

### 1. サーバー(PC側)

```bash
cd server
cp .env.example .env
# .env にSP-APIの認証情報(LWA_CLIENT_ID / LWA_CLIENT_SECRET / LWA_REFRESH_TOKEN)を記入
npm start        # 依存ゼロのため npm install 不要
```

PCのIPアドレスを確認(macOS: `ipconfig getifaddr en0`)。iPhoneと同一Wi-Fiに接続しておく。

### 2. iOSアプリ

```bash
brew install xcodegen
cd ios/BarcodeSedori
xcodegen
open BarcodeSedori.xcodeproj
```

Xcodeで Signing & Capabilities → Team を選択し、**実機**にビルド(カメラ必須)。
起動後、設定タブでサーバーURL(例 `http://192.168.1.10:3000`)を入力して接続テスト。

## コード対応について (v2)

インストアコード(ブックオフ/TSUTAYA/GEO)の変換・学習機能はDBなしでは決定的に解決できないため
v2で廃止した。対応は以下のみ:

- `978`/`979`始まり: ISBN-13として検索
- `45`/`49`始まり: JANとして検索
- `192`/`191`始まり(書籍JANコード2段目): スキャナー段階で無視、またはサーバーで`unresolved`
- その他: `unresolved`

かわりにOCRモードを追加した。バーコードが読めない場合はOCRに切り替え、カバー等の印字から
ISBN/JANのテキストを認識して検索できる。

## 動作確認

```bash
cd server && npm test                              # 変換ロジックのユニットテスト
curl "http://localhost:3000/api/search?code=9784471103644"   # ISBN検索(要 .env 設定)
```
