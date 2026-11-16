import Foundation
import BrowserCore

enum BrowserSplitAxis: Equatable {
    case columns, rows

    var flipped: Self { self == .columns ? .rows : .columns }
}

enum BrowserSplitEdge: CaseIterable, Identifiable {
    case left, right, top, bottom

    var id: Self { self }
    var axis: BrowserSplitAxis {
        switch self {
        case .left, .right: .columns
        case .top, .bottom: .rows
        }
    }
    var insertsBefore: Bool { self == .left || self == .top }
    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Above"
        case .bottom: "Below"
        }
    }
}

struct BrowserSplitLayout: Equatable {
    static let maximumPanes = 4
    let spaceID: UUID
    var axis: BrowserSplitAxis
    var tabIDs: [UUID]

    func neighbor(of removed: UUID, keeping available: (UUID) -> Bool) -> UUID? {
        guard let index = tabIDs.firstIndex(of: removed) else { return nil }
        return tabIDs.dropFirst(index + 1).first(where: available) ?? tabIDs.prefix(index).reversed().first(where: available)
    }
}

extension BrowserStore {
    var visiblePaneIDs: [UUID] {
        splitLayout?.tabIDs ?? selectedID.map { [$0] } ?? []
    }

    var availableSplitTabs: [UUID] {
        guard let selectedID, !isShuttingDown, !awaitingInitialMetadata,
              (windowGroup?.presentation(tabID: selectedID, in: self) ?? .owned) == .owned else { return [] }
        let visible = Set(visiblePaneIDs)
        return space.tabs.compactMap { tab in
            guard !visible.contains(tab.id), !tab.url.isEmpty else { return nil }
            if extensionPopupProfileID != nil, windowGroup?.presentation(tabID: tab.id, in: self) != .owned { return nil }
            return tab.id
        }
    }

    func openInSplit(_ id: UUID, at edge: BrowserSplitEdge? = nil) {
        guard !isShuttingDown, !awaitingInitialMetadata, let primary = selectedID,
              (windowGroup?.presentation(tabID: primary, in: self) ?? .owned) == .owned,
              !profileUnavailable(activeProfileID), space.tabs.contains(where: { $0.id == id && !$0.url.isEmpty }) else { return }
        var layout = splitLayout ?? BrowserSplitLayout(spaceID: space.id, axis: .columns, tabIDs: [primary])
        if layout.tabIDs.contains(id) {
            focusPane(id)
            return
        }
        guard layout.tabIDs.count < BrowserSplitLayout.maximumPanes else {
            message = "Split View can show up to four tabs."
            return
        }
        if let windowGroup, !windowGroup.claimPresentation(tabID: id, in: self) { return }
        if let edge {
            let reference = focusedID.flatMap { layout.tabIDs.firstIndex(of: $0) } ?? 0
            layout.axis = edge.axis
            layout.tabIDs.insert(id, at: reference + (edge.insertsBefore ? 0 : 1))
        } else {
            layout.tabIDs.append(id)
        }
        splitLayout = layout
        focusPane(id)
    }

    func addSplit(at edge: BrowserSplitEdge? = nil) {
        guard let id = availableSplitTabs.first else {
            message = "Open another website to add it to Split View."
            return
        }
        openInSplit(id, at: edge)
    }

    func toggleSplit() {
        if splitLayout == nil { addSplit() }
        else { separateSplit() }
    }

    func separateSplit() {
        let focused = focusedID
        clearSplit()
        if let focused, focused != selectedID { select(focused) }
    }

    func flipSplit() {
        guard var layout = splitLayout else { return }
        layout.axis = layout.axis.flipped
        splitLayout = layout
    }

    func clearSplit() {
        let displacedFocus = splitLayout != nil && activePaneID != nil && (session.spaces.isEmpty || activePaneID != selectedID)
        if splitLayout != nil { splitLayout = nil }
        if activePaneID != nil { activePaneID = nil }
        if displacedFocus { dismissCommand(); cancelRecentTabSwitcher() }
    }

    func removeFromSplit(_ id: UUID) {
        guard var layout = splitLayout, layout.tabIDs.contains(id) else { return }
        let previous = focusedID
        if selectedID == id, let replacement = layout.neighbor(of: id, keeping: { id in
            (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned
        }) {
            session.spaces[spaceIndex].selected = replacement
        }
        layout.tabIDs.removeAll { $0 == id }
        splitLayout = layout.tabIDs.count >= 2 && selectedID != id ? layout : nil
        if activePaneID == id || splitLayout == nil { activePaneID = nil }
        if previous != focusedID { dismissCommand(); cancelRecentTabSwitcher() }
    }

    /// When the selected anchor leaves the Space, keep the neighboring owned pane selected.
    func retainSplitSelection(in incoming: inout Session, keeping owned: (UUID) -> Bool = { _ in true }) -> Bool {
        guard let layout = splitLayout, let selectedID, incoming.selectedSpace == layout.spaceID,
              let index = incoming.spaces.firstIndex(where: { $0.id == layout.spaceID }),
              incoming.spaces[index].effectiveProfileID == space.effectiveProfileID else { return false }
        let panes = Set(incoming.spaces[index].tabs.lazy.map(\.id))
        guard !panes.contains(selectedID),
              let neighbor = layout.neighbor(of: selectedID, keeping: { panes.contains($0) && owned($0) }) else { return false }
        incoming.spaces[index].selected = neighbor
        return true
    }

    func resetSplitIfDiscardingPages(_ discarded: Set<UUID>, in incoming: Session) {
        guard let layout = splitLayout else { return }
        guard let replacement = incoming.spaces.first(where: { $0.id == layout.spaceID }),
              replacement.effectiveProfileID == space.effectiveProfileID else { clearSplit(); return }
        if replacement.tabs.contains(where: { discarded.contains($0.id) && layout.tabIDs.contains($0.id) }) {
            clearSplit()
        }
    }

    func reconcileSplitLayout() {
        guard var layout = splitLayout else { return }
        guard !session.spaces.isEmpty, layout.spaceID == space.id,
              let selectedID, layout.tabIDs.contains(selectedID) else {
            clearSplit()
            return
        }
        let localTabs = space.tabs
        let previous = focusedID
        layout.tabIDs.removeAll { id in !localTabs.contains(where: { $0.id == id }) }
        if layout.tabIDs.count < 2 { clearSplit() }
        else if layout != splitLayout { splitLayout = layout }
        if let activePaneID, !visiblePaneIDs.contains(activePaneID) { self.activePaneID = nil }
        if previous != focusedID { dismissCommand(); cancelRecentTabSwitcher() }
    }
}
