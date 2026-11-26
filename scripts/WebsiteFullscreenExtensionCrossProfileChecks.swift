import AppKit
import WebKit
import CryptoKit
import BrowserCore

extension WebsiteFullscreenChecks {
    @available(macOS 15.4, *) @MainActor
    static func exerciseCrossProfileExtensionFocus(base: URL, owned: OwnedWebsiteStores,
                                                    controllers: OwnedExtensionControllers) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-cross-profile-focus-" + UUID().uuidString)
        let writer = BrowserStore(dataRoot: root, keyProvider: { _ in SymmetricKey(data: Data(repeating: 93, count: 32)) })
        writer.finishOnboarding(); writer.preferences.automaticUpdateChecks = false
        defer { writer.shutdown(); try? FileManager.default.removeItem(at: root) }
        func register(_ profile: UUID) throws {
            try owned.register(profile)
            if let controller = writer.profiles.first(where: { $0.id == profile })?.extensionControllerID {
                try controllers.register(controller)
            }
        }
        let targetProfile = try writer.createProfile(name: "Owned extension target account")
        try register(targetProfile)
        let targetSpace = writer.space.id
        let packageRoot = root.appendingPathComponent("extension-source")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Owned cross-profile focus","version":"1","permissions":["tabs"],"host_permissions":["http://127.0.0.1/*"],"options_page":"options.html"}"#.utf8)
            .write(to: packageRoot.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><main id='owned-cross-profile'>Owned extension</main>".utf8)
            .write(to: packageRoot.appendingPathComponent("options.html"))
        let package = try ExtensionPackage.prepare(at: packageRoot, stagingRoot: root.appendingPathComponent("staging"))
        let approval = try writer.extensionInstallApproval(for: package, profileID: targetProfile,
            permissions: ["tabs"], hostPatterns: ["http://127.0.0.1/*"], enable: true)
        let installed = try await writer.installExtension(package, approval: approval)
        let targetURL = URL(string: "page-no-media#extension-target-account", relativeTo: base)!.absoluteURL
        let targetID = writer.newTab(url: targetURL)
        let sourceProfile = try writer.createProfile(name: "Owned fullscreen source account")
        try register(sourceProfile)
        let sourceSpace = writer.space.id, sourceURL = base.appendingPathComponent("page")
        let sourceID = writer.newTab(url: sourceURL)
        let app = AppDelegate(), owner = app.makeOwner(writer)
        app.normalOwner = owner; app.openPrimary(owner)
        guard let window = app.primaryOwners.first(where: { $0.value === owner })?.key,
              let store = app.windows[window], store.activeProfileID == sourceProfile else {
            throw Failure.fixture("registered two-profile extension focus window")
        }
        defer {
            window.performClose(nil); window.contentView = nil; window.close()
            app.windows.removeAll(); app.primaryOwners.removeAll(); app.primaryLeases.removeAll()
            owner.shutdown()
        }
        let optionsID = try await store.openExtensionOptions(installed, profileID: targetProfile)
        guard let options = store.views[optionsID] else { throw Failure.fixture("actual target-profile options frame") }
        try await wait("cross-profile extension options document") {
            (try? await options.evaluateJavaScript("document.getElementById('owned-cross-profile')!==null")) as? Bool == true
        }
        store.selectSpace(targetSpace); store.select(targetID)
        let target = store.view(for: targetID)
        try await wait("target account's live document") {
            guard target.window === window, store.activeProfileID == targetProfile, store.focusedID == targetID else { return false }
            return (try? await target.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
        }
        _ = try await target.evaluateJavaScript("document.getElementById('draft').value='target account draft';window.ownedCrossProfileTarget=61;true")
        let targetDocument = store.documentIdentity(for: target)
        store.selectSpace(sourceSpace); store.select(sourceID)
        let source = store.view(for: sourceID)
        var caught: Error?
        do {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("visible cross-profile fullscreen source") {
                guard source.window === window, !source.isLoading, window.isKeyWindow else { return false }
                return (try? await source.evaluateJavaScript("document.visibilityState==='visible'&&document.getElementById('video')?.readyState>=2")) as? Bool == true
            }
            _ = try await source.evaluateJavaScript("document.getElementById('draft').value='source account draft';window.ownedCrossProfileSource=62;true")
            let sourceDocument = store.documentIdentity(for: source)
            guard let state = try await options.callAsyncJavaScript("""
                const windows = await browser.windows.getAll({populate:true});
                const target = windows.find(w=>w.tabs?.some(t=>t.url===targetURL));
                return {id:target?.id ?? -1,count:windows.length,focused:target?.focused===true,
                    sourceExposed:windows.some(w=>w.tabs?.some(t=>t.url===sourceURL))};
                """, arguments: ["targetURL": targetURL.absoluteString, "sourceURL": sourceURL.absoluteString],
                in: nil, contentWorld: .page) as? [String: Any],
                let sdkID = state["id"] as? NSNumber, sdkID.intValue >= 0,
                state["count"] as? Int == 1, state["focused"] as? Bool == false,
                state["sourceExposed"] as? Bool == false else {
                throw Failure.fixture("profile-isolated SDK focus target before fullscreen")
            }
            print("FULLSCREEN_CROSS_PROFILE_FOCUS_CONTROL", state)
            try await enter(source, target: "element")
            guard let presentation = source.window, presentation !== window,
                  let fullscreen = (source as? SplitDropWebView)?.websiteFullscreen else {
                throw Failure.fixture("actual other-profile native fullscreen")
            }
            try await wait("other-profile fullscreen key") { presentation.isKeyWindow }
            check(app.activeStore === store && app.activeWebView === source && store.activeProfileID == sourceProfile,
                  "Cross-profile focus starts on the actual other account's native fullscreen document")
            _ = try await options.callAsyncJavaScript("""
                window.ownedCrossFocus={status:'pending'};
                browser.windows.update(id,{focused:true}).then(
                    w=>window.ownedCrossFocus={status:'fulfilled',id:w.id},
                    e=>window.ownedCrossFocus={status:'rejected',error:String(e)});
                return true;
                """, arguments: ["id": sdkID], in: nil, contentWorld: .page)
            var reply: [String: Any] = [:]
            try await wait("cross-profile SDK focus reply") {
                reply = (try? await options.evaluateJavaScript("window.ownedCrossFocus")) as? [String: Any] ?? [:]
                return ["fulfilled", "rejected"].contains(reply["status"] as? String ?? "")
            }
            let restored = await effect {
                source.fullscreenState == .notInFullscreen && !fullscreen.isBorrowed && !presentation.isVisible &&
                    store.activeProfileID == targetProfile && store.space.id == targetSpace && window.isKeyWindow
            }
            print("FULLSCREEN_CROSS_PROFILE_FOCUS_RESULT", "reply", reply, "sourceState", source.fullscreenState.rawValue,
                  "nativeVisible", presentation.isVisible, "targetProfileActive", store.activeProfileID == targetProfile,
                  "logicalKey", window.isKeyWindow)
            check(reply["status"] as? String == "fulfilled" && restored,
                  "An extension's cross-profile focus request restores native fullscreen before showing its own account")
            let targetDraft = (try? await target.evaluateJavaScript("document.getElementById('draft').value==='target account draft'&&window.ownedCrossProfileTarget===61")) as? Bool
            check(store.views[targetID] === target && store.profileID(for: target) == targetProfile &&
                  store.documentIdentity(for: target) === targetDocument && targetDraft == true &&
                  store.currentView === target && target.window === window,
                  "Cross-profile SDK focus shows the exact authorized target account document and unsaved form")
            let sourceDraft = (try? await source.evaluateJavaScript("document.getElementById('draft').value==='source account draft'&&window.ownedCrossProfileSource===62")) as? Bool
            check(store.views[sourceID] === source && store.profileID(for: source) == sourceProfile &&
                  store.documentIdentity(for: source) === sourceDocument && sourceDraft == true,
                  "Cross-profile focus preserves the separate source account's exact document and unsaved form")
        } catch { caught = error }
        if source.fullscreenState != .notInFullscreen || (source as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true {
            try await leave(source)
        }
        if let caught { throw caught }
    }
}
