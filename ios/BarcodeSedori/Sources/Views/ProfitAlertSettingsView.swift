import SwiftUI

/// 利益アラートの詳細設定画面。設定タブの「アラート設定」行からProユーザーのみ遷移する。
/// マスタースイッチ(アラートを有効にする)をOFFにすると、各条件行はグレーアウトして操作不可になる
/// (非表示にはしない。設定値自体は保持し続けるため)。
struct ProfitAlertSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// numberPadキーボードの各TextFieldのフォーカス対象。キーボードツールバーの「完了」で
    /// nilにしてフォーカスを外す(numberPadにはReturnキーが無いため)。
    private enum Field: Hashable {
        case rankThreshold, purchaseCost, marginThreshold, sellerCountNewThreshold, sellerCountUsedThreshold
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                Toggle("アラートを有効にする", isOn: $settings.profitAlertEnabled)

                Toggle("バイブレーションを有効にする", isOn: $settings.profitAlertHapticsEnabled)
                    .disabled(!settings.profitAlertEnabled)
            }

            Section {
                Toggle("ランキングを必要条件", isOn: $settings.profitAlertRankEnabled)
                    .disabled(!settings.profitAlertEnabled)

                HStack {
                    Text("順位")
                    Spacer()
                    TextField("100000", value: $settings.profitAlertRankThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .focused($focusedField, equals: .rankThreshold)
                }
                .disabled(!settings.profitAlertEnabled)
            } header: {
                Text("ランキング")
            } footer: {
                Text("1位以上が有効値")
            }

            Section {
                Toggle("粗利益を必要条件", isOn: $settings.profitAlertMarginEnabled)
                    .disabled(!settings.profitAlertEnabled)

                HStack {
                    Text("仕入れ額(円)")
                    Spacer()
                    TextField("0", value: $settings.profitAlertPurchaseCost, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .focused($focusedField, equals: .purchaseCost)
                }
                .disabled(!settings.profitAlertEnabled)

                HStack {
                    Text("粗利額(円)")
                    Spacer()
                    TextField("300", value: $settings.profitAlertMarginThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .focused($focusedField, equals: .marginThreshold)
                }
                .disabled(!settings.profitAlertEnabled)
            } header: {
                Text("粗利益")
            } footer: {
                Text("1円以上が有効値")
            }

            Section {
                Toggle("出品者数を必要条件", isOn: $settings.profitAlertSellerCountEnabled)
                    .disabled(!settings.profitAlertEnabled)

                HStack {
                    Text("新品(人)")
                    Spacer()
                    TextField("10", value: $settings.profitAlertSellerCountNewThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .focused($focusedField, equals: .sellerCountNewThreshold)
                }
                .disabled(!settings.profitAlertEnabled)

                HStack {
                    Text("中古(人)")
                    Spacer()
                    TextField("10", value: $settings.profitAlertSellerCountUsedThreshold, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .focused($focusedField, equals: .sellerCountUsedThreshold)
                }
                .disabled(!settings.profitAlertEnabled)
            } header: {
                Text("出品者数")
            } footer: {
                Text("指定した人数以下で成立。0を指定した側は判定しない")
            }

            Section {
                Picker("対象コンディション", selection: $settings.profitAlertTargetCondition) {
                    Text("新品").tag(ProfitAlertCondition.new)
                    Text("中古").tag(ProfitAlertCondition.used)
                    Text("両方").tag(ProfitAlertCondition.both)
                }
                .disabled(!settings.profitAlertEnabled)
            } header: {
                Text("対象コンディション")
            } footer: {
                Text("粗利益・定価超えの判定に使うコンディションです")
            }

            Section("プレミアム") {
                Toggle("定価超えを必要条件", isOn: $settings.profitAlertListPriceEnabled)
                    .disabled(!settings.profitAlertEnabled)
            }
        }
        .navigationTitle("アラート設定")
        // numberPadキーボードにはReturnキーが無く閉じる手段が無いため、キーボード上に「完了」を出す。
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
    }
}
