import SwiftUI

/// SKUフォーマットの並べ替え画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// 部品(年/月/日/商品コード/自由文字/枝番/数量)をドラッグで並べ替えて出品SKUの書式を決める。
/// 枝番・数量は自動付与ではなく他の部品と同様に任意の位置へ追加・削除できる(SkuGenerator.build参照)。
struct SkuFormatSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// 自由文字部品の編集シート。編集中の部品のindexを保持する(nilなら非表示)。
    @State private var editingIndex: Int?
    @State private var editingText: String = ""

    // プレビュー用のダミー値(仕様どおり: 追加日=今日、ASIN=B00EXAMPLE、枝番=001)。
    private let previewDate = Date()
    private let previewAsin = "B00EXAMPLE"

    var body: some View {
        Form {
            Section("プレビュー") {
                Text(previewSku)
                    .font(.system(.body, design: .monospaced))
                if previewSku.count > 40 {
                    Text("40文字を超えています。このまま出品しようとするとサーバーでエラーになります。")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }

            Section("部品(ドラッグで並べ替え)") {
                // 同じ部品を複数置ける(例: 区切りの"-"を2箇所)ため、要素内容ベースのIDだと重複して
                // 並べ替え・削除が誤動作する。位置(offset)をIDにして一意性を保証する。
                ForEach(Array(settings.listingSkuFormat.enumerated()), id: \.offset) { index, component in
                    componentRow(index: index, component: component)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)

                Menu {
                    Button("年(4桁)") { addComponent(.year4) }
                    Button("年(2桁)") { addComponent(.year2) }
                    Button("月") { addComponent(.month) }
                    Button("日") { addComponent(.day) }
                    Button("商品コード") { addComponent(.productCode) }
                    Button("自由文字") { addComponent(.text("")) }
                    Button("枝番") { addComponent(.sequence) }
                    Button("数量") { addComponent(.quantity) }
                } label: {
                    Label("部品を追加", systemImage: "plus")
                }
            }

            Section {
                Text("枝番は日付でリセットされます。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("SKUフォーマット")
        .toolbar {
            EditButton()
        }
        .sheet(item: editingSheetItem) { target in
            NavigationView {
                Form {
                    Section("自由文字(A-Za-z0-9._-のみ、10文字まで)") {
                        TextField("例: AMLZ-", text: $editingText)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            .onChange(of: editingText) { newValue in
                                editingText = Self.sanitize(newValue)
                            }
                    }
                }
                .navigationTitle("自由文字を編集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            settings.listingSkuFormat[target.index] = .text(editingText)
                            editingIndex = nil
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { editingIndex = nil }
                    }
                }
            }
        }
    }

    /// プレビュー用SKU文字列(既定値・枝番001固定)。
    private var previewSku: String {
        SkuGenerator.build(
            components: settings.listingSkuFormat,
            addedDate: previewDate,
            asin: previewAsin,
            jan: nil,
            sequence: 1,
            quantity: 3
        )
    }

    @ViewBuilder
    private func componentRow(index: Int, component: SkuComponent) -> some View {
        switch component {
        case .text(let value):
            Button {
                editingText = value
                editingIndex = index
            } label: {
                HStack {
                    Text("自由文字")
                    Spacer()
                    Text(value.isEmpty ? "(未入力)" : value)
                        .foregroundColor(value.isEmpty ? .secondary : .primary)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .buttonStyle(.plain)
        default:
            Text(component.displayName)
        }
    }

    /// シート表示用のIdentifiableラッパー(editingIndexがnilならシート非表示)。
    private var editingSheetItem: Binding<EditingTarget?> {
        Binding(
            get: { editingIndex.map { EditingTarget(index: $0) } },
            set: { editingIndex = $0?.index }
        )
    }

    private struct EditingTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private func move(from source: IndexSet, to destination: Int) {
        settings.listingSkuFormat.move(fromOffsets: source, toOffset: destination)
    }

    private func delete(at offsets: IndexSet) {
        settings.listingSkuFormat.remove(atOffsets: offsets)
    }

    private func addComponent(_ component: SkuComponent) {
        settings.listingSkuFormat.append(component)
    }

    /// 自由文字の入力フィルタ: `[A-Za-z0-9._-]` 以外を除去し、10文字に切り詰める。
    private static func sanitize(_ text: String) -> String {
        let filtered = text.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
        }
        return String(filtered.prefix(10))
    }
}
