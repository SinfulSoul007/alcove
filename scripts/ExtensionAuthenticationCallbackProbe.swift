import Foundation

/// Compile against the actual SDK: Foundation changed these callback annotations.
final class ExtensionAuthenticationCallbackProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping ExtensionAuthenticationCompletion) {
        ExtensionAuthenticationCallback.complete(challenge, using: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping ExtensionAuthenticationCompletion) {
        ExtensionAuthenticationCallback.complete(challenge, using: completionHandler)
    }
}
