import AppKit
import WebKit
import BrowserCore
import ImageIO

// Captured source identity, rather than current selection, owns every later
// snapshot/preview. A URL returning to the same string cannot revive old work.
@main struct EaselCaptureChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        var fixtures: [OutputFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func fixture(isPrivate: Bool = true) throws -> OutputFixture { let f = try OutputFixture(isPrivate: isPrivate); fixtures.append(f); return f }
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let original = try fixture()
        let captured = try EaselCaptureSource(web: original.web, store: original.store, window: original.window)
        check(captured.isCurrent && captured.renderedWeb === original.web, "Visible primary page becomes a source-bound capture")
        original.store.invalidateDocumentIdentity(for: original.web)
        check(!captured.isCurrent, "Same-URL navigation invalidates an earlier capture source")
        let changed = try fixture(), old = try EaselCaptureSource(web: changed.web, store: changed.store, window: changed.window)
        changed.web.fixtureURL = URL(string: "https://output.example.invalid/beta")
        check(!old.isCurrent, "Navigation cannot redirect a pending capture to another page")
        let retired = try fixture(), retiredSource = try EaselCaptureSource(web: retired.web, store: retired.store, window: retired.window)
        retired.store.views.removeValue(forKey: retired.store.selectedID!)
        check(!retiredSource.isCurrent, "A retired page cannot publish its old snapshot")
        let cleared = try fixture(), beforeClear = try EaselCaptureSource(web: cleared.web, store: cleared.store, window: cleared.window)
        cleared.store.invalidateEaselImages(for: BrowserProfile.defaultID)
        check(!beforeClear.isCurrent, "Profile image cancellation invalidates pending source work")
        let shut = try fixture(), beforeShutdown = try EaselCaptureSource(web: shut.web, store: shut.store, window: shut.window)
        shut.store.shutdown(); check(!beforeShutdown.isCurrent, "Shutdown invalidates a pending page capture")
        let covered = try fixture(); covered.store.commandVisible = true
        var rejected = false
        do { _ = try EaselCaptureSource(web: covered.web, store: covered.store, window: covered.window) } catch { rejected = true }
        check(rejected, "Covered page content cannot start a capture behind browser chrome")
        let background = try fixture(); background.window.fixtureKey = false; rejected = false
        do { _ = try EaselCaptureSource(web: background.web, store: background.store, window: background.window) } catch { rejected = true }
        check(rejected, "A background window cannot start a capture chooser")
        let saving = try fixture(), source = try EaselCaptureSource(web: saving.web, store: saving.store, window: saving.window)
        let bytes = NSMutableData()
        let pixel = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixel.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); pixel.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let encoder = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, pixel.makeImage()!, nil); precondition(CGImageDestinationFinalize(encoder))
        let raster = try EaselRaster(data: bytes as Data)
        let savedID = try saving.store.publishEaselCapture(raster, from: source, destination: .new(title: "Captured page"))
        let savedBoard = saving.store.library.easels!.first(where: { $0.id == savedID })!
        check(savedBoard.title == "Captured page" && savedBoard.items.count == 1 && saving.store.tab(saving.store.selectedID!)?.pinned == true, "A new page capture publishes its image, canvas and native pin together")
        if case .image(_, let width, let height, let url, let title) = savedBoard.items[0].content {
            check(width == 120 && height == 80 && url == "https://output.example.invalid/alpha" && title == "Example report", "Page capture retains its exact source attribution")
        } else { check(false, "Page capture retains its exact source attribution") }
        var duplicateRejected = false
        do { _ = try saving.store.publishEaselCapture(raster, from: source, destination: .new(title: "Duplicate")) } catch { duplicateRejected = true }
        check(duplicateRejected && saving.store.library.easels?.count == 1, "A consumed page source cannot publish duplicate canvases after navigation")
        let selected = try fixture(), pageTab = selected.store.selectedID!
        let targetTab = try selected.store.createEasel(title: "Existing capture destination")
        let board = selected.store.easelContext(for: targetTab)!.easel; selected.store.select(pageTab)
        let targetSource = try EaselCaptureSource(web: selected.web, store: selected.store, window: selected.window)
        _ = try selected.store.publishEaselCapture(raster, from: targetSource, destination: .existing(id: board.id, revision: board.revision))
        check(selected.store.library.easels?.first?.items.count == 1 && selected.store.session.spaces.flatMap(\.tabs).filter { EaselRoute.parse($0.url)?.id == board.id }.count == 1, "Capture adds to an existing canvas without duplicating its pin")
        let invalid = try fixture(), invalidSource = try EaselCaptureSource(web: invalid.web, store: invalid.store, window: invalid.window)
        var missingRejected = false
        do { _ = try invalid.store.publishEaselCapture(raster, from: invalidSource, destination: .existing(id: UUID(), revision: UUID())) } catch { missingRejected = true }
        check(missingRejected && invalid.store.library.easels?.isEmpty != false, "A missing capture destination does not create a replacement canvas")
        let peek = try fixture()
        let peekWeb = OutputFixtureWebView(frame: peek.web.frame, configuration: peek.web.configuration)
        peek.store.peekPages[.primary] = PeekState(web: peekWeb, profileID: BrowserProfile.defaultID, spaceID: peek.store.space.id)
        peek.window.contentView = peekWeb
        let peekSource = try EaselCaptureSource(web: peekWeb, store: peek.store, window: peek.window)
        check(peekSource.renderedWeb === peekWeb && peekSource.isCurrent, "A visible primary Peek captures its own document instead of the hidden parent")
        peek.store.closePrimaryPeek()
        check(!peekSource.isCurrent, "Closing Peek invalidates its pending capture")
        let quick = try fixture(), quickID = try quick.store.openQuickPage()
        let quickWeb = OutputFixtureWebView(frame: quick.web.frame, configuration: quick.web.configuration)
        quick.store.registerView(quickWeb, for: quickID, profile: BrowserProfile.defaultID); quick.window.contentView = quickWeb
        let quickSource = try EaselCaptureSource(web: quickWeb, store: quick.store, window: quick.window)
        check(quickSource.renderedWeb === quickWeb && quickSource.isCurrent, "Quick Browse capture stays bound to its compact document")
        try quick.store.closeQuickPage(quickID)
        check(!quickSource.isCurrent, "Retiring a compact document prevents its late capture publication")
        let preparingReader = try fixture()
        let reader = ReaderSession(store: preparingReader.store, source: preparingReader.web, window: preparingReader.window, profile: BrowserProfile.defaultID, url: preparingReader.web.url!)
        preparingReader.store.readerSessions[ObjectIdentifier(preparingReader.web)] = reader
        var readerRejected = false
        do { _ = try EaselCaptureSource(web: preparingReader.web, store: preparingReader.store, window: preparingReader.window) } catch { readerRejected = true }
        check(readerRejected, "Reader preparation cannot silently capture its hidden original page")
        let unicode = try fixture(); unicode.web.fixtureTitle = String(repeating: "🌲", count: 200)
        let unicodeSource = try EaselCaptureSource(web: unicode.web, store: unicode.store, window: unicode.window)
        _ = try unicode.store.publishEaselCapture(raster, from: unicodeSource, destination: .new(title: "Unicode source"))
        check(unicodeSource.title.utf8.count <= 256 && unicode.store.library.easels?.first?.items.count == 1, "Long Unicode page titles cannot break an otherwise valid capture save")
        let credentials = try fixture(); credentials.web.fixtureURL = URL(string: "https://name:password@output.example.invalid/owned")
        let credentialSource = try EaselCaptureSource(web: credentials.web, store: credentials.store, window: credentials.window)
        _ = try credentials.store.publishEaselCapture(raster, from: credentialSource, destination: .new(title: "No credentials"))
        if case .image(_, _, _, let attribution, _) = credentials.store.library.easels?.first?.items.first?.content {
            check(attribution == nil, "Source credentials never enter a saved capture attribution URL")
        } else { check(false, "Source credentials never enter a saved capture attribution URL") }
        let moving = try fixture(isPrivate: false)
        moving.store.namedDataStores[BrowserProfile.defaultID] = moving.web.configuration.websiteDataStore
        let owner = BrowserWindowOwner(store: moving.store), first = try owner.acquirePrimaryStore()
        let second = try owner.acquirePrimaryStore(copying: moving.store, focus: false, claimSelection: false)
        defer { owner.release(second.lease); owner.release(first.lease) }
        let movingSource = try EaselCaptureSource(web: moving.web, store: moving.store, window: moving.window)
        let movingTab = moving.store.selectedID!, group = moving.store.windowGroup!
        let movingWindow = OutputFixtureWindow(contentRect: moving.web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        movingWindow.isReleasedWhenClosed = false; defer { movingWindow.contentView = nil; movingWindow.close() }
        let identity = moving.store.documentIdentity(for: moving.web)
        guard group.claimPresentation(tabID: movingTab, in: second.store) else { throw OutputCheckError.expected }
        movingWindow.contentView = moving.web
        guard group.claimPresentation(tabID: movingTab, in: moving.store) else { throw OutputCheckError.expected }
        moving.window.contentView = nil; moving.window.contentView = moving.web
        check(moving.store.documentIdentity(for: moving.web) === identity && !movingSource.isCurrent, "Moving a live document out and back cannot revive its old capture preview")
        let split = try fixture(), leftID = split.store.selectedID!
        split.store.update(leftID) { $0.url = "https://output.example.invalid/alpha" }
        let right = BrowserCore.Tab(title: "Right capture", url: "https://output.example.invalid/beta")
        var splitDocument = split.store.makeDocument(); splitDocument.session.spaces[0].tabs.append(right)
        try split.store.commitQuickDocument(splitDocument)
        let rightWeb = OutputFixtureWebView(frame: NSRect(x: 400, y: 0, width: 400, height: 600), configuration: split.web.configuration)
        rightWeb.fixtureURL = URL(string: right.url); split.store.registerView(rightWeb, for: right.id, profile: BrowserProfile.defaultID)
        let container = NSView(frame: split.web.frame); split.window.contentView = container
        split.web.frame.size.width = 400; container.addSubview(split.web); container.addSubview(rightWeb)
        split.store.toggleSplit(); split.store.focusPane(leftID)
        let leftCapture = try EaselCaptureSource(web: split.web, store: split.store, window: split.window)
        check(leftCapture.renderedWeb === split.web && leftCapture.isCurrent, "Split capture resolves the focused left document")
        split.store.focusPane(right.id)
        let rightCapture = try EaselCaptureSource(web: rightWeb, store: split.store, window: split.window)
        check(rightCapture.renderedWeb === rightWeb && !leftCapture.isCurrent, "Split focus cannot relabel an earlier capture as the right document")
        print("Easel capture checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
