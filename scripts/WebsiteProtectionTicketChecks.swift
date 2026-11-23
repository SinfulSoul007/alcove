import AppKit
import WebKit
import CryptoKit
import BrowserCore

@main struct WebsiteProtectionTicketChecks {
    enum Failure:Error {case fixture,checks(Int)}
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let data=Data("listed.alcove.example\n".utf8)
        let metadata=try JSONSerialization.data(withJSONObject:["formatVersion":1,"provider":"PhishDestroy","sourceRevision":String(repeating:"1",count:40),"sourceUpdatedAt":"2026-11-01T00:00:00Z","retrievedAt":"2026-11-02T00:00:00Z","sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),"licenseSHA256":String(repeating:"0",count:64),"domainCount":1])
        let catalog=try WebsiteThreatCatalog(domains:data,metadata:metadata)
        let service=WebsiteProtectionService(loader:{catalog})
        _=await service.load()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("alcove-ticket-checks-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=BrowserStore(isPrivate:true,dataRoot:root,websiteProtection:service)
        defer {store.shutdown()}
        let a=store.newTab(),b=store.newTab()
        let webA=store.view(for:a),webB=store.view(for:b)
        let url=URL(string:"https://listed.alcove.example/owned")!
        var checks=0,failures=0
        func check(_ value:Bool,_ name:String){checks+=1;print("\(value ? "PASS":"FAIL"): \(name)");if !value {failures+=1}}
        var first=[Bool]()
        let ticket=store.decideWebsiteProtection(webA,url:url,kind:.navigation(isMainFrame:true)){first.append($0)}
        guard let ticket else {throw Failure.fixture}
        ticket.approve(expectedRevision:ticket.revision)
        check(first.isEmpty,"An unpresented warning cannot approve its captured native decision")
        ticket.cancel();ticket.cancel()
        check(first==[false],"Cancel resolves the captured decision exactly once")
        check(store.websiteProtectionTickets[ticket.id]==nil,"A resolved ticket leaves no pending request")
        var forA=[Bool](),forB=[Bool]()
        let pendingA=store.decideWebsiteProtection(webA,url:url,kind:.navigation(isMainFrame:false)){forA.append($0)}
        let pendingB=store.decideWebsiteProtection(webB,url:url,kind:.navigation(isMainFrame:true)){forB.append($0)}
        guard pendingA != nil,let pendingB else {throw Failure.fixture}
        store.invalidateDocumentIdentity(for:webA)
        check(forA==[false] && forB.isEmpty,"Document replacement cancels only that page's pending decision")
        pendingB.approve(expectedRevision:UUID())
        check(forB.isEmpty,"A stale control revision cannot approve another decision")
        store.discardView(b)
        check(forB==[false],"Closing a page cancels its pending decision")
        let gate=DispatchSemaphore(value:0)
        let delayed=WebsiteProtectionService(loader:{
            guard gate.wait(timeout:.now()+5) == .success else {throw Failure.fixture}
            return catalog
        })
        let slow=BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("slow"),websiteProtection:delayed)
        defer {slow.shutdown()}
        let slowID=slow.newTab(),slowWeb=slow.view(for:slowID)
        var late=[Bool]()
        guard let waiting=slow.decideWebsiteProtection(slowWeb,url:url,kind:.navigation(isMainFrame:true),timeout:.seconds(10),decision:{late.append($0)}) else {throw Failure.fixture}
        waiting.cancel();gate.signal()
        _=await delayed.load()
        await Task.yield()
        check(late==[false],"A late catalog result cannot revive a canceled native request")
        let destination=BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("destination"),websiteProtection:service)
        defer {destination.shutdown()}
        let movingID=store.newTab(),movingWeb=store.view(for:movingID)
        var transferred=[Bool]()
        guard let moving=store.decideWebsiteProtection(movingWeb,url:url,kind:.navigation(isMainFrame:true),decision:{transferred.append($0)}) else {throw Failure.fixture}
        store.update(movingID){$0.url=url.absoluteString;$0.title="Pending destination"}
        guard let retained=store.takeRegisteredView(movingID,transferringTo:destination) else {throw Failure.fixture}
        moving.approve(expectedRevision:moving.revision)
        check(retained.web === movingWeb && transferred==[false],"Moving a registered page cancels its old warning exactly once")
        check(store.tab(movingID)?.url=="","Moving a page restores its original displayed address before detaching the view")
        check(store.tab(movingID)?.title=="New Tab","Canceling a warning on an untitled blank page restores New Tab")
        var shutdown=[Bool]()
        _=store.decideWebsiteProtection(webA,url:url,kind:.navigation(isMainFrame:true)){shutdown.append($0)}
        store.shutdown()
        check(shutdown==[false] && store.websiteProtectionTickets.isEmpty,"Shutdown cancels all captured decisions")
        check(!FileManager.default.fileExists(atPath:root.path),"Private policy tickets write no browsing metadata")
        print("WEBSITE_PROTECTION_TICKET_CHECKS",checks,"FAILURES",failures)
        if failures>0 {throw Failure.checks(failures)}
    }
    @MainActor static func main() async {setbuf(stdout,nil);do{try await run()}catch{print("WEBSITE_PROTECTION_TICKET_FAILED",error);exit(1)}}
}
