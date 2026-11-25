import Foundation

@main struct QualificationJournalChecks {
    static func main() throws {
        let manager=FileManager.default
        let root=manager.temporaryDirectory.appendingPathComponent("alcove-journal-check-"+UUID().uuidString)
        try manager.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? manager.removeItem(at:root)}
        let cache=root.appendingPathComponent("Caches")
        let run="A49BE413-1A81-4F17-BA22-91935C4F3350"
        let bundle="dev.openbrowser.mac.engine-qualification"
        var checks=0
        func check(_ value:Bool,_ name:String) throws {
            guard value else {throw NSError(domain:"QualificationJournalChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name])}
            checks += 1;print("PASS: "+name)
        }
        func path(_ suffix:String,_ id:String?=run,_ identifier:String?=bundle) throws -> URL {
            try QualificationJournalPath.resolve(suffix:suffix,runID:id,bundleIdentifier:identifier,cachesDirectory:cache)
        }
        for bad:String? in [nil,"",run.lowercased(),"../outside","00000000-0000-0000-0000-000000000000"] {
            do {_=try path("owned-stores.json",bad);try check(false,"Invalid run identity must fail")}
            catch let error as CocoaError {try check(error.code == .fileWriteInvalidFileName,"Invalid run identity is rejected")}
        }
        try check(!manager.fileExists(atPath:cache.path),"Rejected identities do not create journal directories")
        do {_=try path("owned-stores.json",run,"dev.openbrowser.mac");try check(false,"Production bundle must be rejected")}
        catch let error as CocoaError {try check(error.code == .fileWriteInvalidFileName,"Journal override is restricted to the qualification app")}
        do {_=try path("../outside");try check(false,"Unknown journal suffix must fail")}
        catch let error as CocoaError {try check(error.code == .fileWriteInvalidFileName,"Journal suffix cannot escape its owned directory")}
        let first=try path("owned-stores.json")
        try check(first.path==cache.appendingPathComponent("AlcoveEngineQualification/"+run+"/owned-stores.json").path,
                  "A run uses a deterministic writable-cache journal")
        try Data("owned".utf8).write(to:first,options:.atomic)
        try check(try path("owned-stores.json")==first,"Recovery resolves the same run journal")
        let other=try path("owned-stores.json","31DE64C4-49BB-45C7-A791-FD98E05E2AF4")
        try check(other != first && (try String(contentsOf:first,encoding:.utf8))=="owned","Another run preserves the first run journal")
        let controller=try path("owned-extension-controllers.json")
        try check(controller.deletingLastPathComponent()==first.deletingLastPathComponent() && controller != first,
                  "Website and controller ownership use separate files in the same run")
        let attributes=try manager.attributesOfItem(atPath:first.deletingLastPathComponent().path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue==0o700,"Run directories are owner-only")
        try manager.createSymbolicLink(at:controller,withDestinationURL:first)
        do {_=try path("owned-extension-controllers.json");try check(false,"Journal symlink must fail")}
        catch let error as CocoaError {try check(error.code == .fileWriteInvalidFileName,"Existing journal symlinks are rejected")}
        print("QUALIFICATION_JOURNAL_CHECKS \(checks) FAILURES 0")
    }
}
