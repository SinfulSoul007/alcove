import AppKit
import BrowserCore
import WebKit
import ImageIO

@main struct EaselExportWebsiteChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let assets = EaselAssetStore(privateProfileID: UUID())
        let pixels = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(red: 0, green: 0.7, blue: 0.4, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let png = NSMutableData(), encoder = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, pixels.makeImage()!, nil); precondition(CGImageDestinationFinalize(encoder))
        let id = try assets.put(png as Data)
        let hostile = "Keep 🌲 مرحبا <script>window.exportRan=1</script><img src='http://127.0.0.1:9/probe' onerror='window.exportRan=2'>"
        var board = try Easel(title: "Portable <ideas>")
        let note = try EaselItem(frame: EaselFrame(x: 20, y: 20, width: 320, height: 180), content: .note(text: hostile))
        let image = try EaselItem(frame: EaselFrame(x: 380, y: 30, width: 200, height: 140), content: .image(assetID: id, pixelWidth: 20, pixelHeight: 10, sourceURL: "https://example.com/?a=1&b=2", sourceTitle: "Source <svg onload='window.exportRan=3'>"))
        for item in [note,image] { try board.apply(.insert(item), expectedRevision: board.revision) }
        let exported = try EaselCanvasExport(easel: board, assets: assets).html()
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        defer { web.stopLoading(); web.loadHTMLString("", baseURL: nil) }
        web.load(exported, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: URL(string: "about:blank")!)
        for _ in 0..<1000 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete' && document.images.length===1 && document.images[0].naturalWidth===20")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check((try? await web.evaluateJavaScript("document.title")) as? String == "Portable <ideas>", "Real WebKit opens the offline export with its original escaped title")
        check((try? await web.evaluateJavaScript("document.querySelector('.card').textContent")) as? String == hostile, "Offline roundtrip preserves the complete Unicode note as literal text")
        check((try? await web.evaluateJavaScript("typeof window.exportRan==='undefined' && document.querySelectorAll('script,iframe,object,form,svg').length===0")) as? Bool == true, "Adversarial note and attribution markup never becomes executable exported content")
        check((try? await web.evaluateJavaScript("document.images.length===1 && document.images[0].src.startsWith('data:image/png;base64,') && document.images[0].naturalWidth===20 && document.images[0].naturalHeight===10")) as? Bool == true, "A separate private WebKit view decodes the embedded image without original asset access")
        check((try? await web.evaluateJavaScript("Array.from(document.images).every(i=>!/^https?:/.test(i.src)) && document.querySelectorAll('link,iframe,object,video,audio').length===0")) as? Bool == true, "Opening the portable document creates no external image or embedded-page source")
        check((try? await web.evaluateJavaScript("document.querySelector('a').href")) as? String == "https://example.com/?a=1&b=2", "Explicit attribution remains a usable source link after offline roundtrip")
        check(!configuration.websiteDataStore.isPersistent, "Offline artifact verification stays inside its own nonpersistent website store")
        print("Easel export website checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
