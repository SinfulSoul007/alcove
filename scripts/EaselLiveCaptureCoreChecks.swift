import Foundation
import BrowserCore

/// Value and decoder contracts only. Never opens a page, application or window.
@main struct EaselLiveCaptureCoreChecks {
    static func main() throws {
        var checked = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            checked += 1; if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL"): \(name)")
        }
        func rejects(_ name: String, _ action: () throws -> Void) {
            do { try action(); check(false, name) }
            catch EaselError.invalidContent { check(true, name) }
            catch { check(false, name + " (unexpected \(error))") }
        }
        let viewport = try EaselCaptureViewport(width: 1024, height: 768, scrollX: 12.5, scrollY: 1200, pageZoom: 1.5)
        let crop = try EaselCaptureCrop(x: 0.25, y: 0.125, width: 0.5, height: 0.75)
        let asset = UUID()
        func capture(width: Int = 8000, height: Int = 5000, url: String = "https://example.test:443/page?q=one#section", title: String = "A live page 🌱", view: EaselCaptureViewport? = nil, region: EaselCaptureCrop? = nil) throws -> EaselLiveCapture {
            try EaselLiveCapture(previewAssetID: asset, pixelWidth: width, pixelHeight: height, sourceURL: url, sourceTitle: title, viewport: view ?? viewport, crop: region ?? crop)
        }
        let value = try capture()
        check(value.previewAssetID == asset && value.pixelWidth == 8000 && value.pixelHeight == 5000, "Capture keeps the exact fallback identity and maximum-area image")
        check(value.viewport == viewport && value.crop == crop && value.sourceTitle == "A live page 🌱", "Capture retains native viewport, CSS scroll, crop and Unicode attribution independently")
        check(try EaselCaptureViewport(width: 1, height: 8192, scrollX: 0, scrollY: 16_777_216, pageZoom: 0.5).height == 8192, "Viewport and scroll minimum/maximum boundaries are supported")
        check(try EaselCaptureViewport(width: 8192, height: 1, scrollX: 16_777_216, scrollY: 0, pageZoom: 3).pageZoom == 3, "Reversed viewport boundaries and maximum page zoom are supported")
        check(try EaselCaptureCrop(x: 0, y: 0, width: 1, height: 1).width == 1, "A whole source viewport is a valid live region")
        check(try EaselCaptureCrop(x: 0.75, y: 0.5, width: 0.25, height: 0.5).x == 0.75, "An exact right and bottom edge remains representable")
        for n in [0.0, -1, 8192.01, .infinity, -.infinity, .nan] {
            rejects("Invalid native viewport width \(n)") { _ = try EaselCaptureViewport(width: n, height: 100, scrollX: 0, scrollY: 0, pageZoom: 1) }
            rejects("Invalid native viewport height \(n)") { _ = try EaselCaptureViewport(width: 100, height: n, scrollX: 0, scrollY: 0, pageZoom: 1) }
        }
        for n in [-0.01, 16_777_216.01, .infinity, -.infinity, .nan] {
            rejects("Invalid CSS horizontal scroll \(n)") { _ = try EaselCaptureViewport(width: 100, height: 100, scrollX: n, scrollY: 0, pageZoom: 1) }
            rejects("Invalid CSS vertical scroll \(n)") { _ = try EaselCaptureViewport(width: 100, height: 100, scrollX: 0, scrollY: n, pageZoom: 1) }
        }
        for n in [0.49, 3.01, .infinity, -.infinity, .nan] {
            rejects("Invalid page zoom \(n)") { _ = try EaselCaptureViewport(width: 100, height: 100, scrollX: 0, scrollY: 0, pageZoom: n) }
        }
        for n in [-0.001, 1.001, .infinity, -.infinity, .nan] {
            rejects("Invalid normalized crop x \(n)") { _ = try EaselCaptureCrop(x: n, y: 0, width: 0.1, height: 0.1) }
            rejects("Invalid normalized crop y \(n)") { _ = try EaselCaptureCrop(x: 0, y: n, width: 0.1, height: 0.1) }
        }
        for n in [0.0, -0.1, 1.01, .infinity, .nan] {
            rejects("Invalid normalized crop width \(n)") { _ = try EaselCaptureCrop(x: 0, y: 0, width: n, height: 0.1) }
            rejects("Invalid normalized crop height \(n)") { _ = try EaselCaptureCrop(x: 0, y: 0, width: 0.1, height: n) }
        }
        rejects("Crop cannot cross the right edge") { _ = try EaselCaptureCrop(x: 0.75, y: 0, width: 0.3, height: 1) }
        rejects("Crop cannot cross the bottom edge") { _ = try EaselCaptureCrop(x: 0, y: 0.75, width: 1, height: 0.3) }
        rejects("Rounded addition cannot hide a crop beyond the right edge") { _ = try EaselCaptureCrop(x: 0.75, y: 0, width: Double(0.25).nextUp, height: 1) }
        rejects("Rounded addition cannot hide a positive region starting at the edge") { _ = try EaselCaptureCrop(x: 1, y: 0, width: .leastNonzeroMagnitude, height: 1) }
        let tiny = try EaselCaptureCrop(x: 0, y: 0, width: .leastNonzeroMagnitude, height: 1)
        rejects("An unusable subpoint live region cannot create an unbounded view transform") { _ = try capture(region: tiny) }
        let onePoint = try EaselCaptureCrop(x: 0, y: 0, width: 1.0 / 1024, height: 1.0 / 768)
        check(try capture(region: onePoint).crop == onePoint, "A one-native-point live region is supported without enlarging its definition")
        for dimensions in [(0, 1), (1, 0), (16385, 1), (1, 16385), (8000, 5001), (Int.max, Int.max)] {
            rejects("Invalid fallback image dimensions \(dimensions)") { _ = try capture(width: dimensions.0, height: dimensions.1) }
        }
        check(try capture(width: 16384, height: 1).pixelWidth == 16384, "A maximum-side thin fallback remains valid")
        for url in ["file:///tmp/private", "javascript:alert(1)", "https://user@example.test/", "https://user:password@example.test/", "https://example.test:0/", "https://example.test:65536/", "https://example.test/\nsecret", "https:///", ""] {
            rejects("Unsafe or invalid source URL \(url.debugDescription)") { _ = try capture(url: url) }
        }
        let prefix = "https://example.test/"
        let longestURL = prefix + String(repeating: "a", count: 8192 - prefix.utf8.count)
        check(try capture(url: longestURL).sourceURL.utf8.count == 8192, "The exact source URL byte limit remains supported")
        rejects("Source URL over its byte limit is refused") { _ = try capture(url: longestURL + "a") }
        let unicodeTitle = String(repeating: "🌱", count: 64)
        check(try capture(title: unicodeTitle).sourceTitle.utf8.count == 256, "Title limits count UTF-8 bytes rather than characters")
        for title in ["", " \n\t", unicodeTitle + "a"] {
            rejects("Invalid source title \(title.debugDescription)") { _ = try capture(title: title) }
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder(), data = try encoder.encode(value)
        check(try decoder.decode(EaselLiveCapture.self, from: data) == value, "Stored live definition roundtrips without runtime page state")
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(json["webView"] == nil && json["form"] == nil && json["cookies"] == nil, "Persistent capture values contain no live document, form or cookie state")
        for (field, number) in [("width", 0.0), ("height", 9000), ("scrollX", -1), ("scrollY", 20_000_000), ("pageZoom", 0.1)] {
            json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var changed = json["viewport"] as! [String: Any]; changed[field] = number; json["viewport"] = changed
            rejects("Decoded viewport validates \(field)") { _ = try decoder.decode(EaselLiveCapture.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["crop"] = ["x": 0.9, "y": 0.0, "width": 0.2, "height": 1.0]
        rejects("Decoded crop cannot bypass its viewport edge") { _ = try decoder.decode(EaselLiveCapture.self, from: JSONSerialization.data(withJSONObject: json)) }
        for (field, replacement) in [("sourceURL", "https://person:secret@example.test/"), ("sourceTitle", "")] {
            json = try JSONSerialization.jsonObject(with: data) as! [String: Any]; json[field] = replacement
            rejects("Decoded source validates \(field)") { _ = try decoder.decode(EaselLiveCapture.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]; json["pixelWidth"] = 16385
        rejects("Decoded fallback dimensions remain bounded") { _ = try decoder.decode(EaselLiveCapture.self, from: JSONSerialization.data(withJSONObject: json)) }
        print("Easel live capture core checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
