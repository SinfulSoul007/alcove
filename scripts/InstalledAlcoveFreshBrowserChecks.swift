import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit

private enum InstalledSmokeError: Error { case environment(String), launch, wrongApp, timeout(String), ax(String, Int32), missing(String), protection }
@main struct InstalledAlcoveFreshBrowserChecks {
    @MainActor static var owned: [NSRunningApplication] = []
    @MainActor static var checks = 0
    @MainActor static var evidence: URL!
    @MainActor static var openingObserved = false
    @MainActor static var openingCaptured = false
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func text(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    static func labels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute].map { text(element, $0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    @MainActor static func check(_ ok: Bool, _ name: String) throws {
        guard ok else { throw InstalledSmokeError.timeout(name) }
        checks += 1; print("PASS:", name)
    }
    @MainActor static func pause(_ milliseconds: Int = 100) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    @MainActor static func launch(_ url: URL) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.promptsUserIfNeeded = false
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let app { continuation.resume(returning: app) } else { continuation.resume(throwing: error ?? InstalledSmokeError.launch) }
            }
        }
        guard app.bundleURL?.standardizedFileURL == url.standardizedFileURL else { throw InstalledSmokeError.wrongApp }
        owned.append(app); return app
    }
    @MainActor static func nodes(_ app: NSRunningApplication, menus: Bool = false) throws -> [AXUIElement] {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 3)
        var queue: [(AXUIElement, Int)] = []
        if menus, let menu = attribute(application, kAXMenuBarAttribute) { queue.append((unsafeBitCast(menu, to: AXUIElement.self), 0)) }
        if let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] { queue.append(contentsOf: windows.map { ($0, 0) }) }
        var result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 600 {
            let (element, depth) = queue.removeFirst(); var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success && pid == app.processIdentifier else { continue }
            result.append(element)
            if depth < 32, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        return result
    }
    static func descendantLabels(_ root: AXUIElement, ownedPID: pid_t) -> [String] {
        var queue = [(root, 0)], result: [String] = [], visited = 0
        while !queue.isEmpty && visited < 150 {
            let (element, depth) = queue.removeFirst(); visited += 1
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success && pid == ownedPID else { continue }
            result.append(contentsOf: labels(element))
            if depth < 20, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        return result
    }
    @MainActor static func find(_ label: String, in app: NSRunningApplication, menus: Bool = false) async throws -> AXUIElement {
        for _ in 0..<100 {
            let all = try nodes(app, menus: menus)
            if all.contains(where: { labels($0).contains("Skip opening animation") }) {
                openingObserved = true
                if !openingCaptured {
                    openingCaptured = true
                    try await capture(app, "installed-opening-active")
                    await pause(450)
                    try await capture(app, "installed-opening-progress")
                }
            }
            if let found = all.first(where: { labels($0).contains(label) && (label != "Continue" || attribute($0, kAXEnabledAttribute) as? Bool == true) }) { return found }
            if app.isTerminated { throw InstalledSmokeError.launch }
            await pause()
        }
        for element in try nodes(app, menus: menus) { print("OWNED_INSTALLED_AX", text(element, kAXRoleAttribute), labels(element).map { String($0.prefix(110)) }) }
        throw InstalledSmokeError.missing(label)
    }
    static func press(_ element: AXUIElement, _ name: String) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw InstalledSmokeError.ax(name, result.rawValue) }
    }
    @MainActor static func capture(_ app: NSRunningApplication, _ name: String, windowTitle: String? = nil) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw InstalledSmokeError.environment("preexisting compositor access absent") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.frame.width >= 400 && $0.frame.height >= 300 && (windowTitle == nil || $0.title == windowTitle) }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { throw InstalledSmokeError.timeout("owned installed window") }
        let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width.rounded(.up)); configuration.height = Int(window.frame.height.rounded(.up)); configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw InstalledSmokeError.launch }
        try png.write(to: evidence.appendingPathComponent(name + ".png"), options: .atomic)
        let receipt: [String: Any] = ["case": name, "method": "SCScreenshotManager.desktopIndependentWindow", "ownedProcessID": app.processIdentifier, "ownedWindowID": window.windowID, "width": image.width, "height": image.height, "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), "screenRecordingAlreadyGranted": true]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
        print("OWNED_INSTALLED_CAPTURE", name, image.width, image.height)
    }
    @MainActor static func fileMenu(in app: NSRunningApplication) async throws -> AXUIElement {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<100 {
            if let value = attribute(application, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let bar = unsafeBitCast(value, to: AXUIElement.self)
                for item in attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(item, &pid) == .success && pid == app.processIdentifier else { continue }
                    if text(item, kAXTitleAttribute) == "File" || text(item, kAXDescriptionAttribute) == "File" { return item }
                }
            }
            await pause()
        }
        throw InstalledSmokeError.missing("File menu")
    }
    @MainActor static func menuItem(_ name: String, below menu: AXUIElement, app: NSRunningApplication) async throws -> AXUIElement {
        for _ in 0..<100 {
            var queue = [(menu, 0)], visited = 0
            while !queue.isEmpty && visited < 100 {
                let (item, depth) = queue.removeFirst(); visited += 1
                var pid: pid_t = 0
                guard AXUIElementGetPid(item, &pid) == .success && pid == app.processIdentifier else { continue }
                if text(item, kAXTitleAttribute) == name || text(item, kAXDescriptionAttribute) == name { return item }
                if depth < 6, let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
            }
            await pause()
        }
        throw InstalledSmokeError.missing("File → " + name)
    }
    @MainActor static func typeName(_ name: String, in app: NSRunningApplication) async throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw InstalledSmokeError.launch }
            event.flags = .maskCommand; event.postToPid(app.processIdentifier)
        }
        await pause()
        let units = Array(name.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw InstalledSmokeError.launch }
            units.withUnsafeBufferPointer { buffer in event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!) }
            event.postToPid(app.processIdentifier)
        }
        await pause(300)
    }
    @MainActor static func key(_ code: CGKeyCode, flags: CGEventFlags = [], app: NSRunningApplication) async throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw InstalledSmokeError.launch }
            event.flags = flags; event.postToPid(app.processIdentifier)
        }
        await pause(250)
    }
    @MainActor static func navigate(_ path: String, in app: NSRunningApplication) async throws {
        try await key(37, flags: .maskCommand, app: app)
        let address = try await find("Search or Enter URL…", in: app)
        guard AXUIElementSetAttributeValue(address, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { throw InstalledSmokeError.missing("focused browser address") }
        try await typeName(path, in: app)
        try await key(36, app: app)
    }
    @MainActor static func close(_ app: NSRunningApplication) async -> Bool {
        if app.isTerminated { return true }
        let requested = app.terminate()
        for _ in 0..<100 { if app.isTerminated { return requested }; await pause() }
        return false
    }
    @MainActor static func cleanup() async {
        for app in owned where !app.isTerminated {
            if !(await close(app)) { print("OWNED_INSTALLED_CLEANUP_FORCE", app.processIdentifier); app.forceTerminate() }
        }
    }
    @MainActor static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", AXIsProcessTrusted() else { throw InstalledSmokeError.environment("hosted client must already have AX access") }
        guard let path = ProcessInfo.processInfo.environment["ALCOVE_INSTALLED_APP"], let directory = ProcessInfo.processInfo.environment["ALCOVE_INSTALLED_EVIDENCE"] else { throw InstalledSmokeError.environment("missing fixed test paths") }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.lastPathComponent == "Alcove.app", url.deletingLastPathComponent().lastPathComponent == "Applications" else { throw InstalledSmokeError.wrongApp }
        evidence = URL(fileURLWithPath: directory, isDirectory: true); try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let info = Bundle(url: url)!.infoDictionary!
        try check(info["CFBundleIdentifier"] as? String == "dev.openbrowser.mac", "The installed app has Alcove's actual bundle identity")
        print("INSTALLED_BUNDLE_VERSION", info["CFBundleShortVersionString"]!, info["CFBundleVersion"]!)
        print("INSTALLED_REDUCE_MOTION", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let requiresOpening = ProcessInfo.processInfo.environment["ALCOVE_REQUIRE_OPENING_ANIMATION"] == "true"
        if requiresOpening { try check(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "The disposable runner actually enables normal motion before app launch") }
        var app = try await launch(url)
        let initialPID = app.processIdentifier
        for _ in 0..<100 { if !(try nodes(app)).isEmpty { break }; await pause() }
        try await capture(app, "installed-first-visible")
        await pause(700); try await capture(app, "installed-welcome-next-frame")
        let firstContinue = try await find("Continue", in: app)
        try check(attribute(firstContinue, kAXEnabledAttribute) as? Bool == true, "The actual first-launch setup becomes usable")
        if requiresOpening { try check(openingObserved && openingCaptured, "The installed first-run animation is actually exposed and transitions into usable setup") }
        try await capture(app, "installed-welcome-step-one")
        try press(firstContinue, "Continue to themes")
        let sage = try await find("Sage", in: app)
        try press(sage, "Choose Sage")
        await pause(600); try await capture(app, "installed-welcome-theme")
        try press(try await find("Continue", in: app), "Continue to setup")
        let field = try await find("Name your first Space", in: app)
        let focused = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        await pause(); try check(focused == .success, "Public AX focuses the actual first Space name editor")
        try await typeName("Installed Smoke", in: app)
        try check(text(field, kAXValueAttribute) == "Installed Smoke", "Targeted keyboard input edits the actual first Space name")
        let automatic = try await find("Check for new versions automatically", in: app)
        try check((attribute(automatic, kAXValueAttribute) as? NSNumber)?.boolValue == false, "First-run automatic update checks remain opt-in")
        try await capture(app, "installed-welcome-setup")
        try press(try await find("Start browsing", in: app), "Finish actual setup")
        _ = try await find("Installed Smoke", in: app)
        try check(true, "The normal installed browser keeps the Space name entered during setup")
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: down) else { throw InstalledSmokeError.launch }
            event.flags = .maskCommand; event.postToPid(app.processIdentifier)
        }
        for _ in 0..<100 {
            let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            if app.isTerminated || windows.isEmpty { break }
            await pause()
        }
        let remaining = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        try check(remaining.isEmpty, "Actual Command-W closes the ordinary empty browser window")
        try check(!app.isTerminated, "Closing the empty window keeps the actual Alcove process running")
        let reopenFile = try await fileMenu(in: app)
        try press(reopenFile, "File menu without a window")
        try press(try await menuItem("Open Main Window", below: reopenFile, app: app), "Open Main Window")
        _ = try await find("Installed Smoke", in: app)
        try check(!app.isTerminated && app.processIdentifier == initialPID, "The resident app reopens its normal window with the saved Space")
        try await capture(app, "installed-empty-window-reopened")
        guard let site = ProcessInfo.processInfo.environment["ALCOVE_INSTALLED_TEST_SITE"],
              let siteURL = URL(string: site), siteURL.host == "127.0.0.1", siteURL.scheme == "http" else { throw InstalledSmokeError.environment("missing owned loopback website") }
        try await navigate(site + "/one", in: app)
        _ = try await find("Alcove owned page one", in: app)
        try check(true, "The ordinary installed WebKit browser loads the owned HTTP page and its real document title")
        try await capture(app, "installed-browser-first-page")
        try await key(17, flags: .maskCommand, app: app)
        let nextAddress = try await find("Search or Enter URL…", in: app)
        _ = AXUIElementSetAttributeValue(nextAddress, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await typeName(site + "/two", in: app)
        try await key(36, app: app)
        _ = try await find("Alcove owned page two", in: app)
        try check(true, "Actual Command-T opens a second independently loaded website tab")
        try await key(13, flags: .maskCommand, app: app)
        _ = try await find("Alcove owned page one", in: app)
        let browserWindows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        try check(!app.isTerminated && browserWindows.count == 1 && !(try nodes(app)).contains(where: { labels($0).contains("Alcove owned page two") }), "Command-W closes the current website tab while the other tab keeps its window open")
        try await key(35, flags: [.maskCommand, .maskShift], app: app)
        try await capture(app, "installed-browser-after-pin-shortcut")
        let pinnedArea = try await find("Pinned tabs", in: app)
        let pinLabels = descendantLabels(pinnedArea, ownedPID: app.processIdentifier)
        print("OWNED_INSTALLED_PINNED_LABELS", pinLabels)
        try check(pinLabels.contains(where: { $0 == "Alcove owned page one" || $0.hasSuffix(", Alcove owned page one") }), "The actual Pin shortcut moves the website into the separate Pinned shelf")
        let folderFile = try await fileMenu(in: app)
        try press(folderFile, "File before new folder")
        try press(try await menuItem("New Folder…", below: folderFile, app: app), "New Folder")
        let folderName = try await find("Folder name", in: app)
        _ = AXUIElementSetAttributeValue(folderName, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await typeName("Installed QA Folder", in: app)
        try press(try await find("Create Folder", in: app), "Create owned folder")
        _ = try await find("Installed QA Folder", in: app)
        try check(true, "The ordinary installed browser creates a named native sidebar folder")
        try await capture(app, "installed-browser-pinned-folder")
        try press(try await find("Pinned", in: app), "Collapse Pinned shelf")
        await pause(350)
        try check(text(try await find("Pinned", in: app), kAXValueAttribute).hasPrefix("Collapsed"), "The installed Pinned shelf collapses with its disclosure state exposed")
        try press(try await find("Pinned", in: app), "Expand Pinned shelf")
        _ = try await find("Installed QA Folder", in: app)
        try check(text(try await find("Pinned", in: app), kAXValueAttribute) == "Expanded", "The installed shelf re-expands with its saved pin and folder available")
        print("INSTALLED_NEW_EASEL_BEGIN", ProcessInfo.processInfo.systemUptime)
        let file = try await fileMenu(in: app)
        try press(file, "File menu")
        try press(try await menuItem("New Easel", below: file, app: app), "New Easel")
        let addNote = try await find("Add your first note", in: app)
        try press(addNote, "Add first note")
        let note = try await find("Canvas note", in: app)
        print("INSTALLED_NEW_EASEL_END", ProcessInfo.processInfo.systemUptime)
        let marker = "Installed protected note 🌱 " + UUID().uuidString
        _ = AXUIElementSetAttributeValue(note, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let edited = AXUIElementSetAttributeValue(note, kAXValueAttribute as CFString, marker as CFString)
        try check(edited == .success && text(note, kAXValueAttribute) == marker, "The ordinary sandboxed app accepts complete Unicode note input")
        try press(try await find("Pen tool", in: app), "Pen tool")
        await pause(900)
        try await capture(app, "installed-normal-note-saved")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations = [home.appendingPathComponent("Library/Containers/dev.openbrowser.mac/Data/Library/Application Support/OpenBrowser/session-v2.sealed"), home.appendingPathComponent("Library/Application Support/OpenBrowser/session-v2.sealed")]
        let files = locations.filter { FileManager.default.fileExists(atPath: $0.path) }
        try check(files.count == 1, "The actual installed app creates one normal protected session file")
        let sealed = try Data(contentsOf: files[0])
        try check(!sealed.isEmpty && sealed.range(of: Data(marker.utf8)) == nil, "The actual normal session does not expose the saved note as plaintext")
        let closed = await close(app)
        try check(closed && app.isTerminated, "Normal Quit completes after saving the owned note")
        app = try await launch(url)
        try check(app.processIdentifier != initialPID, "Cold reopen launches a fresh installed application process")
        let reopened = try await find("Canvas note", in: app)
        try check(text(reopened, kAXValueAttribute) == marker, "A fresh ordinary app restores its real Keychain-protected saved note")
        try check(!(try nodes(app)).contains(where: { labels($0).contains("Start browsing") || labels($0).contains("Skip opening animation") }), "Completed first-run setup does not replay on cold reopen")
        _ = try await find("Installed QA Folder", in: app)
        try check(true, "The actual normal cold reopen restores the created sidebar folder")
        let reopenedPinned = try await find("Pinned tabs", in: app)
        try check(descendantLabels(reopenedPinned, ownedPID: app.processIdentifier).contains(where: { $0 == "Alcove owned page one" || $0.hasSuffix(", Alcove owned page one") }), "The actual normal cold reopen preserves the website pin beside the Easel")
        try await capture(app, "installed-normal-cold-reopen")
        let privateFile = try await fileMenu(in: app)
        try press(privateFile, "File for private navigation")
        try press(try await menuItem("New Private Window", below: privateFile, app: app), "New actual private window")
        _ = try await find("PRIVATE WINDOW · History is not saved. Downloads stay on disk.", in: app)
        let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let privateWindow = windows.first(where: { text($0, kAXTitleAttribute) == "Alcove — Private" }) else { throw InstalledSmokeError.missing("actual private window") }
        _ = AXUIElementPerformAction(privateWindow, kAXRaiseAction as CFString)
        try await navigate(site + "/two", in: app)
        _ = try await find("Alcove owned page two", in: app)
        let privateLabels = descendantLabels(privateWindow, ownedPID: app.processIdentifier)
        try check(privateLabels.contains(where: { $0 == "Alcove owned page two" || $0.hasSuffix(", Alcove owned page two") }), "The actual fresh0.22.1 private window loads its own real HTTP website")
        try check(!privateLabels.contains(where: { $0.contains(marker) || $0 == "Installed QA Folder" || $0 == "Canvas note" }), "The actual private window excludes normal saved note and folder content")
        try await capture(app, "installed-private-real-website", windowTitle: "Alcove — Private")
        try await key(13, flags: .maskCommand, app: app)
        for _ in 0..<100 {
            let remaining = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            if remaining.count == 1 { break }; await pause()
        }
        let remaining = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        try check(!app.isTerminated && remaining.count == 1 && !remaining.contains(where: { text($0, kAXTitleAttribute) == "Alcove — Private" }), "Command-W closes the private website window and keeps the normal browser running")
        let retainedNote = try await find("Canvas note", in: app)
        try check(text(retainedNote, kAXValueAttribute) == marker, "Private browsing and its window closure retain the original normal note")
        let finalClosed = await close(app)
        try check(finalClosed && app.isTerminated, "The final owned app closes without leaving a browser window running")
        let receipt: [String: Any] = ["checks": checks, "failed": 0, "version": info["CFBundleShortVersionString"]!, "build": info["CFBundleVersion"]!, "bundleID": info["CFBundleIdentifier"]!, "firstProcessID": initialPID, "reopenedProcessID": app.processIdentifier, "normalSavedMarkerRestored": true, "ownedWebsiteNavigation": true, "privateHTTPNavigation": true, "normalDataExcludedFromPrivate": true, "privateCommandWClosedWindow": true, "populatedTabCommandW": true, "pinnedWebsiteRestored": true, "namedFolderRestored": true, "emptyWindowCommandWClosed": true, "appStayedResident": true, "residentMainWindowReopened": true, "plainTextMarkerAbsent": true, "sealedBytes": sealed.count, "keyProviderInjected": false, "appArgumentsInjected": false, "normalMotionRequired": requiresOpening, "openingObserved": openingObserved, "openingCaptured": openingCaptured, "preexistingAXAccess": true, "quarantineAssessment": "not simulated; downloaded artifact copy is not browser-quarantined", "scope": "Ordinary bundled app in hosted user's Applications; original update across different binaries, minimum OS, real-user hardware and full-browser coverage remain open"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("installed-result.json"), options: .atomic)
        print("Installed Alcove smoke checks:", checks, "checked, 0 failed")
    }
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); await cleanup(); exit(0) }
            catch { print("FAIL: ordinary installed Alcove smoke", error); await cleanup(); exit(1) }
        }
        NSApplication.shared.run()
    }
}
