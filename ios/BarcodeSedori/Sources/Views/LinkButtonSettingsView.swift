import SwiftUI

/// リンクボタン(検索タブの結果カードに出す4つ)を選ぶ画面。設定タブの「リンクボタン」セクションから遷移する。
/// 無料でも使える機能のためPro限定にはしていない。
///
/// 選択はローカルの `selection` でステージングし、**ちょうど4つになった時点でのみ**
/// `SettingsStore.linkButtons` へ書き戻す。0個や5個の状態を設定へ反映してしまうと
/// 結果カード側(ResultCardActionButtons)のボタン数が不定になるため、常に4つちょうどの
/// スナップショットだけを永続化する。
struct LinkButtonSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selection: [LinkButtonKind]

    /// 表示する個数は常にこれ(4つ固定)。
    private let requiredCount = 4

    init() {
        _selection = State(initialValue: SettingsStore.shared.linkButtons)
    }

    var body: some View {
        Form {
            Section {
                // 並び順はLinkButtonKind.allCasesの順で固定(並べ替えは複雑になるため省略)。
                ForEach(LinkButtonKind.allCases) { kind in
                    row(for: kind)
                }
            } header: {
                Text("表示する4つを選択")
            } footer: {
                Text("現在\(selection.count)/4個選択中。4つ選ぶと結果カードに反映されます。4つ選択済みのときは他を外してから選んでください。")
            }
        }
        .navigationTitle("リンクボタン")
    }

    @ViewBuilder
    private func row(for kind: LinkButtonKind) -> some View {
        let isSelected = selection.contains(kind)
        Button {
            toggle(kind)
        } label: {
            HStack {
                // 色ドットではなく実際のボタンの縮小版を出す。グレー地のボタンが4種あり、
                // 地色だけでは見分けられないため(文字・アイコンまで含めて示す)。
                buttonSwatch(for: kind)
                Text(kind.displayName)
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .fontWeight(.bold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 4つ選択済みのとき、未選択の項目はタップ不可にする(0個や5個にならないよう選択不可で防ぐ)。
        .disabled(!isSelected && selection.count >= requiredCount)
    }

    /// 結果カードに出るボタンの縮小プレビュー(地色+文字/アイコン)。
    private func buttonSwatch(for kind: LinkButtonKind) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(kind.color)
            .frame(width: 24, height: 24)
            .overlay {
                if let icon = kind.iconSystemName {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(kind.labelColor)
                } else {
                    let base: CGFloat = kind.label.allSatisfy { $0.isASCII } ? 13 : 11
                    LinkButtonGlyphLabel(
                        text: kind.label,
                        size: base * kind.labelFontScale,
                        weight: kind.labelFontWeight,
                        design: kind.labelFontDesign,
                        color: kind.labelColor
                    )
                }
            }
            .accessibilityHidden(true)
    }

    private func toggle(_ kind: LinkButtonKind) {
        if let index = selection.firstIndex(of: kind) {
            selection.remove(at: index)
        } else {
            guard selection.count < requiredCount else { return }
            selection.append(kind)
        }
        // ちょうど4つに戻った瞬間だけ確定として保存する。3個以下の間は編集途中とみなし保存しない。
        if selection.count == requiredCount {
            settings.linkButtons = selection
        }
    }
}
