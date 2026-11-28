import AppKit
import SwiftUI
import ApplicationServices
import BrowserCore
import CryptoKit

private enum OwnedBrowserAXError: Error { case environment, childNotReady, missingControl(String), windowUnavailable, foreignElement }
@main struct OwnedBrowserAXChecks {
    static func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        return (AXUIElementCopyAttributeValue(element, name as CFString, &value), value)
    }
    static func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name).1 as? String ?? "" }
    @MainActor static func all<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { all($0, type) }
    }
    @MainActor static func child(_ root: URL) throws {
        NSApplication.shared.setActivationPolicy(.regular)
        var keyRequests = 0
        let dataRoot = root.appendingPathComponent("private-must-not-exist")
        let store = BrowserStore(isPrivate: true, dataRoot: dataRoot, keyProvider: { _ in keyRequests += 1; return SymmetricKey(size: .bits256) })
        store.onboardingVisible = false; store.preferences.onboardingCompleted = true; store.preferences.automaticUpdateChecks = false
        let tab = try store.createEasel(title: "Owned accessibility canvas")
        let note = try EaselItem(frame: EaselFrame(x: 70, y: 70, width: 300, height: 210), content: .note(text: "Original owned AX note"))
        _ = try store.editEasel(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.insert(note)])
        let suite = "Alcove.OwnedAX." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defaults.set(236.0, forKey: "sidebarWidth")
        let host = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "owned-ax-qa")))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Alcove AX Owned Browser"; window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        var originalEditor: EaselNoteTextView?
        var observations = 0
        _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("STOP").path) {
                    store.shutdown(); window.contentView = nil; window.close(); UserDefaults.standard.removePersistentDomain(forName: suite)
                    try? Data("clean".utf8).write(to: root.appendingPathComponent("cleaned"), options: .atomic)
                    exit(0)
                }
                observations += 1
                if observations > 1600 { store.shutdown(); window.close(); UserDefaults.standard.removePersistentDomain(forName: suite); exit(4) }
                host.layoutSubtreeIfNeeded()
                let canvas = all(host, EaselCanvasView.self).first
                let editor = canvas?.cards[note.id]?.noteView
                if originalEditor == nil { originalEditor = editor }
                var saved = ""
                if case .note(let text) = store.easelContext(for: tab)?.easel.items.first?.content { saved = text }
                let bars = all(host, EaselDrawingControls.self)
                let toolbarFits = !bars.isEmpty && bars.allSatisfy { bar in bar.subviews.filter { !$0.isHidden }.allSatisfy { $0.frame.minX >= -0.5 && $0.frame.maxX <= bar.bounds.width + 0.5 } }
                let width = (all(host, SidebarResizeHandle.Handle.self).first?.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
                let state: [String: Any] = ["ready": canvas != nil && window.isKeyWindow, "tool": canvas?.drawingTool.rawValue ?? "missing", "savedNote": saved, "editorText": editor?.string ?? "missing", "noteFocused": window.firstResponder === editor, "sameEditor": editor != nil && editor === originalEditor, "sidebarWidth": width, "windowWidth": window.frame.width, "toolbarFits": toolbarFits, "keyRequests": keyRequests, "privateRootExists": FileManager.default.fileExists(atPath: dataRoot.path), "websiteViews": store.views.count, "draftFailures": store.easelDrafts.failures(in: store).count, "noteID": store.easelContext(for: tab)?.easel.items.first?.id.uuidString ?? "missing"]
                if let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { try? bytes.write(to: root.appendingPathComponent("state.json"), options: .atomic) }
            }
        }
        NSApplication.shared.run()
    }
    @MainActor static func parent() throws -> Int32 {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL"): \(name)") }
        guard AXIsProcessTrusted() else { print("ENVIRONMENT_UNAVAILABLE preexisting AX grant absent; no permission requested"); return 3 }
        check(true, "The hosted client already has public accessibility access")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.BrowserAX." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["--owned-child", root.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        var cleaned = false
        func stop() {
            try? Data().write(to: root.appendingPathComponent("STOP"), options: .atomic)
            for _ in 0..<300 { if !child.isRunning { break }; Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate() }
            child.waitUntilExit(); cleaned = FileManager.default.fileExists(atPath: root.appendingPathComponent("cleaned").path)
        }
        defer { if child.isRunning { stop() } }
        func state() -> [String: Any] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return value
        }
        func until(_ predicate: ([String: Any]) -> Bool) -> [String: Any] {
            for _ in 0..<1000 { let value = state(); if predicate(value) { return value }; if !child.isRunning { return value }; Thread.sleep(forTimeInterval: 0.01) }
            return state()
        }
        let initial = until { $0["ready"] as? Bool == true }
        guard initial["ready"] as? Bool == true else { throw OwnedBrowserAXError.childNotReady }
        check(true, "A separate owned process mounts the real BrowserUI in an active window")
        let pid = child.processIdentifier, app = AXUIElementCreateApplication(child.processIdentifier)
        let (error, value) = attribute(app, kAXWindowsAttribute)
        guard error == .success, let window = (value as? [AXUIElement])?.first else { throw OwnedBrowserAXError.windowUnavailable }
        func elements() throws -> [AXUIElement] {
            var queue = [(window, 0)], result: [AXUIElement] = []
            while !queue.isEmpty && result.count < 400 {
                let (element, depth) = queue.removeFirst(); var actual: pid_t = 0
                guard AXUIElementGetPid(element, &actual) == .success && actual == pid else { throw OwnedBrowserAXError.foreignElement }
                result.append(element)
                if depth < 32, let children = attribute(element, kAXChildrenAttribute).1 as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
            }
            return result
        }
        var nodes = try elements()
        func label(_ element: AXUIElement) -> [String] { [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), string(element, kAXHelpAttribute)] }
        func find(_ text: String) throws -> AXUIElement {
            if let element = nodes.first(where: { label($0).contains(text) }) { return element }
            for element in nodes { print("OWNED_AX_NODE", string(element, kAXRoleAttribute), label(element), String(string(element, kAXValueAttribute).prefix(80))) }
            throw OwnedBrowserAXError.missingControl(text)
        }
        check(!nodes.isEmpty, "The public AX tree contains only elements from the owned browser process")
        let note = try find("Canvas note"), pen = try find("Pen tool"), select = try find("Select tool"), splitter = try find("Sidebar width")
        check(string(note, kAXValueAttribute) == "Original owned AX note", "Public accessibility exposes the actual native note text")
        var writable = DarwinBoolean(false)
        let canWrite = AXUIElementIsAttributeSettable(note, kAXValueAttribute as CFString, &writable)
        check(canWrite == .success && writable.boolValue, "The native note advertises an editable public AX value")
        let focused = AXUIElementSetAttributeValue(note, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let focusState = until { $0["noteFocused"] as? Bool == true }
        check(focused == .success && focusState["noteFocused"] as? Bool == true, "A public AX focus action reaches the real note responder")
        let edited = "A note changed through public accessibility 🌱"
        let changed = AXUIElementSetAttributeValue(note, kAXValueAttribute as CFString, edited as CFString)
        let editState = until { $0["editorText"] as? String == edited }
        check(changed == .success && editState["editorText"] as? String == edited, "Actual cross-process AX editing changes the complete Unicode note")
        let pressed = AXUIElementPerformAction(pen, kAXPressAction as CFString)
        let penState = until { $0["tool"] as? String == "pen" && $0["savedNote"] as? String == edited }
        check(pressed == .success && penState["tool"] as? String == "pen", "Public AX press selects the actual Pen tool")
        check(penState["savedNote"] as? String == edited && penState["noteID"] as? String == initial["noteID"] as? String && penState["sameEditor"] as? Bool == true, "Selecting a tool saves AX-edited text without replacing its item or native editor")
        let selected = AXUIElementPerformAction(select, kAXPressAction as CFString)
        let selectState = until { $0["tool"] as? String == "select" }
        check(selected == .success && selectState["tool"] as? String == "select", "Public AX press returns to Select mode")
        let resizedSidebar = AXUIElementSetAttributeValue(splitter, kAXValueAttribute as CFString, NSNumber(value: 340))
        let sidebarState = until { abs(($0["sidebarWidth"] as? Double ?? 0) - 340) < 1 }
        check(resizedSidebar == .success && abs((sidebarState["sidebarWidth"] as? Double ?? 0) - 340) < 1, "Public AX resizing changes the actual sidebar width")
        var size = CGSize(width: 660, height: 640)
        let resizedWindow = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        let narrow = until { abs(($0["windowWidth"] as? Double ?? 0) - 660) < 1 && $0["toolbarFits"] as? Bool == true }
        check(resizedWindow == .success && abs((narrow["windowWidth"] as? Double ?? 0) - 660) < 1 && narrow["toolbarFits"] as? Bool == true, "Actual AX window resizing keeps drawing controls within the narrow pane")
        check(narrow["savedNote"] as? String == edited && narrow["sameEditor"] as? Bool == true, "Cross-process sidebar/window resizing preserves AX-edited text and focus identity")
        nodes = try elements(); _ = try find("Drawing tools and style")
        check(true, "The compact drawing menu remains exposed through public AX")
        check(narrow["keyRequests"] as? Int == 0 && narrow["privateRootExists"] as? Bool == false && narrow["websiteViews"] as? Int == 0 && narrow["draftFailures"] as? Int == 0, "The owned private accessibility flow uses no key, browser files, website view or failed draft")
        try JSONSerialization.data(withJSONObject: narrow, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALCOVE_AX_EVIDENCE_DIR"]!).appendingPathComponent("owned-state.json"), options: .atomic)
        stop()
        check(cleaned && !child.isRunning && child.terminationStatus == 0, "The owned browser process closes its test window and retires its private store")
        print("Owned browser accessibility checks: \(checks) checked, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { print("ENVIRONMENT_UNAVAILABLE hosted native probe only"); exit(3) }
        do {
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--owned-child" { try child(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)); return }
            exit(try parent())
        } catch { print("FAIL: owned browser AX fixture", error); exit(1) }
    }
}
