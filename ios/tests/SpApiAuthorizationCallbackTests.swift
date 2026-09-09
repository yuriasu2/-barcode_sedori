import Foundation

@main
struct SpApiAuthorizationCallbackTests {
    static func main() {
        func parse(_ value: String) -> SpApiAuthorizationCallback? {
            SpApiAuthorizationCallback(url: URL(string: value)!)
        }
        let valid = parse("barcodesedori://spapi-auth?refresh_token=token%2Bvalue&selling_partner_id=SELLER")
        precondition(valid?.refreshToken == "token+value")
        precondition(valid?.sellerId == "SELLER")
        for invalid in [
            "https://spapi-auth?refresh_token=token&selling_partner_id=S",
            "barcodesedori://other?refresh_token=token&selling_partner_id=S",
            "barcodesedori://spapi-auth?refresh_token=&selling_partner_id=S",
            "barcodesedori://spapi-auth?refresh_token=token",
            "barcodesedori://spapi-auth?refresh_token=one&refresh_token=two&selling_partner_id=S",
            "barcodesedori://spapi-auth?refresh_token=token&selling_partner_id=A&selling_partner_id=B"
        ] {
            precondition(parse(invalid) == nil, "Malformed callback was accepted")
        }
        print("SpApiAuthorizationCallback tests passed")
    }
}
