import SwiftUI
import AVFoundation
import Vision
import UIKit

/// バーコード検出結果(スキャンされたコードと、プレビュー座標系での枠)
struct ScannedBarcode: Equatable {
    let code: String
    let symbology: AVMetadataObject.ObjectType
}

/// AVCaptureMetadataOutputでEAN13を検出するカメラビュー(CHANGES-v2.md準拠)。
/// - 対応シンボロジーはEAN-13のみ。
/// - 192/191始まりのコード(日本図書コード2段目)はdelegate段階で無視する(ハイライトもコールバックもしない)。
/// - 読み取り音は出さない。触覚フィードバックのみ残す。
/// - デデュープは「直前と同じコードは読まない、別のコードで解除」方式。
/// - OCRモード時はAVCaptureVideoDataOutput + VisionのVNRecognizeTextRequestでISBN/JANを抽出する。
///   バーコードモード時はVision処理を止める(電力節約)。
struct ScannerView: UIViewRepresentable {
    /// バーコード/OCRいずれかで確定したコードが検出されるたびに呼ばれる
    var onScan: (ScannedBarcode) -> Void
    /// true: OCRモード(Visionでテキスト認識) / false: バーコードモード(AVCaptureMetadataOutput)
    var isOCRMode: Bool

    func makeUIView(context: Context) -> ScannerContainerView {
        let view = ScannerContainerView()
        view.onScan = onScan
        view.isOCRMode = isOCRMode
        view.startSession()
        return view
    }

    func updateUIView(_ uiView: ScannerContainerView, context: Context) {
        uiView.onScan = onScan
        uiView.isOCRMode = isOCRMode
    }

    static func dismantleUIView(_ uiView: ScannerContainerView, coordinator: ()) {
        uiView.stopSession()
    }
}

/// カメラプレビュー+検出枠ハイライトを保持するUIView。
final class ScannerContainerView: UIView {
    var onScan: ((ScannedBarcode) -> Void)?

    /// OCRモードの切り替え。trueにするとバーコード検出を止めてVisionでのテキスト認識を行う。
    /// SwiftUI側(メインスレッド)から書き込まれ、videoDataQueue/sessionQueueから読み取られるため
    /// スレッドセーフなラッパー(isOCRModeBox)経由でアクセスする。
    var isOCRMode: Bool {
        get { isOCRModeBox.value }
        set {
            let oldValue = isOCRModeBox.value
            isOCRModeBox.value = newValue
            guard oldValue != newValue else { return }
            // モード切替時はデデュープ状態をリセットする。
            // (バーコードで読んだ直後に同じ本をOCRで読むケースを抑止しないため)
            DispatchQueue.main.async { [weak self] in
                self?.lastCode = nil
            }
        }
    }
    private let isOCRModeBox = BoolBox(false)

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.example.barcodesedori.scanner.session")
    private let videoDataQueue = DispatchQueue(label: "com.example.barcodesedori.scanner.videodata")

    /// 検出枠のハイライトレイヤー
    private let highlightLayer = CAShapeLayer()

    /// デデュープ管理: 直前に読み取ったコード。別コードを読むまで同じコードは再通知しない。
    /// バーコード/OCR経由で共通の抑止とする。(メインスレッドからのみアクセス)
    private var lastCode: String?
    /// 最後に読み取りを通知した時刻。次の読み取りまで1秒のクールダウンを設ける。
    private var lastEmitTime: Date = .distantPast
    private let emitCooldown: TimeInterval = 1.0

    /// スキャン枠(画面上部)。0..1の相対座標(表示座標系、y原点は上)
    /// この矩形はUIレイヤーでの枠描画にも、AVCaptureのrectOfInterest計算にも使う。
    private let scanRectRatio = CGRect(x: 0.1, y: 0.12, width: 0.8, height: 0.32)

    // MARK: - OCR (Vision)

    /// OCR処理のスロットル(0.3秒間隔)
    private var lastOCRRequestTime: Date = .distantPast
    private let ocrThrottleInterval: TimeInterval = 0.3
    /// Vision処理中に多重実行しないためのフラグ(videoDataQueue上でのみアクセス)
    private var isProcessingOCR = false

