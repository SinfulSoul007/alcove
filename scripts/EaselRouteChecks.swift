import Foundation
import BrowserCore

@main struct EaselRouteChecks {
    static func main() {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        let id = UUID(uuidString: "A051A37E-E449-49F7-B5EF-CA34456F6423")!
        let expected = "alcove://easel/a051a37e-e449-49f7-b5ef-ca34456f6423"
        let route = EaselRoute(id: id)
        check(route.url.absoluteString == expected && EaselRoute.parse(expected)?.id == id, "A canvas route roundtrips one exact UUID")
        check(EaselRoute.parse(expected.uppercased())?.id == id, "Native scheme, host and UUID accept ASCII case differences")
        for address in [
            "alcove://easel/", "alcove://easel/not-a-uuid", expected + "/", expected + "/extra",
            expected + "?profile=other", expected + "#frame", " " + expected, expected + "\n",
            "alcove://name@easel/" + id.uuidString, "alcove://name:secret@easel/" + id.uuidString,
            "alcove://easel:80/" + id.uuidString, "alcove://%65asel/" + id.uuidString,
            "alcove://easel/%61" + String(id.uuidString.dropFirst()), "alcove://easel/../" + id.uuidString,
            "alcove://easel//" + id.uuidString, "alcove://easel.evil/" + id.uuidString,
            "https://easel/" + id.uuidString, "file://easel/" + id.uuidString,
            "webkit-extension://easel/" + id.uuidString, "alcove:easel/" + id.uuidString
        ] { check(EaselRoute.parse(address) == nil, "Malformed or ambiguous text is not a canvas route: " + address.debugDescription) }
        for address in [expected, "alcove://unknown/page", "ALCOVE:broken", "alcove://easel/not-a-uuid"] {
            check(EaselRoute.isNative(address), "The reserved application scheme stays native even for an unavailable route")
        }
        for address in ["https://example.com/alcove:page", "https://alcove.example/", "javascript:alcove", "webkit-extension://easel/page", ""] {
            check(!EaselRoute.isNative(address), "A web address or different scheme is not captured by native routing")
        }
        check(Address.resolve(expected) == nil, "Native routing does not broaden the ordinary web address resolver")
        print("Easel route checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
