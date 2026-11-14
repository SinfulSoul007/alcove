import AppKit
import WebKit
import CryptoKit
import BrowserCore

/// Only the slow external host boundary is controlled. BrowserStore's real navigation,
/// document identities, views, metadata commits and decision completion remain under test.
@MainActor final class OwnedDelayedExtensionHost:BrowserExtensionHosting {
    var ready = false, starts = 0
    private var waiting:[CheckedContinuation<Void,Error>] = []
    func configure(_ configuration:WKWebViewConfiguration,profileID:UUID) {}
    func requiresPreparation(profileID:UUID) -> Bool {!ready}
    func matches(_ configuration:WKWebViewConfiguration,profileID:UUID) -> Bool {true}
    func prepare(profileID:UUID) async throws {
        if ready {return}
        starts += 1
        try await withCheckedThrowingContinuation {waiting.append($0)}
    }
    func release(_ error:Error? = nil) {
        ready = error == nil
        let values = waiting; waiting = []
        for value in values {if let error {value.resume(throwing:error)} else {value.resume()}}
    }
    func invalidate(profileID:UUID) {ready = false}
    func continueWithout(profileID:UUID) throws {ready = true}
    func refresh() {}
    func shutdown() {release(ExtensionHostError.closed)}
}
@MainActor final class OwnedWeakExtensionStore {
    weak var value:BrowserStore?
    init(_ value:BrowserStore) {self.value = value}
}
@MainActor final class OwnedUnsupportedExtensionNavigation:WKNavigationAction {
    let ownedRequest:URLRequest
    init(_ url:URL) {ownedRequest = URLRequest(url:url);super.init()}
    override var request:URLRequest {ownedRequest}
    override var targetFrame:WKFrameInfo? {nil}
    override var navigationType:WKNavigationType {.other}
}

