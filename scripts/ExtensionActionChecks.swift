import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedExtensionActionError:Error {case missingFixture,timedOut,presentationFailed}
@MainActor final class OwnedExtensionActionWindow:NSWindow {
    var fixtureKey = true
    override var isKeyWindow:Bool {fixtureKey}
    override func makeKeyAndOrderFront(_ sender:Any?) {}
}
/// Hold only the external engine's presentation callback. Its action, context,
/// popup web view, browser windows and completion are the real native objects.
@available(macOS 15.4,*) @MainActor final class OwnedActionCallbackGate:NSObject,WKWebExtensionControllerDelegate {
    weak var host:NativeBrowserExtensionHost?
    var pending:[(WKWebExtensionController,WKWebExtension.Action,WKWebExtensionContext,(Error?)->Void)] = []
    var replies = 0,lastError:Error?
    init(host:NativeBrowserExtensionHost) {self.host = host}
    func webExtensionController(_ controller:WKWebExtensionController,openWindowsFor context:WKWebExtensionContext) -> [any WKWebExtensionWindow] {host?.webExtensionController(controller,openWindowsFor:context) ?? []}
    func webExtensionController(_ controller:WKWebExtensionController,focusedWindowFor context:WKWebExtensionContext) -> (any WKWebExtensionWindow)? {host?.webExtensionController(controller,focusedWindowFor:context)}
    func webExtensionController(_ controller:WKWebExtensionController,presentActionPopup action:WKWebExtension.Action,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {pending.append((controller,action,context,completionHandler))}
    func deliverNext() {
        guard !pending.isEmpty,let host else {return}
        let value = pending.removeFirst()
        host.webExtensionController(value.0,presentActionPopup:value.1,for:value.2){ [self] error in replies += 1;lastError = error;value.3(error)}
    }
    func cancelAll() {for value in pending {value.3(ExtensionHostError.closed)};pending = []}
}
@main struct ExtensionActionChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<700 {
            if web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionActionError.timedOut
    }
    @MainActor static func waitFor(_ condition:@escaping @MainActor ()->Bool) async throws {
        for _ in 0..<700 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        throw OwnedExtensionActionError.timedOut
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Extension action fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedExtensionActionError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:139,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func canonical(_ document:BrowserDocument) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(document)}
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let owner = BrowserWindowOwner(store:store),primary = try owner.acquirePrimary()
            defer {owner.release(primary)}
            let profile = try store.createProfile(name:"Owned action account")
            try owned.register(profile);try controllers.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let source = root.appendingPathComponent("source")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned actions","description":"Action lifetime fixture","version":"1","permissions":["storage","activeTab"],"host_permissions":["http://127.0.0.1/*"],"action":{"default_title":"Owned action","default_popup":"popup.html"},"background":{"service_worker":"background.js"},"options_page":"options.html"}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><body data-owned-extension-page='ready'>Owned options".utf8).write(to:source.appendingPathComponent("options.html"))
            try Data("<!doctype html><body style='width:320px;height:180px'>Owned popup<input id='popup-form'><script src='popup.js'></script>".utf8).write(to:source.appendingPathComponent("popup.html"))
            try Data("window.ownedPopupReady=true;".utf8).write(to:source.appendingPathComponent("popup.js"))
            try Data("browser.action.onClicked.addListener(async t=>{await browser.storage.local.set({ownedActionClicked:t.incognito?'private':'normal'});});".utf8).write(to:source.appendingPathComponent("background.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging"))
            let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","activeTab"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await store.installExtension(package,approval:approval)
            let url = fixture.appendingPathComponent("action-source"),tabID = store.newTab(url:url),web = store.view(for:tabID)
            try await ready(web,url)
            _ = try await web.evaluateJavaScript("document.cookie='owned_action_cookie=normal; path=/';localStorage.setItem('owned_action_site','normal');true")
            let window = OwnedExtensionActionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame:NSRect(x:0,y:0,width:800,height:600)),anchor = NSButton(frame:NSRect(x:748,y:560,width:32,height:32))
            web.frame = content.bounds;content.addSubview(web);content.addSubview(anchor);window.contentView = content
            store.registerExtensionWindow(window,kind:.primary)
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            let optionsID = try await store.openExtensionOptions(id,profileID:profile),options = store.views[optionsID]!
            let host = store.extensionHosting as! NativeBrowserExtensionHost,controller = host.profiles[profile]!.controller,context = host.profiles[profile]!.contexts[id]!
            try await ready(options,context.optionsPageURL!);store.select(tabID);host.synchronizeBrowserState()
            _ = try await options.callAsyncJavaScript("localStorage.setItem('owned_action_setting','normal-extension-setting');await browser.action.setTitle({title:'Owned current action'});await browser.action.setBadgeText({text:'7'});return true;",arguments:[:],in:nil,contentWorld:.page)
            let summaries = store.extensionActionSummaries(for:web)
            check(summaries.count == 1 && summaries.first?.id == id && summaries.first?.label == "Owned current action" && summaries.first?.badge == "7" && summaries.first?.isEnabled == true,"Action summaries read the owning context's actual current label, badge and enabled state")
            var presentations = 0,lastAnchor:NSView?,lastPresentedAction:WKWebExtension.Action?
            weak var popup:WKWebView?
            host.actionPresenter = NativeExtensionActionPresenter(present:{action,view in presentations += 1;lastAnchor = view;lastPresentedAction = action;popup = action.popupWebView})
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep action source';true")
            let before = try canonical(store.makeDocument())
            try store.performExtensionAction(id,from:web,anchor:anchor)
            try store.performExtensionAction(id,from:web,anchor:anchor)
            try await waitFor{presentations == 1}
            guard let popup else {throw OwnedExtensionActionError.missingFixture}
            check(lastAnchor === anchor && popup.configuration.websiteDataStore.identifier == profile && popup.url?.host == context.baseURL.host,"The real native popup uses its source anchor, extension origin and owning account website store")
            check((try await popup.evaluateJavaScript("window.ownedPopupReady === true")) as? Bool == true,"The presented popup is the actual loaded owned extension page")
            let after = try canonical(store.makeDocument()),keptForm = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'keep action source'") as? Bool
            check(after == before && store.views[tabID] === web && keptForm == true,"Opening an action popup keeps the source tab, encrypted document and unsaved form intact")
            let tab = host.nativeTabs.values.first(where:{$0.web === web})!
            check(context.hasActiveUserGesture(in:tab),"Performing the actual source action registers the native user gesture for that tab")
            let actualAction = context.action(for:tab)!,foreignController = WKWebExtensionController(configuration:.nonPersistent())
            var foreignReplies = 0,foreignError:Error?
            host.webExtensionController(foreignController,presentActionPopup:actualAction,for:context){foreignReplies += 1;foreignError = $0}
            check(foreignReplies == 1 && foreignError != nil && actualAction.popupWebView === popup && host.actionJobs.count == 1,"A foreign popup callback cannot close or replace another controller's live action page")
            var duplicateReplies = 0,duplicateError:Error?
            host.webExtensionController(controller,presentActionPopup:actualAction,for:context){duplicateReplies += 1;duplicateError = $0}
            check(duplicateReplies == 1 && duplicateError != nil && actualAction.popupWebView === popup && presentations == 1,"A repeated native callback completes once without reopening or closing the shown action")
            try store.performExtensionAction(id,from:web,anchor:anchor)
            check(host.actionJobs.isEmpty && presentations == 1,"Clicking the source action again closes its existing popup")
            try store.performExtensionAction(id,from:web,anchor:anchor);try await waitFor{presentations == 2}
            store.webView(web,didStartProvisionalNavigation:nil)
            check(host.actionJobs.isEmpty,"The actual navigation-start delegate closes the source popup before another actor turn")
            let changed = fixture.appendingPathComponent("action-source-next-document")
            web.load(URLRequest(url:changed));try await ready(web,changed);host.synchronizeBrowserState()
            check(host.actionJobs.isEmpty,"Source navigation closes and releases its native action presentation")
            let detached = NSButton(frame:.zero)
            var rejectedAnchor = false
            do {try store.performExtensionAction(id,from:web,anchor:detached)} catch {rejectedAnchor = true}
            check(rejectedAnchor && presentations == 2,"A detached action anchor cannot borrow another window for popup presentation")
            let otherAnchorWindow = OwnedExtensionActionWindow(contentRect:NSRect(x:0,y:0,width:400,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false),otherAnchor = NSButton(frame:NSRect(x:0,y:0,width:32,height:32))
            otherAnchorWindow.isReleasedWhenClosed = false;otherAnchorWindow.contentView = otherAnchor
            defer {otherAnchorWindow.contentView = nil;otherAnchorWindow.close()}
            var rejectedOtherWindow = false
            do {try store.performExtensionAction(id,from:web,anchor:otherAnchor)} catch {rejectedOtherWindow = true}
            check(rejectedOtherWindow && presentations == 2,"An action cannot borrow an attached anchor from another native window")
            var staleReplies = 0,staleError:Error?
            host.webExtensionController(controller,presentActionPopup:actualAction,for:context){staleReplies += 1;staleError = $0}
            check(staleReplies == 1 && staleError != nil && host.actionJobs.isEmpty && presentations == 2,"An unrequested native popup cannot infer a new source after its prior document navigates")
            let normalPresenter = host.actionPresenter
            var failedPresentations = 0
            host.actionPresenter = NativeExtensionActionPresenter(present:{_,_ in failedPresentations += 1;throw OwnedExtensionActionError.presentationFailed})
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep failed action';true")
            let beforeFailedPresentation = try canonical(store.makeDocument())
            try store.performExtensionAction(id,from:web,anchor:anchor);try await waitFor{failedPresentations == 1}
            let afterFailedPresentation = try canonical(store.makeDocument()),failedForm = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'keep failed action'") as? Bool
            check(host.actionJobs.isEmpty && beforeFailedPresentation == afterFailedPresentation && failedForm == true,"A failed native presentation releases its popup and preserves the source document and form")
            host.actionPresenter = normalPresenter
            let callbackGate = OwnedActionCallbackGate(host:host)
            controller.delegate = callbackGate
            defer {callbackGate.cancelAll();controller.delegate = host}
            host.actionPreparationTimeout = .seconds(1);store.message = nil
            try store.performExtensionAction(id,from:web,anchor:anchor)
            try await waitFor{callbackGate.pending.count == 1}
            check(!host.actionJobs.isEmpty,"An actual native popup waits for its captured external presentation callback")
            try await waitFor{host.actionJobs.isEmpty}
            controller.delegate = host;callbackGate.deliverNext()
            check(presentations == 2 && store.message == ExtensionHostError.timedOut.localizedDescription && callbackGate.replies == 1 && callbackGate.lastError != nil,"A timed-out popup denies its delayed real native callback exactly once without presenting")
            host.actionPreparationTimeout = .seconds(15)
            let foreign = try store.createProfile(name:"Owned foreign action account")
            try owned.register(foreign);try controllers.register(store.profiles.first(where:{$0.id == foreign})!.extensionControllerID!)
            let foreignURL = fixture.appendingPathComponent("foreign-action-source"),foreignID = store.newTab(url:foreignURL),foreignWeb = store.view(for:foreignID)
            try await ready(foreignWeb,foreignURL)
            var rejectedForeign = false
            do {try store.performExtensionAction(id,from:foreignWeb,anchor:anchor)} catch {rejectedForeign = true}
            check(rejectedForeign && presentations == 2 && foreignWeb.url == foreignURL,"An extension action cannot switch into another account's actual source view")
            store.selectSpace(store.session.spaces.first(where:{$0.effectiveProfileID == profile})!.id);store.select(tabID)
            try store.performExtensionAction(id,from:web,anchor:anchor);try await waitFor{presentations == 3}
            try store.setExtensionEnabled(id,profileID:profile,enabled:false)
            check(host.actionJobs.isEmpty,"Disabling an extension closes its live popup before another action can run")
            try store.setExtensionEnabled(id,profileID:profile,enabled:true);try await store.prepareExtensions(profileID:profile)
            var grant = store.extensionRecords(profileID:profile).first!.grants!;grant.allowPrivate = true
            try store.setExtensionGrants(id,profileID:profile,grants:grant);try await store.prepareExtensions(profileID:profile)
            let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in throw CocoaError(.fileReadNoPermission)})
            defer {privateStore.shutdown()}
            try privateStore.associateExtensions(with:owner,profileID:profile)
            let privateURL = fixture.appendingPathComponent("private-action-source"),privateWeb = privateStore.view(for:privateStore.selectedID!)
            privateWeb.load(URLRequest(url:privateURL));try await ready(privateWeb,privateURL)
            let privateWindow = OwnedExtensionActionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            privateWindow.isReleasedWhenClosed = false;privateWindow.contentView = privateWeb;privateStore.registerExtensionWindow(privateWindow,kind:.primary)
            defer {privateStore.unregisterExtensionWindow(kind:.primary);privateWindow.contentView = nil;privateWindow.close()}
            host.synchronizeBrowserState()
            let initiallyIsolated = try await privateWeb.evaluateJavaScript("document.cookie === '' && localStorage.getItem('owned_action_site') === null") as? Bool
            check(initiallyIsolated == true,"The private action source begins with no normal website cookie or local storage")
            _ = try await privateWeb.evaluateJavaScript("document.cookie='owned_action_cookie=private; path=/';localStorage.setItem('owned_action_site','private');document.getElementById('owned-form').value='keep private action form';true")
            let privateBefore = try canonical(store.makeDocument()),privateSummary = privateStore.extensionActionSummaries(for:privateWeb)
            check(privateSummary.first?.isEnabled == true,"An explicitly private-approved spanning extension exposes its native action")
            try privateStore.performExtensionAction(id,from:privateWeb,anchor:privateWeb);try await waitFor{presentations == 4}
            guard let privatePopup = lastPresentedAction?.popupWebView else {throw OwnedExtensionActionError.missingFixture}
            let sharedSetting = try await privatePopup.evaluateJavaScript("localStorage.getItem('owned_action_setting') === 'normal-extension-setting'") as? Bool
            check(lastAnchor === privateWeb && privatePopup.configuration.websiteDataStore.identifier == profile && sharedSetting == true,"A private source presents the real spanning extension interface with its existing profile settings")
            let privateAfter = try canonical(store.makeDocument()),privateForm = try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value === 'keep private action form' && document.cookie.includes('owned_action_cookie=private') && !document.cookie.includes('owned_action_cookie=normal') && localStorage.getItem('owned_action_site') === 'private'") as? Bool
            check(privateBefore == privateAfter && privateForm == true && !privateWeb.configuration.websiteDataStore.isPersistent && privateWeb.configuration.websiteDataStore === privateStore.privateDataStore,"The private popup preserves the private website's temporary store, cookies, form and normal encrypted document")
            try privateStore.performExtensionAction(id,from:privateWeb,anchor:privateWeb)
            check(host.actionJobs.isEmpty,"The approved private action toggles only its own native popup")
            let currentContext = host.profiles[profile]!.contexts[id]!,currentOptionsID = try await store.openExtensionOptions(id,profileID:profile),currentOptions = store.views[currentOptionsID]!
            try await ready(currentOptions,currentContext.optionsPageURL!);store.select(tabID)
            _ = try await currentOptions.callAsyncJavaScript("await browser.action.setPopup({popup:''});return true;",arguments:[:],in:nil,contentWorld:.page)
            try store.performExtensionAction(id,from:web,anchor:anchor)
            var clicked = false
            for _ in 0..<700 {
                clicked = (try? await currentOptions.callAsyncJavaScript("return (await browser.storage.local.get('ownedActionClicked')).ownedActionClicked === 'normal';",arguments:[:],in:nil,contentWorld:.page)) as? Bool == true
                if clicked {break};try await Task.sleep(for:.milliseconds(10))
            }
            check(clicked && presentations == 4 && host.actionJobs.isEmpty,"An action without a popup runs the actual background click handler for its source tab")
            let beforePrivateClick = try canonical(store.makeDocument())
            try privateStore.performExtensionAction(id,from:privateWeb,anchor:privateWeb)
            var privateClicked = false
            for _ in 0..<700 {
                privateClicked = (try? await currentOptions.callAsyncJavaScript("return (await browser.storage.local.get('ownedActionClicked')).ownedActionClicked === 'private';",arguments:[:],in:nil,contentWorld:.page)) as? Bool == true
                if privateClicked {break};try await Task.sleep(for:.milliseconds(10))
            }
            let afterPrivateClick = try canonical(store.makeDocument())
            check(privateClicked && beforePrivateClick == afterPrivateClick && presentations == 4 && host.actionJobs.isEmpty,"A private no-popup action reaches the real background handler with its private tab flag and no saved session changes")
            _ = try await currentOptions.callAsyncJavaScript("await browser.action.setPopup({popup:'popup.html'});return true;",arguments:[:],in:nil,contentWorld:.page)
            try privateStore.performExtensionAction(id,from:privateWeb,anchor:privateWeb);try await waitFor{presentations == 5}
            grant.allowPrivate = false
            try store.setExtensionGrants(id,profileID:profile,grants:grant)
            var deniedPrivate = false
            do {try privateStore.performExtensionAction(id,from:privateWeb,anchor:privateWeb)} catch {deniedPrivate = true}
            check(host.actionJobs.isEmpty && deniedPrivate && privateStore.extensionActionSummaries(for:privateWeb).isEmpty,"Revoking private approval closes its current popup and denies another action synchronously")
            privateStore.unregisterExtensionWindow(kind:.primary);privateStore.shutdown()
            try await store.prepareExtensions(profileID:profile)
            let quickID = try store.openQuickPage(url:fixture.appendingPathComponent("quick-action-source"),profileID:profile,intendedSpaceID:store.session.spaces.first(where:{$0.effectiveProfileID == profile})!.id),quickWeb = store.view(for:quickID)
            try await ready(quickWeb,fixture.appendingPathComponent("quick-action-source"))
            let quickWindow = OwnedExtensionActionWindow(contentRect:NSRect(x:0,y:0,width:500,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            quickWindow.isReleasedWhenClosed = false;quickWindow.contentView = quickWeb;store.registerExtensionWindow(quickWindow,kind:.quick(quickID))
            defer {store.unregisterExtensionWindow(kind:.quick(quickID));quickWindow.contentView = nil;quickWindow.close()}
            try store.performExtensionAction(id,from:quickWeb,anchor:quickWeb);try await waitFor{presentations == 6}
            check(lastAnchor === quickWeb,"A Quick window action presents from its actual compact page and window")
            NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:quickWindow)
            check(host.actionJobs.isEmpty && store.views[tabID] === web,"Closing the actual compact source window releases its action without closing the main page")
            store.unregisterExtensionWindow(kind:.quick(quickID));try store.closeQuickPage(quickID);quickWindow.contentView = nil
            try store.performExtensionAction(id,from:web,anchor:anchor);try await waitFor{presentations == 7}
            let retiringContext = host.profiles[profile]!.contexts[id]!
            store.extensionHosting = nil;host.synchronizeBrowserState()
            check(host.actionJobs.isEmpty && store.views[tabID] === web,"Detaching a native host invalidates its old popup while keeping the website mounted")
            check(!host.authorized(retiringContext,profileID:profile,client:store) && tab.url(for:retiringContext) == nil,"A detached native host cannot retain authority over its former account's actual tab")
            check(!retiringContext.isLoaded && retiringContext.currentPermissions.isEmpty,"Retiring the active host unloads its actual native context and revokes engine permissions")
        }
        func privateOnlyExercise() async throws {
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("private-only-normal"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary(),profile = try normal.createProfile(name:"Owned private-only actions")
            defer {owner.release(primary)}
            try owned.register(profile);try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("private-only-staging"))
            let approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","activeTab"],hostPatterns:["http://127.0.0.1/*"],allowPrivate:true,enable:true)
            let id = try await normal.installExtension(package,approval:approval)
            try await normal.prepareExtensions(profileID:profile)
            var keyRequests = 0,normalWindowRequests = 0,presentations = 0
            let privateRoot = root.appendingPathComponent("private-only-client"),client = BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in keyRequests += 1;throw CocoaError(.fileReadNoPermission)})
            defer {client.shutdown()}
            try client.associateExtensions(with:owner,profileID:profile)
            let window = OwnedExtensionActionWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false),web = client.view(for:client.selectedID!)
            window.isReleasedWhenClosed = false;window.contentView = web;client.registerExtensionWindow(window,kind:.primary)
            defer {client.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            let url = fixture.appendingPathComponent("private-only-action")
            web.load(URLRequest(url:url));try await ready(web,url)
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='private only kept';true")
            let host = normal.extensionHosting as! NativeBrowserExtensionHost
            host.actionPresenter = NativeExtensionActionPresenter(present:{_,anchor in presentations += 1;check(anchor === web,"A private-only popup retains its actual private source anchor")})
            normal.extensionPrimaryWindowRequested = {normalWindowRequests += 1}
            normal.closePrimaryWindowPages();owner.release(primary);host.synchronizeBrowserState()
            let before = try canonical(normal.makeDocument())
            try client.performExtensionAction(id,from:web,anchor:web);try await waitFor{presentations == 1}
            let after = try canonical(normal.makeDocument()),form = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'private only kept'") as? Bool
            check(before == after && normalWindowRequests == 0 && normal.extensionWindows[.primary] == nil && !owner.isClosed && owner.leaseCount == 1 && form == true,"A private-only extension popup works through its auxiliary owner without opening or modifying a normal window")
            check(keyRequests == 0 && !manager.fileExists(atPath:privateRoot.path),"A private-only popup requests no private key and creates no private metadata directory")
            client.shutdown()
            check(owner.isClosed && normal.isShuttingDown && host.actionJobs.isEmpty,"Closing the last private-only window releases its popup, controller and owner lease")
        }
        do {try await exercise();try await privateOnlyExercise()} catch {check(false,"Owned action fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Action fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Action fixtures release only their owned named website stores")
        print("Extension action checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
