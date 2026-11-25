import AppKit
import SwiftUI
import Combine
import WebKit
import CryptoKit
import BrowserCore
import Darwin

@main struct ReaderModeChecks {
    enum Failure: Error { case timeout(String), fixture, checks(Int) }
    @MainActor static func wait(_ label: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<700 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw Failure.timeout(label)
    }
    @MainActor static func ready(_ web: WKWebView) async throws {
        for _ in 0..<700 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("READER_SOURCE_PRIMITIVE", (try? await web.evaluateJavaScript("42")) ?? "unavailable")
        throw Failure.timeout("source document")
    }
    @MainActor static func reader(_ store: BrowserStore, _ source: WKWebView) async throws -> ReaderSession {
        store.toggleReader(source)
        guard let session = store.readerSession(for: source) else { throw Failure.fixture }
        try await wait("Reader ready") { session.state != .loading }
        guard session.state == .ready else {
            print("READER_PREPARATION_STATE", session.state)
            print("READER_SOURCE_PRIMITIVE", (try? await source.evaluateJavaScript("42")) ?? "unavailable")
            throw Failure.fixture
        }
        return session
    }
    @available(macOS 15.4, *) @MainActor static func exercise(owned: OwnedWebsiteStores, controllers: OwnedExtensionControllers) async throws {
        guard let input = ProcessInfo.processInfo.environment["ALCOVE_READER_FIXTURE_URL"], let base = URL(string: input) else { throw Failure.fixture }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-reader-owned-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = Data("blocked.alcove.example\n".utf8)
        let metadata = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "provider": "PhishDestroy", "sourceRevision": String(repeating: "1", count: 40), "sourceUpdatedAt": "2026-11-01T00:00:00Z", "retrievedAt": "2026-11-02T00:00:00Z", "sha256": SHA256.hash(data: rows).map { String(format: "%02x", $0) }.joined(), "licenseSHA256": String(repeating: "0", count: 64), "domainCount": 1])
        let catalog = try WebsiteThreatCatalog(domains: rows, metadata: metadata)
        let protection = WebsiteProtectionService(loader: { catalog }); _ = await protection.load()
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in SymmetricKey(data: Data(repeating: 71, count: 32)) }, websiteProtection: protection)
        let owner = BrowserWindowOwner(store: store), lease = try owner.acquirePrimaryStore().lease
        defer { owner.release(lease); store.shutdown() }
        let profile = try store.createProfile(name: "Owned Reader profile")
        try owned.register(profile)
        func recordControllers() throws { for item in store.profiles where item.id == profile { if let id = item.extensionControllerID { try controllers.register(id) } } }
        try recordControllers(); store.finishOnboarding()
        let id = store.newTab(url: base.appendingPathComponent("article")), source = store.view(for: id)
        let host = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        WebPane(webView: source, store: store).mount(in: host); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("owned Reader window active") { NSApp.isActive && window.isKeyWindow }
        let app = AppDelegate(); app.windows[window] = store
        defer { app.windows.removeAll() }
        try await ready(source)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(label)"); if !value { failures += 1 } }
        check(store.responds(to: NSSelectorFromString("toggleReader:")), "BrowserStore exposes the native Reader action")
        _ = try await source.evaluateJavaScript("document.getElementById('draft').value='typed draft';window.sourceSentinel=42;window.scrollTo(0,320);true")
        let before = try await source.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let document = store.documentIdentity(for: source), originalURL = source.url
        let originalAppearance = window.effectiveAppearance.name
        let session = try await reader(store, source)
        let firstResponder = window.firstResponder as? NSView
        print("READER_FOCUS_STATE", "active", NSApp.isActive, "key", window.isKeyWindow, "mounted", session.reader.window === window, "accepts", session.reader.acceptsFirstResponder, "responder", window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
        check(window.isKeyWindow && firstResponder.map { $0 === session.reader || $0.isDescendant(of: session.reader) } == true, "The visible Reader receives keyboard focus instead of scrolling the hidden source")
        check(session.source === source && session.profileID == profile && session.window === window, "Reader captures the original webpage profile and native window")
        check(source.superview === host && session.reader !== source && session.overlay?.superview === host, "Reader overlays the mounted original page without replacing it")
        check(session.reader.configuration.websiteDataStore.isPersistent == false && session.reader.configuration.webExtensionController == nil && session.reader.configuration.userContentController.userScripts.isEmpty, "Renderer has an ephemeral store and no extension controller or injected scripts")
        check(!session.reader.allowsLinkPreview, "Reader disables external link previews")
        check(!session.reader.configuration.defaultWebpagePreferences.allowsContentJavaScript, "Reader disables article JavaScript")
        let body = try await session.reader.evaluateJavaScript("document.querySelector('main').innerHTML") as? String ?? ""
        check(body.contains("Along the valley") && body.contains("<strong>Evidence</strong>") && !body.contains("CHROME_NAVIGATION") && !body.contains("<form"), "Reader renders article structure without site chrome or forms")
        _ = try await session.reader.evaluateJavaScript("const attempt=document.createElement('script');attempt.textContent='window.untrustedRan=1';document.body.appendChild(attempt);true")
        check((try await session.reader.evaluateJavaScript("typeof window.untrustedRan==='undefined'") as? Bool) == true, "CSP prevents even a subsequently inserted article script from executing")
        _ = try await session.reader.evaluateJavaScript("window.scrollTo(0,400);true")
        let hasPassage = try await session.reader.evaluateJavaScript("""
            (() => {
                const box = document.querySelector('main').getBoundingClientRect();
                const range = document.caretRangeFromPoint(box.left + 16, 32);
                if (!range || range.startContainer.nodeType !== 3 || !range.startContainer.length) return false;
                const node = range.startContainer, offset = Math.min(range.startOffset, node.length - 1);
                range.setStart(node, offset); range.setEnd(node, offset + 1);
                window.alcoveOwnedReaderPassage = { range, node, offset, text: node.data.slice(offset, offset + 48), top: range.getBoundingClientRect().top };
                return offset > 0;
            })()
            """) as? Bool
        check(hasPassage == true, "Reader appearance fixture identifies text inside a visible paragraph")
        session.theme = .dark; session.sansSerif = true; session.textSize = 26; session.lineWidth = 560
        for _ in 0..<200 {
            if (try? await session.reader.evaluateJavaScript("document.documentElement.style.getPropertyValue('--size')==='26px'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(window.effectiveAppearance.name == originalAppearance, "Reader theme leaves the original window appearance unchanged")
        print("READER_STYLE_STATE", session.state, "current", session.isCurrent, "sameDocument", store.documentIdentity(for: source) === document, "sourceMessage", store.message ?? "none")
        check((try await session.reader.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--paper').trim()==='#202225'&&document.documentElement.style.getPropertyValue('--font').includes('-apple-system')&&document.documentElement.style.getPropertyValue('--width')==='560px'") as? Bool) == true, "Reader controls apply the requested theme, font, text size and width")
        let samePassage = try await session.reader.evaluateJavaScript("""
            (() => {
                const a = window.alcoveOwnedReaderPassage;
                return a && a.node.isConnected && a.range.startContainer === a.node && a.range.startOffset === a.offset
                    && a.node.data.slice(a.offset, a.offset + 48) === a.text && Math.abs(a.range.getBoundingClientRect().top - a.top) <= 2;
            })()
            """) as? Bool
        check(samePassage == true, "Appearance reflow preserves the actual visible text passage and its position")
        let afterControls: String?
        do { afterControls = try await source.evaluateJavaScript("document.documentElement.outerHTML") as? String }
        catch {
            print("READER_SOURCE_BOUNDARY", error, "state", session.state, "current", session.isCurrent, "sameDocument", store.documentIdentity(for: source) === document, "message", store.message ?? "none", "primitive", (try? await source.evaluateJavaScript("42")) ?? "unavailable")
            throw error
        }
        let draftAfterControls = try await source.evaluateJavaScript("document.getElementById('draft').value==='typed draft'&&window.sourceSentinel===42&&scrollY===320") as? Bool
        print("READER_APPEARANCE_DIAGNOSTIC", "state", session.state, "current", session.isCurrent, "sameSourceDocument", store.documentIdentity(for: source) === document, "sourceMessage", store.message ?? "none")
        check(afterControls == before && draftAfterControls == true, "Reader controls preserve the exact source DOM, draft, globals and scroll")
        let queryObservation = session.$searchText.sink { print("READER_FIND_QUERY", $0) }
        let resultObservation = session.$searchResult.sink { print("READER_FIND_RESULT", $0.map(String.init) ?? "pending") }
        defer { queryObservation.cancel(); resultObservation.cancel() }
        print("READER_FIND_STATE", "active", NSApp.isActive, "key", window.isKeyWindow, "current", session.isCurrent, "mounted", session.reader.window === window)
        session.requestFind()
        try await wait("Reader find field focus") { session.searchVisible && window.firstResponder is NSTextView }
        session.searchText = "river"; session.find()
        // Native text bindings can echo an unchanged value while WebKit searches.
        session.searchText = "river"
        try await wait("Reader find") { session.searchResult != nil }
        check(session.searchResult == true, "Reader find searches the visible article")
        session.searchText = "river"
        check(session.searchResult == true, "An unchanged Reader query preserves the current match result")
        session.searchText = "missing-owned-reader-phrase"; session.find()
        try await wait("Reader no matches") { session.searchResult != nil }
        check(session.searchResult == false, "Reader find reports missing text without searching a hidden original page")
        check(app.handleEscape(in: window) && !session.searchVisible && store.readerSession(for: source) === session, "Escape first closes Reader find without leaving the article")
        check(app.handleEscape(in: window) && store.readerSession(for: source) == nil, "A second Escape exits Reader through the native window command")
        session.dismiss(restoringFocus: true)
        check(store.readerSession(for: source) == nil && source.superview === host && source.url == originalURL && store.documentIdentity(for: source) === document, "Exit restores the same original view, address and document identity")
        check((try await source.evaluateJavaScript("document.getElementById('draft').value==='typed draft'&&scrollY===320") as? Bool) == true, "Exit preserves the original unsaved form and scroll")

        let failed = try await reader(store, source)
        failed.webView(failed.reader, didFail: nil, withError: NSError(domain: "OwnedReaderFailure", code: 1))
        let failedState = failed.state, failedResponder = window.firstResponder
        failed.webView(failed.reader, didFinish: nil)
        check(failed.state == failedState && { if case .failed = failed.state { return true }; return false }(), "Late native completion cannot replace Reader failure")
        check(window.firstResponder === failedResponder && store.documentIdentity(for: source) === document, "Late native completion leaves focus and the original document alone")
        failed.dismiss(restoringFocus: true)

        // This executable owns its adjacent manual-build resources. Temporarily
        // remove only that copied style asset, never source or installed app data.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let ownedAssets = executable.deletingLastPathComponent().appendingPathComponent("ReaderAssets")
        guard executable.lastPathComponent == "reader-mode-checks",
              Bundle.main.resourceURL?.standardizedFileURL.resolvingSymlinksInPath() == executable.deletingLastPathComponent() else { throw Failure.fixture }
        let styleFile = ownedAssets.appendingPathComponent("Style.js")
        let savedStyle = ownedAssets.appendingPathComponent("Style-owned-backup-" + UUID().uuidString)
        try FileManager.default.moveItem(at: styleFile, to: savedStyle)
        var styleRestored = false
        defer { if !styleRestored { try? FileManager.default.moveItem(at: savedStyle, to: styleFile) } }
        store.toggleReader(source)
        guard let missingStyle = store.readerSession(for: source) else { throw Failure.fixture }
        try await wait("missing style feedback") { missingStyle.state != .loading }
        check(missingStyle.state == .failed(ReaderFailure.resources.message), "A missing owned style asset keeps Reader unavailable")
        let resourceResponder = window.firstResponder as? NSView
        check(resourceResponder.map { $0 === missingStyle.reader || $0.isDescendant(of: missingStyle.reader) } != true, "Synchronous style failure cannot hand focus to the unavailable article")
        missingStyle.webView(missingStyle.reader, didFinish: nil)
        check(missingStyle.state == .failed(ReaderFailure.resources.message), "Late completion cannot replace the missing-resource explanation")
        try FileManager.default.moveItem(at: savedStyle, to: styleFile); styleRestored = true
        missingStyle.dismiss(restoringFocus: true)

        let nextSession = try await reader(store, source)
        _ = try await nextSession.reader.evaluateJavaScript("document.querySelector('main a').click();true")
        try await wait("Reader link exits") { store.readerSession(for: source) == nil }
        try await ready(source)
        check(source.url?.path == "/next" && nextSession.state == .closed, "A Reader link returns through the registered original browser view")
        _ = try await source.evaluateJavaScript("document.getElementById('draft').value='protected draft';true")
        let protected = try await reader(store, source)
        protected.openLink(URL(string: "http://blocked.alcove.example/owned-reader-link")!)
        try await wait("Reader link protection") { store.websiteProtectionTicket(for: source)?.isPending == true }
        let protectedDraft = try await source.evaluateJavaScript("document.getElementById('draft').value==='protected draft'") as? Bool
        check(protected.state == .closed && protectedDraft == true, "Reader links retain normal website protection and the unsaved source form")
        store.cancelWebsiteProtectionTickets(for: source)
        let popupReader = try await reader(store, source)
        let oldIDs = Set(store.views.keys)
        popupReader.openLink(base.appendingPathComponent("new-page"), modifiers: .command)
        guard let newWeb = store.views.first(where: { !oldIDs.contains($0.key) }) else { throw Failure.fixture }
        check(store.profileID(for: newWeb.value) == profile && newWeb.value !== source && popupReader.state == .closed, "Command-click creates a normal webpage with the captured source profile")
        store.close(newWeb.key); store.select(id); WebPane(webView: source, store: store).mount(in: host)
        let pending = try await reader(store, source)
        store.invalidateDocumentIdentity(for: source)
        check(pending.state == .closed && store.readerSession(for: source) == nil, "Document invalidation revokes the mounted Reader and callbacks")
        let replacement = try await reader(store, source)
        pending.dismiss(restoringFocus: true)
        check(store.readerSession(for: source) === replacement, "A retained stale exit control cannot dismiss a replacement Reader")
        source.load(URLRequest(url: base.appendingPathComponent("article?new")))
        try await ready(source)
        check(replacement.state == .closed && store.readerSession(for: source) == nil, "Actual source navigation cancels Reader")
        store.toggleReader(source)
        let extracting = store.readerSession(for: source)
        store.invalidateDocumentIdentity(for: source)
        try await Task.sleep(for: .milliseconds(200))
        check(extracting?.state == .closed && store.readerSession(for: source) == nil && !host.subviews.contains(where: { $0.identifier?.rawValue == "AlcoveReader" }), "Cancellation before extraction completion cannot remount a stale overlay")

        source.load(URLRequest(url: base.appendingPathComponent("short"))); try await ready(source)
        store.toggleReader(source)
        guard let unavailable = store.readerSession(for: source) else { throw Failure.fixture }
        try await wait("unavailable feedback") { unavailable.state != .loading }
        if case .failed(let message) = unavailable.state { check(message.contains("No readable article"), "Short nonarticles show honest Reader unavailability") }
        else { check(false, "Short nonarticles do not become raw text dumps") }
        unavailable.dismiss(); source.load(URLRequest(url: base.appendingPathComponent("article"))); try await ready(source)

        let secondID = store.newTab(url: base.appendingPathComponent("second")), second = store.view(for: secondID)
        store.select(id); guard store.openInSplit(secondID), let layout = store.splitLayout else { throw Failure.fixture }
        let split = NativeBrowserSplit(layout: layout, size: CGSize(width: 1000, height: 700), onResize: { store.rememberSplitPaneSizes(for: $0, lengths: $1) }, pane: { WebPane(webView: store.view(for: $0), store: store) })
        let splitHost = NSHostingView(rootView: split); splitHost.sizingOptions = []; window.contentView = splitHost; splitHost.layoutSubtreeIfNeeded()
        try await ready(second); store.focusPane(id)
        let left = try await reader(store, source)
        store.focusPane(secondID); let right = try await reader(store, second)
        check(left.source === source && right.source === second && left !== right && left.isCurrent && right.isCurrent, "Both native split panes keep independent Reader sessions")
        check(app.outputTarget(in: window)?.web === second, "Native page commands follow the focused split pane")
        left.dismiss(); right.dismiss(); store.separateSplit()
        window.contentView = host; WebPane(webView: source, store: store).mount(in: host); store.select(id)

        store.openPeek(base.appendingPathComponent("peek"), from: source)
        guard let peek = store.primaryPeekView else { throw Failure.fixture }
        let peekHost = EdgeToEdgeWebHost(frame: NSRect(x: 100, y: 50, width: 800, height: 600)); host.addSubview(peekHost)
        WebPane(webView: peek, store: store).mount(in: peekHost); try await ready(peek)
        let peekReader = try await reader(store, peek)
        check(app.outputTarget(in: window)?.web === peek && peekReader.source === peek, "Peek Reader and native commands target the displayed preview")
        store.closePrimaryPeek()
        check(peekReader.state == .closed && store.readerSession(for: peek) == nil, "Closing Peek cancels its Reader")
        peekHost.removeFromSuperview()

        let quickID = try store.openQuickPage(url: base.appendingPathComponent("quick"), profileID: profile, intendedSpaceID: store.space.id)
        let quick = try QuickBrowseWindowController(owner: owner, pageID: quickID, requestPrimary: {}, requestProfiles: {}, didClose: {})
        quick.surface(); defer { quick.window?.performClose(nil) }
        guard let quickWeb = quick.activeWebView else { throw Failure.fixture }
        try await ready(quickWeb); let quickReader = try await reader(store, quickWeb)
        app.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: quickID)] = quick
        defer { app.quickWindows.removeAll() }
        check(app.outputTarget(in: quick.window)?.web === quickWeb && quickReader.profileID == profile, "Quick Browse Reader targets its own window and profile")
        store.closeQuickPeek(quickID)
        quickReader.dismiss(); store.openPeek(base.appendingPathComponent("quick-peek"), from: quickWeb)
        guard let quickPeek = store.quickPeekView(quickID) else { throw Failure.fixture }
        try await ready(quickPeek)
        try await wait("Quick Peek mounted") { quickPeek.window === quick.window }
        let quickPeekReader = try await reader(store, quickPeek)
        check(app.outputTarget(in: quick.window)?.web === quickPeek && quickPeekReader.window === quick.window, "Quick Peek Reader targets its own preview and native window")
        store.adoptQuickPeek(quickID, into: store.space.id, in: store)
        check(quickPeekReader.state == .closed && store.primaryPeekView === quickPeek && store.readerSession(for: quickPeek) == nil, "Same-store Quick Peek adoption immediately revokes its Reader")
        store.closePrimaryPeek()
        let quickClosingReader = try await reader(store, quickWeb)
        quick.window?.performClose(nil)
        check(quickClosingReader.state == .closed && store.readerSession(for: quickWeb) == nil, "Closing Quick Browse releases its active Reader ownership")

        let promotingID = try store.openQuickPage(url: base.appendingPathComponent("quick-handoff"), profileID: profile, intendedSpaceID: store.space.id)
        let promoting = try QuickBrowseWindowController(owner: owner, pageID: promotingID, requestPrimary: {}, requestProfiles: {}, didClose: {})
        promoting.surface(); defer { promoting.window?.performClose(nil) }
        guard let promotingWeb = promoting.activeWebView else { throw Failure.fixture }
        try await ready(promotingWeb)
        _ = try await promotingWeb.evaluateJavaScript("document.getElementById('draft').value='quick handoff draft';true")
        let promotingDocument = store.documentIdentity(for: promotingWeb), promotingReader = try await reader(store, promotingWeb)
        _ = try store.promoteQuickPage(promotingID, to: store.space.id)
        window.contentView = host; WebPane(webView: promotingWeb, store: store).mount(in: host); window.makeKeyAndOrderFront(nil)
        check(promotingReader.state == .closed && store.readerSession(for: promotingWeb) == nil && store.documentIdentity(for: promotingWeb) === promotingDocument, "Same-store Quick promotion cancels Reader while preserving the live document")
        check((try await promotingWeb.evaluateJavaScript("document.getElementById('draft').value==='quick handoff draft'") as? Bool) == true, "Quick promotion preserves the original unsaved form")
        promoting.window?.performClose(nil); store.close(promotingID)

        window.makeKeyAndOrderFront(nil); store.select(id); WebPane(webView: source, store: store).mount(in: host)
        _ = try await source.evaluateJavaScript("document.getElementById('draft').value='handoff draft';true")
        let handoffReader = try await reader(store, source)
        let other = try owner.acquirePrimaryStore(copying: store)
        defer { owner.release(other.lease) }
        // Opening the second primary claims its selection and transfers the live
        // view already. Assert that real handoff instead of trying to move it twice.
        check(store.views[id] == nil && store.profileID(for: source) == nil
              && other.store.views[id] === source && other.store.profileID(for: source) == profile
              && other.store.documentIdentity(for: source) === handoffReader.document,
              "Opening another owned window transfers the original view, profile and document once")
        check(handoffReader.state == .closed && store.readerSession(for: source) == nil && other.store.readerSession(for: source) == nil, "Handoff discards Reader without copying article state across stores")
        let otherHost = EdgeToEdgeWebHost(frame: host.frame)
        let otherWindow = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false; otherWindow.contentView = otherHost
        WebPane(webView: source, store: other.store).mount(in: otherHost); otherWindow.makeKeyAndOrderFront(nil)
        check((try await source.evaluateJavaScript("document.getElementById('draft').value==='handoff draft'") as? Bool) == true, "Handoff preserves the actual original form")
        let closingReader = try await reader(other.store, source)
        otherWindow.close()
        check(closingReader.state == .closed && other.store.readerSession(for: source) == nil, "Native window closure revokes Reader and retained controls")
        otherWindow.contentView = nil

        store.select(secondID); WebPane(webView: second, store: store).mount(in: host); window.makeKeyAndOrderFront(nil)
        let clearedReader = try await reader(store, second)
        try await store.clearProfileData(profile); try recordControllers()
        check(clearedReader.state == .closed && store.readerSessions.isEmpty && other.store.readerSessions.isEmpty, "Profile clearing discards every owned Reader article and pending extraction")
        print("READER_MODE_CHECKS", checks, "FAILURES", failures)
        if failures > 0 { throw Failure.checks(failures) }
    }
    @MainActor static func run() async throws -> Int32 {
        guard #available(macOS 15.4, *) else { throw Failure.fixture }
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        if CommandLine.arguments.contains("--cleanup-owned-stores") { let a = await controllers.cleanup(), b = await owned.cleanup(); return a && b ? 0 : 1 }
        guard await controllers.cleanup(), await owned.cleanup() else { throw Failure.fixture }
        var good = true
        do { try await exercise(owned: owned, controllers: controllers) } catch { good = false; print("READER_MODE_FAILED", error) }
        let a = await controllers.cleanup(), b = await owned.cleanup(); print("READER_MODE_CLEANUP", a, b)
        return good && a && b ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in try? await Task.sleep(for: .seconds(180)); print("READER_MODE_WATCHDOG_TIMEOUT"); exit(1) }
        Task { @MainActor in do { exit(try await run()) } catch { print("READER_MODE_ERROR", error); exit(1) } }
        NSApp.run()
    }
}
