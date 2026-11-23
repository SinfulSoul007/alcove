import Foundation
import CryptoKit
import BrowserCore

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var mainThread = false
    func record() {lock.lock();calls += 1;mainThread = Thread.isMainThread;lock.unlock()}
    var snapshot:(Int,Bool) {lock.lock();defer{lock.unlock()};return(calls,mainThread)}
}

@main struct WebsiteProtectionServiceChecks {
    enum Failure:Error {case fixture,checks(Int)}
    @MainActor static func run() async throws {
        var checks=0,failures=0
        func check(_ value:Bool,_ label:String){checks += 1;print("\(value ? "PASS":"FAIL"): \(label)");if !value {failures += 1}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("alcove-protection-service-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        guard let bundled=Bundle.main.resourceURL?.appendingPathComponent("WebsiteProtection") else {throw Failure.fixture}
        let license=try Data(contentsOf:bundled.appendingPathComponent("LICENSE.PhishDestroy.txt"))
        let rows=Data("listed.alcove.example\r\n".utf8)
        let metadata=try JSONSerialization.data(withJSONObject:[
            "formatVersion":1,"provider":"PhishDestroy","sourceRevision":String(repeating:"1",count:40),
            "sourceUpdatedAt":"2026-11-01T00:00:00Z","retrievedAt":"2026-11-02T00:00:00Z",
            "sha256":SHA256.hash(data:rows).map{String(format:"%02x",$0)}.joined(),
            "licenseSHA256":SHA256.hash(data:license).map{String(format:"%02x",$0)}.joined(),"domainCount":1
        ])
        func fixture(_ name:String) throws -> URL {
            let directory=root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try rows.write(to:directory.appendingPathComponent("domains.txt"))
            try metadata.write(to:directory.appendingPathComponent("source.json"))
            try license.write(to:directory.appendingPathComponent("LICENSE.PhishDestroy.txt"))
            return directory
        }
        let valid=try fixture("valid")
        let counter=LoadCounter(),gate=DispatchSemaphore(value:0)
        let service=WebsiteProtectionService(loader:{
            counter.record()
            guard gate.wait(timeout:.now()+5) == .success else {throw Failure.fixture}
            return try WebsiteProtectionService.loadCatalog(at:valid)
        })
        if case .loading=service.state {check(true,"A new protection service reports loading")} else {check(false,"A new protection service reports loading")}
        let date=ISO8601DateFormatter().date(from:"2026-12-01T00:00:01Z")!
        let a=Task{@MainActor in await service.assessment(for:URL(string:"https://listed.alcove.example/form?owned=fixture")!,at:date)}
        let b=Task{@MainActor in await service.assessment(for:URL(string:"https://sub.LISTED.ALCOVE.EXAMPLE./")!,at:date)}
        for _ in 0..<250 {if counter.snapshot.0>0 {break};try await Task.sleep(for:.milliseconds(10))}
        check(counter.snapshot.0==1,"Concurrent requests start exactly one real file loader")
        check(!counter.snapshot.1,"Catalog file reading and validation run away from the main thread")
        if case .loading=service.state {check(true,"The main actor remains responsive while the file loader waits")} else {check(false,"The main actor remains responsive while the file loader waits")}
        a.cancel();gate.signal()
        _=await a.value
        let result=await b.value
        if case .listed(let threat,let source,let stale)=result {
            check(threat.host=="sub.listed.alcove.example" && threat.listedHost=="listed.alcove.example","Assessment carries the canonical listed destination")
            check(source.provider=="PhishDestroy" && source.sourceUpdatedAt==ISO8601DateFormatter().date(from:"2026-11-01T00:00:00Z"),"Assessment carries the actual provider and content date")
            check(stale,"Assessment reports stale content independently of retrieval date")
        } else {check(false,"A canceled caller cannot cancel another caller's shared catalog load")}
        if case .ready(let catalog)=service.state {check(catalog.domainCount==1,"Successful validation becomes visible ready state")} else {check(false,"Successful validation becomes visible ready state")}
        let fresh=ISO8601DateFormatter().date(from:"2026-11-15T00:00:00Z")!
        if case .unlisted(_,let stale)=await service.assessment(for:URL(string:"https://listed.alcove.example.safe.example/")!,at:fresh) {
            check(!stale,"A fresh unlisted assessment retains freshness without calling the address safe")
        } else {check(false,"An unrelated suffix remains unlisted")}
        check(counter.snapshot.0==1,"Later assessments reuse the immutable verified catalog")
        let missing=root.appendingPathComponent("missing")
        let missingCount=LoadCounter()
        let missingService=WebsiteProtectionService(loader:{missingCount.record();return try WebsiteProtectionService.loadCatalog(at:missing)})
        if case .unavailable(.missingResources)=await missingService.assessment(for:URL(string:"https://safe.alcove.example/")!) {check(true,"Missing resources report unavailable instead of unlisted")} else {check(false,"Missing resources report unavailable instead of unlisted")}
        _=try fixture("missing")
        if case .unavailable(.missingResources)=await missingService.assessment(for:URL(string:"https://listed.alcove.example/")!) {check(true,"A failed process snapshot cannot silently change into active protection")} else {check(false,"A failed process snapshot cannot silently change into active protection")}
        check(missingCount.snapshot.0==1,"Unavailable state is cached rather than repeatedly reading files")
        for kind in ["edited-data","oversized-metadata","edited-license","directory-resource"] {
            let directory=try fixture(kind)
            switch kind {
            case "edited-data":try Data("other.alcove.example\n".utf8).write(to:directory.appendingPathComponent("domains.txt"))
            case "oversized-metadata":try Data(repeating:32,count:16_385).write(to:directory.appendingPathComponent("source.json"))
            case "edited-license":try Data("owned mismatch".utf8).write(to:directory.appendingPathComponent("LICENSE.PhishDestroy.txt"))
            default:
                let path=directory.appendingPathComponent("domains.txt")
                try FileManager.default.removeItem(at:path)
                try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
            }
            let broken=WebsiteProtectionService(loader:{try WebsiteProtectionService.loadCatalog(at:directory)})
            if case .unavailable(.invalidResources)=await broken.assessment(for:URL(string:"https://safe.alcove.example/")!) {check(true,"Invalid resources are visibly unavailable: "+kind)} else {check(false,"Invalid resources are visibly unavailable: "+kind)}
        }
        let unknown=WebsiteProtectionService(loader:{throw NSError(domain:"OwnedFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"owned-private-marker"])})
        if case .unavailable(let failure)=await unknown.assessment(for:URL(string:"https://safe.alcove.example/")!) {check(!failure.message.contains("owned-private-marker"),"Unexpected file errors do not expose raw implementation details")} else {check(false,"Unexpected loader failure remains unavailable")}
        let defaults=WebsiteProtectionService()
        if case .success(let source)=await defaults.load() {check(source.domainCount>0 && source.metadata.provider=="PhishDestroy","The default service reads the real packaged catalog and license")} else {check(false,"The default service reads the real packaged catalog and license")}
        print("WEBSITE_PROTECTION_SERVICE_CHECKS",checks,"FAILURES",failures)
        if failures>0 {throw Failure.checks(failures)}
    }
    @MainActor static func main() async {setbuf(stdout,nil);do{try await run()}catch{print("WEBSITE_PROTECTION_SERVICE_FAILED",error);exit(1)}}
}
