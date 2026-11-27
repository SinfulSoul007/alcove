import Foundation
import BrowserCore

struct EaselTabContext: Equatable {
    let tabID: UUID
    let profileID: UUID
    let easel: Easel
}

enum EaselActionError: LocalizedError {
    case missing, notPresented
    var errorDescription: String? {
        switch self {
        case .missing: return "This Easel is no longer available in this profile."
        case .notPresented: return "Bring this canvas into this window before editing it."
        }
    }
}

extension BrowserStore {
    func easelContext(for tabID: UUID) -> EaselTabContext? {
        guard !isShuttingDown, let tab = tab(tabID), let route = EaselRoute.parse(tab.url),
              let profile = profileID(for: tabID), !profileUnavailable(profile),
              isPrivate || profiles.contains(where: { $0.id == profile }) else { return nil }
        if let windowGroup, windowGroup.presentation(tabID: tabID, in: self) != .owned { return nil }
        guard let board = library(for: profile).easels?.first(where: { $0.id == route.id }) else { return nil }
        return EaselTabContext(tabID: tabID, profileID: profile, easel: board)
    }

    @discardableResult func createEasel(title: String = "Untitled Easel", in spaceID: UUID? = nil) throws -> UUID {
        let target = spaceID ?? space.id
        let index = try requireManagedSpace(target)
        let profile = isPrivate ? BrowserProfile.defaultID : session.spaces[index].effectiveProfileID
        let board = try Easel(title: title)
        var candidate = makeDocument(), records = candidate.library(for: profile)
        records.easels = [board] + (records.easels ?? [])
        candidate.setLibrary(records, for: profile)
        let tabID = try insertEaselTab(board, in: target, document: &candidate)
        try commitQuickDocument(candidate, beforePublish: { self.closePrimaryPeek(); self.dismissCommand() })
        select(tabID)
        return tabID
    }

    @discardableResult func openEasel(_ id: UUID, in spaceID: UUID? = nil) throws -> UUID {
        let target = spaceID ?? space.id
        let index = try requireManagedSpace(target)
        let profile = isPrivate ? BrowserProfile.defaultID : session.spaces[index].effectiveProfileID
        guard let board = library(for: profile).easels?.first(where: { $0.id == id }) else { throw EaselActionError.missing }
        if let existing = session.spaces[index].tabs.first(where: { EaselRoute.parse($0.url)?.id == id }) {
            selectSpace(target); select(existing.id)
            return existing.id
        }
        var candidate = makeDocument()
        let tabID = try insertEaselTab(board, in: target, document: &candidate)
        try commitQuickDocument(candidate, beforePublish: { self.closePrimaryPeek(); self.dismissCommand() })
        select(tabID)
        return tabID
    }

    func insertEaselTab(_ board: Easel, in spaceID: UUID, document: inout BrowserDocument) throws -> UUID {
        guard let index = document.session.spaces.firstIndex(where: { $0.id == spaceID }) else { throw SpaceManagementError.missingSpace }
        let destination = EaselRoute(id: board.id).url.absoluteString
        var tab = BrowserCore.Tab(title: board.title, url: destination, pinned: true)
        tab.homeURL = destination; tab.pinnedTitle = board.title
        let position = document.session.spaces[index].tabs.firstIndex(where: { !$0.pinned && $0.favorite != true }) ?? document.session.spaces[index].tabs.count
        document.session.spaces[index].tabs.insert(tab, at: position)
        document.session.spaces[index].selected = tab.id
        document.session.activateSpace(spaceID)
        return tab.id
    }

    @discardableResult func editEasel(in tabID: UUID, expectedRevision: UUID, edits: [EaselEdit], at date: Date = Date()) throws -> Easel {
        try existingEaselDrafts?.flush(tabID: tabID)
        return try commitEaselEdits(in: tabID, expectedRevision: expectedRevision, edits: edits, at: date)
    }
    /// The draft coordinator uses this transaction primitive to avoid recursive flushing.
    @discardableResult func commitEaselEdits(in tabID: UUID, expectedRevision: UUID, edits: [EaselEdit], at date: Date = Date()) throws -> Easel {
        guard let tab = tab(tabID), let route = EaselRoute.parse(tab.url), let profile = profileID(for: tabID) else { throw EaselActionError.missing }
        try requireSpaceProfile(profile)
        if let windowGroup, windowGroup.presentation(tabID: tabID, in: self) != .owned { throw EaselActionError.notPresented }
        var candidate = makeDocument(), records = candidate.library(for: profile)
        guard let index = records.easels?.firstIndex(where: { $0.id == route.id }), let original = records.easels?[index] else { throw EaselActionError.missing }
        guard original.revision == expectedRevision else { throw EaselError.staleRevision }
        var edited = original
        for edit in edits { try edited.apply(edit, expectedRevision: edited.revision, at: date) }
        guard edited != original else { return original }
        records.easels?[index] = edited
        if edited.title != original.title {
            refreshEaselTitles(edited, profile: profile, in: &candidate, library: &records)
        }
        candidate.setLibrary(records, for: profile)
        try commitQuickDocument(candidate)
        return edited
    }

    func refreshEaselTitles(_ board: Easel, profile: UUID, in document: inout BrowserDocument, library: inout BrowserLibrary) {
        func updated(_ tabs: [BrowserCore.Tab]) -> [BrowserCore.Tab] {
            tabs.map { original in
                guard EaselRoute.parse(original.url)?.id == board.id else { return original }
                var tab = original; tab.title = board.title
                if tab.pinned { tab.pinnedTitle = board.title }
                return tab
            }
        }
        for index in document.session.spaces.indices where isPrivate || document.session.spaces[index].effectiveProfileID == profile {
            document.session.spaces[index].tabs = updated(document.session.spaces[index].tabs)
        }
        library.favoriteTabs = library.favoriteTabs.map(updated)
        library.closedTabs = updated(library.closedTabs); library.archive = updated(library.archive)
        library.deletedSpaces = library.deletedSpaces?.map { original in
            var record = original; record.space.tabs = updated(record.space.tabs); return record
        }
        library.quickPages = library.quickPages?.map { original in
            var record = original; record.tab = updated([record.tab])[0]; return record
        }
    }
}
