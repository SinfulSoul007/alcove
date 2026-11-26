import AppKit
import WebKit
import CryptoKit
import BrowserCore

/// Observe this fixture's public delegate boundary while retaining the real
/// production alert implementation. No synthetic frame or replacement dialog.
@MainActor private final class OwnedFullscreenScriptProbe: NSObject, WKUIDelegate {
    let store: BrowserStore
    let sample: (String) -> Void
    let nativeExitControl: Bool
    var confirmationResults: [Bool] = []
    init(store: BrowserStore, nativeExitControl: Bool = false, sample: @escaping (String) -> Void) {
        self.store = store; self.sample = sample; self.nativeExitControl = nativeExitControl
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        sample("delegate-entry")
        if nativeExitControl {
            webView.closeAllMediaPresentations {
                self.sample("native-control-completion")
                self.forwardAlert(webView, message: message, frame: frame, completionHandler: completionHandler)
            }
            sample("native-control-return")
            return
        }
        forwardAlert(webView, message: message, frame: frame, completionHandler: completionHandler)
    }
    private func forwardAlert(_ webView: WKWebView, message: String, frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        store.webView(webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: frame) {
            self.sample("delegate-completion"); completionHandler()
        }
        sample("delegate-return")
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        sample("delegate-entry")
        store.webView(webView, runJavaScriptConfirmPanelWithMessage: message, initiatedByFrame: frame) { result in
            self.confirmationResults.append(result)
            self.sample("delegate-completion"); completionHandler(result)
        }
        sample("delegate-return")
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        sample("delegate-entry")
        store.webView(webView, runJavaScriptTextInputPanelWithPrompt: prompt, defaultText: defaultText, initiatedByFrame: frame) { result in
            self.sample("delegate-completion"); completionHandler(result)
        }
        sample("delegate-return")
    }
}

