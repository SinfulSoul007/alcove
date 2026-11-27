import Foundation

private final class OwnedChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@main struct ExtensionAuthenticationCallbackChecks {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        var failures = 0
        let methods = [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault]
        for method in methods {
            let result: (Int, Bool, Bool) = await withCheckedContinuation { continuation in
                Task.detached {
                    let space = URLProtectionSpace(host: "owned.invalid", port: 443, protocol: "https", realm: "Owned callback fixture", authenticationMethod: method)
                    let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: OwnedChallengeSender())
                    ExtensionAuthenticationCallback.complete(challenge) { disposition, credential in
                        continuation.resume(returning: (disposition.rawValue, credential == nil, Thread.isMainThread))
                    }
                }
            }
            let expected: URLSession.AuthChallengeDisposition = method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
            var passed = result.0 == expected.rawValue && result.1
            #if ALCOVE_AUTH_CALLBACK_MAIN_ACTOR
            passed = passed && result.2
            #endif
            print("\(passed ? "PASS" : "FAIL"): Authentication callback preserves disposition, empty credentials and required isolation for \(method)")
            if !passed { failures += 1 }
        }
        print("Authentication callback checks: 6 checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
