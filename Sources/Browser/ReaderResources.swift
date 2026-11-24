import Foundation

/// Both packaged apps and standalone native fixtures carry the same pinned files.
enum ReaderResources {
    static func extractionScript() throws -> String {
        #if SWIFT_PACKAGE
        let root = Bundle.module.resourceURL?.appendingPathComponent("ReaderAssets")
        #else
        let root = Bundle.main.resourceURL?.appendingPathComponent("ReaderAssets")
        #endif
        guard let root else { throw ReaderFailure.resources }
        return try extractionScript(at: root)
    }
    static func extractionScript(at root: URL) throws -> String {
        do {
            let vendor = try String(contentsOf: root.appendingPathComponent("Readability.js"), encoding: .utf8)
            let wrapper = try String(contentsOf: root.appendingPathComponent("Extract.js"), encoding: .utf8)
            guard !vendor.isEmpty, !wrapper.isEmpty, vendor.utf8.count < 250000, wrapper.utf8.count < 20000 else { throw ReaderFailure.resources }
            return vendor + "\n" + wrapper
        } catch { throw ReaderFailure.resources }
    }
}

enum ReaderFailure: Error {
    case resources, unsupported, unavailable, tooLarge, failed
    var message: String {
        switch self {
        case .resources: return "Reader resources are missing or unreadable. Reinstall this build to use Reader."
        case .unsupported: return "Reader supports HTML articles on HTTP and HTTPS webpages."
        case .unavailable: return "No readable article was found on this page. Try opening the full article first."
        case .tooLarge: return "This page is too large or complex for Reader."
        case .failed: return "Reader could not prepare this article. Try again after the page finishes loading."
        }
    }
}
