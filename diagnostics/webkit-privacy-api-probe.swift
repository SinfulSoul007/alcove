import AppKit
import WebKit

@available(macOS 15.4, *) @MainActor final class PrivacyWindow: NSObject, WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [] }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { true }
}

@main struct PrivacyAPIProbe {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        guard #available(macOS 15.4, *) else { throw CocoaError(.featureUnsupported) }
        let framework = Bundle(for: WKWebView.self).bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        print("PRIVACY_API_FRAMEWORK \(framework.path)")
        if let expected = ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] {
            let root = URL(fileURLWithPath: expected).standardizedFileURL.resolvingSymlinksInPath()
            guard framework.path.hasPrefix(root.path + "/") else { throw CocoaError(.featureUnsupported) }
        }
        guard let argument = CommandLine.arguments.dropFirst().first, let server = URL(string: argument),
              server.scheme == "http", server.host == "127.0.0.1", server.port != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-privacy-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard try await capability(root: root.appendingPathComponent("capability")) else {
            print("FAIL: native extension privacy settings must control their approved browser scope")
            exit(1)
        }
        let identifier = UUID()
        guard CommandLine.arguments.count > 2, let rtcServer = URL(string: CommandLine.arguments[2]),
              rtcServer.scheme == "http", rtcServer.host == "127.0.0.1", rtcServer.port != nil else { throw CocoaError(.fileReadInvalidFileName) }
        var result = false
        do { result = try await run(root: root.appendingPathComponent("scopes"), identifier: identifier, server: server, rtcServer: rtcServer) }
        catch { print("PRIVACY_API_ERROR \(error)") }
        var removed = false
        for _ in 0..<40 {
            do { try await WKWebsiteDataStore.remove(forIdentifier: identifier); removed = true; break }
            catch { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard result, removed else {
            print("FAIL: native extension privacy settings must control their approved browser scope")
            exit(1)
        }
        print("NATIVE_PRIVACY_API_PROVEN true")
    }

    @available(macOS 15.4, *) @MainActor static func extensionPage(root: URL, controller: WKWebExtensionController,
        identity: String, permission: Bool = true, date: Date? = nil) async throws -> (WKWebExtensionContext, WKWebView) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 2, "name": identity, "version": "1.0",
            "permissions": ["privacy"], "options_page": "options.html"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><meta charset='utf-8'><title>Owned privacy API fixture</title>".utf8)
            .write(to: root.appendingPathComponent("options.html"))
        let ext = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = identity
        if permission { context.grantedPermissions = [WKWebExtension.Permission(rawValue: "privacy"): .distantFuture] }
        if let date {
            let selector = NSSelectorFromString("_setPrivacyInstallationDate:")
            guard context.responds(to: selector), let method = context.method(for: selector) else { throw CocoaError(.featureUnsupported) }
            typealias SetDate = @convention(c) (AnyObject, Selector, NSDate) -> Void
            unsafeBitCast(method, to: SetDate.self)(context, selector, date as NSDate)
        }
        try controller.load(context)
        guard let configuration = context.webViewConfiguration, let address = context.optionsPageURL else { throw CocoaError(.featureUnsupported) }
        let page = WKWebView(frame: .zero, configuration: configuration)
        try await load(page, address)
        return (context, page)
    }

    @MainActor static func load(_ page: WKWebView, _ address: URL) async throws {
        page.load(URLRequest(url: address))
        for _ in 0..<450 {
            if page.url == address, !page.isLoading,
               (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    @available(macOS 15.4, *) @MainActor static func capability(root: URL) async throws -> Bool {
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)
        let (context, page) = try await extensionPage(root: root, controller: controller, identity: "alcove-privacy-capability")
        defer { try? controller.unload(context) }
        let available = try await page.evaluateJavaScript("typeof browser.privacy?.network?.networkPredictionEnabled?.get === 'function' && typeof globalThis.chrome?.privacy?.network?.networkPredictionEnabled?.get === 'function'") as? Bool == true
        print("PRIVACY_API_AVAILABLE \(available)")
        return available
    }

    @available(macOS 15.4, *) @MainActor static func run(root: URL, identifier: UUID, server: URL, rtcServer: URL) async throws -> Bool {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        let directorySelector = NSSelectorFromString("_setStorageDirectoryPath:")
        guard configuration.responds(to: directorySelector), let directoryMethod = configuration.method(for: directorySelector) else { return false }
        typealias SetDirectory = @convention(c) (AnyObject, Selector, NSString) -> Void
        unsafeBitCast(directoryMethod, to: SetDirectory.self)(configuration, directorySelector, root.appendingPathComponent("state").path as NSString)
        configuration.defaultWebsiteDataStore = dataStore
        let background = WKWebViewConfiguration(); background.websiteDataStore = dataStore
        configuration.webViewConfiguration = background
        let controller = WKWebExtensionController(configuration: configuration)
        let older = try await extensionPage(root: root.appendingPathComponent("older"), controller: controller, identity: "alcove-privacy-older", date: Date(timeIntervalSince1970: 100))
        let newer = try await extensionPage(root: root.appendingPathComponent("newer"), controller: controller, identity: "alcove-privacy-newer", date: Date(timeIntervalSince1970: 200))
        let denied = try await extensionPage(root: root.appendingPathComponent("denied"), controller: controller, identity: "alcove-privacy-denied", permission: false)
        defer {
            for item in [older, newer, denied] { if item.0.isLoaded { try? controller.unload(item.0) } }
        }
        guard try await denied.1.evaluateJavaScript("browser.privacy === undefined") as? Bool == true else { return false }
        func command(_ page: WKWebView, _ action: String, value: Bool? = nil, scope: String = "regular", incognito: Bool = false) async throws -> Any? {
            var details: [String: Any] = action == "get" ? ["incognito": incognito] : ["scope": scope]
            if let value { details["value"] = value }
            return try await page.callAsyncJavaScript("return await browser.privacy.websites.hyperlinkAuditingEnabled[action](details)",
                arguments: ["action": action, "details": details], in: nil, contentWorld: .page)
        }
        func expect(_ page: WKWebView, _ value: Bool, level: String, incognito: Bool = false, specific: Bool? = nil) async throws -> Bool {
            guard let result = try await command(page, "get", incognito: incognito) as? [String: Any],
                  result["value"] as? Bool == value, result["levelOfControl"] as? String == level else { return false }
            if let specific { return result["incognitoSpecific"] as? Bool == specific }
            return true
        }
        func rejects(_ page: WKWebView, _ body: String) async throws -> Bool {
            try await page.callAsyncJavaScript("try { \(body); return false } catch { return true }", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        }
        let normalConfiguration = WKWebViewConfiguration(); normalConfiguration.websiteDataStore = dataStore
        normalConfiguration.webExtensionController = controller
        let normal = WKWebView(frame: .zero, configuration: normalConfiguration)
        let privateConfiguration = WKWebViewConfiguration(); privateConfiguration.websiteDataStore = .nonPersistent()
        privateConfiguration.webExtensionController = controller
        let privatePage = WKWebView(frame: .zero, configuration: privateConfiguration)
        let countSession = URLSession(configuration: .ephemeral)
        defer { countSession.invalidateAndCancel(); normal.stopLoading(); privatePage.stopLoading() }
        func ping(_ phase: String, _ web: WKWebView) async throws -> Int {
            let address = server.appendingPathComponent("link-policy/api-\(phase)-\(UUID().uuidString)")
            try await load(web, address.appendingPathComponent("source"))
            _ = try await web.evaluateJavaScript("document.getElementById('destination').click()")
            for _ in 0..<450 where web.url != address.appendingPathComponent("destination") || web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            guard web.url == address.appendingPathComponent("destination"), !web.isLoading else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(500))
            var query = URLComponents(url: server.appendingPathComponent("__request_count"), resolvingAgainstBaseURL: false)!
            query.queryItems = [URLQueryItem(name: "path", value: address.appendingPathComponent("ping").path)]
            let (body, response) = try await countSession.data(from: query.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let result = Int(String(decoding: body, as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
            print("PRIVACY_API_PING \(phase) \(result)")
            return result
        }
        guard try await expect(older.1, true, level: "controllable_by_this_extension"),
              try await ping("baseline", normal) == 1 else { return false }
        _ = try await older.1.evaluateJavaScript("window.changes=[]; window.held=browser.privacy.websites.hyperlinkAuditingEnabled; window.changeListener=details=>changes.push(details); held.onChange.addListener(changeListener);")
        _ = try await command(older.1, "set", value: false)
        guard try await expect(older.1, false, level: "controlled_by_this_extension"),
              try await expect(newer.1, false, level: "controllable_by_this_extension"),
              try await ping("regular-disabled", normal) == 0,
              try await ping("private-without-approval", privatePage) == 1,
              try await rejects(older.1, "await held.get({incognito:true})") else { return false }
        let fresh = WKWebView(frame: .zero, configuration: normalConfiguration)
        guard try await ping("new-page-inherits", fresh) == 0 else { return false }
        let separateConfiguration = WKWebExtensionController.Configuration.nonPersistent()
        separateConfiguration.defaultWebsiteDataStore = dataStore
        let separateBackground = WKWebViewConfiguration()
        separateBackground.websiteDataStore = dataStore
        separateBackground.preferences = background.preferences
        separateConfiguration.webViewConfiguration = separateBackground
        let separateController = WKWebExtensionController(configuration: separateConfiguration)
        let separate = try await extensionPage(root: root.appendingPathComponent("separate"), controller: separateController,
            identity: "alcove-privacy-separate", date: Date(timeIntervalSince1970: 300))
        defer { try? separateController.unload(separate.0) }
        let separatePageConfiguration = WKWebViewConfiguration()
        separatePageConfiguration.websiteDataStore = dataStore
        separatePageConfiguration.webExtensionController = separateController
        let separatePage = WKWebView(frame: .zero, configuration: separatePageConfiguration)
        guard try await expect(separate.1, true, level: "controllable_by_this_extension"),
              try await ping("controller-isolation", separatePage) == 1 else { return false }
        older.0.hasAccessToPrivateData = true
        guard try await expect(older.1, false, level: "controlled_by_this_extension", incognito: true, specific: false),
              try await ping("private-inherited", privatePage) == 0 else { return false }
        _ = try await command(newer.1, "set", value: true)
        _ = try await command(older.1, "set", value: false)
        guard try await expect(older.1, true, level: "controlled_by_other_extensions"),
              try await ping("newer-wins", normal) == 1 else { return false }
        _ = try await command(newer.1, "clear")
        _ = try await command(older.1, "set", value: true, scope: "regular_only")
        guard try await expect(older.1, true, level: "controlled_by_this_extension"),
              try await expect(older.1, false, level: "controlled_by_this_extension", incognito: true, specific: false) else { return false }
        _ = try await command(older.1, "set", value: true, scope: "incognito_persistent")
        newer.0.hasAccessToPrivateData = true
        _ = try await command(newer.1, "set", value: false)
        guard try await expect(older.1, false, level: "controlled_by_other_extensions", incognito: true, specific: false) else { return false }
        _ = try await command(newer.1, "clear")
        newer.0.hasAccessToPrivateData = false
        guard try await expect(older.1, true, level: "controlled_by_this_extension", incognito: true, specific: true),
              try await rejects(older.1, "await held.set({value:false,scope:'incognito_session_only'})") else { return false }
        let privateWindow = PrivacyWindow()
        for context in [older.0, newer.0, denied.0] { context.didOpenWindow(privateWindow) }
        _ = try await command(older.1, "set", value: false, scope: "incognito_session_only")
        guard try await expect(older.1, false, level: "controlled_by_this_extension", incognito: true, specific: true),
              try await ping("private-session-disabled", privatePage) == 0 else { return false }
        for context in [older.0, newer.0, denied.0] { context.didCloseWindow(privateWindow) }
        guard try await expect(older.1, true, level: "controlled_by_this_extension", incognito: true, specific: true),
              try await rejects(older.1, "await held.set({value:false,scope:'incognito_session_only'})") else { return false }
        older.0.hasAccessToPrivateData = false
        _ = try await command(older.1, "clear", scope: "incognito_persistent")
        _ = try await command(older.1, "clear", scope: "incognito_session_only")
        older.0.hasAccessToPrivateData = true
        guard try await expect(older.1, false, level: "controlled_by_this_extension", incognito: true, specific: false) else { return false }
        _ = try await command(older.1, "clear", scope: "regular_only")
        _ = try await command(older.1, "clear", scope: "incognito_persistent")
        guard try await expect(older.1, false, level: "controlled_by_this_extension") else { return false }
        let callback = try await older.1.callAsyncJavaScript("return await new Promise(resolve=>held.get({},resolve))", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let detached = try await older.1.callAsyncJavaScript("const get=held.get; return await get({})", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        guard callback?["value"] as? Bool == false, detached?["value"] as? Bool == false,
              try await rejects(older.1, "await held.set({value:'false'})"),
              try await rejects(older.1, "await held.set({value:false,scope:'invalid'})") else { return false }
        let callbackSet = try await older.1.callAsyncJavaScript("return await new Promise(resolve=>held.set({value:false},function(){resolve(arguments.length===0 && !browser.runtime.lastError)}))",
            arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        guard callbackSet else { return false }
        for _ in 0..<100 {
            if try await older.1.evaluateJavaScript("changes.some(x=>x.levelOfControl==='controlled_by_other_extensions'&&x.value===true)") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard try await older.1.evaluateJavaScript("changes.some(x=>x.levelOfControl==='controlled_by_other_extensions'&&x.value===true)") as? Bool == true else { return false }
        older.0.grantedPermissions = [:]
        let callbackError = try await older.1.callAsyncJavaScript("return await new Promise(resolve=>held.set({value:false},()=>resolve(typeof browser.runtime.lastError?.message==='string')))",
            arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        guard callbackError, try await rejects(older.1, "await held.set({value:false})"),
              try await ping("permission-revoked", normal) == 1 else { return false }
        older.0.grantedPermissions = [WKWebExtension.Permission(rawValue: "privacy"): .distantFuture]
        guard try await expect(older.1, true, level: "controllable_by_this_extension") else { return false }
        _ = try await command(older.1, "set", value: false)
        try controller.unload(older.0)
        guard try await ping("context-unloaded", normal) == 1 else { return false }
        let restored = try await extensionPage(root: root.appendingPathComponent("older"), controller: controller, identity: "alcove-privacy-older", date: Date(timeIntervalSince1970: 100))
        defer { try? controller.unload(restored.0) }
        guard try await expect(restored.1, false, level: "controlled_by_this_extension") else { return false }
        _ = try await command(newer.1, "set", value: true)
        guard try await expect(restored.1, true, level: "controlled_by_other_extensions") else { return false }
        let types = try await restored.1.callAsyncJavaScript("""
            window.auditChanges=0;
            browser.privacy.websites.hyperlinkAuditingEnabled.onChange.addListener(()=>auditChanges++);
            const prediction=await browser.privacy.network.networkPredictionEnabled.get({});
            const rtc=await browser.privacy.network.webRTCIPHandlingPolicy.get({});
            await browser.privacy.network.networkPredictionEnabled.set({value:false});
            await browser.privacy.network.webRTCIPHandlingPolicy.set({value:'disable_non_proxied_udp'});
            const changedPrediction=await browser.privacy.network.networkPredictionEnabled.get({});
            const changedRTC=await browser.privacy.network.webRTCIPHandlingPolicy.get({});
            const chromePrediction=await chrome.privacy.network.networkPredictionEnabled.get({});
            return prediction.value===true && rtc.value==='default' && changedPrediction.value===false && chromePrediction.value===false && changedRTC.value==='disable_non_proxied_udp';
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        guard types else { return false }
        try await Task.sleep(for: .milliseconds(150))
        guard try await restored.1.evaluateJavaScript("auditChanges===0") as? Bool == true else { return false }
        _ = try await restored.1.callAsyncJavaScript("await browser.privacy.network.webRTCIPHandlingPolicy.clear({})", arguments: [:], in: nil, contentWorld: .page)

        let unloaded = try await extensionPage(root: root.appendingPathComponent("unloaded"), controller: controller,
            identity: "alcove-privacy-unloaded", date: Date(timeIntervalSince1970: 600))
        _ = try await command(unloaded.1, "set", value: false)
        try controller.unload(unloaded.0)
        unloaded.0.grantedPermissions = [:]
        unloaded.0.grantedPermissions = [WKWebExtension.Permission(rawValue: "privacy"): .distantFuture]
        try controller.load(unloaded.0)
        defer { if unloaded.0.isLoaded { try? controller.unload(unloaded.0) } }
        guard let reloadedConfiguration = unloaded.0.webViewConfiguration, let reloadedURL = unloaded.0.optionsPageURL else { return false }
        let reloadedPage = WKWebView(frame: .zero, configuration: reloadedConfiguration)
        try await load(reloadedPage, reloadedURL)
        guard try await expect(reloadedPage, true, level: "controllable_by_this_extension") else { return false }
        _ = try await command(reloadedPage, "set", value: false)
        try controller.unload(unloaded.0)
        let reauthorized = try await extensionPage(root: root.appendingPathComponent("unloaded"), controller: controller,
            identity: "alcove-privacy-unloaded", permission: false, date: Date(timeIntervalSince1970: 600))
        defer { try? controller.unload(reauthorized.0) }
        reauthorized.0.grantedPermissions = [WKWebExtension.Permission(rawValue: "privacy"): .distantFuture]
        guard try await expect(reauthorized.1, true, level: "controllable_by_this_extension") else { return false }

        let timed = try await extensionPage(root: root.appendingPathComponent("timed"), controller: controller,
            identity: "alcove-privacy-timed", date: Date(timeIntervalSince1970: 700))
        defer { try? controller.unload(timed.0) }
        let rtcPage = WKWebView(frame: .zero, configuration: normalConfiguration)
        try await load(rtcPage, rtcServer.appendingPathComponent("page"))
        func gather(_ phase: String) async throws -> (Int, Int) {
            let (descriptorData, _) = try await countSession.data(from: rtcServer.appendingPathComponent("new"))
            guard let descriptor = try JSONSerialization.jsonObject(with: descriptorData) as? [String: Int], let port = descriptor["port"] else { throw CocoaError(.coderInvalidValue) }
            let udp = try await rtcPage.callAsyncJavaScript("""
                const peer=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:'+port}]});
                const candidates=[];
                peer.onicecandidate=e=>{if(e.candidate)candidates.push(e.candidate.candidate)};
                peer.createDataChannel('privacy-expiry');
                try {
                    await peer.setLocalDescription(await peer.createOffer());
                    await new Promise(resolve=>{
                        if(peer.iceGatheringState==='complete'){resolve();return}
                        const timer=setTimeout(resolve,3500);
                        peer.onicegatheringstatechange=()=>{if(peer.iceGatheringState==='complete'){clearTimeout(timer);resolve()}};
                    });
                    return candidates.filter(x=>x.split(' ')[2].toLowerCase()==='udp').length;
                } finally {peer.close()}
                """, arguments: ["port": port], in: nil, contentWorld: .page) as? Int ?? -1
            var query = URLComponents(url: rtcServer.appendingPathComponent("count"), resolvingAgainstBaseURL: false)!
            query.queryItems = [URLQueryItem(name: "port", value: String(port))]
            let (body, _) = try await countSession.data(from: query.url!)
            guard let counts = try JSONSerialization.jsonObject(with: body) as? [String: Int], let requests = counts["requests"] else { throw CocoaError(.coderInvalidValue) }
            print("PRIVACY_API_EXPIRY \(phase) requests=\(requests) udp=\(udp)")
            return (requests, udp)
        }
        timed.0.grantedPermissions = [WKWebExtension.Permission(rawValue: "privacy"): Date.now.addingTimeInterval(3600)]
        _ = try await timed.1.callAsyncJavaScript("window.timedRTC=browser.privacy.network.webRTCIPHandlingPolicy; await timedRTC.set({value:'disable_non_proxied_udp'})", arguments: [:], in: nil, contentWorld: .page)
        let beforeExpiry = try await gather("before")
        guard beforeExpiry == (0, 0) else { return false }
        // Shorten the same grant only after the override is materialized. No later
        // settings API operation may accidentally reschedule the expiry timer.
        let deadline = Date.now.addingTimeInterval(3)
        timed.0.grantedPermissions = [WKWebExtension.Permission(rawValue: "privacy"): deadline]
        guard Date.now < deadline,
              try await timed.1.evaluateJavaScript("typeof browser.privacy?.network?.webRTCIPHandlingPolicy?.get==='function'") as? Bool == true else { return false }
        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.5))
        // No extension API or page/window lifecycle operation occurs after expiry before
        // this new peer connection reads the already-open page's native RTC settings.
        let afterExpiry = try await gather("after")
        guard afterExpiry.0 > 0, afterExpiry.1 > 0,
              try await rejects(timed.1, "await timedRTC.get({})") else { return false }
        print("PASS: scoped native privacy, effective precedence, callbacks, events, revocation, unload and durable restoration")
        return true
    }
}
