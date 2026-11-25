import Foundation

/// Used only by a separately compiled, sandboxed engine qualification fixture.
enum QualificationJournalPath {
    private static func validate(_ suffix:String,_ runID:String?,_ bundleIdentifier:String?) throws -> String {
        guard bundleIdentifier=="dev.openbrowser.mac.engine-qualification",
              ["owned-stores.json","owned-extension-controllers.json"].contains(suffix),
              let runID,let uuid=UUID(uuidString:runID),uuid.uuidString==runID,
              runID != "00000000-0000-0000-0000-000000000000" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return runID
    }
    static func resolve(suffix:String) throws -> URL {
        let run=ProcessInfo.processInfo.environment["ALCOVE_QUALIFICATION_RUN_ID"]
        let bundle=Bundle.main.bundleIdentifier
        _=try validate(suffix,run,bundle)
        let caches=try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        return try resolve(suffix:suffix,runID:run,bundleIdentifier:bundle,cachesDirectory:caches)
    }
    static func resolve(suffix:String,runID:String?,bundleIdentifier:String?,cachesDirectory:URL) throws -> URL {
        let run=try validate(suffix,runID,bundleIdentifier)
        guard cachesDirectory.isFileURL,cachesDirectory.path.hasPrefix("/") else {throw CocoaError(.fileWriteInvalidFileName)}
        let manager=FileManager.default
        var directory=cachesDirectory
        for component in ["AlcoveEngineQualification",run] {
            directory.appendPathComponent(component,isDirectory:true)
            if let attributes=try? manager.attributesOfItem(atPath:directory.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw CocoaError(.fileWriteInvalidFileName)}
            } else {
                try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }
            try manager.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        }
        let journal=directory.appendingPathComponent(suffix)
        if let attributes=try? manager.attributesOfItem(atPath:journal.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {throw CocoaError(.fileWriteInvalidFileName)}
        }
        return journal
    }
}
