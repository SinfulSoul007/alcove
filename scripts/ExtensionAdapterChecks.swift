import AppKit
import WebKit
import CryptoKit
import BrowserCore

/// These native windows stay hidden and suppress activation; only fixture web views are hosted.
@MainActor final class OwnedExtensionWindow:NSWindow {
    var closeOperation:(()->Void)?
    override func makeKeyAndOrderFront(_ sender:Any?) {}
    override func performClose(_ sender:Any?) {closeOperation?()}
}
enum OwnedExtensionAdapterError:Error {case missingFixture,timedOut,missingTab}

@main struct ExtensionAdapterChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL? = nil) async throws {
        for _ in 0..<700 {
            if url == nil || web.url == url,
               (try? await web.evaluateJavaScript(url == nil ? "window.ownedExtensionReady === true" : "document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionAdapterError.timedOut
    }
    @MainActor static func query(_ web:WKWebView) async throws -> [[String:Any]] {
        let value = try await web.callAsyncJavaScript("return JSON.stringify(await browser.tabs.query({}));",arguments:[:],in:nil,contentWorld:.page) as! String
        return try JSONSerialization.jsonObject(with:Data(value.utf8)) as! [[String:Any]]
    }
    @MainActor static func readyTab(_ store:BrowserStore,id:UUID,url:URL,extensionPage:Bool) async throws -> WKWebView {
        for _ in 0..<700 {
            if let web = store.views[id],web.url == url,!web.isLoading,
               (try? await web.evaluateJavaScript(extensionPage ? "window.ownedExtensionReady === true" : "document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return web}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionAdapterError.timedOut
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Native adapter fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"], let fixture = URL(string:address) else {throw OwnedExtensionAdapterError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:55,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let a = try store.createProfile(name:"Owned adapters A"),spaceA = store.space.id
            try owned.register(a);try controllers.register(store.profiles.first(where:{$0.id == a})!.extensionControllerID!)
            let urlA = fixture.appending(queryItems:[URLQueryItem(name:"account",value:"A")])
            let tabA = store.newTab(url:urlA),webA = store.view(for:tabA);try await ready(webA,urlA)
            let b = try store.createProfile(name:"Owned adapters B")
            try owned.register(b);try controllers.register(store.profiles.first(where:{$0.id == b})!.extensionControllerID!)
            let urlB = fixture.appending(queryItems:[URLQueryItem(name:"account",value:"B")])
            let tabB = store.newTab(url:urlB),webB = store.view(for:tabB);try await ready(webB,urlB)
            store.selectSpace(spaceA)
            let window = OwnedExtensionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = webA
            store.registerExtensionWindow(window,kind:.primary)
            defer {window.contentView = nil;store.unregisterExtensionWindow(kind:.primary)}
            let source = root.appendingPathComponent("source"),staging = root.appendingPathComponent("staging")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned adapter extension","description":"Owned API fixture","version":"1","permissions":["tabs","storage"],"host_permissions":["http://127.0.0.1/*"],"options_page":"options.html"}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><html><head><script src='options.js'></script></head><body>Owned options</body></html>".utf8).write(to:source.appendingPathComponent("options.html"))
            try Data("window.ownedExtensionReady=true;".utf8).write(to:source.appendingPathComponent("options.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:staging)
            let approval = try store.extensionInstallApproval(for:package,profileID:a,permissions:["tabs","storage"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await store.installExtension(package,approval:approval)
            let optionsID = try await store.openExtensionOptions(id,profileID:a),options = store.views[optionsID]!
            try await ready(options)
            let tabs = try await query(options),urls = tabs.compactMap{$0["url"] as? String}
            check(urls.contains(urlA.absoluteString) && !urls.contains(urlB.absoluteString),"The real browser.tabs.query API sees its owning account and excludes another account on the same website")
            check(options.configuration.webExtensionController === webA.configuration.webExtensionController,"Options uses the loaded context's own specialized configuration and account controller")
            let nativeA = webA.configuration.webExtensionController!,contextA = nativeA.extensionContexts.first!
            let record = store.extensionRecords(profileID:a).first!
            let packageB = try ExtensionPackage.prepare(at:source,stagingRoot:staging)
            _ = try ExtensionPackage.publish(packageB,profileID:b,extensionID:record.packageID ?? record.id,packagesRoot:store.extensionPackagesRoot)
            // Equal extension IDs in two accounts are valid recovery input; grants are approved separately.
            var clone = record;clone.enabled = false;clone.grants = nil
            var candidate = store.makeDocument(),libraryB = candidate.library(for:b);libraryB.extensions = [clone];candidate.setLibrary(libraryB,for:b)
            try store.commitProfileDocument(candidate)
            let grantB = ExtensionGrantSet(profileID:b,recordID:id,controllerID:store.profiles.first(where:{$0.id == b})!.extensionControllerID!,packageDigest:record.packageDigest,permissions:["tabs","storage"],hostPatterns:["http://127.0.0.1/*"])
            try store.setExtensionGrants(id,profileID:b,grants:grantB);try store.setExtensionEnabled(id,profileID:b,enabled:true)
            _ = try await options.callAsyncJavaScript("await browser.storage.local.set({ownedAccount:'A'});return true;",arguments:[:],in:nil,contentWorld:.page)
            let optionsBID = try await store.openExtensionOptions(id,profileID:b),optionsB = store.views[optionsBID]!
            try await ready(optionsB)
            let missing = try await optionsB.callAsyncJavaScript("return !Object.hasOwn(await browser.storage.local.get('ownedAccount'),'ownedAccount');",arguments:[:],in:nil,contentWorld:.page) as? Bool
            check(missing == true && optionsB.url == options.url,"Identical extension origins and runtime IDs retain separate native storage in different accounts")
            let retained = try await options.callAsyncJavaScript("return (await browser.storage.local.get('ownedAccount')).ownedAccount;",arguments:[:],in:nil,contentWorld:.page) as? String
            check(retained == "A","The original account retains its actual native extension storage while the other account remains empty")
            let contextB = webB.configuration.webExtensionController!.extensionContexts.first!
            guard let candidateAdapter = contextA.openWindows.first?.tabs?(for:contextA).first(where:{$0.webView?(for:contextA) === webA}),let adapterA = candidateAdapter as? NativeExtensionTab else {throw OwnedExtensionAdapterError.missingTab}
            var deniedReplies = 0,deniedError:Error?
            adapterA.loadURL(urlB,for:contextB) {deniedReplies += 1;deniedError = $0}
            check(deniedReplies == 1 && deniedError != nil && webA.url == urlA,"A foreign extension context cannot operate an actual tab adapter from another account")
            let apiTabA = tabs.first(where:{$0["url"] as? String == urlA.absoluteString})!["id"] as! NSNumber
            let changed = fixture.appending(queryItems:[URLQueryItem(name:"account",value:"A-api-update")])
            _ = try await options.callAsyncJavaScript("return await browser.tabs.update(tabID,{url:nextURL});",arguments:["tabID":apiTabA,"nextURL":changed.absoluteString],in:nil,contentWorld:.page)
            try await ready(webA,changed)
            check(store.views[tabA] === webA && webA.url == changed,"Real extension tab updates navigate the existing account view")
            store.selectSpace(spaceA);store.select(optionsID)
            let selectedBefore = store.selectedID
            let createdJSON = try await options.callAsyncJavaScript("return JSON.stringify(await browser.tabs.create({url:nextURL,active:false}));",arguments:["nextURL":fixture.appending(queryItems:[URLQueryItem(name:"account",value:"A-created")]).absoluteString],in:nil,contentWorld:.page) as! String
            let created = try JSONSerialization.jsonObject(with:Data(createdJSON.utf8)) as! [String:Any]
            check(created["id"] != nil && store.selectedID == selectedBefore,"An extension can create a real inactive tab without stealing the selected page")
            do {
                let beforeViews = Set(store.views.keys)
                let boundaryJSON = try await options.callAsyncJavaScript("return JSON.stringify(await browser.tabs.create({url:browser.runtime.getURL('options.html'),active:false}));",arguments:[:],in:nil,contentWorld:.page) as! String
                let boundary = try JSONSerialization.jsonObject(with:Data(boundaryJSON.utf8)) as! [String:Any]
                guard let boundaryID = Set(store.views.keys).subtracting(beforeViews).first,let specialized = store.views[boundaryID],let boundaryAPIID = boundary["id"] as? NSNumber else {throw OwnedExtensionAdapterError.missingTab}
                try await ready(specialized)
                let website = fixture.appending(queryItems:[URLQueryItem(name:"account",value:"A-extension-to-web")])
                _ = try await options.callAsyncJavaScript("return await browser.tabs.update(tabID,{url:nextURL});",arguments:["tabID":boundaryAPIID,"nextURL":website.absoluteString],in:nil,contentWorld:.page)
                let ordinary = try await readyTab(store,id:boundaryID,url:website,extensionPage:false)
                check(ordinary !== specialized,"An extension-origin tab can leave for a website using an ordinary WebKit view")
                let pageAPI = try await ExtensionBoundedResult<Any?>().run(seconds:3) {
                    try await ordinary.callAsyncJavaScript("const b=globalThis.browser;const r={type:typeof b,keys:b?Object.getOwnPropertyNames(b):[],tabs:typeof b?.tabs,storage:typeof b?.storage,runtimeID:b?.runtime?.id??null,storageRead:false,tabQuery:false};if(b?.storage?.local){try{r.value=await b.storage.local.get('ownedAccount');r.storageRead=true}catch(e){r.storageError=String(e)}}if(b?.tabs?.query){try{r.tabsResult=await b.tabs.query({});r.tabQuery=true}catch(e){r.tabError=String(e)}}return JSON.stringify(r);",arguments:[:],in:nil,contentWorld:.page)
                }
                guard let pageJSON = pageAPI as? String,let publicPage = try JSONSerialization.jsonObject(with:Data(pageJSON.utf8)) as? [String:Any] else {throw OwnedExtensionAdapterError.missingFixture}
                check(publicPage["storageRead"] as? Bool == false && publicPage["tabQuery"] as? Bool == false && publicPage["runtimeID"] is NSNull,"The destination website cannot access extension storage, tabs or runtime identity")
                let websiteID = try await query(options).first(where:{$0["url"] as? String == website.absoluteString})?["id"] as? NSNumber
                check(websiteID == boundaryAPIID,"Changing WebKit view configuration preserves the actual browser tab identity")
                store.selectSpace(store.session.spaces.first(where:{$0.effectiveProfileID == b})!.id)
                _ = try await options.callAsyncJavaScript("return await browser.tabs.update(tabID,{url:browser.runtime.getURL('options.html')});",arguments:["tabID":boundaryAPIID],in:nil,contentWorld:.page)
                let back = try await readyTab(store,id:boundaryID,url:contextA.optionsPageURL!,extensionPage:true)
                let sameAccount = try await back.callAsyncJavaScript("return (await browser.storage.local.get('ownedAccount')).ownedAccount === 'A';",arguments:[:],in:nil,contentWorld:.page) as? Bool
                check(back !== ordinary && sameAccount == true && back.configuration.webExtensionController === nativeA,"A website can return to its approved extension origin without following the currently selected other account")
                let clickedURL = fixture.appending(queryItems:[URLQueryItem(name:"account",value:"A-options-link")])
                _ = try? await back.callAsyncJavaScript("const link=document.createElement('a');link.href=nextURL;link.textContent='Owned website link';document.body.appendChild(link);link.click();return true;",arguments:["nextURL":clickedURL.absoluteString],in:nil,contentWorld:.page)
                let clicked = try await readyTab(store,id:boundaryID,url:clickedURL,extensionPage:false)
                check(clicked !== back && store.profileID(for:clicked) == a,"A normal link from an extension page uses its source account and a website configuration")
            } catch {check(false,"Owned extension-origin navigation failed: " + error.localizedDescription)}
            store.selectSpace(spaceA)
            let quickURL = fixture.appending(queryItems:[URLQueryItem(name:"account",value:"A-handoff")])
            let quickID = try store.openQuickPage(url:quickURL,profileID:a,intendedSpaceID:spaceA),quickWeb = store.view(for:quickID);try await ready(quickWeb,quickURL)
            let quickWindow = OwnedExtensionWindow(contentRect:NSRect(x:0,y:0,width:500,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            quickWindow.isReleasedWhenClosed = false;quickWindow.contentView = quickWeb
            store.registerExtensionWindow(quickWindow,kind:.quick(quickID))
            let beforeMove = try await query(options).first(where:{$0["url"] as? String == quickURL.absoluteString})?["id"] as? NSNumber
            _ = try await quickWeb.evaluateJavaScript("document.getElementById('owned-form').value='keep across handoff';true")
            _ = try store.promoteQuickPage(quickID,to:spaceA);store.unregisterExtensionWindow(kind:.quick(quickID));quickWindow.contentView = nil
            let afterMove = try await query(options).first(where:{$0["url"] as? String == quickURL.absoluteString})?["id"] as? NSNumber
            check(beforeMove != nil && beforeMove == afterMove && store.views[quickID] === quickWeb,"Same-account Quick handoff preserves the actual native extension tab identity")
            check((try await quickWeb.evaluateJavaScript("document.getElementById('owned-form').value === 'keep across handoff'")) as? Bool == true,"Extension-aware handoff preserves the live unsaved form")
            _ = try await webB.evaluateJavaScript("document.getElementById('owned-form').value='keep account B form';true")
            var closeRequests = 0,closeReplies = 0,closeError:Error?
            window.closeOperation = { [weak store] in
                closeRequests += 1;store?.closePrimaryWindowPages();store?.unregisterExtensionWindow(kind:.primary)
            }
            guard let actualWindow = adapterA.window(for:contextA) as? NativeExtensionWindow else {throw OwnedExtensionAdapterError.missingTab}
            actualWindow.close(for:contextA) {closeReplies += 1;closeError = $0}
            check(closeRequests == 0 && closeReplies == 1 && closeError != nil && store.views[tabB] === webB,"An account-scoped extension cannot close a shared primary window and discard another account's live pages")
            if store.views[tabB] === webB {
                check((try await webB.evaluateJavaScript("document.getElementById('owned-form').value === 'keep account B form'")) as? Bool == true,"Rejected shared-window closure preserves the other account's actual unsaved form")
            }
            store.shutdown()
            let reopened = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {reopened.shutdown()}
            let reopenedWindow = OwnedExtensionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            reopenedWindow.isReleasedWhenClosed = false;reopened.registerExtensionWindow(reopenedWindow,kind:.primary)
            defer {reopenedWindow.contentView = nil;reopened.unregisterExtensionWindow(kind:.primary)}
            let placeholder = reopened.view(for:optionsID);reopenedWindow.contentView = placeholder
            let restored = try await readyTab(reopened,id:optionsID,url:contextA.optionsPageURL!,extensionPage:true)
            let restoredValue = try await restored.callAsyncJavaScript("return (await browser.storage.local.get('ownedAccount')).ownedAccount;",arguments:[:],in:nil,contentWorld:.page) as? String
            check(restoredValue == "A" && reopened.profileID(for:restored) == a,"Restoring a saved extension tab prepares its native context and retains the owning account's persisted extension storage")
        }
        do {try await exercise()} catch {check(false,"Owned adapter fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Adapter fixtures erase their owned native extension storage")
        check(await owned.cleanup(),"Adapter fixtures release their owned website stores")
        print("Extension adapter checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
