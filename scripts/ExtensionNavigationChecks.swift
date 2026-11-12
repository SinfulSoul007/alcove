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
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let profile = try store.createProfile(name:"Owned navigation gate");try owned.register(profile)
            let host = OwnedDelayedExtensionHost();store.extensionHosting = host
            let tab = store.newTab(), web = store.view(for:tab)
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
            try store.continueWithoutExtensions()
            try await ready(web,failURL)
            check(store.extensionNavigationProblem == nil,"Explicit Continue Without completes the originally requested page")
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
        do {try await exercise()} catch {check(false,"Owned navigation fixture failed: " + error.localizedDescription)}
        check(await owned.cleanup(),"Navigation fixtures release and remove only their owned website stores")
        print("Extension navigation checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
enum OwnedExtensionNavigationError:Error {case fixtureMissing,timedOut}
