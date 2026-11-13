import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedExtensionSurfaceError:Error {case missingFixture,timedOut}
@MainActor final class OwnedShiftSurfaceNavigation:WKNavigationAction {
    let ownedRequest:URLRequest
    init(_ url:URL) {ownedRequest = URLRequest(url:url);super.init()}
    override var request:URLRequest {ownedRequest}
    override var navigationType:WKNavigationType {.linkActivated}
    override var modifierFlags:NSEvent.ModifierFlags {[.shift]}
    override var targetFrame:WKFrameInfo? {nil}
}
@MainActor final class OwnedExtensionSurfaceWindow:NSWindow {
    override var isKeyWindow:Bool {true}
    override func makeKeyAndOrderFront(_ sender:Any?) {}
}
@MainActor final class OwnedSurfacePopupDelegate:NSObject,WKUIDelegate {
    weak var store:BrowserStore?
    var requests = 0
    init(_ store:BrowserStore) {self.store = store}
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures) -> WKWebView? {
        requests += 1
        return store?.webView(webView,createWebViewWith:configuration,for:action,windowFeatures:windowFeatures)
    }
}
@main struct ExtensionSurfaceChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<500 {
            if web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionSurfaceError.timedOut
    }
    @MainActor static func peekReady(_ store:BrowserStore,_ url:URL) async throws -> WKWebView {
        for _ in 0..<500 {
            if let web = store.primaryPeekView,web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return web}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionSurfaceError.timedOut
    }
    @MainActor static func frameResults(_ web:WKWebView,publicURL:URL,privateURL:URL,controlURL:URL) async throws -> [String:Any] {
        let result = try await web.callAsyncJavaScript("""
        window.ownedSurfaceMessages=[];
        if(!window.ownedSurfaceListening){window.ownedSurfaceListening=true;window.addEventListener('message',e=>{if(e.data?.ownedSurface)window.ownedSurfaceMessages.push(e.data.ownedSurface);});}
        let control=false;
        await Promise.all([publicURL,privateURL,controlURL].map((url,index)=>new Promise(resolve=>{
          const frame=document.createElement('iframe');frame.onload=()=>{if(index===2){try{control=frame.contentDocument.body.dataset.ownedExtensionPage==='ready'}catch{}}resolve()};frame.onerror=resolve;frame.src=url;document.body.appendChild(frame);setTimeout(resolve,2000);
        })));
        await new Promise(resolve=>setTimeout(resolve,150));
        return JSON.stringify({control,public:window.ownedSurfaceMessages.includes('public'),private:window.ownedSurfaceMessages.includes('private')});
        """,arguments:["publicURL":publicURL.absoluteString,"privateURL":privateURL.absoluteString,"controlURL":controlURL.absoluteString],in:nil,contentWorld:.page) as! String
        return try JSONSerialization.jsonObject(with:Data(result.utf8)) as! [String:Any]
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Extension surface fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedExtensionSurfaceError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:157,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func canonical(_ document:BrowserDocument) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(document)}
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key}),owner = BrowserWindowOwner(store:store),primary = try owner.acquirePrimary(),profile = try store.createProfile(name:"Owned surface account")
            defer {owner.release(primary);store.shutdown()}
            try owned.register(profile);try controllers.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let spaceID = store.space.id,source = root.appendingPathComponent("source")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned surfaces","description":"Owned resource and origin boundaries","version":"1","permissions":["storage"],"host_permissions":["http://127.0.0.1/*"],"options_page":"options.html","web_accessible_resources":[{"resources":["public.html","public.js"],"matches":["http://127.0.0.1/*"]}]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            for name in ["options","public","private"] {
                try Data("<!doctype html><body data-owned-extension-page='ready'>Owned \(name)<input id='owned-form'><script src='\(name).js'></script>".utf8).write(to:source.appendingPathComponent(name+".html"))
                let script = name == "options" ? "window.ownedSurfaceOptions=true;" : "window.parent.postMessage({ownedSurface:'\(name)'},'*');"
                try Data(script.utf8).write(to:source.appendingPathComponent(name+".js"))
            }
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging")),approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],hostPatterns:["http://127.0.0.1/*"],allowPrivate:true,enable:true)
            let id = try await store.installExtension(package,approval:approval),url = fixture.appendingPathComponent("surface-source"),tabID = store.newTab(url:url),web = store.view(for:tabID)
            try await ready(web,url)
            let window = OwnedExtensionSurfaceWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = web;store.registerExtensionWindow(window,kind:.primary)
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            let optionsID = try await store.openExtensionOptions(id,profileID:profile),options = store.views[optionsID]!,host = store.extensionHosting as! NativeBrowserExtensionHost,context = host.profiles[profile]!.contexts[id]!
            try await ready(options,context.optionsPageURL!);store.select(tabID);host.synchronizeBrowserState()
            _ = try await options.callAsyncJavaScript("await browser.storage.local.set({ownedSurfaceSecret:'owned only'});return true;",arguments:[:],in:nil,contentWorld:.page)
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep website surface';true")
            let publicURL = context.baseURL.appendingPathComponent("public.html"),privateURL = context.baseURL.appendingPathComponent("private.html")
            let frames = try await frameResults(web,publicURL:publicURL,privateURL:privateURL,controlURL:fixture.appendingPathComponent("frame-control"))
            check(frames["control"] as? Bool == true && frames["public"] as? Bool == true && frames["private"] as? Bool == false,"The actual website can embed an exposed extension resource while WebKit blocks its non-exposed private resource")
            let foreign = try store.createProfile(name:"Owned other surface account")
            try owned.register(foreign);try controllers.register(store.profiles.first(where:{$0.id == foreign})!.extensionControllerID!)
            let foreignURL = fixture.appendingPathComponent("foreign-surface"),foreignID = store.newTab(url:foreignURL),foreignWeb = store.view(for:foreignID)
            window.contentView = foreignWeb;try await ready(foreignWeb,foreignURL)
            let foreignFrames = try await frameResults(foreignWeb,publicURL:publicURL,privateURL:privateURL,controlURL:fixture.appendingPathComponent("foreign-frame-control"))
            check(foreignFrames["control"] as? Bool == true && foreignFrames["public"] as? Bool == false && foreignFrames["private"] as? Bool == false,"A different actual account cannot borrow either exposed or private resources from another controller")
            store.selectSpace(spaceID);store.select(tabID);window.contentView = web
            let before = try canonical(store.makeDocument())
            do {
                let peekURL = fixture.appendingPathComponent("normal-extension-peek")
                store.openPeek(peekURL,from:web)
                guard let ordinary = store.primaryPeekView,let pageID = store.peekPages[.primary]?.id else {throw OwnedExtensionSurfaceError.missingFixture}
                window.contentView = ordinary;try await ready(ordinary,peekURL);host.synchronizeBrowserState()
                let tabJSON = try await options.callAsyncJavaScript("return JSON.stringify((await browser.tabs.query({})).find(t=>t.url===sourceURL));",arguments:["sourceURL":peekURL.absoluteString],in:nil,contentWorld:.page) as! String
                let peekAPI = try JSONSerialization.jsonObject(with:Data(tabJSON.utf8)) as! [String:Any],apiID = peekAPI["id"] as! NSNumber
                _ = try await options.callAsyncJavaScript("return await browser.tabs.update(tabID,{url:browser.runtime.getURL('options.html')});",arguments:["tabID":apiID],in:nil,contentWorld:.page)
                let specialized = try await peekReady(store,context.optionsPageURL!)
                window.contentView = specialized
                let secret = try await specialized.callAsyncJavaScript("return (await browser.storage.local.get('ownedSurfaceSecret')).ownedSurfaceSecret === 'owned only';",arguments:[:],in:nil,contentWorld:.page) as? Bool
                check(specialized !== ordinary && store.peekPages[.primary]?.id == pageID && secret == true && specialized.configuration.websiteDataStore.identifier == profile,"The real extension tab API can replace its Peek document with its own privileged page while preserving the Peek identity and account")
                host.synchronizeBrowserState()
                let afterID = try await options.callAsyncJavaScript("return (await browser.tabs.query({})).find(t=>t.url===targetURL && t.id===oldID)?.id;",arguments:["targetURL":context.optionsPageURL!.absoluteString,"oldID":apiID],in:nil,contentWorld:.page) as? NSNumber
                check(afterID == apiID,"Changing a Peek's native view configuration preserves its extension API tab identifier")
                let destination = fixture.appendingPathComponent("peek-leaves-extension")
                _ = try? await specialized.callAsyncJavaScript("const a=document.createElement('a');a.href=targetURL;document.body.appendChild(a);a.click();return true;",arguments:["targetURL":destination.absoluteString],in:nil,contentWorld:.page)
                let website = try await peekReady(store,destination);window.contentView = website
                let privileged = try await website.callAsyncJavaScript("try{await browser.storage.local.get();return true}catch{return false}",arguments:[:],in:nil,contentWorld:.page) as? Bool
                check(website !== specialized && privileged == false && store.peekPages[.primary]?.id == pageID,"An actual link out of the extension Peek creates an ordinary website view without extension storage authority")
            } catch {check(false,"Owned Peek origin transition failed: " + error.localizedDescription)}
            store.closeAllPeeks();window.contentView = web
            let after = try canonical(store.makeDocument()),form = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'keep website surface'") as? Bool
            check(before == after && store.views[tabID] === web && form == true,"Peek origin transitions preserve the underlying real website, unsaved form and normal saved document")
            do {
                check(!options.configuration.preferences.javaScriptCanOpenWindowsAutomatically,"Production extension documents retain the browser's automatic-popup restriction")
                // This prohibited, hidden fixture has no physical click. Enable only
                // its owned opener at construction to obtain real SDK popup callbacks.
                guard let openerConfiguration = context.webViewConfiguration else {throw OwnedExtensionSurfaceError.missingFixture}
                openerConfiguration.websiteDataStore = store.websiteDataStore(forProfile:profile)
                store.configureExtensions(openerConfiguration,profileID:profile)
                openerConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = true
                let opener = WKWebView(frame:options.frame,configuration:openerConfiguration),popupDelegate = OwnedSurfacePopupDelegate(store)
                store.registerView(opener,for:optionsID,profile:profile);opener.uiDelegate = popupDelegate
                window.contentView = opener;store.select(optionsID);opener.load(URLRequest(url:context.optionsPageURL!));try await ready(opener,context.optionsPageURL!)
                _ = try await opener.evaluateJavaScript("document.getElementById('owned-form').value='keep popup opener';true")
                for extensionPage in [true,false] {
                    openerConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = true
                    store.message = nil
                    let known = Set(store.views.keys),documentBefore = try canonical(store.makeDocument()),destination = extensionPage ? context.optionsPageURL!.appending(queryItems:[URLQueryItem(name:"owned-popup",value:"extension")]) : fixture.appendingPathComponent("extension-popup-website")
                    let state = try await opener.callAsyncJavaScript("const active=navigator.userActivation?.isActive,hidden=document.hidden,opened=!!window.open(targetURL,'_blank');return JSON.stringify({active,hidden,opened});",arguments:["targetURL":destination.absoluteString],in:nil,contentWorld:.page) as! String
                    if !extensionPage {
                        let result = try JSONSerialization.jsonObject(with:Data(state.utf8)) as! [String:Any],documentAfter = try canonical(store.makeDocument())
                        check(result["opened"] as? Bool == false && Set(store.views.keys) == known && documentBefore == documentAfter && store.message == ExtensionHostError.unsupportedWebsitePopup.localizedDescription,"An unsupported extension-to-website popup returns failure without publishing a blank tab or changing the saved document")
                        let kept = try await opener.evaluateJavaScript("document.getElementById('owned-form').value === 'keep popup opener'") as? Bool
                        check(kept == true && popupDelegate.requests == 2,"Refusing a website popup preserves its actual extension opener and handles the real native callback")
                        continue
                    }
                    var popupID:UUID?
                    for _ in 0..<500 {popupID = Set(store.views.keys).subtracting(known).first;if popupID != nil {break};try await Task.sleep(for:.milliseconds(10))}
                    guard let popupID,let popup = store.views[popupID] else {throw OwnedExtensionSurfaceError.missingFixture}
                    window.contentView = popup
                    try await ready(popup,destination)
                    let authority = try await popup.callAsyncJavaScript("try{return (await browser.storage.local.get('ownedSurfaceSecret')).ownedSurfaceSecret === 'owned only'}catch{return false}",arguments:[:],in:nil,contentWorld:.page) as? Bool
                    check(popup !== opener && popup.configuration.websiteDataStore.identifier == profile && authority == extensionPage,extensionPage ? "An actual same-extension link popup has only its own account's extension-page authority" : "An actual website popup from an extension uses its owning account without retaining extension storage authority")
                    let openerKept = try await opener.evaluateJavaScript("document.getElementById('owned-form').value === 'keep popup opener'") as? Bool
                    check(openerKept == true && store.views[optionsID] === opener,"Opening the actual native popup retains its original extension document and form")
                    _ = try await popup.evaluateJavaScript("document.getElementById('owned-form').value='keep related popup';true")
                    host.synchronizeBrowserState()
                    guard let adapter = host.tabsByView[ObjectIdentifier(popup)] else {throw OwnedExtensionSurfaceError.missingFixture}
                    var refused = 0,popupError:Error?
                    let website = fixture.appendingPathComponent("existing-extension-popup-website")
                    adapter.loadURL(website,for:context){refused += 1;popupError = $0}
                    check(refused == 1 && popupError != nil && popup.url == destination && store.views[popupID] === popup,"The native tab API cannot silently replace an extension popup and discard its native opener relationship")
                    _ = try? await popup.callAsyncJavaScript("location.href=targetURL;return true;",arguments:["targetURL":website.absoluteString],in:nil,contentWorld:.page)
                    try await Task.sleep(for:.milliseconds(150))
                    let retained = try await popup.evaluateJavaScript("document.getElementById('owned-form').value === 'keep related popup'") as? Bool
                    check(retained == true && popup.url == destination && store.views[popupID] === popup,"An actual website navigation from the related extension popup is refused while keeping its document and form")
                    store.showCommand()
                    let commandBefore = try canonical(store.makeDocument())
                    store.navigate(website.absoluteString)
                    let commandAfter = try canonical(store.makeDocument())
                    check(store.commandVisible && store.commandError == ExtensionHostError.unsupportedWebsitePopup.localizedDescription && commandBefore == commandAfter && store.views[popupID] === popup,"The main command bar reports a refused related-popup navigation before hiding or rewriting the tab")
                    store.dismissCommand()
                    var previewDecisions:[WKNavigationActionPolicy] = []
                    store.webView(popup,decidePolicyFor:OwnedShiftSurfaceNavigation(website)){previewDecisions.append($0)}
                    let preview = store.primaryPeekView
                    if let preview {window.contentView = preview;try await ready(preview,website)}
                    check(previewDecisions == [.cancel] && preview != nil && preview?.configuration.websiteDataStore.identifier == profile && store.views[popupID] === popup,"Shift-click can open an ordinary Peek without navigating or replacing the related extension popup")
                    store.closeAllPeeks();window.contentView = popup
                    var blankReplies = 0,blankError:Error?
                    let blank = URL(string:"about:blank")!
                    adapter.loadURL(blank,for:context){blankReplies += 1;blankError = $0}
                    for _ in 0..<200 {if store.views[popupID]?.url == blank && store.views[popupID]?.isLoading == false {break};try await Task.sleep(for:.milliseconds(10))}
                    let blankOpener = try await store.views[popupID]?.evaluateJavaScript("!!window.opener") as? Bool
                    check(blankReplies == 1 && blankError == nil && store.views[popupID] === popup && blankOpener == true,"A blank document in a related extension popup keeps its real native view and opener relationship")
                    store.close(popupID)
                    window.contentView = opener;store.select(optionsID)
                }
                store.close(optionsID)
                let ordinaryID = store.newTab(),ordinaryConfiguration = WKWebViewConfiguration()
                ordinaryConfiguration.websiteDataStore = store.websiteDataStore(forProfile:profile);store.configureExtensions(ordinaryConfiguration,profileID:profile)
                ordinaryConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = true
                let ordinaryOpener = WKWebView(frame:web.frame,configuration:ordinaryConfiguration),ordinaryURL = fixture.appendingPathComponent("ordinary-popup-source")
                store.registerView(ordinaryOpener,for:ordinaryID,profile:profile);ordinaryOpener.uiDelegate = popupDelegate
                window.contentView = ordinaryOpener;ordinaryOpener.load(URLRequest(url:ordinaryURL));try await ready(ordinaryOpener,ordinaryURL)
                _ = try await ordinaryOpener.evaluateJavaScript("document.getElementById('owned-form').value='keep ordinary opener';true")
                let known = Set(store.views.keys),target = fixture.appendingPathComponent("ordinary-popup-target")
                _ = try await ordinaryOpener.callAsyncJavaScript("window.ownedWebPopupReply=false;const expected=new URL(targetURL).origin;window.addEventListener('message',e=>{if(e.origin===expected&&e.data?.ownedWebPopupReply===true)window.ownedWebPopupReply=true});return !!window.open(targetURL,'_blank');",arguments:["targetURL":target.absoluteString],in:nil,contentWorld:.page)
                var ordinaryPopupID:UUID?
                for _ in 0..<500 {ordinaryPopupID = Set(store.views.keys).subtracting(known).first;if ordinaryPopupID != nil {break};try await Task.sleep(for:.milliseconds(10))}
                guard let ordinaryPopupID,let child = store.views[ordinaryPopupID] else {throw OwnedExtensionSurfaceError.missingFixture}
                window.contentView = child;try await ready(child,target)
                let hasOpener = try await child.callAsyncJavaScript("window.opener?.postMessage({ownedWebPopupReply:true},new URL(sourceURL).origin);try{await browser.storage.local.get();return false}catch{return !!window.opener}",arguments:["sourceURL":ordinaryURL.absoluteString],in:nil,contentWorld:.page) as? Bool
                var replied = false
                for _ in 0..<200 {replied = (try? await ordinaryOpener.evaluateJavaScript("window.ownedWebPopupReply === true")) as? Bool == true;if replied {break};try await Task.sleep(for:.milliseconds(10))}
                check(hasOpener == true && replied && child.configuration.websiteDataStore.identifier == profile && !store.extensionOriginPopups.contains(child),"An actual ordinary website popup loads in its account and preserves native opener messaging without extension storage access")
                let kept = try await ordinaryOpener.evaluateJavaScript("document.getElementById('owned-form').value === 'keep ordinary opener'") as? Bool
                check(kept == true,"The supported ordinary website popup leaves its source form intact")
                store.close(ordinaryPopupID);store.close(ordinaryID)
            } catch {check(false,"Owned extension popup failed: " + error.localizedDescription)}
            store.select(tabID);window.contentView = web
            do {
                guard let config = context.webViewConfiguration else {throw OwnedExtensionSurfaceError.missingFixture}
                let rootID = try store.openQuickPage(profileID:profile,intendedSpaceID:spaceID,configuration:config)
                config.preferences.javaScriptCanOpenWindowsAutomatically = true
                let rootWeb = WKWebView(frame:web.frame,configuration:config),delegate = OwnedSurfacePopupDelegate(store)
                store.registerView(rootWeb,for:rootID,profile:profile);rootWeb.uiDelegate = delegate
                let rootWindow = OwnedExtensionSurfaceWindow(contentRect:NSRect(x:0,y:0,width:500,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                rootWindow.isReleasedWhenClosed = false;rootWindow.contentView = rootWeb;store.registerExtensionWindow(rootWindow,kind:.quick(rootID))
                defer {store.unregisterExtensionWindow(kind:.quick(rootID));try? store.closeQuickPage(rootID);rootWindow.contentView = nil;rootWindow.close()}
                rootWeb.load(URLRequest(url:context.optionsPageURL!));try await ready(rootWeb,context.optionsPageURL!)
                let known = Set(store.views.keys),target = context.optionsPageURL!.appending(queryItems:[URLQueryItem(name:"owned-quick-popup",value:"yes")])
                _ = try await rootWeb.callAsyncJavaScript("return !!window.open(targetURL,'_blank');",arguments:["targetURL":target.absoluteString],in:nil,contentWorld:.page)
                var childID:UUID?
                for _ in 0..<500 {childID = Set(store.views.keys).subtracting(known).first;if childID != nil {break};try await Task.sleep(for:.milliseconds(10))}
                guard let childID,let child = store.views[childID] else {throw OwnedExtensionSurfaceError.missingFixture}
                let childWindow = OwnedExtensionSurfaceWindow(contentRect:NSRect(x:0,y:0,width:500,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                childWindow.isReleasedWhenClosed = false;childWindow.contentView = child;store.registerExtensionWindow(childWindow,kind:.quick(childID))
                defer {store.unregisterExtensionWindow(kind:.quick(childID));try? store.closeQuickPage(childID);childWindow.contentView = nil;childWindow.close()}
                try await ready(child,target)
                check(store.quickPage(childID) != nil && store.extensionOriginPopups.contains(child),"An actual extension popup in a compact window retains its real Quick record and native relation")
                let before = try canonical(store.makeDocument());var denied = false
                do {try store.navigateQuickPage(childID,input:fixture.appendingPathComponent("unsupported-quick-popup-website").absoluteString)} catch {denied = true}
                let after = try canonical(store.makeDocument())
                check(denied && before == after && store.views[childID] === child && store.quickPage(childID)?.tab.url == target.absoluteString,"A refused address-bar navigation from a related compact popup cannot rewrite its saved destination or activity record")
            } catch {check(false,"Owned compact popup failed: " + error.localizedDescription)}
            let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in throw CocoaError(.fileReadNoPermission)})
            defer {privateStore.shutdown()}
            try privateStore.associateExtensions(with:owner,profileID:profile)
            let privateID = privateStore.selectedID!,privateSource = privateStore.view(for:privateID),privateSiteURL = fixture.appendingPathComponent("private-surface")
            privateSource.load(URLRequest(url:privateSiteURL));try await ready(privateSource,privateSiteURL)
            let privateWindow = OwnedExtensionSurfaceWindow(contentRect:NSRect(x:0,y:0,width:650,height:450),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            privateWindow.isReleasedWhenClosed = false;privateWindow.contentView = privateSource;privateStore.registerExtensionWindow(privateWindow,kind:.primary)
            defer {privateStore.unregisterExtensionWindow(kind:.primary);privateWindow.contentView = nil;privateWindow.close()}
            let privatePeekURL = fixture.appendingPathComponent("private-extension-peek")
            privateStore.openPeek(privatePeekURL,from:privateSource)
            guard let privatePeek = privateStore.primaryPeekView else {throw OwnedExtensionSurfaceError.missingFixture}
            privateWindow.contentView = privatePeek;try await ready(privatePeek,privatePeekURL)
            _ = try await privatePeek.evaluateJavaScript("document.getElementById('owned-form').value='keep private peek';true")
            host.synchronizeBrowserState()
            guard let privateTab = host.tabsByView[ObjectIdentifier(privatePeek)] else {throw OwnedExtensionSurfaceError.missingFixture}
            var replies = 0,error:Error?
            privateTab.loadURL(context.optionsPageURL!,for:context){replies += 1;error = $0}
            check(replies == 1 && error != nil && privateStore.primaryPeekView === privatePeek && privatePeek.url == privatePeekURL,"A spanning extension's private Peek refuses a main-frame extension page before publishing or navigating")
        }
        do {try await exercise()} catch {check(false,"Owned surface fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Surface fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Surface fixtures release only their owned named website stores")
        print("Extension surface checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
