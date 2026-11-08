import Foundation
import WebKit
import BrowserCore

/// Test-only ownership log. Never remove a store unless this test executable recorded its random ID.
@MainActor final class OwnedWebsiteStores {
    let manifest: URL
    private var ids: [UUID]
    // WebKit's store enumeration dispatches through its main run loop. Initialize
    // WebKit before recovery-only runs, which otherwise have never made a view.
    private let webKitLifetime: WKWebView
    init() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webKitLifetime = WKWebView(frame: .zero, configuration: configuration)
        manifest = URL(fileURLWithPath: CommandLine.arguments[0]).appendingPathExtension("owned-stores.json")
        ids = FileManager.default.fileExists(atPath: manifest.path) ? try JSONDecoder().decode([UUID].self, from: Data(contentsOf: manifest)) : []
        guard ids.allSatisfy({ $0 != BrowserProfile.defaultID && $0 != BrowserProfile.zeroID }) else { throw CocoaError(.fileReadCorruptFile) }
    }
    func register(_ id: UUID) throws {
        guard id != BrowserProfile.defaultID, id != BrowserProfile.zeroID else { throw CocoaError(.fileWriteInvalidFileName) }
        if !ids.contains(id) { ids.append(id) }
        try JSONEncoder().encode(ids).write(to: manifest, options: .atomic)
    }
    func cleanup() async -> Bool {
        for id in ids {
            var removed = false
            for _ in 0..<50 {
                if !(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(id) { removed = true; break }
                do { try await WKWebsiteDataStore.remove(forIdentifier: id); removed = true; break }
                catch { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard removed else { print("FAIL: Disposable website-store cleanup is still in use; ownership manifest retained."); return false }
        }
        do { if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }; ids = []; return true }
        catch { print("FAIL: Disposable website-store ownership manifest could not be removed."); return false }
    }
}
