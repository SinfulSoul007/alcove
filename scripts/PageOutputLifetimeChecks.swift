import AppKit
import WebKit
import BrowserCore

final class OutputPrintThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [Bool] = []
    func record(_ onMain: Bool) { lock.withLock { deliveries.append(onMain) } }
    var values: [Bool] { lock.withLock { deliveries } }
}

@MainActor final class OutputQuitBoundary {
    var counts: [Int] = [], callbacks: [(PageOutputQuitChoice) -> Void] = []
    var cancellations = 0
    var immediateChoice: PageOutputQuitChoice?
    var presenter: (Int, @escaping (PageOutputQuitChoice) -> Void) -> (() -> Void) {
        { count, done in
            self.counts.append(count); self.callbacks.append(done)
            if let choice = self.immediateChoice { done(choice) }
            return { self.cancellations += 1 }
        }
    }
}

@main struct PageOutputLifetimeChecks {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { throw OutputCheckError.expected }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, fixtures: [OutputFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func fixture() throws -> OutputFixture { let value = try OutputFixture(); fixtures.append(value); return value }
        func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL"): \(name)"); if !ok { failures += 1 } }
        let bytes = Data("Explicitly accepted private document".utf8)
        func accept(_ f: OutputFixture, _ b: OutputBoundaries, _ c: PageOutputCoordinator, fail: Bool = false) {
            c.save(web: f.web, store: f.store, window: f.window, format: .pdf)
            b.captures.last!.2(.success(bytes))
            b.choices.last!.3(fail ? f.root.appendingPathComponent("missing/PRIVATE_FILE.pdf") : f.destination)
        }
        let f = try fixture(), boundary = OutputBoundaries(), output = PageOutputCoordinator(environment: boundary.environment)
        boundary.deferWrite = true; f.web.fixtureTitle = "PRIVATE DOCUMENT TITLE"
        accept(f, boundary, output)
        check(output.pendingWriteCount == 1 && output.pendingOutputCount == 1, "Accepted file IO has application lifetime independent of its window job")
        f.window.close()
        var settled: [Bool] = []
        output.waitForPendingOutput { settled.append($0) }
        check(output.pendingWriteCount == 1 && settled.isEmpty, "Closing a source window does not erase an accepted write or release its waiters")
        boundary.pendingWrites[0]()
        check(try Data(contentsOf: f.destination) == bytes && settled == [true] && output.pendingOutputCount == 0, "A closed-window export settles only after the accepted bytes reach the selected file")
        boundary.writeCompletions[0](.failure(OutputCheckError.expected))
        check(settled == [true] && boundary.orphanedErrors.isEmpty, "A duplicate late completion cannot report a second result or decrement a new operation")
        let failed = try fixture(), fb = OutputBoundaries(), fc = PageOutputCoordinator(environment: fb.environment)
        fb.deferWrite = true; failed.web.fixtureTitle = "PRIVATE DOCUMENT TITLE"
        accept(failed, fb, fc, fail: true); failed.window.close()
        var failedSettlement: Bool?
        fc.waitForPendingOutput { failedSettlement = $0 }; fb.pendingWrites[0]()
        check(failedSettlement == false && fb.orphanedErrors.count == 1 && fb.errors.isEmpty, "A closed-window file failure reaches a generic app-owned result and fails its wait")
        check(fb.orphanedErrors.allSatisfy { !$0.contains("PRIVATE") && !$0.contains(failed.root.path) && !$0.contains("output.example.invalid") }, "Orphaned private failures reveal no captured title, URL or destination path")
        for change in ["URL", "close", "new job"] {
            let item = try fixture(), b = OutputBoundaries(), c = PageOutputCoordinator(environment: b.environment)
            b.deferWrite = true; accept(item, b, c, fail: true)
            item.window.fixtureKey = false; b.pendingWrites[0]()
            check(b.errors.isEmpty && b.orphanedErrors.isEmpty, "An unfocused live document defers its accepted-file error locally")
            switch change {
            case "URL": item.web.fixtureURL = URL(string: "https://replacement.example.invalid")
            case "close": item.window.close()
            default:
                item.window.fixtureKey = true
                c.save(web: item.web, store: item.store, window: item.window, format: .pdf)
                c.cancel(in: item.window)
            }
            item.window.fixtureKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: item.window)
            check(b.orphanedErrors.count == 1 && b.errors.isEmpty, "\(change) cannot silently discard an already failed accepted export")
        }
        let changed = try fixture(), cb = OutputBoundaries(), cc = PageOutputCoordinator(environment: cb.environment)
        cc.save(web: changed.web, store: changed.store, window: changed.window, format: .pdf)
        cb.captures[0].2(.success(bytes)); changed.web.fixtureURL = URL(string: "https://replacement.example.invalid")
        cb.choices[0].3(changed.destination)
        check(cb.writes == 0 && cb.orphanedErrors.count == 1 && !FileManager.default.fileExists(atPath: changed.destination.path), "Rejected explicit picker acceptance reports generic cancellation without saving a changed page")
        let pa = try fixture(), pb = OutputBoundaries(), pc = PageOutputCoordinator(environment: pb.environment)
        pc.printPage(web: pa.web, store: pa.store, window: pa.window); pa.window.close()
        var printSettled: Bool?
        pc.waitForPendingOutput { printSettled = $0 }
        check(pc.pendingOutputCount == 1 && pc.pendingWriteCount == 0 && printSettled == nil, "Native print preparation remains tracked after its source window closes")
        pb.prints[0].2(false)
        check(pc.pendingOutputCount == 0 && printSettled == true, "Cancelling native printing drains its operation without inventing a file-write failure")
        let one = try fixture(), two = try fixture(), mb = OutputBoundaries(), mc = PageOutputCoordinator(environment: mb.environment)
        mb.deferWrite = true; accept(one, mb, mc)
        var allSettled: Bool?
        mc.waitForPendingOutput { allSettled = $0 }; accept(two, mb, mc)
        mb.pendingWrites[0]()
        check(allSettled == nil && mc.pendingWriteCount == 1, "Waiting includes another file accepted before the output set becomes empty")
        mb.pendingWrites[1]()
        check(allSettled == true && mc.pendingOutputCount == 0, "All accepted output must settle before the shared waiter completes")

        let noQuit = OutputQuitBoundary(), idleDelegate = AppDelegate(pageOutput: mc, quitPresenter: noQuit.presenter)
        var idleReplies: [Bool] = []
        check(idleDelegate.terminationDecision(reply: { idleReplies.append($0) }) == .terminateNow && noQuit.counts.isEmpty && idleReplies.isEmpty, "Normal Quit needs no confirmation or later reply when no output is pending")
        let unowned = try fixture()
        idleDelegate.normalOwner = BrowserWindowOwner(store: one.store)
        check(idleDelegate.browserStore(in: unowned.window) == nil && idleDelegate.browserStore(in: nil) == nil, "A native result or Quit window cannot inherit a normal browser store for page shortcuts")
        idleDelegate.windows[one.window] = one.store
        check(idleDelegate.browserStore(in: one.window) === one.store, "Owned-window lookup still resolves the actual browser state")
        let general = [#selector(AppDelegate.settings), #selector(AppDelegate.checkUpdates), #selector(AppDelegate.customize), #selector(AppDelegate.openMain), #selector(AppDelegate.privateWindow)]
        check(general.allSatisfy { idleDelegate.validateMenuItem(NSMenuItem(title: "", action: $0, keyEquivalent: "")) }, "App settings, updates, customization and new windows remain available without a foreground document")
        let pageActions = [#selector(AppDelegate.reload), #selector(AppDelegate.back), #selector(AppDelegate.printPage), #selector(AppDelegate.savePage)]
        check(pageActions.allSatisfy { !idleDelegate.validateMenuItem(NSMenuItem(title: "", action: $0, keyEquivalent: "")) }, "A retained normal owner cannot enable page commands without its foreground window")

        for choice in [PageOutputQuitChoice.wait, .cancel, .quitNow] {
            let item = try fixture(), b = OutputBoundaries(), c = PageOutputCoordinator(environment: b.environment), q = OutputQuitBoundary()
            b.deferWrite = true; accept(item, b, c)
            let delegate = AppDelegate(pageOutput: c, quitPresenter: q.presenter)
            var replies: [Bool] = []
            let decision = delegate.terminationDecision { replies.append($0) }
            check(decision == .terminateLater && replies.isEmpty, "Pending output defers native termination before any asynchronous reply")
            try await waitUntil { q.callbacks.count == 1 }
            q.callbacks[0](choice)
            if choice == .wait {
                check(replies.isEmpty && c.pendingWriteCount == 1, "Wait keeps the application alive until accepted IO completes")
                b.pendingWrites[0](); try await waitUntil { replies.count == 1 }
                check(replies == [true], "Successful accepted IO completes the original Quit request once")
            } else {
                try await waitUntil { replies.count == 1 }
                check(replies == [choice == .quitNow] && c.pendingWriteCount == 1, "An explicit Quit choice changes termination without silently cancelling accepted IO")
                b.pendingWrites[0]()
            }
            q.callbacks[0](.quitNow)
            check(replies.count == 1 && q.counts == [1], "Repeated stale Quit choices cannot send duplicate termination replies")
        }
        let retry = try fixture(), rb = OutputBoundaries(), rc = PageOutputCoordinator(environment: rb.environment), rq = OutputQuitBoundary()
        rb.deferWrite = true; accept(retry, rb, rc, fail: true)
        let retryDelegate = AppDelegate(pageOutput: rc, quitPresenter: rq.presenter)
        var retryReplies: [Bool] = []
        _ = retryDelegate.terminationDecision { retryReplies.append($0) }
        try await waitUntil { rq.callbacks.count == 1 }; rq.callbacks[0](.wait)
        check(retryDelegate.resurfaceQuitChoices(), "Quit choices can be reopened after choosing to wait")
        try await waitUntil { rq.callbacks.count == 2 }
        rb.pendingWrites[0](); try await waitUntil { !retryReplies.isEmpty }
        check(retryReplies == [false] && rq.cancellations >= 1, "A failed accepted save cancels normal termination and dismisses the pending Quit prompt")
        rq.callbacks[1](.quitNow)
        check(retryReplies == [false], "A dismissed Quit prompt cannot override a failed-save cancellation")
        let fast = try fixture(), fastBoundary = OutputBoundaries(), fastOutput = PageOutputCoordinator(environment: fastBoundary.environment), fastQuit = OutputQuitBoundary()
        fastBoundary.deferWrite = true; accept(fast, fastBoundary, fastOutput)
        let fastDelegate = AppDelegate(pageOutput: fastOutput, quitPresenter: fastQuit.presenter)
        var fastReplies: [Bool] = []
        _ = fastDelegate.terminationDecision { fastReplies.append($0) }; fastBoundary.pendingWrites[0]()
        try await waitUntil { !fastReplies.isEmpty }
        check(fastReplies == [true] && fastQuit.counts.isEmpty, "Fast output completes Quit without flashing an unnecessary confirmation")
        let synchronous = try fixture(), sb = OutputBoundaries(), sc = PageOutputCoordinator(environment: sb.environment), sq = OutputQuitBoundary()
        sb.deferWrite = true; accept(synchronous, sb, sc); sq.immediateChoice = .cancel
        let synchronousDelegate = AppDelegate(pageOutput: sc, quitPresenter: sq.presenter)
        var synchronousReplies: [Bool] = []
        check(synchronousDelegate.terminationDecision { synchronousReplies.append($0) } == .terminateLater && synchronousReplies.isEmpty, "A synchronous Quit presenter cannot reply before the native termination decision returns")
        try await waitUntil { !synchronousReplies.isEmpty }
        check(synchronousReplies == [false] && sq.cancellations == 1, "A synchronous choice disposes its returned presentation handle exactly once")
        sb.pendingWrites[0](); sq.callbacks[0](.quitNow)
        check(synchronousReplies == [false], "Output settlement cannot revive a synchronously cancelled Quit")
        let first = try fixture(), last = try fixture(), wb = OutputBoundaries(), wc = PageOutputCoordinator(environment: wb.environment)
        wb.deferWrite = true; accept(first, wb, wc, fail: true); accept(last, wb, wc)
        var earlier: [Bool] = [], later: [Bool] = []
        wc.waitForPendingOutput { earlier.append($0) }; wc.waitForPendingOutput { earlier.append($0) }
        wb.pendingWrites[0](); wc.waitForPendingOutput { later.append($0) }
        check(earlier.isEmpty && later.isEmpty, "A failed file does not release any waiter while another accepted operation is pending")
        wb.pendingWrites[1]()
        check(earlier == [false, false] && later == [true], "Each waiter tracks failures during its own wait and completes exactly once")
        for stage in ["capture", "picker", "accepted error", "deferred error", "away and back"] {
            let item = try fixture(), b = OutputBoundaries(), c = PageOutputCoordinator(environment: b.environment)
            b.deferWrite = true
            c.save(web: item.web, store: item.store, window: item.window, format: .pdf)
            if stage != "capture" { b.captures[0].2(.success(bytes)) }
            if stage == "accepted error" || stage == "deferred error" {
                b.choices[0].3(item.root.appendingPathComponent("missing/private.pdf"))
                if stage == "deferred error" { item.window.fixtureKey = false; b.pendingWrites[0]() }
            }
            if stage == "away and back" { item.web.fixtureURL = URL(string: "https://replacement.example.invalid"); item.store.webView(item.web, didCommit: nil); item.web.fixtureURL = URL(string: "https://output.example.invalid/alpha") }
            item.store.webView(item.web, didCommit: nil)
            switch stage {
            case "capture": b.captures[0].2(.success(bytes))
            case "picker", "away and back": b.choices[0].3(item.destination)
            case "accepted error": b.pendingWrites[0]()
            default: item.window.fixtureKey = true; NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: item.window)
            }
            let correct = stage == "capture" ? b.choices.isEmpty && b.writes == 0 : b.orphanedErrors.count == 1 && b.errors.isEmpty && (stage.contains("error") || b.writes == 0)
            check(correct, "A same-URL document replacement invalidates \(stage) ownership without touching the replacement document")
        }
        for beganBeforeRequest in [false, true] {
            let item = try fixture(), b = OutputBoundaries(), c = PageOutputCoordinator(environment: b.environment)
            if beganBeforeRequest { item.store.webView(item.web, didStartProvisionalNavigation: nil) }
            c.save(web: item.web, store: item.store, window: item.window, format: .pdf)
            if beganBeforeRequest { item.store.webView(item.web, didCommit: nil) }
            else { item.store.webView(item.web, didStartProvisionalNavigation: nil) }
            b.captures[0].2(.success(bytes))
            check(b.choices.isEmpty && b.writes == 0, beganBeforeRequest ? "A navigation already underway at capture invalidates output when its document commits" : "Provisional navigation invalidates pending output before its URL or document commits")
        }
        let unchanged = try fixture(), ub = OutputBoundaries(), uc = PageOutputCoordinator(environment: ub.environment)
        uc.save(web: unchanged.web, store: unchanged.store, window: unchanged.window, format: .pdf)
        unchanged.store.revision += 1; ub.captures[0].2(.success(bytes)); ub.choices[0].3(unchanged.destination)
        check(ub.writes == 1 && (try? Data(contentsOf: unchanged.destination)) == bytes, "An unrelated browser revision does not invalidate the original document's explicit export")
        let printFixture = try fixture(), printProbe = OutputPrintThreadProbe()
        let operation = PageOutputNative.printOperation(for: printFixture.web)
        let nativeJob = PageOutputNative.PrintJob(operation: operation, window: printFixture.window) { _ in printProbe.record(Thread.isMainThread) }
        typealias PrintCallback = @convention(c) (AnyObject, Selector, NSPrintOperation, Bool, UnsafeMutableRawPointer?) -> Void
        let selector = Selector(("didRun:success:contextInfo:"))
        let invoke = unsafeBitCast(nativeJob.method(for: selector), to: PrintCallback.self)
        await Task.detached { invoke(nativeJob, selector, operation, true, nil); invoke(nativeJob, selector, operation, false, nil) }.value
        try await waitUntil { !printProbe.values.isEmpty }
        check(printProbe.values == [true], "A native Objective-C print callback from a worker delivers once on the main actor")
        if failures > 0 { throw OutputCheckError.expected }
    }
}
