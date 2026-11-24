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
        let owner=BrowserWindowOwner(store:store),lease=try owner.acquirePrimary()
        defer {owner.release(lease);store.shutdown()}
        let profile=try store.createProfile(name:"Owned warning surfaces")
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
        let oldNormalSafe=try button(normalWarning,continueRequest:false)
        oldNormalSafe.performClick(nil)
        check(try await requests(port:raw,name:"normal-surface-cancel").isEmpty,"Normal-profile cancellation never contacts the target")
        check((try? await web.evaluateJavaScript("document.getElementById('token').value==='owned-normal'")) as? Bool==true && store.tab(first)?.url==initial.absoluteString,"Normal cancellation preserves the typed form and displayed address")
        check(!store.library(for:profile).history.contains(where:{$0.url==held.absoluteString}),"A blocked normal navigation is not recorded as a visited page")
        let allowed=URL(string:"http://listed.alcove.example/target?case=normal-surface-continue")!
        store.navigate(allowed.absoluteString)
        let allowedWarning=try await warning(web,store:store,url:allowed)
        try button(allowedWarning,continueRequest:true).performClick(nil)
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
        controller.window?.performClose(nil);oldQuickContinue.performClick(nil)
        check(store.quickPage(quick)==nil && store.websiteProtectionTicket(for:quickWeb)==nil,"Closing the real Quick Browse window cancels its warning")
        check(try await requests(port:raw,name:"quick-surface-close").isEmpty,"A closed Quick Browse warning cannot replay its request")
        window.makeKeyAndOrderFront(nil)
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
