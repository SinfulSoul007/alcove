import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedPrivateExtensionError:Error {case missingFixture,timedOut}
@main struct ExtensionPrivateChecks {
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
            try Data(#"{"manifest_version":3,"name":"Owned private fixture","description":"Private lifetime fixture","version":"1","incognito":"spanning","permissions":["storage"],"host_permissions":["http://127.0.0.1/*"],"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["owned.js"],"run_at":"document_end"}]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("document.documentElement.dataset.ownedPrivateExtension='ran';".utf8).write(to:source.appendingPathComponent("owned.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:staging)
            let approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await normal.installExtension(package,approval:approval)
            let normalURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"normal-associated")])
            let normalID = normal.newTab(url:normalURL),normalWeb = normal.view(for:normalID);try await ready(normalWeb,normalURL)
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
            let borrowed = normalWeb.configuration
            let privateWeb = privateStore.view(for:privateStore.selectedID!,configuration:borrowed)
            let deniedURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-denied-owned")])
            privateWeb.load(URLRequest(url:deniedURL));try await ready(privateWeb,deniedURL)
            check(await marker(privateWeb) == nil,"Association alone cannot run an extension without explicit private approval")
            check(privateWeb.configuration.webExtensionController === normalWeb.configuration.webExtensionController,"An associated private view uses only its approved normal account controller")
            let noNormalScripts = try await privateWeb.evaluateJavaScript("document.documentElement.dataset.normalOnly === undefined") as? Bool
            let noNormalCookies = try await privateWeb.evaluateJavaScript("document.cookie === '' && localStorage.getItem('owned_association') === null") as? Bool
            check(privateWeb.configuration.userContentController !== normalWeb.configuration.userContentController && noNormalScripts == true,"Borrowing a normal configuration never imports its user-content controller or scripts into private browsing")
            check(!privateWeb.configuration.websiteDataStore.isPersistent && noNormalCookies == true,"Associated private browsing retains separate temporary cookies and website storage")
            var grant = normal.extensionRecords(profileID:profile).first!.grants!;grant.allowPrivate = true
            try normal.setExtensionGrants(id,profileID:profile,grants:grant);try await normal.prepareExtensions(profileID:profile)
            normal.closePrimaryWindowPages();owner.release(primary);normal.flush()
            let beforePrivate = try canonical(normal.makeDocument())
            check(!owner.isClosed && !normal.isShuttingDown && owner.leaseCount == 1,"The associated private window keeps its normal controller and data owner alive after the normal window closes")
            check(normal.archiveTimer?.isValid != true,"Private-only ownership pauses normal automatic tab archiving")
            let approvedURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-approved-owned")])
            privateWeb.load(URLRequest(url:approvedURL));try await ready(privateWeb,approvedURL)
            check(await marker(privateWeb) == "ran","Explicit private approval enables the real native content script after the normal window closes")
            _ = try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value='keep this private form';true")
            check(try canonical(normal.makeDocument()) == beforePrivate,"Private browsing never serializes its URL or transient session into the normal account")
            check(privateKeyRequests == 0 && !manager.fileExists(atPath:privateRoot.path),"Associated private browsing requests no key and writes no private metadata directory")
            grant.allowPrivate = false;try normal.setExtensionGrants(id,profileID:profile,grants:grant)
            check((try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value === 'keep this private form'")) as? Bool == true,"Revoking private access keeps the current unsaved form mounted")
            let revokedURL = fixture.appending(queryItems:[URLQueryItem(name:"phase",value:"private-revoked-owned")])
            privateWeb.load(URLRequest(url:revokedURL));try await ready(privateWeb,revokedURL)
            check(await marker(privateWeb) == nil,"Revoked private access blocks extension code in the next private document")
            privateStore.shutdown()
            check(owner.isClosed && normal.isShuttingDown && owner.leaseCount == 0,"Closing the last private association releases its auxiliary owner lease and normal writer")
        }
        do {try await exercise()} catch {check(false,"Owned private extension fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Private fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Private fixtures release only their owned named website stores")
        print("Extension private checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
