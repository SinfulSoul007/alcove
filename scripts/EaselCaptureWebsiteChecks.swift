import AppKit
import WebKit
import BrowserCore

@MainActor private final class EaselCaptureWebsiteWindow: NSWindow { override var isKeyWindow: Bool { true } }

@main struct EaselCaptureWebsiteChecks {
    @MainActor static func wait(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<1200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CocoaError(.coderReadCorrupt)
    }
    @MainActor static func snapshot(_ web: WKWebView) async throws -> EaselRaster {
        try await withCheckedThrowingContinuation { continuation in
            EaselCaptureEnvironment.live.snapshot(web) { continuation.resume(with: $0) }
        }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_CAPTURE_FIXTURE_URL"], let url = URL(string: address) else { throw CocoaError(.fileNoSuchFile) }
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.CaptureWebsite." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(isPrivate: true, dataRoot: root, keyProvider: { _ in fatalError("Private capture requested a normal key") })
        store.onboardingVisible = false
        let tab = store.newTab(url: url), web = store.view(for: tab)
        let host = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = EaselCaptureWebsiteWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close(); store.shutdown() }
        WebPane(webView: web, store: store).mount(in: host)
        window.orderFrontRegardless()
        try await wait {
            guard !web.isLoading, web.url == url else { return false }
            return (try? await web.evaluateJavaScript("document.querySelector('article')!==null")) as? Bool == true
        }
        _ = try await web.evaluateJavaScript("document.documentElement.style.background='rgb(200,50,100)';document.body.style.background='rgb(200,50,100)';let header=document.querySelector('header');if(header)header.style.background='rgb(200,50,100)';let input=document.createElement('input');input.id='capture-draft';input.value='kept draft';document.body.appendChild(input);window.captureSentinel=42;true")
        let before = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let source = try EaselCaptureSource(web: web, store: store, window: window)
        let raster = try await snapshot(source.renderedWeb!)
        let pixel = NSBitmapImageRep(data: raster.data)!.colorAt(x: 5, y: 5)!.usingColorSpace(.deviceRGB)!
        check(raster.pixelWidth > 0 && raster.pixelHeight > 0 && raster.pixelWidth <= 4096 && raster.pixelHeight <= 4096 && abs(pixel.redComponent - 200.0/255) < 0.1 && abs(pixel.greenComponent - 50.0/255) < 0.1, "Real public WebKit snapshot captures the visible page pixels within bounded dimensions")
        check((try? await web.evaluateJavaScript("document.documentElement.outerHTML")) as? String == before, "Capturing a real page preserves its document and input state")
        store.toggleReader(web)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return store.readerSession(for: web)?.state == .ready && store.readerSession(for: web)?.reader.window === window && (store.readerSession(for: web)?.reader.bounds.width ?? 0) > 0
        }
        let reader = store.readerSession(for: web)!, readerSource = try EaselCaptureSource(web: web, store: store, window: window)
        let readerRaster = try await snapshot(readerSource.renderedWeb!)
        let paper = NSBitmapImageRep(data: readerRaster.data)!.colorAt(x: 5, y: 5)!.usingColorSpace(.deviceRGB)!
        check(readerSource.renderedWeb === reader.reader && abs(paper.redComponent - 243.0/255) < 0.12 && abs(paper.greenComponent - 234.0/255) < 0.12 && paper.blueComponent > 0.7, "Ready Reader capture contains the displayed reading paper instead of its hidden magenta original")
        let boardID = try store.publishEaselCapture(readerRaster, from: readerSource, destination: .new(title: "Reader snapshot"))
        let saved = store.library.easels!.first(where: { $0.id == boardID })!
        if case .image(let asset, _, _, let attribution, _) = saved.items.first?.content {
            check(try store.easelAssets(for: BrowserProfile.defaultID).read(asset) == readerRaster.data && attribution == url.absoluteString, "A real Reader capture publishes its exact pixels with the original page attribution")
        } else { check(false, "A real Reader capture publishes its exact pixels with the original page attribution") }
        check((try? await web.evaluateJavaScript("window.captureSentinel===42 && document.querySelector('#capture-draft').value==='kept draft'")) as? Bool == true && !FileManager.default.fileExists(atPath: root.path), "Private page and Reader capture preserve the source without creating normal data")
        print("Easel capture website checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
