# 改修仕様 v2 (2026-07-02)

ユーザー決定: インストアコードはDBなしでは認識できないため機能ごと削除し、代わりにOCRを追加する。

## 1. インストアコード機能の全削除

### iOS
- 「バーコード / インストアコード」トグル → 「バーコード / OCR」トグルに変更
- unresolved時の「商品バーコードを続けてスキャン」学習フロー・バナー・POST /api/learn 呼び出しを削除
- LearnModels.swift 削除、APIClient.learn() 削除

### サーバー
- POST /api/learn ルート削除
- src/instore/learnedStore.js・data/instore-map.json 削除
- convert.js: ブックオフ99変換・学習テーブル参照を削除。残す判定は
  - 978/979始まり13桁 → isbn
  - 45/49始まり13桁 → jan
  - 192/191始まり13桁 → unresolved(reason: book_jan_second_line)
  - その他 → unresolved(reason: unsupported)
- テストを新仕様に合わせて更新(ブックオフ/学習テーブルのテスト削除)

## 2. OCR機能の追加 (iOS)

- OCRモード時、AVCaptureVideoDataOutput のフレームに対し Vision の VNRecognizeTextRequest を実行
  - recognitionLevel: .fast、usesLanguageCorrection: false、処理間隔は0.3秒程度(毎フレームは不可)
  - regionOfInterest をスキャン枠相当に設定
- 認識テキストから以下を抽出:
  - ISBN: `97[89]\d{10}` (ハイフン・スペースは除去してからマッチ。「ISBN978-4-...」表記対応)
  - JAN: `4\d{12}` (13桁、4始まり)
- **EAN-13チェックデジット検証に合格したものだけ**を採用(OCR誤読対策)
- 採用したコードは既存の handleScan と同じ検索パイプラインへ
- バーコードモード時はVision処理を止める(電力節約)

## 3. バーコード読み取りの挙動変更 (iOS)

- 対応シンボロジーを EAN-13 のみに戻す(CODE128/39/93/Codabar/ITF削除)
- **192/191始まりのコード(日本図書コード2段目)はスキャナー段階で無視**(サーバーに送らない、緑枠も出さない)
- **読み取り音を削除**(AudioServicesPlaySystemSound呼び出しを削除)。触覚フィードバックは残す
- **同一コードの連続読み込み禁止**: 時間ベース(3秒)のデデュープをやめ、
  「最後に読み取ったコードと同じ間は再読み込みしない。別のコードを読み取ったら解除」方式に変更。
  OCR経由・バーコード経由で共通の抑止とする(SearchTabViewModel側で一元管理でも可)
