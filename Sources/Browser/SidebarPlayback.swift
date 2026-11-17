import Foundation
import WebKit

struct SidebarPlaybackTab: Identifiable, Equatable {
    let id: UUID
    let profileID: UUID
    let title: String
    fileprivate let view: ObjectIdentifier
    fileprivate let document: UUID
    fileprivate let presentation: UUID
    fileprivate let url: URL?
}

extension BrowserStore {
    func playingSidebarTabs() async -> [SidebarPlaybackTab] {
        let profile = activeProfileID
        guard canShowSidebarPlayback(for: profile) else { return [] }
        let requests = profileTabs.compactMap { tab -> (SidebarPlaybackTab, WKWebView)? in
            let id = tab.id
            guard let web = views[id], viewProfileIDs[id] == profile, quickProfileID(id) == nil,
                  (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned else { return nil }
            let title = tab.title.isEmpty ? (web.url?.host ?? tab.sidebarTitle) : tab.title
            let entry = SidebarPlaybackTab(
                id: id, profileID: profile, title: title, view: ObjectIdentifier(web),
                document: documentIdentity(for: web) as UUID,
                presentation: presentationIdentity(for: web) as UUID, url: web.url
            )
            return (entry, web)
        }
        guard !requests.isEmpty else { return [] }
        let entries = requests.map { $0.0 }
        return await withCheckedContinuation { continuation in
            var pending = Set(entries.map(\.id))
            var playing = Set<UUID>()
            var finished = false
            let finish = { [weak self] in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: entries.filter {
                    playing.contains($0.id) && self?.sidebarPlaybackView($0) != nil
                })
            }
            for (entry, web) in requests {
                web.requestMediaPlaybackState { state in
                    guard !finished, pending.remove(entry.id) != nil else { return }
                    if state == .playing { playing.insert(entry.id) }
                    if pending.isEmpty { finish() }
                }
            }
            if !finished {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    finish()
                }
            }
        }
    }

    func showPlaybackTab(_ entry: SidebarPlaybackTab) -> Bool {
        guard sidebarPlaybackView(entry) != nil else { return false }
        selectAny(entry.id)
        return true
    }

    func pausePlaybackTab(_ entry: SidebarPlaybackTab) -> Bool {
        guard let web = sidebarPlaybackView(entry) else { return false }
        web.pauseAllMediaPlayback(completionHandler: nil)
        return true
    }

    private func canShowSidebarPlayback(for profile: UUID) -> Bool {
        !isShuttingDown && !awaitingInitialMetadata
            && activeProfileID == profile && !profileUnavailable(profile)
    }

    private func sidebarPlaybackView(_ entry: SidebarPlaybackTab) -> WKWebView? {
        let id = entry.id
        guard canShowSidebarPlayback(for: entry.profileID), quickProfileID(id) == nil,
              profileID(for: id) == entry.profileID, viewProfileIDs[id] == entry.profileID,
              (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned,
              let web = views[id], ObjectIdentifier(web) == entry.view,
              documentIdentity(for: web) as UUID == entry.document,
              presentationIdentity(for: web) as UUID == entry.presentation,
              web.url == entry.url else { return nil }
        return web
    }
}
