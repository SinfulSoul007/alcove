import AppKit
import Darwin
import WebKit
import CryptoKit
import Combine
import BrowserCore

@MainActor final class PlaybackFixtureWebView: WKWebView {
    var fixturePlayback: WKMediaPlaybackState = .none
    var fixtureCapture: WKMediaCaptureState = .none
    var fixtureMicrophone: WKMediaCaptureState = .none
    var delayReply = false
    var delayedReply: (@MainActor (WKMediaPlaybackState) -> Void)?
    override var cameraCaptureState: WKMediaCaptureState { fixtureCapture }
    override var microphoneCaptureState: WKMediaCaptureState { fixtureMicrophone }
    override func requestMediaPlaybackState(completionHandler: @escaping @MainActor (WKMediaPlaybackState) -> Void) {
        if delayReply { delayedReply = completionHandler } else { completionHandler(fixturePlayback) }
    }
}

@main struct QuickBrowseLifecycleChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        let owned = try OwnedWebsiteStores()
        if CommandLine.arguments.contains("--cleanup-owned-stores") { exit(await owned.cleanup() ? 0 : 1) }
        guard await owned.cleanup() else { exit(1) }
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        let personalSpace = store.space.id
        let profile = try store.createProfile(name: "Quick lifecycle"); try owned.register(profile)
        let originalSpace = store.space.id
        let activity = try store.openQuickPage(profileID: profile)
        let interaction = Date(timeIntervalSince1970: 4_000_000_000)
        var invalidations = 0
        let observation = store.objectWillChange.sink { invalidations += 1 }
        store.touchQuickPage(activity, now: interaction)
        let activeDocument = store.makeDocument()
        check(invalidations == 0 && activeDocument.library(for: profile).quickPages?.first(where: { $0.id == activity })?.lastActiveAt == interaction, "Tracking quick-window keystrokes persists activity without invalidating the whole sidebar and browser chrome")
        observation.cancel()
        let id = try store.openQuickPage(profileID: profile)
        var page: WKWebView? = store.view(for: id)
        store.openPeek(URL(string: "about:blank")!, from: page!)
        var child: WKWebView? = store.peekView
        store.selectSpace(personalSpace)
        check(store.peekView === child && store.peekParentQuickID == id, "Switching the main window's Space does not dismiss another quick window's Peek")
        if store.peekView == nil { store.openPeek(URL(string: "about:blank")!, from: page!); child = store.peekView }
        try store.assignProfile(BrowserProfile.defaultID, to: originalSpace)
        check(store.peekView === child && store.peekProfileID == profile && store.peekSpaceID == nil, "Reassigning an intended Space retains an independent quick Peek under its captured profile")
        if store.peekView == nil { store.openPeek(URL(string: "about:blank")!, from: page!); child = store.peekView }
        let unrelated = try store.createProfile(name: "Unrelated"); try owned.register(unrelated)
        check(store.peekView === child && store.peekParentQuickID == id, "Creating an unrelated main-window profile does not close a quick Peek")
        if store.peekView == nil { store.openPeek(URL(string: "about:blank")!, from: page!); child = store.peekView }
        let destination = try store.promoteQuickPage(id)
        check(store.peekView === child && store.peekParentQuickID == nil && store.peekSpaceID == destination && store.peekProfileID == profile, "Promoting a quick parent retains its same-profile Peek in the destination Space")
        store.closePeek(); child = nil
        let changing = try store.openQuickPage(profileID: profile)
        var changingPage: WKWebView? = store.view(for: changing)
        store.openPeek(URL(string: "about:blank")!, from: changingPage!)
        child = store.peekView
        let beforeChange = try Data(contentsOf: store.sessionURL)
        var declined = false
        do { try store.changeQuickProfile(changing, to: BrowserProfile.defaultID) } catch { declined = true }
        let afterDeclined = try Data(contentsOf: store.sessionURL)
        check(declined && store.peekView === child && store.quickProfileID(changing) == profile && beforeChange == afterDeclined, "An unconfirmed quick-profile change preserves its parent, Peek and encrypted ownership")
        try store.changeQuickProfile(changing, to: BrowserProfile.defaultID, allowReload: true)
        check(store.peekView == nil && store.views[changing] == nil && store.quickProfileID(changing) == BrowserProfile.defaultID, "A confirmed profile reload also closes the old profile's Peek")
        store.closePeek(); child = nil
        let closing = try store.openQuickPage(profileID: profile)
        var closingPage: WKWebView? = store.view(for: closing)
        store.update(closing) { $0.url = "https://example.com/quick-close" }
        store.openPeek(URL(string: "about:blank")!, from: closingPage!)
        child = store.peekView
        store.vault = MetadataStore(url: root, key: key)
        let beforeClose = try Data(contentsOf: store.sessionURL)
        declined = false
        do { try store.closeQuickPage(closing) } catch { declined = true }
        let afterClose = try Data(contentsOf: store.sessionURL)
        check(declined && !store.savingEnabled && store.quickPage(closing) != nil && store.views[closing] === closingPage && store.peekView === child && beforeClose == afterClose, "A failed quick close preserves its live parent and Peek before any native teardown")
        let beforeNew = Set(store.allQuickPages.map(\.id))
        declined = false
        do { _ = try store.openQuickPage(profileID: profile) } catch { declined = true }
        check(declined && Set(store.allQuickPages.map(\.id)) == beforeNew, "Locked creation cannot expose an undurable quick window")
        let resurfaced = try store.openQuickPage(url: URL(string: "https://example.com/quick-close"), profileID: profile)
        check(resurfaced == closing && store.views[closing] === closingPage, "An already-known quick link can resurface while new metadata writes are paused")
        declined = false
        do { _ = try store.promoteQuickPage(closing) } catch { declined = true }
        check(declined && store.quickPage(closing) != nil && store.views[closing] === closingPage && store.peekView === child, "Locked promotion cannot discard or move a live page or its Peek")
        store.update(closing) { $0.url = "https://example.com/latest-close" }
        store.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where store.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(store.savingEnabled && store.views[closing] === closingPage && store.peekView === child && store.peekParentQuickID == closing && store.quickPage(closing)?.tab.url == "https://example.com/latest-close", "Unlock keeps the latest quick page and its still-owned Peek alive")
        try store.closeQuickPage(closing)
        check(store.quickPage(closing) == nil && store.views[closing] == nil && store.peekView == nil && store.library(for: profile).archive.first?.url == "https://example.com/latest-close", "A retried close archives its latest URL and closes its Peek exactly once")
        let now = Date(timeIntervalSince1970: 100_000)
        let expired = try store.openQuickPage(url: URL(string: "https://expiry.example/old"), profileID: BrowserProfile.defaultID)
        let focused = try store.openQuickPage(url: URL(string: "https://expiry.example/focused"), profileID: BrowserProfile.defaultID)
        let recent = try store.openQuickPage(url: URL(string: "https://expiry.example/recent"), profileID: BrowserProfile.defaultID)
        let loading = try store.openQuickPage(profileID: BrowserProfile.defaultID)
        var loadingView: WKWebView? = store.view(for: loading)
        loadingView!.loadHTMLString("<html><body>Disposable loading fixture</body></html>", baseURL: nil)
        if !loadingView!.isLoading { print("FAIL: Disposable loading fixture did not start"); failures += 1 }
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            for index in (records.quickPages ?? []).indices {
                let id = records.quickPages![index].id
                if [expired, focused, loading].contains(id) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
                if id == recent { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 90_000) }
            }
        }
        store.focusedQuickPageID = focused
        store.archiveInactiveQuickPages(now: now)
        check(store.quickPage(expired) == nil && store.library(for: BrowserProfile.defaultID).archive.first(where: { $0.id == expired })?.archiveSource == "quickBrowse", "Six-hour auto-archive closes and records an inactive quick page")
        check(store.quickPage(focused) != nil && store.quickPage(loading) != nil && store.quickPage(recent) != nil, "Quick auto-archive preserves focused, loading and recently used pages")
        store.preferences.quickBrowseArchiveHours = 0; store.focusedQuickPageID = nil
        store.archiveInactiveQuickPages(now: now)
        check(store.quickPage(focused) != nil, "The Off preference prevents quick auto-archive after focus leaves")
        let blocked = try store.openQuickPage(url: URL(string: "https://expiry.example/paused"), profileID: unrelated)
        store.mutateLibrary(for: unrelated) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == blocked }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.profiles[store.profiles.firstIndex(where: { $0.id == unrelated })!].pendingDataClear = true
        store.preferences.quickBrowseArchiveHours = 6; store.archiveInactiveQuickPages(now: now)
        check(store.quickPage(blocked) != nil, "Auto-archive cannot mutate a profile paused for website-data recovery")
        store.profiles[store.profiles.firstIndex(where: { $0.id == unrelated })!].pendingDataClear = false
        let playingID = try store.openQuickPage(url: URL(string: "https://expiry.example/playing"), profileID: BrowserProfile.defaultID)
        let playingConfig = WKWebViewConfiguration(); playingConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var playingView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: playingConfig)
        playingView!.fixturePlayback = .playing; store.registerView(playingView!, for: playingID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == playingID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.quickPage(playingID)?.lastActiveAt == now && store.views[playingID] === playingView, "Active playback keeps its quick page alive and advances its inactivity timestamp")
        let captureID = try store.openQuickPage(url: URL(string: "https://expiry.example/capture"), profileID: BrowserProfile.defaultID)
        let captureConfig = WKWebViewConfiguration(); captureConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var captureView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: captureConfig)
        captureView!.fixtureCapture = .active; store.registerView(captureView!, for: captureID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == captureID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.quickPage(captureID)?.lastActiveAt == now && store.views[captureID] === captureView, "Active camera capture cannot be auto-archived while its window is in the background")
        let microphoneID = try store.openQuickPage(url: URL(string: "https://expiry.example/microphone"), profileID: BrowserProfile.defaultID)
        let microphoneConfig = WKWebViewConfiguration(); microphoneConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var microphoneView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: microphoneConfig)
        microphoneView!.fixtureMicrophone = .muted; store.registerView(microphoneView!, for: microphoneID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == microphoneID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.quickPage(microphoneID)?.lastActiveAt == now && store.views[microphoneID] === microphoneView, "An ongoing muted microphone session is preserved by quick auto-archive")
        let pausedID = try store.openQuickPage(url: URL(string: "https://expiry.example/paused-media"), profileID: BrowserProfile.defaultID)
        let pausedConfig = WKWebViewConfiguration(); pausedConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var pausedView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: pausedConfig)
        pausedView!.fixturePlayback = .paused; store.registerView(pausedView!, for: pausedID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == pausedID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.quickPage(pausedID) == nil && store.library(for: BrowserProfile.defaultID).archive.contains(where: { $0.id == pausedID }), "Paused media still follows the configured inactivity archive policy")
        let delayedID = try store.openQuickPage(url: URL(string: "https://expiry.example/delayed"), profileID: BrowserProfile.defaultID)
        let delayedConfig = WKWebViewConfiguration(); delayedConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var delayedView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: delayedConfig)
        delayedView!.delayReply = true; store.registerView(delayedView!, for: delayedID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == delayedID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<100 where delayedView!.delayedReply == nil && store.quickPage(delayedID) != nil { try await Task.sleep(for: .milliseconds(10)) }
        if store.quickPage(delayedID) != nil { _ = try store.promoteQuickPage(delayedID) }
        let resume = delayedView!.delayedReply; delayedView!.delayedReply = nil; resume?(.paused)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.session.spaces.flatMap(\.tabs).contains(where: { $0.id == delayedID }) && store.quickPage(delayedID) == nil && store.views[delayedID] === delayedView, "A late media reply cannot overwrite or archive a page already handed into a Space")
        let switchedOffID = try store.openQuickPage(url: URL(string: "https://expiry.example/turned-off"), profileID: BrowserProfile.defaultID)
        let switchedOffConfig = WKWebViewConfiguration(); switchedOffConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var switchedOffView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: switchedOffConfig)
        switchedOffView!.delayReply = true; store.registerView(switchedOffView!, for: switchedOffID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == switchedOffID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now); store.preferences.quickBrowseArchiveHours = 0
        let disabledReply = switchedOffView!.delayedReply; switchedOffView!.delayedReply = nil; disabledReply?(.paused)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.quickPage(switchedOffID) != nil && store.views[switchedOffID] === switchedOffView, "Turning auto-archive Off while WebKit is replying prevents that pending close")
        store.preferences.quickBrowseArchiveHours = 6
        switchedOffView!.delayReply = false; switchedOffView!.fixturePlayback = .playing
        let unknownID = try store.openQuickPage(url: URL(string: "https://expiry.example/unresponsive"), profileID: BrowserProfile.defaultID)
        let unknownConfig = WKWebViewConfiguration(); unknownConfig.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        var unknownView: PlaybackFixtureWebView? = PlaybackFixtureWebView(frame: .zero, configuration: unknownConfig)
        unknownView!.delayReply = true; store.registerView(unknownView!, for: unknownID, profile: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == unknownID }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(store.quickArchiveProbeID == nil && store.quickPage(unknownID) != nil && store.views[unknownID] === unknownView, "An unresponsive media query times out without closing an unknown live page")
        unknownView!.delayedReply = nil
        unknownView!.delayReply = false; unknownView!.fixturePlayback = .playing
        let failedArchive = try store.openQuickPage(url: URL(string: "https://expiry.example/save-failure"), profileID: BrowserProfile.defaultID)
        store.mutateLibrary(for: BrowserProfile.defaultID) { records in
            if let index = records.quickPages?.firstIndex(where: { $0.id == failedArchive }) { records.quickPages?[index].lastActiveAt = Date(timeIntervalSince1970: 1) }
        }
        store.vault = MetadataStore(url: root, key: key)
        let beforeAutoSave = try Data(contentsOf: store.sessionURL)
        store.archiveInactiveQuickPages(now: now)
        for _ in 0..<300 where store.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        let afterAutoSave = try Data(contentsOf: store.sessionURL)
        check(!store.savingEnabled && store.quickPage(failedArchive) != nil && !store.library(for: BrowserProfile.defaultID).archive.contains(where: { $0.id == failedArchive }) && beforeAutoSave == afterAutoSave, "A failed archive save leaves every page and its prior ciphertext intact")
        store.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where store.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        let privateRoot = root.appendingPathComponent("private-auto")
        var privateKeyRequests = 0
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in privateKeyRequests += 1; return key })
        let privateID = try privateStore.openQuickPage(url: URL(string: "https://expiry.example/private"))
        check(privateStore.archiveTimer?.isValid == true, "A private owner starts its own quick archive timer only when quick windows exist")
        privateStore.mutateLibrary(for: BrowserProfile.defaultID) { records in records.quickPages?[0].lastActiveAt = Date(timeIntervalSince1970: 1) }
        privateStore.archiveInactiveQuickPages(now: now)
        check(privateStore.quickPage(privateID) == nil && privateStore.library.archive.first?.url == "https://expiry.example/private" && privateKeyRequests == 0 && !FileManager.default.fileExists(atPath: privateRoot.path), "Private auto-archive keeps its records in memory without requesting a normal key or file")
        check(privateStore.archiveTimer?.isValid != true, "A private owner stops its archive timer after its final quick window leaves")
        privateStore.shutdown(); loadingView = nil; playingView = nil; captureView = nil; pausedView = nil; delayedView = nil; microphoneView = nil; switchedOffView = nil; unknownView = nil
        store.shutdown(); page = nil; changingPage = nil; closingPage = nil; child = nil
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while store.closingPages.contains(where: { $0.webView != nil }) && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        store.namedDataStores.removeAll(); if !(await owned.cleanup()) { failures += 1 }
        exit(failures == 0 ? 0 : 1)
    }
}
