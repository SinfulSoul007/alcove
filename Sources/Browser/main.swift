import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow: BrowserStore] = [:]
    var normalWindow: NSWindow?
    var activeStore: BrowserStore? { (NSApp.keyWindow.flatMap { windows[$0] }) ?? (NSApp.mainWindow.flatMap { windows[$0] }) ?? normalWindow.flatMap { windows[$0] } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); buildMenu(); openWindow(isPrivate: false); NSApp.activate(ignoringOtherApps: true)
    }
    func openWindow(isPrivate: Bool) {
        if !isPrivate, let normalWindow { normalWindow.makeKeyAndOrderFront(nil); return }
        let store = BrowserStore(isPrivate: isPrivate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = isPrivate ? "Alcove — Private" : "Alcove"; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 800, height: 540)
        window.contentView = NSHostingView(rootView: BrowserUI(store: store))
        windows[window] = store
        if !isPrivate { normalWindow = window }
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let store = windows.removeValue(forKey: window) {
            store.flush(); store.archiveTimer?.invalidate()
            for id in Array(store.views.keys) { store.discardView(id) }
        }
        if normalWindow === window { normalWindow = nil }
    }
    func applicationWillTerminate(_ notification: Notification) { for store in windows.values { store.flush() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        openWindow(isPrivate: false)
        guard let normalWindow, let store = windows[normalWindow] else { return }
        for url in urls where ["http", "https"].contains(url.scheme?.lowercased() ?? "") { store.newTab(url: url) }
    }
    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); item.title = title; let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = self; menu.addItem(item)
        }
        let app = submenu("Alcove")
        add(app, "About Alcove", #selector(about), ""); add(app, "Settings…", #selector(settings), ",")
        app.addItem(.separator()); add(app, "Quit Alcove", #selector(quit), "q")
        let file = submenu("File")
        add(file, "New Tab", #selector(newTab), "t"); add(file, "New Private Window", #selector(privateWindow), "n", [.command, .shift])
        add(file, "New Space…", #selector(newSpace), "n", [.command, .option]); add(file, "Open Location…", #selector(location), "l")
        add(file, "Import Preview Session…", #selector(importSession), "")
        add(file, "Close Tab", #selector(closeTab), "w"); add(file, "Reopen Closed Tab", #selector(reopen), "t", [.command, .shift])
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)) }
        add(edit, "Find in Page…", #selector(find), "f")
        let view = submenu("View")
        add(view, "Reload", #selector(reload), "r"); add(view, "Toggle Sidebar", #selector(sidebar), "s")
        add(view, "Toggle Split View", #selector(split), "d", [.command, .shift]); add(view, "Pin / Unpin Tab", #selector(pin), "p", [.command, .shift])
        add(view, "Zoom In", #selector(zoomIn), "="); add(view, "Zoom Out", #selector(zoomOut), "-"); add(view, "Actual Size", #selector(resetZoom), "0")
        let library = submenu("Library")
        add(library, "Show Library", #selector(showLibrary), "b", [.command, .shift]); add(library, "Bookmark This Page", #selector(bookmark), "d")
        let history = submenu("History")
        add(history, "Back", #selector(back), "["); add(history, "Forward", #selector(forward), "]")
        let window = submenu("Window"); NSApp.windowsMenu = window
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.mainMenu = main
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Alcove", .applicationVersion: "0.2 Unsigned Preview", .credits: NSAttributedString(string: "An independent, open-source WebKit browser for Mac. Not notarized by Apple.")]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func newTab() { activeStore?.showCommand(new: true) }
    @objc func privateWindow() { openWindow(isPrivate: true) }
    @objc func importSession() { activeStore?.importLegacySession() }
    @objc func newSpace() { activeStore?.addSpace() }
    @objc func location() { activeStore?.showCommand() }
    @objc func closeTab() { if let store = activeStore, let id = store.selectedID { store.close(id) } }
    @objc func reopen() { activeStore?.reopenClosed() }
    @objc func reload() { activeStore?.currentView?.reload() }
    @objc func sidebar() { activeStore?.sidebarVisible.toggle() }
    @objc func split() { activeStore?.toggleSplit() }
    @objc func pin() { if let store = activeStore, let id = store.selectedID { store.togglePin(id) } }
    @objc func back() { activeStore?.currentView?.goBack() }
    @objc func forward() { activeStore?.currentView?.goForward() }
    @objc func find() { activeStore?.findVisible = true }
    @objc func zoomIn() { activeStore?.zoom(0.1) }
    @objc func zoomOut() { activeStore?.zoom(-0.1) }
    @objc func resetZoom() { activeStore?.currentView?.pageZoom = 1 }
    @objc func showLibrary() { activeStore?.libraryVisible = true }
    @objc func bookmark() { activeStore?.addBookmark() }
    @objc func settings() { activeStore?.settingsVisible = true }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
