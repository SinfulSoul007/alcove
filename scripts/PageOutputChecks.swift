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
    override var title: String? { "Example report" }
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
    var cancellations = 0, writes = 0
    var immediateDestination: URL?
    var afterWrite: (() -> Void)?
    var deferWrite = false
    var pendingWrite: (() -> Void)?
    var environment: PageOutputEnvironment {
        PageOutputEnvironment(capture: { web, format, done in self.captures.append((web, format, done)) }, choose: { window, name, format, done in
            self.choices.append((window, name, format, done))
            if let url = self.immediateDestination { done(url) }
            return { self.cancellations += 1 }
        }, print: { web, window, done in
            self.prints.append((web, window, done)); return { self.cancellations += 1 }
        }, write: { data, url, done in
            self.writes += 1
            let operation = {
                do { try data.write(to: url, options: .atomic); done(.success(())) }
                catch { done(.failure(error)) }
                self.afterWrite?()
            }
            if self.deferWrite { self.pendingWrite = operation } else { operation() }
        }, reportError: { message, window in self.errors.append((window, message)) })
    }
}

@main struct PageOutputChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0
        var fixtures: [OutputFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func fixture(isPrivate: Bool = true) throws -> OutputFixture {
            let f = try OutputFixture(isPrivate: isPrivate); fixtures.append(f); return f
        }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let bytes = Data("Captured ALPHA document".utf8)
        let f = try fixture(), boundary = OutputBoundaries()
        let output = PageOutputCoordinator(environment: boundary.environment)
        check(output.canBegin(web: f.web, store: f.store, window: f.window), "A live focused private page can start explicit output without metadata permission")
        f.window.fixtureKey = false
        output.save(web: f.web, store: f.store, window: f.window, format: .pdf)
        check(boundary.captures.isEmpty && !output.isBusy(in: f.window), "A background request cannot capture a page or open a picker")
        f.window.fixtureKey = true; f.store.commandVisible = true
        check(!output.canBegin(web: f.web, store: f.store, window: f.window), "Covered primary content cannot start page output")
        f.store.commandVisible = false
        let other = try fixture()
        check(!output.canBegin(web: f.web, store: f.store, window: other.window), "A request cannot relabel another window's native document")
        f.window.fixtureSheet = other.window
        check(!output.canBegin(web: f.web, store: f.store, window: f.window), "Output does not stack a new native sheet over an existing sheet")
        f.window.fixtureSheet = nil
        output.save(web: f.web, store: f.store, window: f.window, format: .pdf)
        output.save(web: f.web, store: f.store, window: f.window, format: .webArchive)
        check(boundary.captures.count == 1 && boundary.captures[0].0 === f.web && boundary.captures[0].1 == .pdf && output.isBusy(in: f.window), "Duplicate output requests capture only the original visible document once")
        let captured = boundary.captures[0].2
        captured(.success(bytes)); captured(.success(Data("Wrong duplicate".utf8)))
        check(boundary.choices.count == 1 && boundary.choices[0].0 === f.window && boundary.choices[0].1 == "Example report.pdf", "Repeated capture callbacks create one correctly named owning-window picker")
        f.window.fixtureKey = false
        let choose = boundary.choices[0].3
        choose(f.destination); choose(f.root.appendingPathComponent("duplicate.pdf"))
        check(try Data(contentsOf: f.destination) == bytes && boundary.writes == 1 && !output.isBusy(in: f.window), "A valid sheet result saves captured bytes once before key-window restoration")
        check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("duplicate.pdf").path), "A repeated destination callback cannot write a second file")
        check(f.keyCounter.reads == 0 && !FileManager.default.fileExists(atPath: f.store.sessionURL.path), "Explicit private output does not read a normal key or save normal metadata")
        f.window.fixtureKey = true
        output.save(web: f.web, store: f.store, window: f.window, format: .webArchive)
        captured(.failure(OutputCheckError.expected))
        check(output.isBusy(in: f.window) && boundary.captures.count == 2, "An old completion cannot clear a replacement output job")
        output.cancel(in: f.window)
        boundary.captures[1].2(.success(bytes))
        check(!output.isBusy(in: f.window) && boundary.choices.count == 1, "Cancellation before capture completion cannot resurrect a save sheet")

        for phase in ["capture", "picker"] {
            for mutation in ["URL", "view", "profile", "close", "cancel"] {
                let item = try fixture(), b = OutputBoundaries(), c = PageOutputCoordinator(environment: b.environment)
                c.save(web: item.web, store: item.store, window: item.window, format: .pdf)
                if phase == "picker" { b.captures[0].2(.success(bytes)) }
                switch mutation {
                case "URL": item.web.fixtureURL = URL(string: "https://output.example.invalid/replacement")
                case "view": item.store.views.removeValue(forKey: item.store.selectedID!)
                case "profile": item.store.viewProfileIDs[item.store.selectedID!] = UUID()
                case "close": item.window.close()
                default: c.cancel(in: item.window)
                }
                if phase == "capture" { b.captures[0].2(.success(bytes)) }
                else { b.choices[0].3(item.destination) }
                check(b.writes == 0 && !FileManager.default.fileExists(atPath: item.destination.path) && !c.isBusy(in: item.window), "\(mutation) change during \(phase) cannot export invalidated page bytes")
            }
        }
        let paused = try fixture(isPrivate: false), p = OutputBoundaries(), pausedOutput = PageOutputCoordinator(environment: p.environment)
        paused.store.profiles[0].pendingDataClear = true
        pausedOutput.save(web: paused.web, store: paused.store, window: paused.window, format: .pdf)
        check(p.captures.isEmpty, "A profile paused for clearing cannot start page output")
        for badData in [false, true] {
            let item = try fixture(), b = OutputBoundaries(), c = PageOutputCoordinator(environment: b.environment)
            c.save(web: item.web, store: item.store, window: item.window, format: .pdf)
            b.captures[0].2(badData ? .success(Data()) : .failure(OutputCheckError.expected))
            check(b.choices.isEmpty && b.writes == 0 && !c.isBusy(in: item.window), "\(badData ? "Empty" : "Failed") capture never presents a destination or writes an empty output")
        }
        let cancelled = try fixture(), cb = OutputBoundaries(), cc = PageOutputCoordinator(environment: cb.environment)
        cc.save(web: cancelled.web, store: cancelled.store, window: cancelled.window, format: .pdf)
        cb.captures[0].2(.success(bytes)); cb.choices[0].3(nil)
        check(cb.writes == 0 && !cc.isBusy(in: cancelled.window), "Cancelling the native picker writes nothing and releases the window")
        let failedWrite = try fixture(), wb = OutputBoundaries(), wc = PageOutputCoordinator(environment: wb.environment)
        wc.save(web: failedWrite.web, store: failedWrite.store, window: failedWrite.window, format: .pdf)
        wb.captures[0].2(.success(bytes)); wb.choices[0].3(failedWrite.root.appendingPathComponent("missing/result.pdf"))
        check(!wc.isBusy(in: failedWrite.window) && wb.errors.count == 1 && wb.errors[0].0 === failedWrite.window && !FileManager.default.fileExists(atPath: failedWrite.root.appendingPathComponent("missing/result.pdf").path), "An actual file-write failure releases the job and reports an owning-window error without a partial destination")

        let printing = try fixture(), pb = OutputBoundaries(), pc = PageOutputCoordinator(environment: pb.environment)
        pc.printPage(web: printing.web, store: printing.store, window: printing.window)
        check(pb.prints.count == 1 && pb.prints[0].0 === printing.web && pb.prints[0].1 === printing.window && pb.captures.isEmpty, "Print presents the current WebKit document in its own window without a file capture")
        printing.window.close(); pb.prints[0].2(true)
        check(pb.cancellations == 1 && !pc.isBusy(in: printing.window), "Window close cancels its pending print presentation and ignores its late completion")
        let a = try fixture(), b = try fixture(), multi = OutputBoundaries(), multiple = PageOutputCoordinator(environment: multi.environment)
        multiple.save(web: a.web, store: a.store, window: a.window, format: .pdf)
        multiple.printPage(web: b.web, store: b.store, window: b.window)
        multiple.cancel(in: a.window)
        check(multiple.isBusy(in: b.window) && multi.prints.count == 1, "Cancelling one window does not release another window's print job")
        multi.prints[0].2(false)
        check(!multiple.isBusy(in: b.window), "A cancelled native print result releases only its own job")

        let synchronous = try fixture(), sb = OutputBoundaries(), sc = PageOutputCoordinator(environment: sb.environment)
        sb.immediateDestination = synchronous.destination
        sb.afterWrite = { sb.afterWrite = nil; sc.save(web: synchronous.web, store: synchronous.store, window: synchronous.window, format: .pdf) }
        sc.save(web: synchronous.web, store: synchronous.store, window: synchronous.window, format: .pdf)
        sb.captures[0].2(.success(bytes))
        check(sc.isBusy(in: synchronous.window) && sb.captures.count == 2, "Synchronous picker/write completion does not clear a reentrant replacement job")
        sc.cancel(in: synchronous.window)
        check(sb.cancellations == 0, "A completed picker cannot install its stale cancellation handle on a replacement job")

        let accepted = try fixture(), ab = OutputBoundaries(), ac = PageOutputCoordinator(environment: ab.environment)
        ab.deferWrite = true
        ac.save(web: accepted.web, store: accepted.store, window: accepted.window, format: .pdf)
        ab.captures[0].2(.success(bytes)); ab.choices[0].3(accepted.destination)
        accepted.window.close(); accepted.store.message = "Current message"
        ab.pendingWrite?()
        check(try Data(contentsOf: accepted.destination) == bytes && accepted.store.message == "Current message", "Accepted atomic output may finish after close without a stale status message")
        let background = try fixture(), bg = OutputBoundaries(), backgroundOutput = PageOutputCoordinator(environment: bg.environment)
        bg.deferWrite = true
        backgroundOutput.save(web: background.web, store: background.store, window: background.window, format: .pdf)
        bg.captures[0].2(.success(bytes)); bg.choices[0].3(background.root.appendingPathComponent("missing/output.pdf"))
        background.window.fixtureKey = false; background.store.message = "Other window status"
        bg.pendingWrite?()
        check(background.store.message == "Other window status" && bg.errors.isEmpty && !backgroundOutput.isBusy(in: background.window), "A background write error cannot publish its filename or status into another window's UI")
        background.store.message = "Other window status"
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other.window)
        background.window.fixtureKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: background.window)
        check(bg.errors.count == 1 && bg.errors[0].0 === background.window && background.store.message == "Other window status", "A background output error is delivered only to its own unchanged document when it regains focus")
        let waiting = try fixture(), waitBoundary = OutputBoundaries(), waitingOutput = PageOutputCoordinator(environment: waitBoundary.environment)
        waitingOutput.save(web: waiting.web, store: waiting.store, window: waiting.window, format: .pdf)
        waiting.window.fixtureKey = false; waitBoundary.captures[0].2(.success(bytes))
        check(waitBoundary.choices.isEmpty && waitingOutput.isBusy(in: waiting.window), "A prepared export waits for its original window instead of interrupting another window")
        waiting.window.fixtureKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: waiting.window)
        check(waitBoundary.choices.count == 1 && waitBoundary.choices[0].0 === waiting.window, "Returning to the original document presents its already requested save sheet once")
        waitingOutput.cancel(in: waiting.window)

        let timed = try fixture(), tb = OutputBoundaries(), tc = PageOutputCoordinator(environment: tb.environment, preparationTimeout: .milliseconds(30))
        tc.save(web: timed.web, store: timed.store, window: timed.window, format: .pdf)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while tc.isBusy(in: timed.window) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        tb.captures[0].2(.success(bytes))
        check(!tc.isBusy(in: timed.window) && tb.choices.isEmpty && tb.writes == 0, "A stalled WebKit capture times out and cannot later reopen the output flow")
        check(PageOutputFormat.pdf.suggestedName(nil) == "Page.pdf" && PageOutputFormat.webArchive.suggestedName("   ... ") == "Page.webarchive", "Empty document titles get visible format-correct filename defaults")
        let unsafe = PageOutputFormat.pdf.suggestedName("Report/../../Secret\u{0}:copy")
        check(!unsafe.contains("/") && !unsafe.contains(":") && !unsafe.contains("\u{0}") && !unsafe.hasPrefix(".") && unsafe.hasSuffix(".pdf"), "A document title cannot turn the suggested filename into a path or hidden control name")
        let unicode = PageOutputFormat.webArchive.suggestedName(String(repeating: "📚", count: 300))
        check(unicode.utf8.count < 240 && unicode.hasSuffix(".webarchive") && !unicode.contains("�"), "Long Unicode titles stay within filename byte bounds without breaking characters")
        if failures > 0 { throw OutputCheckError.expected }
    }
}
