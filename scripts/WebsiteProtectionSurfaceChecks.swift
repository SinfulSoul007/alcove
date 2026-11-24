import AppKit
import SwiftUI
import WebKit
import Network
import CryptoKit
import BrowserCore
import Darwin

@main struct WebsiteProtectionSurfaceChecks {
    enum Failure:Error {case fixture,timeout,checks(Int)}
    nonisolated(unsafe) static var completed=false
    @MainActor static func descendants(_ root:NSView) -> [NSView] {[root]+root.subviews.flatMap{descendants($0)}}
    @MainActor static func ready(_ web:WKWebView,host:String) async throws {
        for _ in 0..<600 {
            if web.url?.host==host,!web.isLoading,(try? await web.evaluateJavaScript("document.readyState==='complete'&&document.getElementById('token')!==null")) as? Bool==true {return}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw Failure.timeout
    }
    @MainActor static func warning(_ web:WKWebView,store:BrowserStore,url:URL) async throws -> NSView {
        for _ in 0..<400 {
            if store.websiteProtectionTicket(for:web)?.url==url,let parent=web.superview,
               let overlay=descendants(parent).first(where:{$0.identifier?.rawValue=="AlcoveWebsiteProtection" && !$0.isHiddenOrHasHiddenAncestor}),overlay.window?.isVisible==true {return overlay}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw Failure.timeout
    }
    @MainActor static func button(_ overlay:NSView,continueRequest:Bool) throws -> NSButton {
        let name=continueRequest ? "AlcoveWebsiteProtectionContinue":"AlcoveWebsiteProtectionSafe"
        guard let value=descendants(overlay).first(where:{$0.identifier?.rawValue==name}) as? NSButton,!value.isHiddenOrHasHiddenAncestor else {throw Failure.fixture}
        return value
    }
    static func requests(port:String,name:String) async throws -> [[String:Any]] {
        let address=URL(string:"http://127.0.0.1:"+port+"/_events")!
        let (data,_)=try await URLSession.shared.data(from:address)
        let rows=try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        return rows.filter{$0["case"] as? String==name && $0["host"] as? String=="listed.alcove.example"}
    }
    @available(macOS 15.4,*)
    @MainActor static func exercise(owned:OwnedWebsiteStores,controllers:OwnedExtensionControllers) async throws {
        guard let raw=ProcessInfo.processInfo.environment["ALCOVE_OWNED_PROXY_PORT"],let number=UInt16(raw),let port=NWEndpoint.Port(rawValue:number) else {throw Failure.fixture}
        let rows=Data("listed.alcove.example\n".utf8)
        let metadata=try JSONSerialization.data(withJSONObject:["formatVersion":1,"provider":"PhishDestroy","sourceRevision":String(repeating:"1",count:40),"sourceUpdatedAt":"2026-11-01T00:00:00Z","retrievedAt":"2026-11-02T00:00:00Z","sha256":SHA256.hash(data:rows).map{String(format:"%02x",$0)}.joined(),"licenseSHA256":String(repeating:"0",count:64),"domainCount":1])
        let catalog=try WebsiteThreatCatalog(domains:rows,metadata:metadata)
        let service=WebsiteProtectionService(loader:{catalog});_=await service.load()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("alcove-protection-surfaces-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let key=SymmetricKey(data:Data(repeating:37,count:32))
        let store=BrowserStore(dataRoot:root,keyProvider:{_ in key},websiteProtection:service)
        let owner=BrowserWindowOwner(store:store),lease=try owner.acquirePrimaryStore().lease
        defer {owner.release(lease);store.shutdown()}
        let profile=try store.createProfile(name:"Owned warning surfaces")
        store.finishOnboarding()
        try owned.register(profile)
        func recordController() throws {
            if let id=store.profiles.first(where:{$0.id==profile})?.extensionControllerID {try controllers.register(id)}
        }
        try recordController()
        let dataStore=store.websiteDataStore(forProfile:profile)
        var proxy=ProxyConfiguration(httpCONNECTProxy:.hostPort(host:"127.0.0.1",port:port));proxy.allowFailover=false;dataStore.proxyConfigurations=[proxy]
        var checks=0,failures=0
        func check(_ value:Bool,_ label:String){checks+=1;print("\(value ? "PASS":"FAIL"): \(label)");if !value {failures+=1}}
        let initial=URL(string:"http://safe.alcove.example/form?case=normal-surface-baseline")!
        let first=store.newTab(url:initial),web=store.view(for:first)
        var singleHost:EdgeToEdgeWebHost?=EdgeToEdgeWebHost(frame:NSRect(x:0,y:0,width:1000,height:680))
        WebPane(webView:web,store:store).mount(in:singleHost!)
        let window=NSWindow(contentRect:singleHost!.frame,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="Alcove owned warning surface checks";window.contentView=singleHost
        store.registerExtensionWindow(window,kind:.primary);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer {store.unregisterExtensionWindow(kind:.primary);window.contentView=nil;window.close()}
        try await ready(web,host:"safe.alcove.example")
        check(!store.isPrivate && web.configuration.websiteDataStore.isPersistent && store.profileID(for:web)==profile,"The actual normal page belongs to an owned persistent profile")
        _=try await web.evaluateJavaScript("document.getElementById('token').value='owned-normal';true")
        let held=URL(string:"http://listed.alcove.example/target?case=normal-surface-cancel")!
        store.navigate(held.absoluteString)
        let normalWarning=try await warning(web,store:store,url:held)
        check(try await requests(port:raw,name:"normal-surface-cancel").isEmpty,"Normal-profile warning holds the actual target request")
        let oldNormalSafe=try button(normalWarning,continueRequest:false),oldNormalContinue=try button(normalWarning,continueRequest:true)
        oldNormalSafe.performClick(nil)
        check(try await requests(port:raw,name:"normal-surface-cancel").isEmpty,"Normal-profile cancellation never contacts the target")
        check((try? await web.evaluateJavaScript("document.getElementById('token').value==='owned-normal'")) as? Bool==true && store.tab(first)?.url==initial.absoluteString,"Normal cancellation preserves the typed form and displayed address")
        check(!store.library(for:profile).history.contains(where:{$0.url==held.absoluteString}),"A blocked normal navigation is not recorded as a visited page")
        let allowed=URL(string:"http://listed.alcove.example/target?case=normal-surface-continue")!
        store.navigate(allowed.absoluteString)
        let allowedWarning=try await warning(web,store:store,url:allowed)
        oldNormalContinue.performClick(nil)
        let staleNormalRows=try await requests(port:raw,name:"normal-surface-continue")
        check(store.websiteProtectionTicket(for:web)?.isPending==true && staleNormalRows.isEmpty,"A retained Continue control cannot approve a different warning in the same mounted pane")
        if store.websiteProtectionTicket(for:web)?.isPending==true {try button(allowedWarning,continueRequest:true).performClick(nil)}
        try await ready(web,host:"listed.alcove.example")
        let allowedRows=try await requests(port:raw,name:"normal-surface-continue")
        check(allowedRows.count==1 && allowedRows.first?["method"] as? String=="GET","Normal native continuation sends exactly its captured GET")
        let second=store.newTab(url:initial),other=store.view(for:second)
        store.select(first);guard store.openInSplit(second),let layout=store.splitLayout else {throw Failure.fixture}
        let split=NativeBrowserSplit(layout:layout,size:CGSize(width:1000,height:680),onResize:{store.rememberSplitPaneSizes(for:$0,lengths:$1)},pane:{id in WebPane(webView:store.view(for:id),store:store)})
        let splitHost=NSHostingView(rootView:split);splitHost.sizingOptions=[];window.contentView=splitHost;singleHost=nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await ready(other,host:"safe.alcove.example")
        let left=URL(string:"http://listed.alcove.example/target?case=split-surface-left")!,right=URL(string:"http://listed.alcove.example/target?case=split-surface-right")!
        web.load(URLRequest(url:left));other.load(URLRequest(url:right))
        let leftWarning=try await warning(web,store:store,url:left),rightWarning=try await warning(other,store:store,url:right)
        let leftRows=try await requests(port:raw,name:"split-surface-left"),rightRows=try await requests(port:raw,name:"split-surface-right")
        check(leftRows.isEmpty && rightRows.isEmpty,"Both real split panes hold their own target requests")
        check(leftWarning !== rightWarning && leftWarning.superview === web.superview && rightWarning.superview === other.superview,"Each mounted native split pane owns its own warning")
        oldNormalSafe.performClick(nil)
        check(store.websiteProtectionTicket(for:web)?.url==left && store.websiteProtectionTicket(for:other)?.url==right,"Controls retained from an unmounted pane cannot cancel the current split warnings")
        try button(leftWarning,continueRequest:true).performClick(nil)
        try await ready(web,host:"listed.alcove.example")
        let leftAfter=try await requests(port:raw,name:"split-surface-left"),rightAfter=try await requests(port:raw,name:"split-surface-right")
        check(leftAfter.count==1 && rightAfter.isEmpty && store.websiteProtectionTicket(for:other) != nil,"Continuing one split pane leaves the other request held")
        try button(rightWarning,continueRequest:false).performClick(nil)
        check(try await requests(port:raw,name:"split-surface-right").isEmpty,"Canceling the other split warning keeps its target untouched")
        window.orderOut(nil)
        let quickInitial=URL(string:"http://safe.alcove.example/redirect-safe?case=quick-surface-baseline")!
        let quickDocument=URL(string:"http://safe.alcove.example/form?case=quick-surface-baseline")!
        let quick=try store.openQuickPage(url:quickInitial,profileID:profile,intendedSpaceID:store.space.id)
        let controller=try QuickBrowseWindowController(owner:owner,pageID:quick,requestPrimary:{},requestProfiles:{},didClose:{})
        controller.surface()
        defer {controller.window?.performClose(nil)}
        guard let quickWeb=controller.activeWebView else {throw Failure.fixture}
        try await ready(quickWeb,host:"safe.alcove.example")
        let quickHeld=URL(string:"http://listed.alcove.example/target?case=quick-surface-cancel")!
        try store.navigateQuickPage(quick,input:quickHeld.absoluteString)
        let quickWarning=try await warning(quickWeb,store:store,url:quickHeld)
        check(try await requests(port:raw,name:"quick-surface-cancel").isEmpty,"The actual Quick Browse window holds its listed request")
        try button(quickWarning,continueRequest:false).performClick(nil)
        check(store.quickPage(quick)?.tab.url==quickDocument.absoluteString && quickWeb.url==quickDocument,"Canceling a Quick Browse warning restores its displayed page")
        check(try store.openQuickPage(url:quickInitial,profileID:profile,intendedSpaceID:store.space.id)==quick,"The restored redirected page still reopens through its original external address")
        let retried=try store.openQuickPage(url:quickHeld,profileID:profile,intendedSpaceID:store.space.id)
        check(retried != quick || quickWeb.url==quickHeld || store.websiteProtectionTicket(for:quickWeb) != nil,"Opening the canceled destination again must attempt that destination")
        if retried != quick {try store.closeQuickPage(retried)}
        let quickClosing=URL(string:"http://listed.alcove.example/target?case=quick-surface-close")!
        try store.navigateQuickPage(quick,input:quickClosing.absoluteString)
        let closingWarning=try await warning(quickWeb,store:store,url:quickClosing)
        let oldQuickContinue=try button(closingWarning,continueRequest:true)
        let heldTicket=store.websiteProtectionTicket(for:quickWeb),beforeClose=try Data(contentsOf:store.sessionURL),savedVault=store.vault
        store.vault=MetadataStore(url:root,key:key)
        controller.window?.performClose(nil)
        let afterFailedClose=try Data(contentsOf:store.sessionURL)
        check(controller.window?.isVisible==true && store.quickPage(quick) != nil && heldTicket?.isPending==true && store.websiteProtectionTicket(for:quickWeb) === heldTicket && afterFailedClose==beforeClose,"A failed Quick Browse close keeps its warning, page and prior ciphertext intact")
        store.vault=savedVault
        _=store.unlockLocalData(keyProvider:{key})
        for _ in 0..<500 where store.unlocking {try await Task.sleep(for:.milliseconds(10))}
        guard store.savingEnabled else {throw Failure.fixture}
        check(store.websiteProtectionTicket(for:quickWeb) === heldTicket && heldTicket?.isPending==true,"Unlocking after a failed close preserves the same live warning")
        controller.window?.performClose(nil);oldQuickContinue.performClick(nil)
        check(store.quickPage(quick)==nil && store.websiteProtectionTicket(for:quickWeb)==nil,"Closing the real Quick Browse window cancels its warning")
        check(try await requests(port:raw,name:"quick-surface-close").isEmpty,"A closed Quick Browse warning cannot replay its request")
        check(store.library(for:profile).archive.first(where:{$0.id==quick})?.url==quickDocument.absoluteString,"Closing a Quick Browse warning archives the displayed page rather than its unvisited blocked destination")
        let initialBlocked=URL(string:"http://listed.alcove.example/target?case=quick-surface-initial-close")!
        let neverOpened=try store.openQuickPage(url:initialBlocked,profileID:profile,intendedSpaceID:store.space.id)
        let initialController=try QuickBrowseWindowController(owner:owner,pageID:neverOpened,requestPrimary:{},requestProfiles:{},didClose:{})
        initialController.surface()
        defer {initialController.window?.performClose(nil)}
        guard let initialWeb=initialController.activeWebView else {throw Failure.fixture}
        _=try await warning(initialWeb,store:store,url:initialBlocked)
        initialController.window?.performClose(nil)
        check(!store.library(for:profile).archive.contains(where:{$0.id==neverOpened}),"Closing a Quick Browse page at its first warning does not archive an unvisited destination")
        check(try await requests(port:raw,name:"quick-surface-initial-close").isEmpty && store.quickPage(neverOpened)==nil,"Closing an initial Quick Browse warning cancels its request without contacting the target")
        window.makeKeyAndOrderFront(nil)
        let closingInitial=URL(string:"http://safe.alcove.example/form?case=normal-close-committed")!
        let closingID=store.newTab(url:closingInitial),closingWeb=store.view(for:closingID)
        let closingHost=EdgeToEdgeWebHost(frame:NSRect(x:0,y:0,width:1000,height:680))
        WebPane(webView:closingWeb,store:store).mount(in:closingHost);window.contentView=closingHost
        try await ready(closingWeb,host:"safe.alcove.example")
        let closingBlocked=URL(string:"http://listed.alcove.example/target?case=normal-close-blocked")!
        store.navigate(closingBlocked.absoluteString)
        _=try await warning(closingWeb,store:store,url:closingBlocked)
        store.close(closingID)
        check(store.library(for:profile).closedTabs.first(where:{$0.id==closingID})?.url==closingInitial.absoluteString,"Closing a normal warning saves the committed page for Reopen Closed Tab")
        window.contentView=splitHost;store.select(first)
        let movingInitial=URL(string:"http://safe.alcove.example/form?case=quick-moving-committed")!
        let movingID=try store.openQuickPage(url:movingInitial,profileID:profile,intendedSpaceID:store.space.id)
        let movingController=try QuickBrowseWindowController(owner:owner,pageID:movingID,requestPrimary:{},requestProfiles:{},didClose:{})
        movingController.surface();defer {movingController.window?.close()}
        guard let movingWeb=movingController.activeWebView else {throw Failure.fixture}
        try await ready(movingWeb,host:"safe.alcove.example")
        let peekInitial=URL(string:"http://safe.alcove.example/form?case=quick-moving-peek-committed")!
        store.openPeek(peekInitial,from:movingWeb)
        guard let movingPeek=store.quickPeekView(movingID) else {throw Failure.fixture}
        try await ready(movingPeek,host:"safe.alcove.example")
        let movingBlocked=URL(string:"http://listed.alcove.example/target?case=quick-moving-blocked")!,peekBlocked=URL(string:"http://listed.alcove.example/target?case=quick-moving-peek-blocked")!
        try store.navigateQuickPage(movingID,input:movingBlocked.absoluteString)
        _=try await warning(movingWeb,store:store,url:movingBlocked)
        movingPeek.load(URLRequest(url:peekBlocked))
        _=try await warning(movingPeek,store:store,url:peekBlocked)
        let heldMoving=store.websiteProtectionTicket(for:movingWeb),heldPeek=store.websiteProtectionTicket(for:movingPeek)
        let beforePromotion=try Data(contentsOf:store.sessionURL),promotionVault=store.vault
        store.vault=MetadataStore(url:root,key:key)
        var refusedPromotion=false
        do {_=try store.promoteQuickPage(movingID)}catch{refusedPromotion=true}
        let afterFailedPromotion=try Data(contentsOf:store.sessionURL)
        store.vault=promotionVault
        _=store.unlockLocalData(keyProvider:{key})
        for _ in 0..<500 where store.unlocking {try await Task.sleep(for:.milliseconds(10))}
        guard store.savingEnabled else {throw Failure.fixture}
        check(refusedPromotion && store.quickPage(movingID) != nil && heldMoving?.isPending==true && heldPeek?.isPending==true && store.websiteProtectionTicket(for:movingWeb) === heldMoving && store.websiteProtectionTicket(for:movingPeek) === heldPeek && beforePromotion==afterFailedPromotion,"A failed Quick promotion preserves both pending warnings and the prior ciphertext")
        _=try store.promoteQuickPage(movingID)
        check(heldMoving?.isPending==false && store.websiteProtectionTicket(for:movingWeb)==nil && store.tab(movingID)?.url==movingInitial.absoluteString,"Same-store Quick promotion cancels its original warning and carries the committed page")
        check(heldPeek?.isPending==false && store.websiteProtectionTicket(for:movingPeek)==nil && store.primaryPeekView === movingPeek,"Same-store Quick promotion cancels the adopted Peek warning while retaining its native page")
        store.closePrimaryPeek();store.close(movingID);store.select(first)
        window.contentView=splitHost
        let extensionSource=root.appendingPathComponent("extension-source")
        try FileManager.default.createDirectory(at:extensionSource,withIntermediateDirectories:true)
        try Data(#"{"manifest_version":3,"name":"Owned warning windows","version":"1","permissions":["tabs"],"host_permissions":["http://*.alcove.example/*"],"options_page":"options.html"}"#.utf8).write(to:extensionSource.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Owned warning options</title><body>Owned extension options</body>".utf8).write(to:extensionSource.appendingPathComponent("options.html"))
        let package=try ExtensionPackage.prepare(at:extensionSource,stagingRoot:root.appendingPathComponent("extension-staging"))
        let approval=try store.extensionInstallApproval(for:package,profileID:profile,permissions:["tabs"],hostPatterns:["http://*.alcove.example/*"],enable:true)
        let extensionID=try await store.installExtension(package,approval:approval)
        try recordController()
        let optionsID=try await store.openExtensionOptions(extensionID,profileID:profile)
        var retainedOptions:WKWebView?=store.view(for:optionsID)
        for _ in 0..<400 {
            if !retainedOptions!.isLoading,(try? await retainedOptions!.evaluateJavaScript("typeof browser.windows.create==='function'")) as? Bool==true {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let app=AppDelegate(),previousDelegate=NSApp.delegate
        NSApp.delegate=app;app.normalOwner=owner
        defer {for ownedWindow in Array(app.windows.keys) {ownedWindow.close()};NSApp.delegate=previousDelegate}
        for kind in ["normal","popup"] {
            let before=Set(app.windows.keys)
            let starting=URL(string:"http://safe.alcove.example/form?case=extension-\(kind)-baseline")!
            let answer=try await retainedOptions!.callAsyncJavaScript("try{return JSON.stringify(await browser.windows.create(settings))}catch(e){return JSON.stringify({error:String(e)})}",arguments:["settings":["type":kind,"url":starting.absoluteString,"focused":false]],in:nil,contentWorld:.page)
            print("OWNED_EXTENSION_WINDOW_CREATE",kind,String(describing:answer))
            guard let createdWindow=app.windows.keys.first(where:{!before.contains($0)}),let createdStore=app.windows[createdWindow] else {throw Failure.fixture}
            var createdWeb:WKWebView?
            for _ in 0..<400 {
                createdWeb=createdStore.views.values.first(where:{$0.url?.host=="safe.alcove.example"})
                if createdWeb != nil {break};try await Task.sleep(for:.milliseconds(20))
            }
            guard let createdWeb else {throw Failure.fixture}
            try await ready(createdWeb,host:"safe.alcove.example")
            check(createdStore.activeProfileID==profile && createdStore.websiteProtection === service && createdWindow.isVisible,"The real extension \(kind) window inherits its requesting profile and protection service")
            _=try await createdWeb.evaluateJavaScript("document.getElementById('token').value='owned-extension-draft';true")
            let canceled=URL(string:"http://listed.alcove.example/target?case=extension-\(kind)-cancel")!
            createdWeb.load(URLRequest(url:canceled))
            let heldWarning=try await warning(createdWeb,store:createdStore,url:canceled)
            check(try await requests(port:raw,name:"extension-\(kind)-cancel").isEmpty,"The extension \(kind) warning holds its actual target request")
            try button(heldWarning,continueRequest:false).performClick(nil)
            check((try? await createdWeb.evaluateJavaScript("document.getElementById('token').value==='owned-extension-draft'")) as? Bool==true && createdWeb.url==starting,"Canceling the extension \(kind) warning preserves its actual form and document")
            let continued=URL(string:"http://listed.alcove.example/target?case=extension-\(kind)-continue")!
            createdWeb.load(URLRequest(url:continued))
            let continuedWarning=try await warning(createdWeb,store:createdStore,url:continued)
            try button(continuedWarning,continueRequest:true).performClick(nil)
            try await ready(createdWeb,host:"listed.alcove.example")
            check(try await requests(port:raw,name:"extension-\(kind)-continue").count==1,"Continuing the extension \(kind) warning sends its original request once")
            let closing=URL(string:"http://listed.alcove.example/target?case=extension-\(kind)-close")!
            createdWeb.load(URLRequest(url:closing))
            let closingWarning=try await warning(createdWeb,store:createdStore,url:closing),staleContinue=try button(closingWarning,continueRequest:true)
            createdWindow.close();staleContinue.performClick(nil)
            check(try await requests(port:raw,name:"extension-\(kind)-close").isEmpty,"Closing an extension \(kind) window revokes its pending warning and retained control")
        }
        retainedOptions=nil // Release the fixture's privileged document before requesting actual extension-data erasure.
        store.select(first)
        let clearA=URL(string:"http://listed.alcove.example/target?case=clear-surface-a")!,clearB=URL(string:"http://listed.alcove.example/target?case=clear-surface-b")!
        web.load(URLRequest(url:clearA));other.load(URLRequest(url:clearB))
        let clearWarningA=try await warning(web,store:store,url:clearA),clearWarningB=try await warning(other,store:store,url:clearB)
        let oldA=try button(clearWarningA,continueRequest:true),oldB=try button(clearWarningB,continueRequest:true)
        try await store.clearProfileData(profile);try recordController()
        oldA.performClick(nil);oldB.performClick(nil)
        let afterA=try await requests(port:raw,name:"clear-surface-a"),afterB=try await requests(port:raw,name:"clear-surface-b")
        check(afterA.isEmpty && afterB.isEmpty && store.websiteProtectionTickets.isEmpty,"Profile clearing cancels both real pending split requests and stale controls")
        check(store.library(for:profile).history.isEmpty,"Normal-profile clearing removes the actual owned browsing history")
        print("WEBSITE_PROTECTION_SURFACE_CHECKS",checks,"FAILURES",failures)
        if failures>0 {throw Failure.checks(failures)}
    }
    @MainActor static func run() async throws -> Int32 {
        guard #available(macOS 15.4,*) else {throw Failure.fixture}
        let owned=try OwnedWebsiteStores(),controllers=try OwnedExtensionControllers()
        if CommandLine.arguments.contains("--cleanup-owned-stores") {let a=await controllers.cleanup(),b=await owned.cleanup();return a && b ? 0:1}
        guard await controllers.cleanup(),await owned.cleanup() else {throw Failure.fixture}
        var good=true
        do {try await exercise(owned:owned,controllers:controllers)}catch{good=false;print("WEBSITE_PROTECTION_SURFACE_FAILED",error)}
        let a=await controllers.cleanup(),b=await owned.cleanup();print("WEBSITE_PROTECTION_SURFACE_CLEANUP",a,b)
        return good && a && b ? 0:1
    }
    @MainActor static func main() {
        setbuf(stdout,nil);atexit{if !WebsiteProtectionSurfaceChecks.completed {_exit(86)}}
        NSApplication.shared.setActivationPolicy(.regular)
        Task{@MainActor in do{let status=try await run();completed=true;exit(status)}catch{completed=true;print("WEBSITE_PROTECTION_SURFACE_MAIN_FAILED",error);exit(1)}}
        NSApp.run()
    }
}
