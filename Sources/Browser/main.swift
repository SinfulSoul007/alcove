import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = BrowserStore()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Browser"; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 800, height: 540)
        window.contentView = NSHostingView(rootView: BrowserUI(store: store))
        window.center(); window.makeKeyAndOrderFront(nil)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { store.flush() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); item.title = title; let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = self; menu.addItem(item)
        }
        let app = submenu("Browser")
        add(app, "About Browser", #selector(about), "")
        app.addItem(.separator()); add(app, "Quit Browser", #selector(quit), "q")
        let file = submenu("File")
        add(file, "New Tab", #selector(newTab), "t"); add(file, "New Space…", #selector(newSpace), "n", [.command, .shift]); add(file, "Open Location…", #selector(location), "l"); add(file, "Close Tab", #selector(closeTab), "w")
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let view = submenu("View")
        add(view, "Reload", #selector(reload), "r"); add(view, "Toggle Sidebar", #selector(sidebar), "s"); add(view, "Toggle Split View", #selector(split), "d", [.command, .shift])
        add(view, "Pin / Unpin Tab", #selector(pin), "p", [.command, .shift])
        let history = submenu("History")
        add(history, "Back", #selector(back), "["); add(history, "Forward", #selector(forward), "]")
        let windowMenu = submenu("Window"); NSApp.windowsMenu = windowMenu
        let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"); windowMenu.addItem(minimize)
        NSApp.mainMenu = main
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Browser", .applicationVersion: "0.1 Preview", .credits: NSAttributedString(string: "An independent, open-source WebKit browser for Mac.")]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func newTab() { store.showCommand(new: true) }
    @objc func newSpace() { store.addSpace() }
    @objc func location() { store.showCommand() }
    @objc func closeTab() { if let id = store.selectedID { store.close(id) } }
    @objc func reload() { store.currentView?.reload() }
    @objc func sidebar() { store.sidebarVisible.toggle() }
    @objc func split() { store.toggleSplit() }
    @objc func pin() { if let id = store.selectedID { store.togglePin(id) } }
    @objc func back() { store.currentView?.goBack() }
    @objc func forward() { store.currentView?.goForward() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
