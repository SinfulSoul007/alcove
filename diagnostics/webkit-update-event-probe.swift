import AppKit
import WebKit

@main struct ExtensionUpdateEventProbe {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        guard #available(macOS 15.4, *) else { throw CocoaError(.featureUnsupported) }
        let framework = Bundle(for: WKWebView.self)
        let frameworkURL = framework.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        print("FRAMEWORK \(framework.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") at \(frameworkURL.path)")
        if let expected = ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] {
            let product = URL(fileURLWithPath: expected).standardizedFileURL.resolvingSymlinksInPath()
            guard frameworkURL.path.hasPrefix(product.path + "/") else {
                print("FAIL: update-event probe did not load the newly built framework")
                exit(1)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-update-event-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let passed = try await run(root: root)
        if !passed {
            print("FAIL: a pending extension update must reach its own native runtime listeners")
            exit(1)
        }
        print("NATIVE_EXTENSION_UPDATE_EVENT_PROVEN true")
    }

    @available(macOS 15.4, *)
    @MainActor static func run(root: URL) async throws -> Bool {
        let data = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = data
        let background = WKWebViewConfiguration()
        background.websiteDataStore = data
        configuration.webViewConfiguration = background
        let controller = WKWebExtensionController(configuration: configuration)
        let first = try await makeExtension(root: root.appendingPathComponent("first"), controller: controller)
        let second = try await makeExtension(root: root.appendingPathComponent("second"), controller: controller)
        defer {
            if first.0.isLoaded { try? controller.unload(first.0) }
            if second.0.isLoaded { try? controller.unload(second.0) }
        }
        let pageHasEvent = try await first.1.evaluateJavaScript("window.updateEventAvailable") as? Bool == true
        let hostSelector = NSSelectorFromString("_didFindExtensionUpdateWithVersion:")
        let hostHasEvent = first.0.responds(to: hostSelector)
        print("UPDATE_EVENT_OPTIONS_API \(pageHasEvent)")
        print("UPDATE_EVENT_NATIVE_HOST \(hostHasEvent)")
        guard pageHasEvent, hostHasEvent else { return false }

        func announce(_ context: WKWebExtensionContext, _ version: String) {
            _ = context.perform(hostSelector, with: version as NSString)
        }
        func options(_ page: WKWebView) async throws -> [String] {
            try await page.evaluateJavaScript("window.updateEvents.map(event => event.version)") as? [String] ?? []
        }
        func stored(_ page: WKWebView) async throws -> [String] {
            try await page.callAsyncJavaScript("return (await browser.storage.local.get('versions')).versions || []",
                                              arguments: [:], in: nil, contentWorld: .page) as? [String] ?? []
        }
        func waitFor(_ page: WKWebView, versions: [String], includeOptions: Bool = true) async throws -> Bool {
            for _ in 0..<200 {
                let actual = try await stored(page)
                if actual == versions {
                    if !includeOptions { return true }
                    if try await options(page) == versions { return true }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        announce(first.0, "2.3.4")
        guard try await waitFor(first.1, versions: ["2.3.4"]) else { return false }
        let detailsAreExact = try await first.1.evaluateJavaScript("JSON.stringify(window.updateEvents) === '[{\"version\":\"2.3.4\"}]'") as? Bool == true
        guard detailsAreExact, try await stored(second.1).isEmpty, try await options(second.1).isEmpty else { return false }
        print("PASS: real background and options listeners receive the exact version; sibling context receives nothing")

        _ = try await first.1.evaluateJavaScript("browser.runtime.onUpdateAvailable.removeListener(window.updateListener)")
        let listenerRemoved = try await first.1.evaluateJavaScript("!browser.runtime.onUpdateAvailable.hasListener(window.updateListener)") as? Bool == true
        announce(first.0, "2.4.0")
        guard listenerRemoved, try await waitFor(first.1, versions: ["2.3.4", "2.4.0"], includeOptions: false),
              try await options(first.1) == ["2.3.4"] else { return false }
        print("PASS: removing an options listener preserves the separate background listener")

        announce(first.0, "")
        announce(first.0, "1.0")
        announce(second.0, "3.0")
        guard try await waitFor(second.1, versions: ["3.0"]) else { return false }
        try await Task.sleep(for: .milliseconds(250))
        guard try await stored(first.1) == ["2.3.4", "2.4.0"] else { return false }
        print("PASS: empty and installed versions are ignored and sibling dispatch remains isolated")

        try controller.unload(first.0)
        announce(first.0, "4.0")
        announce(second.0, "3.1")
        guard !first.0.isLoaded, try await waitFor(second.1, versions: ["3.0", "3.1"]) else { return false }
        let backgroundSelector = NSSelectorFromString("_backgroundWebView")
        if first.0.responds(to: backgroundSelector), first.0.perform(backgroundSelector)?.takeUnretainedValue() != nil { return false }
        print("PASS: an unloaded context does not wake background content; the loaded sibling continues receiving events")

        let sleeping = try await makeExtension(root: root.appendingPathComponent("event-page"), controller: controller, persistent: false)
        defer { if sleeping.0.isLoaded { try? controller.unload(sleeping.0) } }
        guard sleeping.0.responds(to: backgroundSelector) else { return false }
        var backgroundUnloaded = false
        for _ in 0..<160 {
            if sleeping.0.perform(backgroundSelector)?.takeUnretainedValue() == nil {
                backgroundUnloaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard backgroundUnloaded else {
            print("FAIL: the nonpersistent background page did not unload before the wake-up test")
            return false
        }
        announce(sleeping.0, "5.0")
        guard try await waitFor(sleeping.1, versions: ["5.0"]) else { return false }
        print("PASS: the native event wakes an actually unloaded nonpersistent background page and reaches its listener")
        return true
    }

    @available(macOS 15.4, *)
    @MainActor static func makeExtension(root: URL, controller: WKWebExtensionController, persistent: Bool = true) async throws -> (WKWebExtensionContext, WKWebView) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 2, "name": root.lastPathComponent,
            "version": "1.0", "permissions": ["storage"], "options_page": "options.html",
            "background": ["scripts": ["background.js"], "persistent": persistent]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data("""
            globalThis.versions = [];
            const available = typeof browser.runtime.onUpdateAvailable?.addListener === 'function';
            if (available) browser.runtime.onUpdateAvailable.addListener(details => {
                versions.push(details.version);
                browser.storage.local.set({versions: [...versions]});
            });
            browser.storage.local.set({versions: [], ready: true, backgroundHasEvent: available});
            """.utf8).write(to: root.appendingPathComponent("background.js"))
        try Data("<!doctype html><meta charset='utf-8'><title>Native update event</title><script src='options.js'></script>".utf8)
            .write(to: root.appendingPathComponent("options.html"))
        try Data("""
            window.updateEvents = [];
            window.updateEventAvailable = typeof browser.runtime.onUpdateAvailable?.addListener === 'function';
            window.updateListener = details => window.updateEvents.push(details);
            if (window.updateEventAvailable) browser.runtime.onUpdateAvailable.addListener(window.updateListener);
            """.utf8).write(to: root.appendingPathComponent("options.js"))
        let ext = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: ext)
        context.grantedPermissions = [WKWebExtension.Permission(rawValue: "storage"): .distantFuture]
        try controller.load(context)
        guard let pageConfiguration = context.webViewConfiguration, let optionsURL = context.optionsPageURL else { throw CocoaError(.featureUnsupported) }
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: pageConfiguration)
        page.load(URLRequest(url: optionsURL))
        for _ in 0..<300 {
            if page.url == optionsURL, !page.isLoading,
               let ready = try? await page.callAsyncJavaScript("return (await browser.storage.local.get('ready')).ready === true",
                    arguments: [:], in: nil, contentWorld: .page) as? Bool, ready { return (context, page) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
}
