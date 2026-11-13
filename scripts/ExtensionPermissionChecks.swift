import AppKit
import WebKit
import CryptoKit
import BrowserCore
import Darwin

enum OwnedExtensionPermissionError:Error {case missingFixture,timedOut}
@MainActor final class OwnedExtensionPermissionWindow:NSWindow {
    override func makeKeyAndOrderFront(_ sender:Any?) {}
}
@main struct ExtensionPermissionChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<700 {
            if web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionPermissionError.timedOut
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Extension permission fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedExtensionPermissionError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:119,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func canonical(_ document:BrowserDocument) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(document)}
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let owner = BrowserWindowOwner(store:store),primary = try owner.acquirePrimary()
            defer {owner.release(primary)}
            let profile = try store.createProfile(name:"Owned permission account")
            try owned.register(profile);try controllers.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let source = root.appendingPathComponent("source")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned permissions","description":"Permission lifetime fixture","version":"1","options_page":"options.html","permissions":["storage"],"optional_permissions":["alarms","clipboardWrite","activeTab"],"host_permissions":["http://127.0.0.1/*"],"optional_host_permissions":["https://allowed.invalid/*","https://pattern.invalid/*"]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><body data-owned-extension-page='ready'>Owned permission options".utf8).write(to:source.appendingPathComponent("options.html"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging"))
            let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await store.installExtension(package,approval:approval)
            let url = fixture.appendingPathComponent("permission-source"),tabID = store.newTab(url:url),web = store.view(for:tabID)
            try await ready(web,url)
            let window = OwnedExtensionPermissionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = web;store.registerExtensionWindow(window,kind:.primary)
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            try await store.prepareExtensions(profileID:profile)
            let host = store.extensionHosting as! NativeBrowserExtensionHost
            host.synchronizeBrowserState()
            let controller = host.profiles[profile]!.controller,context = host.profiles[profile]!.contexts[id]!
            let tab = host.nativeTabs.values.first(where:{$0.web === web})!
            let alarms = WKWebExtension.Permission(rawValue:"alarms"),clipboard = WKWebExtension.Permission(rawValue:"clipboardWrite")
            var prompts:[NativeExtensionPermissionReview] = [],replies:[(Bool)->Void] = [],dismissals = 0
            host.permissionPrompt = NativeExtensionPermissionPrompt(present:{_,review,reply in
                prompts.append(review);replies.append(reply);return {dismissals += 1}
            })
            var nilReplies = 0
            host.webExtensionController(controller,promptForPermissions:[alarms],in:nil,for:context){allowed,_ in nilReplies += 1;check(allowed.isEmpty,"A source-less native permission request is denied")}
            check(nilReplies == 1 && prompts.isEmpty,"A background request cannot choose another window for permission review")
            var invalidReplies = 0
            host.webExtensionController(controller,promptForPermissions:[WKWebExtension.Permission(rawValue:"history")],in:tab,for:context){allowed,_ in invalidReplies += 1;check(allowed.isEmpty,"An undeclared native API cannot gain permission")}
            host.webExtensionController(controller,promptForPermissionToAccess:[URL(fileURLWithPath:"/tmp/owned-unapproved")],in:tab,for:context){allowed,_ in invalidReplies += 1;check(allowed.isEmpty,"A native permission reply cannot approve a local file")}
            let foreign = WKWebExtensionController(configuration:.nonPersistent())
            host.webExtensionController(foreign,promptForPermissions:[alarms],in:tab,for:context){allowed,_ in invalidReplies += 1;check(allowed.isEmpty,"A foreign native controller cannot present a permission request")}
            let allURLs = try WKWebExtension.MatchPattern(string:"<all_urls>"),outsidePattern = try WKWebExtension.MatchPattern(string:"https://outside.invalid/*")
            host.webExtensionController(controller,promptForPermissionMatchPatterns:[allURLs],in:tab,for:context){allowed,_ in invalidReplies += 1;check(allowed.isEmpty,"Native all-URL requests cannot silently include local files")}
            host.webExtensionController(controller,promptForPermissionMatchPatterns:[outsidePattern],in:tab,for:context){allowed,_ in invalidReplies += 1;check(allowed.isEmpty,"Undeclared native match patterns cannot earn approval")}
            check(invalidReplies == 5 && prompts.isEmpty,"Invalid requests complete once without presenting UI")
            let precisionSource = NativeExtensionSource(host:host,controller:controller,context:context,tab:tab)!
            let precisionDate = Date(timeIntervalSinceReferenceDate:floor(Date().timeIntervalSinceReferenceDate) + 299 + 0.00000011920928955078125)
            let precisionGrant = NativeExtensionSessionGrant(source:precisionSource,permissions:[alarms],patterns:[],expiration:precisionDate)
            precisionGrant.apply()
            let nativePrecisionDate = context.grantedPermissions[alarms]
            precisionGrant.revoke()
            print("INFO: Owned native permission date differs after round-trip: \(nativePrecisionDate != precisionDate)")
            check(!context.hasPermission(alarms) && context.hasPermission(WKWebExtension.Permission(rawValue:"storage")),"Revocation removes its actual native grant even when the framework rounds its expiration date")
            let before = try canonical(store.makeDocument())
            var deniedReplies = 0
            host.webExtensionController(controller,promptForPermissions:[alarms],in:tab,for:context){allowed,_ in deniedReplies += 1;check(allowed.isEmpty,"Declining an optional permission returns no grant")}
            check(prompts.count == 1 && deniedReplies == 0 && !context.hasPermission(alarms),"A valid optional request waits for an explicit source-window reply")
            replies.last?(false);replies.last?(true)
            check(deniedReplies == 1 && !context.hasPermission(alarms),"A duplicate late approval cannot reverse a declined permission")
            var approvedReplies = 0,approvedExpiration:Date?
            host.webExtensionController(controller,promptForPermissions:[alarms],in:tab,for:context){allowed,date in approvedReplies += 1;approvedExpiration = date;check(allowed == [alarms],"An approved native reply includes only the requested API")}
            replies.last?(true);replies.last?(true)
            let after = try canonical(store.makeDocument())
            check(approvedReplies == 1 && approvedExpiration.map{$0 > Date() && $0 <= Date().addingTimeInterval(301)} == true && context.hasPermission(alarms) && context.hasPermission(WKWebExtension.Permission(rawValue:"storage")),"Approval creates a bounded native grant while retaining the permanent storage permission")
            check(after == before,"A runtime permission approval does not mutate the encrypted catalog or normal tab document")
            store.webView(web,didStartProvisionalNavigation:nil)
            check(!context.hasPermission(alarms),"The actual navigation-start delegate revokes its source grant before returning")
            let next = fixture.appendingPathComponent("permission-new-document")
            web.load(URLRequest(url:next));try await ready(web,next);host.synchronizeBrowserState()
            check(!context.hasPermission(alarms) && context.hasPermission(WKWebExtension.Permission(rawValue:"storage")),"Navigating the source revokes its temporary API grant while permanent rights remain")
            var staleReplies = 0
            host.webExtensionController(controller,promptForPermissions:[clipboard],in:tab,for:context){allowed,_ in staleReplies += 1;check(allowed.isEmpty,"A reply for an earlier document grants nothing")}
            let staleReply = replies.last!
            let newer = fixture.appendingPathComponent("permission-later-document")
            web.load(URLRequest(url:newer));try await ready(web,newer);staleReply(true);host.synchronizeBrowserState()
            check(staleReplies == 1 && !context.hasPermission(clipboard),"Navigation cancels a pending request exactly once before a late approval")
            var siteReplies = 0
            let optionalSite = URL(string:"https://allowed.invalid/private-value?owned=secret")!
            host.webExtensionController(controller,promptForPermissionToAccess:[optionalSite],in:tab,for:context){allowed,_ in siteReplies += 1;check(allowed == [optionalSite],"An approved native URL reply retains only its requested URL")}
            replies.last?(true)
            check(siteReplies == 1 && context.hasAccess(to:optionalSite) && !context.hasAccess(to:URL(string:"https://outside.invalid/")!),"Temporary native site access remains within the declared site boundary")
            let requestedPattern = try WKWebExtension.MatchPattern(string:"https://pattern.invalid/*")
            var patternReplies = 0
            host.webExtensionController(controller,promptForPermissionMatchPatterns:[requestedPattern],in:tab,for:context){allowed,_ in patternReplies += 1;check(allowed == [requestedPattern],"A native match-pattern approval returns only the reviewed pattern")}
            replies.last?(true)
            check(patternReplies == 1 && context.hasAccess(to:URL(string:"https://pattern.invalid/test")!),"A declared native match pattern grants actual site access after approval")
            var overlapReplies = 0
            host.webExtensionController(controller,promptForPermissions:[alarms],in:tab,for:context){_,_ in overlapReplies += 1}
            var queuedReplies = 0
            let promptCount = prompts.count
            host.webExtensionController(controller,promptForPermissions:[clipboard],in:tab,for:context){allowed,_ in queuedReplies += 1;check(allowed.isEmpty,"An overlapping window request is declined")}
            check(prompts.count == promptCount && queuedReplies == 1 && overlapReplies == 0,"One source window cannot accumulate permission sheets")
            replies.last?(false)
            host.permissionRequestTimeout = .milliseconds(60)
            var timeoutReplies = 0
            host.webExtensionController(controller,promptForPermissions:[alarms],in:tab,for:context){allowed,_ in timeoutReplies += 1;check(allowed.isEmpty,"An unanswered permission request expires without a grant")}
            let timeoutReply = replies.last!
            try await Task.sleep(for:.milliseconds(120));timeoutReply(true)
            check(timeoutReplies == 1 && !context.hasPermission(alarms),"Timeout and late approval complete the native request only once")
            var delayedReplies = 0
            host.webExtensionController(controller,promptForPermissions:[clipboard],in:tab,for:context){allowed,_ in delayedReplies += 1;check(allowed.isEmpty,"A permission reply after its deadline cannot grant access while the timer callback is delayed")}
            let delayedReply = replies.last!
            // Hold only this generated fixture's MainActor so its timeout Task
            // cannot run before the real monotonic deadline has already passed.
            usleep(120_000);delayedReply(true)
            check(delayedReplies == 1 && !context.hasPermission(clipboard),"A delayed timer cannot extend the actual permission approval deadline")
            host.cancelPermissionRequests()
            host.permissionRequestTimeout = .seconds(60)
            let elapsedSource = NativeExtensionSource(host:host,controller:controller,context:context,tab:tab)!
            let futureNativeDate = Date().addingTimeInterval(300),elapsedGrant = NativeExtensionSessionGrant(source:elapsedSource,permissions:[alarms],patterns:[],expiration:futureNativeDate)
            host.permissionSessionGrants[elapsedGrant.id] = elapsedGrant;elapsedGrant.apply()
            check(context.hasPermission(alarms) && futureNativeDate > Date(),"The elapsed-time fixture starts with a live native grant and a future wall-clock expiration")
            host.reconcilePermissionRequests(at:ContinuousClock.now.advanced(by:.seconds(301)))
            check(!context.hasPermission(alarms) && context.hasPermission(WKWebExtension.Permission(rawValue:"storage")) && host.permissionSessionGrants[elapsedGrant.id] == nil,"Elapsed monotonic time revokes the actual native grant even while its wall-clock expiration is still in the future")
            var repeatedRevocation = true
            for index in 0..<12 {
                var granted = false
                host.webExtensionController(controller,promptForPermissions:[alarms],in:tab,for:context){allowed,_ in granted = allowed == [alarms]}
                replies.last?(true)
                repeatedRevocation = repeatedRevocation && granted && context.hasPermission(alarms)
                let address = fixture.appendingPathComponent("permission-date-round-trip-\(index)")
                web.load(URLRequest(url:address));try await ready(web,address);host.synchronizeBrowserState()
                repeatedRevocation = repeatedRevocation && !context.hasPermission(alarms) && context.hasPermission(WKWebExtension.Permission(rawValue:"storage"))
            }
            check(repeatedRevocation,"Repeated native date round-trips cannot leave a temporary API grant after its source navigates")
            var activeAddress = URLComponents(url:fixture.appendingPathComponent("temporary-active-tab"),resolvingAgainstBaseURL:false)!
            activeAddress.host = "localhost"
            let activeURL = activeAddress.url!,activeTabPermission = WKWebExtension.Permission(rawValue:"activeTab")
            web.load(URLRequest(url:activeURL));try await ready(web,activeURL);host.synchronizeBrowserState()
            check(!context.hasAccess(to:activeURL,in:tab) && !tab.shouldGrantPermissionsOnUserGesture(for:context),"The activeTab fixture starts without native access to its different owned loopback origin")
            var activeTabReplies = 0
            host.webExtensionController(controller,promptForPermissions:[activeTabPermission],in:tab,for:context){allowed,_ in activeTabReplies += 1;check(allowed == [activeTabPermission],"Temporary activeTab approval returns only its reviewed API")}
            replies.last?(true)
            check(activeTabReplies == 1 && context.hasPermission(activeTabPermission) && tab.shouldGrantPermissionsOnUserGesture(for:context),"An explicitly approved temporary activeTab permission enables the actual native gesture gate")
            context.userGesturePerformed(in:tab)
            check(context.hasAccess(to:activeURL,in:tab),"The approved native user gesture can access only its intended active tab")
            let activeNext = activeURL.appendingPathComponent("next-document")
            web.load(URLRequest(url:activeNext));try await ready(web,activeNext);host.synchronizeBrowserState()
            check(!context.hasPermission(activeTabPermission) && !context.hasActiveUserGesture(in:tab) && !context.hasAccess(to:activeNext,in:tab),"Ending a temporary activeTab approval also clears its native gesture and tab access")
            var grant = store.extensionRecords(profileID:profile).first!.grants!;grant.allowPrivate = true
            try store.setExtensionGrants(id,profileID:profile,grants:grant);try await store.prepareExtensions(profileID:profile)
            let privateContext = host.profiles[profile]!.contexts[id]!
            let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in throw CocoaError(.fileReadNoPermission)})
            defer {privateStore.shutdown()}
            try privateStore.associateExtensions(with:owner,profileID:profile)
            let privateURL = fixture.appendingPathComponent("private-permission-source"),privateWeb = privateStore.view(for:privateStore.selectedID!)
            privateWeb.load(URLRequest(url:privateURL));try await ready(privateWeb,privateURL)
            let privateWindow = OwnedExtensionPermissionWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            privateWindow.isReleasedWhenClosed = false;privateWindow.contentView = privateWeb;privateStore.registerExtensionWindow(privateWindow,kind:.primary)
            defer {privateStore.unregisterExtensionWindow(kind:.primary);privateWindow.contentView = nil;privateWindow.close()}
            host.synchronizeBrowserState()
            let privateTab = host.nativeTabs.values.first(where:{$0.web === privateWeb})!,beforePrivate = try canonical(store.makeDocument())
            var privateReplies = 0
            host.webExtensionController(controller,promptForPermissions:[alarms],in:privateTab,for:privateContext){allowed,_ in privateReplies += 1;check(allowed == [alarms],"An approved private request returns only its temporary requested API")}
            check(prompts.last?.isPrivate == true && privateReplies == 0,"Private permission review stays attached to its actual private source window")
            replies.last?(true)
            let afterPrivate = try canonical(store.makeDocument())
            check(privateContext.hasPermission(alarms) && beforePrivate == afterPrivate,"Private approval grants live native capability without serializing a grant or private URL")
            privateStore.unregisterExtensionWindow(kind:.primary);privateStore.shutdown();host.synchronizeBrowserState()
            check(!privateContext.hasPermission(alarms) && !store.isShuttingDown && privateContext.hasPermission(WKWebExtension.Permission(rawValue:"storage")),"Closing the private source immediately revokes its temporary grant without stopping the normal runtime")
            let controlledPrompt = host.permissionPrompt
            var enginePrompts = 0
            host.permissionPrompt = NativeExtensionPermissionPrompt(present:{_,_,reply in enginePrompts += 1;reply(true);return nil})
            do {
                let optionsID = try await store.openExtensionOptions(id,profileID:profile),options = store.views[optionsID]!
                window.contentView = options;host.synchronizeBrowserState();try await ready(options,privateContext.optionsPageURL!)
                let result = try await ExtensionBoundedResult<Any?>().run(seconds:3) {
                    try await options.callAsyncJavaScript("return await browser.permissions.request({permissions:['alarms']});",arguments:[:],in:nil,contentWorld:.page)
                }
                check(result as? Bool == false && enginePrompts == 0 && !privateContext.hasPermission(alarms),"The real browser.permissions.request API is denied when WebKit supplies no source tab")
                store.close(optionsID);host.synchronizeBrowserState()
                check(!privateContext.hasPermission(alarms),"A source-less native API request leaves no grant after its extension tab closes")
            } catch {check(false,"The real native permission API completes successfully: " + error.localizedDescription)}
            host.permissionPrompt = controlledPrompt;window.contentView = web;store.select(tabID)
            host.synchronizeBrowserState()
            let currentTab = host.nativeTabs.values.first(where:{$0.web === web})!
            grant.deniedPermissions = ["alarms"];try store.setExtensionGrants(id,profileID:profile,grants:grant);try await store.prepareExtensions(profileID:profile)
            let deniedContext = host.profiles[profile]!.contexts[id]!,beforeDeniedPrompts = prompts.count
            var explicitDeniedReplies = 0
            host.webExtensionController(controller,promptForPermissions:[alarms],in:currentTab,for:deniedContext){allowed,_ in explicitDeniedReplies += 1;check(allowed.isEmpty,"An explicit saved API denial cannot be bypassed by another native prompt")}
            check(explicitDeniedReplies == 1 && prompts.count == beforeDeniedPrompts && !deniedContext.hasPermission(alarms),"Explicitly denied access completes without another permission sheet")
            var changedReplies = 0
            host.webExtensionController(controller,promptForPermissions:[clipboard],in:currentTab,for:deniedContext){allowed,_ in changedReplies += 1;check(allowed.isEmpty,"A changed approval cannot receive a stale permission grant")}
            check(changedReplies == 0,"The approval-change fixture has a live outstanding source request")
            let changedReply = replies.last!
            try store.setExtensionEnabled(id,profileID:profile,enabled:false);changedReply(true)
            check(changedReplies == 1 && !deniedContext.hasPermission(clipboard),"Disabling an extension cancels its outstanding native permission request")
            try store.setExtensionEnabled(id,profileID:profile,enabled:true);try await store.prepareExtensions(profileID:profile)
            let closingContext = host.profiles[profile]!.contexts[id]!
            var closingReplies = 0
            host.webExtensionController(controller,promptForPermissions:[clipboard],in:currentTab,for:closingContext){allowed,_ in closingReplies += 1;check(allowed.isEmpty,"A closed browser session cannot receive a pending permission grant")}
            let closingReply = replies.last!
            check(closingReplies == 0,"The shutdown fixture begins with a live pending permission request")
            store.shutdown();closingReply(true)
            check(closingReplies == 1 && !closingContext.hasPermission(clipboard),"Shutdown cancels a native permission request exactly once before late approval")
            check(dismissals > 0,"Cancelled or completed permission requests dismiss their own native presentation")
        }
        do {try await exercise()} catch {check(false,"Owned permission fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Permission fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Permission fixtures release only their owned named website stores")
        print("Extension permission checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
