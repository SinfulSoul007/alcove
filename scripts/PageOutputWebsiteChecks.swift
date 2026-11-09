import AppKit
import WebKit
import PDFKit
import CryptoKit
import BrowserCore

enum OutputWebsiteError: Error { case timedOut, failed }
@MainActor final class OutputWebsiteWindow: NSWindow { override var isKeyWindow: Bool { true } }
@main struct PageOutputWebsiteChecks {
    @MainActor static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw OutputWebsiteError.timedOut
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.OutputWebsite.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0, keyReads = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let a = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("a"), keyProvider: { _ in keyReads += 1; return SymmetricKey(size: .bits256) })
        let b = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("b"), keyProvider: { _ in keyReads += 1; return SymmetricKey(size: .bits256) })
        a.onboardingVisible = false; b.onboardingVisible = false
        let aw = OutputWebsiteWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let bw = OutputWebsiteWindow(contentRect: aw.frame, styleMask: [.titled], backing: .buffered, defer: false)
        aw.isReleasedWhenClosed = false; bw.isReleasedWhenClosed = false
        defer { aw.contentView = nil; bw.contentView = nil; aw.close(); bw.close(); a.shutdown(); b.shutdown() }
        func makeWeb(_ store: BrowserStore, window: NSWindow, marker: String) -> WKWebView {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            store.registerView(web, for: store.selectedID!, profile: BrowserProfile.defaultID); window.contentView = web
            web.loadHTMLString("<html><head><meta charset='utf-8'><title>Output \(marker)</title></head><body><h1>TOP \(marker)</h1><div style='margin-top:2000px'>BOTTOM \(marker)</div></body></html>", baseURL: URL(string: "about:blank"))
            return web
        }
        let alpha = makeWeb(a, window: aw, marker: "ALPHA"), beta = makeWeb(b, window: bw, marker: "BETA")
        try await waitUntil { alpha.title == "Output ALPHA" && beta.title == "Output BETA" && !alpha.isLoading && !beta.isLoading }
        var environment = PageOutputEnvironment.live
        var choices: [(NSWindow, String, PageOutputFormat)] = [], errors: [String] = []
        environment.choose = { window, name, format, done in choices.append((window, name, format)); done(root.appendingPathComponent(name)); return {} }
        environment.reportError = { message, _ in errors.append(message) }
        let output = PageOutputCoordinator(environment: environment)
        output.save(web: alpha, store: a, window: aw, format: .pdf)
        output.save(web: beta, store: b, window: bw, format: .webArchive)
        try await waitUntil { !output.isBusy(in: aw) && !output.isBusy(in: bw) }
        check(errors.isEmpty && choices.count == 2, "Real WebKit capture and the native background writer finish both explicit outputs")
        let pdfURL = root.appendingPathComponent("Output ALPHA.pdf"), archiveURL = root.appendingPathComponent("Output BETA.webarchive")
        let pdf = try Data(contentsOf: pdfURL), archive = try Data(contentsOf: archiveURL)
        let document = PDFDocument(data: pdf), text = document?.string ?? ""
        check(document != nil && text.contains("TOP ALPHA") && text.contains("BOTTOM ALPHA") && !text.contains("TOP BETA"), "The saved PDF contains the chosen whole document, including content below the viewport")
        let plist = try PropertyListSerialization.propertyList(from: archive, options: [], format: nil) as? [String: Any]
        let resource = plist?["WebMainResource"] as? [String: Any]
        let html = (resource?["WebResourceData"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(html.contains("TOP BETA") && html.contains("BOTTOM BETA") && !html.contains("TOP ALPHA"), "The saved WebArchive contains its own complete main resource rather than another page")
        let restoreConfig = WKWebViewConfiguration(); restoreConfig.websiteDataStore = .nonPersistent()
        let restored = WKWebView(frame: alpha.frame, configuration: restoreConfig)
        restored.load(archive, mimeType: "application/x-webarchive", characterEncodingName: "UTF-8", baseURL: URL(string: "about:blank")!)
        try await waitUntil { (try? await restored.evaluateJavaScript("document.body && document.body.textContent.includes('BOTTOM BETA')")) as? Bool == true }
        check((try? await restored.evaluateJavaScript("document.body.textContent.includes('TOP BETA') && !document.body.textContent.includes('TOP ALPHA')")) as? Bool == true, "A separate nonpersistent WebKit view can consume the actual saved archive")
        restored.stopLoading()
        let operation = PageOutputNative.printOperation(for: alpha)
        check(operation.showsPrintPanel && operation.showsProgressPanel && operation.jobTitle == "Output ALPHA", "Native print construction preserves the real page title and always requires the print panel")
        let pdfPanel = PageOutputNative.savePanel(name: "Chosen.pdf", format: .pdf)
        let archivePanel = PageOutputNative.savePanel(name: "Chosen.webarchive", format: .webArchive)
        check(pdfPanel.nameFieldStringValue == "Chosen.pdf" && pdfPanel.allowedContentTypes == [.pdf] && !pdfPanel.allowsOtherFileTypes && archivePanel.allowedContentTypes == [.webArchive], "Native save panels present the requested names and restrict the correct file formats")
        check(keyReads == 0 && !FileManager.default.fileExists(atPath: a.sessionURL.path) && !FileManager.default.fileExists(atPath: b.sessionURL.path), "Real private SDK output writes only selected files and never normal metadata or keys")
        let originalURL = alpha.url
        var pendingChoice: ((URL?) -> Void)?, orphaned: [String] = [], localErrors: [String] = []
        var held = PageOutputEnvironment.live
        held.choose = { _, _, _, done in pendingChoice = done; return {} }
        held.reportError = { text, _ in localErrors.append(text) }; held.reportOrphanedError = { orphaned.append($0) }
        let staleOutput = PageOutputCoordinator(environment: held)
        staleOutput.save(web: alpha, store: a, window: aw, format: .pdf)
        try await waitUntil { pendingChoice != nil }
        alpha.loadHTMLString("<title>REPLACEMENT B</title><body>New account document</body>", baseURL: originalURL)
        try await waitUntil { alpha.title == "REPLACEMENT B" && !alpha.isLoading }
        let staleFile = root.appendingPathComponent("stale-document.pdf")
        pendingChoice?(staleFile)
        try await waitUntil { !staleOutput.isBusy(in: aw) }
        check(alpha.url == originalURL && !FileManager.default.fileExists(atPath: staleFile.path) && orphaned.count == 1, "A real same-URL WebKit replacement rejects a pending original-document export")
        orphaned.removeAll(); pendingChoice = nil
        var pendingWrite: ((Result<Void, Error>) -> Void)?
        held.choose = { _, _, _, done in done(root.appendingPathComponent("accepted.pdf")); return {} }
        held.write = { _, _, done in pendingWrite = done }
        let acceptedOutput = PageOutputCoordinator(environment: held)
        acceptedOutput.save(web: alpha, store: a, window: aw, format: .pdf)
        try await waitUntil { pendingWrite != nil }
        alpha.loadHTMLString("<title>REPLACEMENT C</title><body>Another account document</body>", baseURL: originalURL)
        try await waitUntil { alpha.title == "REPLACEMENT C" && !alpha.isLoading }
        pendingWrite?(.failure(OutputWebsiteError.failed))
        check(orphaned.count == 1 && localErrors.isEmpty && acceptedOutput.pendingOutputCount == 0, "An accepted export failure after real same-URL replacement stays generic and drains its operation")
        if failures > 0 { throw OutputWebsiteError.failed }
    }
}
