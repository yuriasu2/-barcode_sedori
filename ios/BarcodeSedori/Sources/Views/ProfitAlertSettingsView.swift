import SwiftUI

/// 利益アラートの詳細設定画面。設定タブの「アラート設定」行からProユーザーのみ遷移する。
/// マスタースイッチ(アラートを有効にする)をOFFにすると、各条件行はグレーアウトして操作不可になる
/// (非表示にはしない。設定値自体は保持し続けるため)。
struct ProfitAlertSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("アラートを有効にする", isOn: $settings.profitAlertEnabled)
            }

            Section("利益アラート") {
                Toggle("粗利", isOn: $settings.profitAlertMarginEnabled)
                    .disabled(!settings.profitAlertEnabled)
                if settings.profitAlertMarginEnabled {
                    HStack {
                        Text("粗利がこの金額(円)以上")
                        Spacer()
                        TextField("300", value: $settings.profitAlertMarginThreshold, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    .disabled(!settings.profitAlertEnabled)
                }

                HStack {
                    Text("仕入れ値(円)")
                    Spacer()
                    TextField("0", value: $settings.profitAlertPurchaseCost, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                .disabled(!settings.profitAlertEnabled)

                Picker("対象コンディション", selection: $settings.profitAlertTargetCondition) {
                    Text("新品").tag(ProfitAlertCondition.new)
                    Text("中古").tag(ProfitAlertCondition.used)
                }
                .disabled(!settings.profitAlertEnabled)

                Toggle("ランキング", isOn: $settings.profitAlertRankEnabled)
                    .disabled(!settings.profitAlertEnabled)
                if settings.profitAlertRankEnabled {
                    HStack {
                        Text("ランキングがこの順位以内")
                        Spacer()
                        TextField("100000", value: $settings.profitAlertRankThreshold, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    .disabled(!settings.profitAlertEnabled)
                }

                Toggle("出品者数", isOn: $settings.profitAlertSellerCountEnabled)
                    .disabled(!settings.profitAlertEnabled)
                if settings.profitAlertSellerCountEnabled {
                    HStack {
                        Text("出品者数がこの人数以下")
                        Spacer()
                        TextField("10", value: $settings.profitAlertSellerCountThreshold, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    .disabled(!settings.profitAlertEnabled)
                }

                Toggle("売値が定価以上", isOn: $settings.profitAlertListPriceEnabled)
                    .disabled(!settings.profitAlertEnabled)

                Text("ONにした条件をすべて満たしたスキャン結果を緑色で強調表示します。粗利・出品者数は上で選んだコンディション(新品/中古)を参照します。定価は取得できない商品があり、その場合はこの条件のみスキップされます。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("アラート設定")
    }
}
