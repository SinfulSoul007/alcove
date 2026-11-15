import AppKit
import BrowserCore
import WebKit

@MainActor
private final class UploadFixtureDelegate: NSObject, WKUIDelegate {
    let store: BrowserStore
    let files: [URL]
    weak var presentedWindow: NSWindow?
    var recognizedRequest = false

    init(store: BrowserStore, files: [URL]) {
        self.store = store
        self.files = files
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        recognizedRequest = frame.webView === webView && frame.isMainFrame && parameters.allowsMultipleSelection
        guard recognizedRequest else { completionHandler(nil); return }
        store.requestWebsiteFiles(from: webView, present: { window, complete in
            presentedWindow = window
            complete(files)
        }, completion: completionHandler)
    }
}

@main struct WebsitePromptChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print("\(ok ? "PASS" : "FAIL"): \(message)")
            if !ok { failures += 1 }
        }
        let fixture = try OutputFixture(isPrivate: false)
        defer { fixture.close() }
        let store = fixture.store
        let web = fixture.web
        let files = [fixture.root.appendingPathComponent("owned-upload.txt")]
        try Data("Fixture content".utf8).write(to: files[0])

        func fileRequest(from source: WKWebView? = nil) -> (answer: ([URL]?) -> Void, results: () -> [[URL]?]) {
            var result: [[URL]?] = []
            var finish: ([URL]?) -> Void = { _ in }
            store.requestWebsiteFiles(from: source ?? web, present: { _, respond in finish = respond }, completion: { result.append($0) })
            return (finish, { result })
        }
        func mediaRequest(from source: WKWebView? = nil) -> (answer: (Bool) -> Void, results: () -> [WKPermissionDecision]) {
            var result: [WKPermissionDecision] = []
            var finish: (Bool) -> Void = { _ in }
            store.requestWebsiteMedia(from: source ?? web, present: { _, respond in finish = respond }, completion: { result.append($0) })
            return (finish, { result })
        }

        let file = fileRequest()
        file.answer(files)
        check(file.results() == [files], "The foreground website can receive its explicitly selected files")
        let media = mediaRequest()
        media.answer(true)
        check(media.results() == [.grant], "The foreground website can receive a one-time device grant")
        file.answer(nil); media.answer(false)
        check(file.results().count == 1 && media.results().count == 1, "Each website prompt finishes once even when a callback is repeated")

        fixture.window.fixtureKey = false
        check(fileRequest().results() == [nil] && mediaRequest().results() == [.deny],
              "A background page cannot start either website prompt")
        fixture.window.fixtureKey = true
        let otherWindow = OutputFixtureWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.contentView = nil; otherWindow.close() }
        fixture.window.fixtureSheet = otherWindow
        check(fileRequest().results() == [nil] && mediaRequest().results() == [.deny],
              "Website prompts cannot stack on an existing sheet")
        fixture.window.fixtureSheet = nil

        let beforeReload = fileRequest(), mediaBeforeReload = mediaRequest()
        store.webView(web, didCommit: nil)
        beforeReload.answer(files); mediaBeforeReload.answer(true)
        check(beforeReload.results() == [nil] && mediaBeforeReload.results() == [.deny],
              "A same-URL navigation revokes pending file selection and device permission")

        let beforeMove = fileRequest(), mediaBeforeMove = mediaRequest()
        let document = store.documentIdentity(for: web)
        let owner = BrowserWindowOwner(store: store)
        store.namedDataStores[BrowserProfile.defaultID] = web.configuration.websiteDataStore
        let first = try owner.acquirePrimaryStore()
        let second = try owner.acquirePrimaryStore(copying: store, focus: false, claimSelection: false)
        defer { owner.release(second.lease); owner.release(first.lease) }
        guard let tab = store.selectedID, let group = store.windowGroup,
              group.claimPresentation(tabID: tab, in: second.store) else { throw OutputCheckError.expected }
        otherWindow.contentView = web
        guard group.claimPresentation(tabID: tab, in: store) else { throw OutputCheckError.expected }
        fixture.window.contentView = nil
        fixture.window.contentView = web
        check(web.window === fixture.window && store.documentIdentity(for: web) === document,
              "Tab handoff returns the same document to the original window")
        beforeMove.answer(files); mediaBeforeMove.answer(true)
        check(beforeMove.results() == [nil] && mediaBeforeMove.results() == [.deny],
              "Tab handoff revokes both pending prompts even if the same page returns")

        let afterMove = fileRequest(), mediaAfterMove = mediaRequest()
        fixture.window.fixtureKey = false
        afterMove.answer(files); mediaAfterMove.answer(true)
        check(afterMove.results() == [files] && mediaAfterMove.results() == [.grant],
              "A fresh prompt can finish before AppKit returns key status to its original window")
        fixture.window.fixtureKey = true

        let quick = try store.openQuickPage(url: web.url)
        let quickConfiguration = WKWebViewConfiguration()
        quickConfiguration.websiteDataStore = web.configuration.websiteDataStore
        let quickWeb = OutputFixtureWebView(frame: web.frame, configuration: quickConfiguration)
        store.registerView(quickWeb, for: quick, profile: BrowserProfile.defaultID)
        otherWindow.contentView = nil
        otherWindow.contentView = quickWeb
        let quickFile = fileRequest(from: quickWeb), quickMedia = mediaRequest(from: quickWeb)
        check(quickFile.results().isEmpty && quickMedia.results().isEmpty, "A foreground Quick Browse page presents its own prompts")
        _ = try store.promoteQuickPage(quick, to: store.space.id)
        fixture.window.contentView = nil
        fixture.window.contentView = quickWeb
        quickFile.answer(files); quickMedia.answer(true)
        check(store.currentView === quickWeb && quickWeb.window === fixture.window &&
                quickFile.results() == [nil] && quickMedia.results() == [.deny],
              "Promoting a Quick Browse page revokes prompts from its compact window")

        let uploadStore = BrowserStore(isPrivate: true)
        let upload = uploadStore.view(for: uploadStore.selectedID!)
        let delegate = UploadFixtureDelegate(store: uploadStore, files: files)
        upload.uiDelegate = delegate
        let uploadWindow = OutputFixtureWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        uploadWindow.isReleasedWhenClosed = false
        uploadWindow.contentView = upload
        defer { uploadWindow.contentView = nil; uploadWindow.close(); uploadStore.shutdown() }
        upload.loadHTMLString("<input id='owned' type='file' multiple>", baseURL: URL(string: "about:blank"))
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < readyDeadline {
            if (try? await upload.evaluateJavaScript("document.getElementById('owned') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await upload.callAsyncJavaScript("document.getElementById('owned').click(); return true;",
                                                 arguments: [:], in: nil, contentWorld: .page)
        var selected = false
        let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < selectionDeadline {
            if (try? await upload.evaluateJavaScript("document.getElementById('owned').files[0]?.name === 'owned-upload.txt'")) as? Bool == true {
                selected = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let selectedText = try? await upload.callAsyncJavaScript("return document.getElementById('owned').files[0]?.text();",
                                                                 arguments: [:], in: nil, contentWorld: .page)
        check(delegate.recognizedRequest && delegate.presentedWindow === uploadWindow && selected &&
                (selectedText as? String) == "Fixture content",
              "A real WebKit file control receives the selected file from its own window and frame")
        if failures > 0 { exit(1) }
    }
}
