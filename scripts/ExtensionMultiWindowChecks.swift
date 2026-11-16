import AppKit
import BrowserCore
import CryptoKit
import WebKit

enum ExtensionWindowTestError: Error { case missingFixture, missingRuntime, pageDidNotLoad }

@MainActor
private final class OwnedExtensionMenuTarget: NSObject {
    private(set) var selections = 0
    @objc func choose(_ item: NSMenuItem) { selections += 1 }
}

@main
struct ExtensionMultiWindowChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard #available(macOS 15.4, *) else { print("UNAVAILABLE: Native extension windows require macOS 15.4."); return }
        let stores = try OwnedWebsiteStores()
        let controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await stores.cleanup() else { exit(1) }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        do { try await exercise(stores: stores, controllers: controllers, check: check) }
        catch { check(false, "The extension window fixture completed: \(error.localizedDescription)") }
        check(await controllers.cleanup(), "The fixture releases its owned extension controllers")
        check(await stores.cleanup(), "The fixture releases its owned website stores")
        if failures > 0 { exit(1) }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func exercise(stores: OwnedWebsiteStores, controllers: OwnedExtensionControllers,
                                 check: (Bool, String) -> Void) async throws {
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"], let fixture = URL(string: address) else {
            throw ExtensionWindowTestError.missingFixture
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-native-extension-windows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let root = BrowserStore(dataRoot: directory.appendingPathComponent("profile"), keyProvider: { _ in key })
        let profile = try root.createProfile(name: "Owned window extension test")
        try stores.register(profile)
        try controllers.register(root.profiles.first { $0.id == profile }!.extensionControllerID!)
        let owner = BrowserWindowOwner(store: root)
        let first = try owner.acquirePrimaryStore()
        let second = try owner.acquirePrimaryStore(copying: root)
        let child = second.store
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let left = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let right = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        left.isReleasedWhenClosed = false
        right.isReleasedWhenClosed = false
        root.registerExtensionWindow(left, kind: .primary)
        child.registerExtensionWindow(right, kind: .primary)
        defer {
            left.contentView = nil; right.contentView = nil
            root.unregisterExtensionWindow(kind: .primary); child.unregisterExtensionWindow(kind: .primary)
            left.close(); right.close()
            owner.release(first.lease); owner.release(second.lease)
        }

        let source = directory.appendingPathComponent("extension")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"Owned window extension","version":"1","permissions":["tabs"],"host_permissions":["http://127.0.0.1/*"],"options_page":"options.html"}"#
        try Data(manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Owned window options</title><main id='owned-options'>Options</main>".utf8).write(to: source.appendingPathComponent("options.html"))
        let package = try ExtensionPackage.prepare(at: source, stagingRoot: directory.appendingPathComponent("staging"))
        let approval = try root.extensionInstallApproval(for: package, profileID: profile, permissions: ["tabs"], hostPatterns: ["http://127.0.0.1/*"], enable: true)
        let installed = try await root.installExtension(package, approval: approval)
        let urlA = fixture.appending(queryItems: [URLQueryItem(name: "window", value: "left")])
        let urlB = fixture.appending(queryItems: [URLQueryItem(name: "window", value: "right")])
        let tabA = root.newTab(url: urlA)
        let tabB = child.newTab(url: urlB)
        let pageA = root.view(for: tabA)
        let pageB = child.view(for: tabB)
        right.contentView = pageB
        let optionsID = try await root.openExtensionOptions(installed, profileID: profile)
        guard let options = root.views[optionsID], let native = root.extensionHosting as? NativeBrowserExtensionHost,
              let controller = pageA.configuration.webExtensionController,
              let context = controller.extensionContexts.first else { throw ExtensionWindowTestError.missingRuntime }
        left.contentView = options
        try await ready(options, expression: "document.getElementById('owned-options') !== null")
        try await ready(pageA, expression: "document.body?.dataset.ownedExtensionPage === 'ready'")
        try await ready(pageB, expression: "document.body?.dataset.ownedExtensionPage === 'ready'")
        check(pageB.configuration.webExtensionController === controller && child.extensionHosting === native,
              "Both normal windows share the profile's actual WebKit extension controller")
        native.synchronizeBrowserState()
        let tabs = try await query(options)
        let a = tabs.filter { ($0["url"] as? String) == urlA.absoluteString }
        let b = tabs.filter { ($0["url"] as? String) == urlB.absoluteString }
        check(a.count == 1 && b.count == 1 && (a.first?["windowId"] as? NSNumber) != (b.first?["windowId"] as? NSNumber),
              "The real tabs API sees each normal tab once under its actual window")

        left.contentView = pageA
        let previousAdapter = native.tabsByView[ObjectIdentifier(pageA)]
        let previousSource = previousAdapter.flatMap { NativeExtensionSource(host: native, controller: controller, context: context, tab: $0) }
        guard let previousSource else { throw ExtensionWindowTestError.missingRuntime }
        let target = OwnedExtensionMenuTarget()
        let original = NSMenuItem(title: "Owned action", action: #selector(OwnedExtensionMenuTarget.choose(_:)), keyEquivalent: "")
        original.target = target
        var budget = 1
        let guarded = NativeExtensionGuardedMenuItem(original, source: previousSource, expires: .now.advanced(by: .seconds(90)), depth: 0, budget: &budget)
        child.select(tabA)
        right.contentView = pageA
        native.synchronizeBrowserState()
        let moved = native.tabsByView[ObjectIdentifier(pageA)]
        check(moved != nil && moved === previousAdapter && moved?.browserWindow?.store === child,
              "Tab handoff preserves the native extension tab identity and changes its window")
        check(!previousSource.current,
              "An old window's extension action loses its document authorization on handoff")
        root.select(tabA)
        left.contentView = pageA
        native.synchronizeBrowserState()
        if let action = guarded.action { _ = NSApp.sendAction(action, to: guarded.target, from: guarded) }
        check(!previousSource.current && !guarded.validateMenuItem(guarded) && target.selections == 0,
              "A retained extension menu item stays revoked after its original document returns")
        child.select(tabA)
        right.contentView = pageA
        native.synchronizeBrowserState()

        let unloadedID = root.newTab(url: fixture.appendingPathComponent("unloaded-handoff"), activate: false)
        native.synchronizeBrowserState()
        let unloadedKey = NativeExtensionTabKey(storeID: root.extensionStoreID, profileID: profile, id: unloadedID, isPeek: false)
        guard let unloaded = native.nativeTabs[unloadedKey], unloaded.web == nil,
              let unloadedSource = NativeExtensionSource(host: native, controller: controller, context: context, tab: unloaded, requiresMountedView: false),
              unloadedSource.current, let group = root.windowGroup else { throw ExtensionWindowTestError.missingRuntime }
        let changedOwner = group.claimPresentation(tabID: unloadedID, in: child)
        let returnedOwner = group.claimPresentation(tabID: unloadedID, in: root)
        native.synchronizeBrowserState()
        check(changedOwner && returnedOwner && !unloadedSource.current,
              "An unloaded tab's menu source stays revoked even when both logical moves happen before synchronization")
        root.close(unloadedID)

        let app = AppDelegate()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        app.normalOwner = owner
        defer {
            for window in Array(app.windows.keys) { window.close() }
            NSApp.delegate = previousDelegate
        }
        root.windowGroup?.focusPrimary(child)
        let requestA = fixture.appending(queryItems: [URLQueryItem(name: "window-create", value: "first")])
        let requestB = fixture.appending(queryItems: [URLQueryItem(name: "window-create", value: "second")])
        let created = try await createWindow(options, arguments: ["url": [requestA.absoluteString, requestB.absoluteString], "focused": false])
        let newStore = app.windows.values.first
        let windowID = created["id"] as? NSNumber
        let newTabs = try await query(options).filter { ($0["windowId"] as? NSNumber) == windowID }
        check(windowID != nil && newStore?.activeProfileID == profile && app.windows.count == 1 &&
              Set(newTabs.compactMap { $0["url"] as? String }) == Set([requestA.absoluteString, requestB.absoluteString]),
              "The real windows.create API opens both URLs in one new window under the requesting profile")
        check(root.windowGroup?.focusedPrimary === child && child.views[tabA] === pageA,
              "A background extension window leaves the current window and live tab alone")

        _ = try await pageA.evaluateJavaScript("document.getElementById('owned-form').value = 'keep this window draft'; true")
        let oldTabID = a.first?["id"] as? NSNumber
        let movedWindow = try await createWindow(options, arguments: ["tabId": oldTabID ?? -1, "focused": false])
        let movedWindowID = movedWindow["id"] as? NSNumber
        let reported = try await query(options).first { ($0["id"] as? NSNumber) == oldTabID }
        let retained = (try await pageA.evaluateJavaScript("document.getElementById('owned-form').value === 'keep this window draft'")) as? Bool == true
        check(movedWindowID != nil && (reported?["windowId"] as? NSNumber) == movedWindowID && retained &&
              app.windows.values.contains { $0.views[tabA] === pageA },
              "windows.create with an existing tab keeps its native ID and unsaved form")

        let popupURL = fixture.appending(queryItems: [URLQueryItem(name: "extension-popup", value: "website")])
        let optionsURL = context.optionsPageURL!.absoluteString
        let beforePopup = Set(app.windows.keys)
        let popup = try await createWindow(options, arguments: ["type": "popup", "url": [optionsURL, popupURL.absoluteString],
                                                               "focused": false, "width": 640, "height": 450])
        let popupID = popup["id"] as? NSNumber
        if let popupID, let popupWindow = app.windows.keys.first(where: { !beforePopup.contains($0) }), let popupStore = app.windows[popupWindow] {
            let popupTabs = try await query(options).filter { ($0["windowId"] as? NSNumber) == popupID }
            check(popup["type"] as? String == "popup" && popupStore.activeProfileID == profile && popupWindow.frame.width == 640 &&
                    Set(popupTabs.compactMap { $0["url"] as? String }) == Set([optionsURL, popupURL.absoluteString]),
                  "The real windows API opens the extension page and webpage in a compact popup under the requesting profile")
            check(root.windowGroup?.focusedPrimary === child && !popupStore.sidebarVisible,
                  "A background popup leaves the focused normal window in place and starts compact")
            check(root.windowGroup?.restoreState()?.records.contains { $0.selection.id == popupStore.windowGroupID } == false,
                  "An extension popup is omitted from normal workspace restoration")
            let popupPages = popupStore.extensionPopupTabs
            if let ownedExtensionTab = popupPages.first(where: { $0.url == optionsURL }),
               let ownedWebTab = popupPages.first(where: { $0.url == popupURL.absoluteString }) {
                _ = popupStore.view(for: ownedExtensionTab.id)
                var extensionLoaded = false
                for _ in 0..<600 {
                    if let ownPage = popupStore.views[ownedExtensionTab.id], ownPage.url == context.optionsPageURL,
                       (try? await ownPage.evaluateJavaScript("document.getElementById('owned-options') !== null")) as? Bool == true {
                        extensionLoaded = ownPage !== options && ownPage.configuration.webExtensionController === controller
                        break
                    }
                    try await Task.sleep(for: .milliseconds(15))
                }
                let web = popupStore.view(for: ownedWebTab.id)
                try await ready(web, expression: "document.body?.dataset.ownedExtensionPage === 'ready'")
                check(extensionLoaded && web.configuration.websiteDataStore === pageA.configuration.websiteDataStore,
                      "Both popup documents load with the requesting profile's native configuration")
            } else {
                check(false, "Both popup documents load with the requesting profile's native configuration")
            }
            let removed = try await options.callAsyncJavaScript("await browser.windows.remove(id); return true;",
                                                               arguments: ["id": popupID], in: nil, contentWorld: .page) as? Bool
            check(removed == true && Set(app.windows.keys) == beforePopup && popupPages.count == 2 &&
                    popupPages.allSatisfy { root.tab($0.id) == nil } && root.tab(optionsID)?.url == optionsURL,
                  "Closing a popup removes only its own pages and leaves the original options tab and normal windows alive")
        } else { check(false, "The real windows API opens the extension page and webpage in a compact popup under the requesting profile") }

        let beforeEmptyPopup = Set(app.windows.keys)
        let oneTabPopup = try await createWindow(options, arguments: ["type": "popup", "url": popupURL.absoluteString, "focused": false])
        if let popupID = oneTabPopup["id"] as? NSNumber,
           let temporary = app.windows.keys.first(where: { !beforeEmptyPopup.contains($0) }),
           let popupStore = app.windows[temporary],
           let doomed = try await query(options).first(where: { ($0["windowId"] as? NSNumber) == popupID })?["id"] as? NSNumber {
            let removed = try await options.callAsyncJavaScript("await browser.tabs.remove(id); return true;",
                                                               arguments: ["id": doomed], in: nil, contentWorld: .page) as? Bool
            let hadNoSelection = popupStore.selectedID == nil
            let before = Set(root.session.spaces.flatMap(\.tabs).map(\.id))
            popupStore.showCommand()
            popupStore.command = popupURL.absoluteString
            popupStore.submitCommandInput()
            let newlyOpened = popupStore.extensionPopupTabs.first { !before.contains($0.id) }
            check(removed == true && hadNoSelection && newlyOpened?.url == popupURL.absoluteString,
                  "Navigating after removing the last popup tab creates an owned tab without claiming a normal tab")
            native.synchronizeBrowserState()
            if let newlyOpened,
               let replacementID = try await query(options).first(where: { ($0["windowId"] as? NSNumber) == popupID })?["id"] as? NSNumber {
                let pinned = try await options.callAsyncJavaScript("""
                    const kept = await browser.tabs.update(tabId, {pinned:true});
                    await browser.windows.remove(windowId);
                    return kept.pinned;
                    """, arguments: ["tabId": replacementID, "windowId": popupID], in: nil, contentWorld: .page) as? Bool
                let savedPin = root.tab(newlyOpened.id)?.pinned == true
                let sameWindows = Set(app.windows.keys) == beforeEmptyPopup
                if pinned != true || !savedPin || !sameWindows {
                    print("PIN_PROBE native=\(pinned == true) metadata=\(savedPin) windows=\(sameWindows)")
                }
                check(pinned == true && savedPin && sameWindows, "Closing a popup keeps its pinned tab in the shared browser library")
            } else {
                check(false, "Closing a popup keeps its pinned tab in the shared browser library")
                temporary.close()
            }
        } else {
            check(false, "Navigating after removing the last popup tab creates an owned tab without claiming a normal tab")
        }

        let previousPopupWindows = Set(app.windows.keys)
        let originalPresenter = app.windows.values.first { $0.views[tabA] === pageA }
        let movedPopup = try await createWindow(options, arguments: ["type": "popup", "tabId": oldTabID ?? -1, "focused": false])
        if let movedPopupID = movedPopup["id"] as? NSNumber,
           let nativePopup = app.windows.keys.first(where: { !previousPopupWindows.contains($0) }) {
            let residing = try await query(options).first { ($0["id"] as? NSNumber) == oldTabID }
            let liveDraft = try await pageA.evaluateJavaScript("document.getElementById('owned-form').value === 'keep this window draft'") as? Bool
            check(movedPopup["type"] as? String == "popup" && (residing?["windowId"] as? NSNumber) == movedPopupID &&
                    app.windows[nativePopup]?.views[tabA] === pageA && liveDraft == true,
                  "Moving a tab into a popup preserves its native ID and its unsaved form")
            if let originalPresenter {
                let extra = try owner.acquirePrimaryStore(copying: originalPresenter, focus: false)
                check(extra.store.selectedID != tabA && extra.store.views[tabA] == nil && app.windows[nativePopup]?.views[tabA] === pageA,
                      "Opening a normal window cannot automatically take a live tab from a popup")
                owner.release(extra.lease)
            } else { check(false, "Opening a normal window cannot automatically take a live tab from a popup") }
            let popupStore = app.windows[nativePopup]!
            let survivingTab = try popupStore.createExtensionTab(url: popupURL, profileID: profile, activate: true)
            popupStore.openInSplit(tabA)
            popupStore.focusPane(tabA)
            let hadFocusedSplit = popupStore.splitLayout?.tabIDs.contains(tabA) == true && popupStore.focusedID == tabA
            let returned = try await createWindow(options, arguments: ["tabId": oldTabID ?? -1, "focused": false])
            check(hadFocusedSplit && popupStore.splitLayout == nil && popupStore.focusedID == survivingTab,
                  "Moving a focused popup split keeps its remaining tab selected")
            let current = try await query(options).first { ($0["id"] as? NSNumber) == oldTabID }
            check(returned["id"] != nil && (current?["windowId"] as? NSNumber) == (returned["id"] as? NSNumber) &&
                    app.windows.values.contains { $0.views[tabA] === pageA },
                  "The same popup tab can return to a normal window without a new document")
            nativePopup.close()
        } else { check(false, "Moving a tab into a popup preserves its native ID and its unsaved form") }

        let knownWindowCount = app.windows.count
        let blocked = try await createWindow(options, arguments: ["url": "file:///alcove-owned-fixture.html", "focused": false])
        let privateWindow = try await createWindow(options, arguments: ["incognito": true, "focused": false])
        let foreignPopup = try await createWindow(options, arguments: ["type": "popup", "url": "webkit-extension://foreign-fixture/options.html", "focused": false])
        check(blocked["id"] == nil && privateWindow["id"] == nil && app.windows.count == knownWindowCount,
              "Unauthorized file and private window requests leave no new window behind")
        check(foreignPopup["id"] == nil && app.windows.count == knownWindowCount,
              "A popup cannot open another extension's origin")
        root.unregisterExtensionWindow(kind: .primary)
        owner.release(first.lease)
        check(native.authorized(context, profileID: profile, client: child) && !owner.isClosed,
              "Closing the writer's original window keeps extension permissions valid for the surviving normal window")

        let manager = try ExtensionManagerSession(store: child, sourceWindow: right, profileID: profile)
        defer { manager.close() }
        check(manager.canManage, "The surviving normal window can review extensions through the shared writer")
        if manager.canManage {
            let additionalSource = directory.appendingPathComponent("second-extension")
            try FileManager.default.copyItem(at: source, to: additionalSource)
            let additionalManifest = manifest.replacingOccurrences(of: "Owned window extension", with: "Owned second window extension")
            try Data(additionalManifest.utf8).write(to: additionalSource.appendingPathComponent("manifest.json"))
            let review = try await manager.reviewFile(additionalSource)
            let added = try await manager.approve(review, permissions: ["tabs"], hostPatterns: [], allowPrivate: false)
            check(root.extensionRecords(profileID: profile).contains { $0.id == added } &&
                child.extensionRecords(profileID: profile).contains { $0.id == added },
                  "Approval in the second window durably publishes to the shared profile library")
            let pending = try await manager.reviewFile(additionalSource)
            child.unregisterExtensionWindow(kind: .primary)
            do {
                _ = try await manager.approve(pending, permissions: ["tabs"], hostPatterns: [], allowPrivate: false)
                check(false, "Closing the source window revokes its pending approval")
            } catch ExtensionHostError.closed {
                check(true, "Closing the source window revokes its pending approval")
            }
        }
    }

    @MainActor
    private static func ready(_ web: WKWebView, expression: String) async throws {
        for _ in 0..<600 {
            if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw ExtensionWindowTestError.pageDidNotLoad
    }

    @MainActor
    private static func query(_ web: WKWebView) async throws -> [[String: Any]] {
        let value = try await web.callAsyncJavaScript("return JSON.stringify(await browser.tabs.query({}));", arguments: [:], in: nil, contentWorld: .page)
        guard let string = value as? String, let tabs = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [[String: Any]] else {
            throw ExtensionWindowTestError.missingRuntime
        }
        return tabs
    }

    @MainActor
    private static func createWindow(_ web: WKWebView, arguments: [String: Any]) async throws -> [String: Any] {
        let body = """
            try { return JSON.stringify(await browser.windows.create(settings)); }
            catch (error) { return JSON.stringify({ error: String(error) }); }
            """
        let result = try await web.callAsyncJavaScript(body, arguments: ["settings": arguments], in: nil, contentWorld: .page)
        guard let json = result as? String, let data = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ExtensionWindowTestError.missingRuntime
        }
        return data
    }
}
