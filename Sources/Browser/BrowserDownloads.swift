import AppKit
import Darwin
import WebKit

struct DownloadFileIdentity: Equatable, Sendable {
    private let device: dev_t
    private let inode: ino_t

    init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        var info = stat()
        let isRegularFile = url.withUnsafeFileSystemRepresentation { path in
            guard let path, lstat(path, &info) == 0 else { return false }
            return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        }
        guard isRegularFile else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

struct DownloadStaging: Sendable {
    let fileURL: URL

    init(filename: String) throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("AlcoveDownload-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent(filename, isDirectory: false)
    }

    func publish(to destination: URL) throws -> DownloadFileIdentity {
        guard DownloadFileIdentity(fileURL) != nil else { throw CocoaError(.fileReadNoSuchFile) }
        try FileManager.default.moveItem(at: fileURL, to: destination)
        guard let identity = DownloadFileIdentity(destination) else { throw CocoaError(.fileReadNoSuchFile) }
        return identity
    }

    func discard() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

struct DownloadItem: Identifiable {
    struct Transfer {
        let download: WKDownload
        let staging: DownloadStaging
    }

    enum State {
        case downloading(Transfer)
        case canceling(Transfer)
        case saving
        case finished(DownloadFileIdentity)
        case failed(String)
        case canceled

        var transfer: Transfer? {
            switch self {
            case .downloading(let transfer), .canceling(let transfer): return transfer
            default: return nil
            }
        }

        var isActive: Bool {
            if case .saving = self { return true }
            return transfer != nil
        }
    }

    let id = UUID()
    let destination: URL
    let profileID: UUID
    var state: State
    var name: String { destination.lastPathComponent }
}

extension BrowserStore {
    var hasDownloadsForActiveProfile: Bool {
        let profileID = activeProfileID
        return downloads.contains { $0.profileID == profileID }
    }

    var downloadsForActiveProfile: [DownloadItem] {
        let profileID = activeProfileID
        return downloads.filter { $0.profileID == profileID }
    }

    func showDownloads() {
        librarySection = .downloads
        libraryVisible = true
    }

    func completedDownloadURL(_ id: UUID) -> URL? {
        guard let item = downloads.first(where: { $0.id == id && $0.profileID == activeProfileID }),
              case .finished(let identity) = item.state, DownloadFileIdentity(item.destination) == identity else { return nil }
        return item.destination
    }

    func removeDownloadRecord(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id && $0.profileID == activeProfileID }),
              !downloads[index].state.isActive else { return }
        downloads.remove(at: index)
    }

