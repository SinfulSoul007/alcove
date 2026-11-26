import AppKit
import WebKit

/// Forward the actual OS termination transaction unchanged. The parent runner
/// verifies this process exits and cleans only its journaled temporary stores.
@MainActor private final class OwnedFullscreenQuitAudit: NSObject, NSApplicationDelegate {
    let production: AppDelegate
    let sourceIntact: () -> Bool
    let didShutdown: () -> Void
    init(production: AppDelegate, sourceIntact: @escaping () -> Bool, didShutdown: @escaping () -> Void) {
        self.production = production; self.sourceIntact = sourceIntact; self.didShutdown = didShutdown
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WebsiteFullscreenChecks.check(sourceIntact(),
              "The native Quit transaction consults production with its exact live source intact")
        return production.applicationShouldTerminate(sender)
    }
    func applicationWillTerminate(_ notification: Notification) {
        production.applicationWillTerminate(notification)
        didShutdown()
    }
}

extension WebsiteFullscreenChecks {
    @available(macOS 15.4, *) @MainActor
    static func exerciseRealQuit(app: AppDelegate, owner: BrowserWindowOwner, store: BrowserStore,
                                 web: WKWebView, presentation: NSWindow, savedState: @escaping () -> Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["ALCOVE_FULLSCREEN_QUIT_ROOT"],
              let name = environment["ALCOVE_FULLSCREEN_COMMAND_CASES"], !name.contains(",") else {
            throw Failure.fixture("dedicated owned Quit child process")
        }
        let document = store.documentIdentity(for: web), identity = store.presentationIdentity(for: web)
        let profile = store.profileID(for: web)
        check(presentation.isVisible && web.fullscreenState == .inFullscreen &&
              (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true,
              "A real Quit request begins with an actual borrowed fullscreen page")
        let audit = OwnedFullscreenQuitAudit(production: app, sourceIntact: {
            !owner.isClosed && !store.isShuttingDown && web.navigationDelegate === store &&
                store.profileID(for: web) == profile && store.documentIdentity(for: web) === document &&
                store.presentationIdentity(for: web) === identity
        }, didShutdown: {
            check(owner.isClosed && store.isShuttingDown,
                  "Actual application termination shuts down its captured browser owner")
            check(savedState(), store.isPrivate
                  ? "Actual private Quit never reads a metadata key or writes a saved session"
                  : "Actual normal Quit durably saves its exact profile and primary or Quick tab")
            let result: [String: Any] = ["formatVersion": 1, "case": name,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "checks": checks, "failures": failures, "success": failures == 0]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: root).appendingPathComponent("quit-result.json"), options: .atomic)
                print("WEBSITE_FULLSCREEN_QUIT_CHECKS", checks, "FAILURES", failures)
            } catch { print("FULLSCREEN_QUIT_WITNESS_ERROR", error) }
        })
        NSApp.delegate = audit
        app.quit()
        // A successful native Quit ends the child before this condition times out.
        // Keep the weak native delegate alive until that happens.
        defer { withExtendedLifetime(audit) {}; NSApp.delegate = nil }
        try await wait("actual owned native process termination") { false }
    }
}
