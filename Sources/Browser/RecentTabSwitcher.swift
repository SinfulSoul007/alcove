import AppKit
import BrowserCore
import SwiftUI

struct RecentTabEntry: Identifiable {
    let id: UUID
    let spaceID: UUID
    let spaceName: String
    let title: String
    let url: String
    let lastAccessed: Date?
}

struct RecentTabSwitcher {
    let spaceID: UUID
    let profileID: UUID
    let sourceTabID: UUID?
    var entries: [RecentTabEntry]
    var index: Int
    var selected: RecentTabEntry { entries[index] }

    mutating func advance(_ direction: Int) {
        index = (index + direction + entries.count) % entries.count
    }
}

extension BrowserStore {
    private var canSwitchRecentTabs: Bool {
        guard !isShuttingDown, !awaitingInitialMetadata, !onboardingVisible, !commandVisible,
              presentedPanel == nil, primaryPeekView == nil, boostPicker == nil,
              !profileUnavailable(activeProfileID) else { return false }
        return focusedID.map(ownsRecentTab) ?? true
    }

    private func ownsRecentTab(_ id: UUID) -> Bool {
        (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned
    }

    var visibleRecentTabSwitcher: RecentTabSwitcher? {
        guard let switcher = recentTabSwitcher, canSwitchRecentTabs,
              switcher.spaceID == space.id, switcher.profileID == activeProfileID,
              switcher.sourceTabID == focusedID else { return nil }
        return switcher
    }

    func cancelRecentTabSwitcher() {
        if recentTabSwitcher != nil { recentTabSwitcher = nil }
    }

    @discardableResult
    func advanceRecentTab(_ direction: Int) -> Bool {
        guard canSwitchRecentTabs else { cancelRecentTabSwitcher(); return false }
        if var switcher = visibleRecentTabSwitcher {
            let previous = switcher.selected.id
            switcher.entries.removeAll { !canSelectRecentTab($0) }
            guard !switcher.entries.isEmpty else { cancelRecentTabSwitcher(); return true }
            if let index = switcher.entries.firstIndex(where: { $0.id == previous }) {
                switcher.index = index
                switcher.advance(direction)
            } else {
                switcher.index = min(switcher.index, switcher.entries.count - 1)
            }
            recentTabSwitcher = switcher
            return true
        }
        let entries = recentTabCandidates()
        guard entries.count >= 2 || (entries.count == 1 && entries.first?.id != focusedID) else {
            cancelRecentTabSwitcher()
            return false
        }
        let start = entries.firstIndex { $0.id == focusedID }
        let index = start.map { ($0 + direction + entries.count) % entries.count }
            ?? (direction > 0 ? 0 : entries.count - 1)
        recentTabSwitcher = RecentTabSwitcher(spaceID: space.id, profileID: activeProfileID,
                                               sourceTabID: focusedID, entries: entries, index: index)
        return true
    }

    func chooseRecentTab(_ id: UUID? = nil) {
        let switcher = visibleRecentTabSwitcher
        cancelRecentTabSwitcher()
        guard let switcher, let entry = switcher.entries.first(where: { $0.id == (id ?? switcher.selected.id) }),
              canSelectRecentTab(entry), entry.id != focusedID else { return }
        if entry.spaceID != space.id { selectSpace(entry.spaceID, recordingVisit: false) }
        select(entry.id)
        if let view = views[entry.id], let window = view.window, window === NSApp.keyWindow {
            window.makeFirstResponder(view)
        }
    }

    func closeHighlightedRecentTab() {
        guard var switcher = visibleRecentTabSwitcher else { cancelRecentTabSwitcher(); return }
        let entry = switcher.selected
        guard canSelectRecentTab(entry) else { cancelRecentTabSwitcher(); return }
        close(entry.id)
        guard visibleRecentTabSwitcher != nil else { cancelRecentTabSwitcher(); return }
        switcher.entries.removeAll { $0.id == entry.id || !canSelectRecentTab($0) }
        guard switcher.entries.count >= 2 else { cancelRecentTabSwitcher(); return }
        switcher.index = min(switcher.index, switcher.entries.count - 1)
        recentTabSwitcher = switcher
    }

    private func recentTabCandidates() -> [RecentTabEntry] {
        let eligibleSpaces = session.spaces.filter { isPrivate || $0.effectiveProfileID == activeProfileID }
        let entries = eligibleSpaces.flatMap { space in
            space.tabs.compactMap { tab -> RecentTabEntry? in
                guard !tab.url.isEmpty else { return nil }
                return RecentTabEntry(id: tab.id, spaceID: space.id, spaceName: space.name,
                                      title: tab.pinnedTitle ?? tab.title, url: tab.url,
                                      lastAccessed: tab.lastAccessed)
            }
        }
        let current = focusedID
        let ranked = entries.sorted { first, second in
            if first.id == current || second.id == current { return first.id == current && second.id != current }
            return (first.lastAccessed ?? .distantPast) > (second.lastAccessed ?? .distantPast)
        }
        return Array(ranked.lazy.filter { self.ownsRecentTab($0.id) }.prefix(5))
    }

    private func canSelectRecentTab(_ entry: RecentTabEntry) -> Bool {
        guard let owner = session.spaces.first(where: { $0.id == entry.spaceID }),
              isPrivate || owner.effectiveProfileID == activeProfileID,
              owner.tabs.contains(where: { $0.id == entry.id && !$0.url.isEmpty }) else { return false }
        return ownsRecentTab(entry.id)
    }
}

extension AppDelegate {
    @discardableResult
    func handleRecentTabInput(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow, window === NSApp.keyWindow,
              window.sheetParent == nil, let store = windows[window],
              ExtensionManagerWindowController.active == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.control, .shift, .command, .option])
        if event.type == .flagsChanged {
            if !modifiers.contains(.control) { store.chooseRecentTab() }
            return false
        }
        guard event.type == .keyDown, !hasMarkedText(in: window) else { return false }
        let controlTab = event.keyCode == 48 && (modifiers == .control || modifiers == [.control, .shift])
        if controlTab { return store.advanceRecentTab(modifiers.contains(.shift) ? -1 : 1) }
        guard store.visibleRecentTabSwitcher != nil else {
            store.cancelRecentTabSwitcher()
            return false
        }
        switch event.keyCode {
        case 53: store.cancelRecentTabSwitcher(); return true
        case 36, 76: store.chooseRecentTab(); return true
        case 13 where modifiers == .control: store.closeHighlightedRecentTab(); return true
        default: store.cancelRecentTabSwitcher(); return false
        }
    }
}

