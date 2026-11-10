import Foundation
import JavaScriptCore
import BrowserCore

enum BoostScriptError: LocalizedError {
    case syntax(String), unavailable
    var errorDescription: String? {
        switch self {
        case .syntax(let detail): return "JavaScript could not be compiled: \(detail)"
        case .unavailable: return "JavaScript validation is unavailable. Your previous Boost was kept."
        }
    }
}

@MainActor enum BoostScript {
    /// Never use native functionBody interpolation as the user-code syntax boundary.
    /// Compile a standalone body first, then keep all its declarations inside an inner scope.
    static func validatedBody(_ code: String) throws -> String {
        guard code.utf8.count <= 32768 else { throw BoostError.codeTooLarge }
        guard let context = JSContext(),
              let constructor = context.evaluateScript("Object.getPrototypeOf(async function(){}).constructor"),
              context.exception == nil else { throw BoostScriptError.unavailable }
        let compiled = constructor.construct(withArguments: [code])
        guard context.exception == nil, let compiled, !compiled.isUndefined else {
            throw BoostScriptError.syntax(String((context.exception?.toString() ?? "Invalid async function body").prefix(300)))
        }
        // The nonce is an immutable page-global installed at document start by the runtime.
        // A separate isolated-world nonce authenticates native bridge messages.
        return """
        if (typeof __alcoveHost !== 'string' || typeof __alcoveNonce !== 'string' ||
            (location.protocol !== 'https:' && location.protocol !== 'http:') ||
            (location.hostname !== __alcoveHost && location.hostname !== __alcoveHost + '.') ||
            typeof __alcoveBoostPageNonce_v1 !== 'string' || __alcoveBoostPageNonce_v1 !== __alcoveNonce) return false;
        return await (async function(){
        \(code)
        })();
        """
    }
}
