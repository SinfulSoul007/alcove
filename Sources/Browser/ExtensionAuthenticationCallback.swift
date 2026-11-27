import Foundation

#if ALCOVE_AUTH_CALLBACK_MAIN_ACTOR
typealias ExtensionAuthenticationCompletion = @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
#else
typealias ExtensionAuthenticationCompletion = @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
#endif

enum ExtensionAuthenticationCallback {
    static func complete(_ challenge: URLAuthenticationChallenge, using completion: @escaping ExtensionAuthenticationCompletion) {
        let disposition: URLSession.AuthChallengeDisposition = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
        #if ALCOVE_AUTH_CALLBACK_MAIN_ACTOR
        Task { @MainActor in completion(disposition, nil) }
        #else
        completion(disposition, nil)
        #endif
    }
}
