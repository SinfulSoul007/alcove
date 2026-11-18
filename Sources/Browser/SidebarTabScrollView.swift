import AppKit
import SwiftUI
import BrowserCore

func sidebarTabPositions(_ tabs: [BrowserCore.Tab]) -> [UUID: Int] {
    Dictionary(tabs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
}

private struct SidebarTabBounds<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [ID: Anchor<CGRect>], nextValue: () -> [ID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

extension View {
    func sidebarTabScrollTarget<ID: Hashable>(_ id: ID) -> some View {
        anchorPreference(key: SidebarTabBounds<ID>.self, value: .bounds) { [id: $0] }
    }
}

private enum SidebarOverflowDirection {
    case above, below

    var description: String { self == .above ? "above" : "below" }
    var symbol: String { self == .above ? "chevron.up" : "chevron.down" }
    var alignment: Alignment { self == .above ? .topTrailing : .bottomTrailing }
}

struct SidebarTabScrollView<ID: Hashable, Content: View>: View {
    let positions: [ID: Int]
    let focusedTab: ID?
    let theme: AppearanceTheme
    let motion: Animation?
    var showsIndicators = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: showsIndicators, content: content)
                .overlayPreferenceValue(SidebarTabBounds<ID>.self) { anchors in
                    if let focusedTab, let position = positions[focusedTab] {
                        GeometryReader { geometry in
                            if let direction = direction(for: focusedTab, position: position, anchors: anchors, in: geometry) {
                                SidebarActiveTabButton(direction: direction, tint: theme.ink) {
                                    withAnimation(motion) { proxy.scrollTo(focusedTab) }
                                }
                                .frame(width: 24, height: 20)
                                .background(theme.tile, in: Capsule())
                                .background { theme.surface.clipShape(Capsule()) }
                                .overlay(Capsule().strokeBorder(theme.ink.opacity(0.2), lineWidth: 1).allowsHitTesting(false))
                                .padding(4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: direction.alignment)
                            }
                        }
                    }
                }
        }
    }

    private func direction(for id: ID, position: Int, anchors: [ID: Anchor<CGRect>], in geometry: GeometryProxy) -> SidebarOverflowDirection? {
        guard geometry.size.height > 0 else { return nil }
        if let anchor = anchors[id] {
            let row = geometry[anchor]
            if row.maxY <= 0 { return .above }
            if row.minY >= geometry.size.height { return .below }
            return nil
        }
        // Distant lazy rows can have no geometry until SwiftUI scrolls them into view.
        let realized = anchors.keys.lazy.compactMap { positions[$0] }
        guard let first = realized.min(), let last = realized.max() else { return nil }
        if position < first { return .above }
        if position > last { return .below }
        return nil
    }
}

private struct SidebarActiveTabButton: NSViewRepresentable {
    let direction: SidebarOverflowDirection
    let tint: Color
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = "Show active tab"
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let label = "Active tab \(direction.description)"
        button.image = NSImage(systemSymbolName: direction.symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        button.contentTintColor = NSColor(tint)
        button.setAccessibilityLabel("Show active tab \(direction.description)")
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func activate() { action?() }
    }
}
