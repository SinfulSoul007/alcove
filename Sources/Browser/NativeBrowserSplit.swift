import AppKit
import SwiftUI
import BrowserCore

/// One native split controller keeps each tab's host attached when the axis changes.
struct NativeBrowserSplit<Pane: View>: NSViewControllerRepresentable {
    let layout: BrowserSplitLayout
    let size: CGSize
    let pane: (UUID) -> Pane

    final class Coordinator {
        var items: [UUID: NSSplitViewItem] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = layout.axis == .columns
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
    }
}
