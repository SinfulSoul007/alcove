import Foundation
import Darwin

@main struct ReaderResourceChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-reader-resources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(label)"); if !value { failures += 1 } }
        func unavailable() -> Bool {
            do { _ = try ReaderResources.styleScript(at: root); return false }
            catch ReaderFailure.resources { return true }
            catch { return false }
        }
        check(unavailable(), "A missing style resource fails explicitly")
        try "".write(to: root.appendingPathComponent("Style.js"), atomically: true, encoding: .utf8)
        check(unavailable(), "An empty style resource fails explicitly")
        try String(repeating: "x", count: 20001).write(to: root.appendingPathComponent("Style.js"), atomically: true, encoding: .utf8)
        check(unavailable(), "An oversized style resource fails explicitly")
        try "return true;".write(to: root.appendingPathComponent("Style.js"), atomically: true, encoding: .utf8)
        check(try ReaderResources.styleScript(at: root) == "return true;", "A valid local style resource is loaded intact")
        print("READER_RESOURCE_CHECKS", checks, "FAILURES", failures)
        exit(failures == 0 ? 0 : 1)
    }
}
