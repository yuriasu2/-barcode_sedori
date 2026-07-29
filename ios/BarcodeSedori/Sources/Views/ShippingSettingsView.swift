import SwiftUI

/// 「利益計算用送料」画面(Pro限定)。設定タブの「出品」セクションから遷移する。
/// 仕入れフォーム(PurchaseFormView)の利益セクションで使う配送料・発送費用のデフォルト値を設定する。
/// どちらもAmazonへは送らず、粗利益の計算にのみ使う。
struct ShippingSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// numberPadキーボードの配送料・発送費用TextFieldのフォーカス対象。キーボードツールバーの
    /// 「完了」でnilにしてフォーカスを外す(numberPadにはReturnキーが無いため。
    /// PurchaseFormViewと同方式)。
    private enum Field: Hashable {
        case shippingIncome
        case shippingCost
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section("配送料") {
                HStack {
                    Text("配送料デフォルト(円)")
                    Spacer()
                    TextField("配送料", value: $settings.purchaseShippingIncomeDefault, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .focused($focusedField, equals: .shippingIncome)
                }
                Text("購入者が支払い、自分に入金される額です。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack {
                    Text("発送費用デフォルト(円)")
                    Spacer()
                    TextField("発送費用", value: $settings.purchaseShippingCostDefault, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .focused($focusedField, equals: .shippingCost)
                }
                Text("自分が支払う発送コストです。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("利益計算用送料")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
    }
}
