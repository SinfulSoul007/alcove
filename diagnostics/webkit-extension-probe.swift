import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor final class ProbeTab: NSObject, WKWebExtensionTab {
    let page: WKWebView
    let provisionalURL: URL
    weak var owner: ProbeWindow?
    init(page: WKWebView, provisionalURL: URL) { self.page = page; self.provisionalURL = provisionalURL }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { page }
    func url(for context: WKWebExtensionContext) -> URL? { page.url ?? provisionalURL }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
}

@available(macOS 15.4, *)
@MainActor final class ProbeWindow: NSObject, WKWebExtensionWindow {
    let tab: ProbeTab
    init(tab: ProbeTab) {
        self.tab = tab
        super.init()
        tab.owner = self
    }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
}

@available(macOS 15.4, *)
@MainActor final class ProbeWindowDelegate: NSObject, WKWebExtensionControllerDelegate {
    let window: ProbeWindow
    init(window: ProbeWindow) { self.window = window }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext)
    -> [any WKWebExtensionWindow] { [window] }
}

@MainActor final class ProbeNavigation: NSObject, WKNavigationDelegate {
    var result: Bool?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) { result = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) { result = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) { result = false }
}

@main
struct SystemWebKitExtensionProbe {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        guard #available(macOS 15.4, *) else { throw CocoaError(.featureUnsupported) }
        let framework = Bundle(for: WKWebView.self)
        let frameworkURL = framework.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let version = framework.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"
        print("FRAMEWORK \(version) at \(frameworkURL.path)")
        if let expected = ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] {
            let product = URL(fileURLWithPath: expected, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard frameworkURL.path.hasPrefix(product.path + "/") else {
                print("FAIL: the probe did not load the newly built framework")
                exit(1)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-webkit-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if CommandLine.arguments.contains("--require-runtime-url") {
            do { try await runRuntimeURL(root: root) }
            catch {
                print("FAIL: the extension runtime URL function lost its native owner or rejected a supported call")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            if CommandLine.arguments.contains("--runtime-url-only") { return }
        }
        let predictionTest = CommandLine.arguments.contains("--network-prediction-only")
        guard let argument = CommandLine.arguments.dropFirst().first,
              let server = URL(string: argument), server.scheme == (predictionTest ? "https" : "http"), server.host == "127.0.0.1",
              server.port != nil else { throw CocoaError(.fileReadInvalidFileName) }
        if CommandLine.arguments.contains("--navigation-target-only") {
            let passed = try await runNavigationTarget(root: root.appendingPathComponent("navigation"), server: server)
            if !passed {
                print("FAIL: the native extension requires a permission-checked created navigation target before navigation")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--request-cache-only") {
            let passed = try await runRequestCache(root: root.appendingPathComponent("request-cache"), server: server)
            if !passed {
                print("FAIL: extension changes must reach memory-cached requests in the approved WebKit profile")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--hyperlink-auditing-only") {
            let passed = try await runHyperlinkAuditing(server: server)
            if !passed {
                print("FAIL: the per-page privacy control must suppress hyperlink pings")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--privacy-overlay-only") {
            let passed = try await runPrivacyOverlay(server: server)
            if !passed {
                print("FAIL: extension privacy overrides must be isolated from shared browser preferences")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            return
        }
        if predictionTest {
            let passed = try await runNetworkPrediction(server: server)
            if !passed {
                print("FAIL: the WebKit network-prediction setting must suppress speculative loads")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--rtc-policy-only") {
            let passed = try await runRTCPolicy(server: server)
            if !passed {
                print("FAIL: WebRTC policy must control native UDP routes in its page")
                try? FileManager.default.removeItem(at: root)
                exit(1)
            }
            return
        }
        try await runOffscreen(root: root.appendingPathComponent("mv3"))
        try await runBlocking(root: root.appendingPathComponent("mv2"), server: server,
                              requireBlocking: CommandLine.arguments.contains("--require-blocking"))
    }

    @available(macOS 15.4, *)
    @MainActor static func create(_ directory: URL, manifest: [String: Any], resources: [String: String],
                                  permissions: [String], loopback: Bool = false) async throws
    -> (WKWebExtensionController, WKWebExtensionContext, WKWebsiteDataStore, WKWebView) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        for (name, content) in resources { try Data(content.utf8).write(to: directory.appendingPathComponent(name)) }
        try Data("<!doctype html><meta charset='utf-8'><title>Owned WebKit capability probe</title>".utf8)
            .write(to: directory.appendingPathComponent("options.html"))
        let ext = try await WKWebExtension(resourceBaseURL: directory)
        let data = WKWebsiteDataStore.nonPersistent()
        let controllerConfig = WKWebExtensionController.Configuration.nonPersistent()
        controllerConfig.defaultWebsiteDataStore = data
        let background = WKWebViewConfiguration()
        background.websiteDataStore = data
        controllerConfig.webViewConfiguration = background
        let controller = WKWebExtensionController(configuration: controllerConfig)
        let context = WKWebExtensionContext(for: ext)
        context.grantedPermissions = Dictionary(uniqueKeysWithValues: permissions.map { (WKWebExtension.Permission(rawValue: $0), .distantFuture) })
        if loopback {
            context.grantedPermissionMatchPatterns = [try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*"): .distantFuture]
        }
        try controller.load(context)
        guard let configuration = context.webViewConfiguration, let pageURL = context.optionsPageURL else {
            throw CocoaError(.featureUnsupported)
        }
        let page = try await load(pageURL, configuration: configuration)
        guard (try await page.evaluateJavaScript("typeof browser?.runtime?.getManifest")) as? String == "function" else {
            throw CocoaError(.featureUnsupported)
        }
        return (controller, context, data, page)
    }

    @MainActor static func load(_ address: URL, configuration: WKWebViewConfiguration) async throws -> WKWebView {
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 420), configuration: configuration)
        page.load(URLRequest(url: address))
        for _ in 0..<450 {
            if page.url == address, !page.isLoading,
               (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" { return page }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    @available(macOS 15.4, *)
    @MainActor static func runRuntimeURL(root: URL) async throws {
        func observe(_ name: String) async throws -> URL {
            let (controller, context, _, page) = try await create(root.appendingPathComponent(name),
                manifest: ["manifest_version": 2, "name": name, "version": "1", "options_page": "options.html"],
                resources: [:], permissions: [])
            defer { try? controller.unload(context) }
            let result = try await page.evaluateJavaScript("""
                (() => {
                    const runtime = browser.runtime;
                    const alias = runtime.getURL;
                    const copied = {lookup: alias};
                    const safe = (fn) => { try { return fn() ?? null; } catch (_) { return null; } };
                    const rejects = (fn) => { try { fn(); return false; } catch (_) { return true; } };
                    return {root:runtime.getURL(''), direct:runtime.getURL('options.html'),
                        moved:safe(() => copied.lookup('options.html')),
                        called:safe(() => alias.call({}, 'options.html')),
                        stable:alias === runtime.getURL, callable:typeof alias === 'function',
                        rejectsMissing:rejects(() => alias()), rejectsNumber:rejects(() => alias(17))};
                })()
                """) as? [String: Any]
            let base = context.baseURL
            let expected = base.appendingPathComponent("options.html").absoluteString
            print("RUNTIME_URL_OWNER \(name) direct=\(result?["direct"] as? String == expected) moved=\(result?["moved"] as? String == expected) called=\(result?["called"] as? String == expected)")
            guard result?["root"] as? String == base.absoluteString,
                  result?["direct"] as? String == expected,
                  result?["moved"] as? String == expected, result?["called"] as? String == expected,
                  result?["stable"] as? Bool == true, result?["callable"] as? Bool == true,
                  result?["rejectsMissing"] as? Bool == true, result?["rejectsNumber"] as? Bool == true else {
                throw CocoaError(.coderInvalidValue)
            }
            return base
        }
        let first = try await observe("Owned URL runtime A")
        let second = try await observe("Owned URL runtime B")
        guard first.host != nil, second.host != nil, first.host != second.host else {
            throw CocoaError(.coderInvalidValue)
        }
        print("RUNTIME_URL_OWNERS_VERIFIED")
    }

    @available(macOS 15.4, *)
    @MainActor static func runOffscreen(root: URL) async throws {
        let (controller, context, _, page) = try await create(root,
            manifest: ["manifest_version": 3, "name": "Owned Offscreen Capability", "version": "1",
                       "permissions": ["offscreen", "userScripts"], "options_page": "options.html",
                       "background": ["service_worker": "background.js"]],
            resources: ["background.js": "/* owned capability fixture */",
                        "offscreen.html": "<!doctype html><script src='offscreen.js'></script>",
                        "offscreen.js": "browser.runtime.onMessage.addListener(m => m.kind === 'offscreen-fixture' ? Promise.resolve('owned-offscreen') : undefined);"],
            permissions: ["offscreen", "userScripts"])
        defer { try? controller.unload(context) }
        let result = try await page.callAsyncJavaScript("""
            const result = { offscreen: typeof browser.offscreen?.createDocument, userScripts: typeof browser.userScripts?.register };
            if (result.offscreen === "function") {
                try {
                    await browser.offscreen.createDocument({ url: "offscreen.html", reasons: ["DOM_PARSER"], justification: "Alcove owned compatibility test" });
                    result.message = await browser.runtime.sendMessage({kind: "offscreen-fixture"});
                    await browser.offscreen.closeDocument();
                    result.closed = true;
                } catch (error) {
                    result.error = String(error);
                }
            }
            return JSON.stringify(result);
            """, arguments: [:], in: nil, contentWorld: .page)
        guard let result = result as? String else { throw CocoaError(.coderInvalidValue) }
        print("MV3_CAPABILITIES \(result)")
    }

    @available(macOS 15.4, *)
    @MainActor static func runBlocking(root: URL, server: URL, requireBlocking: Bool) async throws {
        let watcher = """
            const observed = [];
            const status = {event: typeof browser.webRequest?.onBeforeRequest?.addListener};
            if (status.event === "function") {
                const filter = {urls:["http://127.0.0.1/*"]};
                browser.webRequest.onBeforeRequest.addListener(({url}) => { observed.push(url); }, filter);
                try {
                    browser.webRequest.onBeforeRequest.addListener(({url}) => {
                        observed.push(url);
                        const path = new URL(url).pathname;
                        if (path.endsWith("/should-cancel.js") || path.startsWith("/native-block-top-")) return {cancel:true};
                    }, filter, ["blocking"]);
                    status.registered = true;
                } catch (error) {
                    status.registered = false;
                    status.error = String(error);
                }
            }
            window.probeData = {status, observed};
            return JSON.stringify(status);
            """
        let (controller, context, data, options) = try await create(root,
            manifest: ["manifest_version": 2, "name": "Owned Blocking Capability", "version": "1",
                       "permissions": ["webRequest", "webRequestBlocking", "http://127.0.0.1/*"],
                       "options_page": "options.html"], resources: [:],
            permissions: ["webRequest", "webRequestBlocking"], loopback: true)
        defer { try? controller.unload(context) }
        context.setPermissionStatus(.grantedExplicitly, for: server)
        let registration = try await options.callAsyncJavaScript(watcher, arguments: [:], in: nil, contentWorld: .page)
        print("MV2_REGISTRATION \(registration ?? "missing")")
        print("MV2_HOST_APPROVED \(context.hasAccess(to: server))")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = data
        configuration.webExtensionController = controller
        let page = WKWebView(frame: .zero, configuration: configuration)
        let tab = ProbeTab(page: page, provisionalURL: server)
        let window = ProbeWindow(tab: tab)
        let delegate = ProbeWindowDelegate(window: window)
        controller.delegate = delegate
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        controller.didOpenTab(tab)
        defer {
            controller.didCloseTab(tab, windowIsClosing: true)
            controller.didCloseWindow(window)
            withExtendedLifetime(delegate) {}
        }
        let requests = URLSession(configuration: .ephemeral)
        defer { requests.invalidateAndCancel() }
        func count(_ path: String) async throws -> Int {
            var address = URLComponents(url: server.appendingPathComponent("__request_count"), resolvingAgainstBaseURL: false)!
            address.queryItems = [URLQueryItem(name: "path", value: path)]
            let (data, response) = try await requests.data(from: address.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let count = Int(String(decoding: data, as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
            return count
        }
        func matchingEvents(for address: URL) async throws -> [String] {
            try await Task.sleep(for: .milliseconds(400))
            let observed = try await options.evaluateJavaScript("window.probeData.observed") as? [String] ?? []
            return observed.filter { $0.hasPrefix(address.absoluteString) }
        }
        func exercise(_ phase: String, in page: WKWebView) async throws -> (candidate: Bool, requests: Int, events: [String]) {
            let address = server.appendingPathComponent("native-fixture-\(phase)-\(UUID().uuidString)")
            page.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
            for _ in 0..<450 where page.url != address || page.isLoading {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !page.isLoading, page.url == address,
                  let result = try await page.evaluateJavaScript("""
                    ({control: window.controlRequestLoaded === true, candidate: window.candidateRequestLoaded === true})
                    """) as? [String: Bool] else { throw URLError(.timedOut) }
            let events = try await matchingEvents(for: address)
            let control = result["control"] == true
            let candidate = result["candidate"] == true
            let controlRequests = try await count(address.path + "/control.js")
            let candidateRequests = try await count(address.path + "/should-cancel.js")
            print("MV2_\(phase.uppercased()) control=\(control) candidate=\(candidate) requests=\(controlRequests)/\(candidateRequests) events=\(events)")
            guard control, controlRequests > 0, !candidate || candidateRequests > 0 else { throw CocoaError(.coderInvalidValue) }
            return (candidate, candidateRequests, events)
        }
        func exerciseMain(_ phase: String) async throws -> (loaded: Bool, requests: Int, observed: Bool) {
            let address = server.appendingPathComponent("native-block-top-\(phase)-\(UUID().uuidString)")
            let navigation = ProbeNavigation()
            page.navigationDelegate = navigation
            defer { page.navigationDelegate = nil }
            page.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
            for _ in 0..<450 where navigation.result == nil { try await Task.sleep(for: .milliseconds(20)) }
            guard let loaded = navigation.result else { throw URLError(.timedOut) }
            let observed = try await matchingEvents(for: address).contains(address.absoluteString)
            let requests = try await count(address.path)
            print("MV2_TOP_\(phase.uppercased()) loaded=\(loaded) requests=\(requests) observed=\(observed)")
            return (loaded, requests, observed)
        }
        // This fixture has a disposable nonpersistent data store, so WebKit treats its tab as private.
        // Verify the barrier before granting this synthetic extension access to that tab.
        guard !context.hasAccessToPrivateData else { throw CocoaError(.coderInvalidValue) }
        let privateDenied = try await exercise("private-denied", in: page)
        let privateDeniedMain = try await exerciseMain("private-denied")
        guard privateDenied.candidate, privateDenied.requests > 0, privateDenied.events.isEmpty,
              privateDeniedMain.loaded, privateDeniedMain.requests > 0, !privateDeniedMain.observed else {
            throw CocoaError(.coderInvalidValue)
        }
        context.hasAccessToPrivateData = true
        let granted = try await exercise("granted", in: page)
        let grantedMain = try await exerciseMain("granted")
        let isolatedConfig = WKWebViewConfiguration()
        isolatedConfig.websiteDataStore = .nonPersistent()
        let isolated = try await exercise("isolated", in: WKWebView(frame: .zero, configuration: isolatedConfig))
        guard isolated.candidate, isolated.requests > 0, isolated.events.isEmpty else { throw CocoaError(.coderInvalidValue) }

        let pattern = try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*")
        context.setPermissionStatus(.deniedExplicitly, for: server)
        context.setPermissionStatus(.deniedExplicitly, for: pattern)
        guard !context.hasAccess(to: server) else { throw CocoaError(.featureUnsupported) }
        let denied = try await exercise("denied", in: page)
        let deniedMain = try await exerciseMain("denied")
        guard denied.candidate, denied.requests > 0, denied.events.isEmpty,
              deniedMain.loaded, deniedMain.requests > 0, !deniedMain.observed else { throw CocoaError(.coderInvalidValue) }
        let observedControl = granted.events.contains { URL(string: $0)?.lastPathComponent == "control.js" }
        let observedCandidate = granted.events.contains { URL(string: $0)?.lastPathComponent == "should-cancel.js" }
        let blockedResource = observedControl && observedCandidate && !granted.candidate && granted.requests == 0
        let blockedMain = grantedMain.observed && !grantedMain.loaded && grantedMain.requests == 0
        print("MV2_SUBRESOURCE_BLOCKING_PROVEN \(blockedResource)")
        print("MV2_TOP_BLOCKING_PROVEN \(blockedMain)")
        if requireBlocking && !(blockedResource && blockedMain) {
            print("FAIL: before-send blocking was not proven for both request types")
            exit(1)
        }
    }
}

@available(macOS 15.4, *)
@MainActor final class NavigationTargetDelegate: NSObject, WKUIDelegate, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    var windows: [ProbeWindow] = []
    var rejected = 0
    var allowsPopup = true

    init(controller: WKWebExtensionController) { self.controller = controller }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows
    }

    func openTab(_ configuration: WKWebViewConfiguration, url: URL) -> WKWebView {
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.uiDelegate = self
        let tab = ProbeTab(page: page, provisionalURL: url)
        let window = ProbeWindow(tab: tab)
        windows.append(window)
        controller.didOpenWindow(window)
        controller.didOpenTab(tab)
        return page
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard allowsPopup, let address = action.request.url else { rejected += 1; return nil }
        return openTab(configuration, url: address)
    }

    func closeTabs() {
        for window in windows.reversed() {
            controller.didCloseTab(window.tab, windowIsClosing: true)
            controller.didCloseWindow(window)
        }
        windows.removeAll()
    }
}

@available(macOS 15.4, *)
extension SystemWebKitExtensionProbe {
    @MainActor static func runNavigationTarget(root: URL, server: URL) async throws -> Bool {
        let scope = "http://127.0.0.1/*"
        let (controller, context, data, options) = try await create(root,
            manifest: ["manifest_version": 2, "name": "Owned Navigation Target", "version": "1",
                       "permissions": ["webNavigation", scope], "options_page": "options.html"],
            resources: [:], permissions: ["webNavigation"], loopback: true)
        let delegate = NavigationTargetDelegate(controller: controller)
        controller.delegate = delegate
        defer {
            delegate.closeTabs()
            try? controller.unload(context)
        }
        let available = try await options.callAsyncJavaScript("""
            const navigation = browser.webNavigation;
            const events = [];
            window.navigationEvents = events;
            const filter = {url:[{hostEquals:"127.0.0.1", pathPrefix:"/navigation-target-"}]};
            navigation.onBeforeNavigate.addListener(details => events.push({kind:"before", ...details}), filter);
            const target = navigation.onCreatedNavigationTarget;
            if (!target) return false;
            target.addListener(details => events.push({kind:"created", ...details}), filter);
            return typeof target.hasListener === "function";
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        print("NAVIGATION_TARGET_API \(available)")

        func configuration() -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = data
            configuration.webExtensionController = controller
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            return configuration
        }
        func address(_ label: String) -> URL {
            server.appendingPathComponent("navigation-target-\(label)-\(UUID().uuidString)")
        }
        func waitForLoad(_ page: WKWebView, url: URL) async throws {
            for _ in 0..<450 {
                if page.url == url && !page.isLoading { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        func events(for url: URL) async throws -> [[String: Any]] {
            try await Task.sleep(for: .milliseconds(250))
            let events = try await options.evaluateJavaScript("window.navigationEvents") as? [[String: Any]] ?? []
            return events.filter { $0["url"] as? String == url.absoluteString }
        }
        func popup(from source: WKWebView, label: String, subframe: Bool = false) async throws -> URL {
            let target = address(label)
            let previous = delegate.windows.count
            let launch = subframe
                ? "document.querySelector('iframe').contentWindow.eval(source);"
                : "eval(source);"
            let script = "window.open('\(target.absoluteString)', '_blank', 'noopener');"
            _ = try await source.callAsyncJavaScript(launch, arguments: ["source": script], in: nil, contentWorld: .page)
            guard delegate.windows.count == previous + 1, let page = delegate.windows.last?.tab.page else {
                throw CocoaError(.coderInvalidValue)
            }
            try await waitForLoad(page, url: target)
            return target
        }

        let openerURL = address("opener")
        let opener = delegate.openTab(configuration(), url: openerURL)
        opener.load(URLRequest(url: openerURL))
        try await waitForLoad(opener, url: openerURL)
        let privateTarget = try await popup(from: opener, label: "private-denied")
        let privateEvents = try await events(for: privateTarget)
        context.hasAccessToPrivateData = true

        let navigateOpener = address("opener-granted")
        opener.load(URLRequest(url: navigateOpener))
        try await waitForLoad(opener, url: navigateOpener)
        let openerEvent = try await events(for: navigateOpener).first
        guard openerEvent?["kind"] as? String == "before", let openerID = openerEvent?["tabId"] as? Int else {
            throw CocoaError(.coderInvalidValue)
        }
        let target = try await popup(from: opener, label: "accepted")
        let mainEvents = try await events(for: target)
        let frameURL = address("frame")
        _ = try await opener.callAsyncJavaScript("""
            await new Promise((resolve, reject) => {
                const frame = document.createElement("iframe");
                frame.onload = resolve;
                frame.onerror = reject;
                frame.src = url;
                document.body.append(frame);
            });
            """, arguments: ["url": frameURL.absoluteString], in: nil, contentWorld: .page)
        let frameEvent = try await events(for: frameURL).first
        guard let sourceFrame = frameEvent?["frameId"] as? Int, sourceFrame > 0,
              frameEvent?["tabId"] as? Int == openerID else { throw CocoaError(.coderInvalidValue) }
        let nestedTarget = try await popup(from: opener, label: "subframe", subframe: true)
        let nestedEvents = try await events(for: nestedTarget)

        let ordinaryURL = address("ordinary")
        let ordinary = delegate.openTab(configuration(), url: ordinaryURL)
        ordinary.load(URLRequest(url: ordinaryURL))
        try await waitForLoad(ordinary, url: ordinaryURL)
        let ordinaryEvents = try await events(for: ordinaryURL)
        delegate.allowsPopup = false
        let canceled = address("canceled")
        _ = try await opener.callAsyncJavaScript("window.open(url, '_blank', 'noopener');",
            arguments: ["url": canceled.absoluteString], in: nil, contentWorld: .page)
        let canceledEvents = try await events(for: canceled)
        delegate.allowsPopup = true

        var alternate = URLComponents(url: address("source-site-denied"), resolvingAgainstBaseURL: false)!
        alternate.host = "localhost"
        let otherSource = alternate.url!
        guard !context.hasAccess(to: otherSource) else { throw CocoaError(.coderInvalidValue) }
        let otherOpener = delegate.openTab(configuration(), url: otherSource)
        otherOpener.load(URLRequest(url: otherSource))
        try await waitForLoad(otherOpener, url: otherSource)
        let sourceDenied = try await popup(from: otherOpener, label: "source-site-denied-target")
        let sourceDeniedEvents = try await events(for: sourceDenied)

        context.setPermissionStatus(.deniedExplicitly, for: try WKWebExtension.MatchPattern(string: scope))
        let denied = try await popup(from: opener, label: "site-denied")
        let deniedEvents = try await events(for: denied)

        func valid(_ events: [[String: Any]], from frame: Int) -> Bool {
            guard events.map({ $0["kind"] as? String }) == ["created", "before"],
                  let destination = events[0]["tabId"] as? Int, destination != openerID else { return false }
            return events[0]["sourceTabId"] as? Int == openerID && events[0]["sourceFrameId"] as? Int == frame &&
                events[1]["tabId"] as? Int == destination && events[0]["timeStamp"] as? Double != nil &&
                events[0]["frameId"] == nil && events[0]["documentId"] == nil
        }
        let mainPassed = valid(mainEvents, from: 0)
        let nestedPassed = valid(nestedEvents, from: sourceFrame)
        let isolationPassed = privateEvents.isEmpty && canceledEvents.isEmpty && deniedEvents.isEmpty &&
            ordinaryEvents.map({ $0["kind"] as? String }) == ["before"] &&
            sourceDeniedEvents.map({ $0["kind"] as? String }) == ["before"] && delegate.rejected == 1
        print("NAVIGATION_TARGET main=\(mainEvents.map { $0["kind"] ?? "unknown" }) nested=\(nestedEvents.map { $0["kind"] ?? "unknown" }) isolation=\(isolationPassed)")
        return available && mainPassed && nestedPassed && isolationPassed
    }
}