extension WebsiteFullscreenChecks {
    @MainActor static func effect(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        do { try await wait("captured native command effect") { condition() }; return true }
        catch { return false }
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseCommand(base: URL, kind: String, owned: OwnedWebsiteStores,
                                controllers: OwnedExtensionControllers, isPrivate: Bool = false, isQuick: Bool = false) async throws {
        if ["layout-production", "layout-normal-production", "layout-no-motion-production", "layout-collapsed-production", "layout-single-tab-production", "layout-minimum-control", "layout-fixed-control", "layout-preconfigured-control", "layout-content-minimum-control", "layout-web-content-control", "layout-chrome-reader-control", "layout-sidebar-row-control", "layout-sidebar-scroll-control", "layout-sidebar-saved-control", "layout-chrome-feedback-control", "layout-native-menus-control", "layout-address-controls-control", "layout-tracking-control", "layout-store-sheet-control", "layout-full-sidebar-control", "layout-isolated-defaults-control", "layout-progress-control", "layout-content-frame-control", "layout-resize-grip-control", "layout-ignored-safe-area-control", "layout-conditional-progress-control", "layout-ready-production", "layout-full-sidebar-narrow-control", "layout-wide-defaults-control", "layout-normal-motion-production", "layout-normal-no-motion-production", "layout-normal-ready-focus-production", "layout-normal-loading-focus-production", "layout-private-ready-focus-production", "layout-private-loading-focus-production", "layout-normal-background-focus-production"].contains(kind) {
            guard !isPrivate, !isQuick else { throw Failure.fixture("owned layout diagnostic context") }
            try await exerciseNativeLayout(base: base, kind: kind, owned: owned, controllers: controllers)
            print("FULLSCREEN_COMMAND_CASE_COMPLETED", kind, "private", false, "quick", false)
            return
        }
        if kind == "profile-delete" || kind == "peek-profile-delete" {
            guard !isPrivate, isQuick else { throw Failure.fixture("normal Quick profile deletion") }
            print("FULLSCREEN_COMMAND_CONTEXT", kind, "private", false, "quick", true)
            try await exerciseProfileDeletion(base: base, owned: owned, controllers: controllers, peek: kind == "peek-profile-delete")
            print("FULLSCREEN_COMMAND_CASE_COMPLETED", kind, "private", false, "quick", true)
            return
        }
        let root = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_QUIT_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-command-" + UUID().uuidString)
        let isProfileClear = kind == "profile-clear" || kind == "peek-profile-clear"
        let extensionPeek = ["peek-extension-focus", "peek-extension-focus-request"].contains(kind)
        var protection: WebsiteProtectionService?
        if kind == "warning" {
            // A one-domain owned catalog; no target navigation or network request.
            let rows = Data("listed.alcove.example\n".utf8)
            let instant = ISO8601DateFormatter().string(from: Date())
            let metadata = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "provider": "PhishDestroy",
                "sourceRevision": String(repeating: "1", count: 40), "sourceUpdatedAt": instant, "retrievedAt": instant,
                "sha256": SHA256.hash(data: rows).map { String(format: "%02x", $0) }.joined(),
                "licenseSHA256": String(repeating: "0", count: 64), "domainCount": 1])
            let catalog = try WebsiteThreatCatalog(domains: rows, metadata: metadata)
            let service = WebsiteProtectionService(loader: { catalog }); _ = await service.load(); protection = service
        }
        var keyReads = 0
        let writer = BrowserStore(isPrivate: isPrivate, dataRoot: root, keyProvider: { _ in
            keyReads += 1; return SymmetricKey(data: Data(repeating: 87, count: 32))
        }, websiteProtection: protection)
        writer.finishOnboarding(); writer.preferences.automaticUpdateChecks = false
        if kind == "archive-static" || kind == "suspend-static" {
            writer.preferences.archiveAfterDays = 0; writer.preferences.suspendTabs = false
        }
        if kind == "expire-static" || kind == "peek-expire-static" { writer.preferences.quickBrowseArchiveHours = 6 }
        let profile: UUID
        if isPrivate { profile = BrowserProfile.defaultID }
        else {
            profile = try writer.createProfile(name: "Owned fullscreen commands")
            try owned.register(profile)
            for item in writer.profiles where item.id == profile {
                if let controller = item.extensionControllerID { try controllers.register(controller) }
            }
        }
        let sourceSpace = writer.space.id
        var fullscreenExtensionID: UUID?
        if extensionPeek || ["extension-focus", "extension-focus-request", "extension-close", "extension-close-disable", "extension-close-revoke"].contains(kind) {
            guard !isPrivate else { throw Failure.fixture("normal owned extension focus baseline") }
            let source = root.appendingPathComponent("focus-extension")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"Owned fullscreen focus","version":"1","permissions":["tabs"],"host_permissions":["http://127.0.0.1/*"],"options_page":"options.html"}"#.utf8)
                .write(to: source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><title>Owned extension focus</title><main id='owned-focus'>Owned focus</main>".utf8)
                .write(to: source.appendingPathComponent("options.html"))
            let package = try ExtensionPackage.prepare(at: source, stagingRoot: root.appendingPathComponent("extension-staging"))
            let approval = try writer.extensionInstallApproval(for: package, profileID: profile,
                permissions: ["tabs"], hostPatterns: ["http://127.0.0.1/*"], enable: true)
            fullscreenExtensionID = try await writer.installExtension(package, approval: approval)
        }
        var clearingSurvivorSpace: UUID?, clearingSurvivorProfile: UUID?
        if isProfileClear && !isPrivate {
            let otherProfile = try writer.createProfile(name: "Owned clearing survivor")
            try owned.register(otherProfile)
            if let controller = writer.profiles.first(where: { $0.id == otherProfile })?.extensionControllerID {
                try controllers.register(controller)
            }
            clearingSurvivorProfile = otherProfile; clearingSurvivorSpace = writer.space.id
            writer.selectSpace(sourceSpace)
        }
        var nextSpace: UUID?
        if kind == "next-space" {
            nextSpace = try writer.createSpace(name: "Owned next fullscreen Space", profileID: profile)
            _ = writer.newTab(url: base.appendingPathComponent("page"))
            writer.selectSpace(sourceSpace)
        }
        let sourceURL = kind == "peek-expire-static"
            ? URL(string: "page-no-media#quick-expiry-parent", relativeTo: base)!.absoluteURL
            : base.appendingPathComponent(kind == "reader" ? "article" : (kind == "no-media" ? "page-no-media" : "page"))
        let primaryID = writer.newTab(url: sourceURL)
        if kind == "next-tab" || kind == "split" {
            _ = writer.newTab(url: sourceURL, activate: false)
            // This API appends to the session's selection even without
            // activating a pane. Explicitly stage the intended source first.
            writer.select(primaryID)
        }
        var outputSource: WKWebView?, outputWindow: NSWindow?, outputFormat: PageOutputFormat?
        var outputCalls = 0, outputErrors: [String] = []
        var environment = PageOutputEnvironment.live
        // Actual page capture remains native. Only the user-owned destination
        // and print-panel boundaries are witnessed/cancelled by this fixture.
        let nativeCapture = environment.capture
        environment.capture = { source, format, done in
            outputSource = source; nativeCapture(source, format, done)
        }
        environment.choose = { window, _, format, done in
            outputWindow = window; outputFormat = format; outputCalls += 1
            done(nil); return {}
        }
        environment.print = { source, window, done in
            outputSource = source; outputWindow = window; outputCalls += 1
            _ = PageOutputNative.printOperation(for: source)
            done(false); return {}
        }
        environment.reportError = { message, _ in outputErrors.append(message) }
        environment.reportOrphanedError = { outputErrors.append($0) }
        let app = AppDelegate(pageOutput: PageOutputCoordinator(environment: environment)), owner = app.makeOwner(writer)
        var clearingPrivateOwner: BrowserWindowOwner?
        var clearingPrivateKeyReads = 0
        app.normalOwner = owner // Even a broken fallback can only open this owned profile.
        defer {
            clearingPrivateOwner?.shutdown()
            owner.shutdown(); writer.shutdown()
            if isPrivate {
                check(keyReads == 0 && !FileManager.default.fileExists(atPath: writer.sessionURL.path),
                      "Private fullscreen \(kind) never reads a metadata key or writes a saved session")
                if let other = clearingPrivateOwner {
                    check(clearingPrivateKeyReads == 0 && !FileManager.default.fileExists(atPath: other.store.sessionURL.path),
                          "The surviving private session never reads a metadata key or writes a saved session")
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        app.openPrimary(owner)
        guard let primaryWindow = app.primaryOwners.first(where: { $0.value === owner })?.key,
              let store = app.windows[primaryWindow], store.activeProfileID == profile else {
            throw Failure.fixture("real owned browser window")
        }
        var window = primaryWindow, id = primaryID
        var quick: QuickBrowseWindowController?
        if isQuick {
            id = try store.openQuickPage(url: sourceURL, profileID: profile, intendedSpaceID: store.space.id)
            app.syncQuickWindows(owner)
            guard let controller = app.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: id)],
                  let compactWindow = controller.window else { throw Failure.fixture("registered Quick command window") }
            quick = controller; window = compactWindow; controller.surface()
        }
        window.title = "Alcove owned fullscreen \(isPrivate ? "private" : "regular") \(kind)"
        print("FULLSCREEN_COMMAND_CONTEXT", kind, "private", isPrivate, "quick", isQuick)
        let underlying = store.view(for: id)
        var web = underlying
        var fullscreenExtensionOptions: WKWebView?
        var extensionSourceURL = sourceURL
        var extensionPeekParent: (web: WKWebView, document: NSUUID)?
        var targetID = id
        var handoff: (store: BrowserStore, window: NSWindow, survivorID: UUID, survivor: WKWebView, document: NSUUID)?
        var clearingSurvivor: (store: BrowserStore, window: NSWindow, id: UUID, web: WKWebView, profile: UUID, document: NSUUID)?
        if kind == "peek-escape" || kind == "peek-expire-static" || kind == "peek-close-primary-window-direct" || kind == "peek-quit" || kind.hasPrefix("peek-parent-") || kind.hasPrefix("peek-") && kind.hasSuffix("script-sheet") {
            store.openPeek(base.appendingPathComponent("page"), from: underlying)
            guard let peek = isQuick ? store.quickPeekView(id) : store.primaryPeekView else { throw Failure.fixture("command Peek") }
            web = peek
        } else {
            if (kind == "close" || kind.hasPrefix("close-direct") || kind == "close-script-sheet" || kind == "navigate-script-sheet") && !isQuick {
                targetID = store.newTab(url: base.appendingPathComponent("page"))
                web = store.view(for: targetID)
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var caught: Error?
        do {
            if isProfileClear {
                let other: BrowserStore, otherWindow: NSWindow, otherProfile: UUID
                if isPrivate {
                    other = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("private-clearing-survivor"), keyProvider: { _ in
                        clearingPrivateKeyReads += 1; return SymmetricKey(data: Data(repeating: 91, count: 32))
                    })
                    other.finishOnboarding(); other.preferences.automaticUpdateChecks = false
                    let otherOwner = app.makeOwner(other); clearingPrivateOwner = otherOwner
                    app.openPrimary(otherOwner)
                    guard let opened = app.primaryOwners.first(where: { $0.value === otherOwner })?.key else {
                        throw Failure.fixture("independent private clearing survivor window")
                    }
                    otherWindow = opened; otherProfile = BrowserProfile.defaultID
                } else {
                    guard let otherSpace = clearingSurvivorSpace, let otherID = clearingSurvivorProfile else {
                        throw Failure.fixture("owned clearing survivor profile")
                    }
                    app.newBrowserWindow()
                    guard let opened = app.windows.keys.first(where: { $0 !== primaryWindow && app.primaryOwners[$0] === owner }),
                          let openedStore = app.windows[opened] else { throw Failure.fixture("owned clearing survivor window") }
                    other = openedStore; otherWindow = opened; otherProfile = otherID
                    other.selectSpace(otherSpace)
                }
                let survivorID = other.newTab(url: base.appendingPathComponent("page-no-media"))
                let survivor = other.view(for: survivorID)
                try await wait("other-profile clearing survivor ready") {
                    (try? await survivor.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await survivor.evaluateJavaScript("document.getElementById('draft').value='surviving profile clear draft';document.cookie='owned_fullscreen_clear=survivor; path=/; SameSite=Lax';localStorage.setItem('owned_fullscreen_clear','survivor');true")
                clearingSurvivor = (other, otherWindow, survivorID, survivor, otherProfile, other.documentIdentity(for: survivor))
                if !isQuick { store.select(id) }
                if kind == "peek-profile-clear" {
                    store.openPeek(base.appendingPathComponent("page"), from: underlying)
                    guard let peek = isQuick ? store.quickPeekView(id) : store.primaryPeekView else {
                        throw Failure.fixture("clearing source Peek")
                    }
                    web = peek
                }
                window.makeKeyAndOrderFront(nil)
            }
            if kind.hasPrefix("handoff") {
                app.newBrowserWindow()
                guard let destinationWindow = app.windows.keys.first(where: { $0 !== window && app.primaryOwners[$0] === owner }),
                      let destination = app.windows[destinationWindow], destination.windowGroup === store.windowGroup else {
                    throw Failure.fixture("registered same-owner handoff destination")
                }
                let survivorID = destination.newTab(url: base.appendingPathComponent("page"))
                let survivor = destination.view(for: survivorID)
                try await wait("handoff survivor document") {
                    (try? await survivor.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await survivor.evaluateJavaScript("document.getElementById('draft').value='surviving handoff draft';true")
                let survivorDocument = destination.documentIdentity(for: survivor)
                destination.select(id)
                store.select(id)
                // The destination now shows the real Bring Tab Here placeholder;
                // its independent live page remains available in the background.
                handoff = (destination, destinationWindow, survivorID, survivor, survivorDocument)
                window.makeKeyAndOrderFront(nil)
            }
            if let installed = fullscreenExtensionID {
                let optionsID = try await store.openExtensionOptions(installed, profileID: profile)
                guard let options = store.views[optionsID] else { throw Failure.fixture("real extension options view") }
                try await wait("owned extension options document") {
                    (try? await options.evaluateJavaScript("document.getElementById('owned-focus')!==null")) as? Bool == true
                }
                fullscreenExtensionOptions = options
                store.select(primaryID)
                window.makeKeyAndOrderFront(nil)
            }
            if extensionPeek {
                try await wait("extension Peek parent document") {
                    (try? await underlying.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await underlying.evaluateJavaScript("document.getElementById('draft').value='extension Peek parent';window.ownedExtensionPeekParent=53;true")
                extensionPeekParent = (underlying, store.documentIdentity(for: underlying))
                extensionSourceURL = URL(string: "page#owned-extension-peek", relativeTo: base)!.absoluteURL
                store.openPeek(extensionSourceURL, from: underlying)
                guard let peek = isQuick ? store.quickPeekView(id) : store.primaryPeekView else {
                    throw Failure.fixture("real extension fullscreen Peek")
                }
                web = peek
            }
            try await wait("real browser website host") { web.window === window && web.superview is EdgeToEdgeWebHost }
            guard let commandHost = web.superview as? EdgeToEdgeWebHost else { throw Failure.fixture("original command host") }
            try await wait("command source decoded") {
                guard !web.isLoading else { return false }
                if kind == "no-media" {
                    return (try? await web.evaluateJavaScript("document.getElementById('enter')!==null&&document.querySelectorAll('video,audio').length===0")) as? Bool == true
                }
                return (try? await web.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true
            }
            do {
                try await wait("owned command window and document visible") {
                    guard NSApp.isActive, window.isVisible, window.isKeyWindow, window.isOnActiveSpace,
                          web.window === window, !web.isHiddenOrHasHiddenAncestor else { return false }
                    return (try? await web.evaluateJavaScript("document.visibilityState==='visible'")) as? Bool == true
                }
            } catch {
                print("FULLSCREEN_COMMAND_VISIBILITY_FAILURE", kind, "key", window.isKeyWindow,
                      "active", NSApp.isActive, "visible", window.isVisible, "activeSpace", window.isOnActiveSpace,
                      "document", (try? await web.evaluateJavaScript("document.visibilityState")) ?? "unavailable")
                throw error
            }
            _ = try await web.evaluateJavaScript("document.getElementById('draft').value='captured command draft';window.ownedCommandToken=41;true")
            if isProfileClear {
                _ = try await web.evaluateJavaScript("document.cookie='owned_fullscreen_clear=target; path=/; SameSite=Lax';localStorage.setItem('owned_fullscreen_clear','target');true")
            }
            let document = store.documentIdentity(for: web)
            if let options = fullscreenExtensionOptions {
                _ = try await options.evaluateJavaScript("window.ownedFocusEvents=[];browser.windows.onFocusChanged.addListener(id=>window.ownedFocusEvents.push(id));true")
                try await wait("real extension focus API before fullscreen") {
                    (try? await options.callAsyncJavaScript("""
                        const windows = await browser.windows.getAll({populate:true});
                        const targets = windows.filter(w => w.type === type && w.tabs?.some(t => t.url === url));
                        return targets.length === 1 && targets[0].focused === true &&
                            targets[0].tabs.some(t => t.active && t.url === url);
                        """, arguments: ["type": isQuick ? "popup" : "normal", "url": extensionSourceURL.absoluteString],
                        in: nil, contentWorld: .page)) as? Bool == true
                }
                print("FULLSCREEN_EXTENSION_FOCUS_CONTROL", "ready", true, "quick", isQuick)
            }
            if kind == "close-primary-entering" || kind == "close-primary-exiting" {
                try await exerciseTransitionWindowClose(app: app, owner: owner, store: store, web: web,
                                                        window: window, entering: kind == "close-primary-entering")
            } else {
            if kind == "no-media" { try await enterWithOwnedClick(web, window: window) }
            else { try await enter(web, target: "element") }
            guard let presentation = web.window, presentation !== window else { throw Failure.fixture("command presentation") }
            try await wait("command native window key") { presentation.isKeyWindow }
            let routed = app.browserStore(in: presentation) === store && app.activeStore === store && app.activeWebView === web
            check(routed, "\(kind): native fullscreen command routing retains the actual page and store")
            check(app.activeBrowserWindow === window, "\(kind): native fullscreen resolves to its captured logical browser window")
            check(app.outputTarget(in: presentation)?.web === web,
                  "\(kind): page-output selection retains the fullscreen source")
            switch kind {
            case "extension-focus", "peek-extension-focus":
                guard let options = fullscreenExtensionOptions else { throw Failure.fixture("owned installed focus extension") }
                try await exerciseFullscreenExtensionFocus(options: options, store: store, web: web, window: window,
                    presentation: presentation, sourceURL: extensionSourceURL, windowType: isQuick ? "popup" : "normal", document: document)
            case "extension-focus-request", "peek-extension-focus-request", "extension-close", "extension-close-disable", "extension-close-revoke":
                guard let options = fullscreenExtensionOptions, !kind.hasPrefix("extension-close") || isQuick else {
                    throw Failure.fixture("owned extension window action")
                }
                let cancellation = ["extension-close-disable", "extension-close-revoke"].contains(kind)
                    ? fullscreenExtensionID.map { (id: $0, profile: profile, revoke: kind == "extension-close-revoke") } : nil
                try await exerciseFullscreenExtensionWindowAction(options: options, app: app, owner: owner,
                    store: store, web: web, window: window, presentation: presentation, sourceURL: extensionSourceURL,
                    sourceID: id, primaryID: primaryID, windowType: isQuick ? "popup" : "normal",
                    document: document, removing: kind.hasPrefix("extension-close"), cancellation: cancellation)
            case "quit", "peek-quit":
                try await exerciseRealQuit(app: app, owner: owner, store: store, web: web, presentation: presentation) {
                    if isPrivate { return keyReads == 0 && !FileManager.default.fileExists(atPath: writer.sessionURL.path) }
                    guard let saved = try? MetadataStore(url: writer.sessionURL,
                        key: SymmetricKey(data: Data(repeating: 87, count: 32))).load(BrowserDocument.self),
                          saved.profiles?.contains(where: { $0.id == profile }) == true else { return false }
                    return isQuick ? saved.library(for: profile).quickPages?.contains(where: { $0.id == id }) == true
                        : saved.session.spaces.contains { $0.tabs.contains { $0.id == primaryID } }
                }
            case "profile-clear", "peek-profile-clear":
                guard let survivor = clearingSurvivor else { throw Failure.fixture("independent clearing survivor") }
                let targetStore = web.configuration.websiteDataStore
                let otherStore = survivor.web.configuration.websiteDataStore
                let ownedTarget = isPrivate ? (!targetStore.isPersistent && targetStore === store.privateDataStore) :
                    (profile != BrowserProfile.defaultID && targetStore.identifier == profile)
                guard ownedTarget else {
                    throw Failure.fixture("owned website store for actual profile erasure")
                }
                let targetState = (try? await web.evaluateJavaScript("document.cookie==='owned_fullscreen_clear=target'&&localStorage.getItem('owned_fullscreen_clear')==='target'")) as? Bool
                let otherState = (try? await survivor.web.evaluateJavaScript("document.cookie==='owned_fullscreen_clear=survivor'&&localStorage.getItem('owned_fullscreen_clear')==='survivor'")) as? Bool
                let isolated = isPrivate ? (!otherStore.isPersistent && otherStore !== targetStore) :
                    (survivor.profile != profile && otherStore.identifier == survivor.profile)
                check(targetState == true && otherState == true && isolated,
                      "Profile clearing starts with isolated real cookies and local storage in two owned website stores")
                var removalCalls = 0, safeBeforeRemoval = false, removed = false
                try await store.clearProfileData(profile, removeData: { dataStore in
                    guard dataStore === targetStore,
                          isPrivate ? !dataStore.isPersistent : (dataStore.isPersistent && dataStore.identifier == profile) else {
                        throw Failure.fixture("refusing erasure outside the exact owned website store")
                    }
                    removalCalls += 1
                    safeBeforeRemoval = !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false &&
                        store.pageStores.allSatisfy { !$0.viewProfileIDs.values.contains(profile) &&
                            !$0.peekPages.values.contains(where: { $0.profileID == profile }) }
                    check(safeBeforeRemoval,
                          "Profile clearing completes physical fullscreen retirement before actual website-data erasure")
                    await withCheckedContinuation { reply in
                        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { reply.resume() }
                    }
                    removed = true
                })
                if let controller = store.profiles.first(where: { $0.id == profile })?.extensionControllerID {
                    try controllers.register(controller)
                }
                let retired = await effect {
                    !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false && store.views[id] == nil &&
                        store.pageStores.allSatisfy { !$0.peekPages.values.contains(where: { $0.web === web }) }
                }
                check(removalCalls == 1 && removed && safeBeforeRemoval && retired && !store.profileUnavailable(profile) &&
                      primaryWindow.isVisible && (isQuick ? !window.isVisible && store.quickPage(id) == nil : window.isVisible),
                      "Profile clearing erases once, releases the old native presentation and resumes the cleared profile without recovery")
                guard let clearedSpace = store.session.spaces.first(where: { $0.id == sourceSpace }),
                      clearedSpace.tabs.count == 1, let freshID = clearedSpace.selected,
                      clearedSpace.tabs.first?.url.isEmpty == true else { throw Failure.fixture("cleared profile's blank replacement") }
                let fresh = store.view(for: freshID)
                fresh.load(URLRequest(url: base.appendingPathComponent("page-no-media")))
                try await wait("cleared profile fresh website document") {
                    guard !fresh.isLoading else { return false }
                    return (try? await fresh.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                let emptyData = (try? await fresh.evaluateJavaScript("document.cookie===''&&localStorage.getItem('owned_fullscreen_clear')===null")) as? Bool
                let freshStore = fresh.configuration.websiteDataStore
                check(fresh !== web && store.profileID(for: fresh) == profile &&
                      (isPrivate ? !freshStore.isPersistent && freshStore === targetStore : freshStore.identifier == profile) && emptyData == true,
                      "Reopening the cleared profile actually has no prior cookie or local-storage marker")
                let survivorData = (try? await survivor.web.evaluateJavaScript("document.getElementById('draft').value==='surviving profile clear draft'&&document.cookie==='owned_fullscreen_clear=survivor'&&localStorage.getItem('owned_fullscreen_clear')==='survivor'")) as? Bool
                check(survivor.window.isVisible && survivor.store.views[survivor.id] === survivor.web &&
                      survivor.store.profileID(for: survivor.web) == survivor.profile &&
                      survivor.store.documentIdentity(for: survivor.web) === survivor.document && survivorData == true,
                      "Clearing the fullscreen profile preserves the other profile's exact live document, form, cookie and local storage")
            case "handoff", "handoff-cancel", "handoff-close", "handoff-source-close", "handoff-source-navigate":
                guard let handoff else { throw Failure.fixture("prepared handoff destination") }
                handoff.window.makeKeyAndOrderFront(nil)
                try await wait("handoff requesting window key") { handoff.window.isKeyWindow }
                check(web.fullscreenState != .notInFullscreen &&
                      (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true,
                      "Window handoff begins with the actual source still borrowed by native fullscreen")
                handoff.store.select(id)
                let nativeStillOwns = web.fullscreenState != .notInFullscreen || presentation.isVisible ||
                    (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true
                check(!nativeStillOwns || store.views[id] === web && handoff.store.views[id] == nil,
                      "Pending window selection keeps the source registration until native fullscreen really ends")
                if kind == "handoff-cancel" { handoff.store.select(handoff.survivorID) }
                if kind == "handoff-close" { handoff.window.performClose(nil) }
                if kind == "handoff-source-close" { store.close(id) }
                let replacement = base.appendingPathComponent("article")
                if kind == "handoff-source-navigate" { store.commandOpensNewTab = false; store.navigate(replacement.absoluteString) }
                let destination = kind == "handoff" ? handoff.store : store
                let expectedWindow = kind == "handoff" ? handoff.window : window
                let transferred = await effect {
                    guard web.fullscreenState == .notInFullscreen, !presentation.isVisible,
                          (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false else { return false }
                    if kind == "handoff-source-close" {
                        return store.views[id] == nil && handoff.store.views[id] == nil && store.tab(id) == nil
                    }
                    if kind == "handoff-source-navigate", web.url != replacement || web.isLoading || store.documentIdentity(for: web) === document { return false }
                    return destination.views[id] === web && web.window === expectedWindow &&
                        (kind == "handoff" ? store.views[id] == nil : handoff.store.views[id] == nil)
                }
                check(transferred, kind == "handoff" ?
                      "Same-profile window handoff completes native exit before moving the exact live website" :
                      "A newer destination or source action safely supersedes the pending fullscreen handoff")
                if kind == "handoff-source-navigate" {
                    let fresh = (try? await web.evaluateJavaScript("document.querySelector('article')!==null&&document.getElementById('draft').value==='original'&&window.ownedCommandToken===undefined")) as? Bool
                    check(transferred && destination.profileID(for: web) == profile && fresh == true,
                          "A newer source navigation cancels handoff and commits its fresh document in the original window/profile")
                } else if kind != "handoff-source-close" {
                    let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41")) as? Bool
                    check(transferred && destination.profileID(for: web) == profile &&
                          destination.documentIdentity(for: web) === document && draft == true,
                          "Fullscreen handoff preserves the original profile, document identity and unsaved form without reloading")
                }
                let survivorOwner = store.pageStores.first { $0.views[handoff.survivorID] === handoff.survivor }
                let survivorDraft = (try? await handoff.survivor.evaluateJavaScript("document.getElementById('draft').value==='surviving handoff draft'")) as? Bool
                check(survivorOwner?.profileID(for: handoff.survivor) == profile &&
                      survivorOwner?.documentIdentity(for: handoff.survivor) === handoff.document && survivorDraft == true,
                      "Fullscreen transfer or cancellation preserves the independent destination page's live document and form")
                if kind != "handoff-close" {
                    check(transferred && handoff.window.isKeyWindow,
                          "Finishing or cancelling a fullscreen handoff preserves its requesting window's focus")
                }
            case "archive-static", "suspend-static", "expire-static", "peek-expire-static":
                // Entry uses the existing decoded-media fixture. Remove that
                // media before measuring idle cleanup; this does not qualify
                // fullscreen entry on a fresh no-media document.
                _ = try await web.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(node=>{node.pause();node.remove()});true")
                var playback: WKMediaPlaybackState?
                try await wait("fullscreen fixture has no active media") {
                    let state: WKMediaPlaybackState = await withCheckedContinuation { reply in
                        web.requestMediaPlaybackState { reply.resume(returning: $0) }
                    }
                    playback = state
                    return state == .paused || state == .none
                }
                print("FULLSCREEN_STATIC_PLAYBACK_STATE", playback?.rawValue ?? -1)
                if isQuick {
                    if web !== underlying {
                        try await wait("Quick expiry parent document ready") { !underlying.isLoading }
                        _ = try await underlying.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(node=>{node.pause();node.remove()});true")
                        try await wait("Quick expiry parent has no active media") {
                            let state: WKMediaPlaybackState = await withCheckedContinuation { reply in
                                underlying.requestMediaPlaybackState { reply.resume(returning: $0) }
                            }
                            return state == .paused || state == .none
                        }
                    }
                    let primary = store.view(for: primaryID)
                    try await wait("Quick expiry primary survivor ready") {
                        (try? await primary.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                    }
                    _ = try await primary.evaluateJavaScript("document.getElementById('draft').value='surviving Quick expiry draft';true")
                    let primaryDocument = store.documentIdentity(for: primary)
                    let idleID = try store.openQuickPage(url: base.appendingPathComponent("page-no-media"), profileID: profile, intendedSpaceID: store.space.id)
                    app.syncQuickWindows(owner)
                    guard let idleWindow = app.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: idleID)]?.window else {
                        throw Failure.fixture("registered idle Quick expiry control")
                    }
                    let idle = store.view(for: idleID)
                    try await wait("idle Quick expiry control loaded") { !idle.isLoading }
                    primaryWindow.makeKeyAndOrderFront(nil)
                    let borrowed = (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true
                    let setup = borrowed && !presentation.isKeyWindow && primaryWindow.isKeyWindow && store.focusedQuickPageID == nil
                    check(setup, "Quick expiry starts with an actual borrowed fullscreen source in the background, without playing media")
                    guard setup else { throw Failure.fixture("background Quick source no longer borrowed") }
                    // Own-model clock values make both records genuinely old
                    // without letting incidental native focus notifications
                    // change a timestamp while playback replies are pending.
                    let instant = Date(), activity = Date().addingTimeInterval(3600)
                    let expiry = instant.addingTimeInterval(9 * 3600)
                    store.touchQuickPage(id, now: activity); store.touchQuickPage(idleID, now: activity)
                    check(idleID != id && store.preferences.quickBrowseArchiveHours == 6 &&
                          store.quickPage(id)?.lastActiveAt == activity && store.quickPage(idleID)?.lastActiveAt == activity &&
                          activity < expiry.addingTimeInterval(-6 * 3600),
                          "Quick expiry stages two distinct pages older than the supported six-hour inactivity cutoff")
                    store.archiveInactiveQuickPages(now: expiry)
                    let completed = await effect { store.quickArchiveProbeID == nil && store.quickPage(idleID) == nil && !idleWindow.isVisible }
                    check(completed, "Quick inactivity expiry removes its eligible idle control and closes that real window")
                    let retained = store.quickPage(id) != nil && store.views[id] === underlying &&
                        (web === underlying || store.quickPeekView(id) === web)
                    let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41")) as? Bool
                    check(retained && store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                          "Quick inactivity expiry protects the exact static fullscreen source/profile/document/form even when another window is key")
                    let primaryDraft = (try? await primary.evaluateJavaScript("document.getElementById('draft').value==='surviving Quick expiry draft'")) as? Bool
                    check(store.views[primaryID] === primary && store.documentIdentity(for: primary) === primaryDocument && primaryDraft == true,
                          "Quick inactivity expiry preserves the other primary window's independent live document and form")
                    if retained { quick?.surface(); try await leave(web) }
                    break
                }
                let control = kind == "archive-static" ? store.newTab(url: base.appendingPathComponent("article"), activate: false) : store.newTab(activate: false)
                let otherID = store.newTab(url: base.appendingPathComponent("article"))
                let other = store.view(for: otherID)
                try await wait("other selected document while original remains fullscreen") {
                    guard other.window === window, !other.isLoading else { return false }
                    return (try? await other.evaluateJavaScript("document.querySelector('article')!==null")) as? Bool == true
                }
                let completed: Bool
                if kind == "archive-static" {
                    let old = Date().addingTimeInterval(-3 * 86400)
                    store.update(id) { $0.lastAccessed = old }
                    store.update(control) { $0.lastAccessed = old }
                    check(store.views[control] == nil && web.window === presentation && web.fullscreenState == .inFullscreen,
                          "Archive fixture has an unloaded old control and an actual paused fullscreen source outside the selected tab")
                    store.preferences.archiveAfterDays = 1
                    store.archiveOldTabs()
                    completed = await effect { !store.archivingOldTabs && store.tab(control) == nil }
                    check(completed, "Automatic archive completes and removes its eligible old control")
                } else {
                    var idlePages = [store.view(for: control)]
                    for _ in 0..<5 { idlePages.append(store.view(for: store.newTab(activate: false))) }
                    store.select(otherID)
                    try await wait("owned background suspension documents") { idlePages.allSatisfy { !$0.isLoading } }
                    check(store.views.count > 6 && store.views[control] != nil &&
                          web.window === presentation && web.fullscreenState == .inFullscreen,
                          "Suspension fixture exceeds the live-view budget while its actual idle fullscreen source remains unselected")
                    store.preferences.suspendTabs = true
                    store.scheduleTabSuspension(afterOpening: otherID, retaining: nil)
                    completed = await effect { store.pendingTabSuspensionExclusions == nil && store.views[control] == nil }
                    check(completed && store.tab(control) != nil,
                          "Automatic suspension unloads its eligible idle control while keeping that tab in the sidebar")
                }
                let retained = store.tab(id) != nil && store.views[id] === web &&
                    web.window === presentation && web.fullscreenState == .inFullscreen
                check(completed && retained,
                      "\(kind): automatic cleanup protects a genuinely fullscreen static page without playing media or current tab selection")
                let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41")) as? Bool
                check(retained && store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): automatic cleanup preserves the exact fullscreen view/profile/document and unsaved form")
                if retained {
                    let otherDocument = store.documentIdentity(for: other)
                    _ = try await other.evaluateJavaScript("document.getElementById('draft').value='surviving explicit-clear draft';true")
                    store.update(otherID) { $0.pinned = true }
                    store.clearTodayTabs()
                    let cleared = await effect {
                        store.tab(id) == nil && store.views[id] == nil && !presentation.isVisible &&
                            web.fullscreenState == .notInFullscreen &&
                            (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                    }
                    check(cleared, "Explicit Clear Today exits fullscreen and closes the same static page protected from automatic cleanup")
                    let otherDraft = (try? await other.evaluateJavaScript("document.getElementById('draft').value==='surviving explicit-clear draft'")) as? Bool
                    check(cleared && window.isVisible && store.views[otherID] === other &&
                          store.documentIdentity(for: other) === otherDocument && store.profileID(for: other) == profile && otherDraft == true,
                          "Explicit fullscreen cleanup preserves its pinned survivor's exact profile/document/form")
                }
            case "no-media":
                check(app.handleEscape(in: presentation), "Escape handles an ordinary page's native fullscreen presentation")
                let restored = await effect {
                    web.window === window && !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(restored, "A page without media returns from genuine fullscreen to its original browser window")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41&&document.querySelectorAll('video,audio').length===0") as? Bool
                check(restored && store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "Ordinary fullscreen preserves its exact profile, live document and unsaved form without adding media")
            case "escape", "peek-escape":
                let first = app.handleEscape(in: presentation), second = app.handleEscape(in: presentation)
                check(first && second, "\(kind): repeated Escape is handled while the same fullscreen exit is pending")
                let exited = await effect { web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                check(exited && !presentation.isVisible && web.window === window,
                      "\(kind): Escape exits the actual native presentation and restores its original window")
                if kind == "peek-escape" {
                    check((isQuick ? store.quickPeekView(id) : store.primaryPeekView) === web,
                          "Escape exits fullscreen before closing the underlying Peek")
                } else {
                    check(store.views[id] === web && window.isVisible, "Escape preserves its original tab and browser window")
                }
                let originalDraft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(exited && store.documentIdentity(for: web) === document && originalDraft == true,
                      "\(kind): Escape preserves the exact original draft and document")
            case "location":
                if routed {
                    app.location(); app.location()
                    let opened = await effect { (quick?.state.isEditingAddress ?? store.commandVisible) && web.window === window && window.firstResponder is NSTextView && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                    check(opened && app.windows.count == 1 && app.quickWindows.count == (isQuick ? 1 : 0), "Cmd-L leaves fullscreen and opens the captured address field without creating another window")
                } else {
                    check(false, "Cmd-L requires its captured routing context before address UI can be delivered")
                }
                store.dismissCommand()
                quick?.state.cancelLocation(currentURL: web.url?.absoluteString ?? "")
            case "find":
                app.find()
                let opened = await effect { (quick?.state.findVisible ?? store.findVisible) && web.window === window && window.firstResponder is NSTextView && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                check(opened && store.documentIdentity(for: web) === document, "Cmd-F leaves fullscreen and searches its captured live page")
                store.findVisible = false
                quick?.state.dismissFind()
            case "reader":
                let menu = NSMenuItem(title: "Show Reader", action: #selector(AppDelegate.toggleReader), keyEquivalent: "")
                check(app.validateMenuItem(menu), "Reader remains available for the captured fullscreen article")
                app.toggleReader()
                let opened = await effect {
                    store.readerSession(for: web)?.state == .ready && web.window === window &&
                    (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                let reader = store.readerSession(for: web)
                check(opened && !presentation.isVisible && reader?.window === window && reader?.reader.window === window,
                      "Reader leaves native fullscreen and mounts in the original browser window")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(opened && store.documentIdentity(for: web) === document && draft == true,
                      "Fullscreen Reader preserves the exact original article, document and unsaved form")
                reader?.dismiss(restoringFocus: true)
            case "print", "pdf", "archive":
                let action = kind == "print" ? #selector(AppDelegate.printPage) : kind == "pdf" ? #selector(AppDelegate.exportPDF) : #selector(AppDelegate.savePage)
                let menu = NSMenuItem(title: "Output", action: action, keyEquivalent: "")
                check(app.validateMenuItem(menu), "\(kind): page-output menu remains available during native fullscreen")
                let command: PageOutputCommand = kind == "print" ? .printPage : kind == "pdf" ? .pdf : .webArchive
                app.performPageOutput(command, in: presentation)
                let delivered = await effect { outputCalls == 1 }
                check(delivered && outputSource === web && outputWindow === window && !presentation.isVisible &&
                      web.window === window && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false,
                      "\(kind): native page output reaches its boundary only after restoring the captured browser window")
                check(delivered && outputErrors.isEmpty && (kind == "print" || outputFormat == (kind == "pdf" ? .pdf : .webArchive)) &&
                      store.documentIdentity(for: web) === document && !app.pageOutput.isBusy(in: window),
                      "\(kind): cancelling the captured output boundary preserves the document and releases its job")
            case "customize", "settings", "library":
                if kind == "customize" { app.customize() }
                else if kind == "settings" { app.settings() }
                else { app.showLibrary() }
                let delivered = await effect {
                    let visible = kind == "customize" ? store.appearanceVisible : kind == "settings" ? store.settingsVisible : store.libraryVisible
                    return visible && web.window === window && !presentation.isVisible &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(delivered && app.windows.count == 1 && store.documentIdentity(for: web) === document,
                      "\(kind): browser chrome opens after restoring its existing window and live page")
                store.appearanceVisible = false; store.settingsVisible = false; store.libraryVisible = false
            case "new-tab", "sidebar", "next-tab", "next-space", "split":
                let sidebarWasVisible = store.sidebarVisible
                switch kind {
                case "new-tab": app.newTab()
                case "sidebar": app.sidebar()
                case "next-tab": app.nextTab()
                case "next-space": app.nextSpace()
                default: app.split()
                }
                let delivered = await effect {
                    let changed: Bool
                    switch kind {
                    case "new-tab": changed = store.commandVisible
                    case "sidebar": changed = store.sidebarVisible != sidebarWasVisible
                    case "next-tab": changed = store.selectedID != id && store.currentView?.window === window
                    case "next-space": changed = store.space.id == nextSpace && store.currentView?.window === window
                    default: changed = store.splitLayout?.tabIDs.contains(id) == true && web.window === window
                    }
                    return changed && !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(delivered, "\(kind): browser navigation and layout actions restore native fullscreen before changing the visible browser")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(delivered && store.views[id] === web && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): browser navigation and layout retain the exact source page and unsaved form")
                store.dismissCommand()
            case "file-prompt", "media-prompt":
                var prompt: NSWindow?, presentedIn: NSWindow?
                var denials: [Bool] = []
                var duplicateReply: (() -> Void)?, recoveryReply: (() -> Void)?
                if kind == "file-prompt" {
                    store.requestWebsiteFiles(from: web, present: { parent, reply in
                        let panel = NSOpenPanel(); panel.directoryURL = root
                        panel.canChooseFiles = true; panel.canChooseDirectories = false
                        presentedIn = parent; prompt = panel
                        duplicateReply = { reply([root.appendingPathComponent("never-selected.txt")]) }
                        recoveryReply = { reply(nil) }
                        panel.beginSheetModal(for: parent) { _ in reply(nil) }
                        return { panel.cancel(nil) }
                    }, completion: { denials.append($0 == nil) })
                } else {
                    store.requestWebsiteMedia(from: web, present: { parent, reply in
                        let alert = NSAlert(); alert.messageText = "Owned fullscreen media consent"
                        alert.addButton(withTitle: "Don’t Allow"); alert.addButton(withTitle: "Allow Once")
                        presentedIn = parent; prompt = alert.window
                        duplicateReply = { reply(true) }; recoveryReply = { reply(false) }
                        alert.beginSheetModal(for: parent) { reply($0 == .alertSecondButtonReturn) }
                        return {
                            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
                            alert.window.orderOut(nil)
                        }
                    }, completion: { denials.append($0 == .deny) })
                }
                let shown = await effect { prompt != nil && prompt?.isVisible == true && prompt?.sheetParent === presentedIn }
                print("FULLSCREEN_PROMPT_PRESENTED", kind, "shown", shown, "parentIsOrigin", presentedIn === window,
                      "sourceInOrigin", web.window === window, "nativeVisible", presentation.isVisible,
                      "state", web.fullscreenState.rawValue, "borrowed", (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed ?? false)
                check(shown && presentedIn === window && web.window === window && !presentation.isVisible &&
                      (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false,
                      "\(kind): the actual native sheet presents only after restoring its original browser window")
                app.location()
                print("FULLSCREEN_PROMPT_COMMAND", kind, "commandVisible", store.commandVisible,
                      "keyIsSheet", NSApp.keyWindow === prompt, "originHasSheet", window.attachedSheet != nil)
                check(shown && !store.commandVisible,
                      "\(kind): a native website sheet blocks conflicting address UI")
                let endedNativeSheet: Bool
                if let prompt, let parent = prompt.sheetParent {
                    endedNativeSheet = true
                    parent.endSheet(prompt, returnCode: kind == "file-prompt" ? .cancel : .alertFirstButtonReturn)
                    prompt.orderOut(nil)
                } else {
                    endedNativeSheet = false
                    // Recovery can settle an unavailable native boundary, but
                    // cannot make either visibility or callback assertion pass.
                    recoveryReply?(); prompt?.orderOut(nil)
                }
                let settled = await effect { !denials.isEmpty }
                duplicateReply?()
                check(endedNativeSheet && settled && denials == [true],
                      "\(kind): cancelling the real native sheet denies once and rejects a duplicate reply")
                store.dismissCommand()
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): the native prompt preserves its captured profile, live document and unsaved form")
            case "warning":
                var decisions: [Bool] = []
                let held = URL(string: "https://listed.alcove.example/owned-fullscreen-warning")!
                guard let ticket = store.decideWebsiteProtection(web, url: held, kind: .navigation(isMainFrame: true),
                                                                 decision: { decisions.append($0) }) else { throw Failure.fixture("owned warning ticket") }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                var warning: NSView?
                let visible = await effect {
                    guard web.window === window, !presentation.isVisible,
                          (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false,
                          let parent = web.superview,
                          let overlay = descendants(parent).first(where: { $0.identifier?.rawValue == "AlcoveWebsiteProtection" && !$0.isHiddenOrHasHiddenAncestor }),
                          overlay.window === window, overlay.frame.intersects(parent.bounds) else { return false }
                    warning = overlay; return true
                }
                check(visible && ticket.isPending && decisions.isEmpty,
                      "A held website warning exits fullscreen and visibly covers the captured original page")
                let controls = warning.map(descendants) ?? []
                let safe = controls.first(where: { $0.identifier?.rawValue == "AlcoveWebsiteProtectionSafe" }) as? NSButton
                let proceed = controls.first(where: { $0.identifier?.rawValue == "AlcoveWebsiteProtectionContinue" }) as? NSButton
                print("FULLSCREEN_WARNING_CONTROLS", "assessment", ticket.assessment != nil,
                      "safeFound", safe != nil, "safeEnabled", safe?.isEnabled ?? false,
                      "safeTarget", safe?.target != nil, "continueFound", proceed != nil,
                      "continueHidden", proceed?.isHidden ?? true)
                if let safe { safe.performClick(nil) } else { ticket.cancel() }
                print("FULLSCREEN_WARNING_AFTER_SAFE", "decisions", decisions, "pending", ticket.isPending,
                      "safeEnabled", safe?.isEnabled ?? false, "safeTarget", safe?.target != nil)
                proceed?.performClick(nil)
                print("FULLSCREEN_WARNING_AFTER_CONTINUE", "decisions", decisions, "pending", ticket.isPending)
                check(visible && safe != nil && decisions == [false] && !ticket.isPending,
                      "The visible warning cancels once and a retained Continue control cannot revive it")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "Cancelling the fullscreen warning preserves its original profile, document and unsaved form")
            case "script-alert", "script-confirm", "script-prompt", "script-alert-native-control":
                let marker = "Owned fullscreen " + kind
                var observed = false, restoredBeforePrompt = false, attachedToOrigin = false
                var nativeHiddenBeforePrompt = false, sourceSheet = false, commandBlocked = false
                var defaultWasPreserved = kind != "script-prompt"
                let probe = OwnedFullscreenScriptProbe(store: store, nativeExitControl: kind == "script-alert-native-control") { label in
                    residency(kind + " " + label, web: web, host: commandHost, window: window)
                    print("FULLSCREEN_SCRIPT_BOUNDARY", kind, label, "nativeVisible", presentation.isVisible,
                          "originKey", window.isKeyWindow, "nativeKey", presentation.isKeyWindow,
                          "modal", NSApp.modalWindow != nil, "sourceWindowNil", web.window == nil,
                          "sourceInNative", web.window === presentation)
                }
                guard web.uiDelegate === store else { throw Failure.fixture("original production UI delegate") }
                web.uiDelegate = probe
                defer { web.uiDelegate = store }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                // The legacy app-modal implementation can nest AppKit's run
                // loop. A common-mode native timer witnesses/dismisses only
                // this owned marker, without relying on a blocked actor task.
                let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        guard let prompt = window.attachedSheet ?? presentation.attachedSheet ?? NSApp.modalWindow,
                              let content = prompt.contentView,
                              descendants(content).contains(where: { ($0 as? NSTextField)?.stringValue == marker }) else { return }
                        observed = true
                        restoredBeforePrompt = web.window === window && !presentation.isVisible &&
                            web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                        attachedToOrigin = prompt.sheetParent === window
                        nativeHiddenBeforePrompt = !presentation.isVisible
                        sourceSheet = attachedToOrigin && NSApp.modalWindow !== prompt
                        print("FULLSCREEN_SCRIPT_DIALOG", kind, "restored", restoredBeforePrompt, "originSheet", attachedToOrigin,
                              "appModal", NSApp.modalWindow === prompt)
                        if sourceSheet { app.location(); commandBlocked = !store.commandVisible }
                        if kind == "script-prompt", let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) {
                            defaultWasPreserved = field.stringValue == "Owned starting text"
                            field.stringValue = "Owned submitted text"
                        }
                        timer.invalidate()
                        let response: NSApplication.ModalResponse = kind == "script-confirm" ? .alertSecondButtonReturn : .alertFirstButtonReturn
                        if let parent = prompt.sheetParent { parent.endSheet(prompt, returnCode: response) }
                        else {
                            NSApp.stopModal(withCode: response)
                            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                                NSApp.postEvent(wake, atStart: true)
                            }
                        }
                        prompt.orderOut(nil)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                _ = try await web.callAsyncJavaScript("""
                    window.ownedScriptDialogDone=false;
                    setTimeout(()=>{
                        if(kind.startsWith('script-alert')){alert(marker);window.ownedScriptDialogResult='alert-returned';}
                        else if(kind==='script-confirm') window.ownedScriptDialogResult=confirm(marker);
                        else window.ownedScriptDialogResult=prompt(marker,'Owned starting text');
                        window.ownedScriptDialogDone=true;
                    },0);return true;
                    """, arguments: ["marker": marker, "kind": kind], in: nil, contentWorld: .page)
                let shown = await effect { observed }
                // WebKit cannot finalize its immediate exit until the dialog
                // reply resumes JavaScript. Physical hiding and correct sheet
                // ownership must precede the prompt; live restoration follows.
                check(shown && nativeHiddenBeforePrompt && sourceSheet,
                      "\(kind): native fullscreen is hidden before a real dialog sheet appears on its captured browser window")
                check(shown && commandBlocked, "\(kind): a source-bound script sheet blocks conflicting address UI")
                var completed = false
                do {
                    try await wait("owned script dialog completion") { (try? await web.evaluateJavaScript("window.ownedScriptDialogDone===true")) as? Bool == true }
                    completed = true
                } catch { print("FULLSCREEN_SCRIPT_DIALOG_COMPLETION_ERROR", kind, error) }
                let result = try await web.evaluateJavaScript("window.ownedScriptDialogResult")
                let expectedResult = kind == "script-confirm" ? (result as? Bool == false) :
                    (result as? String == (kind.hasPrefix("script-alert") ? "alert-returned" : "Owned submitted text"))
                check(completed && expectedResult, "\(kind): the actual document receives the native dialog result")
                if kind == "script-prompt" { check(shown && defaultWasPreserved, "The real prompt preserves its starting text before submitting edited text") }
                let restored = await effect {
                    web.window === window && web.superview is EdgeToEdgeWebHost && !presentation.isVisible &&
                        web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(restored && store.profileID(for: web) == profile,
                      "\(kind): answering the actual dialog completes native exit and restores its exact page to the original profile/window")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(completed && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): dismissing the actual dialog resumes its original document and preserves the unsaved form")
                residency(kind + " after-script", web: web, host: commandHost, window: window)
            case "coalesced", "coalesced-close":
                guard let coordinator = (web as? SplitDropWebView)?.websiteFullscreen else { throw Failure.fixture("exit coordinator") }
                var results: [Bool] = []
                coordinator.exit { restored in
                    results.append(restored)
                    if restored && kind == "coalesced-close" { store.close(id) }
                }
                coordinator.exit { results.append($0) }
                let finished = await effect { results.count == 2 }
                check(finished && !presentation.isVisible && web.fullscreenState == .notInFullscreen,
                      "\(kind): simultaneous exit requests complete at the actual native restoration boundary")
                if kind == "coalesced-close" {
                    check(results == [true, false] && store.views[id] == nil,
                          "A captured tab closed by the first exit callback revokes the second callback")
                } else {
                    check(results == [true, true] && web.window === window,
                          "Coalesced callbacks each receive one valid original presentation")
                    if finished {
                        try await enter(web, target: "element")
                        check(results.count == 2 && coordinator.isBorrowed,
                              "A new genuine fullscreen presentation does not replay completed exit callbacks")
                        try await leave(web)
                        check(results.count == 2, "Completed callbacks remain settled after a later native exit")
                    }
                }
            case "focus-change":
                let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 280),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
                other.isReleasedWhenClosed = false; other.title = "Owned alternate focus"
                other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
                defer { other.contentView = nil; other.close() }
                var focusEvents: [String] = []
                let focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
                    MainActor.assumeIsolated {
                        guard let changed = notification.object as? NSWindow else { return }
                        focusEvents.append(changed === other ? "other" : changed === window ? "origin" : changed === presentation ? "fullscreen" : "unrelated")
                    }
                }
                defer { NotificationCenter.default.removeObserver(focusObserver) }
                app.find()
                other.makeKeyAndOrderFront(nil)
                print("FULLSCREEN_FOCUS_REQUESTED", "otherKey", other.isKeyWindow, "originKey", window.isKeyWindow,
                      "fullscreenKey", presentation.isKeyWindow, "find", store.findVisible)
                let exited = await effect { (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                print("FULLSCREEN_FOCUS_RESULT", "exited", exited, "otherKey", other.isKeyWindow,
                      "originKey", window.isKeyWindow, "fullscreenKey", presentation.isKeyWindow,
                      "find", store.findVisible, "events", focusEvents)
                check(exited && !presentation.isVisible && web.window === window,
                      "A focus change during command delivery still completes native fullscreen restoration")
                check(exited && !store.findVisible && other.isKeyWindow,
                      "A deferred browser command neither opens UI nor steals focus after another window becomes key")
            case "close-primary-window-direct", "peek-close-primary-window-direct":
                guard !isQuick else { throw Failure.fixture("direct primary-window close requires a primary page") }
                check(owner.leaseCount == 1 && !owner.isClosed && !store.isShuttingDown,
                      "Direct primary closure starts with one live window retaining its browser owner")
                var closedWhileNative = false
                let closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        if presentation.isVisible || web.fullscreenState != .notInFullscreen {
                            closedWhileNative = true
                        }
                    }
                }
                defer { NotificationCenter.default.removeObserver(closeObservation) }
                window.performClose(nil)
                window.performClose(nil)
                let stillNative = presentation.isVisible || web.fullscreenState != .notInFullscreen ||
                    (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true
                check(!stillNative || (window.isVisible && app.windows[window] === store &&
                      app.primaryOwners[window] === owner && !owner.isClosed && !store.isShuttingDown &&
                      store.views[id] === underlying && (web === underlying || store.primaryPeekView === web)),
                      "Direct primary closure retains its window, owner, parent and Peek until physical fullscreen return")
                let closed = await effect {
                    !window.isVisible && app.windows[window] == nil && app.primaryOwners[window] == nil &&
                        owner.isClosed && store.isShuttingDown && owner.leaseCount == 0 &&
                        !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(!closedWhileNative,
                      "The primary window's actual close notification follows native fullscreen completion")
                check(closed && store.views.isEmpty && store.primaryPeekView == nil,
                      "Repeated direct primary closure releases the last owner, real page and native windows without recovery")
                check(closed && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                      "Closing the last primary window leaves the browser application running")
            case "close-window-direct", "peek-parent-close", "peek-parent-model-close":
                guard isQuick else { throw Failure.fixture("direct compact-window close requires Quick Browse") }
                let survivor = store.view(for: primaryID)
                try await wait("direct Quick close surviving primary document") {
                    (try? await survivor.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await survivor.evaluateJavaScript("document.getElementById('draft').value='surviving compact close draft';true")
                let survivorDocument = store.documentIdentity(for: survivor)
                check((web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true &&
                      web.fullscreenState == .inFullscreen,
                      "Direct Quick parent closure begins with the actual page or Peek still borrowed by native fullscreen")
                if kind == "peek-parent-model-close" { try store.closeQuickPage(id) }
                else { window.performClose(nil) }
                let stillNative = presentation.isVisible || web.fullscreenState != .notInFullscreen ||
                    (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true
                check(!stillNative || (window.isVisible && store.quickPage(id) != nil && store.views[id] === underlying &&
                      (web === underlying || store.quickPeekView(id) === web)),
                      "Direct Quick parent closure retains its window, parent and Peek until physical fullscreen exit")
                let closed = await effect {
                    store.quickPage(id) == nil && store.views[id] == nil && store.quickPeekView(id) == nil &&
                        !window.isVisible && !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(closed && !app.quickWindows.keys.contains(QuickWindowKey(ownerID: owner.id, pageID: id)),
                      "Direct Quick parent closure removes its actual native fullscreen and compact windows without recovery")
                check(closed && store.library(for: profile).archive.filter({ $0.id == id }).count == 1,
                      "Direct Quick parent closure archives the parent exactly once after native return")
                let survivorDraft = (try? await survivor.evaluateJavaScript("document.getElementById('draft').value==='surviving compact close draft'")) as? Bool
                check(primaryWindow.isVisible && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp) &&
                      store.views[primaryID] === survivor && store.profileID(for: survivor) == profile &&
                      store.documentIdentity(for: survivor) === survivorDocument && survivorDraft == true,
                      "Direct Quick parent closure preserves the primary window's exact independent profile, document and unsaved form")
            case "close":
                app.closeTab()
                if isQuick {
                    let closed = await effect { store.quickPage(id) == nil && !window.isVisible && !presentation.isVisible && web.fullscreenState == .notInFullscreen }
                    check(closed && app.quickWindows.isEmpty && primaryWindow.isVisible && store.tab(primaryID) != nil,
                          "Cmd-W leaves fullscreen and closes only its captured Quick window")
                    check(closed && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                          "Closing a fullscreen Quick window keeps the browser application running")
                    break
                }
                let closed = await effect { store.views[targetID] == nil && web.fullscreenState == .notInFullscreen && !presentation.isVisible }
                check(closed && window.isVisible && store.tab(id) != nil, "Cmd-W exits fullscreen and closes only the captured tab while another page remains")
                if closed {
                    store.select(id)
                    try await wait("real survivor browser host") { underlying.window === window && underlying.superview is EdgeToEdgeWebHost }
                    try await wait("remaining page decoded") { (try? await underlying.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true }
                    try await enter(underlying, target: "element")
                    app.closeTab()
                    let windowClosed = await effect { !window.isVisible && underlying.fullscreenState == .notInFullscreen }
                    check(windowClosed && app.windows[window] == nil, "Cmd-W on the last real tab exits fullscreen and closes its browser window")
                    check(windowClosed && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                          "Closing the last fullscreen tab leaves the browser application running")
                } else {
                    check(false, "Last-tab close remains unqualified while captured tab close fails")
                }
            case "close-script-sheet", "navigate-script-sheet", "peek-close-script-sheet", "peek-navigate-script-sheet", "peek-replace-script-sheet", "peek-replace-cancel-script-sheet":
                let isPeek = kind.hasPrefix("peek-"), replacing = kind.hasPrefix("peek-replace")
                let retiring = kind.hasSuffix("close-script-sheet") || kind == "peek-replace-cancel-script-sheet"
                let replacement = base.appendingPathComponent("article")
                let survivorID = isQuick && !isPeek ? primaryID : id
                let survivor = isQuick && !isPeek ? store.view(for: primaryID) : underlying
                func sourceRegistered() -> Bool {
                    isPeek ? (isQuick ? store.quickPeekView(id) : store.primaryPeekView) === web : store.views[targetID] === web
                }
                func closeSource() {
                    if isPeek {
                        if isQuick { store.closeQuickPeek(id) } else { store.closePrimaryPeek() }
                    } else { store.close(targetID) }
                }
                try await wait("owned surviving sheet-close document") {
                    (try? await survivor.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await survivor.evaluateJavaScript("document.getElementById('draft').value='surviving sheet-close draft';true")
                let survivorDocument = store.documentIdentity(for: survivor)
                let marker = "Owned pending confirmation on tab closure"
                let probe = OwnedFullscreenScriptProbe(store: store) { label in
                    residency(kind + " " + label, web: web, host: commandHost, window: window)
                }
                guard web.uiDelegate === store else { throw Failure.fixture("pending-script production delegate") }
                web.uiDelegate = probe
                defer { if sourceRegistered() { web.uiDelegate = store } }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                var prompt: NSWindow?, deadline: ContinuousClock.Instant?
                var observed = false, unanswered = false, hiddenBeforePrompt = false
                var closedBeforeRecovery = false, recoveryUsed = false
                let clock = ContinuousClock()
                // A real JS dialog can hold even the initiating evaluation's
                // reply. Observe/close in AppKit's common run-loop modes.
                let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        if !observed {
                            guard let sheet = window.attachedSheet, sheet.isVisible, let content = sheet.contentView,
                                  descendants(content).contains(where: { ($0 as? NSTextField)?.stringValue == marker }) else { return }
                            prompt = sheet; observed = true
                            unanswered = probe.confirmationResults.isEmpty
                            hiddenBeforePrompt = !presentation.isVisible
                            deadline = clock.now.advanced(by: .seconds(12))
                            if replacing {
                                store.openPeek(base.appendingPathComponent("page"), from: survivor)
                                store.openPeek(replacement, from: survivor)
                                let stillNative = web.fullscreenState != .notInFullscreen ||
                                    (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true
                                check(!stillNative || sourceRegistered(),
                                      "Peek replacement retains the old source until its real native exit completes")
                                if retiring { closeSource() }
                            } else if retiring { closeSource() }
                            else if isQuick {
                                do { try store.navigateForegroundQuickPage(targetID, input: replacement.absoluteString) }
                                catch { print("FULLSCREEN_PENDING_QUICK_NAVIGATION_ERROR", error) }
                            } else {
                                // Primary Peek URL edits capture their target
                                // through the actual address-command context.
                                if isPeek { store.showCommand(new: false) }
                                else { store.commandOpensNewTab = false }
                                store.navigate(replacement.absoluteString)
                            }
                        }
                        let replacementPeek = isQuick ? store.quickPeekView(id) : store.primaryPeekView
                        let sourceSettled = retiring ? (isPeek ? !sourceRegistered() && replacementPeek == nil : (store.views[targetID] == nil &&
                            (isQuick ? store.quickPage(targetID) == nil && !window.isVisible : store.tab(targetID) == nil))) :
                            (replacing ? (!sourceRegistered() && replacementPeek != nil && replacementPeek !== web &&
                                replacementPeek?.url == replacement && replacementPeek?.isLoading == false && replacementPeek?.window === window) :
                                (sourceRegistered() && web.url == replacement && !web.isLoading && web.window === window &&
                                    store.documentIdentity(for: web) !== document))
                        if sourceSettled && !presentation.isVisible &&
                            web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false &&
                            prompt?.isVisible == false && window.attachedSheet == nil && probe.confirmationResults == [false] {
                            closedBeforeRecovery = true; timer.invalidate()
                        } else if let deadline, clock.now >= deadline {
                            // Snapshot failure before ending our owned sheet.
                            // Recovery must never make the assertion pass.
                            recoveryUsed = true; timer.invalidate()
                            if let prompt, let parent = prompt.sheetParent {
                                parent.endSheet(prompt, returnCode: .alertSecondButtonReturn); prompt.orderOut(nil)
                            }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                do {
                    _ = try await web.callAsyncJavaScript("setTimeout(()=>confirm(marker),0);return true;",
                        arguments: ["marker": marker], in: nil, contentWorld: .page)
                } catch {
                    guard observed else { throw error }
                    print("FULLSCREEN_PENDING_SHEET_EVALUATION_ENDED", error)
                }
                let settled = await effect { closedBeforeRecovery || recoveryUsed }
                timer.invalidate()
                let closed = settled && closedBeforeRecovery
                check(observed && unanswered && hiddenBeforePrompt,
                      "An actual unanswered page confirmation belongs to its captured browser window after fullscreen hides")
                check(closed,
                      "\(kind): changing the source cancels its actual pending script sheet once and completes native exit")
                print("FULLSCREEN_PENDING_SHEET_LIFETIME", kind, "settled", closed, "recoveryUsed", recoveryUsed,
                      "replies", probe.confirmationResults, "sheetVisible", prompt?.isVisible ?? false,
                      "attached", window.attachedSheet != nil, "registered", sourceRegistered(),
                      "state", web.fullscreenState.rawValue)
                if let prompt, let parent = prompt.sheetParent {
                    parent.endSheet(prompt, returnCode: .alertSecondButtonReturn); prompt.orderOut(nil)
                }
                if !closed {
                    _ = await effect { !probe.confirmationResults.isEmpty }
                    if retiring {
                        closeSource()
                        _ = await effect { !sourceRegistered() }
                    } else if replacing {
                        _ = await effect { (isQuick ? store.quickPeekView(id) : store.primaryPeekView)?.url == replacement }
                    } else { _ = await effect { web.url == replacement && !web.isLoading } }
                }
                let survivorDraft = try await survivor.evaluateJavaScript("document.getElementById('draft').value==='surviving sheet-close draft'") as? Bool
                let browserVisible = isQuick && retiring && !isPeek ? primaryWindow.isVisible && !window.isVisible : window.isVisible
                check(closed && browserVisible && NSApp.isRunning && store.views[survivorID] === survivor &&
                      store.profileID(for: survivor) == profile && store.documentIdentity(for: survivor) === survivorDocument && survivorDraft == true,
                      "Cancelling a source's script sheet preserves the other exact live profile/document/form")
                if !retiring {
                    let target = replacing ? (isQuick ? store.quickPeekView(id) : store.primaryPeekView) : web
                    let replacementDOM = try await target?.evaluateJavaScript("document.querySelector('article')!==null&&document.getElementById('draft').value==='original'&&window.ownedCommandToken===undefined") as? Bool
                    let registered = replacing ? target != nil && target !== web && !sourceRegistered() : sourceRegistered()
                    check(closed && registered && target.map { store.profileID(for: $0) == profile } == true && replacementDOM == true,
                          "The latest Peek replacement or navigation commits its requested fresh document in the captured profile")
                }
            case "close-direct", "close-direct-background":
                try await wait("owned surviving document") {
                    (try? await underlying.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await underlying.evaluateJavaScript("document.getElementById('draft').value='surviving close draft';true")
                let survivorDocument = store.documentIdentity(for: underlying)
                var alternate: NSWindow?
                if kind == "close-direct-background" {
                    let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 280),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    other.isReleasedWhenClosed = false; other.title = "Owned background tab-close requester"
                    other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
                    other.makeKeyAndOrderFront(nil); alternate = other
                    try await wait("owned close requester key") { other.isKeyWindow }
                }
                defer { alternate?.contentView = nil; alternate?.close() }
                // This is the shared model API used by tab close controls;
                // AppDelegate's already-qualified Cmd-W wrapper is bypassed.
                store.close(targetID)
                let closed = await effect {
                    store.views[targetID] == nil && store.tab(targetID) == nil && !presentation.isVisible &&
                        web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(closed, "Closing a fullscreen tab through its shared model API finishes native exit before retiring the page")
                let survivorDraft = try await underlying.evaluateJavaScript("document.getElementById('draft').value==='surviving close draft'") as? Bool
                check(closed && window.isVisible && NSApp.isRunning && store.views[id] === underlying &&
                      store.profileID(for: underlying) == profile && store.documentIdentity(for: underlying) === survivorDocument && survivorDraft == true,
                      "Direct fullscreen tab closure keeps the browser and its other exact live document/profile/form intact")
                if let alternate { check(closed && alternate.isKeyWindow, "Closing a fullscreen tab from another window preserves the requesting window's focus") }
            default: throw Failure.fixture("unknown native command")
            }
            if let parent = extensionPeekParent {
                let retained = (try? await parent.web.evaluateJavaScript("document.getElementById('draft').value==='extension Peek parent'&&window.ownedExtensionPeekParent===53")) as? Bool
                check(store.views[id] === parent.web && store.documentIdentity(for: parent.web) === parent.document &&
                      store.profileID(for: parent.web) == profile && retained == true &&
                      (isQuick ? store.quickPeekView(id) : store.primaryPeekView) === web,
                      "Extension fullscreen Peek focus preserves its separate parent document and unsaved form")
            }
            }
        } catch { caught = error }

        // Recover using the independently qualified document exit, only after
        // observing each command's own result. Recovery never turns a failure green.
        let remaining = [underlying, web] + Array(store.views.values) + store.peekPages.values.map(\.web)
        var recovered = Set<ObjectIdentifier>()
        for page in remaining where recovered.insert(ObjectIdentifier(page)).inserted &&
            (page.fullscreenState != .notInFullscreen || (page as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true) {
            do { try await leave(page) }
            catch { failures += 1; print("FULLSCREEN_COMMAND_RECOVERY_ERROR", kind, error) }
        }
        for controller in Array(app.quickWindows.values) { controller.window?.performClose(nil) }
        app.quickWindows.removeAll()
        for ownedWindow in Array(app.windows.keys) { ownedWindow.performClose(nil) }
        app.windows.removeAll(); app.primaryOwners.removeAll(); app.primaryLeases.removeAll()
        if let caught { throw caught }
        print("FULLSCREEN_COMMAND_CASE_COMPLETED", kind, "private", isPrivate, "quick", isQuick)
    }

    @available(macOS 15.4, *) @MainActor
    private static func exerciseFullscreenExtensionWindowAction(options: WKWebView, app: AppDelegate,
        owner: BrowserWindowOwner, store: BrowserStore, web: WKWebView, window: NSWindow,
        presentation: NSWindow, sourceURL: URL, sourceID: UUID, primaryID: UUID,
        windowType: String, document: NSUUID, removing: Bool,
        cancellation: (id: UUID, profile: UUID, revoke: Bool)? = nil) async throws {
        guard let sdkID = try await options.callAsyncJavaScript("""
            const windows = await browser.windows.getAll({populate:true});
            const targets = windows.filter(w => w.type === type && w.tabs?.some(t => t.url === url));
            return targets.length === 1 ? targets[0].id : -1;
            """, arguments: ["type": windowType, "url": sourceURL.absoluteString],
            in: nil, contentWorld: .page) as? NSNumber, sdkID.intValue >= 0,
            let coordinator = (web as? SplitDropWebView)?.websiteFullscreen else {
            throw Failure.fixture("actual SDK window action target")
        }
        let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 280),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.title = "Owned extension action focus control"
        other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        defer { other.contentView = nil; other.close() }
        var survivor: WKWebView?, survivorDocument: NSUUID?
        if removing {
            let page = store.view(for: primaryID)
            try await wait("extension close survivor document") {
                (try? await page.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
            }
            _ = try await page.evaluateJavaScript("document.getElementById('draft').value='surviving extension window';window.ownedExtensionSurvivor=91;true")
            survivor = page; survivorDocument = store.documentIdentity(for: page)
        } else {
            other.makeKeyAndOrderFront(nil)
            try await wait("extension action alternate focus") { other.isKeyWindow }
        }
        var cancellationObservation: NSKeyValueObservation?
        var cancellationPhase: Int?, cancellationApplied = false, contextUnloaded = false
        var cancellationScheduled = false, cancellationError: String?
        if let cancellation {
            guard let controller = options.configuration.webExtensionController,
                  let context = controller.extensionContexts.first(where: { $0.baseURL.host == options.url?.host }) else {
                throw Failure.fixture("original owned extension context before cancellation")
            }
            cancellationObservation = web.observe(\.fullscreenState, options: [.new]) { view, _ in
                MainActor.assumeIsolated {
                    guard view.fullscreenState == .exitingFullscreen, !cancellationScheduled else { return }
                    cancellationScheduled = true
                    DispatchQueue.main.async {
                        guard web.fullscreenState == .exitingFullscreen, !store.isShuttingDown else {
                            cancellationError = "missed actual exit phase"; return
                        }
                        cancellationPhase = Int(web.fullscreenState.rawValue)
                        do {
                            if cancellation.revoke {
                                try store.setExtensionGrants(cancellation.id, profileID: cancellation.profile, grants: nil)
                            } else {
                                try store.setExtensionEnabled(cancellation.id, profileID: cancellation.profile, enabled: false)
                            }
                            let record = store.extensionRecords(profileID: cancellation.profile).first { $0.id == cancellation.id }
                            cancellationApplied = record?.enabled == false && (!cancellation.revoke || record?.grants == nil)
                            contextUnloaded = !controller.extensionContexts.contains(where: { $0 === context })
                            print("FULLSCREEN_EXTENSION_CANCEL_APPLIED", "revoke", cancellation.revoke,
                                  "phase", cancellationPhase ?? -1, "applied", cancellationApplied,
                                  "contextUnloaded", contextUnloaded, "afterState", web.fullscreenState.rawValue)
                        } catch { cancellationError = error.localizedDescription }
                    }
                }
            }
        }
        defer { cancellationObservation?.invalidate() }
        _ = try await options.callAsyncJavaScript("""
            window.ownedFullscreenAction = {status:'pending'};
            try {
                const operation = removing ? browser.windows.remove(id) : browser.windows.update(id,{focused:true});
                operation.then(value => {window.ownedFullscreenAction = {status:'fulfilled',id:value?.id ?? id};},
                    error => {window.ownedFullscreenAction = {status:'rejected',error:String(error.message ?? error)};});
            } catch(error) {window.ownedFullscreenAction = {status:'rejected',error:String(error.message ?? error)};}
            return true;
            """, arguments: ["id": sdkID, "removing": removing], in: nil, contentWorld: .page)
        if let cancellation {
            let restored = await effect {
                web.fullscreenState == .notInFullscreen && !coordinator.isBorrowed &&
                    !presentation.isVisible && web.window === window
            }
            guard cancellationPhase == 3, cancellationApplied, contextUnloaded, cancellationError == nil else {
                print("FULLSCREEN_EXTENSION_CANCEL_SETUP", "phase", cancellationPhase ?? -1,
                      "applied", cancellationApplied, "contextUnloaded", contextUnloaded,
                      "error", cancellationError ?? "none", "restored", restored)
                throw Failure.fixture("extension revocation before physical fullscreen return")
            }
            check(cancellationApplied && contextUnloaded,
                  "The normal extension \(cancellation.revoke ? "revoke" : "disable") operation unloads its actual SDK context during native exit")
            check(restored && window.isVisible && store.quickPage(sourceID) != nil && store.views[sourceID] === web &&
                  app.quickWindows.values.contains(where: { $0.window === window }),
                  "Revoking the requesting context cancels its deferred window close and preserves the real Quick page")
            let sourceDraft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41")) as? Bool
            let survivorDraft = try? await survivor?.evaluateJavaScript("document.getElementById('draft').value==='surviving extension window'&&window.ownedExtensionSurvivor===91")
            check(restored && store.documentIdentity(for: web) === document && sourceDraft == true &&
                  survivor != nil && store.documentIdentity(for: survivor!) === survivorDocument && survivorDraft as? Bool == true &&
                  !owner.isClosed && !store.isShuttingDown && owner.leaseCount == 2 && NSApp.isRunning,
                  "Cancelled SDK removal preserves both exact live documents, unsaved forms and window leases")
            return
        }
        var reply: [String: Any] = [:]
        try await wait("actual SDK window action reply") {
            reply = (try? await options.evaluateJavaScript("window.ownedFullscreenAction")) as? [String: Any] ?? [:]
            return ["fulfilled", "rejected"].contains(reply["status"] as? String ?? "")
        }
        let accepted = reply["status"] as? String == "fulfilled"
        print("FULLSCREEN_EXTENSION_WINDOW_ACTION", "remove", removing, "type", windowType, "reply", reply,
              "nativeKey", presentation.isKeyWindow, "originKey", window.isKeyWindow, "state", web.fullscreenState.rawValue)
        check(accepted, "The actual extension window \(removing ? "remove" : "focus") request completes successfully")
        if removing {
            let retired = await effect {
                !window.isVisible && !presentation.isVisible && store.quickPage(sourceID) == nil && store.views[sourceID] == nil &&
                    !app.quickWindows.values.contains(where: { $0.window === window }) &&
                    web.fullscreenState == .notInFullscreen && !coordinator.isBorrowed
            }
            check(retired, "SDK window removal physically closes its captured Quick window and fullscreen page without recovery")
            let draft = try? await survivor?.evaluateJavaScript("document.getElementById('draft').value==='surviving extension window'&&window.ownedExtensionSurvivor===91")
            check(retired && survivor != nil && store.documentIdentity(for: survivor!) === survivorDocument && draft as? Bool == true &&
                  !owner.isClosed && !store.isShuttingDown && owner.leaseCount == 1 && NSApp.isRunning,
                  "SDK Quick removal preserves the exact primary page/form, its owner and the running browser")
        } else {
            let returned = await effect {
                presentation.isKeyWindow && presentation.isVisible && web.window === presentation &&
                    web.fullscreenState == .inFullscreen && coordinator.logicalWindow === window
            }
            check(accepted && returned,
                  "An SDK focus request returns keyboard focus to the existing native fullscreen presentation")
            if coordinator.isBorrowed || web.fullscreenState != .notInFullscreen { try await leave(web) }
            window.makeKeyAndOrderFront(nil)
            let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41")) as? Bool
            check(web.window === window && store.documentIdentity(for: web) === document && draft == true,
                  "SDK window focusing preserves the exact page/document/form through subsequent native exit")
        }
    }

    @available(macOS 15.4, *) @MainActor
    private static func exerciseFullscreenExtensionFocus(options: WKWebView, store: BrowserStore,
        web: WKWebView, window: NSWindow, presentation: NSWindow, sourceURL: URL,
        windowType: String, document: NSUUID) async throws {
        var last: [String: Any] = [:]
        func focused(_ expected: Bool, afterEvents: Int? = nil) async -> Bool {
            do {
                try await wait("actual extension focus API") {
                    guard let state = try await options.callAsyncJavaScript("""
                        const windows = await browser.windows.getAll({populate:true});
                        const targets = windows.filter(w => w.type === type && w.tabs?.some(t => t.url === url));
                        const target = targets[0];
                        return {windowCount:windows.length,targets:targets.length,targetId:target?.id ?? -2,
                            focused:target?.focused === true,focusedCount:windows.filter(w => w.focused).length,
                            activeSource:target?.tabs?.some(t => t.active && t.url === url) === true,
                            eventCount:window.ownedFocusEvents?.length ?? 0,
                            lastEvent:window.ownedFocusEvents?.at(-1) ?? -2};
                        """, arguments: ["type": windowType, "url": sourceURL.absoluteString],
                        in: nil, contentWorld: .page) as? [String: Any] else {
                        throw Failure.fixture("native extension windows API result")
                    }
                    last = state
                    let id = (state["targetId"] as? NSNumber)?.intValue
                    let lastEvent = (state["lastEvent"] as? NSNumber)?.intValue
                    let eventCount = (state["eventCount"] as? NSNumber)?.intValue ?? 0
                    return state["targets"] as? Int == 1 && state["activeSource"] as? Bool == true &&
                        state["focused"] as? Bool == expected && state["focusedCount"] as? Int == (expected ? 1 : 0) &&
                        (afterEvents == nil || (eventCount > afterEvents! && lastEvent == (expected ? id : -1)))
                }
                return true
            } catch { return false }
        }
        let fullscreenFocused = await focused(true)
        print("FULLSCREEN_EXTENSION_FOCUS", "phase", "fullscreen", "type", windowType, "state", last)
        check(fullscreenFocused, "The real extension windows API reports its logical browser window focused during website fullscreen")
        let expectedCount = windowType == "popup" ? 2 : 1
        check(last["windowCount"] as? Int == expectedCount,
              "The extension API does not expose WebKit's physical fullscreen window as another browser window")
        let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 280),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.title = "Owned extension focus control"
        other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        defer { other.contentView = nil; other.close() }
        let beforeOther = (last["eventCount"] as? NSNumber)?.intValue ?? 0
        other.makeKeyAndOrderFront(nil)
        try await wait("alternate extension focus control is key") { other.isKeyWindow }
        let unfocused = await focused(false, afterEvents: beforeOther)
        print("FULLSCREEN_EXTENSION_FOCUS", "phase", "other", "type", windowType, "state", last)
        check(unfocused, "Actual extension focus state and onFocusChanged report no browser window when an unrelated window is key")
        let beforeReturn = (last["eventCount"] as? NSNumber)?.intValue ?? 0
        presentation.makeKeyAndOrderFront(nil)
        try await wait("native fullscreen regains key") { presentation.isKeyWindow }
        let refocused = await focused(true, afterEvents: beforeReturn)
        print("FULLSCREEN_EXTENSION_FOCUS", "phase", "returned", "type", windowType, "state", last)
        check(refocused, "Returning to native fullscreen delivers the real extension focus event for the same logical browser window")
        try await leave(web)
        window.makeKeyAndOrderFront(nil)
        let restored = await focused(true)
        let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41")) as? Bool
        check(restored && web.window === window && store.documentIdentity(for: web) === document && draft == true,
              "Exiting fullscreen preserves extension focus, the actual source document and its unsaved form")
    }

    @available(macOS 15.4, *) @MainActor
    private static func exerciseTransitionWindowClose(app: AppDelegate, owner: BrowserWindowOwner,
                                                      store: BrowserStore, web: WKWebView,
                                                      window: NSWindow, entering: Bool) async throws {
        guard let coordinator = (web as? SplitDropWebView)?.websiteFullscreen else {
            throw Failure.fixture("real primary fullscreen coordinator")
        }
        let phase: WKWebView.FullscreenState = entering ? .enteringFullscreen : .exitingFullscreen
        check(owner.leaseCount == 1 && !owner.isClosed && !store.isShuttingDown,
              "Transition closure starts with a live primary window and its sole owner lease")
        var scheduled = false, attempted: WKWebView.FullscreenState?
        var presentation: NSWindow?, states: [Int] = []
        var retainedDuringTransition = false, closedWhileNative = false, closeNotifications = 0
        let closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                      object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                closeNotifications += 1
                if web.fullscreenState != .notInFullscreen || coordinator.isBorrowed || presentation?.isVisible == true {
                    closedWhileNative = true
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(closeObservation) }
        let stateObservation = web.observe(\.fullscreenState, options: [.new]) { view, _ in
            MainActor.assumeIsolated {
                states.append(Int(view.fullscreenState.rawValue))
                if let native = view.window, native !== window { presentation = native }
                guard view.fullscreenState == phase, !scheduled else { return }
                scheduled = true
                // Deliver the close on the app queue, outside WebKit's KVO
                // callback. Missing the actual phase is a fixture failure.
                DispatchQueue.main.async {
                    guard web.fullscreenState == phase else {
                        print("FULLSCREEN_TRANSITION_CLOSE_MISSED", "expected", phase.rawValue,
                              "actual", web.fullscreenState.rawValue)
                        return
                    }
                    attempted = web.fullscreenState
                    print("FULLSCREEN_TRANSITION_CLOSE_REQUESTED", "phase", phase.rawValue,
                          "borrowed", coordinator.isBorrowed, "logicalWindow", coordinator.logicalWindow === window)
                    window.performClose(nil); window.performClose(nil)
                    retainedDuringTransition = app.windows[window] === store && app.primaryOwners[window] === owner &&
                        !owner.isClosed && !store.isShuttingDown && owner.leaseCount == 1 &&
                        store.views.values.contains(where: { $0 === web })
                }
            }
        }
        defer { stateObservation.invalidate() }
        if entering {
            web.callAsyncJavaScript("""
                document.getElementById('element').requestFullscreen().catch(() => {});
                return true;
                """, arguments: [:], in: nil, in: .page) { _ in }
        } else {
            try await enter(web, target: "element")
            if let native = web.window, native !== window { presentation = native }
            web.callAsyncJavaScript("""
                Document.prototype.exitFullscreen.call(document).catch(() => {});
                return true;
                """, arguments: [:], in: nil, in: .defaultClient) { _ in }
        }
        let closed = await effect {
            attempted != nil && !window.isVisible && app.windows[window] == nil && app.primaryOwners[window] == nil &&
                owner.isClosed && store.isShuttingDown && owner.leaseCount == 0 &&
                web.fullscreenState == .notInFullscreen && !coordinator.isBorrowed &&
                presentation != nil && presentation?.isVisible == false
        }
        print("FULLSCREEN_TRANSITION_CLOSE_RESULT", "expected", phase.rawValue,
              "attempted", attempted?.rawValue ?? -1, "states", states, "closed", closed,
              "retained", retainedDuringTransition, "notifications", closeNotifications,
              "premature", closedWhileNative)
        check(attempted == phase, "The close is actually delivered during the requested native fullscreen transition")
        check(retainedDuringTransition, "Closing during a native transition retains the page, window and owner until return")
        check(!closedWhileNative && closeNotifications == 1,
              "Repeated transition closes deliver one window-close notification after physical fullscreen return")
        check(closed && store.views.isEmpty, "Transition closure retires the actual native window and last page without recovery")
        check(closed && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp),
              "Closing the final transitioning window leaves the browser application running")
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseCommands(base: URL) async throws {
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await owned.cleanup() else { throw Failure.fixture("command ownership recovery") }
        let regular = ["escape", "peek-escape", "location", "find", "close", "reader", "print", "pdf", "archive", "customize", "settings", "library", "coalesced", "coalesced-close", "focus-change", "new-tab", "sidebar", "next-tab", "next-space", "split", "file-prompt", "media-prompt", "warning", "script-alert", "script-confirm", "script-prompt", "archive-static", "suspend-static", "profile-clear", "peek-profile-clear", "quit", "peek-quit"]
        let extensionFocusCases = ["extension-focus", "quick-extension-focus", "extension-focus-request", "quick-extension-focus-request", "quick-extension-close", "quick-extension-close-disable", "quick-extension-close-revoke", "peek-extension-focus", "quick-peek-extension-focus", "peek-extension-focus-request", "quick-peek-extension-focus-request"]
        let scriptDialogs = ["script-alert", "script-confirm", "script-prompt"]
        let promptLifetimes = ["close-script-sheet", "navigate-script-sheet"]
        let peekLifetimes = ["peek-close-script-sheet", "peek-navigate-script-sheet", "peek-replace-script-sheet", "peek-replace-cancel-script-sheet"]
        let compact = (["escape", "peek-escape", "location", "find", "reader", "close", "close-window-direct", "peek-parent-close", "peek-parent-model-close", "expire-static", "peek-expire-static", "profile-clear", "peek-profile-clear", "quit", "peek-quit"] + scriptDialogs + promptLifetimes).map { "quick-" + $0 }
        let primaryWindowClosure = ["close-primary-window-direct", "peek-close-primary-window-direct", "close-primary-entering", "close-primary-exiting"]
        let all = extensionFocusCases + regular + ["close-direct", "close-direct-background", "handoff", "handoff-cancel", "handoff-close", "handoff-source-close", "handoff-source-navigate"] + promptLifetimes + peekLifetimes + primaryWindowClosure + (["escape", "location", "find", "reader", "close", "suspend-static", "profile-clear", "peek-profile-clear", "quit", "peek-quit"] + scriptDialogs + promptLifetimes + peekLifetimes + primaryWindowClosure).map { "private-" + $0 } + compact + compact.map { "private-" + $0 } + peekLifetimes.map { "quick-" + $0 } + peekLifetimes.map { "private-quick-" + $0 } + ["quick-profile-delete", "quick-peek-profile-delete"]
        let selected = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_COMMAND_CASES"].map { $0.split(separator: ",").map(String.init) } ?? []
        let group = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_COMMAND_GROUP"] ?? ""
        guard ["", "primary", "private-primary", "quick"].contains(group), group.isEmpty || selected.isEmpty else {
            throw Failure.fixture("invalid command group or mixed selection")
        }
        // Characterization controls are opt-in and never counted as normal
        // production-path command coverage in the full default matrix.
        // App-local events do not grant WebKit transient activation on this
        // hosted OS. Keep no-media's strict input control explicit; ordinary
        // no-media fullscreen remains a required, unqualified live-input gate.
        guard selected.allSatisfy((all + ["script-alert-native-control", "no-media", "layout-production", "layout-normal-production", "layout-no-motion-production", "layout-collapsed-production", "layout-single-tab-production", "layout-minimum-control", "layout-fixed-control", "layout-preconfigured-control", "layout-content-minimum-control", "layout-web-content-control", "layout-chrome-reader-control", "layout-sidebar-row-control", "layout-sidebar-scroll-control", "layout-sidebar-saved-control", "layout-chrome-feedback-control", "layout-native-menus-control", "layout-address-controls-control", "layout-tracking-control", "layout-store-sheet-control", "layout-full-sidebar-control", "layout-isolated-defaults-control", "layout-progress-control", "layout-content-frame-control", "layout-resize-grip-control", "layout-ignored-safe-area-control", "layout-conditional-progress-control", "layout-ready-production", "layout-full-sidebar-narrow-control", "layout-wide-defaults-control", "layout-normal-motion-production", "layout-normal-no-motion-production", "layout-normal-ready-focus-production", "layout-normal-loading-focus-production", "layout-private-ready-focus-production", "layout-private-loading-focus-production", "layout-normal-background-focus-production"]).contains) else { throw Failure.fixture("unknown selected command case") }
        for name in selected.isEmpty ? all : selected {
            let isPrivate = name.hasPrefix("private-"), presentation = isPrivate ? String(name.dropFirst(8)) : name
            let isQuick = presentation.hasPrefix("quick-"), kind = isQuick ? String(presentation.dropFirst(6)) : presentation
            if ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_SKIP_QUIT"] == "1" && ["quit", "peek-quit"].contains(kind) { continue }
            if group == "primary" && (isQuick || isPrivate) ||
                group == "private-primary" && (isQuick || !isPrivate) ||
                group == "quick" && !isQuick { continue }
            print("FULLSCREEN_COMMAND_CASE_STARTED", name)
            print("FULLSCREEN_COMMAND_CASE_ELAPSED", name, runStarted.duration(to: .now))
            do { try await exerciseCommand(base: base, kind: kind, owned: owned, controllers: controllers, isPrivate: isPrivate, isQuick: isQuick) }
            catch { failures += 1; print("FULLSCREEN_COMMAND_CASE_ERROR", name, error) }
        }
        let a = await controllers.cleanup(), b = await owned.cleanup()
        check(a && b, "Native command fixtures release and erase all owned website/extension stores")
        print("FULLSCREEN_COMMAND_CLEANUP", a, b)
    }
}
