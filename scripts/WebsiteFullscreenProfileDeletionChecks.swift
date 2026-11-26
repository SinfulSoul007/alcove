import AppKit
import WebKit
import CryptoKit
import BrowserCore
import Combine

/// Observations must not keep the page or its native window alive while the
/// production deletion path waits for WebKit's last references to disappear.
@MainActor private final class OwnedFullscreenDeletionWitness {
    weak var parent: WKWebView?
    weak var source: WKWebView?
    weak var compactWindow: NSWindow?
    weak var presentationWindow: NSWindow?

    init(parent: WKWebView, source: WKWebView, compact: NSWindow, presentation: NSWindow) {
        self.parent = parent; self.source = source
        compactWindow = compact; presentationWindow = presentation
    }
    var sourceReleased: Bool { parent == nil && source == nil }
    var nativeGone: Bool { presentationWindow?.isVisible != true }
    var compactGone: Bool { compactWindow?.isVisible != true }
    var stillNative: Bool {
        guard let source else { return !nativeGone }
        return !nativeGone || source.fullscreenState != .notInFullscreen ||
            (source as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true
    }
    func isBorrowed(in store: BrowserStore, profile: UUID, id: UUID, peek: Bool) -> Bool {
        guard let source, let parent else { return false }
        return source.fullscreenState == .inFullscreen &&
            (source as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true &&
            store.profileID(for: source) == profile && store.views[id] === parent &&
            (!peek || store.quickPeekView(id) === source)
    }
    func closeNativeForCleanup() { presentationWindow?.close() }
}

extension WebsiteFullscreenChecks {
    @available(macOS 15.4, *) @MainActor
    private static func stageProfileDeletion(base: URL, app: AppDelegate, store: BrowserStore,
                                            id: UUID, profile: UUID, window: NSWindow,
                                            peek: Bool) async throws -> OwnedFullscreenDeletionWitness {
        let parent = store.view(for: id)
        let source: WKWebView
        if peek {
            store.openPeek(base.appendingPathComponent("page"), from: parent)
            guard let child = store.quickPeekView(id) else { throw Failure.fixture("deletion Quick Peek") }
            source = child
        } else { source = parent }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("deletion source mounted and decoded") {
            guard source.window === window, source.superview is EdgeToEdgeWebHost, !source.isLoading else { return false }
            return (try? await source.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true
        }
        try await wait("deletion source window and document visible") {
            guard NSApp.isActive, window.isVisible, window.isKeyWindow, window.isOnActiveSpace,
                  source.window === window, !source.isHiddenOrHasHiddenAncestor else { return false }
            return (try? await source.evaluateJavaScript("document.visibilityState==='visible'")) as? Bool == true
        }
        guard source.configuration.websiteDataStore.identifier == profile else {
            throw Failure.fixture("deletion source own named store")
        }
        _ = try await source.evaluateJavaScript("document.cookie='owned_fullscreen_delete=target; path=/; SameSite=Lax';localStorage.setItem('owned_fullscreen_delete','target');true")
        try await enter(source, target: "element")
        guard let presentation = source.window, presentation !== window else { throw Failure.fixture("deletion native presentation") }
        try await wait("deletion native presentation key") { presentation.isKeyWindow }
        check(app.browserStore(in: presentation) === store && app.activeWebView === source && app.activeBrowserWindow === window,
              "Profile deletion starts with its actual fullscreen Quick source in the captured logical window")
        return OwnedFullscreenDeletionWitness(parent: parent, source: source, compact: window, presentation: presentation)
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseProfileDeletion(base: URL, owned: OwnedWebsiteStores,
                                        controllers: OwnedExtensionControllers, peek: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-deletion-" + UUID().uuidString)
        let key = SymmetricKey(data: Data(repeating: 93, count: 32))
        let writer = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        writer.finishOnboarding(); writer.preferences.automaticUpdateChecks = false
        let target = try writer.createProfile(name: "Owned deleting fullscreen profile")
        let oldSpace = writer.space.id
        let survivorProfile = try writer.createProfile(name: "Owned deletion survivor")
        for profile in [target, survivorProfile] {
            try owned.register(profile)
            if let controller = writer.profiles.first(where: { $0.id == profile })?.extensionControllerID {
                try controllers.register(controller)
            }
        }
        try writer.assignProfile(survivorProfile, to: oldSpace)
        let app = AppDelegate(), owner = app.makeOwner(writer)
        app.normalOwner = owner
        defer { owner.shutdown(); writer.shutdown(); try? FileManager.default.removeItem(at: root) }
        app.openPrimary(owner)
        guard let primary = app.primaryOwners.first(where: { $0.value === owner })?.key,
              let store = app.windows[primary], store === writer else { throw Failure.fixture("deletion primary owner") }
        defer {
            for controller in Array(app.quickWindows.values) { controller.window?.close() }
            app.quickWindows.removeAll()
            for window in Array(app.windows.keys) { window.performClose(nil) }
            app.windows.removeAll(); app.primaryOwners.removeAll(); app.primaryLeases.removeAll()
        }
        let survivorID = store.newTab(url: base.appendingPathComponent("page-no-media"))
        let survivor = store.view(for: survivorID)
        try await wait("profile deletion survivor document") {
            (try? await survivor.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
        }
        _ = try await survivor.evaluateJavaScript("document.getElementById('draft').value='surviving profile deletion draft';document.cookie='owned_fullscreen_delete=survivor; path=/; SameSite=Lax';localStorage.setItem('owned_fullscreen_delete','survivor');true")
        let survivorDocument = store.documentIdentity(for: survivor)
        let id = try store.openQuickPage(url: base.appendingPathComponent("page"), profileID: target)
        app.syncQuickWindows(owner)
        guard let compact = app.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: id)]?.window else {
            throw Failure.fixture("deletion compact window")
        }
        check(target != BrowserProfile.defaultID && !store.session.spaces.contains(where: { $0.effectiveProfileID == target }) &&
              store.quickProfileID(id) == target && survivor.configuration.websiteDataStore.identifier == survivorProfile,
              "An unused owned named profile retains a live Quick page while another profile owns the primary window")
        let witness = try await stageProfileDeletion(base: base, app: app, store: store, id: id,
                                                     profile: target, window: compact, peek: peek)
        defer { witness.closeNativeForCleanup() }
        guard witness.isBorrowed(in: store, profile: target, id: id, peek: peek) else {
            throw Failure.fixture("actual borrowed deletion source")
        }
        var retiredBeforeNative = false
        let subscription = store.objectWillChange.sink { [weak store] _ in
            MainActor.assumeIsolated {
                guard let store, witness.stillNative else { return }
                if store.views[id] == nil || store.quickPage(id) == nil ||
                    (peek && store.quickPeekView(id) == nil) || witness.compactGone { retiredBeforeNative = true }
            }
        }
        defer { subscription.cancel() }
        var calls = 0, safeRemoval = false, durableMarker = false, deletionError: Error?
        do {
            try await store.deleteProfile(target, removeStore: { identifier in
                guard identifier == target, identifier != BrowserProfile.defaultID else {
                    throw Failure.fixture("refusing deletion outside own named profile")
                }
                calls += 1
                safeRemoval = witness.nativeGone && witness.compactGone && witness.sourceReleased &&
                    store.quickPage(id) == nil && store.views[id] == nil && store.quickPeekView(id) == nil
                check(safeRemoval, "Named-store deletion begins only after native fullscreen, compact window and source references are released")
                let saved = try MetadataStore(url: writer.sessionURL, key: key).load(BrowserDocument.self)
                durableMarker = saved?.profiles?.first(where: { $0.id == target })?.isPendingDeletion == true
                check(durableMarker, "The encrypted deletion marker is durable before actual named-store removal")
                for attempt in 0..<50 {
                    guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(identifier) else { return }
                    do { try await WKWebsiteDataStore.remove(forIdentifier: identifier); return }
                    catch { if attempt == 49 { throw error }; try await Task.sleep(for: .milliseconds(100)) }
                }
            })
        } catch { deletionError = error; print("FULLSCREEN_PROFILE_DELETION_ERROR", error) }
        subscription.cancel()
        check(!retiredBeforeNative, "Profile deletion retains parent, Peek and compact registration until native fullscreen really ends")
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        check(deletionError == nil && calls == 1 && safeRemoval && durableMarker && witness.nativeGone && witness.compactGone &&
              witness.sourceReleased && !store.profiles.contains(where: { $0.id == target }) && !identifiers.contains(target),
              "Deleting a fullscreen profile actually removes its one named website store and registry entry without recovery")
        let survivorData = (try? await survivor.evaluateJavaScript("document.getElementById('draft').value==='surviving profile deletion draft'&&document.cookie==='owned_fullscreen_delete=survivor'&&localStorage.getItem('owned_fullscreen_delete')==='survivor'")) as? Bool
        check(primary.isVisible && NSApp.isRunning && store.views[survivorID] === survivor &&
              store.profileID(for: survivor) == survivorProfile && store.documentIdentity(for: survivor) === survivorDocument &&
              survivorData == true && identifiers.contains(survivorProfile),
              "Deleting the fullscreen profile preserves the other profile's exact live document, form, cookie, local storage and named store")
        if deletionError != nil {
            print("FULLSCREEN_PROFILE_DELETION_FAILED_STATE", "nativeVisible", !witness.nativeGone,
                  "compactVisible", !witness.compactGone, "sourceReleased", witness.sourceReleased,
                  "pending", store.profiles.first(where: { $0.id == target })?.isPendingDeletion == true)
        }
    }
}
