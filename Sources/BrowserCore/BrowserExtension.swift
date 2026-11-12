import Foundation
import CryptoKit

public enum ExtensionSourceKind:String,Codable,Sendable { case folder, zip, crx3, webStore }

/// Saved approvals are bound to both the account and the exact code revision.
/// Session-only private grants belong to the native host and are never encoded here.
public struct ExtensionGrantSet:Codable,Equatable,Sendable {
    public var profileID:UUID
    public var packageDigest:String
    public var recordID:UUID?
    public var controllerID:UUID?
    public var permissions:[String]
    public var hostPatterns:[String]
    public var allowPrivate:Bool
    public var deniedPermissions:[String]?
    public var deniedHostPatterns:[String]?
    public init(profileID:UUID,recordID:UUID,controllerID:UUID,packageDigest:String,permissions:[String] = [],hostPatterns:[String] = [],allowPrivate:Bool = false) {
        self.profileID = profileID; self.recordID = recordID; self.controllerID = controllerID; self.packageDigest = packageDigest
        self.permissions = Array(Set(permissions)).sorted(); self.hostPatterns = Array(Set(hostPatterns)).sorted(); self.allowPrivate = allowPrivate
    }
}

public struct BrowserExtensionRecord:Codable,Identifiable,Equatable,Sendable {
    public var id:UUID
    /// Immutable package directory identity; retained when a recovered record must be renamed.
    public var packageID:UUID?
    public var name:String
    public var version:String
    public var summary:String?
    public var manifestVersion:Int
    public var incognito:String?
    public var packageDigest:String
    public var source:ExtensionSourceKind
    public var storeID:String?
    public var signerID:String?
    public var publisherVerified:Bool?
    public var requestedPermissions:[String]
    public var optionalPermissions:[String]
    public var hostPermissions:[String]
    public var optionalHostPermissions:[String]
    public var grants:ExtensionGrantSet?
    public var enabled:Bool
    public var pendingRemoval:Bool?
    public init(id:UUID = UUID(),name:String,version:String,manifestVersion:Int,packageDigest:String,source:ExtensionSourceKind,
                requestedPermissions:[String] = [],optionalPermissions:[String] = [],hostPermissions:[String] = [],optionalHostPermissions:[String] = []) {
        self.id = id; self.name = name; self.version = version; self.manifestVersion = manifestVersion; self.packageDigest = packageDigest; self.source = source
        self.requestedPermissions = requestedPermissions; self.optionalPermissions = optionalPermissions
        self.hostPermissions = hostPermissions; self.optionalHostPermissions = optionalHostPermissions; enabled = false
    }
    public var runtimeIdentifier:String {
        if source == .webStore, let storeID, Self.validExternalID(storeID), storeID == signerID, publisherVerified == true { return storeID }
        if source == .crx3, let signerID, Self.validExternalID(signerID) { return signerID }
        let hash = SHA256.hash(data:Data(id.uuidString.utf8))
        return hash.prefix(16).map { byte in String(UnicodeScalar(97 + UInt32(byte >> 4))!) + String(UnicodeScalar(97 + UInt32(byte & 15))!) }.joined()
    }
    public static func validExternalID(_ value:String) -> Bool { value.utf8.count == 32 && value.utf8.allSatisfy { 97...112 ~= $0 } }
    public static func validDigest(_ value:String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    public var hasValidIdentity:Bool {
        guard Self.validDigest(packageDigest), id != BrowserProfile.zeroID, packageID != BrowserProfile.zeroID else { return false }
        switch source {
        case .folder,.zip: return storeID == nil && signerID == nil && publisherVerified != true
        case .crx3: return storeID == nil && signerID.map(Self.validExternalID) == true
        case .webStore: return storeID.map(Self.validExternalID) == true && storeID == signerID && publisherVerified == true
        }
    }
    /// The current private bridge shares one approved spanning context. A package
    /// requesting a separate private context must not silently receive that model.
    public var supportsPrivateAccess:Bool {incognito == nil || incognito == "spanning"}
    public mutating func revokeApproval() { grants = nil; enabled = false }
}
