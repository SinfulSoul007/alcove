import AppKit
import BrowserCore

extension BrowserStore {
    private var canChangeTabMetadata: Bool {
        canModifyLocalMetadata && !isShuttingDown && !profileDataOperationInProgress && (isPrivate || !profileUnavailable(activeProfileID))
    }
    var availableCommands: [BrowserCommand] {
        BrowserCommand.allCases.filter { command in
            switch command {
            case .pin: return canChangeTabMetadata && selectedTab?.url.isEmpty == false
            case .unpin: return canChangeTabMetadata && selectedTab?.pinned == true
            case .favorite: return canChangeTabMetadata && selectedTab?.url.isEmpty == false
            case .unfavorite: return canChangeTabMetadata && selectedTab?.favorite == true
            case .copyURL: return currentView?.url != nil
            case .profiles: return !isPrivate
            default: return true
            }
        }
    }
    func runCommand(_ command: BrowserCommand) {
        guard availableCommands.contains(command) else { return }
        commandVisible = false; commandOpensNewTab = false
        switch command {
        case .pin: if let tab = selectedTab, !tab.pinned { togglePin(tab.id) }
        case .unpin: if let tab = selectedTab, tab.pinned { togglePin(tab.id) }
        case .favorite: if let tab = selectedTab, tab.favorite != true { toggleFavorite(tab.id) }
        case .unfavorite: if let tab = selectedTab, tab.favorite == true { toggleFavorite(tab.id) }
        case .sidebar: sidebarVisible.toggle()
        case .split: toggleSplit()
        case .library: libraryVisible = true
        case .settings: settingsVisible = true
        case .profiles: if !isPrivate { profilesVisible = true }
        case .siteSearch: presentedPanel = .siteSearch
        case .linkRouting: presentedPanel = .links
        case .copyURL:
            if let url = currentView?.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
    }
}
