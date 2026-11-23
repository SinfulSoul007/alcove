import Foundation
import Combine
import CryptoKit
import BrowserCore

enum WebsiteProtectionFailure:Error,Equatable,Sendable {
    case missingResources,invalidResources,unreadableResources
    var message:String {
        switch self {
        case .missingResources:return "Website protection data is missing."
        case .invalidResources:return "Website protection data could not be verified."
        case .unreadableResources:return "Website protection data could not be read."
        }
    }
}

enum WebsiteProtectionState:Sendable {
    case loading
    case ready(WebsiteThreatCatalog)
    case unavailable(WebsiteProtectionFailure)
}

enum WebsiteProtectionAssessment:Sendable {
    case listed(WebsiteThreat,WebsiteThreatMetadata,stale:Bool)
    case unlisted(WebsiteThreatMetadata,stale:Bool)
    case unavailable(WebsiteProtectionFailure)
}

/// One immutable, offline source for normal and private pages. Addresses are not cached.
@MainActor final class WebsiteProtectionService:ObservableObject {
    static let shared=WebsiteProtectionService()
    @Published private(set) var state:WebsiteProtectionState = .loading
    private let loader:@Sendable () throws -> WebsiteThreatCatalog
    private var loadingTask:Task<Result<WebsiteThreatCatalog,WebsiteProtectionFailure>,Never>?

    init(loader:@escaping @Sendable () throws -> WebsiteThreatCatalog = {try WebsiteProtectionService.bundledCatalog()}) {
        self.loader=loader
    }

    func load() async -> Result<WebsiteThreatCatalog,WebsiteProtectionFailure> {
        switch state {
        case .ready(let source):return .success(source)
        case .unavailable(let failure):return .failure(failure)
        case .loading:break
        }
        if loadingTask==nil {
            let read=loader
            loadingTask=Task.detached(priority:.userInitiated) {
                do {return .success(try read())}
                catch let failure as WebsiteProtectionFailure {return .failure(failure)}
                catch {return .failure(.unreadableResources)}
            }
        }
        let result=await loadingTask!.value
        if case .loading=state {
            switch result {
            case .success(let source):state = .ready(source)
            case .failure(let failure):state = .unavailable(failure)
            }
        }
        return result
    }

    func assessment(for url:URL,at now:Date = Date()) async -> WebsiteProtectionAssessment {
        assessment(for:url,result:await load(),at:now)
    }

    func cachedAssessment(for url:URL,at now:Date = Date()) -> WebsiteProtectionAssessment? {
        switch state {
        case .loading:return nil
        case .ready(let source):return assessment(for:url,result:.success(source),at:now)
        case .unavailable(let failure):return .unavailable(failure)
        }
    }

    func assessment(for url:URL,result:Result<WebsiteThreatCatalog,WebsiteProtectionFailure>,at now:Date = Date()) -> WebsiteProtectionAssessment {
        switch result {
        case .failure(let failure):return .unavailable(failure)
        case .success(let source):
            if let threat=source.threat(for:url) {return .listed(threat,source.metadata,stale:source.isStale(at:now))}
            return .unlisted(source.metadata,stale:source.isStale(at:now))
        }
    }

    nonisolated private static func bundledCatalog() throws -> WebsiteThreatCatalog {
        guard let root=Bundle.main.resourceURL?.appendingPathComponent("WebsiteProtection") else {throw WebsiteProtectionFailure.missingResources}
        return try loadCatalog(at:root)
    }

    nonisolated static func loadCatalog(at root:URL) throws -> WebsiteThreatCatalog {
        do {
            let domains=try readBounded(root.appendingPathComponent("domains.txt"),limit:8_388_608)
            let metadata=try readBounded(root.appendingPathComponent("source.json"),limit:16_384)
            let license=try readBounded(root.appendingPathComponent("LICENSE.PhishDestroy.txt"),limit:65_536)
            let source=try WebsiteThreatCatalog(domains:domains,metadata:metadata)
            let digest=SHA256.hash(data:license).map{String(format:"%02x",$0)}.joined()
            guard digest==source.metadata.licenseSHA256 else {throw WebsiteProtectionFailure.invalidResources}
            return source
        } catch let failure as WebsiteProtectionFailure {throw failure}
        catch is WebsiteThreatCatalogError {throw WebsiteProtectionFailure.invalidResources}
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {throw WebsiteProtectionFailure.missingResources}
        catch {throw WebsiteProtectionFailure.unreadableResources}
    }

    nonisolated private static func readBounded(_ url:URL,limit:Int) throws -> Data {
        guard try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else {throw WebsiteProtectionFailure.invalidResources}
        let file=try FileHandle(forReadingFrom:url)
        defer {try? file.close()}
        var data=Data()
        while data.count<=limit {
            let part=try file.read(upToCount:min(65_536,limit+1-data.count)) ?? Data()
            if part.isEmpty {return data}
            data.append(part)
        }
        throw WebsiteProtectionFailure.invalidResources
    }
}
