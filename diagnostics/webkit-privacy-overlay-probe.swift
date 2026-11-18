import Foundation
import WebKit

extension SystemWebKitExtensionProbe {
    @MainActor static func applyPrivacyOverlay(_ values: [String: Any], to web: WKWebView) -> Bool? {
        let selector = NSSelectorFromString("_setExtensionPrivacyPreferences:")
        guard web.responds(to: selector), let implementation = web.method(for: selector) else { return nil }
        typealias Apply = @convention(c) (AnyObject, Selector, NSDictionary) -> ObjCBool
        return unsafeBitCast(implementation, to: Apply.self)(web, selector, values as NSDictionary).boolValue
    }

    @MainActor static func runPrivacyOverlay(server: URL) async throws -> Bool {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func count(_ address: URL) async throws -> Int {
            var query = URLComponents(url: server.appendingPathComponent("__request_count"), resolvingAgainstBaseURL: false)!
            query.queryItems = [URLQueryItem(name: "path", value: address.path)]
            let (data, reply) = try await session.data(from: query.url!)
            guard (reply as? HTTPURLResponse)?.statusCode == 200,
                  let count = Int(String(decoding: data, as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
            return count
        }
        func load(_ web: WKWebView, _ address: URL) async throws {
            web.load(URLRequest(url: address))
            for _ in 0..<450 {
                if web.url == address, !web.isLoading { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        func exercise(_ phase: String, _ web: WKWebView) async throws -> (Int, Int, Int) {
            let root = server.appendingPathComponent("link-policy/overlay-\(phase)-\(UUID().uuidString)")
            let destination = root.appendingPathComponent("destination")
            try await load(web, root.appendingPathComponent("source"))
            let queued = try await web.callAsyncJavaScript("return navigator.sendBeacon(url, 'fixture');",
                arguments: ["url": root.appendingPathComponent("beacon").absoluteString], in: nil, contentWorld: .page) as? Bool == true
            guard queued else { throw CocoaError(.coderInvalidValue) }
            _ = try await web.evaluateJavaScript("document.getElementById('destination').click();")
            for _ in 0..<450 where web.url != destination || web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            guard web.url == destination, !web.isLoading else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(500))
            let observed = try await (count(root.appendingPathComponent("ping")), count(destination), count(root.appendingPathComponent("beacon")))
            print("PRIVACY_OVERLAY \(phase) ping=\(observed.0) destination=\(observed.1) beacon=\(observed.2)")
            return observed
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = configuration.preferences
        let first = WKWebView(frame: .zero, configuration: configuration)
        let second = WKWebView(frame: .zero, configuration: configuration)
        let shared = first.configuration.preferences === second.configuration.preferences
        print("PRIVACY_OVERLAY_SHARED_PREFERENCES \(shared)")
        guard shared, try await exercise("baseline", first) == (1, 1, 1) else { return false }
        guard let applied = applyPrivacyOverlay(["hyperlinkAuditingEnabled": false,
            "networkPredictionEnabled": false, "webRTCIPHandlingPolicy": "disable_non_proxied_udp"], to: first) else {
            print("PRIVACY_OVERLAY_API false")
            return false
        }
        guard applied else { return false }
        let fresh = WKWebView(frame: .zero, configuration: configuration)
        guard applyPrivacyOverlay(["hyperlinkAuditingEnabled": false], to: fresh) == true,
              try await exercise("first-navigation", fresh) == (0, 1, 1) else { return false }
        guard try await exercise("disabled", first) == (0, 1, 1),
              try await exercise("shared-sibling", second) == (1, 1, 1) else { return false }

        let setter = NSSelectorFromString("_setHyperlinkAuditingEnabled:")
        guard let method = preferences.method(for: setter) else { return false }
        typealias SetBase = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let setBase = unsafeBitCast(method, to: SetBase.self)
        setBase(preferences, setter, ObjCBool(false))
        guard applyPrivacyOverlay(["hyperlinkAuditingEnabled": true], to: first) == true else { return false }
        preferences.javaScriptCanOpenWindowsAutomatically.toggle()
        guard try await exercise("override-after-base-change", first) == (1, 1, 1),
              try await exercise("sibling-base-change", second) == (0, 1, 1) else { return false }
        guard applyPrivacyOverlay([:], to: first) == true,
              try await exercise("clear-restores-current-base", first) == (0, 1, 1) else { return false }
        setBase(preferences, setter, ObjCBool(true))
        guard try await exercise("base-restored", first) == (1, 1, 1) else { return false }

        guard applyPrivacyOverlay(["hyperlinkAuditingEnabled": false], to: first) == true,
              applyPrivacyOverlay(["hyperlinkAuditingEnabled": "true"], to: first) == false,
              applyPrivacyOverlay(["hyperlinkAuditingEnabled": NSNumber(value: 1)], to: first) == false,
              applyPrivacyOverlay(["webRTCIPHandlingPolicy": "invalid"], to: first) == false,
              applyPrivacyOverlay(["unknownSetting": true], to: first) == false,
              applyPrivacyOverlay(["hyperlinkAuditingEnabled": true, "webRTCIPHandlingPolicy": "invalid"], to: first) == false,
              try await exercise("invalid-preserves-override", first) == (0, 1, 1),
              applyPrivacyOverlay([:], to: first) == true,
              try await exercise("final-restored", first) == (1, 1, 1) else { return false }
        print("PRIVACY_OVERLAY_ISOLATION_PROVEN true")
        return true
    }
}
