import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OutputCheckError: Error { case expected }
@MainActor final class OutputFixtureWindow: NSWindow {
    var fixtureKey = true
    var fixtureSheet: NSWindow?
    override var isKeyWindow: Bool { fixtureKey }
    override var attachedSheet: NSWindow? { fixtureSheet ?? super.attachedSheet }
}
@MainActor final class OutputFixtureWebView: WKWebView {
    var fixtureURL: URL? = URL(string: "https://output.example.invalid/alpha")
    override var url: URL? { fixtureURL }
    var fixtureTitle = "Example report"
    override var title: String? { fixtureTitle }
}
final class OutputKeyCounter { var reads = 0 }
@MainActor final class OutputFixture {
    let root: URL
    let store: BrowserStore
    let window: OutputFixtureWindow
    let web: OutputFixtureWebView
    let keyCounter = OutputKeyCounter()
    var destination: URL { root.appendingPathComponent("selected.pdf") }
    init(isPrivate: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.OutputChecks.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let counter = keyCounter, key = SymmetricKey(size: .bits256)
        store = BrowserStore(isPrivate: isPrivate, dataRoot: root.appendingPathComponent("metadata"), keyProvider: { _ in counter.reads += 1; return key })
        store.onboardingVisible = false
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        web = OutputFixtureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        store.registerView(web, for: store.selectedID!, profile: BrowserProfile.defaultID)
        window = OutputFixtureWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web
    }
    func close() { window.fixtureSheet = nil; window.contentView = nil; window.close(); store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

/// Substitute only presentation/capture timing. Accepted output uses real temporary-file writes.
@MainActor final class OutputBoundaries {
    var captures: [(WKWebView, PageOutputFormat, (Result<Data, Error>) -> Void)] = []
    var choices: [(NSWindow, String, PageOutputFormat, (URL?) -> Void)] = []
    var prints: [(WKWebView, NSWindow, (Bool) -> Void)] = []
    var errors: [(NSWindow, String)] = []
    var orphanedErrors: [String] = []
    var cancellations = 0, writes = 0
    var immediateDestination: URL?
    var afterWrite: (() -> Void)?
    var deferWrite = false
    var pendingWrites: [() -> Void] = []
    var writeCompletions: [(Result<Void, Error>) -> Void] = []
    var pendingWrite: (() -> Void)? { pendingWrites.first }
    var environment: PageOutputEnvironment {
        PageOutputEnvironment(capture: { web, format, done in self.captures.append((web, format, done)) }, choose: { window, name, format, done in
            self.choices.append((window, name, format, done))
            if let url = self.immediateDestination { done(url) }
            return { self.cancellations += 1 }
        }, print: { web, window, done in
            self.prints.append((web, window, done)); return { self.cancellations += 1 }
        }, write: { data, url, done in
            self.writes += 1; self.writeCompletions.append(done)
            let operation = { [weak self] in
                do { try data.write(to: url, options: .atomic); done(.success(())) }
                catch { done(.failure(error)) }
                self?.afterWrite?()
            }
            if self.deferWrite { self.pendingWrites.append(operation) } else { operation() }
        }, reportError: { message, window in self.errors.append((window, message)) }, reportOrphanedError: { self.orphanedErrors.append($0) })
    }
}

