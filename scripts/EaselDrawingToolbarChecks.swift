import AppKit
import BrowserCore

@main struct EaselDrawingToolbarChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0, failed = 0
        func check(_ ok: Bool, _ name: String) { checks += 1; if !ok { failed += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)") }
        let store = BrowserStore(isPrivate: true); defer { store.shutdown() }
        let tab = try store.createEasel(title: "Owned drawing toolbar")
        let canvas = EaselCanvasView(store: store, tabID: tab)
        let controls = EaselDrawingControls(canvas: canvas)
        controls.frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        controls.needsLayout = true; controls.layoutSubtreeIfNeeded()
        let pen = controls.toolButtons.first { $0.accessibilityLabel() == "Pen tool" }
        pen?.performClick(nil)
        check(pen != nil && canvas.drawingTool == .pen && pen?.state == .on, "The actual labeled Pen button selects its native canvas tool")
        func item(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
            for (i, entry) in menu.items.enumerated() {
                if entry.title == title { return (menu, i) }
                if let submenu = entry.submenu, let found = item(title, in: submenu) { return found }
            }
            return nil
        }
        func choose(_ title: String) -> Bool {
            guard let found = item(title, in: controls.overflow.menu!) else { return false }
            found.0.performActionForItem(at: found.1); return true
        }
        check(choose("Arrow") && canvas.drawingTool == .arrow, "The compact menu selects a shape through its actual action")
        check(choose("8 pt") && canvas.drawingStyle.lineWidth == 8, "The style menu changes subsequent stroke thickness")
        check(choose("50%") && canvas.drawingStyle.opacity == 0.5, "The style menu changes subsequent stroke opacity")
        check(choose("White") && canvas.drawingStyle.color == "#FFFFFF", "A native color action preserves canonical RGB ink")
        for width in [50.0, 90, 150, 220, 320, 480] {
            controls.frame.size = NSSize(width: width, height: 36)
            controls.needsLayout = true; controls.layoutSubtreeIfNeeded()
            let visible = controls.subviews.filter { !$0.isHidden }
            check(!visible.isEmpty && visible.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= width && $0.frame.minY >= 0 && $0.frame.maxY <= 36 }, "Drawing controls stay inside an actual \(Int(width))-point native toolbar")
            check(!controls.overflow.isHidden && item("Ellipse", in: controls.overflow.menu!) != nil && item("32 pt", in: controls.overflow.menu!) != nil, "The \(Int(width))-point toolbar keeps all tools and styles discoverable")
        }
        check(controls.toolButtons.count == 6 && controls.toolButtons.allSatisfy { $0.accessibilityLabel()?.isEmpty == false }, "Every actual native tool button exposes an accessibility label")
        let prior = canvas.drawingTool
        store.shutdown(); pen?.performClick(nil)
        check(canvas.drawingTool == prior, "A retired toolbar action cannot change a different or closed canvas")
        print("Easel drawing toolbar checks: \(checks) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
