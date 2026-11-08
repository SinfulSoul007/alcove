import Foundation

public enum SidebarSection { case favorites, pinned, today }
public enum SidebarSizing {
    public static func width(saved: Double, windowWidth: Double) -> Double {
        min(max(196, saved), min(360, max(196, windowWidth * 0.45)))
    }
}
extension Session {
    public mutating func placeTab(_ id: UUID, in destination: UUID, section: SidebarSection, before target: UUID? = nil) {
        guard id != target, let source = spaces.firstIndex(where: { $0.tabs.contains(where: { $0.id == id }) }),
              let sourceIndex = spaces[source].tabs.firstIndex(where: { $0.id == id }),
              let dest = spaces.firstIndex(where: { $0.id == destination }) else { return }
        var tab = spaces[source].tabs.remove(at: sourceIndex)
        switch section {
        case .favorites:
            tab.favorite = true; tab.pinned = true; tab.folder = nil
            tab.homeURL = tab.homeURL ?? tab.url; tab.pinnedTitle = tab.pinnedTitle ?? tab.title
        case .pinned:
            tab.favorite = nil; tab.pinned = true; tab.folder = nil
            tab.homeURL = tab.homeURL ?? tab.url; tab.pinnedTitle = tab.pinnedTitle ?? tab.title
        case .today:
            tab.favorite = nil; tab.pinned = false; tab.folder = nil; tab.homeURL = nil; tab.pinnedTitle = nil
        }
        if let target, let insertion = spaces[dest].tabs.firstIndex(where: { $0.id == target }) { spaces[dest].tabs.insert(tab, at: insertion) }
        else { spaces[dest].tabs.append(tab) }
        if spaces[source].tabs.isEmpty { spaces[source].tabs = [Tab()] }
        if source != dest && spaces[source].selected == id { spaces[source].selected = spaces[source].tabs.first?.id }
    }
}
