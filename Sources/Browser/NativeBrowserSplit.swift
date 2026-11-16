import AppKit
import SwiftUI
import BrowserCore

/// One native split controller keeps each tab's host attached when the axis changes.
struct NativeBrowserSplit<Pane: View>: NSViewControllerRepresentable {
    let layout: BrowserSplitLayout
    let size: CGSize
    let onResize: (BrowserSplitLayout, [Double]) -> Void
    let pane: (UUID) -> Pane

    final class Coordinator {
        var items: [UUID: NSSplitViewItem] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        let split = BrowserPaneSplitView()
        split.dividerStyle = .thin
        split.isVertical = layout.axis == .columns
        controller.splitView = split
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        let columns = layout.axis == .columns
        if controller.splitView.isVertical != columns { controller.splitView.isVertical = columns }
        let count = CGFloat(layout.tabIDs.count)
        let available = (columns ? size.width : size.height) - (count - 1) * controller.splitView.dividerThickness
        let minimum = min(columns ? 160 : 112, max(0, available / count - 1))
        var retained: [UUID: NSSplitViewItem] = [:]
        let items = layout.tabIDs.map { id in
            let item: NSSplitViewItem
            if let existing = context.coordinator.items[id], let host = existing.viewController as? NSHostingController<Pane> {
                host.rootView = pane(id)
                item = existing
            } else {
                let host = NSHostingController(rootView: pane(id))
                host.sizingOptions = []
                item = NSSplitViewItem(viewController: host)
                item.canCollapse = false
            }
            if item.minimumThickness != minimum { item.minimumThickness = minimum }
            item.preferredThicknessFraction = 1 / count
            retained[id] = item
            return item
        }
        if controller.splitViewItems != items { controller.splitViewItems = items }
        context.coordinator.items = retained
        if let split = controller.splitView as? BrowserPaneSplitView {
            split.onResize = onResize
            split.configure(for: layout)
        }
    }
}

private final class BrowserPaneSplitView: NSSplitView {
    var onResize: ((BrowserSplitLayout, [Double]) -> Void)?
    private var configuration: BrowserSplitLayout?
    private var appliedExtent: CGFloat?
    private var trackingResize = false
    private var restorationScheduled = false

    func configure(for layout: BrowserSplitLayout) {
        var geometry = layout
        geometry.focusedTabID = nil
        guard configuration != geometry else { return }
        configuration = geometry
        appliedExtent = nil
        needsLayout = true
    }

    private var extent: CGFloat { isVertical ? bounds.width : bounds.height }

    private var paneLengths: [CGFloat] {
        arrangedSubviews.map { isVertical ? $0.frame.width : $0.frame.height }
    }

    override func mouseDown(with event: NSEvent) {
        let original = configuration
        let originalExtent = extent
        let before = paneLengths
        trackingResize = true
        super.mouseDown(with: event)
        trackingResize = false
        guard let original, configuration == original, originalExtent == extent else {
            needsLayout = true
            return
        }
        let after = paneLengths
        guard before.count == after.count, zip(before, after).contains(where: { old, new in abs(old - new) >= 1 }) else { return }
        onResize?(original, after.map { Double($0) })
    }

    override func layout() {
        super.layout()
        guard configuration?.paneFractions != nil, extent != appliedExtent, !trackingResize, !restorationScheduled else { return }
        restorationScheduled = true
        // Divider setters update the controller’s constraints. Let AppKit finish its current layout first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restorationScheduled = false
            self.restorePanePositions()
        }
    }

    private func restorePanePositions() {
        guard !trackingResize, let configuration, configuration.paneFractions != nil,
              extent != appliedExtent, arrangedSubviews.count == configuration.tabIDs.count else { return }
        let count = CGFloat(arrangedSubviews.count)
        let available = extent - (count - 1) * dividerThickness
        let minimum = min(isVertical ? 160 : 112, max(0, available / count - 1))
        guard let lengths = configuration.fittedPaneLengths(available: available, minimum: minimum),
              paneLengths.allSatisfy({ $0 > 0 }) else { return }
        appliedExtent = extent
        let existing = positions(for: paneLengths)
        let target = positions(for: lengths.map { CGFloat($0) })
        // Move dividers away from their neighbors before moving those that follow them.
        for index in target.indices where target[index] < existing[index] - 0.5 {
            moveDivider(at: index, to: target[index])
        }
        for index in target.indices.reversed() where target[index] > existing[index] + 0.5 {
            moveDivider(at: index, to: target[index])
        }
    }

    private func positions(for lengths: [CGFloat]) -> [CGFloat] {
        var position: CGFloat = 0
        return lengths.dropLast().map { length in
            position += length + dividerThickness
            return position - dividerThickness
        }
    }

    private func moveDivider(at index: Int, to offset: CGFloat) {
        let position = isVertical ? bounds.minX + offset : (isFlipped ? bounds.minY + offset : bounds.maxY - offset)
        setPosition(position, ofDividerAt: index)
    }
}
