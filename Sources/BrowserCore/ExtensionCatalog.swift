import Foundation

public enum ExtensionCatalog {
    public static let unavailablePermissions:Set<String> = ["nativeMessaging","debugger","sidePanel"]
    /// Merge immutable revisions once. Different approval copies can only reduce one another.
    public static func merged(_ current:[BrowserExtensionRecord],_ incoming:[BrowserExtensionRecord]) -> [BrowserExtensionRecord] {
        var result:[BrowserExtensionRecord] = []
        for original in current + incoming {
            if let index = result.firstIndex(where:{ sameRevision($0,original) }) {
                var saved = result[index]
                if immutableMetadata(saved) != immutableMetadata(original) { saved.revokeApproval() }
                else {
                    saved.enabled = saved.enabled && original.enabled
                    saved.grants = intersect(saved.grants,original.grants)
                }
                saved.pendingRemoval = saved.pendingRemoval == true || original.pendingRemoval == true
                if saved.pendingRemoval == true || saved.grants == nil { saved.revokeApproval() }
                result[index] = saved
                continue
            }
            var record = original
            if record.id == BrowserProfile.zeroID || result.contains(where:{$0.id == record.id}) {
                record.packageID = record.packageID ?? record.id
                record.id = UUID(); record.revokeApproval()
            }
            result.append(record)
        }
        // Multiple distinct installations cannot share a signed origin and its persistent storage.
        var signedOrigins:[String:Int] = [:]
        for index in result.indices where result[index].source == .crx3 || result[index].source == .webStore {
            let origin = result[index].runtimeIdentifier
            if let previous = signedOrigins[origin] { result[previous].revokeApproval(); result[index].revokeApproval() }
            else { signedOrigins[origin] = index }
        }
        return result
    }
    public static func repaired(_ records:[BrowserExtensionRecord],profileID:UUID,controllerID:UUID,paused:Bool = false) -> [BrowserExtensionRecord] {
        merged(records,[]).map { original in
            var record = original
            record.requestedPermissions = unique(record.requestedPermissions)
            record.optionalPermissions = unique(record.optionalPermissions)
            record.hostPermissions = unique(record.hostPermissions)
            record.optionalHostPermissions = unique(record.optionalHostPermissions)
            let declaredHosts = (record.hostPermissions + record.optionalHostPermissions).compactMap(ExtensionMatchPattern.init)
            guard !paused, record.pendingRemoval != true, record.hasValidIdentity,
                  record.manifestVersion == 2 || record.manifestVersion == 3,
                  let grant = record.grants, grant.profileID == profileID, grant.recordID == record.id,
                  grant.controllerID == controllerID, grant.packageDigest == record.packageDigest,
                  !grant.allowPrivate || record.supportsPrivateAccess,
                  Set(grant.permissions).isDisjoint(with:unavailablePermissions),
                  Set(grant.permissions).isSubset(of:Set(record.requestedPermissions + record.optionalPermissions)),
                  grant.hostPatterns.allSatisfy({ granted in
                      guard let pattern = ExtensionMatchPattern(granted) else { return false }
                      return declaredHosts.contains { $0.covers(pattern) }
                  }) else { record.revokeApproval(); return record }
            var normalized = grant
            normalized.permissions = Set(grant.permissions).subtracting(grant.deniedPermissions ?? []).sorted()
            normalized.hostPatterns = unique(grant.hostPatterns)
            normalized.deniedPermissions = grant.deniedPermissions.map(unique)
            normalized.deniedHostPatterns = grant.deniedHostPatterns.map(unique)
            record.grants = normalized
            return record
        }
    }
    private static func unique(_ values:[String]) -> [String] { Array(Set(values)).sorted() }
    private static func sameRevision(_ left:BrowserExtensionRecord,_ right:BrowserExtensionRecord) -> Bool {
        (left.packageID ?? left.id) == (right.packageID ?? right.id) && left.packageDigest == right.packageDigest
            && left.source == right.source && left.storeID == right.storeID && left.signerID == right.signerID
    }
    private static func immutableMetadata(_ record:BrowserExtensionRecord) -> BrowserExtensionRecord {
        var value = record; value.id = value.packageID ?? value.id; value.packageID = nil
        value.grants = nil; value.enabled = false; value.pendingRemoval = nil
        return value
    }
    private static func intersect(_ left:ExtensionGrantSet?,_ right:ExtensionGrantSet?) -> ExtensionGrantSet? {
        guard var result = left, let right, result.profileID == right.profileID,
              result.recordID == right.recordID, result.controllerID == right.controllerID,
              result.packageDigest == right.packageDigest else { return nil }
        result.permissions = Set(result.permissions).intersection(right.permissions).sorted()
        let first = result.hostPatterns.compactMap(ExtensionMatchPattern.init), second = right.hostPatterns.compactMap(ExtensionMatchPattern.init)
        result.hostPatterns = unique(first.filter { candidate in second.contains { $0.covers(candidate) } }.map(\.string)
            + second.filter { candidate in first.contains { $0.covers(candidate) } }.map(\.string))
        result.allowPrivate = result.allowPrivate && right.allowPrivate
        result.deniedPermissions = unique((result.deniedPermissions ?? []) + (right.deniedPermissions ?? []))
        result.deniedHostPatterns = unique((result.deniedHostPatterns ?? []) + (right.deniedHostPatterns ?? []))
        return result
    }
}