    /// ISBN: 97[89] + 10桁 = 13桁。ハイフン・スペース除去後の文字列に対してマッチ。
    private static let isbnRegex = try! NSRegularExpression(pattern: "97[89]\\d{10}")
    /// JAN: 4始まり13桁。
    private static let janRegex = try! NSRegularExpression(pattern: "4\\d{12}")
    /// ISBN-10: 4始まり9桁+チェック文字(数字またはX)。
    /// 前後に数字が続く場合(13桁コードの一部など)は除外するため境界条件付き。
    private static let isbn10Regex = try! NSRegularExpression(pattern: "(?<!\\d)4\\d{8}[0-9X](?!\\d)")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        setupHighlightLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        setupHighlightLayer()
    }

    private func setupHighlightLayer() {
        highlightLayer.strokeColor = UIColor.systemGreen.cgColor
        highlightLayer.fillColor = UIColor.clear.cgColor
        highlightLayer.lineWidth = 3
        highlightLayer.isHidden = true
        layer.addSublayer(highlightLayer)

        // セッション起動完了後にrectOfInterestを再計算する。
        // 起動前にmetadataOutputRectConvertedを呼ぶとゼロ矩形が返り、
        // 検出領域が空になってバーコードが一切検出されなくなるため必須。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidStartRunning),
            name: .AVCaptureSessionDidStartRunning,
            object: captureSession
        )
    }

    @objc private func sessionDidStartRunning() {
        DispatchQueue.main.async { [weak self] in
            self?.updateRectOfInterest()
        }
    }

    func startSession() {
        // カメラ権限を明示的にリクエストしてから設定・起動する。
        // (権限確定済みの場合はコールバックが即時に呼ばれる)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.sessionQueue.async {
                self.configureSessionIfNeeded()
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard captureSession.inputs.isEmpty else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input)
        else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        // バーコード(EAN-13のみ, CHANGES-v2.md準拠)
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.ean13].filter {
                metadataOutput.availableMetadataObjectTypes.contains($0)
            }
        }

        // OCR用のビデオフレーム出力(OCRモード時のみ有効化。既定は無効)
        if captureSession.canAddOutput(videoDataOutput) {
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            captureSession.addOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        }

        captureSession.commitConfiguration()

        DispatchQueue.main.async { [weak self] in
            self?.attachPreviewLayerIfNeeded()
            self?.updateRectOfInterest()
        }
    }

    private func attachPreviewLayerIfNeeded() {
        guard previewLayer == nil else { return }
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        updateRectOfInterest()
        updateScanRectPath()
    }

    /// rectOfInterestはプレビュー座標(0..1, 原点左上、AVFoundation内部表現は入れ替わることに注意)で指定する。
    /// AVCaptureVideoPreviewLayer.metadataOutputRectConverted(fromLayerRect:) を使うことで
    /// UIKit座標のスキャン枠から正しいrectOfInterestへ変換できる。
    private func updateRectOfInterest() {
        // 検出領域は全面(既定値 0,0,1,1)のままにする。
        // 領域を限定する最適化は座標変換のタイミング問題で検出不能を招きやすいため撤去した。
        // (スキャン枠のガイド表示は視覚的な目安としてそのまま残す)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.metadataOutput.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// スキャン枠の白い案内線を描画(常時表示)。検出時ハイライトとは別レイヤーで簡易的に矩形を出す。
    private let guideLayer = CAShapeLayer()
    private var didAddGuideLayer = false

    private func updateScanRectPath() {
        if !didAddGuideLayer {
            guideLayer.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            guideLayer.fillColor = UIColor.clear.cgColor
            guideLayer.lineWidth = 2
            layer.addSublayer(guideLayer)
            didAddGuideLayer = true
        }
        guideLayer.path = UIBezierPath(roundedRect: scanRectInBounds(), cornerRadius: 8).cgPath
        guideLayer.frame = bounds
    }

    /// スキャン枠(scanRectRatio)を現在のbounds座標系の矩形に変換して返す。
    private func scanRectInBounds() -> CGRect {
        CGRect(
            x: bounds.width * scanRectRatio.minX,
            y: bounds.height * scanRectRatio.minY,
            width: bounds.width * scanRectRatio.width,
            height: bounds.height * scanRectRatio.height
        )
    }

    /// 検出したバーコードの枠を緑でハイライトし、一定時間後に消す。
    private func highlight(rect: CGRect) {
        highlightLayer.isHidden = false
        highlightLayer.frame = bounds
        highlightLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.highlightLayer.isHidden = true
        }
    }

    /// デデュープを通過したコードをコールバックへ通知する(メインスレッドで呼ぶこと)。
    /// - 直前と同じコードは読まない(別のコードで解除、モード切替でもリセット)
    /// - 1度読み込んだら次の読み込みまで1秒のクールダウン
    private func emit(code: String, symbology: AVMetadataObject.ObjectType) {
        if let lastCode, lastCode == code {
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastEmitTime) < emitCooldown {
            return
        }
        lastCode = code
        lastEmitTime = now

        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)

        onScan?(ScannedBarcode(code: code, symbology: symbology))
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate (バーコードモード)

