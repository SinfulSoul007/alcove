import Foundation

public enum SidebarSection { case favorites, pinned, today }
public enum SidebarSizing {
    public static let defaultWidth = 236.0
    private static let widthRange = 196.0...360.0

    public static func validSavedWidth(_ saved: Double?) -> Double? {
        guard let saved, widthRange.contains(saved) else { return nil }
        return saved
    }

    public static func width(saved: Double, windowWidth: Double) -> Double {
        let minimum = widthRange.lowerBound
        return min(max(minimum, saved), min(widthRange.upperBound, max(minimum, windowWidth * 0.45)))
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

public struct SidebarFolderTree {
    public struct Row: Identifiable {
        public let name: String
        public let depth: Int
        public let expanded: Bool
        public var id: String { name }
    }

    public let names: [String]
    public let parents: [String: String]
    private let childrenByParent: [String?: [String]]

    public init(space: Space) {
        let names = space.folderNames
        let known = Set(names)
        var parents = (space.folderParents ?? [:]).filter {
            $0.key != $0.value && known.contains($0.key) && known.contains($0.value)
        }
        // Keep the folder definitions when repairing cycles in imported metadata.
        var visited = Set<String>()
        for name in names where !visited.contains(name) {
            var chain = Set<String>()
            var node = name
            while !visited.contains(node) {
                guard chain.insert(node).inserted else {
                    parents.removeValue(forKey: node)
                    break
                }
                guard let parent = parents[node] else { break }
                node = parent
            }
            visited.formUnion(chain)
        }
        self.names = names
        self.parents = parents
        self.childrenByParent = Dictionary(grouping: names) { parents[$0] }
    }

    public func children(of folder: String?) -> [String] {
        childrenByParent[folder] ?? []
    }

    public func path(to folder: String) -> [String] {
        var path = [folder]
        while let last = path.last, let parent = parents[last] { path.append(parent) }
        return path.reversed()
    }

    public func canMove(_ folder: String, under parent: String?) -> Bool {
        guard names.contains(folder) else { return false }
        guard let parent else { return true }
        return names.contains(parent) && !path(to: parent).contains(folder)
    }

    public func visibleFolders(collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        var stack = children(of: nil).reversed().map { (name: $0, depth: 0) }
        while let folder = stack.popLast() {
            let expanded = !collapsed.contains(folder.name)
            rows.append(Row(name: folder.name, depth: folder.depth, expanded: expanded))
            if expanded {
                stack.append(contentsOf: children(of: folder.name).reversed().map { ($0, folder.depth + 1) })
            }
        }
        return rows
    }
}
