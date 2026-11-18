import Foundation
import ObjectiveC
import Security
import WebKit

private final class PredictionFixtureTrust: NSObject, WKNavigationDelegate, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    let port: Int

    init(certificate: Data, port: Int) {
        self.certificate = certificate
        self.port = port
    }

    private func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", space.port == port,
              let trust = space.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SecCertificateCopyData(leaf) as Data == certificate else { return nil }
        return URLCredential(trust: trust)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let credential = credential(for: challenge)
        completionHandler(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let credential = credential(for: challenge)
        completionHandler(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
    }
}

extension SystemWebKitExtensionProbe {
    @MainActor static func runNetworkPrediction(server: URL) async throws -> Bool {
        guard let port = server.port,
              let certificatePath = ProcessInfo.processInfo.environment["ALCOVE_PREDICTION_TLS_CERT_DER"] else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let certificate = try Data(contentsOf: URL(fileURLWithPath: certificatePath))
        let trust = PredictionFixtureTrust(certificate: certificate, port: port)
        let featuresSelector = NSSelectorFromString("_features")
        let setFeatureSelector = NSSelectorFromString("_setEnabled:forFeature:")
        let readFeatureSelector = NSSelectorFromString("_isEnabledForFeature:")
        guard let featuresMethod = class_getClassMethod(WKPreferences.self, featuresSelector),
              let setFeatureMethod = class_getInstanceMethod(WKPreferences.self, setFeatureSelector),
              let readFeatureMethod = class_getInstanceMethod(WKPreferences.self, readFeatureSelector) else {
            throw CocoaError(.featureUnsupported)
        }
        typealias ListFeatures = @convention(c) (AnyClass, Selector) -> Unmanaged<NSArray>?
        typealias SetFeature = @convention(c) (AnyObject, Selector, ObjCBool, AnyObject) -> Void
        typealias ReadFeature = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
        let features = unsafeBitCast(method_getImplementation(featuresMethod), to: ListFeatures.self)
        let setFeature = unsafeBitCast(method_getImplementation(setFeatureMethod), to: SetFeature.self)
        let readFeature = unsafeBitCast(method_getImplementation(readFeatureMethod), to: ReadFeature.self)
        let names = Set(["LinkPrefetchEnabled", "SpeculationRulesPrefetchEnabled"])
        let featureKey = NSSelectorFromString("key")
        let selection = (features(WKPreferences.self, featuresSelector)?.takeUnretainedValue() as? [NSObject] ?? [])
            .filter { $0.responds(to: featureKey) && ($0.perform(featureKey)?.takeUnretainedValue() as? String).map(names.contains) == true }
        guard selection.count == names.count else { throw CocoaError(.featureUnsupported) }
        func configuration() throws -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            for feature in selection {
                setFeature(configuration.preferences, setFeatureSelector, ObjCBool(true), feature)
                guard readFeature(configuration.preferences, readFeatureSelector, feature).boolValue else {
                    throw CocoaError(.featureUnsupported)
                }
            }
            return configuration
        }

        let countsSession = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { countsSession.invalidateAndCancel() }
        func count(_ address: URL) async throws -> Int {
            var counter = URLComponents(url: server.appendingPathComponent("__request_count"), resolvingAgainstBaseURL: false)!
            counter.queryItems = [URLQueryItem(name: "path", value: address.path)]
            let (body, response) = try await countsSession.data(from: counter.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let count = Int(String(decoding: body, as: UTF8.self)) else { throw CocoaError(.coderInvalidValue) }
            return count
        }
        func exercise(_ phase: String, web: WKWebView, expectsPrefetch: Bool) async throws -> (Int, Int, Int) {
            let directory = server.appendingPathComponent("network-prediction/\(phase)-\(UUID().uuidString)")
            let document = directory.appendingPathComponent("source")
            let link = directory.appendingPathComponent("link-target")
            let rule = directory.appendingPathComponent("rule-target")
            let ordinary = directory.appendingPathComponent("ordinary.js")
            web.load(URLRequest(url: document))
            for _ in 0..<450 where web.url != document || web.isLoading {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard web.url == document, !web.isLoading,
                  try await web.evaluateJavaScript("window.ordinaryScriptLoaded === true") as? Bool == true else {
                throw CocoaError(.coderInvalidValue)
            }
            if expectsPrefetch {
                for _ in 0..<60 {
                    let linkCount = try await count(link)
                    let ruleCount = try await count(rule)
                    if linkCount > 0 && ruleCount > 0 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else {
                try await Task.sleep(for: .seconds(1))
            }
            let result = try await (count(link), count(rule), count(ordinary))
            print("NETWORK_PREDICTION \(phase) link=\(result.0) rule=\(result.1) ordinary=\(result.2)")
            return result
        }

        let control = WKWebView(frame: .zero, configuration: try configuration())
        control.navigationDelegate = trust
        let baseline = try await exercise("baseline", web: control, expectsPrefetch: true)
        guard baseline == (1, 1, 1) else {
            print("NETWORK_PREDICTION_BASELINE incomplete")
            return false
        }
        let changedConfiguration = try configuration()
        let preferences = changedConfiguration.preferences
        let readSelector = NSSelectorFromString("_networkPredictionEnabled")
        let setSelector = NSSelectorFromString("_setNetworkPredictionEnabled:")
        guard let readMethod = class_getInstanceMethod(WKPreferences.self, readSelector),
              let setMethod = class_getInstanceMethod(WKPreferences.self, setSelector) else {
            print("NETWORK_PREDICTION_API false")
            return false
        }
        typealias ReadPrediction = @convention(c) (AnyObject, Selector) -> ObjCBool
        typealias SetPrediction = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let read = unsafeBitCast(method_getImplementation(readMethod), to: ReadPrediction.self)
        let set = unsafeBitCast(method_getImplementation(setMethod), to: SetPrediction.self)
        let defaultValue = read(preferences, readSelector).boolValue
        set(preferences, setSelector, ObjCBool(false))
        let disabledValue = read(preferences, readSelector).boolValue
        let changed = WKWebView(frame: .zero, configuration: changedConfiguration)
        changed.navigationDelegate = trust
        let disabled = try await exercise("disabled", web: changed, expectsPrefetch: false)
        let separate = try await exercise("separate-page", web: control, expectsPrefetch: true)
        set(preferences, setSelector, ObjCBool(true))
        let restoredValue = read(preferences, readSelector).boolValue
        let restored = try await exercise("restored", web: changed, expectsPrefetch: true)
        return defaultValue && !disabledValue && restoredValue &&
            disabled == (0, 0, 1) && separate == baseline && restored == baseline
    }
}
