import Foundation
import BrowserCore

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

extension BrowserStore {
    var splitLayout: BrowserSplitLayout? {
        get { activeSplit(in: session) }
        set {
            if let newValue { storeSplitGroup(newValue) }
            else if let group = activeSplit(in: session) { splitGroups.removeAll { $0.id == group.id } }
        }
    }

    var activePaneID: UUID? {
        get { splitLayout?.focusedTabID }
        set {
            guard var group = splitLayout, group.focusedTabID != newValue,
                  newValue.map(group.tabIDs.contains) ?? true else { return }
            group.focusedTabID = newValue
            splitLayout = group
        }
    }

    func splitGroup(containing id: UUID) -> BrowserSplitLayout? {
        splitGroups.first { $0.tabIDs.contains(id) }
    }

    private func activeSplit(in model: Session) -> BrowserSplitLayout? {
        guard let space = model.spaces.first(where: { $0.id == model.selectedSpace }) ?? model.spaces.first,
              let selected = space.selected else { return nil }
        return splitGroups.first { $0.spaceID == space.id && $0.tabIDs.contains(selected) }
    }

    private func storeSplitGroup(_ group: BrowserSplitLayout) {
        let added = Set(group.tabIDs)
        var updated = splitGroups.compactMap { existing -> BrowserSplitLayout? in
            guard existing.id != group.id else { return group }
            guard !added.isDisjoint(with: existing.tabIDs) else { return existing }
            var trimmed = existing
            trimmed.tabIDs.removeAll(where: added.contains)
            if let focus = trimmed.focusedTabID, !trimmed.tabIDs.contains(focus) { trimmed.focusedTabID = nil }
            return trimmed.tabIDs.count >= 2 ? trimmed : nil
        }
        if !updated.contains(where: { $0.id == group.id }) { updated.append(group) }
        if updated != splitGroups { splitGroups = updated }
    }

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

