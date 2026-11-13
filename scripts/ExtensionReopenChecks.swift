import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedExtensionReopenError:Error {case missingFixture,timedOut}
@MainActor final class OwnedExtensionReopenWindow:NSWindow {
    override var isKeyWindow:Bool {true}
    override func makeKeyAndOrderFront(_ sender:Any?) {}
}
@main struct ExtensionReopenChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<700 {
            if web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionReopenError.timedOut
    }
    @MainActor static func waitFor(_ condition:@escaping @MainActor ()->Bool) async throws {
        for _ in 0..<700 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        throw OwnedExtensionReopenError.timedOut
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Extension reopen fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedExtensionReopenError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:151,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func canonical(_ document:BrowserDocument) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(document)}
        func exercise() async throws {
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary(),profile = try normal.createProfile(name:"Owned reopen account")
            defer {owner.release(primary)}
            try owned.register(profile);try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let source = root.appendingPathComponent("source")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned reopen","version":"1","host_permissions":["http://127.0.0.1/*"],"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["script.js"],"run_at":"document_end"}]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("document.documentElement.dataset.ownedReopen='approved';".utf8).write(to:source.appendingPathComponent("script.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,hostPatterns:["http://127.0.0.1/*"],allowPrivate:true,enable:true)
            let id = try await normal.installExtension(package,approval:approval)
            try await normal.prepareExtensions(profileID:profile)
            var keyRequests = 0
            let privateRoot = root.appendingPathComponent("private"),client = BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in keyRequests += 1;throw CocoaError(.fileReadNoPermission)})
            defer {client.shutdown()}
            let tabID = client.selectedID!,url = fixture.appendingPathComponent("reopen-source"),web = client.view(for:tabID)
            client.update(tabID){$0.url = url.absoluteString};web.load(URLRequest(url:url));try await ready(web,url)
            let window = OwnedExtensionReopenWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = web;client.registerExtensionWindow(window,kind:.primary)
            defer {client.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep before consent';document.cookie='owned_reopen_cookie=private; path=/';true")
            var reviews:[PrivateExtensionReopenReview] = [],replies:[(Bool)->Void] = [],dismissed = 0,results:[Result<Void,Error>] = []
            let prompt = PrivateExtensionReopenPrompt(confirm:{_,review,reply in reviews.append(review);replies.append(reply);return {dismissed += 1}})
            let before = try canonical(normal.makeDocument()),oldUCC = web.configuration.userContentController
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            check(reviews.count == 1 && reviews[0].usesExtensions && reviews[0].pageCount == 1 && reviews[0].profileName == "Owned reopen account" && results.isEmpty,"Reopening presents the captured normal account and reload scope before changing a private page")
            let pendingForm = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'keep before consent' && document.documentElement.dataset.ownedReopen === undefined") as? Bool
            check(client.views[tabID] === web && client.extensionHosting == nil && pendingForm == true,"Waiting for reopen consent retains the original private document and unsaved form without extensions")
            var overlapping:[Result<Void,Error>] = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){overlapping.append($0)}
            check(reviews.count == 1 && overlapping.count == 1,"One private session cannot accumulate concurrent reopen sheets")
            replies[0](false);replies[0](true)
            check(results.count == 1 && dismissed == 1 && client.views[tabID] === web && client.extensionHosting == nil && owner.leaseCount == 1,"Cancelling releases the candidate lease and ignores a duplicate late approval")
            results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            replies.last?(true);try await waitFor{results.count == 1}
            try results[0].get()
            guard var enabled = client.views[tabID] else {throw OwnedExtensionReopenError.missingFixture}
            window.contentView = enabled;try await ready(enabled,url)
            let enabledState = try await enabled.evaluateJavaScript("document.documentElement.dataset.ownedReopen === 'approved' && document.cookie.includes('owned_reopen_cookie=private') && document.getElementById('owned-form').value === ''") as? Bool
            check(enabled !== web && enabled.configuration.userContentController !== oldUCC && enabled.configuration.websiteDataStore === client.privateDataStore && enabledState == true,"Confirmed reopen uses a fresh controller and real approved injection while retaining only the private website store")
            let after = try canonical(normal.makeDocument())
            check(before == after && owner.leaseCount == 2 && keyRequests == 0 && !manager.fileExists(atPath:privateRoot.path),"Approved reopen holds one auxiliary lease without normal session changes, private key requests or metadata writes")
            let priorAssociation = client.extensionHosting,priorView = enabled,priorController = enabled.configuration.webExtensionController
            results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            replies.last?(true);try await waitFor{results.count == 1};try results[0].get()
            guard let refreshed = client.views[tabID] else {throw OwnedExtensionReopenError.missingFixture}
            window.contentView = refreshed;try await ready(refreshed,url);enabled = refreshed
            let server = normal.extensionHosting as! NativeBrowserExtensionHost
            check(refreshed !== priorView && client.extensionHosting !== priorAssociation && refreshed.configuration.webExtensionController === priorController && owner.leaseCount == 2 && server.isAssociated(client,profileID:profile),"Replacing an existing association acquires its new lease before retiring the old one and retains the live controller registry")
            _ = try await enabled.evaluateJavaScript("document.getElementById('owned-form').value='keep after preparation';true")
            let liveAssociation = client.extensionHosting,actualTarget = try NativePrivateExtensionReopenTarget(client:client,owner:owner,profileID:profile),actual = actualTarget.destination
            var preparedReply:CheckedContinuation<Void,Never>?,published = 0,delayedResults:[Result<Void,Error>] = []
            defer {preparedReply?.resume()}
            // Only completion of the real candidate preparation is held. Native package,
            // context, store, permission, lease, source and page state remain real.
            let delayed = PrivateExtensionReopenDestination(profileName:actual.profileName,usesExtensions:true,current:actual.current,prepare:{
                try await actual.prepare();await withCheckedContinuation{preparedReply = $0}
            },publish:{published += 1;actual.publish($0)},close:actual.close)
            let captured = try PrivateExtensionReopenSource(client:client,window:window),job = PrivateExtensionReopenJob(source:captured,destination:delayed){delayedResults.append($0)}
            client.privateExtensionReopenJob = job;job.start(prompt:prompt,duration:.seconds(60));replies.last?(true)
            try await waitFor{preparedReply != nil}
            client.webView(enabled,didStartProvisionalNavigation:nil)
            let resume = preparedReply;preparedReply = nil;resume?.resume();try await waitFor{delayedResults.count == 1}
            let retainedAfterPrepare = try await enabled.evaluateJavaScript("document.getElementById('owned-form').value === 'keep after preparation'") as? Bool
            check(published == 0 && (try? delayedResults[0].get()) == nil && client.views[tabID] === enabled && client.extensionHosting === liveAssociation && retainedAfterPrepare == true && owner.leaseCount == 2 && server.isAssociated(client,profileID:profile),"Navigation after real preparation prevents publication and releases only the candidate lease, preserving the previous association and form")
            let record = normal.extensionRecords(profileID:profile).first!,installed = try ExtensionPackage.inspectInstalled(record:record,profileID:profile,packagesRoot:normal.extensionPackagesRoot),script = installed.url.appendingPathComponent("script.js"),originalScript = try Data(contentsOf:script)
            try Data("document.documentElement.dataset.ownedReopen='changed';".utf8).write(to:script)
            server.invalidate(profileID:profile);results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            replies.last?(true);try await waitFor{results.count == 1}
            check((try? results[0].get()) == nil && client.views[tabID] === enabled && client.extensionHosting === liveAssociation && owner.leaseCount == 2,"A real tampered-package preparation failure leaves the original private page and association in place")
            try originalScript.write(to:script)
            let quickURL = fixture.appendingPathComponent("private-quick-reopen"),quickID = try client.openQuickPage(url:quickURL,profileID:BrowserProfile.defaultID,intendedSpaceID:client.space.id),quick = client.view(for:quickID)
            let quickWindow = OwnedExtensionReopenWindow(contentRect:NSRect(x:0,y:0,width:500,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            quickWindow.isReleasedWhenClosed = false;quickWindow.contentView = quick;client.registerExtensionWindow(quickWindow,kind:.quick(quickID))
            defer {client.unregisterExtensionWindow(kind:.quick(quickID));quickWindow.contentView = nil;quickWindow.close()}
            try await ready(quick,quickURL)
            _ = try await quick.evaluateJavaScript("document.getElementById('owned-form').value='keep compact form';true")
            results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            check(reviews.last?.pageCount == 2 && client.views[tabID] === enabled && client.views[quickID] === quick,"The reopen review includes both actual main and compact pages before replacing either")
            replies.last?(true);try await waitFor{results.count == 1};try results[0].get()
            guard let reopenedMain = client.views[tabID],let reopenedQuick = client.views[quickID] else {throw OwnedExtensionReopenError.missingFixture}
            window.contentView = reopenedMain;quickWindow.contentView = reopenedQuick
            try await ready(reopenedMain,url);try await ready(reopenedQuick,quickURL);enabled = reopenedMain
            let quickInjected = try await reopenedQuick.evaluateJavaScript("document.documentElement.dataset.ownedReopen === 'approved' && document.getElementById('owned-form').value === ''") as? Bool
            check(reopenedQuick !== quick && reopenedQuick.configuration.userContentController === reopenedMain.configuration.userContentController && quickInjected == true && owner.leaseCount == 2,"One confirmed session reload recreates main and compact pages with the same fresh private content controller and one association lease")
            client.unregisterExtensionWindow(kind:.quick(quickID));try client.closeQuickPage(quickID);quickWindow.contentView = nil;quickWindow.close()
            _ = try await enabled.evaluateJavaScript("document.getElementById('owned-form').value='keep until disabled';true")
            let enabledUCC = enabled.configuration.userContentController
            results = []
            client.requestReopenPrivateWithoutExtensions(from:window,confirmation:prompt){results.append($0)}
            check(reviews.last?.usesExtensions == false && client.views[tabID] === enabled,"Turning extensions off also waits for explicit reload consent")
            replies.last?(true);try await waitFor{results.count == 1};try results[0].get()
            guard let disabled = client.views[tabID] else {throw OwnedExtensionReopenError.missingFixture}
            window.contentView = disabled;try await ready(disabled,url)
            let disabledState = try await disabled.evaluateJavaScript("document.documentElement.dataset.ownedReopen === undefined && document.cookie.includes('owned_reopen_cookie=private')") as? Bool
            check(disabled !== enabled && disabled.configuration.userContentController !== enabledUCC && disabled.configuration.webExtensionController == nil && disabledState == true && client.extensionHosting == nil && owner.leaseCount == 1,"Confirmed reopen without extensions removes the old native and content controllers and releases only its association lease")
            _ = try await disabled.evaluateJavaScript("document.getElementById('owned-form').value='keep stale form';true")
            results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            client.webView(disabled,didStartProvisionalNavigation:nil);replies.last?(true)
            try await waitFor{results.count == 1}
            let staleForm = try await disabled.evaluateJavaScript("document.getElementById('owned-form').value === 'keep stale form'") as? Bool
            check((try? results[0].get()) == nil && client.views[tabID] === disabled && staleForm == true && client.extensionHosting == nil,"An approval captured before source navigation cannot replace the current private document")
            results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            var grants = normal.extensionRecords(profileID:profile).first!.grants!;grants.allowPrivate = false
            try normal.setExtensionGrants(id,profileID:profile,grants:grants);replies.last?(true);try await waitFor{results.count == 1}
            check((try? results[0].get()) == nil && client.views[tabID] === disabled && client.extensionHosting == nil,"Revoking the target account's private approval invalidates the pending reopen")
            grants.allowPrivate = true;try normal.setExtensionGrants(id,profileID:profile,grants:grants)
            let foreignWindow = OwnedExtensionReopenWindow(contentRect:NSRect(x:0,y:0,width:400,height:300),styleMask:[.titled],backing:.buffered,defer:false)
            foreignWindow.isReleasedWhenClosed = false
            defer {foreignWindow.close()}
            let reviewCount = reviews.count;results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:foreignWindow,confirmation:prompt){results.append($0)}
            check(results.count == 1 && (try? results[0].get()) == nil && reviews.count == reviewCount && owner.leaseCount == 1,"A foreign native window cannot present a private reload review or acquire a candidate lease")
            var lockedKeyRequests = 0
            let locked = BrowserStore(dataRoot:root.appendingPathComponent("locked-normal"),keyProvider:{_ in lockedKeyRequests += 1;throw CocoaError(.fileReadNoPermission)}),lockedOwner = BrowserWindowOwner(store:locked),lockedPrimary = try lockedOwner.acquirePrimary()
            defer {lockedOwner.release(lockedPrimary)}
            let originalKeyRequests = lockedKeyRequests;results = []
            client.requestReopenPrivateExtensions(with:lockedOwner,profileID:BrowserProfile.defaultID,from:window,confirmation:prompt){results.append($0)}
            check(results.count == 1 && (try? results[0].get()) == nil && reviews.count == reviewCount && lockedKeyRequests == originalKeyRequests && client.views[tabID] === disabled,"A locked target account cannot trigger another key request or replace a usable private page")
            client.privateExtensionReopenTimeout = .milliseconds(30);results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            try await waitFor{results.count == 1};let expiredReply = replies.last!;expiredReply(true)
            check((try? results[0].get()) == nil && results.count == 1 && client.views[tabID] === disabled && owner.leaseCount == 1,"An unanswered reopen expires once, releases its candidate lease and rejects a late approval")
            client.privateExtensionReopenTimeout = .seconds(60);results = []
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            owner.release(primary)
            check(!owner.isClosed && owner.leaseCount == 1,"The candidate auxiliary lease keeps a closed-main account alive while its reopen review waits")
            replies.last?(false)
            check(owner.isClosed && normal.isShuttingDown && client.views[tabID] === disabled && !client.isShuttingDown,"Cancelling the last candidate releases the normal writer while keeping the standalone private page")
        }
        func clearInterleavingExercise() async throws {
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("clear-normal"),keyProvider:{_ in key}),owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary(),profile = try normal.createProfile(name:"Owned clear/reopen account")
            defer {owner.release(primary);normal.shutdown()}
            try owned.register(profile);try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("clear-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,hostPatterns:["http://127.0.0.1/*"],allowPrivate:true,enable:true)
            _ = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            var keyRequests = 0
            let client = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("clear-private"),keyProvider:{_ in keyRequests += 1;throw CocoaError(.fileReadNoPermission)})
            defer {client.shutdown()}
            let id = client.selectedID!,url = fixture.appendingPathComponent("clear-interleaving"),web = client.view(for:id)
            client.update(id){$0.url = url.absoluteString};web.load(URLRequest(url:url));try await ready(web,url)
            _ = try await web.evaluateJavaScript("document.cookie='owned_clear_reopen=private; path=/';true")
            let window = OwnedExtensionReopenWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = web;client.registerExtensionWindow(window,kind:.primary)
            defer {client.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            var readyToRemove:CheckedContinuation<Void,Never>?,replies:[(Bool)->Void] = [],reviews = 0,results:[Result<Void,Error>] = []
            defer {readyToRemove?.resume()}
            let clear = Task { @MainActor in
                try await client.clearProfileData(BrowserProfile.defaultID,removeData:{store in
                    await withCheckedContinuation{readyToRemove = $0}
                    await withCheckedContinuation {done in store.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast){done.resume()}}
                })
            }
            try await waitFor{readyToRemove != nil}
            let before = try canonical(normal.makeDocument()),prompt = PrivateExtensionReopenPrompt(confirm:{_,_,reply in reviews += 1;replies.append(reply);return nil})
            client.requestReopenPrivateExtensions(with:owner,profileID:profile,from:window,confirmation:prompt){results.append($0)}
            check(results.count == 1 && (try? results[0].get()) == nil && reviews == 0 && owner.leaseCount == 1,"A private clear waiting on its real removal boundary refuses a new extension reload before any review or candidate lease")
            replies.last?(false)
            let removal = readyToRemove;readyToRemove = nil;removal?.resume();try await clear.value
            let cookies = await withCheckedContinuation {done in client.privateDataStore!.httpCookieStore.getAllCookies{done.resume(returning:$0)}}
            let after = try canonical(normal.makeDocument())
            check(cookies.isEmpty && client.extensionHosting == nil && client.privateExtensionReopenJob == nil && before == after && keyRequests == 0,"Completing the real private website clear does not resurrect a candidate host or change the normal session")
        }
        func normalPauseAttachmentExercise() async throws {
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("pause-normal"),keyProvider:{_ in key}),owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary(),profile = try normal.createProfile(name:"Owned paused account")
            defer {owner.release(primary);normal.shutdown()}
            try owned.register(profile);try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("pause-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,hostPatterns:["http://127.0.0.1/*"],allowPrivate:true,enable:true)
            let extensionID = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            let server = normal.extensionHosting as! NativeBrowserExtensionHost,context = server.profiles[profile]!.contexts[extensionID]!
            var keyRequests = 0
            let client = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("pause-private"),keyProvider:{_ in keyRequests += 1;throw CocoaError(.fileReadNoPermission)})
            defer {client.shutdown()}
            try client.associateExtensions(with:owner,profileID:profile)
            let association = client.extensionHosting,id = client.selectedID!,url = fixture.appendingPathComponent("paused-private-form"),web = client.view(for:id)
            client.update(id){$0.url = url.absoluteString};web.load(URLRequest(url:url));try await ready(web,url)
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='retain through normal clear';document.cookie='owned_paused_private=keep; path=/';true")
            let window = OwnedExtensionReopenWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = web;client.registerExtensionWindow(window,kind:.primary)
            defer {client.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            server.synchronizeBrowserState()
            check(server.privateClients[client.extensionStoreID]?.current === client && web.configuration.webExtensionController?.extensionContexts.contains(context) == true,"The paused-account fixture starts with a live approved private association and actual owning controller")
            var removal:CheckedContinuation<Void,Never>?
            defer {removal?.resume()}
            let clear = Task { @MainActor in
                do {
                    try await normal.clearProfileData(profile,removeData:{_ in
                        await withCheckedContinuation{removal = $0}
                        throw CocoaError(.fileWriteNoPermission)
                    })
                    return false
                } catch {return true}
            }
            try await waitFor{removal != nil};server.synchronizeBrowserState()
            check(server.privateClients[client.extensionStoreID] != nil,"Pausing a normal profile retains its structurally attached private client for old-controller cleanup")
            check(server.privateClients[client.extensionStoreID]?.current == nil && !server.authorized(context,profileID:profile,client:client) && !server.nativeWindows.keys.contains(where:{$0.storeID == client.extensionStoreID}),"Retained cleanup ownership exposes no private window or authority through the paused native runtime")
            let retained = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'retain through normal clear' && document.cookie.includes('owned_paused_private=keep')") as? Bool
            check(client.views[id] === web && client.extensionHosting === association && retained == true && owner.leaseCount == 2,"A normal profile pause preserves the private view, unsaved form, temporary cookie and association lease")
            let release = removal;removal = nil;release?.resume();let failed = await clear.value
            check(failed && normal.profiles.first(where:{$0.id == profile})?.isPendingClear == true && client.views[id] === web && keyRequests == 0,"A failed normal clear stays retryable without reopening the private page or requesting a private key")
            client.shutdown();server.synchronizeBrowserState()
            check(server.privateClients[client.extensionStoreID] == nil && owner.leaseCount == 1,"Closing a private client while its account is paused releases its structural association and auxiliary lease")
        }
        do {try await exercise();try await clearInterleavingExercise();try await normalPauseAttachmentExercise()} catch {check(false,"Owned reopen fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Reopen fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Reopen fixtures release only their owned named website stores")
        print("Extension reopen checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
