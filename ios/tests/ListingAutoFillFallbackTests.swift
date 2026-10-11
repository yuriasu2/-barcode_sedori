import Foundation

// Keepa経路の出品価格自動入力フォールバックと手数料概算(ListingModels)の単体テスト。
// 実行: swiftc -module-cache-path /tmp/sellerlens-swift-cache BarcodeSedori/Sources/Models/ListingModels.swift BarcodeSedori/Sources/Models/OffersModels.swift tests/ListingAutoFillFallbackTests.swift -o /tmp/lf && /tmp/lf

nonisolated(unsafe) var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
}

@main
struct ListingAutoFillFallbackTests {
    static func main() {
        let landed = LandedPrices(new: 1600, used: 700)
        let plain = LandedPrices(new: 1500, used: 600)

        // オファー無し: 送料込み優先
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .newNew, shippingIncome: 0, subtractShipping: false, landedPrices: landed, plainPrices: plain) == 1600, "新品はlanded.new")
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .usedGood, shippingIncome: 0, subtractShipping: false, landedPrices: landed, plainPrices: plain) == 700, "中古はlanded.used")
        // landedが無ければprices.new/used
        let noUsedLanded = LandedPrices(new: nil, used: nil)
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .usedGood, shippingIncome: 0, subtractShipping: false, landedPrices: noUsedLanded, plainPrices: plain) == 600, "landed無しはplain.used")
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .newNew, shippingIncome: 0, subtractShipping: false, landedPrices: nil, plainPrices: plain) == 1500, "landed nilはplain.new")
        // 何も無ければnil
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .newNew, shippingIncome: 0, subtractShipping: false) == nil, "全部無しはnil")
        // 配送料差し引きは従来どおり、1円下限
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .usedGood, shippingIncome: 300, subtractShipping: true, landedPrices: landed, plainPrices: plain) == 400, "配送料を引く")
        check(ListingModels.autoFillListingPrice(offers: nil, condition: .usedGood, shippingIncome: 900, subtractShipping: true, landedPrices: landed, plainPrices: plain) == 1, "下限1円")

        // 手数料: feeInfo nil → 15% + 80円 + 税
        let d = ListingModels.estimateFees(price: 1000, shipping: 0, feeInfo: nil)
        check(d.referral == 150 && d.closing == 80 && d.tax == 23 && d.total == 253, "feeInfo nilは15%+80円(税23)")
        // 非メディア10%: 成約料なし
        let n = ListingModels.estimateFees(price: 2000, shipping: 0, feeInfo: FeeInfo(referralFeePercent: 10, hasClosingFee: false))
        check(n.referral == 200 && n.closing == 0 && n.tax == 20 && n.total == 220, "非メディア10%は成約料0")
        // メディア/不明は80円
        let m = ListingModels.estimateFees(price: 2000, shipping: 0, feeInfo: FeeInfo(referralFeePercent: 15, hasClosingFee: true))
        check(m.closing == 80 && m.total == 300 + 80 + 38, "メディアは80円")
        let u = ListingModels.estimateFees(price: 2000, shipping: 100, feeInfo: FeeInfo(referralFeePercent: 8, hasClosingFee: nil))
        check(u.referral == 168 && u.closing == 80, "不明は80円・配送料が基礎に含まれる")
        // 料率nilは15%
        let r = ListingModels.estimateFees(price: 1000, shipping: 0, feeInfo: FeeInfo(referralFeePercent: nil, hasClosingFee: false))
        check(r.referral == 150 && r.closing == 0, "料率nilは15%")

        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("ALL PASSED")
    }
}
