import Foundation
import WebKit
import BrowserCore

/// WebKit before the 624.1.16 branch omits existing DNR rules when a new
/// user-content controller appears (WebKit 301720 / 302465@main). Normal
/// profiles can reuse their background controller; private sessions must
/// keep separate controllers and therefore require the fixed engine.
enum BrowserExtensionCompatibility {
    @MainActor static var webKitBuild:String? {Bundle(for:WKWebView.self).infoDictionary?["CFBundleVersion"] as? String}
    static func supportsPrivateRequestBlocking(webKitBuild:String?) -> Bool {
        guard let webKitBuild,webKitBuild.utf8.count <= 128 else {return false}
        let parts=webKitBuild.split(separator:".",omittingEmptySubsequences:false)
        guard (3...8).contains(parts.count),parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy{48...57 ~= $0}}) else {return false}
        let numbers=parts.compactMap{Int($0)}
        guard numbers.count==parts.count else {return false}
        // Apple's platform prefix differs (20624 / 21624); the engine is 624.
        return ![numbers[0] % 1000,numbers[1],numbers[2]].lexicographicallyPrecedes([624,1,16])
    }
    @MainActor static var supportsPrivateRequestBlocking:Bool {supportsPrivateRequestBlocking(webKitBuild:webKitBuild)}
    static func privateAccessIssue(permissions:[String],webKitBuild:String?) -> String? {
        guard permissions.contains(where:{$0=="declarativeNetRequest" || $0=="declarativeNetRequestWithHostAccess"}),
              !supportsPrivateRequestBlocking(webKitBuild:webKitBuild) else {return nil}
        return ExtensionHostError.unsupportedPrivateRequestBlocking.localizedDescription
    }
    @MainActor static func privateAccessIssue(for record:BrowserExtensionRecord) -> String? {
        privateAccessIssue(permissions:record.requestedPermissions+record.optionalPermissions+(record.grants?.permissions ?? []),webKitBuild:webKitBuild)
    }
    @MainActor static func requirePrivateAccess(_ records:[BrowserExtensionRecord]) throws {
        if records.contains(where:{$0.enabled && $0.pendingRemoval != true && $0.grants?.allowPrivate==true && privateAccessIssue(for:$0) != nil}) {
            throw ExtensionHostError.unsupportedPrivateRequestBlocking
        }
    }
}
