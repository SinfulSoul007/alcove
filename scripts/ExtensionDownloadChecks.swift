import Foundation
import BrowserCore

private final class OwnedExtensionProtocol:URLProtocol,@unchecked Sendable {
    struct Plan {var status = 200,headers:[String:String] = ["Content-Type":"application/x-chrome-extension"],chunks:[Data] = [];var stall = false;var redirect:URL?;var redirectEveryRequest = false}
    private static let lock = NSLock()
    private static var plan = Plan(),seen:[URLRequest] = [],stops = 0
    static func reset(_ plan:Plan) {lock.lock();defer {lock.unlock()};self.plan = plan;seen = [];stops = 0}
    static func observation() -> ([URLRequest],Int) {lock.lock();defer {lock.unlock()};return (seen,stops)}
    override class func canInit(with request:URLRequest) -> Bool {true}
    override class func canonicalRequest(for request:URLRequest) -> URLRequest {request}
    override func startLoading() {
        Self.lock.lock();let plan = Self.plan;Self.seen.append(request);Self.lock.unlock()
        guard let url = request.url else {return}
        if let target = plan.redirect,(url != target || plan.redirectEveryRequest) {
            let response = HTTPURLResponse(url:url,statusCode:302,httpVersion:"HTTP/1.1",headerFields:["Location":target.absoluteString])!
            client?.urlProtocol(self,wasRedirectedTo:URLRequest(url:target),redirectResponse:response);return
        }
        let response = HTTPURLResponse(url:url,statusCode:plan.status,httpVersion:"HTTP/1.1",headerFields:plan.headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        for chunk in plan.chunks {client?.urlProtocol(self,didLoad:chunk)}
        if !plan.stall {client?.urlProtocolDidFinishLoading(self)}
    }
    override func stopLoading() {Self.lock.lock();Self.stops += 1;Self.lock.unlock()}
}

private final class OwnedPackageResponses:@unchecked Sendable {
    let metadata:Data,archive:Data
    private let lock = NSLock()
    private var urls:[URL] = [],limits:[Int] = []
    init(metadata:Data,archive:Data) {self.metadata = metadata;self.archive = archive}
    func respond(_ url:URL,_ resource:ExtensionStoreResource,_ limit:Int) -> Data {
        lock.lock();defer {lock.unlock()};urls.append(url);limits.append(limit)
        switch resource {case .metadata:return metadata;case .package:return archive}
    }
    func observation() -> ([URL],[Int]) {lock.lock();defer {lock.unlock()};return (urls,limits)}
}
private final class OwnedMetadataGate:@unchecked Sendable {
    private let lock = NSLock()
    private var continuation:CheckedContinuation<Data,Never>?
    func wait() async -> Data {await withCheckedContinuation {lock.lock();continuation = $0;lock.unlock()}}
    var pending:Bool {lock.lock();defer {lock.unlock()};return continuation != nil}
    func release(_ data:Data) {lock.lock();let continuation = self.continuation;self.continuation = nil;lock.unlock();continuation?.resume(returning:data)}
}

@main struct ExtensionDownloadChecks {
    static func main() async throws {
        setbuf(stdout,nil)
        var failures = 0
        func check(_ value:Bool,_ label:String) {print("\(value ? "PASS" : "FAIL"): \(label)");if !value {failures += 1}}
        let url = try ExtensionStoreCatalog.downloadURL(id:String(repeating:"a",count:32),version:"143.0.1234.56")
        func configuration() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral;value.protocolClasses = [OwnedExtensionProtocol.self]
            let cookie = HTTPCookie(properties:[.domain:"clients2.google.com",.path:"/",.name:"owned_test_cookie",.value:"never send this fixture cookie",.secure:"TRUE"])!
            value.httpCookieStorage?.setCookie(cookie)
            return value
        }
        func fetch(_ plan:OwnedExtensionProtocol.Plan,limit:Int = 16) async throws -> (Data,HTTPURLResponse) {
            OwnedExtensionProtocol.reset(plan)
            return try await ExtensionStoreTransfer.fetch(url:url,resource:.package,limit:limit,configuration:configuration())
        }
        let body = Data("owned bytes".utf8),reply = try await fetch(.init(headers:["Content-Type":"application/x-chrome-extension","Content-Length":String(body.count)],chunks:[body.prefix(4),body.dropFirst(4)]))
        check(reply.0 == body && reply.1.url == url,"The real URLSession delegate preserves an owned streamed response exactly")
        let requests = OwnedExtensionProtocol.observation().0
        check(requests.count == 1 && requests[0].httpMethod == "GET" && requests[0].httpBody == nil && requests[0].value(forHTTPHeaderField:"Cookie") == nil && requests[0].value(forHTTPHeaderField:"Authorization") == nil && requests[0].value(forHTTPHeaderField:"Accept-Encoding") == "identity","An injected cookie jar cannot add cookies or credentials to the dedicated package request")
        func rejects(_ plan:OwnedExtensionProtocol.Plan,_ label:String,limit:Int = 16) async {
            do {_ = try await fetch(plan,limit:limit);check(false,label)} catch {check(true,label)}
        }
        await rejects(.init(headers:["Content-Type":"application/x-chrome-extension","Content-Length":"17"],chunks:[]),"An excessive declared length is refused before accepting the response body")
        await rejects(.init(chunks:[Data(repeating:1,count:10),Data(repeating:2,count:7)]),"An unknown-length stream cannot cross its actual byte cap")
        await rejects(.init(headers:["Content-Type":"application/x-chrome-extension","Content-Length":"12"],chunks:[Data(repeating:3,count:4)]),"A completed response cannot pass with fewer bytes than its declared length")
        await rejects(.init(headers:["Content-Type":"application/x-chrome-extension","Content-Length":"-1"]),"Malformed negative content length is refused")
        await rejects(.init(headers:["Content-Type":"application/x-chrome-extension","Content-Encoding":"gzip"],chunks:[body]),"Unexpected content encoding cannot bypass the transfer byte policy")
        await rejects(.init(status:404,chunks:[body]),"An HTTP error cannot become an installable response")
        await rejects(.init(headers:["Content-Type":"text/html"],chunks:[body]),"A successful HTML error page cannot become a CRX response")
        let blob = URL(string:"https://clients2.googleusercontent.com/crx/blobs/owned/package.crx")!
        let redirected = try await fetch(.init(chunks:[body],redirect:blob))
        check(redirected.0 == body && redirected.1.url == blob && OwnedExtensionProtocol.observation().0.count == 2,"An actual URLSession redirect follows the permitted blob origin and preserves its owned payload")
        await rejects(.init(chunks:[body],redirect:URL(string:"https://outside.invalid/crx/blobs/owned/package.crx")!),"A forbidden redirect cannot supply package bytes")
        check(OwnedExtensionProtocol.observation().0.count == 1,"The real transport rejects a forbidden destination before sending a request to it")
        await rejects(.init(redirect:url,redirectEveryRequest:true),"A native redirect loop stops at Alcove’s bounded hop count")
        check(OwnedExtensionProtocol.observation().0.count == 6,"Five permitted redirect hops cannot turn into an unbounded transfer")
        let metadataURL = ExtensionStoreCatalog.versionURL(platform:.arm64),metadata = Data(#"{"versions":[{"name":"chrome/platforms/mac_arm64/channels/stable/versions/143.0.1234.56","version":"143.0.1234.56"}]}"#.utf8)
        OwnedExtensionProtocol.reset(.init(headers:["Content-Type":"application/json"],chunks:[metadata]))
        let selected = try await ExtensionStoreTransfer.fetch(url:metadataURL,resource:.metadata(.arm64),limit:1_048_576,configuration:configuration())
        check(try ExtensionStoreCatalog.selectionVersion(from:selected.0,platform:.arm64) == "143.0.1234.56","Owned stable-version metadata passes through the real transfer and the exact-platform parser")
        OwnedExtensionProtocol.reset(.init(stall:true))
        let pending = Task {try await ExtensionStoreTransfer.fetch(url:url,resource:.package,limit:16,configuration:configuration())}
        for _ in 0..<500 {if !OwnedExtensionProtocol.observation().0.isEmpty {break};try await Task.sleep(for:.milliseconds(2))}
        pending.cancel()
        do {_ = try await pending.value;check(false,"Caller cancellation stops the actual URLSession task")} catch is CancellationError {check(true,"Caller cancellation stops the actual URLSession task")} catch {check(false,"Cancellation returned an unrelated error: \(error)")}
        for _ in 0..<500 {if OwnedExtensionProtocol.observation().1 > 0 {break};try await Task.sleep(for:.milliseconds(2))}
        check(OwnedExtensionProtocol.observation().1 > 0,"Cancellation reaches the actual owned protocol's stopLoading callback")
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? manager.removeItem(at:root)}
        let package = try ownedDownloadPackageFixture(),responses = OwnedPackageResponses(metadata:metadata,archive:package.bytes)
        let transport:ExtensionStoreDownload.Transport = {responses.respond($0,$1,$2)}
        var rejectedPublisher = false
        do {let prepared = try await ExtensionStoreDownload.fetch(id:package.id,stagingRoot:root,platform:.arm64,transport:transport);try prepared.discard()}
        catch {rejectedPublisher = error.localizedDescription.localizedCaseInsensitiveContains("publisher")}
        check(rejectedPublisher,"The complete network pipeline requires the production publisher proof even for a valid generated developer signature")
        let observed = responses.observation(),expectedPackageURL = try ExtensionStoreCatalog.downloadURL(id:package.id,version:"143.0.1234.56")
        check(observed.0 == [metadataURL,expectedPackageURL] && observed.1 == [1_048_576,ExtensionPackageLimits.default.inputBytes],"The pipeline requests fresh stable metadata before its exact ID/version package with the correct byte limits")
        check(!manager.fileExists(atPath:root.path),"A fetched but unauthenticated package cannot create staged resources")
        let wrongID = (package.id.first == "a" ? "b" : "a")+package.id.dropFirst(),wrong = OwnedPackageResponses(metadata:metadata,archive:package.bytes)
        var rejectedIdentity = false
        do {_ = try await ExtensionStoreDownload.fetch(id:String(wrongID),stagingRoot:root,platform:.arm64,transport:{wrong.respond($0,$1,$2)})}
        catch {rejectedIdentity = error.localizedDescription.localizedCaseInsensitiveContains("requested extension")}
        check(rejectedIdentity,"The complete fetch pipeline binds the downloaded developer key to the requested extension ID")
        let invalid = OwnedPackageResponses(metadata:metadata,archive:package.bytes)
        do {_ = try await ExtensionStoreDownload.fetch(id:"invalid",stagingRoot:root,platform:.arm64,transport:{invalid.respond($0,$1,$2)});check(false,"Invalid input cannot begin a store transfer")}
        catch {check(invalid.observation().0.isEmpty,"Invalid input cannot begin a store transfer")}
        let gate = OwnedMetadataGate()
        let cancelled = Task {try await ExtensionStoreDownload.fetch(id:package.id,stagingRoot:root,platform:.arm64,transport:{_,resource,_ in
            guard case .metadata = resource else {throw ExtensionDownloadError.invalidResponse}
            return await gate.wait()
        })}
        for _ in 0..<500 {if gate.pending {break};try await Task.sleep(for:.milliseconds(2))}
        check(gate.pending,"The pipeline cancellation fixture holds an actual pending metadata result")
        cancelled.cancel();gate.release(metadata)
        do {_ = try await cancelled.value;check(false,"A late metadata response cannot publish after caller cancellation")}
        catch is CancellationError {check(true,"A late metadata response cannot publish after caller cancellation")}
        catch {check(false,"Pipeline cancellation returned an unrelated error: \(error)")}
        check(!manager.fileExists(atPath:root.path),"Cancelling package selection leaves no unauthenticated resource files")
        print("Extension download checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
