import AppKit
import BrowserCore

struct SidebarTabRename: Identifiable {
    let id = UUID()
    let tabID: UUID
    let profileID: UUID
    let originalName: String?
    let displayedName: String
}

private enum SidebarTabNameError: LocalizedError {
    case moved, invalidName

    var errorDescription: String? {
        switch self {
        case .moved: "This tab or its name changed. Start the rename again."
        case .invalidName: "Use up to 120 characters without line breaks or control characters."
        }
    }
}

extension BrowserStore {
    func beginSidebarRename(_ id: UUID) throws -> SidebarTabRename {
        guard let tab = tab(id), !tab.url.isEmpty, quickPage(id) == nil,
              let profile = profileID(for: id) else { throw SidebarTabNameError.moved }
        try requireSpaceProfile(profile)
        return SidebarTabRename(tabID: id, profileID: profile, originalName: tab.customTitle, displayedName: tab.sidebarTitle)
    }

    func renameSidebarTab(_ snapshot: SidebarTabRename, to proposedName: String) throws {
        let current = try beginSidebarRename(snapshot.tabID)
        guard current.profileID == snapshot.profileID, current.originalName == snapshot.originalName else {
            throw SidebarTabNameError.moved
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let disallowed = CharacterSet.controlCharacters.union(.newlines)
        guard name.count <= 120, !name.unicodeScalars.contains(where: disallowed.contains) else {
            throw SidebarTabNameError.invalidName
        }
        let customName: String? = name.isEmpty || (snapshot.originalName == nil && name == snapshot.displayedName) ? nil : name
        guard customName != current.originalName else { return }
        var candidate = makeDocument()
        if let space = candidate.session.spaces.firstIndex(where: { $0.tabs.contains { $0.id == snapshot.tabID } }),
           let tab = candidate.session.spaces[space].tabs.firstIndex(where: { $0.id == snapshot.tabID }) {
            candidate.session.spaces[space].tabs[tab].customTitle = customName
        }
        var library = candidate.library(for: snapshot.profileID)
        if let favorite = library.favoriteTabs?.firstIndex(where: { $0.id == snapshot.tabID }) {
            library.favoriteTabs?[favorite].customTitle = customName
            candidate.setLibrary(library, for: snapshot.profileID)
        }
        try commitQuickDocument(candidate)
    }

    func requestRenameSidebarTab(_ id: UUID) {
        do {
            let snapshot = try beginSidebarRename(id)
            let alert = NSAlert()
            alert.messageText = "Rename Tab"
            let field = NSTextField(string: snapshot.displayedName)
            field.placeholderString = "Tab name"
            field.frame = NSRect(x: 0, y: 0, width: 290, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try renameSidebarTab(snapshot, to: field.stringValue)
        } catch { message = error.localizedDescription }
    }

    func restoreSidebarTabName(_ id: UUID) {
        do { try renameSidebarTab(beginSidebarRename(id), to: "") }
        catch { message = error.localizedDescription }
    }
}
