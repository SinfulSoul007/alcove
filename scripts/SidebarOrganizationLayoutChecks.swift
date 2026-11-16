import AppKit
import SwiftUI
import WebKit
import BrowserCore

@MainActor private final class SidebarGestureFixtureWindow: NSWindow {
    var claimsKeyForGestures = false
    override var isKeyWindow: Bool { claimsKeyForGestures || super.isKeyWindow }
}

@main struct SidebarOrganizationLayoutChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func descendants<T:NSView>(_ root:NSView,_ type:T.Type) -> [T] {(root as? T).map{[$0]} ?? root.subviews.flatMap{descendants($0,type)}}
        func settle() async {for _ in 0..<15 {try? await Task.sleep(for:.milliseconds(10))}}
        let attachment = EdgeToEdgeWebHost(frame:NSRect(x:0,y:0,width:600,height:400))
        let configuration = WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        let attached = WKWebView(frame:.zero,configuration:configuration)
        attachment.setContent(attached)
        check(attached.frame == attachment.bounds,"A newly attached website immediately fills its existing native host")
        attachment.setFrameSize(NSSize(width:800,height:500))
        check(attached.frame == attachment.bounds,"Native host resizing immediately sizes its website without a deferred layout pass")
        let replacement = WKWebView(frame:.zero,configuration:configuration);attachment.setContent(replacement)
        check(replacement.frame == attachment.bounds && attached.superview == nil,"Replacing an attached document immediately fills the same viewport and detaches only the old view")
        let store = BrowserStore(isPrivate:true),suite = "Alcove.SavedSidebar.\(UUID())",defaults = UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite);store.shutdown()}
        store.onboardingVisible = false
        var settings = store.appearance;settings.animationsEnabled = false;store.appearance = settings
        let pageID = store.selectedID!;store.update(pageID){$0.url = "about:blank"}
        let web = store.view(for:pageID)
        var library = store.library;library.favoriteTabs = (0..<24).map {i in
            var tab = BrowserCore.Tab(title:"Favorite \(i)",url:"about:blank",pinned:true);tab.favorite = true;return tab
        };store.library = library
        for i in 0..<90 {
            var tab = BrowserCore.Tab(title:"Page \(i)",url:"about:blank",pinned:i < 45)
            if i < 20 {tab.folder = "Projects"};store.session.spaces[store.spaceIndex].tabs.append(tab)
        }
        let emptyFolder = try store.createTabFolder(name:"Empty folder",in:store.space.id)
        let nestedFolder = try store.createTabFolder(name: "Current projects", in: store.space.id, parent: "Projects")
        let row = SidebarSavedLayout(space: store.space).folders.first { $0.name == nestedFolder }
        check(row?.depth == 1, "The mounted sidebar receives the child folder with one level of indentation")
        let expandedHeight = SidebarSavedLayout(space: store.space).height(rowHeight: store.appearance.rowHeight)
        try store.setTabFolderExpanded("Projects", expanded: false, in: store.space.id)
        let collapsed = SidebarSavedLayout(space: store.space)
        check(!collapsed.folders.contains { $0.name == nestedFolder } &&
              collapsed.height(rowHeight: store.appearance.rowHeight) < expandedHeight,
              "Collapsed descendants no longer reserve pinned-sidebar space")
        try store.setTabFolderExpanded("Projects", expanded: true, in: store.space.id)
        let hosting = NSHostingView(rootView:BrowserUI(store:store,sidebarDefaults:defaults).environmentObject(UpdateController(installedTag:"test")))
        hosting.safeAreaRegions = [];hosting.sizingOptions = []
        let window = SidebarGestureFixtureWindow(contentRect:NSRect(x:0,y:0,width:1260,height:820),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.titlebarAppearsTransparent = true;window.titleVisibility = .hidden;window.contentView = hosting
        defer {window.contentView = nil;window.close()}
        for scale in [1.0,1.35] {
            settings.textScale = scale;store.appearance = settings
            for (width,height) in [(1260.0,820.0),(960,494),(760,400)] {
                window.setContentSize(NSSize(width:width,height:height));await settle();hosting.layoutSubtreeIfNeeded()
                let bounds = hosting.convert(hosting.bounds,to:nil),name = "\(Int(width))×\(Int(height)), text\(scale)"
                let scrolls = descendants(hosting,NSScrollView.self).filter {
                    let frame = $0.convert($0.bounds,to:nil)
                    return frame.width > 100 && frame.height > 30 && frame.maxX < 245
                }.sorted {$0.convert($0.bounds,to:nil).minY < $1.convert($1.bounds,to:nil).minY}
                check(scrolls.count == 3,"Favorites, Pinned and Today have independent native scroll regions at \(name)")
                check(scrolls.allSatisfy {let r = $0.convert($0.bounds,to:nil);return r.minY >= bounds.minY && r.maxY <= bounds.maxY && r.height >= 31},"All saved and daily scroll regions fit the viewport at \(name)")
                let menus = descendants(hosting,NSPopUpButton.self)
                check(menus.count >= 2 && menus.allSatisfy {let r = $0.convert($0.bounds,to:nil);return r.minY >= bounds.minY && r.maxY <= bounds.maxY},"Space and footer controls remain reachable at \(name)")
                if scrolls.count == 3 {
                    let today = scrolls[0],pins = scrolls[1],favorites = scrolls[2]
                    let pinnedFrame = pins.convert(pins.bounds,to:nil),pinOffset = pins.contentView.bounds.origin,favoriteOffset = favorites.contentView.bounds.origin
                    let travel = max(0,(today.documentView?.bounds.height ?? 0) - today.contentView.bounds.height)
                    today.contentView.scroll(to:NSPoint(x:0,y:travel));today.reflectScrolledClipView(today.contentView);await settle()
                    check(travel > 0 && today.contentView.bounds.origin.y > 0 && pins.convert(pins.bounds,to:nil) == pinnedFrame && pins.contentView.bounds.origin == pinOffset && favorites.contentView.bounds.origin == favoriteOffset,"Scrolling Today keeps the separate saved shelf fixed at \(name)")
                    check((pins.documentView?.bounds.height ?? 0) > pins.contentView.bounds.height,"Crowded folders and pins remain scrollable within their shelf at \(name)")
                }
                check(store.space.folderNames.contains(emptyFolder) && store.views[pageID] === web && web.window === window,"Resizing retains empty folders and the mounted page at \(name)")
                if let output = ProcessInfo.processInfo.environment["ALCOVE_SIDEBAR_SCREENSHOT_DIR"],scale == 1 {
                    let dir = URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) {
                        hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
                        try bitmap.representation(using:.png,properties:[:])?.write(to:dir.appendingPathComponent("sidebar-\(Int(width))x\(Int(height)).png"))
                    }
                }
            }
        }
        // Match the app's hosting and animated command submission path after the root already exists.
        window.setContentSize(NSSize(width:1260,height:820));await settle()
        hosting.sizingOptions = [.minSize]
        settings.animationsEnabled = true;store.appearance = settings
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw CocoaError(.fileNoSuchFile)}
        for index in 0..<2 {
            store.showCommand(new:true);await settle()
            store.navigate(fixture.appendingPathComponent("dynamic-\(index)").absoluteString)
            let id = store.selectedID!
            await settle()
            guard let added = store.views[id] else {check(false,"A newly selected tab constructs its native page");continue}
            for _ in 0..<500 {
                if (try? await added.evaluateJavaScript("document.getElementById('owned-form') !== null")) as? Bool == true {break}
                try await Task.sleep(for:.milliseconds(10))
            }
            await settle()
            let frame = added.convert(added.bounds,to:hosting)
            check(added.window === window && added.isDescendant(of:hosting) && frame.width > 300 && frame.height > 200,"New tab \(index + 1) mounts at a visible size without unrelated layout changes")
            var visible = !added.isHiddenOrHasHiddenAncestor,ancestor:NSView? = added
            while let current = ancestor {visible = visible && current.alphaValue > 0.99 && (current.layer?.opacity ?? 1) > 0.99;ancestor = current.superview}
            check(visible,"New command tab \(index + 1) finishes its native visibility transition")
            if added.window !== window || frame.height <= 200 {print("DYNAMIC FRAME",frame,"HOST",added.superview?.bounds as Any)}
        }
        do {
            let showcase = try store.createSpace(name: "Research")
            store.selectSpace(showcase)
            let showcaseTab = store.newTab(url: URL(string: "about:blank")!)
            store.update(showcaseTab) { $0.title = "Reading list" }
            try store.createTabFolder(name: "Projects", in: showcase)
            try store.createTabFolder(name: "Field notes", in: showcase, parent: "Projects", adding: showcaseTab)
            try store.createTabFolder(name: "Reference", in: showcase, parent: "Field notes")
            try store.createTabFolder(name: "Archive", in: showcase)
            store.select(showcaseTab)
            window.setContentSize(NSSize(width: 800, height: 540))
            await settle(); hosting.layoutSubtreeIfNeeded()
            let shelves = descendants(hosting, NSScrollView.self).filter {
                let frame = $0.convert($0.bounds, to: hosting)
                return frame.width > 100 && frame.height >= 25 && frame.maxX < 245
            }.sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
            // The empty Today scroll region can have no intrinsic width. Pinned is directly below Favorites.
            let pinnedHeight = shelves.dropLast().last?.bounds.height ?? 0
            let mounted = store.views[showcaseTab]?.window === window
            if pinnedHeight < 155 || !mounted {
                print("Sparse sidebar shelf heights: \(shelves.map { $0.bounds.height }), page mounted: \(mounted)")
            }
            check(pinnedHeight >= 155 && mounted,
                  "An empty Today section yields room for nested pins without disturbing the mounted page")
            if let output = ProcessInfo.processInfo.environment["ALCOVE_SIDEBAR_SCREENSHOT_DIR"],
               let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("sidebar-nested.png"))
                for title in ["Research notes", "Project roadmap", "Design review", "Reference library", "Reading list"] {
                    let id = store.newTab(url: URL(string: "about:blank")!)
                    store.update(id) { $0.title = title }
                }
                _ = store.advanceRecentTab(1)
                await settle(); hosting.layoutSubtreeIfNeeded()
                if let switcher = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: switcher)
                    try switcher.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("recent-tabs.png"))
                }
                store.cancelRecentTabSwitcher()
            }
        }

        if let gesture = descendants(hosting, SidebarSpaceSwipeRegion.Host.self).first,
           let first = store.session.spaces.first?.id, store.space.id != first {
            let second = store.space.id
            let originalTab = store.selectedID
            window.claimsKeyForGestures = true
            store.selectSpace(first)
            await settle()
            hosting.layoutSubtreeIfNeeded()
            let frame = gesture.convert(gesture.bounds.intersection(gesture.visibleRect), to: nil)
            check(frame.width > 100 && frame.height > 120 && frame.minY > 28 && frame.maxX < 245,
                  "The mounted Space gesture covers the sidebar tab shelves and excludes the footer and page")
            let shelf = NSPoint(x: frame.midX, y: frame.midY)
            let footer = NSPoint(x: frame.midX, y: frame.minY - 16)
            let page = NSPoint(x: frame.maxX + 90, y: frame.midY)
            func send(_ phase: CGScrollPhase, x: Int32 = 0, y: Int32 = 0,
                      at point: NSPoint, units: CGScrollEventUnit = .pixel,
                      flags: CGEventFlags = []) -> Bool {
                guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                            wheel1: y, wheel2: x, wheel3: 0) else { return false }
                // Avoid inheriting modifier flags from unrelated keyboard activity in the VM.
                cgEvent.flags = flags
                cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                let expected: NSEvent.Phase
                switch phase {
                case .began: expected = .began
                case .changed: expected = .changed
                case .ended: expected = .ended
                case .cancelled: expected = .cancelled
                case .mayBegin: expected = .mayBegin
                @unknown default: return false
                }
                guard let event = NSEvent(cgEvent: cgEvent), event.phase == expected,
                      event.hasPreciseScrollingDeltas == (units == .pixel) else {
                    check(false, "Core Graphics preserves the fixture's scroll phase and precision")
                    return false
                }
                return gesture.route(event, in: window, at: point) == nil
            }
            check(!send(.began, x: -22, at: footer) &&
                  !send(.changed, x: -95, at: shelf) && !send(.ended, at: shelf) && store.space.id == first,
                  "A gesture starting on the footer retains footer scrolling after crossing into the tab list")
            check(!send(.began, x: -25, at: page) &&
                  !send(.changed, x: -95, at: shelf) && !send(.ended, at: shelf) && store.space.id == first,
                  "A gesture starting on the webpage cannot switch Spaces by crossing the sidebar")
            check(!send(.began, y: -30, at: shelf) &&
                  !send(.changed, x: -110, y: -14, at: shelf) && !send(.ended, at: shelf) && store.space.id == first,
                  "Native vertical scrolling passes through the shelf without selecting a Space")
            check(!send(.began, x: -24, at: shelf, units: .line) &&
                  !send(.changed, x: -100, at: shelf, units: .line) && store.space.id == first,
                  "Coarse wheel events leave Space navigation untouched")
            check(!send(.began, x: -83, at: shelf, flags: .maskShift) &&
                  !send(.ended, at: shelf) && store.space.id == first,
                  "Using a modifier during a scroll gesture leaves Space navigation untouched")
            check(send(.began, x: -20, at: shelf) && send(.changed, x: -88, at: shelf) &&
                  store.space.id == first, "A mounted horizontal gesture tracks without switching before release")
            check(send(.ended, at: shelf) && store.space.id == second && store.selectedID == originalTab,
                  "Releasing a sidebar swipe selects the adjacent Space and its saved tab")
            await settle()
            check(send(.began, x: 24, at: shelf) && send(.changed, x: 89, at: shelf) &&
                  send(.cancelled, at: shelf) && store.space.id == second,
                  "Cancelling a native reverse swipe leaves the current Space selected")
            check(send(.began, x: 32, at: shelf) && send(.changed, x: 92, at: shelf) &&
                  send(.ended, at: shelf) && store.space.id == first,
                  "Swiping back across the mounted sidebar returns to the original Space")
            await settle()
            check(send(.began, x: -74, at: shelf), "A mounted sidebar can begin a swipe before its Space order changes")
            try store.moveSpace(second, to: 0)
            _ = send(.ended, at: shelf)
            check(store.space.id == first, "A swipe cannot select a Space moved to the opposite side before the next render")
            try store.moveSpace(second, to: 1)
            store.selectSpace(first)
            await settle()
            check(send(.began, x: -74, at: shelf), "A fresh stable sidebar can begin another native swipe")
            store.showCommand()
            await settle()
            check(!send(.ended, at: shelf) && store.space.id == first,
                  "Opening the command overlay cancels a pending Space switch")
            store.dismissCommand()
            await settle()
            let menu = NSMenu(title: "Owned sidebar menu")
            check(send(.began, x: -75, at: shelf), "A mounted native menu fixture begins with an active swipe")
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            check(!send(.changed, x: -22, at: shelf) && !send(.began, x: -82, at: shelf),
                  "Native menu tracking cancels the active swipe and rejects new gestures")
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            check(!send(.ended, at: shelf) && store.space.id == first,
                  "Ending native menu tracking cannot commit a swipe started before the menu")
            if let current = store.currentView, let source = try? BoostEditSource(store: store, web: current) {
                check(send(.began, x: -74, at: shelf), "A fresh swipe can start after the menu stops tracking")
                let boost = SiteBoost(content: BoostContent(name: "Owned swipe picker", host: source.host))
                store.boostPicker = BoostPickerSession(source: source, boost: boost)
                _ = send(.ended, at: shelf)
                check(store.space.id == first && store.boostPicker?.source === source,
                      "Opening the element picker preserves its Space and mounted document during a swipe")
                store.cancelBoostPicker()
            } else {
                check(false, "The swipe interruption probe has an owned web document for its element picker")
            }
            store.selectSpace(second)
            await settle()
            window.claimsKeyForGestures = false
        } else {
            check(false, "The multi-Space browser exposes a native sidebar gesture region")
        }
        let splitTabs = (1...4).map { index in
            store.newTab(url: URL(string: "about:blank#split-layout-\(index)"))
        }
        store.select(splitTabs[0])
        for id in splitTabs.dropFirst() { store.openInSplit(id) }
        await settle(); hosting.layoutSubtreeIfNeeded()
        let pages = splitTabs.compactMap { store.views[$0] }
        let pageTitles = ["Field Notes", "Project Plan", "Reference", "Reading List"]
        for (index, page) in pages.enumerated() {
            let title = pageTitles[index]
            page.loadHTMLString("""
                <!doctype html><meta name="viewport" content="width=device-width"><title>\(title)</title>
                <style>body { background: #f7f4ee; color: #202031; font: 16px system-ui; margin: 20px; }
                h1 { font-size: clamp(16px, 6vw, 27px); font-weight: 600; } input { width: min(100%, 14em); box-sizing: border-box; }</style>
                <h1>\(title)</h1><input id="split-note" aria-label="Note">
                """, baseURL: nil)
        }
        for (index, page) in pages.enumerated() {
            for _ in 0..<100 {
                if (try? await page.evaluateJavaScript("document.getElementById('split-note') !== null")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try await page.evaluateJavaScript("document.getElementById('split-note').value = 'Draft \(index + 1)'")
        }
        for (size, axis) in [(NSSize(width: 760, height: 400), BrowserSplitAxis.columns),
                             (NSSize(width: 960, height: 540), BrowserSplitAxis.rows)] {
            if store.splitLayout?.axis != axis { store.flipSplit() }
            window.setContentSize(size); await settle(); hosting.layoutSubtreeIfNeeded()
            let frames = pages.map { $0.convert($0.bounds, to: hosting) }
            check(pages.count == 4 && zip(splitTabs, pages).allSatisfy { id, page in
                store.views[id] === page && page.window === window && page.isDescendant(of: hosting)
            }, "Four \(axis) use the same mounted WebKit views after resizing and rotation")
            let ordered = zip(frames, frames.dropFirst()).allSatisfy { a, b in
                if axis == .columns { return a.maxX <= b.minX + 1 }
                return hosting.isFlipped ? a.maxY <= b.minY + 1 : b.maxY <= a.minY + 1
            }
            let hostedBounds = hosting.bounds.insetBy(dx: -1, dy: -1)
            let allVisible = frames.allSatisfy { $0.width >= 64 && $0.height >= 64 && hostedBounds.contains($0) }
            if !ordered || !allVisible { print("Split \(axis) frames: \(frames), host: \(hostedBounds)") }
            check(frames.count == 4 && ordered && allVisible, "Four \(axis) remain visible inside the window at \(Int(size.width))×\(Int(size.height))")
        }
        store.flipSplit()
        window.setContentSize(NSSize(width: 1260, height: 820)); await settle(); hosting.layoutSubtreeIfNeeded()
        if let split = descendants(hosting, NSSplitView.self).first(where: { $0.isVertical && $0.arrangedSubviews.count == 4 }) {
            let before = split.arrangedSubviews[0].frame.maxX
            split.setPosition(before + 20, ofDividerAt: 0)
            await settle(); hosting.layoutSubtreeIfNeeded()
            let moved = split.arrangedSubviews[0].frame.maxX
            store.focusPane(splitTabs[2])
            await settle(); hosting.layoutSubtreeIfNeeded()
            check(abs(moved - before) >= 8 && abs(split.arrangedSubviews[0].frame.maxX - moved) <= 2,
                  "The native divider resizes the panes and keeps its position after a focus change")
        } else { check(false, "Four columns expose a native, movable divider") }
        var drafts: [String] = []
        for page in pages {
            let draft = try await page.evaluateJavaScript("document.getElementById('split-note').value") as? String
            drafts.append(draft ?? "")
        }
        check(drafts == ["Draft 1", "Draft 2", "Draft 3", "Draft 4"], "All four unsaved forms survive two orientation changes and divider resizing")
        if let output = ProcessInfo.processInfo.environment["ALCOVE_SIDEBAR_SCREENSHOT_DIR"],
           let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("four-pane.png"))
        }
        _ = try store.createSpace(name: "Empty Pinned fixture")
        window.setContentSize(NSSize(width: 800, height: 540))
        await settle()
        hosting.layoutSubtreeIfNeeded()
        let emptyShelfOverflow = descendants(hosting, NSScrollView.self).contains { scroll in
            let frame = scroll.convert(scroll.bounds, to: hosting)
            return frame.maxX < 245 && frame.height >= 25 && frame.height <= 40 &&
                (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 1
        }
        check(!emptyShelfOverflow, "An empty pinned shelf has no overflowing scroll view")
        print("Sidebar organization layout checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
