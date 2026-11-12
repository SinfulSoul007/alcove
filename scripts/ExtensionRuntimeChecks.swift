import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedExtensionRuntimeError:Error { case fixtureMissing, timedOut }
final class OwnedExtensionKeyGate:@unchecked Sendable {
    let started = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
    func key(_ value:SymmetricKey) -> SymmetricKey {started.signal();release.wait();return value}
    func didStart() -> Bool {started.wait(timeout:.now()) == .success}
}

@main struct ExtensionRuntimeChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<500 {
            if web.url == url, !web.isLoading,
               (try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        throw OwnedExtensionRuntimeError.timedOut
    }
    @MainActor static func marker(_ web:WKWebView) async -> String? {
        (try? await web.evaluateJavaScript("document.documentElement.dataset.alcoveExtensionFixture || null")) as? String
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else { print("UNAVAILABLE: Native extensions require macOS15.4; the browser remains available."); return }
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        if CommandLine.arguments.contains("--cleanup-owned-stores") {
            let extensionClean = await controllers.cleanup(), websiteClean = await owned.cleanup()
            exit(extensionClean && websiteClean ? 0 : 1)
        }
        guard await controllers.cleanup(), await owned.cleanup() else { exit(1) }
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"], let fixture = URL(string:address) else { throw OwnedExtensionRuntimeError.fixtureMissing }
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at:root) }
        let key = SymmetricKey(data:Data(repeating:73,count:32))
        var failures = 0
        func check(_ value:Bool,_ name:String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name:String,_ body:()async throws -> Void) async { do {try await body();check(false,name)} catch {check(true,name)} }
        func exercise() async throws {
        let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
        defer {store.shutdown()}
        let profile = try store.createProfile(name:"Owned runtime A"), firstSpace = store.space.id
        try owned.register(profile); try controllers.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
        let source = root.appendingPathComponent("mv3"), staging = root.appendingPathComponent("staging")
        try manager.createDirectory(at:source,withIntermediateDirectories:true)
        try Data(#"{"manifest_version":3,"name":"Owned runtime MV3","version":"1","permissions":["storage"],"host_permissions":["http://127.0.0.1/*"],"optional_host_permissions":["https://example.invalid/*"],"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["owned.js"],"run_at":"document_start"}]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.alcoveExtensionFixture='mv3';".utf8).write(to:source.appendingPathComponent("owned.js"))
        let prepared = try ExtensionPackage.prepare(at:source,stagingRoot:staging)
        let approval = try store.extensionInstallApproval(for:prepared,profileID:profile,permissions:["storage"],enable:true)
        let id = try await store.installExtension(prepared,approval:approval)
        let page = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"no-host-grant")])
        let tabID = store.newTab(url:page)
        var web:WKWebView? = store.view(for:tabID)
        try await ready(web!,page)
        check(await marker(web!) == nil,"An enabled MV3 package cannot inject before explicit site approval")
        check(web!.configuration.webExtensionController != nil,"A browser-created view receives its profile controller before navigation")
        var record = store.extensionRecords(profileID:profile).first!
        var grant = record.grants!; grant.hostPatterns = ["http://127.0.0.1/*"]
        try store.setExtensionGrants(id,profileID:profile,grants:grant)
        try await store.prepareExtensions(profileID:profile)
        let approved = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"approved")])
        web!.load(URLRequest(url:approved)); try await ready(web!,approved)
        for _ in 0..<200 { if await marker(web!) == "mv3" { break }; try await Task.sleep(for:.milliseconds(10)) }
        check(await marker(web!) == "mv3","An approved package runs its actual MV3 content script in the owning browser account")
        check(store.extensionDiagnostics[profile]?[id]?.isEmpty == false,"Native optional-manifest diagnostics remain visible instead of silently disappearing")
        let native = web!.configuration.webExtensionController!, context = native.extensionContexts.first!
        check(!context.hasAccess(to:URL(string:"https://example.invalid/private")!),"Optional sites remain inaccessible until separately approved")
        check(!context.hasAccess(to:URL(fileURLWithPath:"/tmp/alcove-extension-unapproved")),"Browser site approval never grants native local-file access")
        let other = try store.createProfile(name:"Owned runtime B")
        try owned.register(other); try controllers.register(store.profiles.first(where:{$0.id == other})!.extensionControllerID!)
        let otherPage = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"other-account")])
        let otherID = store.newTab(url:otherPage); var otherWeb:WKWebView? = store.view(for:otherID)
        try await ready(otherWeb!,otherPage)
        check(await marker(otherWeb!) == nil,"The same website in another account never inherits the first account's code")
        check(otherWeb!.configuration.webExtensionController !== native,"Each browser account receives its own native controller")
        store.selectSpace(firstSpace)
        try store.setExtensionEnabled(id,profileID:profile,enabled:false)
        let disabled = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"disabled")])
        web!.load(URLRequest(url:disabled)); try await ready(web!,disabled)
        check(await marker(web!) == nil,"Disabling saves and unloads native code before the next document")
        check(native.extensionContexts.isEmpty,"Disable removes the actual loaded native context")
        try store.setExtensionEnabled(id,profileID:profile,enabled:true)
        try await store.prepareExtensions(profileID:profile)
        record = store.extensionRecords(profileID:profile).first!
        let installed = store.extensionPackagesRoot.appendingPathComponent(profile.uuidString).appendingPathComponent((record.packageID ?? record.id).uuidString).appendingPathComponent(record.packageDigest)
        try Data("document.documentElement.dataset.alcoveExtensionFixture='tampered';".utf8).write(to:installed.appendingPathComponent("owned.js"))
        await rejects("Retry refuses resources changed after the encrypted digest was approved") { try await store.retryExtensions(profileID:profile) }
        check(native.extensionContexts.isEmpty,"A damaged revision is unloaded instead of running changed code")
        let mv2Source = root.appendingPathComponent("mv2")
        try manager.createDirectory(at:mv2Source,withIntermediateDirectories:true)
        try Data(#"{"manifest_version":2,"name":"Owned runtime MV2","version":"1","permissions":["<all_urls>"],"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["owned.js"],"run_at":"document_end"}]}"#.utf8).write(to:mv2Source.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.alcoveExtensionFixture='mv2';".utf8).write(to:mv2Source.appendingPathComponent("owned.js"))
        let mv2 = try ExtensionPackage.prepare(at:mv2Source,stagingRoot:staging)
        let mv2Approval = try store.extensionInstallApproval(for:mv2,profileID:other,hostPatterns:["<all_urls>"],enable:true)
        let mv2ID = try await store.installExtension(mv2,approval:mv2Approval)
        do {
            try await store.prepareExtensions(profileID:other)
            let mv2URL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"mv2-all-sites")])
            otherWeb!.load(URLRequest(url:mv2URL)); try await ready(otherWeb!,mv2URL)
            check(await marker(otherWeb!) == "mv2","An owned MV2 package runs after explicit all-web-sites approval")
            let mv2Context = otherWeb!.configuration.webExtensionController!.extensionContexts.first!
            check(mv2Context.hasAccess(to:URL(string:"https://example.org/approved")!),"All-web-sites approval covers ordinary HTTPS sites")
            check(!mv2Context.hasAccess(to:URL(fileURLWithPath:"/tmp/not-approved")) && !mv2Context.hasAccess(to:URL(string:"ftp://example.org/secret")!),"Native all-sites translation excludes both file and FTP access")
            var denied = store.extensionRecords(profileID:other).first(where:{$0.id == mv2ID})!.grants!
            denied.deniedHostPatterns = ["https://example.invalid/*"]
            try store.setExtensionGrants(mv2ID,profileID:other,grants:denied)
            try await store.prepareExtensions(profileID:other)
            let deniedContext = otherWeb!.configuration.webExtensionController!.extensionContexts.first!
            check(!deniedContext.hasAccess(to:URL(string:"https://example.invalid/private")!),"An explicit native site denial wins over an all-sites grant")
            try store.setExtensionEnabled(mv2ID,profileID:other,enabled:false)
            try store.setExtensionEnabled(mv2ID,profileID:other,enabled:true)
            store.selectSpace(store.session.spaces.first(where:{$0.effectiveProfileID == other})!.id)
            let automaticURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"automatic-startup")])
            let automaticID = store.newTab(url:automaticURL), automaticWeb = store.view(for:automaticID)
            try await ready(automaticWeb,automaticURL)
            check(await marker(automaticWeb) == "mv2","The actual navigation delegate loads approved contexts before a newly created page proceeds")
            let quickURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"quick")])
            let quickID = try store.openQuickPage(url:quickURL,profileID:other), quickWeb = store.view(for:quickID)
            try await ready(quickWeb,quickURL)
            check(await marker(quickWeb) == "mv2","A real Quick Browse page receives the account's approved content script")
            let popupConfiguration = WKWebViewConfiguration()
            let popupWeb = store.createPopup(from:quickWeb,configuration:popupConfiguration)!
            let popupURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"quick-popup")])
            popupWeb.load(URLRequest(url:popupURL));try await ready(popupWeb,popupURL)
            check(await marker(popupWeb) == "mv2" && store.quickContext(for:popupWeb)?.profileID == other,"Popup creation wires the supplied Quick configuration to its actual owning account")
            let peekURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"peek")])
            store.openPeek(peekURL,from:quickWeb)
            let peekWeb = store.quickPeekView(quickID)!
            try await ready(peekWeb,peekURL)
            check(await marker(peekWeb) == "mv2","A real Peek is configured for approved extensions before its first document")
            check(peekWeb.configuration.webExtensionController === automaticWeb.configuration.webExtensionController && popupWeb.configuration.webExtensionController === automaticWeb.configuration.webExtensionController,"Main, Quick, Peek and popup pages share only the same account's controller")
            store.closeQuickPeek(quickID)
            let borrowed = WKWebViewConfiguration();borrowed.webExtensionController = automaticWeb.configuration.webExtensionController
            let unowned = store.view(for:UUID(),configuration:borrowed)
            check(unowned.configuration.webExtensionController == nil && !unowned.configuration.websiteDataStore.isPersistent,"Unknown tab ownership strips a supplied extension controller and uses temporary storage")
        } catch {check(false,"Owned MV2 all-sites hosting failed: " + error.localizedDescription)}
        var privateKeyRequests = 0
        let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in privateKeyRequests += 1; return key})
        let privateConfiguration = WKWebViewConfiguration();privateConfiguration.webExtensionController = otherWeb!.configuration.webExtensionController
        var privateWeb:WKWebView? = privateStore.view(for:privateStore.selectedID!,configuration:privateConfiguration)
        check(privateKeyRequests == 0 && privateWeb!.configuration.webExtensionController == nil,"Standalone private startup never requests a normal key or persistent extension controller")
        let privateURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-denied")])
        privateWeb!.load(URLRequest(url:privateURL));try await ready(privateWeb!,privateURL)
        check(await marker(privateWeb!) == nil,"A private page cannot inherit code from a caller-supplied normal controller")
        check(!manager.fileExists(atPath:privateStore.sessionURL.path),"Standalone private browsing writes no normal extension metadata")
        privateStore.shutdown(); privateWeb = nil
        let keyGate = OwnedExtensionKeyGate(), blockedRoot = root.appendingPathComponent("blocked-normal")
        let access = MetadataKeyAccess {_,_ in keyGate.key(key)}
        let blocked = BrowserStore(dataRoot:blockedRoot,metadataKeyAccess:access)
        for _ in 0..<200 {if keyGate.didStart() {break};try await Task.sleep(for:.milliseconds(5))}
        let blockedWeb = blocked.view(for:blocked.selectedID!)
        check(blocked.awaitingInitialMetadata && blocked.extensionHosting == nil && blockedWeb.configuration.webExtensionController == nil && !blockedWeb.configuration.websiteDataStore.isPersistent,"Key-pending normal startup creates no persistent extension controller or fallback website store")
        blocked.shutdown();keyGate.release.signal()
        check(!manager.fileExists(atPath:blocked.sessionURL.path),"Closing a key-pending extension session does not create sealed metadata")
        store.shutdown(); web = nil; otherWeb = nil
        }
        do {try await exercise()} catch {check(false,"Owned runtime exercise failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Owned native extension runtime records are erased through the public framework API")
        check(await owned.cleanup(),"Owned named website stores are removed without touching real browser profiles")
        print("Extension runtime checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
