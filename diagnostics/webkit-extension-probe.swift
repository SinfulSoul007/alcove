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
        try await runOffscreen(root: root.appendingPathComponent("mv3"))
        guard let argument = CommandLine.arguments.dropFirst().first,
              let server = URL(string: argument), server.scheme == "http", server.host == "127.0.0.1",
              server.port != nil else { throw CocoaError(.fileReadInvalidFileName) }
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
                        if (new URL(url).pathname.endsWith("/should-cancel.js")) return {cancel:true};
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
        func exercise(_ phase: String) async throws -> (control: Bool, candidate: Bool, events: [String]) {
            let address = server.appendingPathComponent("native-fixture-\(phase)-\(UUID().uuidString)")
            page.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
            for _ in 0..<450 where page.url != address || page.isLoading {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !page.isLoading, page.url == address,
                  let result = try await page.evaluateJavaScript("""
                    ({control: window.controlRequestLoaded === true, candidate: window.candidateRequestLoaded === true})
                    """) as? [String: Bool] else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(400))
            let observed = try await options.evaluateJavaScript("window.probeData.observed") as? [String] ?? []
            let events = observed.filter { $0.hasPrefix(address.absoluteString) }
            let control = result["control"] == true
            let candidate = result["candidate"] == true
            print("MV2_\(phase.uppercased()) control=\(control) candidate=\(candidate) events=\(events)")
            guard control else { throw CocoaError(.coderInvalidValue) }
            return (control, candidate, events)
        }
        let granted = try await exercise("granted")
        let pattern = try WKWebExtension.MatchPattern(string: "http://127.0.0.1/*")
        context.setPermissionStatus(.deniedExplicitly, for: server)
        context.setPermissionStatus(.deniedExplicitly, for: pattern)
        guard !context.hasAccess(to: server) else { throw CocoaError(.featureUnsupported) }
        let denied = try await exercise("denied")
        guard denied.candidate, denied.events.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let observedControl = granted.events.contains { URL(string: $0)?.lastPathComponent == "control.js" }
        let observedCandidate = granted.events.contains { URL(string: $0)?.lastPathComponent == "should-cancel.js" }
        let blocked = observedControl && observedCandidate && !granted.candidate
        print("MV2_BLOCKING_PROVEN \(blocked)")
        if requireBlocking && !blocked { throw CocoaError(.featureUnsupported) }
    }
}