@main struct ExtensionNavigationChecks {
    @MainActor static func until(_ condition:() -> Bool) async throws {
        for _ in 0..<400 {if condition() {return};try await Task.sleep(for:.milliseconds(5))}
        throw OwnedExtensionNavigationError.timedOut
    }
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<500 {
            if web.url == url, !web.isLoading, (try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionNavigationError.timedOut
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        let owned = try OwnedWebsiteStores()
        guard await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"], let fixture = URL(string:address) else {throw OwnedExtensionNavigationError.fixtureMissing}
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString), key = SymmetricKey(data:Data(repeating:19,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ description:String) {print("\(value ? "PASS" : "FAIL"): \(description)");if !value {failures += 1}}
        func button(_ name:String,in view:NSView) -> NSButton? {
            if let value=view as? NSButton,value.identifier?.rawValue=="extension.recovery."+name {return value}
            for child in view.subviews {if let found=button(name,in:child) {return found}}
            return nil
        }
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let profile = try store.createProfile(name:"Owned navigation gate");try owned.register(profile)
            let host = OwnedDelayedExtensionHost();store.extensionHosting = host
            let tab = store.newTab(), web = store.view(for:tab)
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;store.registerExtensionWindow(window,kind:.primary)
            let edge=EdgeToEdgeWebHost(frame:NSRect(x:0,y:0,width:800,height:600));edge.setContent(web);edge.setRecovery(store:store,webView:web)
            window.contentView=edge
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView=nil;window.close()}

            let firstURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"first")])
            let nextURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"newer")])
            var first:[WKNavigationActionPolicy] = [], newer:[WKNavigationActionPolicy] = []
            store.decideExtensionNavigation(web,url:firstURL,isMainFrame:true,allow:.allow) {first.append($0)}
            try await until {host.starts == 1}
            check(first.isEmpty,"A real browser decision remains pending while its extension host prepares")
            store.decideExtensionNavigation(web,url:nextURL,isMainFrame:true,allow:.download) {newer.append($0)}
            try await until {host.starts == 2}
            check(first == [.cancel] && newer.isEmpty,"A newer main navigation cancels the superseded decision exactly once")
            host.release();try await until {!newer.isEmpty}
            check(first == [.cancel] && newer == [.download],"Late preparation preserves the newer download decision without reviving the old navigation")
            host.invalidate(profileID:profile)
            var superseded:[WKNavigationActionPolicy] = [],unsupported:[WKNavigationActionPolicy] = []
            let beforeUnsupported = host.starts
            store.decideExtensionNavigation(web,url:firstURL,isMainFrame:true,allow:.allow) {superseded.append($0)}
            try await until {host.starts == beforeUnsupported + 1}
            store.webView(web,decidePolicyFor:OwnedUnsupportedExtensionNavigation(URL(string:"mailto:owned@example.invalid")!)) {unsupported.append($0)}
            host.release();try await until {!superseded.isEmpty}
            check(unsupported == [.cancel] && superseded == [.cancel],"Even a rejected newer scheme cancels an earlier pending extension navigation")
            host.invalidate(profileID:profile)
            let closingID = store.newTab(), closingWeb = store.view(for:closingID)
            var closed:[WKNavigationActionPolicy] = []
            let beforeClose = host.starts
            store.decideExtensionNavigation(closingWeb,url:firstURL,isMainFrame:true,allow:.allow) {closed.append($0)}
            try await until {host.starts == beforeClose + 1}
            store.discardView(closingID);host.release()
            try await until {!closed.isEmpty}
            check(closed == [.cancel],"Closing the source page drains its pending decision and rejects a late host reply")
            let formURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"form")])
            web.load(URLRequest(url:formURL));try await ready(web,formURL)
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep this owned form';true")
            host.invalidate(profileID:profile)
            let failURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"host-failed")])
            let beforeFailure = host.starts
            web.load(URLRequest(url:failURL));try await until {host.starts > beforeFailure}
            check((try await web.evaluateJavaScript("document.getElementById('owned-form')?.value === 'keep this owned form'")) as? Bool == true,"The mounted page and unsaved form survive while new navigation waits")
            host.release(ExtensionHostError.damaged)
            try await until {store.extensionNavigationProblem != nil}
            check((try await web.evaluateJavaScript("document.getElementById('owned-form')?.value === 'keep this owned form'")) as? Bool == true,"A host failure cancels the navigation without reloading the existing form")
            try await until {button("without",in:edge) != nil}
            let keptFrame=web.frame
            button("without",in:edge)!.performClick(nil)
            try await ready(web,failURL)
            check(web.superview === edge && web.frame==keptFrame,"The real recovery control keeps the mounted website and viewport instead of replacing its form host")
            check(store.extensionNavigationProblem == nil,"Explicit Continue Without completes the originally requested page")
            let headerURL=fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"retry-header")])
            var request=URLRequest(url:headerURL);request.setValue("owned-header-kept",forHTTPHeaderField:"X-Owned-Recovery")
            host.invalidate(profileID:profile);let beforeHeader=host.starts
            web.load(request);try await until {host.starts>beforeHeader};host.release(ExtensionHostError.damaged)
            try await until {store.extensionNavigationProblem != nil && button("retry",in:edge) != nil}
            let beforeRetry=host.starts;button("retry",in:edge)!.performClick(nil)
            try await until {host.starts>beforeRetry};host.release();try await ready(web,headerURL)
            check((try await web.evaluateJavaScript("document.body.dataset.ownedRecovery === 'owned-header-kept'")) as? Bool==true,"The production Retry control preserves the original GET request headers")
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep POST form';true")
            host.invalidate(profileID:profile);let beforePost=host.starts
            _ = try? await web.callAsyncJavaScript("const f=document.createElement('form');f.method='POST';f.action=target;const v=document.createElement('input');v.name='owned';v.value='fake-owned-payload';f.appendChild(v);document.body.appendChild(f);f.submit();return true;",arguments:["target":fixture.appendingPathComponent("owned-post").absoluteString],in:nil,contentWorld:.page)
            try await until {host.starts>beforePost};host.release(ExtensionHostError.damaged)
            try await until {store.extensionNavigationProblem != nil && button("retry",in:edge) != nil}
            check(store.extensionNavigationProblem?.request.httpMethod=="POST","The real form navigation retains its POST identity for recovery")
            let beforePostRetry=host.starts;button("retry",in:edge)!.performClick(nil)
            try await until {host.starts>beforePostRetry};host.release()
            try await until {store.extensionNavigationProblem?.recoveryNotice != nil}
            let postKept=(try await web.evaluateJavaScript("document.getElementById('owned-form')?.value === 'keep POST form'")) as? Bool==true
            check(web.url==headerURL && postKept,"Retrying extension setup never turns a POST into GET or destroys the unsent form")
            try await until {button("dismiss",in:edge) != nil};button("dismiss",in:edge)!.performClick(nil)
            for (isMain,policy,label) in [(false,WKNavigationActionPolicy.allow,"embedded frame"),(true,WKNavigationActionPolicy.download,"download")] {
                host.invalidate(profileID:profile);let before=host.starts
                store.decideExtensionNavigation(web,url:fixture.appendingPathComponent("owned-"+label.replacingOccurrences(of:" ",with:"-")),isMainFrame:isMain,allow:policy){_ in}
                try await until {host.starts>before};host.release(ExtensionHostError.damaged)
                try await until {store.extensionNavigationProblem != nil && button("without",in:edge) != nil}
                button("without",in:edge)!.performClick(nil)
                let kept=(try await web.evaluateJavaScript("document.getElementById('owned-form')?.value === 'keep POST form'")) as? Bool==true
                check(web.url==headerURL && kept && store.extensionNavigationProblem?.recoveryNotice != nil,"An explicit bypass does not replay a \(label) as a top-level GET")
                try await until {button("dismiss",in:edge) != nil};button("dismiss",in:edge)!.performClick(nil)
            }
            host.invalidate(profileID:profile);let beforeStale=host.starts
            store.decideExtensionNavigation(web,url:firstURL,isMainFrame:true,allow:.allow){_ in}
            try await until {host.starts>beforeStale};host.release(ExtensionHostError.damaged)
            try await until {button("without",in:edge) != nil}
            let staleButton=button("without",in:edge)!,newRequest=fixture.appendingPathComponent("owned-newer-than-recovery")
            let beforeNew=host.starts;web.load(URLRequest(url:newRequest));try await until {host.starts>beforeNew}
            if let action=staleButton.action,let target=staleButton.target {_ = NSApp.sendAction(action,to:target,from:staleButton)}
            check(!host.ready,"An old recovery button cannot bypass extensions for a newer request")
            host.release();try await ready(web,newRequest)
            host.invalidate(profileID:profile)
            var timedOut:[WKNavigationActionPolicy] = []
            let beforeTimeout = host.starts
            store.decideExtensionNavigation(web,url:firstURL,isMainFrame:true,allow:.allow,timeout:.milliseconds(35)) {timedOut.append($0)}
            try await until {host.starts > beforeTimeout};try await until {!timedOut.isEmpty}
            host.release();try await Task.sleep(for:.milliseconds(15))
            check(timedOut == [.cancel],"A hung preparation times out once and cannot later authorize navigation")
            host.invalidate(profileID:profile)
            var clearing:[WKNavigationActionPolicy] = []
            let beforeClear = host.starts
            store.decideExtensionNavigation(web,url:firstURL,isMainFrame:true,allow:.allow) {clearing.append($0)}
            try await until {host.starts > beforeClear}
            var pending = store.makeDocument()
            if let index = pending.profiles?.firstIndex(where:{$0.id == profile}) {pending.profiles?[index].pendingDataClear = true}
            try store.commitProfileDocument(pending)
            host.release();try await until {!clearing.isEmpty}
            check(clearing == [.cancel],"A durable profile-clear intent invalidates pending host decisions before loading another page")
            var abandoned:BrowserStore? = BrowserStore(dataRoot:root.appendingPathComponent("abandoned"),keyProvider:{_ in key})
            let abandonedProfile = try abandoned!.createProfile(name:"Owned abandoned navigation");try owned.register(abandonedProfile)
            let abandonedHost = OwnedDelayedExtensionHost();abandoned!.extensionHosting = abandonedHost
            var abandonedWeb:WKWebView? = abandoned!.view(for:abandoned!.selectedID!)
            let weakStore = OwnedWeakExtensionStore(abandoned!)
            var abandonedReplies:[WKNavigationActionPolicy] = []
            abandoned!.decideExtensionNavigation(abandonedWeb!,url:firstURL,isMainFrame:true,allow:.allow) {abandonedReplies.append($0)}
            try await until {abandonedHost.starts == 1}
            abandoned!.shutdown();abandonedWeb = nil;abandoned = nil
            try await until {weakStore.value == nil}
            check(abandonedReplies == [.cancel] && weakStore.value == nil,"Shutdown completes navigation and releases the owner even while preparation is outstanding")
        }
        func unavailableExercise() async throws {
            let store=BrowserStore(dataRoot:root.appendingPathComponent("unavailable"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let profile=try store.createProfile(name:"Owned unavailable native API");try owned.register(profile)
            let unavailable=UnavailableBrowserExtensionHost(owner:store);store.extensionHosting=unavailable
            let id=store.newTab(),web=store.view(for:id),form=fixture.appendingPathComponent("owned-unavailable-form")
            web.load(URLRequest(url:form));try await ready(web,form)
            check(!unavailable.requiresPreparation(profileID:profile),"An unavailable native API still permits immediate ordinary browsing when no extension is expected")
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;store.registerExtensionWindow(window,kind:.primary)
            let edge=EdgeToEdgeWebHost(frame:NSRect(x:0,y:0,width:800,height:600));edge.setContent(web);edge.setRecovery(store:store,webView:web);window.contentView=edge
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView=nil;window.close()}
            let source=root.appendingPathComponent("unavailable-source");try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned expected extension","version":"1","permissions":["storage"]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            let package=try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("unavailable-staging"))
            let approval=try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],enable:true)
            let extensionID=try await store.installExtension(package,approval:approval)
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep unavailable form';true")
            let target=fixture.appendingPathComponent("owned-unavailable-target");web.load(URLRequest(url:target))
            try await until {store.extensionNavigationProblem != nil && button("without",in:edge) != nil}
            let kept=(try await web.evaluateJavaScript("document.getElementById('owned-form')?.value === 'keep unavailable form'")) as? Bool==true
            check(web.url==form && kept && unavailable.requiresPreparation(profileID:profile),"An enabled saved extension on an unavailable engine blocks navigation visibly and preserves the mounted form")
            button("without",in:edge)!.performClick(nil);try await ready(web,target)
            check(!unavailable.requiresPreparation(profileID:profile) && store.extensionRecords(profileID:profile).first?.enabled==true,"Explicit Continue Without is session-only and never clears the saved enabled approval")
            try store.setExtensionEnabled(extensionID,profileID:profile,enabled:false);try store.setExtensionEnabled(extensionID,profileID:profile,enabled:true)
            check(unavailable.requiresPreparation(profileID:profile),"Changing the expected catalog invalidates an unavailable-engine bypass")
        }
        do {try await exercise();try await unavailableExercise()} catch {check(false,"Owned navigation fixture failed: " + error.localizedDescription)}
        check(await owned.cleanup(),"Navigation fixtures release and remove only their owned website stores")
        print("Extension navigation checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
enum OwnedExtensionNavigationError:Error {case fixtureMissing,timedOut}
