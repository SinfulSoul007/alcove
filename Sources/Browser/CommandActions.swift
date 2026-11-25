import AppKit
import BrowserCore

extension BrowserStore {
    private var canChangeTabMetadata: Bool {
        canModifyLocalMetadata && !isShuttingDown && !profileDataOperationInProgress && (isPrivate || !profileUnavailable(activeProfileID))
    }
    var availableCommands: [BrowserCommand] {
        let addresses = focusedID.map { pinnedAddressActions(for: $0) } ?? .unavailable
        return BrowserCommand.allCases.filter { command in
            switch command {
            case .reader: return (primaryPeekView ?? currentView).map { canToggleReader(for: $0) } ?? false
            case .pin: return canChangeTabMetadata && selectedTab?.url.isEmpty == false
            case .unpin: return canChangeTabMetadata && selectedTab?.pinned == true
            case .favorite: return canChangeTabMetadata && selectedTab?.url.isEmpty == false
            case .unfavorite: return canChangeTabMetadata && selectedTab?.favorite == true
            case .copyURL: return currentView?.url != nil
            case .profiles: return !isPrivate
            case .spaces,.deletedSpaces: return !isShuttingDown && !awaitingInitialMetadata
            case .newSpace,.renameSpace,.deleteSpace,.newFolder: return canManageSpace(space.id)
            case .collapsePinned: return space.pinnedShelfCollapsed != true && canManageSpace(space.id)
            case .expandPinned: return space.pinnedShelfCollapsed == true && canManageSpace(space.id)
            case .renameTab: return focusedID.map { (try? beginSidebarRename($0)) != nil } ?? false
            case .duplicateTab: return focusedID.map(canDuplicateSidebarTab) ?? false
            case .returnToPinnedURL: return addresses.canReturn
            case .returnToPinnedURLKeepingPage: return addresses.canKeepCurrent
            case .editPinnedURL: return addresses.canEdit
            case .useCurrentPinnedURL: return addresses.canUseCurrent
            case .restoreSpace: return canUndoSpaceDeletion
            case .splitLeft, .splitRight, .splitTop, .splitBottom:
                return !isShuttingDown && !awaitingInitialMetadata &&
                    visiblePaneIDs.count < BrowserSplitLayout.maximumPanes && !availableSplitTabs.isEmpty
            case .flipSplit: return splitLayout != nil
            default: return true
            }
        }
    }
    func runCommand(_ command: BrowserCommand) {
        guard availableCommands.contains(command) else { return }
        commandVisible = false; commandOpensNewTab = false
        switch command {
        case .reader: if let web = primaryPeekView ?? currentView { toggleReader(web) }
        case .pin: if let tab = selectedTab, !tab.pinned { togglePin(tab.id) }
        case .unpin: if let tab = selectedTab, tab.pinned { togglePin(tab.id) }
        case .favorite: if let tab = selectedTab, tab.favorite != true { toggleFavorite(tab.id) }
        case .unfavorite: if let tab = selectedTab, tab.favorite == true { toggleFavorite(tab.id) }
        case .sidebar: sidebarVisible.toggle()
        case .split: toggleSplit()
        case .splitLeft: addSplit(at: .left)
        case .splitRight: addSplit(at: .right)
        case .splitTop: addSplit(at: .top)
        case .splitBottom: addSplit(at: .bottom)
        case .flipSplit: flipSplit()
        case .library: libraryVisible = true
        case .downloads: showDownloads()
        case .settings: settingsVisible = true
        case .extensions: requestExtensionManager()
        case .profiles: if !isPrivate { profilesVisible = true }
        case .spaces: showSpacesManager()
        case .deletedSpaces: showSpacesManager(deleted:true)
        case .newSpace: requestNewSpace()
        case .newFolder: requestNewTabFolder()
        case .collapsePinned: requestPinnedShelfCollapsed(true, in: space.id)
        case .expandPinned: requestPinnedShelfCollapsed(false, in: space.id)
        case .renameTab: if let id = focusedID { requestRenameSidebarTab(id) }
        case .duplicateTab: if let id = focusedID { duplicateSidebarTab(id) }
        case .returnToPinnedURL: if let id = focusedID { requestReturnToPinnedAddress(id) }
        case .returnToPinnedURLKeepingPage: if let id = focusedID { requestReturnToPinnedAddress(id, keepingCurrentPage: true) }
        case .editPinnedURL: if let id = focusedID { requestPinnedAddressEdit(id) }
        case .useCurrentPinnedURL: if let id = focusedID { requestUseCurrentAddressAsPinned(id) }
        case .renameSpace: requestRenameSpace(space.id)
        case .deleteSpace: requestDeleteSpace(space.id)
        case .restoreSpace: undoSpaceDeletion()
        case .siteSearch: presentedPanel = .siteSearch
        case .linkRouting: presentedPanel = .links
        case .boosts:
            do { try requestBoostEditor(for: primaryPeekView ?? currentView) } catch { message = error.localizedDescription }
        case .copyURL:
            if let url = currentView?.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
    }
}
