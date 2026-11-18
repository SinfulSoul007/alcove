import WebKit

@available(macOS 15.4, *)
extension SystemWebKitExtensionProbe {
    @MainActor static func runRequestCache(root: URL, server: URL) async throws -> Bool {
        let (controller, context, data, options) = try await create(root,
            manifest: ["manifest_version": 2, "name": "Owned Request Cache", "version": "1",
                       "permissions": ["webRequest", "webRequestBlocking", "http://127.0.0.1/*"],
                       "options_page": "options.html"], resources: [:],
            permissions: ["webRequest", "webRequestBlocking"], loopback: true)
        defer { try? controller.unload(context) }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = data
        configuration.webExtensionController = controller
        let page = WKWebView(frame: .zero, configuration: configuration)
        let tab = ProbeTab(page: page, provisionalURL: server)
        let window = ProbeWindow(tab: tab)
        let delegate = ProbeWindowDelegate(window: window)
        controller.delegate = delegate
        controller.didOpenWindow(window)
        controller.didOpenTab(tab)
        defer {
            controller.didCloseTab(tab, windowIsClosing: true)
            controller.didCloseWindow(window)
            withExtendedLifetime(delegate) {}
        }

        let isolated = WKWebsiteDataStore.nonPersistent()
        let isolatedConfiguration = WKWebViewConfiguration()
        isolatedConfiguration.websiteDataStore = isolated
        let isolatedPage = WKWebView(frame: .zero, configuration: isolatedConfiguration)
        let dataDirectory = server.appendingPathComponent("rule-cache/" + UUID().uuidString)
        let isolatedDirectory = server.appendingPathComponent("rule-cache/" + UUID().uuidString)
        let resource = dataDirectory.appendingPathComponent("candidate.js")
        let cacheTypes: Set<String> = [WKWebsiteDataTypeMemoryCache]

        func navigate(_ target: WKWebView, _ address: URL) async throws -> Bool {
            target.load(URLRequest(url: address))
            for _ in 0..<450 {
                if target.url == address && !target.isLoading {
                    return try await target.evaluateJavaScript("window.cacheFixtureScriptRan === true") as? Bool == true
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        func hasLoopbackCache(_ store: WKWebsiteDataStore) async -> Bool {
            let records = await store.dataRecords(ofTypes: cacheTypes)
            return records.contains { $0.displayName.contains("127.0.0.1") && $0.dataTypes.contains(WKWebsiteDataTypeMemoryCache) }
        }
        func requestCount() async throws -> Int {
            var address = URLComponents(url: server.appendingPathComponent("__request_count"), resolvingAgainstBaseURL: false)!
            address.queryItems = [URLQueryItem(name: "path", value: resource.path)]
            let (contents, response) = try await URLSession.shared.data(from: address.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let count = Int(String(decoding: contents, as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
            return count
        }

        let warm = try await navigate(page, dataDirectory.appendingPathComponent("warm"))
        let warmIsolated = try await navigate(isolatedPage, isolatedDirectory.appendingPathComponent("warm"))
        let ownedMemory = await hasLoopbackCache(data)
        let isolatedMemory = await hasLoopbackCache(isolated)
        let count = try await requestCount()
        print("REQUEST_CACHE_WARM owned=\(warm && ownedMemory) isolated=\(warmIsolated && isolatedMemory) requests=\(count)")
        guard warm, warmIsolated, ownedMemory, isolatedMemory, count == 1 else { throw CocoaError(.coderInvalidValue) }

        let available = try await options.evaluateJavaScript("typeof browser.webRequest.handlerBehaviorChanged === 'function'") as? Bool == true
        print("REQUEST_CACHE_API \(available)")
        guard available else { return false }

        _ = try await page.evaluateJavaScript("localStorage.setItem('owned-cache-fixture','kept')")
        let deniedResult = try await options.callAsyncJavaScript("""
            await browser.webRequest.handlerBehaviorChanged();
            return true;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        let cacheDenied = await hasLoopbackCache(data)
        context.hasAccessToPrivateData = true
        let registered = try await options.callAsyncJavaScript("""
            window.cacheFixtureAttempts = [];
            browser.webRequest.onBeforeRequest.addListener(details => {
                if (details.url === resource) {
                    window.cacheFixtureAttempts.push(details.url);
                    return {cancel:true};
                }
            }, {urls:["http://127.0.0.1/*"]}, ["blocking"]);
            return true;
            """, arguments: ["resource": resource.absoluteString], in: nil, contentWorld: .page) as? Bool == true
        let bypassedRule = try await navigate(page, dataDirectory.appendingPathComponent("still-warm"))
        let promiseResult = try await options.callAsyncJavaScript("""
            const reply = browser.webRequest.handlerBehaviorChanged();
            return reply instanceof Promise && await reply === undefined;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        let cacheAfterEviction = await hasLoopbackCache(data)
        let isolationPreserved = await hasLoopbackCache(isolated)
        let afterEviction = try await navigate(page, dataDirectory.appendingPathComponent("new-rule"))
        let observed = try await options.evaluateJavaScript("window.cacheFixtureAttempts.length") as? Int ?? 0
        let finalCount = try await requestCount()
        let retained = try await page.evaluateJavaScript("localStorage.getItem('owned-cache-fixture')") as? String == "kept"
        let callbacks = try await options.callAsyncJavaScript("""
            return await new Promise(resolve => chrome.webRequest.handlerBehaviorChanged(function() {
                resolve(arguments.length === 0 && chrome.runtime.lastError === undefined);
            }));
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        let quota = try await options.callAsyncJavaScript("""
            const api = browser.webRequest;
            let allowed = 0;
            let rejected = 0;
            for (let call = 0; call < 19; ++call) {
                try { await api.handlerBehaviorChanged(); ++allowed; }
                catch (_) { ++rejected; }
            }
            return api.MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES === 20 && allowed === 17 && rejected === 2;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true

        print("REQUEST_CACHE_RESULT denied=\(deniedResult && cacheDenied) isolated=\(isolationPreserved) warmBypassedRule=\(bypassedRule) evicted=\(!cacheAfterEviction) blocked=\(!afterEviction && observed == 1 && finalCount == 1) retained=\(retained) callback=\(callbacks) promise=\(promiseResult) quota=\(quota)")
        return deniedResult && cacheDenied && registered && bypassedRule && !cacheAfterEviction &&
            isolationPreserved && !afterEviction && observed == 1 && finalCount == 1 && retained &&
            callbacks && promiseResult && quota
    }
}
