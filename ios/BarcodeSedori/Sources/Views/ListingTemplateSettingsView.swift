import SwiftUI

/// 出品説明文テンプレートの編集画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// ProfitAlertSettingsViewと同じ分離画面方式。コンディション5種(新品含む)それぞれのテンプレートを編集できる。
struct ListingTemplateSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("新品") {
                TextEditor(text: $settings.listingTemplateNew)
                    .frame(minHeight: 80)
            }
            Section("ほぼ新品") {
                TextEditor(text: $settings.listingTemplateLikeNew)
                    .frame(minHeight: 80)
            }
            Section("非常に良い") {
                TextEditor(text: $settings.listingTemplateVeryGood)
                    .frame(minHeight: 80)
            }
            Section("良い") {
                TextEditor(text: $settings.listingTemplateGood)
                    .frame(minHeight: 80)
            }
            Section("可") {
                TextEditor(text: $settings.listingTemplateAcceptable)
                    .frame(minHeight: 80)
            }
            Section {
                Text("出品フォームでコンディションを選ぶと、対応するテンプレートが説明文に自動入力されます(出品ごとに個別編集もできます)。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("出品説明文テンプレート")
    }
}
