import Foundation

public enum ExtensionStoreError:LocalizedError {
    case invalidLocation,invalidVersion,invalidMetadata
    public var errorDescription:String? {
        switch self {
        case .invalidLocation:return "Paste a Chrome Web Store link or its 32-letter extension ID."
        case .invalidVersion:return "Google’s package selection version was invalid. Try again later."
        case .invalidMetadata:return "Google’s version service returned an unexpected response. Try again later."
        }
    }
}

/// Input links identify a package; their tracking queries are never requested.
public struct ExtensionStoreLocation:Equatable,Sendable {
    public let id:String
    public var url:URL {URL(string:"https://chromewebstore.google.com/detail/"+id)!}
    public init(_ input:String) throws {
        let value = input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.utf8.count <= 4096 else {throw ExtensionStoreError.invalidLocation}
        if BrowserExtensionRecord.validExternalID(value) {id = value;return}
        guard !value.contains("\\"),let parts = URLComponents(string:value),parts.scheme?.lowercased() == "https",
              parts.user == nil,parts.password == nil,parts.port == nil,parts.fragment == nil,
              let host = parts.host?.lowercased(),parts.percentEncodedPath.hasPrefix("/") else {throw ExtensionStoreError.invalidLocation}
        let path = parts.percentEncodedPath.dropFirst().split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        let suffix:[String]
        switch host {
        case "chromewebstore.google.com":
            guard path.first == "detail" else {throw ExtensionStoreError.invalidLocation};suffix = Array(path.dropFirst())
        case "chrome.google.com":
            guard Array(path.prefix(2)) == ["webstore","detail"] else {throw ExtensionStoreError.invalidLocation};suffix = Array(path.dropFirst(2))
        default:throw ExtensionStoreError.invalidLocation
        }
        guard (1...2).contains(suffix.count),let identifier = suffix.last,BrowserExtensionRecord.validExternalID(identifier),
              suffix.allSatisfy({part in
                  guard let decoded = part.removingPercentEncoding else {return false}
                  return !decoded.isEmpty && decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\") && !decoded.contains("\0")
              }) else {throw ExtensionStoreError.invalidLocation}
        id = identifier
    }
}

public enum ExtensionStorePlatform:String,Sendable {
    case arm64 = "mac_arm64",x86_64 = "mac"
    public static var current:Self {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}
public enum ExtensionStoreResource:Sendable {case metadata(ExtensionStorePlatform),package}

/// Exact service scopes are checked again by the streaming transport at each hop.
public enum ExtensionStoreCatalog {
    public static func versionURL(platform:ExtensionStorePlatform) -> URL {
        URL(string:"https://versionhistory.googleapis.com/v1/chrome/platforms/\(platform.rawValue)/channels/stable/versions?order_by=version%20desc&page_size=1")!
    }
    private static func validVersion(_ version:String) -> Bool {
        let fields = version.split(separator:".",omittingEmptySubsequences:false)
        return fields.count == 4 && fields.allSatisfy{!$0.isEmpty && $0.utf8.count <= 10 && $0.utf8.allSatisfy{48...57 ~= $0} && UInt32($0) != nil}
    }
    public static func selectionVersion(from data:Data,platform:ExtensionStorePlatform) throws -> String {
        guard data.count <= 1_048_576,let response = try? JSONDecoder().decode(VersionResponse.self,from:data),response.versions.count == 1,
              let entry = response.versions.first,validVersion(entry.version),
              entry.name == "chrome/platforms/\(platform.rawValue)/channels/stable/versions/\(entry.version)" else {throw ExtensionStoreError.invalidMetadata}
        return entry.version
    }
    public static func downloadURL(id:String,version:String) throws -> URL {
        guard BrowserExtensionRecord.validExternalID(id) else {throw ExtensionStoreError.invalidLocation}
        guard validVersion(version) else {throw ExtensionStoreError.invalidVersion}
        var components = URLComponents(string:"https://clients2.google.com/service/update2/crx")!
        components.queryItems = [URLQueryItem(name:"response",value:"redirect"),URLQueryItem(name:"prodversion",value:version),URLQueryItem(name:"acceptformat",value:"crx3"),URLQueryItem(name:"x",value:"id="+id+"&uc")]
        return components.url!
    }
    public static func allows(_ url:URL,for resource:ExtensionStoreResource) -> Bool {
        guard let components = URLComponents(url:url,resolvingAgainstBaseURL:false),components.scheme?.lowercased() == "https",
              components.user == nil,components.password == nil,components.fragment == nil,
              components.port == nil || components.port == 443 else {return false}
        switch resource {
        case .metadata(let platform):return url == versionURL(platform:platform)
        case .package:
            let path = components.percentEncodedPath
            guard !path.contains("%"),!path.contains("\\"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0 == "." || $0 == ".."}) else {return false}
            switch components.host?.lowercased() {
            case "clients2.google.com":return path == "/service/update2/crx"
            case "clients2.googleusercontent.com":return path.hasPrefix("/crx/blobs/") && path.count > "/crx/blobs/".count
            default:return false
            }
        }
    }
    private struct VersionResponse:Decodable {let versions:[Entry]}
    private struct Entry:Decodable {let name:String,version:String}
}
