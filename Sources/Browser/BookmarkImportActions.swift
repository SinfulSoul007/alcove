import AppKit
import BrowserCore
import UniformTypeIdentifiers

extension BrowserStore {
    var canImportBookmarkHTML: Bool {
        !isPrivate && !awaitingInitialMetadata && extensionPopupProfileID == nil &&
            (try? requireSpaceProfile(activeProfileID)) != nil
    }

    @discardableResult
    func importBookmarkHTML(_ imported: BookmarkHTMLImport, into profile: UUID) throws -> UUID {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard !awaitingInitialMetadata, extensionPopupProfileID == nil else { throw ProfileError.locked }
        try requireSpaceProfile(profile)

        var candidate = makeDocument()
        let names = Set(candidate.session.spaces.map(\.name))
        let baseName = "Imported Bookmarks"
        var name = baseName
        var suffix = 1
        while names.contains(name) {
            suffix += 1
            name = "\(baseName) \(suffix)"
        }

        var space = Space(name: name)
        space.profileID = profile
        space.icon = SpaceSymbol.defaultName(at: candidate.session.spaces.count)
        space.folders = imported.folders.map(\.name)
        space.folderParents = Dictionary(uniqueKeysWithValues: imported.folders.compactMap { folder in
            folder.parent.map { (folder.name, $0) }
        })

        var library = candidate.library(for: profile)
        var existingAddresses = Set(library.bookmarks.map(\.url))
        for bookmark in imported.bookmarks {
            var tab = BrowserCore.Tab(title: bookmark.title, url: bookmark.url, pinned: true)
            tab.homeURL = bookmark.url
            tab.pinnedTitle = bookmark.title
            tab.folder = bookmark.folder
            space.tabs.append(tab)
            if existingAddresses.insert(bookmark.url).inserted {
                library.bookmarks.append(PageRecord(title: bookmark.title, url: bookmark.url, date: bookmark.addedAt))
            }
        }
        candidate.session.spaces.append(space)
        candidate.setLibrary(library, for: profile)
        try commitProfileDocument(candidate)

        let count = imported.bookmarks.count
        let item = count == 1 ? "bookmark" : "bookmarks"
        let skipped = imported.skippedLinkCount
        var summary = "Imported \(count) \(item) into \(name)."
        if skipped > 0 {
            let link = skipped == 1 ? "link" : "links"
            summary += " Skipped \(skipped) unsupported \(link)."
        }
        message = summary
        return space.id
    }
}

extension AppDelegate {
    @objc func importBookmarks() {
        guard activeQuick == nil, let window = activeBrowserWindow, let store = windows[window], store.canImportBookmarkHTML else { return }
        let destination = store.activeProfileID
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a bookmarks HTML file. The folders and bookmarks will be added to the \(store.activeProfile.name) profile."
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak self, weak window, weak store] result in
            guard result == .OK, let file = panel.url else { return }
            Task { @MainActor [weak self, weak window, weak store] in
                let read = await Task.detached(priority: .userInitiated) { Result { try BookmarkHTMLImport.read(from: file) } }.value
                guard let window, let store, self?.windows[window] === store else { return }
                do { try store.importBookmarkHTML(read.get(), into: destination) }
                catch { store.message = "Couldn’t import bookmarks. \(error.localizedDescription)" }
            }
        }
    }
}