    func cancelDownload(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id && $0.profileID == activeProfileID }),
              case .downloading(let transfer) = downloads[index].state else { return }
        downloads[index].state = .canceling(transfer)
        cancelDownloadWebsiteProtection(transfer.download)
        transfer.download.cancel { [weak self, staging = transfer.staging] _ in
            staging.discard()
            guard let self, let index = self.downloads.firstIndex(where: { $0.id == id }),
                  case .canceling = self.downloads[index].state else { return }
            self.downloads[index].state = .canceled
        }
    }

    func trackDownload(_ download: WKDownload, from webView: WKWebView) {
        guard let profileID = profileID(for: webView), !profileUnavailable(profileID), !isShuttingDown else {
            download.cancel()
            return
        }
        pendingDownloadProfiles.setObject(profileID as NSUUID, forKey: download)
        downloadProtectionSources.setObject(WebsiteProtectionSource(store:self,web:webView,profileID:profileID),forKey:download)
        download.delegate = self
    }

    private func websiteProtectionOwner(of download:WKDownload) -> UUID? {
        guard !isShuttingDown else {return nil}
        let active=downloads.first { item in
            if case .downloading(let transfer)=item.state {return transfer.download === download}
            return false
        }?.profileID
        guard let profile=(pendingDownloadProfiles.object(forKey:download) as UUID?) ?? active,
              !profileUnavailable(profile) else {return nil}
        return profile
    }

    private func cancelDownloadWebsiteProtection(_ download:WKDownload) {
        downloadProtectionTickets.object(forKey:download)?.cancel()
        downloadProtectionTickets.removeObject(forKey:download)
        downloadProtectionSources.removeObject(forKey:download)
    }

    func download(_ download:WKDownload,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,decisionHandler:@escaping(WKDownload.RedirectPolicy)->Void) {
        guard let profile=websiteProtectionOwner(of:download),let url=request.url,
              ["http","https"].contains(url.scheme?.lowercased() ?? "") else {decisionHandler(.cancel);return}
        // An unlisted background download can keep running after its page closes.
        if let assessment=websiteProtection.cachedAssessment(for:url),case .unlisted=assessment {decisionHandler(.allow);return}
        guard let source=downloadProtectionSources.object(forKey:download),source.profileID==profile,
              source.currentWeb != nil,downloadProtectionTickets.object(forKey:download)?.isPending != true else {decisionHandler(.cancel);return}
        let ticket=decideWebsiteProtection(source,url:url,kind:.download) { [weak self,weak download] approved in
            guard approved,let self,let download,self.websiteProtectionOwner(of:download)==profile else {decisionHandler(.cancel);return}
            decisionHandler(.allow)
        }
        if let ticket {downloadProtectionTickets.setObject(ticket,forKey:download)}
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.begin { [weak self] result in
            guard let self, let owner = self.pendingDownloadProfiles.object(forKey: download) else { completionHandler(nil); return }
            self.pendingDownloadProfiles.removeObject(forKey: download)
            let profileID = owner as UUID
            guard result == .OK, let url = panel.url, !self.isShuttingDown, !self.profileUnavailable(profileID) else {
                self.cancelDownloadWebsiteProtection(download)
                completionHandler(nil)
                return
            }
            do {
                // WebKit may leave an incomplete file on cancel. Keep its writes in our own temporary directory.
                let staging = try DownloadStaging(filename: url.lastPathComponent)
                let transfer = DownloadItem.Transfer(download: download, staging: staging)
                self.downloads.insert(DownloadItem(destination: url, profileID: profileID, state: .downloading(transfer)), at: 0)
                if !self.libraryVisible && profileID == self.activeProfileID { self.librarySection = .downloads }
                completionHandler(staging.fileURL)
            } catch {
                self.cancelDownloadWebsiteProtection(download)
                if profileID == self.activeProfileID { self.message = "Download failed: \(error.localizedDescription)" }
                completionHandler(nil)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        cancelDownloadWebsiteProtection(download)
        if let index = downloads.firstIndex(where: { $0.state.transfer?.download === download }) {
            downloads[index].state.transfer?.staging.discard()
            if case .canceling = downloads[index].state {
                downloads[index].state = .canceled
            } else {
                downloads[index].state = .failed(error.localizedDescription)
                if downloads[index].profileID == activeProfileID { message = "Download failed: \(error.localizedDescription)" }
            }
        } else if let owner = pendingDownloadProfiles.object(forKey: download) {
            pendingDownloadProfiles.removeObject(forKey: download)
            if owner as UUID == activeProfileID { message = "Download failed: \(error.localizedDescription)" }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        cancelDownloadWebsiteProtection(download)
        guard let index = downloads.firstIndex(where: { $0.state.transfer?.download === download }),
              let transfer = downloads[index].state.transfer else { return }
        if case .canceling = downloads[index].state {
            transfer.staging.discard()
            downloads[index].state = .canceled
            return
        }
        let id = downloads[index].id
        let destination = downloads[index].destination
        let staging = transfer.staging
        downloads[index].state = .saving
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try staging.publish(to: destination) }
            staging.discard()
            await self?.finishedSavingDownload(id, result: result)
        }
    }

    private func finishedSavingDownload(_ id: UUID, result: Result<DownloadFileIdentity, Error>) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), case .saving = downloads[index].state else { return }
        let summary: String
        switch result {
        case .success(let identity):
            downloads[index].state = .finished(identity)
            summary = "Download finished."
        case .failure(let error):
            downloads[index].state = .failed(error.localizedDescription)
            summary = "Download failed: \(error.localizedDescription)"
        }
        if downloads[index].profileID == activeProfileID { message = summary }
    }
}
