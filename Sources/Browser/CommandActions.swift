import AppKit
import BrowserCore

extension BrowserStore {
    var availableCommands: [BrowserCommand] {
        BrowserCommand.allCases.filter { command in
            switch command {
            case .pin: return selectedTab?.url.isEmpty == false
            case .unpin: return selectedTab?.pinned == true
            case .favorite: return selectedTab?.url.isEmpty == false
            case .unfavorite: return selectedTab?.favorite == true
            case .copyURL: return currentView?.url != nil
            case .profiles: return !isPrivate
            default: return true
            }
        }
    }
    func runCommand(_ command: BrowserCommand) {
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
        case .copyURL:
            if let url = currentView?.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
    }
}
