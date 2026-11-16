import AppKit
import UniformTypeIdentifiers
import BrowserCore

struct SidebarTabDrag: Codable, Equatable {
    static let contentType = UTType(exportedAs: "dev.openbrowser.mac.sidebar-tab", conformingTo: .data)
    static let dropTypes: [UTType] = [contentType, .text]
    static let pasteboardType = NSPasteboard.PasteboardType(contentType.identifier)
    // SwiftUI provides drag data only on drop. This is the active in-process tab's hover preview.
    @MainActor static var preview: Self?

    let tabID: UUID
    let sourceWindow: UUID
    let sourceSpace: UUID
    let tabSpace: UUID?
    let profileID: UUID
    let presentationID: UUID?
    let sourceLayout: UUID?

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? JSONEncoder().encode(self) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .ownProcess) { complete in
            complete(data, nil)
            return nil
        }
        return provider
    }

    static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct BrowserSplitDropTarget: Equatable {
    let window: UUID
    let space: UUID
    let profile: UUID
    let tab: UUID
    let layout: UUID?
    let panes: [UUID]
    let axis: BrowserSplitAxis?
}

extension BrowserStore {
    private var sidebarDragScope: UUID? {
        guard let windowGroup else { return sidebarDragID }
        return windowGroup.containsPrimary(self) ? windowGroupID : nil
    }

    func beginSidebarTabDrag(_ tabID: UUID) -> NSItemProvider {
        let drag = sidebarTabDrag(tabID)
        SidebarTabDrag.preview = drag
        return drag?.itemProvider() ?? NSItemProvider()
    }

    func sidebarTabDrag(_ tabID: UUID) -> SidebarTabDrag? {
        guard !isShuttingDown, !awaitingInitialMetadata, extensionPopupProfileID == nil,
              let scope = sidebarDragScope,
              let profile = profileID(for: tabID), profile == activeProfileID, tab(tabID) != nil else { return nil }
        let owner = session.spaces.first { $0.tabs.contains { $0.id == tabID } }
        return SidebarTabDrag(tabID: tabID, sourceWindow: scope, sourceSpace: space.id,
                              tabSpace: owner?.id, profileID: profile,
                              presentationID: windowGroup.map { $0.extensionPresentationIdentity(for: tabID) as UUID },
                              sourceLayout: splitGroup(containing: tabID)?.id)
    }

    func validatesSidebarDrag(_ drag: SidebarTabDrag) -> Bool {
        guard let origin = pageStores.first(where: { $0.sidebarDragScope == drag.sourceWindow }) else { return false }
        return origin.sidebarTabDrag(drag.tabID) == drag
    }

    func splitDropTarget(_ tabID: UUID) -> BrowserSplitDropTarget? {
        guard !isShuttingDown, !awaitingInitialMetadata, !profileDataOperationInProgress, let scope = sidebarDragScope,
              extensionPopupProfileID == nil, !commandVisible, !onboardingVisible, presentedPanel == nil,
              primaryPeekView == nil, visibleRecentTabSwitcher == nil, canModifyLocalMetadata,
              space.tabs.contains(where: { $0.id == tabID && !$0.url.isEmpty }),
              (windowGroup?.presentation(tabID: tabID, in: self) ?? .owned) == .owned else { return nil }
        let layout = splitGroup(containing: tabID)
        return BrowserSplitDropTarget(window: scope, space: space.id, profile: activeProfileID,
                                      tab: tabID, layout: layout?.id, panes: layout?.tabIDs ?? [tabID], axis: layout?.axis)
    }

    func canSplitDrop(_ drag: SidebarTabDrag, onto target: BrowserSplitDropTarget) -> Bool {
        guard splitDropTarget(target.tab) == target, validatesSidebarDrag(drag), drag.tabID != target.tab,
              drag.sourceSpace == target.space, drag.tabSpace == target.space, drag.profileID == target.profile,
              space.tabs.contains(where: { $0.id == drag.tabID && !$0.url.isEmpty }),
              target.panes.contains(drag.tabID) || target.panes.count < BrowserSplitLayout.maximumPanes else { return false }
        return windowGroup?.canClaimPresentation(tabID: drag.tabID, in: self) ?? true
    }

    @discardableResult
    func performSplitDrop(_ drag: SidebarTabDrag, onto target: BrowserSplitDropTarget, edge: BrowserSplitEdge) -> Bool {
        guard canSplitDrop(drag, onto: target) else { return false }
        return openInSplit(drag.tabID, at: edge, relativeTo: target.tab)
    }
}
