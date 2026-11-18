import Foundation
import ObjectiveC
import WebKit

extension SystemWebKitExtensionProbe {
    @MainActor static func runRTCPolicy(server: URL) async throws -> Bool {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func response(_ address: URL) async throws -> [String: Int] {
            let (data, reply) = try await session.data(from: address)
            guard (reply as? HTTPURLResponse)?.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
                throw CocoaError(.coderInvalidValue)
            }
            return value
        }
        func page(_ configuration: WKWebViewConfiguration) async throws -> WKWebView {
            configuration.websiteDataStore = .nonPersistent()
            return try await load(server.appendingPathComponent("page"), configuration: configuration)
        }
        func gather(_ phase: String, web: WKWebView) async throws -> (requests: Int, host: Int, reflexive: Int, udp: Int) {
            let descriptor = try await response(server.appendingPathComponent("new"))
            guard let port = descriptor["port"] else { throw CocoaError(.coderInvalidValue) }
            let collected = try await web.callAsyncJavaScript("""
                const peer = new RTCPeerConnection({iceServers:[{urls: 'stun:127.0.0.1:' + port}]});
                const candidates = [];
                peer.onicecandidate = event => { if (event.candidate) candidates.push(event.candidate.toJSON()); };
                peer.createDataChannel('owned-rtc-fixture');
                try {
                    await peer.setLocalDescription(await peer.createOffer());
                    await new Promise(resolve => {
                        if (peer.iceGatheringState === 'complete') { resolve(); return; }
                        const timer = setTimeout(resolve, 3500);
                        peer.onicegatheringstatechange = () => {
                            if (peer.iceGatheringState === 'complete') { clearTimeout(timer); resolve(); }
                        };
                    });
                    return candidates.map(item => {
                        const fields = item.candidate.split(' ');
                        return {protocol: fields[2].toLowerCase(), type: fields[7]};
                    });
                } finally { peer.close(); }
                """, arguments: ["port": port], in: nil, contentWorld: .page) as? [[String: String]] ?? []
            var counter = URLComponents(url: server.appendingPathComponent("count"), resolvingAgainstBaseURL: false)!
            counter.queryItems = [URLQueryItem(name: "port", value: String(port))]
            let counts = try await response(counter.url!)
            guard let requests = counts["requests"] else { throw CocoaError(.coderInvalidValue) }
            let hosts = collected.filter { $0["type"] == "host" }.count
            let reflexive = collected.filter { $0["type"] == "srflx" }.count
            let udp = collected.filter { $0["protocol"] == "udp" }.count
            print("RTC_POLICY \(phase) requests=\(requests) host=\(hosts) srflx=\(reflexive) udp=\(udp)")
            return (requests, hosts, reflexive, udp)
        }

        let control = try await page(WKWebViewConfiguration())
        let baseline = try await gather("baseline", web: control)
        guard baseline.requests > 0, baseline.reflexive > 0, baseline.udp > 0 else { return false }
        let getter = NSSelectorFromString("_webRTCIPHandlingPolicy")
        let setter = NSSelectorFromString("_setWebRTCIPHandlingPolicy:")
        guard let getMethod = class_getInstanceMethod(WKPreferences.self, getter),
              let setMethod = class_getInstanceMethod(WKPreferences.self, setter) else {
            print("RTC_POLICY_API false")
            return false
        }
        typealias GetPolicy = @convention(c) (AnyObject, Selector) -> Unmanaged<NSString>?
        typealias SetPolicy = @convention(c) (AnyObject, Selector, NSString) -> Void
        let get = unsafeBitCast(method_getImplementation(getMethod), to: GetPolicy.self)
        let set = unsafeBitCast(method_getImplementation(setMethod), to: SetPolicy.self)
        let configuration = WKWebViewConfiguration()
        let preferences = configuration.preferences
        let initialValue = get(preferences, getter)?.takeUnretainedValue() as String? == "default"
        set(preferences, setter, "disable_non_proxied_udp")
        let changed = try await page(configuration)
        let disabled = try await gather("udp-disabled", web: changed)
        let isolated = try await gather("separate-page", web: control)
        let request = server.appendingPathComponent("page")
        changed.load(URLRequest(url: request))
        for _ in 0..<200 where changed.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let browsing = try await changed.evaluateJavaScript("document.title") as? String == "Owned RTC policy"
        set(preferences, setter, "default_public_interface_only")
        let publicOnly = try await gather("public-only", web: changed)
        set(preferences, setter, "default_public_and_private_interfaces")
        let publicAndPrivate = try await gather("public-and-private", web: changed)
        set(preferences, setter, "default")
        let restored = try await gather("restored", web: changed)
        set(preferences, setter, "invalid-policy")
        let rejectedInvalid = get(preferences, getter)?.takeUnretainedValue() as String? == "default"
        return initialValue && rejectedInvalid && browsing &&
            disabled.requests == 0 && disabled.udp == 0 &&
            isolated.requests > 0 && isolated.reflexive > 0 &&
            publicOnly.requests > 0 && publicOnly.reflexive > 0 && publicOnly.host == 0 &&
            publicAndPrivate.requests > 0 && publicAndPrivate.reflexive > 0 &&
            restored.requests > 0 && restored.reflexive > 0
    }
}
