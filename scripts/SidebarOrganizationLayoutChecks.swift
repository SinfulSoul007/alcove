import AppKit
import SwiftUI
import WebKit
import BrowserCore

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
        let hosting = NSHostingView(rootView:BrowserUI(store:store,sidebarDefaults:defaults).environmentObject(UpdateController(installedTag:"test")))
        hosting.safeAreaRegions = [];hosting.sizingOptions = []
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1260,height:820),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
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
        print("Sidebar organization layout checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