struct RecentTabPanel: View {
    @ObservedObject var store: BrowserStore
    let switcher: RecentTabSwitcher
    let theme: AppearanceTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recent Tabs")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.ink.opacity(0.65))
                .padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(switcher.entries) { entry in
                let selected = entry.id == switcher.selected.id
                Button { store.chooseRecentTab(entry.id) } label: {
                    HStack(spacing: 9) {
                        SiteBadge(url: entry.url, image: store.appearance.showFavicons ? store.siteIcons[entry.id] : nil)
                            .frame(width: 24, height: 24).accessibilityHidden(true)
                        Text(entry.title.isEmpty ? "New Tab" : entry.title)
                            .font(.system(size: 13 * store.appearance.textScale, weight: .medium))
                            .lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 8)
                        if entry.spaceID != switcher.spaceID {
                            Text(entry.spaceName).font(.system(size: 11)).lineLimit(1).opacity(0.7)
                        }
                    }.padding(.horizontal, 10).frame(minHeight: 39)
                        .contentShape(Rectangle())
                        .background(selected ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(10)
            .foregroundStyle(theme.ink)
            .background { theme.surface.clipShape(RoundedRectangle(cornerRadius: 14)) }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.ink.opacity(0.16)) }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .accessibilityElement(children: .contain)
    }
}
