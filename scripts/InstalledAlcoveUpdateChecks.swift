import AppKit
import ApplicationServices
import ScreenCaptureKit
import CryptoKit

private enum InstalledSmokeError: Error { case environment(String), launch, wrongApp, timeout(String), ax(String, Int32), missing(String), protection }
@main struct InstalledAlcoveUpdateChecks {
    @MainActor static var owned: [NSRunningApplication] = []
    @MainActor static var checks = 0
    @MainActor static var evidence: URL!
    @MainActor static var bundleBackup: (installed: URL, backup: URL)?
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
    @MainActor static func close(_ app: NSRunningApplication) async -> Bool {
        if app.isTerminated { return true }
        let requested = app.terminate()
        for _ in 0..<100 { if app.isTerminated { return requested }; await pause() }
        return false
    }
    static func descendantLabels(_ root: AXUIElement, ownedPID: pid_t) -> [String] {
        var queue = [(root, 0)], result: [String] = [], visited = 0
        while !queue.isEmpty && visited < 600 {
            let (element, depth) = queue.removeFirst(); visited += 1
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success && pid == ownedPID else { continue }
            result.append(contentsOf: labels(element))
            if depth < 32, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        return result
    }
    static func copyBundle(_ source: URL, to destination: URL) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); child.arguments = [source.path, destination.path]
        try child.run(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw InstalledSmokeError.environment("owned app bundle copy failed") }
    }
    @MainActor static func restoreOriginalBundle() throws {
        guard let bundleBackup else { return }
        guard owned.allSatisfy({ $0.isTerminated }) else { throw InstalledSmokeError.environment("owned app still running; preserving both bundles") }
        if FileManager.default.fileExists(atPath: bundleBackup.installed.path) { try FileManager.default.removeItem(at: bundleBackup.installed) }
        try FileManager.default.moveItem(at: bundleBackup.backup, to: bundleBackup.installed)
        self.bundleBackup = nil
    }
    @MainActor static func cleanup() async {
        for app in owned where !app.isTerminated {
            if !(await close(app)) {
                print("OWNED_INSTALLED_CLEANUP_FORCE", app.processIdentifier); app.forceTerminate()
                for _ in 0..<100 { if app.isTerminated { break }; await pause() }
            }
        }
        do { try restoreOriginalBundle() } catch { print("OWNED_UPDATE_RESTORE_FAILED", error) }
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
        try await capture(app, "installed-normal-cold-reopen")
        let initialReopenedPID = app.processIdentifier
        let finalClosed = await close(app)
        try check(finalClosed && app.isTerminated, "The final owned app closes without leaving a browser window running")
        let beforeUpgrade = try Data(contentsOf: files[0])
        guard let candidatePath = ProcessInfo.processInfo.environment["ALCOVE_UPDATE_CANDIDATE_APP"] else { throw InstalledSmokeError.environment("missing exact source-built candidate") }
        let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: true)
        let expectedCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/update-candidate/Alcove.app", isDirectory: true)
        guard candidateURL.standardizedFileURL == expectedCandidate.standardizedFileURL,
              let candidateInfo = Bundle(url: candidateURL)?.infoDictionary else { throw InstalledSmokeError.wrongApp }
        try check(candidateInfo["CFBundleIdentifier"] as? String == "dev.openbrowser.mac" && candidateInfo["CFBundleShortVersionString"] as? String == "0.22.1", "The replacement is the real0.22.1 browser app with the same bundle identity")
        let originalExecutable = try Data(contentsOf: url.appendingPathComponent("Contents/MacOS/Alcove"))
        let candidateExecutable = try Data(contentsOf: candidateURL.appendingPathComponent("Contents/MacOS/Alcove"))
        try check(SHA256.hash(data: originalExecutable) != SHA256.hash(data: candidateExecutable), "The update actually changes the signed executable identity")
        let backup = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ordinary-update-backup/Alcove.app", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw InstalledSmokeError.environment("owned backup already exists") }
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: backup); bundleBackup = (url, backup)
        try copyBundle(candidateURL, to: url)
        try check(try Data(contentsOf: url.appendingPathComponent("Contents/MacOS/Alcove")) == candidateExecutable, "The actually installed replacement executable matches the verified source-built candidate bytes")
        let replacementStart = ProcessInfo.processInfo.systemUptime
        app = try await launch(url)
        let replacementPID = app.processIdentifier
        let unlock = try await find("Unlock Local Data…", in: app)
        let recoverySeconds = ProcessInfo.processInfo.systemUptime - replacementStart
        try check(attribute(unlock, kAXEnabledAttribute) as? Bool == true, "The changed ordinary app reaches explicit Unlock Local Data instead of waiting on automatic Keychain authorization")
        _ = try await find("Your saved data is locked", in: app)
        try check(!(try nodes(app)).contains(where: { labels($0).contains("Waiting for macOS Keychain. Complete any Keychain prompt on your Mac to open your saved tabs.") }), "Automatic startup finishes the denied lookup and leaves the saved-data recovery UI responsive")
        try check(try Data(contentsOf: files[0]) == beforeUpgrade, "Denied upgraded startup leaves the exact original encrypted session bytes unchanged")
        try await capture(app, "installed-update-explicit-recovery")
        try press(try await find("Open Private Window", in: app), "Open private browsing while saved data is locked")
        _ = try await find("PRIVATE WINDOW · History is not saved. Downloads stay on disk.", in: app)
        let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let privateWindow = windows.first(where: { text($0, kAXTitleAttribute) == "Alcove — Private" }) else { throw InstalledSmokeError.missing("actual private native window") }
        let privateLabels = descendantLabels(privateWindow, ownedPID: app.processIdentifier)
        try check(windows.count == 2 && privateLabels.contains("PRIVATE WINDOW · History is not saved. Downloads stay on disk."), "The real upgraded app opens an independent usable private browser while normal saved data is locked")
        try check(!privateLabels.contains(where: { $0.contains(marker) || $0 == "Canvas note" || $0 == "Start browsing" }), "The private window exposes neither the protected note nor normal first-run setup")
        try await capture(app, "installed-update-private-available", windowTitle: "Alcove — Private")
        let replacementClosed = await close(app)
        try check(replacementClosed && app.isTerminated, "The denied normal owner and temporary private window quit normally")
        try check(try Data(contentsOf: files[0]) == beforeUpgrade, "The denied update and private session preserve the original encrypted file through Quit")
        try restoreOriginalBundle()
        try check(try Data(contentsOf: url.appendingPathComponent("Contents/MacOS/Alcove")) == originalExecutable, "The original authenticated installer is restored byte-for-byte at the same application path")
        app = try await launch(url)
        let restoredOriginalPID = app.processIdentifier
        let restoredNote = try await find("Canvas note", in: app)
        try check(text(restoredNote, kAXValueAttribute) == marker, "The original installed app still reads its original protected key and restores the exact saved note after the denied update")
        try await capture(app, "installed-update-original-data-preserved")
        let lastClosed = await close(app)
        try check(lastClosed && app.isTerminated, "Both update-test application identities leave no browser process running")
        let receipt: [String: Any] = ["checks": checks, "failed": 0, "version": info["CFBundleShortVersionString"]!, "build": info["CFBundleVersion"]!, "bundleID": info["CFBundleIdentifier"]!, "firstProcessID": initialPID, "reopenedProcessID": initialReopenedPID, "replacementProcessID": replacementPID, "restoredOriginalProcessID": restoredOriginalPID, "recoveryAvailableSeconds": recoverySeconds, "candidateVersion": "0.22.1", "candidateSource": "fb3b90b2fc6be86fb4366979204a48e7eb9362e3", "originalCiphertextPreservedByUpdate": true, "privateAvailableDuringDeniedUpdate": true, "originalKeyReadableAfterDeniedUpdate": true, "normalSavedMarkerRestored": true, "emptyWindowCommandWClosed": true, "appStayedResident": true, "residentMainWindowReopened": true, "plainTextMarkerAbsent": true, "sealedBytes": sealed.count, "keyProviderInjected": false, "appArgumentsInjected": false, "normalMotionRequired": requiresOpening, "openingObserved": openingObserved, "openingCaptured": openingCaptured, "preexistingAXAccess": true, "quarantineAssessment": "not simulated; downloaded artifact copy is not browser-quarantined", "scope": "Actual installed baseline335 creator plus normal source-built0.22.1 changed app at same path, no key/providers/arguments injected. This verifies denied update UI/private availability and original key/data preservation; changed-app explicit authorization, final universal candidate artifact, quarantine, minimumOS14 and real-user hardware remain open"]
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
