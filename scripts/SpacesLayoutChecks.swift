import AppKit
import SwiftUI
import WebKit
import BrowserCore

@MainActor final class SpacesLayoutApplication: NSApplication {
    var fixtureWindow: NSWindow?
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}
@main struct SpacesLayoutChecks {
    @MainActor static func main() async throws {
        let application = SpacesLayoutApplication.shared as! SpacesLayoutApplication
        application.setActivationPolicy(.prohibited); setbuf(stdout,nil)
        var failures = 0
        func check(_ value:Bool,_ name:String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func settle() async { for _ in 0..<15 { try? await Task.sleep(for:.milliseconds(10)) } }
        let store = BrowserStore(isPrivate:true)
        let suite = "Alcove.SpacesLayout.\(UUID())"
        let testDefaults = UserDefaults(suiteName:suite)!
        defer { testDefaults.removePersistentDomain(forName:suite) }
        var appearance = store.appearance; appearance.animationsEnabled = false; store.appearance = appearance
        let originalSpace = store.space.id, pageID = store.selectedID!
        for index in 0..<8 { _ = try store.createSpace(name:"Research \(index) — a long descriptive name") }
        store.selectSpace(originalSpace); store.update(pageID) { $0.url = "about:blank" }
        let web = store.view(for:pageID)
        let hosting = NSHostingView(rootView:BrowserUI(store:store,sidebarDefaults:testDefaults).environmentObject(UpdateController(installedTag:"test")))
        hosting.safeAreaRegions = []; hosting.sizingOptions = []
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1260,height:820),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.contentView = hosting
        await settle(); web.loadHTMLString("<input id='owned' value='unchanged'>",baseURL:nil)
        var ready = false
        for _ in 0..<500 where !ready {
            ready = (try? await web.evaluateJavaScript("document.getElementById('owned') !== null")) as? Bool == true
            if !ready { try await Task.sleep(for:.milliseconds(10)) }
        }
        check(ready,"Owned page is ready before Space manager layout assertions")
        let identity = store.documentIdentity(for:web)
        for (width,height) in [(1260.0,820.0),(960,494),(760,400),(800,540)] {
            window.setContentSize(NSSize(width:width,height:height))
            for pinned in [true,false] {
            store.sidebarVisible = pinned
            for scale in [1.0,1.35] {
                var settings = store.appearance; settings.textScale = scale; store.appearance = settings
                store.showSpacesManager(); await settle(); hosting.layoutSubtreeIfNeeded()
                let frame = web.convert(web.bounds,to:hosting)
                check(frame.minX >= 400 && frame.maxX <= hosting.bounds.maxX + 1 && frame.width > 0, "Space manager shares the actual viewport with the mounted page at \(Int(width))×\(Int(height)), text\(scale), pinned\(pinned)")
                check(window.attachedSheet == nil && store.views[pageID] === web && store.views.count == 1 && store.documentIdentity(for:web) === identity, "Space previews create no modal sheet, duplicate website or new document")
                store.presentedPanel = nil; await settle()
                let value = ready ? (try? await web.evaluateJavaScript("document.getElementById('owned').value")) as? String : nil
                let restoredFrame = web.convert(web.bounds,to:hosting)
                check(value == "unchanged" && web.superview != nil && store.session.selectedSpace == originalSpace && restoredFrame.minX <= (pinned ? 260 : 20), "Closing the manager preserves the original form, mounted page and selected Space")
            }
            }
        }
        store.showSpacesManager()
        BrowserUI(store:store,sidebarDefaults:testDefaults).sheetPanel.wrappedValue = nil
        check(store.presentedPanel == .spaces, "A late sheet-dismiss callback cannot erase the in-window manager")
        store.presentedPanel = nil
        let delegate = AppDelegate(); delegate.windows[window] = store; application.fixtureWindow = window
        delegate.buildMenu()
        let spacesMenu = NSApp.mainMenu?.items.first(where:{$0.title == "Spaces"})?.submenu
        if let spacesMenu { spacesMenu.delegate?.menuNeedsUpdate?(spacesMenu) }
        let menuIDs = spacesMenu?.items.compactMap {$0.representedObject as? UUID} ?? []
        check(spacesMenu != nil && menuIDs == store.session.spaces.map(\.id), "The native Spaces menu exposes every Space in sidebar order")
        try store.renameSpace(originalSpace,name:"Updated menu name")
        if let spacesMenu { spacesMenu.delegate?.menuNeedsUpdate?(spacesMenu) }
        check(spacesMenu?.items.contains(where:{$0.title.hasPrefix("Updated menu name") && ($0.representedObject as? UUID) == originalSpace}) == true, "Native menu names refresh after editing rather than retaining a stale snapshot")
        if let output = ProcessInfo.processInfo.environment["ALCOVE_SPACES_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for index in store.session.spaces.indices {
                store.session.spaces[index].theme = SidebarTheme.allCases[index % SidebarTheme.allCases.count].rawValue
                var pin = BrowserCore.Tab(title:"Project notes",url:"https://example.com/notes"); pin.pinned = true
                store.session.spaces[index].tabs.append(pin)
            }
            func capture(_ name:String,width:Double,height:Double) async throws {
                let rendered = NSHostingView(rootView:SpacesPanel(store:store,topInset:34).environment(\.colorScheme,.dark))
                rendered.safeAreaRegions = []; rendered.sizingOptions = []
                let renderWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[],backing:.buffered,defer:false)
                renderWindow.isReleasedWhenClosed = false; renderWindow.contentView = rendered
                defer { renderWindow.contentView = nil; renderWindow.close() }
                await settle(); rendered.layoutSubtreeIfNeeded()
                guard let bitmap = rendered.bitmapImageRepForCachingDisplay(in:rendered.bounds) else { throw CocoaError(.fileWriteUnknown) }
                rendered.effectiveAppearance.performAsCurrentDrawingAppearance { rendered.cacheDisplay(in:rendered.bounds,to:bitmap) }
                guard let png = bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to:directory.appendingPathComponent(name)); print("Saved native snapshot: \(name)")
            }
            store.message = nil; store.showSpacesManager(); try await capture("spaces-open-native.png",width:780,height:650)
            _ = try store.deleteSpace(store.session.spaces.last!.id)
            store.showSpacesManager(deleted:true); try await capture("spaces-deleted-short-native.png",width:520,height:360)
        }
        application.fixtureWindow = nil; delegate.windows = [:]
        store.shutdown(); window.contentView = nil; window.close()
        exit(failures == 0 ? 0 : 1)
    }
}
