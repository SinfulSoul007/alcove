import AppKit
import BrowserCore
import CryptoKit
import WebKit

enum BrowserWindowHandoffTestError: Error {
    case missingWindow, pageDidNotLoad
}

@main
struct BrowserWindowHandoffChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let owned = try OwnedWebsiteStores()
        guard await owned.cleanup() else { exit(1) }
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-window-handoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let key = SymmetricKey(size: .bits256)
        let root = BrowserStore(dataRoot: dataRoot, keyProvider: { _ in key })
        let privateWindow = BrowserStore(isPrivate: true)
        let owner = BrowserWindowOwner(store: root)
        let first = try owner.acquirePrimaryStore()
        let second = try owner.acquirePrimaryStore(copying: root)
        let child = second.store
        defer {
            owner.release(first.lease)
            owner.release(second.lease)
            privateWindow.shutdown()
        }
        guard let group = root.windowGroup, let rootID = root.windowGroupID, let childID = child.windowGroupID else {
            throw BrowserWindowHandoffTestError.missingWindow
        }
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL"): \(description)")
            if condition { passed += 1 } else { failed += 1 }
        }

        let movingTab = root.newTab()
        let independentTab = child.newTab()
        let source = root.view(for: movingTab)
        let independent = child.view(for: independentTab)
        try await loadFixture(source, token: "moving")
        try await loadFixture(independent, token: "independent")
        let identity = root.documentIdentity(for: source)
        let independentIdentity = child.documentIdentity(for: independent)
        let paneFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let originalHost = EdgeToEdgeWebHost(frame: paneFrame)
        let destinationHost = EdgeToEdgeWebHost(frame: paneFrame)
        let obsoletePane = WebPane(webView: source, store: root)
        obsoletePane.mount(in: originalHost)
        check(source.superview === originalHost, "The initial pane mounts the live WebKit view")

        check(group.presentation(tabID: movingTab, in: child) == .elsewhere(windowID: rootID),
              "Normal rendering can identify the existing presenter without claiming a tab")
        check(child.primaryPageView(for: movingTab) == nil && child.views[movingTab] == nil,
              "Rendering the same tab from another window creates no second WebKit view")
        root.update(movingTab) { $0.url = "about:blank" }
        child.openInSplit(movingTab)
        check(child.splitID == movingTab && child.selectedID == independentTab && child.primaryPageView(for: movingTab) === source &&
                root.views[movingTab] == nil && child.documentIdentity(for: source) === identity,
              "Open in Split View brings over the exact live tab and keeps the existing primary pane")
        child.splitID = nil
        _ = group.claimPresentation(tabID: movingTab, in: root)
        WebPane(webView: source, store: root).mount(in: originalHost)
        child.select(movingTab)
        check(child.selectedID == movingTab && group.presentation(tabID: movingTab, in: child) == .owned,
              "The ordinary tab selection action claims the page")
        check(root.views[movingTab] == nil && child.views[movingTab] === source &&
              source.navigationDelegate === child && source.uiDelegate === child,
              "The original view and delegates move to the destination with one live instance")
        check(child.documentIdentity(for: source) === identity,
              "The destination retains the exact document identity across handoff")
        WebPane(webView: source, store: child).mount(in: destinationHost)
        obsoletePane.mount(in: originalHost)
        check(source.superview === destinationHost && originalHost.subviews.isEmpty,
              "An obsolete AppKit update cannot remount a transferred view in its old host")
        let preserved = try await hasFixture(source, token: "moving")
        check(preserved, "The live page retains its unsaved form, JavaScript token and scroll position")
        check(group.presentation(tabID: movingTab, in: root) == .elsewhere(windowID: childID) && root.views[movingTab] == nil,
              "An obsolete render in the original window cannot take the page back")
        let individual = try await hasFixture(independent, token: "independent")
        check(child.views[independentTab] === independent && child.documentIdentity(for: independent) === independentIdentity && individual,
              "Claiming another tab leaves the independent live page intact")
        check(!group.claimPresentation(tabID: movingTab, in: privateWindow) && privateWindow.views.isEmpty,
              "A private window cannot claim a normal browsing document")

        let inactive = root.newTab(url: URL(string: "https://archive.example.invalid/"))
        _ = root.newTab()
        root.preferences.archiveAfterDays = 1
        root.update(inactive) { $0.lastAccessed = .distantPast }
        child.update(movingTab) {
            if $0.url.isEmpty { $0.url = "about:blank" }
            $0.lastAccessed = .distantPast
        }
        root.archiveOldTabs()
        check(child.views[movingTab] === source && child.tab(movingTab) != nil,
              "Auto-archive protects the tab selected in the other window")
        check(root.tab(inactive) == nil && root.library.archive.contains { $0.id == inactive },
              "The same archive pass removes an equally old unselected tab")

        root.close(independentTab)
        check(child.views[independentTab] == nil && root.tab(independentTab) == nil && child.tab(independentTab) == nil,
              "Closing a tab from a different window also discards its live view")

        check(group.claimPresentation(tabID: movingTab, in: root), "An explicit claim can move the tab back")
        let returned = try await hasFixture(source, token: "moving")
        check(root.views[movingTab] === source && root.documentIdentity(for: source) === identity && returned,
              "Returning the page preserves the same document and in-memory state")

        let leftTab = BrowserCore.Tab(title: "Writer choice", url: "about:blank#writer")
        let rightTab = BrowserCore.Tab(title: "Secondary choice", url: "about:blank#secondary")
        let separateSpace = Space(name: "Separate selection", tabs: [leftTab, rightTab])
        let primarySpace = root.space.id
        root.session.spaces.append(separateSpace)
        root.selectSpace(separateSpace.id); root.select(leftTab.id); root.selectSpace(primarySpace)
        child.selectSpace(separateSpace.id); child.select(rightTab.id); child.selectSpace(primarySpace)
        _ = group.focusPrimary(child)
        let selectionProbe = try root.openQuickPage(url: URL(string: "http://127.0.0.1:9/quick-selection"))
        _ = try root.promoteQuickPage(selectionProbe, to: primarySpace)
        check(child.selectedID == selectionProbe && child.session.spaces.first { $0.id == separateSpace.id }?.selected == rightTab.id &&
                root.session.spaces.first { $0.id == separateSpace.id }?.selected == leftTab.id,
              "A Quick Browse expansion preserves each window's selection in an unrelated Space")
        child.close(selectionProbe)
        owner.release(first.lease)
        let survived = try await hasFixture(source, token: "moving")
        check(child.views[movingTab] === source && child.documentIdentity(for: source) === identity && survived,
              "Closing its presenter hands the still-open tab to the surviving window without reloading")

        let compact = try root.openQuickPage(url: URL(string: "https://handoff.example.invalid/"),
                                             configuration: WKWebViewConfiguration())
        let compactWeb = root.views[compact]!
        try await loadFixture(compactWeb, token: "compact")
        root.openPeek(URL(string: "about:blank")!, from: compactWeb)
        let compactPeek = root.quickPeekView(compact)!
        try await loadFixture(compactPeek, token: "compact-preview")
        let compactIdentity = root.documentIdentity(for: compactWeb)
        let peekIdentity = root.documentIdentity(for: compactPeek)
        _ = try root.promoteQuickPage(compact, to: child.space.id)
        let promoted = child.primaryPageView(for: compact)
        let draftSurvived = try await hasFixture(compactWeb, token: "compact")
        check(promoted === compactWeb && root.views[compact] == nil && child.selectedID == compact &&
            child.documentIdentity(for: compactWeb) === compactIdentity && draftSurvived,
              "Expanding Quick Browse into the surviving normal window moves the original page and selects it")
        let previewSurvived = try await hasFixture(compactPeek, token: "compact-preview")
        check(child.primaryPeekView === compactPeek && root.primaryPeekView == nil &&
            compactPeek.navigationDelegate === child && child.documentIdentity(for: compactPeek) === peekIdentity && previewSurvived,
              "Expanding Quick Browse moves its exact Peek and retains its separate draft")

        let secondaryPeekURL = URL(string: "http://127.0.0.1:9/secondary-peek-compact")!
        child.openPeek(secondaryPeekURL, from: compactWeb)
        guard let secondaryPeek = child.primaryPeekView else { throw BrowserWindowHandoffTestError.missingWindow }
        try await loadFixture(secondaryPeek, token: "source-window-preview", baseURL: secondaryPeekURL)
        let secondaryDocument = child.documentIdentity(for: secondaryPeek)
        try child.saveLinkRule(LinkRule(pattern: "/secondary-peek-compact", destination: .quickBrowse))
        let routedCompact = try child.promotePeek(in: .primary)
        let secondaryDraft = try await hasFixture(secondaryPeek, token: "source-window-preview")
        check(root.quickPage(routedCompact) != nil && root.views[routedCompact] === secondaryPeek && child.views[routedCompact] == nil &&
                root.documentIdentity(for: secondaryPeek) === secondaryDocument && secondaryDraft,
              "A secondary window's Peek becomes the actual Quick Browse document with its draft intact")

        let parent = try root.openQuickPage(url: URL(string: "http://127.0.0.1:9/quick-peek-parent"))
        let parentWeb = root.view(for: parent)
        let compactPromotionURL = URL(string: "http://127.0.0.1:9/quick-peek-expansion")!
        root.openPeek(compactPromotionURL, from: parentWeb)
        guard let routedPeek = root.quickPeekView(parent) else { throw BrowserWindowHandoffTestError.missingWindow }
        try await loadFixture(routedPeek, token: "compact-to-primary", baseURL: compactPromotionURL)
        let routedDocument = root.documentIdentity(for: routedPeek)
        let otherPreviewURL = URL(string: "http://127.0.0.1:9/keep-secondary-preview")!
        child.openPeek(otherPreviewURL, from: compactWeb)
        guard let unrelatedPeek = child.primaryPeekView else { throw BrowserWindowHandoffTestError.missingWindow }
        try await loadFixture(unrelatedPeek, token: "separate-preview", baseURL: otherPreviewURL)
        let routedMain = try root.promotePeek(in: .quick(parent), to: child.space.id)
        let mainDraft = try await hasFixture(routedPeek, token: "compact-to-primary")
        check(child.selectedID == routedMain && child.views[routedMain] === routedPeek && root.views[routedMain] == nil &&
                child.documentIdentity(for: routedPeek) === routedDocument && mainDraft,
              "A Quick Browse Peek opens as the original document in the surviving normal window")
        let otherDraft = try await hasFixture(unrelatedPeek, token: "separate-preview")
        check(child.primaryPeekView == nil && child.views.values.contains { $0 === unrelatedPeek } && otherDraft,
              "Expanding a Quick Browse Peek also preserves the destination window's existing preview as a tab")

        let operations = try await checkProfileOperations(owned: owned)
        for operation in operations { check(operation.0, operation.1) }
        if !(await owned.cleanup()) { failed += 1 }
        print("Window handoff checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

    @MainActor
    private static func checkProfileOperations(owned: OwnedWebsiteStores) async throws -> [(Bool, String)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-window-profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let root = BrowserStore(dataRoot: directory, keyProvider: { _ in key })
        let owner = BrowserWindowOwner(store: root)
        let first = try owner.acquirePrimaryStore()
        defer { owner.release(first.lease) }
        let defaultTab = root.newTab()
        let profile = try root.createProfile(name: "Window Handoff Fixture")
        try owned.register(profile)
        let targetSpace = root.space.id
        let originalTab = root.newTab()
        _ = root.view(for: originalTab)
        let other = try owner.acquirePrimaryStore(copying: root)
        defer { owner.release(other.lease) }
        let child = other.store
        let otherTab = child.newTab()
        _ = child.view(for: otherTab)
        let quick = try child.openQuickPage(url: URL(string: "https://profile.example.invalid/"))
        var clearReachedWebKit = false
        do {
            try await child.clearProfileData(profile) { dataStore in
                clearReachedWebKit = dataStore.identifier == profile && root.profileUnavailable(profile) &&
                    root.views[originalTab] == nil && child.views[otherTab] == nil && root.quickPage(quick) == nil
                owner.release(other.lease)
            }
        } catch ProfileError.locked {
            return [(false, "A secondary window can clear its profile through the writer")]
        }
        let clearPersisted = !root.profileUnavailable(profile) && root.tab(defaultTab) != nil &&
            root.tab(originalTab) == nil && root.tab(otherTab) == nil && child.isShuttingDown
        try root.deleteSpace(targetSpace)
        let deletion = try owner.acquirePrimaryStore(copying: root)
        defer { owner.release(deletion.lease) }
        var deleted: UUID?
        try await deletion.store.deleteProfile(profile) { deleted = $0 }
        return [
            (clearReachedWebKit, "A secondary window can clear its profile through the writer"),
            (clearPersisted, "Closing the initiating window does not interrupt the profile clear"),
            (deleted == profile && !root.profiles.contains { $0.id == profile } && root.tab(defaultTab) != nil,
             "Deletion requested from another window preserves other profiles and tabs"),
        ]
    }

    @MainActor
    private static func loadFixture(_ web: WKWebView, token: String, baseURL: URL? = nil) async throws {
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        web.loadHTMLString("<input id='draft'><main style='height:5000px'></main>", baseURL: baseURL)
        for _ in 0..<500 {
            let ready = try? await web.evaluateJavaScript("document.getElementById('draft') !== null")
            if ready as? Bool == true {
                _ = try await web.evaluateJavaScript("window.handoffToken = '\(token)'; document.getElementById('draft').value = '\(token)'; window.scrollTo(0, 900); true")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BrowserWindowHandoffTestError.pageDidNotLoad
    }

    @MainActor
    private static func hasFixture(_ web: WKWebView, token: String) async throws -> Bool {
        try await web.evaluateJavaScript("window.handoffToken === '\(token)' && document.getElementById('draft')?.value === '\(token)' && Math.round(window.scrollY) === 900") as? Bool == true
    }
}
