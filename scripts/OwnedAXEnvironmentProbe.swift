import AppKit
import ApplicationServices

private enum OwnedProbeError: Error { case childNotReady, windowUnavailable, foreignElement, buttonMissing }

@main struct OwnedAXEnvironmentProbe {
    static func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
    @MainActor static func run() throws {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
            print("ENVIRONMENT_UNAVAILABLE hosted native probe only"); exit(3)
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--owned-child" {
            NSApplication.shared.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 480, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Alcove AX Owned Window"
            let button = NSButton(title: "Alcove AX Owned Button", target: nil, action: nil)
            button.frame = NSRect(x: 80, y: 100, width: 280, height: 40)
            window.contentView!.addSubview(button)
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                try! Data("ready".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            }
            _ = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in exit(4) }
            NSApplication.shared.run(); return
        }
        let trusted = AXIsProcessTrusted()
        print("PREEXISTING_AX_TRUST", trusted)
        guard trusted else { print("ENVIRONMENT_UNAVAILABLE accessibility grant absent; no permission requested"); exit(3) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.OwnedAX." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--owned-child", ready.path]; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        for _ in 0..<400 { if FileManager.default.fileExists(atPath: ready.path) { break }; Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: ready.path) else { throw OwnedProbeError.childNotReady }
        let ownedPID = child.processIdentifier
        let app = AXUIElementCreateApplication(ownedPID)
        let (error, value) = attribute(app, kAXWindowsAttribute)
        print("OWNED_AX_WINDOW_QUERY", ownedPID, error.rawValue)
        guard error == .success, let windows = value as? [AXUIElement], !windows.isEmpty else { throw OwnedProbeError.windowUnavailable }
        var queue = windows.map { ($0, 0) }, visited = 0, found = false
        while !queue.isEmpty && visited < 200 {
            let (element, depth) = queue.removeFirst(); visited += 1
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success && pid == ownedPID else { throw OwnedProbeError.foreignElement }
            let (_, title) = attribute(element, kAXTitleAttribute)
            if title as? String == "Alcove AX Owned Button" { found = true }
            if depth < 20, let children = attribute(element, kAXChildrenAttribute).1 as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        print(found ? "PASS: Cross-process public AX exposes the owned native button" : "FAIL: Owned native button absent from public AX")
        print("OWNED_AX_NODE_COUNT", visited)
        if !found { throw OwnedProbeError.buttonMissing }
    }
    @MainActor static func main() {
        do { try run() }
        catch { print("FAIL: owned AX environment probe", error); exit(1) }
    }
}
