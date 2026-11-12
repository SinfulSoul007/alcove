import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedPrivateExtensionError:Error {case missingFixture,timedOut}
@MainActor final class OwnedPrivateExtensionWindow:NSWindow {
    var closeOperation:(()->Void)?
    var fixtureKey = false
    override var isKeyWindow:Bool {fixtureKey}
    override func makeKeyAndOrderFront(_ sender:Any?) {}
    override func performClose(_ sender:Any?) {closeOperation?()}
}
@main struct ExtensionPrivateChecks {
    @available(macOS 15.4,*) @MainActor static func apiView(_ context:WKWebExtensionContext) async throws -> WKWebView {
        guard let configuration = context.webViewConfiguration else {throw OwnedPrivateExtensionError.missingFixture}
        let view = WKWebView(frame:.zero,configuration:configuration)
        view.load(URLRequest(url:context.baseURL.appendingPathComponent("options.html")))
        for _ in 0..<700 {
            if (try? await view.evaluateJavaScript("window.privateAPIReady === true")) as? Bool == true {return view}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedPrivateExtensionError.timedOut
    }
    @MainActor static func records(_ view:WKWebView,_ script:String) async throws -> [[String:Any]] {
        let raw = try await view.callAsyncJavaScript("return JSON.stringify(" + script + ");",arguments:[:],in:nil,contentWorld:.page) as! String
        return try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [[String:Any]]
    }
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<700 {
            if web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedPrivateExtensionError.timedOut
    }
    @MainActor static func marker(_ web:WKWebView) async -> String? {(try? await web.evaluateJavaScript("document.documentElement.dataset.ownedPrivateExtension || null")) as? String}
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Private extension fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedPrivateExtensionError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:91,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func canonical(_ document:BrowserDocument) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(document)}
        func exercise() async throws {
            let locked = BrowserStore(dataRoot:root.appendingPathComponent("locked"),keyProvider:{_ in throw CocoaError(.fileReadNoPermission)})
            let lockedOwner = BrowserWindowOwner(store:locked),lockedLease = try lockedOwner.acquirePrimary()
            check(locked.archiveTimer?.isValid != true,"Acquiring a window while local data is unavailable starts no normal archive work")
            let standalone = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("unassociated"),keyProvider:{_ in throw CocoaError(.fileReadNoPermission)})
            var deniedLocked = false
            do {try standalone.associateExtensions(with:lockedOwner,profileID:BrowserProfile.defaultID)} catch {deniedLocked = true}
            check(deniedLocked && standalone.extensionHosting == nil && standalone.views.isEmpty,"An unavailable normal owner cannot create a private association or request a normal controller")
            standalone.shutdown();lockedOwner.release(lockedLease)
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary()
            let profile = try normal.createProfile(name:"Owned associated account")
            try owned.register(profile);try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let source = root.appendingPathComponent("source"),staging = root.appendingPathComponent("staging")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned private fixture","description":"Private lifetime fixture","version":"1","incognito":"spanning","permissions":["tabs","storage"],"optional_permissions":["activeTab"],"host_permissions":["http://127.0.0.1/*"],"options_page":"options.html","content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["owned.js"],"run_at":"document_end"}]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("document.documentElement.dataset.ownedPrivateExtension='ran';".utf8).write(to:source.appendingPathComponent("owned.js"))
            try Data("<!doctype html><script src='options.js'></script>Owned private API fixture".utf8).write(to:source.appendingPathComponent("options.html"))
            try Data("window.seenTabs=[];browser.tabs.onCreated.addListener(t=>seenTabs.push(t));window.privateAPIReady=true;".utf8).write(to:source.appendingPathComponent("options.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:staging)
            let approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["tabs","storage"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await normal.installExtension(package,approval:approval)
            let normalURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"normal-associated")])
            let normalID = normal.newTab(url:normalURL),normalWeb = normal.view(for:normalID);try await ready(normalWeb,normalURL)
            let normalWindow = OwnedPrivateExtensionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            normalWindow.isReleasedWhenClosed = false;normal.registerExtensionWindow(normalWindow,kind:.primary)
            defer {normal.unregisterExtensionWindow(kind:.primary);normalWindow.contentView = nil;normalWindow.close()}
            let host = normal.extensionHosting as! NativeBrowserExtensionHost
            host.synchronizeBrowserState()
            let deniedContext = host.profiles[profile]!.contexts[id]!,deniedAPI = try await apiView(deniedContext)
            check(try await records(deniedAPI,"await browser.tabs.query({})").contains(where:{$0["url"] as? String == normalURL.absoluteString}),"The owned extension API sees its normal account as a positive control")
            normalWeb.configuration.userContentController.addUserScript(WKUserScript(source:"document.documentElement.dataset.normalOnly='ran';",injectionTime:.atDocumentEnd,forMainFrameOnly:true))
            let normalNext = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"normal-script-control")])
            normalWeb.load(URLRequest(url:normalNext));try await ready(normalWeb,normalNext)
            check((try await normalWeb.evaluateJavaScript("document.documentElement.dataset.normalOnly === 'ran'")) as? Bool == true,"The owned normal user-content script is a live positive control")
            _ = try await normalWeb.evaluateJavaScript("document.cookie='owned_association=A; path=/';localStorage.setItem('owned_association','A');true")
            var privateKeyRequests = 0
            let privateRoot = root.appendingPathComponent("private")
            let privateStore = BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in privateKeyRequests += 1;return key})
            defer {privateStore.shutdown()}
            try privateStore.associateExtensions(with:owner,profileID:profile)
            let privateWindow = OwnedPrivateExtensionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            privateWindow.fixtureKey = true;privateWindow.isReleasedWhenClosed = false
            privateStore.registerExtensionWindow(privateWindow,kind:.primary)
            defer {privateStore.unregisterExtensionWindow(kind:.primary);privateWindow.contentView = nil;privateWindow.close()}
            privateWindow.closeOperation = {privateStore.unregisterExtensionWindow(kind:.primary);privateStore.shutdown()}
            let borrowed = normalWeb.configuration
            let privateWeb = privateStore.view(for:privateStore.selectedID!,configuration:borrowed)
            let deniedURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-denied-owned")])
            privateWeb.load(URLRequest(url:deniedURL));try await ready(privateWeb,deniedURL)
            host.synchronizeBrowserState()
            let reference = privateStore.extensionWindows[.primary]!
            let classification = NativeExtensionWindow(host:host,store:privateStore,profileID:profile,reference:reference)
            check(classification.isPrivate(for:deniedContext),"Private classification remains true before approval so WebKit cannot cache a normal-window identity")
            let deniedTabs = try await records(deniedAPI,"await browser.tabs.query({})")
            let deniedEvents = try await records(deniedAPI,"window.seenTabs")
            check(!deniedTabs.contains(where:{$0["incognito"] as? Bool == true || $0["url"] as? String == deniedURL.absoluteString}) && !deniedEvents.contains(where:{$0["incognito"] as? Bool == true}),"Native queries and tab-created events reveal no unapproved private page")
            check(await marker(privateWeb) == nil,"Association alone cannot run an extension without explicit private approval")
            check(privateWeb.configuration.webExtensionController === normalWeb.configuration.webExtensionController,"An associated private view uses only its approved normal account controller")
            let noNormalScripts = try await privateWeb.evaluateJavaScript("document.documentElement.dataset.normalOnly === undefined") as? Bool
            let noNormalCookies = try await privateWeb.evaluateJavaScript("document.cookie === '' && localStorage.getItem('owned_association') === null") as? Bool
            check(privateWeb.configuration.userContentController !== normalWeb.configuration.userContentController && noNormalScripts == true,"Borrowing a normal configuration never imports its user-content controller or scripts into private browsing")
            check(!privateWeb.configuration.websiteDataStore.isPersistent && noNormalCookies == true,"Associated private browsing retains separate temporary cookies and website storage")
            var grant = normal.extensionRecords(profileID:profile).first!.grants!;grant.allowPrivate = true
            try normal.setExtensionGrants(id,profileID:profile,grants:grant);try await normal.prepareExtensions(profileID:profile)
            let approvedContext = host.profiles[profile]!.contexts[id]!,approvedAPI = try await apiView(approvedContext)
            host.synchronizeBrowserState()
            let approvedWindows = try await records(approvedAPI,"await browser.windows.getAll({populate:true})")
            let privateProjection = approvedWindows.first(where:{$0["incognito"] as? Bool == true})
            check(privateProjection != nil && host.nativeWindows.values.contains(where:{$0.key.storeID == privateStore.extensionStoreID}),"An approved extension sees the real associated private window with its separate client identity")
            let privateNativeTab = host.nativeTabs.values.first(where:{$0.key.storeID == privateStore.extensionStoreID && $0.key.id == privateStore.selectedID})
            check(privateNativeTab?.web === privateWeb && privateNativeTab?.url(for:approvedContext) == deniedURL,"The private tab adapter maps the live private view into the approved normal controller")
            check(privateNativeTab?.shouldGrantPermissionsOnUserGesture(for:approvedContext) == false,"A browser gesture cannot grant activeTab access that the user has not approved")
            let normalBeforeAmbiguous = try canonical(normal.makeDocument()),normalViewsBeforeAmbiguous = Set(normal.views.keys)
            let privateTabCount = privateStore.session.spaces.flatMap(\.tabs).count
            let ambiguousCreateJSON = try await approvedAPI.callAsyncJavaScript("try{return JSON.stringify({refused:false,tab:await browser.tabs.create({url:address})})}catch(e){return JSON.stringify({refused:true,error:String(e)})}",arguments:["address":deniedURL.absoluteString],in:nil,contentWorld:.page) as! String
            let ambiguousCreate = try JSONSerialization.jsonObject(with:Data(ambiguousCreateJSON.utf8)) as! [String:Any]
            let ambiguousCreateRefused = ambiguousCreate["refused"] as? Bool
            let normalAfterAmbiguousCreate = try canonical(normal.makeDocument())
            let ambiguousOptionsRefused = try await approvedAPI.callAsyncJavaScript("try{await browser.runtime.openOptionsPage();return false}catch(e){return true}",arguments:[:],in:nil,contentWorld:.page) as? Bool
            let normalAfterAmbiguous = try canonical(normal.makeDocument())
            let resolvedPrivateTab = ambiguousCreate["tab"] as? [String:Any]
            check(normalAfterAmbiguousCreate == normalBeforeAmbiguous && (ambiguousCreateRefused == true || (resolvedPrivateTab?["incognito"] as? Bool == true && privateStore.session.spaces.flatMap(\.tabs).count == privateTabCount + 1)),"A request resolved by WebKit to the focused private window cannot copy private input into the normal document")
            check(ambiguousOptionsRefused == true && normalAfterAmbiguous == normalBeforeAmbiguous && Set(normal.views.keys) == normalViewsBeforeAmbiguous,"A source-less options request cannot silently create a normal tab while private clients are open")
            if let createdID = resolvedPrivateTab?["id"] {_ = try await approvedAPI.callAsyncJavaScript("await browser.tabs.remove(tid);",arguments:["tid":createdID],in:nil,contentWorld:.page)}
            let secondPrivate = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("second-private"),keyProvider:{_ in privateKeyRequests += 1;return key})
            defer {secondPrivate.shutdown()}
            try secondPrivate.associateExtensions(with:owner,profileID:profile)
            let secondWindow = OwnedPrivateExtensionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            secondWindow.isReleasedWhenClosed = false;secondPrivate.registerExtensionWindow(secondWindow,kind:.primary)
            defer {secondPrivate.unregisterExtensionWindow(kind:.primary);secondWindow.contentView = nil;secondWindow.close()}
            secondWindow.closeOperation = {secondPrivate.unregisterExtensionWindow(kind:.primary);secondPrivate.shutdown()}
            let secondURL = fixture.appendingPathComponent("second-private-client"),secondWeb = secondPrivate.view(for:secondPrivate.selectedID!)
            _ = try await privateWeb.evaluateJavaScript("localStorage.setItem('owned-private-client','first');true")
            secondWeb.load(URLRequest(url:secondURL));try await ready(secondWeb,secondURL)
            host.synchronizeBrowserState()
            let multipleWindows = try await records(approvedAPI,"await browser.windows.getAll({populate:true})")
            let secondProjection = multipleWindows.first { window in (window["tabs"] as? [[String:Any]])?.contains(where:{$0["url"] as? String == secondURL.absoluteString}) == true }
            let isolatedSecondStorage = try await secondWeb.evaluateJavaScript("localStorage.getItem('owned-private-client') === null") as? Bool
            check(multipleWindows.filter{$0["incognito"] as? Bool == true}.count == 2 && isolatedSecondStorage == true,"Two private clients retain distinct native windows and separate temporary website storage")
            if let secondWindowID = secondProjection?["id"] {
                let firstBeforeSecond = try canonical(privateStore.makeDocument()),normalBeforeSecond = try canonical(normal.makeDocument())
                let secondCreatedURL = fixture.appendingPathComponent("created-in-second-private")
                _ = try await approvedAPI.callAsyncJavaScript("await browser.tabs.create({windowId:wid,url:address,active:false});",arguments:["wid":secondWindowID,"address":secondCreatedURL.absoluteString],in:nil,contentWorld:.page)
                let firstAfterSecond = try canonical(privateStore.makeDocument()),normalAfterSecond = try canonical(normal.makeDocument())
                check(secondPrivate.session.spaces.flatMap(\.tabs).contains(where:{$0.url == secondCreatedURL.absoluteString}) && firstAfterSecond == firstBeforeSecond && normalAfterSecond == normalBeforeSecond,"An explicit second-private-window target changes only that client")
                let retiredTab = host.nativeTabs.values.first(where:{$0.key.storeID == secondPrivate.extensionStoreID && $0.web === secondWeb})
                _ = try await approvedAPI.callAsyncJavaScript("await browser.windows.remove(wid);",arguments:["wid":secondWindowID],in:nil,contentWorld:.page)
                host.synchronizeBrowserState()
                check(secondPrivate.isShuttingDown && owner.leaseCount == 2 && !host.nativeWindows.keys.contains(where:{$0.storeID == secondPrivate.extensionStoreID}) && privateNativeTab?.web === privateWeb,"Closing one private window retires its graph and lease while the other private client stays live")
                var staleReplies = 0,staleError:Error?
                retiredTab?.loadURL(fixture.appendingPathComponent("stale-private-client"),for:approvedContext){staleReplies += 1;staleError = $0}
                check(staleReplies == 1 && staleError != nil && retiredTab?.url(for:approvedContext) == nil && privateWeb.url == deniedURL,"A retired private tab adapter cannot navigate either surviving client")
            } else {check(false,"The second private client has an actual native target window")}
            let foreignProfile = try normal.createProfile(name:"Owned foreign private account")
            try owned.register(foreignProfile);try controllers.register(normal.profiles.first(where:{$0.id == foreignProfile})!.extensionControllerID!)
            let foreignPackage = try ExtensionPackage.prepare(at:source,stagingRoot:staging)
            let foreignApproval = try normal.extensionInstallApproval(for:foreignPackage,profileID:foreignProfile,permissions:["tabs","storage"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let foreignID = try await normal.installExtension(foreignPackage,approval:foreignApproval)
            var foreignGrant = normal.extensionRecords(profileID:foreignProfile).first!.grants!;foreignGrant.allowPrivate = true
            try normal.setExtensionGrants(foreignID,profileID:foreignProfile,grants:foreignGrant);try await normal.prepareExtensions(profileID:foreignProfile)
            let foreignContext = host.profiles[foreignProfile]!.contexts[foreignID]!,foreignAPI = try await apiView(foreignContext)
            host.synchronizeBrowserState()
            let foreignTabs = try await records(foreignAPI,"await browser.tabs.query({})")
            check(!foreignTabs.isEmpty && !foreignTabs.contains(where:{$0["incognito"] as? Bool == true || $0["url"] as? String == deniedURL.absoluteString}),"Another approved account sees its own live tabs and cannot query this account's private pages")
            check(privateNativeTab?.url(for:foreignContext) == nil && classification.tabs(for:foreignContext).isEmpty,"A foreign native context cannot operate a private tab or enumerate its window")
            normal.unregisterExtensionWindow(kind:.primary);normal.closePrimaryWindowPages();owner.release(primary);normal.flush()
            let beforePrivate = try canonical(normal.makeDocument())
            check(!owner.isClosed && !normal.isShuttingDown && owner.leaseCount == 1,"The associated private window keeps its normal controller and data owner alive after the normal window closes")
            check(normal.archiveTimer?.isValid != true,"Private-only ownership pauses normal automatic tab archiving")
            let approvedURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-approved-owned")])
            privateWeb.load(URLRequest(url:approvedURL));try await ready(privateWeb,approvedURL)
            check(await marker(privateWeb) == "ran","Explicit private approval enables the real native content script after the normal window closes")
            _ = try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value='keep this private form';true")
            check(try canonical(normal.makeDocument()) == beforePrivate,"Private browsing never serializes its URL or transient session into the normal account")
            check(privateKeyRequests == 0 && !manager.fileExists(atPath:privateRoot.path),"Associated private browsing requests no key and writes no private metadata directory")
            if let windowID = privateProjection?["id"] as? NSNumber {
                let createdURL = fixture.appendingPathComponent("created-private")
                let raw = try await approvedAPI.callAsyncJavaScript("return JSON.stringify(await browser.tabs.create({windowId:wid,url:address,active:false}));",arguments:["wid":windowID,"address":createdURL.absoluteString],in:nil,contentWorld:.page) as! String
                let created = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
                check(created["incognito"] as? Bool == true && privateStore.session.spaces.flatMap(\.tabs).contains(where:{$0.url == createdURL.absoluteString}),"Explicit private-window tab creation changes only the temporary private client")
                let updatedURL = fixture.appendingPathComponent("updated-private")
                _ = try await approvedAPI.callAsyncJavaScript("await browser.tabs.update(tid,{url:address});",arguments:["tid":created["id"]!,"address":updatedURL.absoluteString],in:nil,contentWorld:.page)
                let updatedTab = privateStore.session.spaces.flatMap(\.tabs).first(where:{$0.url == updatedURL.absoluteString})!
                try await ready(privateStore.views[updatedTab.id]!,updatedURL)
                check(privateStore.views[updatedTab.id]?.configuration.websiteDataStore.isPersistent == false,"Private native URL updates retain the actual nonpersistent website store")
                let duplicateRaw = try await approvedAPI.callAsyncJavaScript("return JSON.stringify(await browser.tabs.duplicate(tid,{active:false}));",arguments:["tid":created["id"]!],in:nil,contentWorld:.page) as! String
                let duplicate = try JSONSerialization.jsonObject(with:Data(duplicateRaw.utf8)) as! [String:Any]
                check(duplicate["incognito"] as? Bool == true && privateStore.session.spaces.flatMap(\.tabs).filter({$0.url == updatedURL.absoluteString}).count == 2,"Private duplication creates another temporary private tab rather than a saved normal tab")
                check(try canonical(normal.makeDocument()) == beforePrivate,"Private API tab creation never copies its URL into the normal encrypted document")
                _ = try await approvedAPI.callAsyncJavaScript("await browser.tabs.update(tid,{pinned:true});await browser.tabs.remove([tid,copy]);",arguments:["tid":created["id"]!,"copy":duplicate["id"]!],in:nil,contentWorld:.page)
                check(!privateStore.session.spaces.flatMap(\.tabs).contains(where:{$0.url == updatedURL.absoluteString}),"Private native pin and close actions operate on the actual private tab")
            } else {check(false,"Private native tab creation has a real private target window")}
            let privateBeforeOptions = try canonical(privateStore.makeDocument()),privateViewsBeforeOptions = Set(privateStore.views.keys)
            var optionsRefused = false
            do {_ = try await privateStore.openExtensionOptions(id,profileID:BrowserProfile.defaultID)}
            catch ExtensionHostError.unsupportedPrivatePage {optionsRefused = true}
            let privateAfterOptions = try canonical(privateStore.makeDocument())
            check(optionsRefused && Set(privateStore.views.keys) == privateViewsBeforeOptions && privateAfterOptions == privateBeforeOptions,"Private options refuse an incompatible native configuration before creating a tab or replacing a document")
            check(try canonical(normal.makeDocument()) == beforePrivate,"Refused private options do not open a normal window or write a tab into normal metadata")
            grant.permissions.append("activeTab");try normal.setExtensionGrants(id,profileID:profile,grants:grant);try await normal.prepareExtensions(profileID:profile)
            let gestureContext = host.profiles[profile]!.contexts[id]!
            check(privateNativeTab?.shouldGrantPermissionsOnUserGesture(for:gestureContext) == true,"Explicit activeTab approval enables the native gesture capability in the current context")
            grant.allowPrivate = false;try normal.setExtensionGrants(id,profileID:profile,grants:grant)
            check((try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value === 'keep this private form'")) as? Bool == true,"Revoking private access keeps the current unsaved form mounted")
            let revokedURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-revoked-owned")])
            privateWeb.load(URLRequest(url:revokedURL));try await ready(privateWeb,revokedURL)
            check(await marker(privateWeb) == nil,"Revoked private access blocks extension code in the next private document")
            check(privateNativeTab?.url(for:approvedContext) == nil && classification.isPrivate(for:approvedContext),"Revoked adapters expose no private URL while retaining immutable privacy classification")
            privateStore.shutdown()
            check(owner.isClosed && normal.isShuttingDown && owner.leaseCount == 0,"Closing the last private association releases its auxiliary owner lease and normal writer")
        }
        do {try await exercise()} catch {check(false,"Owned private extension fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Private fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Private fixtures release only their owned named website stores")
        print("Extension private checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