extension ScannerContainerView: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // OCRモード中はバーコード検出を完全に無視する
        guard !isOCRMode else { return }
        guard let previewLayer else { return }

        for metadataObject in metadataObjects {
            guard
                let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
                let stringValue = readableObject.stringValue,
                !stringValue.isEmpty
            else {
                continue
            }

            // 192/191始まりのコード(日本図書コード2段目)はここで無視する。
            // ハイライトもコールバックも行わない。
            if stringValue.hasPrefix("192") || stringValue.hasPrefix("191") {
                continue
            }

            // 検出枠をプレビュー座標系(UIKit座標)へ変換してハイライト
            if let transformed = previewLayer.transformedMetadataObject(for: readableObject) {
                highlight(rect: transformed.bounds)
            }

            emit(code: stringValue, symbology: readableObject.type)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (OCRモード)

extension ScannerContainerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // videoDataQueue上で呼ばれる
        guard isOCRMode else { return }

        let now = Date()
        guard now.timeIntervalSince(lastOCRRequestTime) >= ocrThrottleInterval else { return }
        guard !isProcessingOCR else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastOCRRequestTime = now
        isProcessingOCR = true

        // VNImageRequestHandler.perform(_:)は同期実行のため、この完了ハンドラは
        // perform呼び出しと同じスレッド(videoDataQueue)上で呼ばれる。
        // そのためisProcessingOCRへの読み書きはvideoDataQueueに閉じており競合しない。
        let request = VNRecognizeTextRequest { [weak self] request, error in
            defer { self?.isProcessingOCR = false }
            guard let self else { return }
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation]
            else {
                return
            }
            self.handleOCRObservations(observations)
        }
        // regionOfInterestは指定しない(全面認識)。
        // プレビュー座標→画像座標の変換はresizeAspectFill+回転が絡み誤りやすく、
        // 誤った領域指定は「何も認識されない」原因になる。
        // 誤読はISBN/JANの正規表現+チェックデジット検証で弾けるため全面認識で問題ない。
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        // 縦持ち・背面カメラでのCMSampleBuffer→VNImageRequestHandlerの向きは.right。
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            isProcessingOCR = false
        }
    }

    private func handleOCRObservations(_ observations: [VNRecognizedTextObservation]) {
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if let code = Self.extractCode(fromRaw: candidate.string) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // OCRで確定した際もバーコードモードと同様に緑枠を表示する。
                    // テキストのバウンディングボックス変換は座標系(向き・アスペクト)の誤りを招きやすいため、
                    // スキャン案内枠の領域を緑でハイライトして読み取りフィードバックとする。
                    self.highlight(rect: self.scanRectInBounds())
                    self.emit(code: code, symbology: .ean13)
                }
                return
            }
        }
    }

    /// OCRテキストからISBN(13桁/10桁)/JANを抽出する。ハイフン・スペースは無視。
    ///
    /// 13桁: バーコード直下の数字(ハイフンなしの連続13桁)は読まない —
    /// バーコード自体が読める状態のため、バーコードモードで読むべき。
    /// 採用は「ISBN」表記を含む行、またはハイフン区切りで印字された番号のみ。
    ///
    /// 10桁(ISBN-10, 4始まり, 末尾X可): ISBN表記・ハイフンがなくても採用
    /// (バーコード下に10桁表記は存在しないため)。ISBN-13に変換して返す。
    ///
    /// いずれもチェックデジット検証に合格したもののみ。
    static func extractCode(fromRaw raw: String) -> String? {
        let noSpace = raw.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "") // 全角スペース
        let hasIsbnPrefix = noSpace.contains("ISBN")
        let cleaned = noSpace.replacingOccurrences(of: "-", with: "")

        // 13桁 (ISBN-13 / JAN)
        if let code = firstMatch(regex: isbnRegex, in: cleaned) ?? firstMatch(regex: janRegex, in: cleaned),
           EAN13Validator.isValid(code) {
            if hasIsbnPrefix || containsHyphenated(code: code, in: noSpace) {
                return code
            }
            // 裸の連続13桁(=バーコード下の数字の可能性が高い)は不採用。ISBN-10判定へ進む
        }

        // 10桁 (ISBN-10)
        if let code10 = firstMatch(regex: isbn10Regex, in: cleaned),
           ISBN10Validator.isValid(code10) {
            return ISBN10Validator.toIsbn13(code10)
        }

        return nil
    }

    /// text中に、codeの数字列が「ハイフンを1つ以上挟んだ形」で出現するかを判定する。
    private static func containsHyphenated(code: String, in text: String) -> Bool {
        var pattern = ""
        for (i, ch) in code.enumerated() {
            pattern += String(ch)
            if i < code.count - 1 { pattern += "-?" }
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, options: [], range: range) {
            if let matchRange = Range(match.range, in: text), text[matchRange].contains("-") {
                return true
            }
        }
        return false
    }

    private static func firstMatch(regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[matchRange])
    }
}

