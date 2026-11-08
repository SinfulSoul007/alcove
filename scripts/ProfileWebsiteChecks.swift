import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum WebsiteCheckError: Error { case fixtureMissing, timedOut }
@main struct ProfileWebsiteChecks {
    @MainActor static func ready(_ web: WKWebView, url: URL) async throws {
        let json = try JSONSerialization.data(withJSONObject: [url.absoluteString])
        let quotedURL = String(decoding: json, as: UTF8.self).dropFirst().dropLast()
        let expression = "window.alcoveFixtureReady === true && location.href === \(quotedURL)"
        for _ in 0..<1000 {
            if let result = try? await web.evaluateJavaScript(expression), result as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebsiteCheckError.timedOut
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard let base = ProcessInfo.processInfo.environment["ALCOVE_PROFILE_FIXTURE_URL"], let fixture = URL(string: base) else { throw WebsiteCheckError.fixtureMissing }
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        var store: BrowserStore? = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        let a = try store!.createProfile(name: "A"); let spaceA = store!.space.id; let tabA = store!.selectedID!
        var urlA = URL(string: "?context=A", relativeTo: fixture)!.absoluteURL
        store!.update(tabA) { $0.url = urlA.absoluteString }
        var webA: WKWebView? = store!.view(for: tabA); try await ready(webA!, url: urlA)
        _ = try await webA!.evaluateJavaScript("document.cookie='alcove_profile_test=A; path=/; SameSite=Lax'; localStorage.setItem('alcove_profile_test','A')")
        let b = try store!.createProfile(name: "B"); let tabB = store!.selectedID!
        let urlB = URL(string: "?context=B", relativeTo: fixture)!.absoluteURL
        store!.update(tabB) { $0.url = urlB.absoluteString }
        var webB: WKWebView? = store!.view(for: tabB); try await ready(webB!, url: urlB)
        check(try await webB!.evaluateJavaScript("document.cookie === '' && localStorage.getItem('alcove_profile_test') === null") as? Bool == true, "A second profile cannot read the first profile's cookie or local storage")
        _ = try await webB!.evaluateJavaScript("document.cookie='alcove_profile_test=B; path=/; SameSite=Lax'; localStorage.setItem('alcove_profile_test','B')")
        check(try await webA!.evaluateJavaScript("document.cookie === 'alcove_profile_test=A' && localStorage.getItem('alcove_profile_test') === 'A'") as? Bool == true, "Writing the same site's account in profile B leaves profile A unchanged")
        let privateRoot = root.appendingPathComponent("private")
        var privateStore: BrowserStore? = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in fatalError("Private website requested key") })
        let urlPrivate = URL(string: "?context=private", relativeTo: fixture)!.absoluteURL
        let privateTab = privateStore!.newTab(url: urlPrivate)
        var webPrivate: WKWebView? = privateStore!.view(for: privateTab); try await ready(webPrivate!, url: urlPrivate)
        check(try await webPrivate!.evaluateJavaScript("document.cookie === '' && localStorage.getItem('alcove_profile_test') === null") as? Bool == true, "A private window cannot read either normal profile's website data")
        _ = try await webPrivate!.evaluateJavaScript("document.cookie='alcove_profile_test=private; path=/'; localStorage.setItem('alcove_profile_test','private')")
        check(try await webB!.evaluateJavaScript("document.cookie === 'alcove_profile_test=B' && localStorage.getItem('alcove_profile_test') === 'B'") as? Bool == true, "Private website writes do not alter a normal profile")
        check(privateStore!.library.history.isEmpty && !FileManager.default.fileExists(atPath: privateRoot.path), "Private fixture browsing saves no normal history or metadata")
        urlA = URL(string: "?context=A-background", relativeTo: fixture)!.absoluteURL
        webA!.load(URLRequest(url: urlA)); try await ready(webA!, url: urlA)
        check(store!.activeProfileID == b, "Background fixture navigation leaves the selected profile unchanged")
        check(store!.library(for: a).history.contains(where: { $0.url == urlA.absoluteString }) && !store!.library(for: a).history.contains(where: { $0.url == urlB.absoluteString }) && store!.library(for: b).history.contains(where: { $0.url == urlB.absoluteString }), "Real background navigation records history in the correct profile")
        store!.flush()
        for id in Array(store!.views.keys) { store!.discardView(id) }
        webA = nil; webB = nil; store!.namedDataStores.removeAll(); store!.archiveTimer?.invalidate(); store = nil
        await Task.yield()
        store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        webB = store!.view(for: tabB); try await ready(webB!, url: urlB)
        check(try await webB!.evaluateJavaScript("document.cookie === 'alcove_profile_test=B' && localStorage.getItem('alcove_profile_test') === 'B'") as? Bool == true, "Reopening saved profile identifiers restores the same site's account storage")
        do { try await store!.clearProfileData(a) } catch { check(false, "Profile website clearing completes") }
        store!.selectSpace(spaceA)
        let clearedTab = store!.selectedID!; store!.update(clearedTab) { $0.url = urlA.absoluteString }
        webA = store!.view(for: clearedTab); try await ready(webA!, url: urlA)
        check(try await webA!.evaluateJavaScript("document.cookie === '' && localStorage.getItem('alcove_profile_test') === null") as? Bool == true, "Clearing profile A actually removes its cookies and local storage")
        check(try await webB!.evaluateJavaScript("document.cookie === 'alcove_profile_test=B' && localStorage.getItem('alcove_profile_test') === 'B'") as? Bool == true, "Clearing profile A preserves profile B's live website session")
        try store!.assignProfile(BrowserProfile.defaultID, to: spaceA)
        webA = nil
        do { try await store!.deleteProfile(a) } catch { print("Deletion error: \(error)"); check(false, "Real named-store deletion completes") }
        let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
        check(!remaining.contains(a) && remaining.contains(b), "Deleting unused profile A removes only its named WebKit store")
        for current in [store!, privateStore!] { for id in Array(current.views.keys) { current.discardView(id) }; current.archiveTimer?.invalidate(); current.namedDataStores.removeAll() }
        webA = nil; webB = nil; webPrivate = nil; privateStore = nil; store = nil
        await Task.yield()
        for id in [a, b] { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        exit(failures == 0 ? 0 : 1)
    }
}
