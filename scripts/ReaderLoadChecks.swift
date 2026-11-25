import Foundation
import Darwin

@main struct ReaderLoadChecks {
    static func main() {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(label)"); if !value { failures += 1 } }
        var normal = ReaderLoadState()
        check(!normal.finishDocument() && normal.phase == .loading, "Completion before an article load cannot make Reader ready")
        check(normal.beginDocument() && normal.finishDocument() && normal.phase == .ready, "A current article load becomes ready once")
        check(!normal.finishDocument(), "Duplicate completion cannot repeat presentation effects")
        var timeout = ReaderLoadState()
        _ = timeout.beginDocument(); _ = timeout.fail("Preparing article timed out")
        check(!timeout.isLoadingDocument, "Failure revokes the pending local document load")
        check(!timeout.finishDocument() && timeout.phase == .failed("Preparing article timed out"), "A late completion cannot replace failure or authorize focus")
        check(!timeout.beginDocument(), "A failed session cannot begin another article load")
        _ = timeout.fail("Navigation cancelled")
        check(timeout.phase == .failed("Preparing article timed out"), "Cancellation after failure retains the original explanation")
        var closed = ReaderLoadState()
        _ = closed.beginDocument(); closed.close()
        check(!closed.finishDocument() && !closed.beginDocument() && !closed.fail("late error") && closed.phase == .closed, "A closed Reader cannot be revived by callbacks")
        var terminated = ReaderLoadState()
        _ = terminated.beginDocument(); _ = terminated.finishDocument(); _ = terminated.fail("Reader process stopped")
        check(terminated.phase == .failed("Reader process stopped") && !terminated.finishDocument(), "A ready Reader can fail without allowing a later completion")
        print("READER_LOAD_CHECKS", checks, "FAILURES", failures)
        exit(failures == 0 ? 0 : 1)
    }
}
