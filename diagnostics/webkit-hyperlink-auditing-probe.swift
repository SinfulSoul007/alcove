import Foundation
import WebKit

extension SystemWebKitExtensionProbe {
    @MainActor static func runHyperlinkAuditing(server: URL) async throws -> Bool {
        let isolatedSession = URLSession(configuration: .ephemeral)
        defer { isolatedSession.invalidateAndCancel() }
        func requests(to address: URL) async throws -> Int {
            var counter = URLComponents(url: server.appendingPathComponent("__request_count"), resolvingAgainstBaseURL: false)!
            counter.queryItems = [URLQueryItem(name: "path", value: address.path)]
            let (data, reply) = try await isolatedSession.data(from: counter.url!)
            guard (reply as? HTTPURLResponse)?.statusCode == 200,
                  let count = Int(String(decoding: data, as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
            return count
        }
        func waitForLoad(_ web: WKWebView, at address: URL) async throws {
            for _ in 0..<450 {
                if web.url == address && !web.isLoading { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        func exercise(_ phase: String, web: WKWebView) async throws -> (ping: Int, destination: Int, beacon: Int) {
            let root = server.appendingPathComponent("link-policy/\(phase)-\(UUID().uuidString)")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            let ping = root.appendingPathComponent("ping")
            let beacon = root.appendingPathComponent("beacon")
            web.load(URLRequest(url: source))
            try await waitForLoad(web, at: source)
            let queued = try await web.callAsyncJavaScript("return navigator.sendBeacon(url, 'fixture');",
                arguments: ["url": beacon.absoluteString], in: nil, contentWorld: .page) as? Bool == true
            guard queued else { throw CocoaError(.coderInvalidValue) }
            _ = try await web.evaluateJavaScript("document.getElementById('destination').click();")
            try await waitForLoad(web, at: destination)
            // Wait for the async ping to arrive independently of navigation.
            try await Task.sleep(for: .milliseconds(500))
            let result = try await (requests(to: ping), requests(to: destination), requests(to: beacon))
            print("LINK_AUDITING \(phase) ping=\(result.0) destination=\(result.1) beacon=\(result.2)")
            return result
        }
        func configuration() -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }
        let controlConfiguration = configuration()
        let control = WKWebView(frame: .zero, configuration: controlConfiguration)
        let baseline = try await exercise("baseline", web: control)
        guard baseline == (1, 1, 1) else { throw CocoaError(.coderInvalidValue) }

        let getter = NSSelectorFromString("_hyperlinkAuditingEnabled")
        let setter = NSSelectorFromString("_setHyperlinkAuditingEnabled:")
        let changedConfiguration = configuration()
        let preferences = changedConfiguration.preferences
        guard preferences.responds(to: getter), preferences.responds(to: setter),
              let getterMethod = preferences.method(for: getter),
              let setterMethod = preferences.method(for: setter) else {
            print("LINK_AUDITING_API false")
            return false
        }
        typealias ReadAuditing = @convention(c) (AnyObject, Selector) -> ObjCBool
        typealias SetAuditing = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let read = unsafeBitCast(getterMethod, to: ReadAuditing.self)
        let set = unsafeBitCast(setterMethod, to: SetAuditing.self)
        let defaultValue = read(preferences, getter).boolValue
        set(preferences, setter, ObjCBool(false))
        let disabledValue = read(preferences, getter).boolValue
        let changed = WKWebView(frame: .zero, configuration: changedConfiguration)
        let disabled = try await exercise("disabled", web: changed)
        let untouched = try await exercise("separate-page", web: control)
        set(preferences, setter, ObjCBool(true))
        let restoredValue = read(preferences, getter).boolValue
        let restored = try await exercise("restored", web: changed)
        return defaultValue && !disabledValue && restoredValue &&
            disabled == (0, 1, 1) && untouched == (1, 1, 1) && restored == (1, 1, 1)
    }
}
