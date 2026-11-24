import AppKit
import WebKit
import Darwin

@MainActor final class ReaderExtractionLifetime: NSObject, WKNavigationDelegate {
    var terminated = false
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminated = true }
}

@main struct ReaderExtractionChecks {
    @MainActor static func run() async throws -> Int32 {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640), configuration: config)
        let lifetime = ReaderExtractionLifetime(); web.navigationDelegate = lifetime
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer { web.stopLoading(); web.navigationDelegate = nil; window.contentView = nil; window.close() }
        let prose = String(repeating: "A patient reader follows the river through the mountains. This detailed report explains the landscape, its history, and the people who live here. ", count: 12)
        web.loadHTMLString("<html><head><title>The River Report</title></head><body><nav>CHROME_NAVIGATION <a href='/noise'>Account</a></nav><article><h1>The River Report</h1><p>\(prose)</p><h2>Along the valley</h2><p>\(prose)</p><p><strong>Evidence</strong> and <a href='/follow'>further reading</a>.</p></article><form><input id='draft' value='original'></form></body></html>", baseURL: URL(string: "https://reader.alcove.example/story"))
        for _ in 0..<500 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.getElementById('draft') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard (try? await web.evaluateJavaScript("document.getElementById('draft') !== null")) as? Bool == true else { throw NSError(domain: "Reader fixture load timeout", code: 1) }
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value='typed draft';window.sourceSentinel=42;window.scrollTo(0,300);true")
        let before = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Browser/ReaderAssets")
        let script = try ReaderResources.extractionScript(at: root)
        let result = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "AlcoveReaderExtractionChecks")) as? [String: Any]
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(label)"); if !value { failures += 1 } }
        do { _ = try ReaderResources.extractionScript(at: root.appendingPathComponent("missing-owned-resource")); check(false, "Missing extractor resources fail explicitly") }
        catch ReaderFailure.resources { check(true, "Missing extractor resources fail explicitly") }
        check(result?["html"] as? String != nil, "Readability extracts a genuine article")
        if let html = result?["html"] as? String {
            check(html.contains("<h2>Along the valley</h2>") && html.contains("<strong>Evidence</strong>"), "Article headings and emphasis survive extraction")
            check(!html.contains("CHROME_NAVIGATION") && !html.contains("<form"), "Navigation chrome and forms stay outside the article")
            check(html.contains("https://reader.alcove.example/follow"), "Article links resolve against the original document")
        }
        print("READER_STAGE source DOM")
        check((try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String) == before, "Extraction leaves the original DOM untouched")
        print("READER_STAGE source state")
        check((try await web.evaluateJavaScript("document.getElementById('draft').value==='typed draft'&&window.sourceSentinel===42&&scrollY>0") as? Bool) == true, "Extraction preserves typed form, page globals, and scroll")
        // Inject into the owned fixture only. A dangerous attribute or URL escaping
        // the serializer would fail these assertions even with renderer JS disabled.
        print("READER_STAGE hostile fixture")
        _ = try await web.evaluateJavaScript("""
            document.querySelector('article').insertAdjacentHTML('beforeend', '<p id="hostile">Safe text <a href="javascript:alert(1)">bad link</a><a href="https://reader.alcove.example/ok?x=&quot;">good link</a><span onclick="alert(1)" style="background:url(data:image/png,invalid)">styled text</span><img src="data:image/png,invalid" onerror="alert(1)" alt="A river"><iframe src="about:blank"></iframe><svg onload="alert(1)"></svg></p>');true
            """)
        print("READER_STAGE hostile extraction")
        let hostile: [String: Any]?
        do { hostile = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "AlcoveReaderExtractionChecks")) as? [String: Any] }
        catch {
            print("READER_EXTRACTION_BOUNDARY", error, "terminated", lifetime.terminated, "primitive", (try? await web.evaluateJavaScript("42")) ?? "unavailable")
            throw error
        }
        let safe = hostile?["html"] as? String ?? ""
        check(!safe.isEmpty && !safe.contains("javascript:") && !safe.contains("onclick") && !safe.contains("onerror") && !safe.contains("<svg") && !safe.contains("<iframe") && !safe.contains("src=") && !safe.contains("style="), "Hostile elements, event handlers, styles and URL schemes are removed")
        check(safe.contains("bad link") && safe.contains("https://reader.alcove.example/ok"), "Disallowed links retain text while safe links remain usable")
        _ = try await web.evaluateJavaScript("document.body.innerHTML='<p>Short nonarticle page</p>';true")
        let short = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "AlcoveReaderExtractionChecks")) as? [String: Any]
        check(short?["error"] as? String == "unavailable", "Short nonarticles produce honest unavailability")
        _ = try await web.evaluateJavaScript("document.body.textContent='x'.repeat(2000001);true")
        let large = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "AlcoveReaderExtractionChecks")) as? [String: Any]
        check(large?["error"] as? String == "tooLarge", "Oversized documents are rejected before cloning")
        print("READER_EXTRACTION_CHECKS", checks, "FAILURES", failures)
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in do { exit(try await run()) } catch { print("READER_EXTRACTION_ERROR", error); exit(1) } }
        NSApp.run()
    }
}
