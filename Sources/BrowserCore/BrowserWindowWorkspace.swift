import Foundation

public enum BrowserWindowWorkspaceError: Error, Equatable {
    case missingWindow, duplicateWindow, invalidSession
}

/// Selection belongs to a window; tab content and organization belong to the library.
public struct BrowserWindowSelection: Codable, Equatable, Identifiable {
    public var id: UUID
    public var spaceID: UUID
    public var selectedTabsBySpace: [UUID: UUID]

    public init(id: UUID, session: Session) {
        self.id = id
        spaceID = session.selectedSpace
        selectedTabsBySpace = [:]
        for space in session.spaces {
            if let selected = space.selected { selectedTabsBySpace[space.id] = selected }
        }
    }

    fileprivate func reconciled(in session: Session) -> Self {
        var result = self
        if !session.spaces.contains(where: { $0.id == spaceID }) { result.spaceID = session.selectedSpace }
        result.selectedTabsBySpace = [:]
        for space in session.spaces {
            let requested = selectedTabsBySpace[space.id]
            result.selectedTabsBySpace[space.id] = space.tabs.first(where: { $0.id == requested })?.id ?? space.selected ?? space.tabs.first?.id
        }
        return result
    }

    fileprivate func projecting(_ session: Session) -> Session {
        var result = session
        result.selectedSpace = spaceID
        for index in result.spaces.indices {
            result.spaces[index].selected = selectedTabsBySpace[result.spaces[index].id]
        }
        return result
    }
}

/// A value model only. Assignments are logical ownership, not WebKit, profile or permission grants.
public struct BrowserWindowWorkspace {
    public private(set) var session: Session
    public private(set) var windows: [BrowserWindowSelection]
    public private(set) var focusedWindowID: UUID?
    public private(set) var assignments: [UUID: UUID]

    public init(session: Session, windows: [BrowserWindowSelection] = [], focusedWindowID: UUID? = nil, assignments: [UUID: UUID] = [:]) throws {
        let normalized = try Self.normalized(session)
        var identities = Set<UUID>()
        for window in windows {
            guard identities.insert(window.id).inserted else { throw BrowserWindowWorkspaceError.duplicateWindow }
        }
        self.session = normalized
        self.windows = windows.map { $0.reconciled(in: normalized) }
        self.focusedWindowID = focusedWindowID.flatMap { identities.contains($0) ? $0 : nil } ?? windows.first?.id
        let tabs = Set(normalized.spaces.flatMap(\.tabs).map(\.id))
        self.assignments = assignments.filter { tabs.contains($0.key) && identities.contains($0.value) }
        fillUnassignedTabs(with: self.focusedWindowID)
        synchronizeFocusedSelection()
    }

    public func session(for windowID: UUID) -> Session? {
        windows.first(where: { $0.id == windowID })?.projecting(session)
    }

    @discardableResult public mutating func openWindow(id: UUID = UUID(), copying sourceID: UUID? = nil) throws -> BrowserWindowSelection {
        guard !windows.contains(where: { $0.id == id }) else { throw BrowserWindowWorkspaceError.duplicateWindow }
        let seed: Session
        if let sourceID {
            guard let value = session(for: sourceID) else { throw BrowserWindowWorkspaceError.missingWindow }
            seed = value
        } else { seed = session }
        let selection = BrowserWindowSelection(id: id, session: seed).reconciled(in: session)
        windows.append(selection)
        focusedWindowID = id
        fillUnassignedTabs(with: id)
        if let selected = selection.selectedTabsBySpace[selection.spaceID] { assignments[selected] = id }
        synchronizeFocusedSelection(recordFocus: true)
        return selection
    }

    /// Callers publish from a current projection on the same serialized actor as the group.
    /// The source selection changes locally; all other windows keep valid selections.
    public mutating func apply(_ incoming: Session, from windowID: UUID) throws {
        guard windows.contains(where: { $0.id == windowID }) else { throw BrowserWindowWorkspaceError.missingWindow }
        try replaceSession(incoming, selectingFor: windowID)
    }

