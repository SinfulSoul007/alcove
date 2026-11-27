import AppKit
import WebKit
import BrowserCore
import CryptoKit

@main struct EaselReviewExtensionChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        guard #available(macOS 15.4, *) else { return }
        let websites = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await websites.cleanup() else { exit(1) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.NativeExtensionReview." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func exercise() async throws {
            let key = SymmetricKey(size: .bits256)
            let store = BrowserStore(dataRoot: root.appendingPathComponent("data"), keyProvider: { _ in key })
            defer { store.shutdown() }
            let profile = try store.createProfile(name: "Owned native tab review")
            try websites.register(profile); try controllers.register(store.activeProfile.extensionControllerID!)
            let source = root.appendingPathComponent("extension")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"Owned native route review","version":"1","permissions":[]}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
            let package = try ExtensionPackage.prepare(at: source, stagingRoot: root.appendingPathComponent("staging"))
            let approval = try store.extensionInstallApproval(for: package, profileID: profile, permissions: [], hostPatterns: [], enable: true)
            let extensionID = try await store.installExtension(package, approval: approval)
            let website = store.newTab(url: URL(string: "about:blank")!), web = store.view(for: website)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; store.registerExtensionWindow(window, kind: .primary)
            defer { store.unregisterExtensionWindow(kind: .primary); window.contentView = nil; window.close() }
            try await store.prepareExtensions(profileID: profile)
            let host = store.extensionHosting as! NativeBrowserExtensionHost
            host.synchronizeBrowserState()
            let context = host.profiles[profile]!.contexts[extensionID]!
            let retained = host.nativeTabs.values.first { $0.key.id == website }!
            check(retained.live(context) === store, "An authorized ordinary website remains available to its extension adapter")
            let native = try store.createEasel(), route = store.tab(native)!.url
            let malformed = store.newTab(); store.update(malformed) { $0.url = "alcove://easel/not-a-board"; $0.title = "Native error view" }
            host.synchronizeBrowserState()
            check(!host.nativeTabs.values.contains { $0.key.id == native || $0.key.id == malformed }, "Extension inventory excludes both real Easels and malformed reserved native routes")
            store.update(website) { $0.url = route; $0.title = "Native replacement" }
            check(retained.live(context) == nil && retained.title(for: context) == nil && retained.url(for: context) == nil, "A retained website adapter stops exposing data immediately when its model becomes native")
            var rejected = false
            retained.loadURL(URL(string: "https://example.com/replacement")!, for: context) { rejected = $0 != nil }
            check(rejected && store.tab(website)?.url == route, "A retained extension adapter cannot navigate a native canvas into a website")
            host.synchronizeBrowserState()
            check(!host.nativeTabs.values.contains { $0.key.id == website }, "Controller synchronization retires the adapter after the website becomes native")
        }
        try await exercise()
        guard await controllers.cleanup(), await websites.cleanup() else { exit(1) }
        print("Easel native extension review checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
