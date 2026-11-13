import Foundation
import BrowserCore

enum ExtensionDownloadError:LocalizedError {
    case untrustedResponse,tooLarge,invalidResponse,http(Int)
    var errorDescription:String? {
        switch self {
        case .untrustedResponse:return "The extension service returned an unexpected download address."
        case .tooLarge:return "The extension download exceeds Alcove’s size limit."
        case .invalidResponse:return "The extension service returned an incomplete or unexpected response."
        case .http(403),.http(429):return "The extension service is limiting requests. Try again later."
        case .http(let status):return "The extension service could not provide this package (HTTP \(status))."
        }
    }
}

/// Foundation calls its delegate on a serial queue; cancellation can arrive on any
/// thread. The lock protects completion, buffers and native task ownership only.
final class ExtensionStoreTransfer:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    typealias Response = (Data,HTTPURLResponse)
    private let lock = NSLock(),resource:ExtensionStoreResource,limit:Int
    private var continuation:CheckedContinuation<Response,Error>?,session:URLSession?,task:URLSessionDataTask?
    private var response:HTTPURLResponse?,declaredLength:Int?,data = Data(),redirects = 0
    private var started = false,cancelled = false,completed = false
    private init(resource:ExtensionStoreResource,limit:Int) {self.resource = resource;self.limit = limit}
    static func fetch(url:URL,resource:ExtensionStoreResource,limit:Int,configuration:URLSessionConfiguration = .ephemeral) async throws -> Response {
        let transfer = ExtensionStoreTransfer(resource:resource,limit:limit)
        let result = try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {transfer.start(url:url,configuration:configuration,continuation:$0)}
        },onCancel:{transfer.cancel()})
        try Task.checkCancellation();return result
    }
    private func request(_ url:URL) -> URLRequest {
        var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:20)
        request.httpMethod = "GET";request.httpShouldHandleCookies = false
        request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        request.setValue("Alcove-Extension-Download",forHTTPHeaderField:"User-Agent")
        return request
    }
    private func start(url:URL,configuration:URLSessionConfiguration,continuation:CheckedContinuation<Response,Error>) {
        let maximum:Int;switch resource {case .metadata:maximum = 1_048_576;case .package:maximum = ExtensionPackageLimits.default.inputBytes}
        guard limit > 0,limit <= maximum,url.absoluteString.utf8.count <= 8192,ExtensionStoreCatalog.allows(url,for:resource) else {continuation.resume(throwing:ExtensionDownloadError.untrustedResponse);return}
        lock.lock()
        guard !started else {lock.unlock();continuation.resume(throwing:ExtensionDownloadError.invalidResponse);return}
        started = true;self.continuation = continuation
        if cancelled || Task.isCancelled {lock.unlock();finish(.failure(CancellationError()));return}
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false;configuration.httpCookieStorage = nil;configuration.urlCredentialStorage = nil;configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData;configuration.timeoutIntervalForRequest = 20
        switch resource {case .metadata:configuration.timeoutIntervalForResource = 15;case .package:configuration.timeoutIntervalForResource = 60}
        let queue = OperationQueue();queue.maxConcurrentOperationCount = 1;queue.qualityOfService = .utility
        let session = URLSession(configuration:configuration,delegate:self,delegateQueue:queue),task = session.dataTask(with:request(url))
        self.session = session;self.task = task;lock.unlock();task.resume()
    }
    private func cancel() {
        lock.lock();cancelled = true;let active = started;lock.unlock()
        if active {finish(.failure(CancellationError()))}
    }
    private func finish(_ result:Result<Response,Error>) {
        lock.lock()
        guard !completed,let continuation else {lock.unlock();return}
        completed = true;self.continuation = nil
        let task = self.task,session = self.session;self.task = nil;self.session = nil
        data = Data();response = nil;lock.unlock()
        task?.cancel();session?.invalidateAndCancel();continuation.resume(with:result)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        lock.lock();redirects += 1
        let allowed = !completed && redirects <= 5 && request.url.map{$0.absoluteString.utf8.count <= 8192 && ExtensionStoreCatalog.allows($0,for:resource)} == true
        lock.unlock()
        guard allowed,let url = request.url else {completionHandler(nil);finish(.failure(ExtensionDownloadError.untrustedResponse));return}
        completionHandler(self.request(url))
    }
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        do {
            guard let http = response as? HTTPURLResponse,let url = http.url,ExtensionStoreCatalog.allows(url,for:resource) else {throw ExtensionDownloadError.untrustedResponse}
            guard http.statusCode == 200 else {throw ExtensionDownloadError.http(http.statusCode)}
            let encoding = http.value(forHTTPHeaderField:"Content-Encoding")?.trimmingCharacters(in:.whitespaces).lowercased()
            guard encoding == nil || encoding == "identity" else {throw ExtensionDownloadError.invalidResponse}
            let mime = http.mimeType?.lowercased()
            switch resource {
            case .metadata:guard mime == "application/json" else {throw ExtensionDownloadError.invalidResponse}
            case .package:guard mime == "application/x-chrome-extension" || mime == "application/octet-stream" else {throw ExtensionDownloadError.invalidResponse}
            }
            let declared:Int?
            if let raw = http.value(forHTTPHeaderField:"Content-Length")?.trimmingCharacters(in:.whitespaces) {
                guard !raw.isEmpty,raw.utf8.allSatisfy({48...57 ~= $0}),let value = Int(raw),http.value(forHTTPHeaderField:"Transfer-Encoding") == nil else {throw ExtensionDownloadError.invalidResponse}
                declared = value
            } else {declared = http.expectedContentLength >= 0 ? Int(exactly:http.expectedContentLength) : nil}
            if let declared,declared > limit {throw ExtensionDownloadError.tooLarge}
            lock.lock();let active = !completed
            if active {self.response = http;declaredLength = declared}
            lock.unlock();completionHandler(active ? .allow : .cancel)
        } catch {completionHandler(.cancel);finish(.failure(error))}
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive chunk:Data) {
        lock.lock();guard !completed,response != nil else {lock.unlock();return}
        guard chunk.count <= limit-data.count else {lock.unlock();finish(.failure(ExtensionDownloadError.tooLarge));return}
        if let declaredLength,chunk.count > declaredLength-data.count {lock.unlock();finish(.failure(ExtensionDownloadError.invalidResponse));return}
        data.append(chunk);lock.unlock()
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        lock.lock();guard !completed else {lock.unlock();return}
        let response = self.response,data = self.data,declared = declaredLength;lock.unlock()
        if let error {finish(.failure(error));return}
        guard let response,declared == nil || declared == data.count else {finish(.failure(ExtensionDownloadError.invalidResponse));return}
        finish(.success((data,response)))
    }
}