    /// Service work can edit tabs while the writer's original window is closed.
    public mutating func applySharedSession(_ incoming: Session) throws {
        try replaceSession(incoming, selectingFor: nil)
    }

    private mutating func replaceSession(_ incoming: Session, selectingFor windowID: UUID?) throws {
        let normalized = try Self.normalized(incoming)
        let previousTabs = allTabIDs
        var selections = windows
        if let windowID, let source = selections.firstIndex(where: { $0.id == windowID }) {
            selections[source] = BrowserWindowSelection(id: windowID, session: normalized)
        }
        selections = selections.map { $0.reconciled(in: normalized) }
        let retainedTabs = Set(normalized.spaces.flatMap(\.tabs).map(\.id))
        let retainedWindows = Set(selections.map(\.id))
        var nextAssignments = assignments.filter { retainedTabs.contains($0.key) && retainedWindows.contains($0.value) }
        if let owner = windowID ?? focusedWindowID {
            for id in retainedTabs.subtracting(previousTabs) { nextAssignments[id] = owner }
        }
        session = normalized
        windows = selections
        assignments = nextAssignments
        fillUnassignedTabs(with: focusedWindowID ?? windows.first?.id)
        synchronizeFocusedSelection()
    }

    @discardableResult public mutating func focusWindow(_ id: UUID) -> Bool {
        guard windows.contains(where: { $0.id == id }) else { return false }
        focusedWindowID = id
        synchronizeFocusedSelection(recordFocus: true)
        return true
    }

    @discardableResult public mutating func closeWindow(_ id: UUID) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        windows.remove(at: index)
        if focusedWindowID == id { focusedWindowID = windows.last?.id }
        let remaining = Set(windows.map(\.id))
        assignments = assignments.filter { remaining.contains($0.value) }
        fillUnassignedTabs(with: focusedWindowID ?? windows.first?.id)
        synchronizeFocusedSelection()
        return true
    }

    @discardableResult public mutating func claim(_ tabID: UUID, for windowID: UUID) -> Bool {
        guard allTabIDs.contains(tabID), windows.contains(where: { $0.id == windowID }) else { return false }
        assignments[tabID] = windowID
        return true
    }

    public func assignedWindow(for tabID: UUID) -> UUID? { assignments[tabID] }

    private var allTabIDs: Set<UUID> { Set(session.spaces.flatMap(\.tabs).map(\.id)) }

    private mutating func fillUnassignedTabs(with owner: UUID?) {
        guard let owner else { assignments = [:]; return }
        for id in allTabIDs where assignments[id] == nil { assignments[id] = owner }
    }

    private mutating func synchronizeFocusedSelection(recordFocus: Bool = false) {
        guard let selection = windows.first(where: { $0.id == focusedWindowID }) else { return }
        session = selection.projecting(session)
        if recordFocus { session.activateSpace(selection.spaceID) }
    }

    private static func normalized(_ incoming: Session) throws -> Session {
        var result = incoming
        if result.spaces.isEmpty { result = Session() }
        var spaces = Set<UUID>(), tabs = Set<UUID>()
        for index in result.spaces.indices {
            guard spaces.insert(result.spaces[index].id).inserted else { throw BrowserWindowWorkspaceError.invalidSession }
            if result.spaces[index].tabs.isEmpty { result.spaces[index].tabs = [Tab()] }
            for tab in result.spaces[index].tabs {
                guard tabs.insert(tab.id).inserted else { throw BrowserWindowWorkspaceError.invalidSession }
            }
            if !result.spaces[index].tabs.contains(where: { $0.id == result.spaces[index].selected }) {
                result.spaces[index].selected = result.spaces[index].tabs.first?.id
            }
        }
        if !spaces.contains(result.selectedSpace) { result.selectedSpace = result.spaces[0].id }
        return result
    }
}