    @discardableResult
    func openInSplit(_ id: UUID, at edge: BrowserSplitEdge? = nil, relativeTo target: UUID? = nil) -> Bool {
        guard !isShuttingDown, !awaitingInitialMetadata, let anchor = target ?? selectedID, anchor != id,
              (windowGroup?.presentation(tabID: anchor, in: self) ?? .owned) == .owned,
              !profileUnavailable(activeProfileID), space.tabs.contains(where: { $0.id == id && !$0.url.isEmpty }),
              space.tabs.contains(where: { $0.id == anchor }) else { return false }
        var layout = splitGroup(containing: anchor) ?? BrowserSplitLayout(spaceID: space.id, axis: .columns, tabIDs: [anchor])
        if layout.tabIDs.contains(id) {
            if target == nil { focusPane(id); return true }
            layout.tabIDs.removeAll { $0 == id }
        }
        guard layout.tabIDs.count < BrowserSplitLayout.maximumPanes else {
            message = "Split View can show up to four tabs."
            return false
        }
        if let windowGroup, !windowGroup.claimPresentation(tabID: id, in: self) { return false }
        if let edge {
            let reference = (target ?? focusedID).flatMap { layout.tabIDs.firstIndex(of: $0) } ?? 0
            layout.axis = edge.axis
            layout.tabIDs.insert(id, at: reference + (edge.insertsBefore ? 0 : 1))
        } else {
            layout.tabIDs.append(id)
        }
        splitLayout = layout
        if splitLayout?.id != layout.id { select(anchor) }
        focusPane(id)
        return true
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

    func rememberSplitPaneSizes(for snapshot: BrowserSplitLayout, lengths: [Double]) {
        guard !isShuttingDown, !awaitingInitialMetadata, !profileUnavailable(activeProfileID),
              var layout = splitLayout, layout.id == snapshot.id, layout.axis == snapshot.axis,
              layout.tabIDs == snapshot.tabIDs, layout.paneFractions == snapshot.paneFractions,
              layout.tabIDs.allSatisfy({ (windowGroup?.presentation(tabID: $0, in: self) ?? .owned) == .owned }),
              layout.rememberPaneSizes(lengths) else { return }
        splitLayout = layout
    }

    func clearSplit() {
        guard splitLayout != nil else { return }
        let previous = focusedID
        splitLayout = nil
        if previous != focusedID { dismissCommand(); cancelRecentTabSwitcher() }
    }

    func removeFromSplit(_ id: UUID) {
        guard var layout = splitGroup(containing: id) else { return }
        let previous = focusedID
        if let index = session.spaces.firstIndex(where: { $0.id == layout.spaceID && $0.selected == id }),
           let replacement = layout.neighbor(of: id, keeping: { id in
            (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned
        }) {
            session.spaces[index].selected = replacement
        }
        layout.tabIDs.removeAll { $0 == id }
        if layout.focusedTabID == id { layout.focusedTabID = nil }
        if layout.tabIDs.count >= 2 { storeSplitGroup(layout) }
        else { splitGroups.removeAll { $0.id == layout.id } }
        if previous != focusedID { dismissCommand(); cancelRecentTabSwitcher() }
    }

    /// Preserve the remembered pane when a tab leaves its Space without navigating to it.
    func splitSelectionRepairs(in incoming: Session, keeping owned: (UUID) -> Bool = { _ in true }) -> [UUID: UUID] {
        guard !splitGroups.isEmpty else { return [:] }
        let groupsBySpace = Dictionary(grouping: splitGroups, by: \.spaceID)
        let selectedGroups = session.spaces.reduce(into: [UUID: (BrowserSplitLayout, UUID, UUID)]()) { result, space in
            guard let selected = space.selected,
                  let layout = groupsBySpace[space.id]?.first(where: { $0.tabIDs.contains(selected) }) else { return }
            result[space.id] = (layout, selected, space.effectiveProfileID)
        }
        return incoming.spaces.reduce(into: [UUID: UUID]()) { result, space in
            guard let (layout, anchor, profile) = selectedGroups[space.id], space.effectiveProfileID == profile,
                  !space.tabs.contains(where: { $0.id == anchor }) else { return }
            result[space.id] = layout.neighbor(of: anchor) { id in
                owned(id) && space.tabs.contains { $0.id == id }
            }
        }
    }

    func reconciledSplitGroups(in incoming: Session, previous: Session, discarding: Set<UUID> = [],
                               keeping owned: (UUID) -> Bool = { _ in true }) -> [BrowserSplitLayout] {
        guard !splitGroups.isEmpty else { return [] }
        let groupSpaceIDs = Set(splitGroups.map(\.spaceID))
        let profiles = previous.spaces.reduce(into: [UUID: UUID]()) { result, space in
            if groupSpaceIDs.contains(space.id) { result[space.id] = space.effectiveProfileID }
        }
        let spaces = incoming.spaces.filter { incomingSpace in
            profiles[incomingSpace.id] == incomingSpace.effectiveProfileID
        }
        return BrowserSplitLayout.repairedGroups(splitGroups, in: spaces) { !discarding.contains($0) && owned($0) }
    }

    func resetSplitIfDiscardingPages(_ discarded: Set<UUID>, in incoming: Session) {
        let previous = focusedID
        let remaining = reconciledSplitGroups(in: incoming, previous: session, discarding: discarded)
        if remaining != splitGroups { splitGroups = remaining }
        if previous != focusedID { dismissCommand(); cancelRecentTabSwitcher() }
    }

    func reconcileSplitGroups(from previous: Session) {
        guard !splitGroups.isEmpty else { return }
        let previousSpace = previous.spaces.first { $0.id == previous.selectedSpace } ?? previous.spaces.first
        let oldFocus = activeSplit(in: previous)?.focusedTabID ?? previousSpace?.selected
        let remaining = reconciledSplitGroups(in: session, previous: previous)
        if remaining != splitGroups { splitGroups = remaining }
        if oldFocus != focusedID { dismissCommand(); cancelRecentTabSwitcher() }
    }
}
