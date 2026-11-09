import AppKit
import SwiftUI
import WebKit
import BrowserCore

enum LinkRoutingInputError: Error { case failed, timeout }
@main struct LinkRoutingInputChecks {
    @MainActor static func render(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ALCOVE_LINK_ROUTING_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw LinkRoutingInputError.failed }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let png = bitmap.representation(using:.png,properties:[:]) else { throw LinkRoutingInputError.failed }
        try png.write(to:folder.appendingPathComponent(name+".png"),options:.atomic)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout,nil)
        var failures = 0, fixtures:[SiteSearchStoreFixture] = [], windows:[NSWindow] = []
        defer { windows.forEach { $0.contentView = nil; $0.close() }; fixtures.forEach { $0.close() } }
        func fixture(_ privateMode: Bool = false) throws -> SiteSearchStoreFixture { let f = try SiteSearchStoreFixture(isPrivate:privateMode); fixtures.append(f); return f }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func window(_ size: NSSize = NSSize(width:600,height:420)) -> NSWindow {
            let w = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            w.isReleasedWhenClosed = false; windows.append(w); return w
        }
        func preview(_ f: SiteSearchStoreFixture, context: PeekContext = .primary) -> (SiteSearchProbeWeb,NSWindow) {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = SiteSearchProbeWeb(frame:f.web.frame,configuration:config), w = window(); w.contentView = web
            f.store.peekPages[context] = PeekState(web:web,profileID:f.profile,spaceID:context == .primary ? f.store.space.id : nil)
            return (web,w)
        }
        func crossing() throws -> (SiteSearchStoreFixture,UUID,SiteSearchProbeWeb,NSWindow) {
            let f = try fixture(), source = f.store.space.id
            let b = try f.store.createProfile(name:"Owned reload target"); f.store.namedDataStores[b] = .nonPersistent(); let target = f.store.space.id
            f.store.selectSpace(source); let (web,w) = preview(f); return (f,target,web,w)
        }
        let f = try fixture(), store = f.store, delegate = AppDelegate()
        check(BrowserCommand.linkRouting.matches("link preferences") && BrowserCommand.linkRouting.matches("air traffic control") && store.availableCommands.contains(.linkRouting), "Both Arc-style aliases discover the actual routing command")
        store.showCommand(); store.runCommand(.linkRouting)
        check(store.presentedPanel == .links && !store.commandVisible, "Routing command closes input and opens Links settings")
        store.presentedPanel = .settings
        let settingsWindow = window(NSSize(width:720,height:620)), settingsHost = NSHostingView(rootView:SettingsPanel(store:store))
        settingsHost.safeAreaRegions = []; settingsHost.sizingOptions = []; settingsWindow.contentView = settingsHost
        settingsHost.layoutSubtreeIfNeeded()
        check(settingsHost.fittingSize.width <= 601, "The Settings entry host retains its bounded panel width")
        delegate.buildMenu()
        check(NSApp.mainMenu?.items.first?.submenu?.items.contains(where:{$0.action == #selector(AppDelegate.linkRoutingSettings) && $0.target === delegate}) == true, "The native app menu exposes the actual Link Routing action")
        let original = LinkRule(pattern:"/original",destination:.mostRecentSpace); try store.saveLinkRule(original)
        let editor = LinkRoutingEditor(); editor.edit(original); editor.pattern = "/edited"
        var toggled = original; toggled.enabled = false; try store.saveLinkRule(toggled)
        check(editor.save(in:store) && store.linkRuleCatalog.entries[0].pattern == "/edited" && !store.linkRuleCatalog.entries[0].enabled, "Saving fields preserves a newer disabled state")
        editor.edit(store.linkRuleCatalog.entries[0]); editor.pattern = "/enabled-edit"
        toggled = store.linkRuleCatalog.entries[0]; toggled.enabled = true; try store.saveLinkRule(toggled)
        check(editor.save(in:store) && store.linkRuleCatalog.entries[0].enabled && store.linkRuleCatalog.entries[0].pattern == "/enabled-edit", "Saving fields preserves a newer enabled state")
        editor.edit(store.linkRuleCatalog.entries[0]); editor.pattern = "/done-save"
        let linksWindow = window(NSSize(width:600,height:620)), linksHost = NSHostingView(rootView:LinkRoutingPanel(store:store,editor:editor))
        linksHost.safeAreaRegions = []; linksHost.sizingOptions = []; linksWindow.contentView = linksHost
        linksHost.layoutSubtreeIfNeeded()
        _ = editor.finish(in:store)
        check(store.presentedPanel == nil && store.linkRuleCatalog.entries[0].pattern == "/done-save", "Done’s shared action commits a dirty editor before dismissal")
        store.presentedPanel = .links; editor.edit(store.linkRuleCatalog.entries[0]); editor.pattern = "\n"
        _ = editor.finish(in:store)
        check(store.presentedPanel == .links && editor.error != nil && store.linkRuleCatalog.entries[0].pattern == "/done-save", "Invalid Done keeps the editor and existing route visible")
        editor.cancel(); check(!editor.isDirty && editor.error == nil, "Cancel Edit drops only the local draft")
        let bytes = try Data(contentsOf:store.sessionURL), previous = store.effectiveDefaultLinkDestination
        store.savingEnabled = false; var failedDefault = false
        do { try store.setDefaultLinkDestination(.space(store.space.id)) } catch { failedDefault = true }
        check(try failedDefault && store.effectiveDefaultLinkDestination == previous && Data(contentsOf:store.sessionURL) == bytes, "A rejected settings default preserves live selection and ciphertext")
        store.savingEnabled = true
        let requests = f.web.requests.count
        let description = LinkRoutingPanel.preview("http://127.0.0.1:9/done-save",in:store)
        check(description.contains("Most Recent Space") && f.web.requests.count == requests, "Match preview describes the chosen route without navigating the page")
        let mountedWindow = window(NSSize(width:800,height:600)); mountedWindow.contentView = f.web
        for height in [360.0,620.0] {
            var appearance = store.appearance; appearance.textScale = 1.35; store.appearance = appearance
            let w = window(NSSize(width:600,height:height)), host = NSHostingView(rootView:LinkRoutingPanel(store:store,availableHeight:height))
            host.safeAreaRegions = []; host.sizingOptions = []; w.contentView = host
            host.layoutSubtreeIfNeeded()
            check(host.fittingSize.width <= 601 && host.fittingSize.height <= height + 1, "Links settings stay bounded at600pt by\(Int(height))pt with large text")
            check(f.web.window === mountedWindow && store.views[store.selectedID!] === f.web, "Opening and resizing Links preserves the mounted website")
            try render(host,name:"links-600x\(Int(height))-large-text")
        }
        try render(settingsHost,name:"settings-entry-large-text")
        let plain = try fixture(), plainStore = plain.store
        let (plainPeek,_) = preview(plain)
        plainStore.expandPeek(in:.primary)
        check(plainStore.primaryPeekView == nil && plainStore.views.values.contains(where:{$0 === plainPeek}), "The primary Peek button's callback-free wrapper actually completes its handoff")
        let unmounted = try fixture(), us = unmounted.store
        let unmountedConfig = WKWebViewConfiguration(); unmountedConfig.websiteDataStore = .nonPersistent()
        let unmountedPeek = SiteSearchProbeWeb(frame:unmounted.web.frame,configuration:unmountedConfig)
        us.peekPages[.primary] = PeekState(web:unmountedPeek,profileID:unmounted.profile,spaceID:us.space.id)
        let unmountedCount = us.session.spaces.flatMap(\.tabs).count; var windowError = false
        us.requestExpandPeek(in:.primary,onError:{ windowError = $0 is LinkRoutingError })
        check(windowError && us.primaryPeekView === unmountedPeek && us.session.spaces.flatMap(\.tabs).count == unmountedCount, "A windowless UI request is rejected without metadata or page ownership changes")
        let privateF = try fixture(true)
        check(LinkRoutingPanel.scopeDescription(in:privateF.store).contains("Private") && !privateF.store.canEditLinkRules, "Private Links settings explain the separate temporary owner")
        let alert = LinkRoutingPrompt.makeAlert(title:"Reload in target?",detail:"Owned fixture")
        check(alert.buttons.map(\.title) == ["Cancel","Reload in Profile"] && alert.messageText == "Reload in target?" && alert.informativeText == "Owned fixture", "The real native consent alert presents cancel first and an explicit reload action")
        var callbacks:[(Bool)->Void] = [], completions:[UUID] = [], errors = 0, prompts = 0
        let prompt = LinkRoutingPrompt(confirm:{_,_,_,reply in prompts += 1; callbacks.append(reply)})
        let (cancelF,cancelTarget,cancelWeb,_) = try crossing(), cancelStore = cancelF.store
        cancelStore.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        // No automatic route means source ownership is retained, so this first action needs no prompt.
        check(completions.count == 1 && prompts == 0 && cancelStore.views[completions[0]] === cancelWeb, "Same-profile native action completes without a consent sheet")
        let (cf,target,cw,_) = try crossing(), cs = cf.store
        try cs.saveLinkRule(LinkRule(pattern:"/original",destination:.space(target)))
        let beforeTabs = cs.session.spaces.flatMap(\.tabs).count
        cs.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        check(prompts == 1 && cs.primaryPeekView === cw && cs.session.spaces.flatMap(\.tabs).count == beforeTabs, "Cross-profile native action waits without creating a tab")
        callbacks[0](false)
        check(cs.primaryPeekView === cw && completions.count == 1 && cs.session.spaces.flatMap(\.tabs).count == beforeTabs, "Cancel leaves the source Peek and metadata unchanged")
        cs.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        cs.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        check(prompts == 2, "A busy source window cannot open duplicate reload prompts")
        callbacks[1](true); callbacks[1](true)
        check(completions.count == 2 && cs.session.spaces.first(where:{$0.id == target})?.tabs.filter({$0.url == "http://127.0.0.1:9/original"}).count == 1 && cs.selectedID == completions.last && cs.primaryPeekView == nil, "One accepted prompt publishes one target tab despite duplicate callbacks")
        let (closedF,closedTarget,closedWeb,closedWindow) = try crossing(), closedStore = closedF.store
        try closedStore.saveLinkRule(LinkRule(pattern:"/original",destination:.space(closedTarget)))
        closedStore.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        closedWindow.close(); callbacks.last!(true)
        check(completions.count == 2 && closedStore.primaryPeekView === closedWeb, "Closing the source window invalidates its pending callback")
        let (changedF,changedTarget,changedWeb,_) = try crossing(), changedStore = changedF.store
        var changingRule = LinkRule(pattern:"/original",destination:.space(changedTarget)); try changedStore.saveLinkRule(changingRule)
        changedStore.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        changingRule.destination = .quickBrowse; try changedStore.saveLinkRule(changingRule); callbacks.last!(true)
        check(completions.count == 2 && changedStore.primaryPeekView === changedWeb, "Native acceptance revalidates the matched route")
        try changedStore.saveLinkRule(LinkRule(id:changingRule.id,pattern:"/original",destination:.space(changedTarget)))
        changedStore.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        changedStore.invalidateDocumentIdentity(for:changedWeb); callbacks.last!(true)
        check(completions.count == 2 && changedStore.primaryPeekView === changedWeb, "Native acceptance revalidates document identity")
        changedStore.requestExpandPeek(in:.primary,confirmation:prompt,onComplete:{completions.append($0)},onError:{_ in errors += 1})
        changedStore.session.spaces[changedStore.session.spaces.firstIndex(where:{$0.id == changedTarget})!].profileID = changedF.profile; callbacks.last!(true)
        check(completions.count == 2 && changedStore.primaryPeekView === changedWeb, "Native acceptance revalidates destination account ownership")
        check(errors >= 4, "Blocked or changed native requests report recoverable errors")
        let quickF = try fixture(), qs = quickF.store, owner = BrowserWindowOwner(store:quickF.store)
        let parent = try qs.openQuickPage(profileID:quickF.profile); var primaryRequests = 0
        let controller = try QuickBrowseWindowController(owner:owner,pageID:parent,requestPrimary:{primaryRequests += 1},requestProfiles:{},didClose:{})
        let quickConfig = WKWebViewConfiguration(); quickConfig.websiteDataStore = .nonPersistent()
        let quickPeek = SiteSearchProbeWeb(frame:quickF.web.frame,configuration:quickConfig)
        qs.peekPages[.quick(parent)] = PeekState(web:quickPeek,profileID:quickF.profile,spaceID:nil)
        controller.window?.contentView = quickPeek
        try qs.saveLinkRule(LinkRule(pattern:"/original",destination:.quickBrowse))
        controller.promotePeek()
        check(primaryRequests == 0 && qs.views.values.contains(where:{$0 === quickPeek}) && qs.primaryPeekView == nil, "Compact Peek destination never requests a primary window lease")
        let anotherPeek = SiteSearchProbeWeb(frame:quickF.web.frame,configuration:quickConfig)
        qs.peekPages[.quick(parent)] = PeekState(web:anotherPeek,profileID:quickF.profile,spaceID:nil); controller.window?.contentView = anotherPeek
        try qs.removeLinkRule(qs.linkRuleCatalog.entries[0].id); controller.promotePeek()
        check(primaryRequests == 1 && qs.views.values.contains(where:{$0 === anotherPeek}), "A successful Space Peek opening requests exactly one primary lease")
        controller.window?.close()
        _ = cancelTarget
        guard failures == 0 else { throw LinkRoutingInputError.failed }
    }
}