/// 複数スレッドから読み書きされるBoolを安全に受け渡すための小さなラッパー。
final class BoolBox {
    private let lock = NSLock()
    private var _value: Bool

    init(_ initial: Bool) {
        _value = initial
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

/// EAN-13チェックデジット検証(OCR誤読対策)。
enum EAN13Validator {
    /// 先頭12桁からチェックデジットを計算する。
    static func checkDigit(body12: [Int]) -> Int {
        var sum = 0
        for i in 0..<12 {
            let weight = (i % 2 == 0) ? 1 : 3
            sum += body12[i] * weight
        }
        let mod = sum % 10
        return mod == 0 ? 0 : 10 - mod
    }

    static func isValid(_ code: String) -> Bool {
        guard code.count == 13, code.allSatisfy({ $0.isNumber }) else { return false }
        let digits = code.compactMap { $0.wholeNumberValue }
        guard digits.count == 13 else { return false }
        return checkDigit(body12: Array(digits[0..<12])) == digits[12]
    }
}

/// ISBN-10チェックデジット検証とISBN-13への変換。
enum ISBN10Validator {
    /// ISBN-10のチェックデジット検証(モジュラス11、ウェイト10〜2、チェック文字X=10)。
    static func isValid(_ code: String) -> Bool {
        guard code.count == 10 else { return false }
        let chars = Array(code)
        var sum = 0
        for i in 0..<9 {
            guard let d = chars[i].wholeNumberValue, chars[i].isNumber else { return false }
            sum += d * (10 - i)
        }
        let checkChar = chars[9]
        let checkValue: Int
        if checkChar == "X" {
            checkValue = 10
        } else if let d = checkChar.wholeNumberValue, checkChar.isNumber {
            checkValue = d
        } else {
            return false
        }
        return (sum + checkValue) % 11 == 0
    }

    /// ISBN-10 → ISBN-13 (978プレフィックス付与+EAN-13チェックデジット再計算)。
    static func toIsbn13(_ isbn10: String) -> String {
        let body9 = String(isbn10.prefix(9))
        let body12String = "978" + body9
        let body12 = body12String.compactMap { $0.wholeNumberValue }
        let cd = EAN13Validator.checkDigit(body12: body12)
        return body12String + String(cd)
    }
}
