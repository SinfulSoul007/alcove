import Foundation
import CryptoKit
import BrowserCore

@main struct WebsiteThreatCoreChecks {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        let rows = Data("phishing.example\nxn--bcher-kva.example\nlogin.bad.example\n".utf8)
        let fixtureDigest = "8780e2deb7a76c39f95a245e1a05c149e3bfa60a7ee838374736cf292d3a1764"
        var fields: [String: Any] = [
            "formatVersion": 1, "provider": "PhishDestroy",
            "sourceRevision": "c22df68d2bded72fdb5415f929556dd220c8056c",
            "sourceUpdatedAt": "2026-11-01T00:00:00Z", "retrievedAt": "2026-11-02T00:00:00Z",
            "sha256": fixtureDigest, "domainCount": 3,
            "licenseSHA256": String(repeating: "a", count: 64)
        ]
        func metadata(_ changed: [String: Any] = [:]) throws -> Data {
            var value = fields
            for (key, entry) in changed { value[key] = entry }
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func rejected(_ name: String, _ expected: WebsiteThreatCatalogError, domains: Data? = nil, changes: [String: Any] = [:], rawMetadata: Data? = nil) throws {
            do {
                _ = try WebsiteThreatCatalog(domains: domains ?? rows, metadata: rawMetadata ?? metadata(changes))
                check(false, name)
            } catch let error as WebsiteThreatCatalogError { check(error == expected, name) }
            catch { check(false, name + " (unexpected error)") }
        }
        let catalog = try WebsiteThreatCatalog(domains: rows, metadata: metadata())
        check(catalog.domainCount == 3 && catalog.metadata.provider == "PhishDestroy", "Verified source count and provider survive catalog loading")
        let matches: [(String, String, String)] = [
            ("https://phishing.example/login?secret=owned#fragment", "phishing.example", "phishing.example"),
            ("HTTP://PHISHING.EXAMPLE:8080/", "phishing.example", "phishing.example"),
            ("https://one.two.phishing.example/", "one.two.phishing.example", "phishing.example"),
            ("https://phishing.example./", "phishing.example", "phishing.example"),
            ("https://%70hishing.example/", "phishing.example", "phishing.example"),
            ("https://phishing%2eexample/", "phishing.example", "phishing.example"),
            ("https://safe.example@phishing.example/", "phishing.example", "phishing.example"),
            ("https://bücher.example/", "xn--bcher-kva.example", "xn--bcher-kva.example"),
            ("https://shop.xn--bcher-kva.example/", "shop.xn--bcher-kva.example", "xn--bcher-kva.example"),
            ("https://sub.login.bad.example/", "sub.login.bad.example", "login.bad.example")
        ]
        for (text, host, listed) in matches {
            let hit = catalog.threat(for: URL(string: text)!)
            check(hit?.host == host && hit?.listedHost == listed, "Classifies the real destination host: " + text)
        }
        for text in [
            "https://notphishing.example/", "https://phishing.example.safe.example/",
            "https://phishing-example/", "https://safe.example/phishing.example",
            "https://safe.example/?next=https://phishing.example", "https://phishing.example@safe.example/",
            "https://bad.example/", "https://login-bad.example/", "https://other.bad.example/",
            "https://127.0.0.1/", "https://2130706433/", "http://[::1]/", "http://localhost/",
            "file://phishing.example/a", "ftp://phishing.example/", "data:text/plain,phishing.example",
            "about:blank", "webkit-extension://phishing.example/options.html",
            "https://testsafebrowsing.appspot.com/s/phishing.html"
        ] {
            check(catalog.threat(for: URL(string: text)!) == nil, "Unlisted, unrelated or non-web address has no catalog match: " + text)
        }
        let updated = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
        check(!catalog.isStale(at: updated.addingTimeInterval(30 * 86400)), "A snapshot reaches, but has not exceeded, its 30-day freshness boundary")
        check(catalog.isStale(at: updated.addingTimeInterval(30 * 86400 + 1)), "A snapshot older than 30 days is stale")
        fields["retrievedAt"] = "2026-11-30T00:00:00Z"
        let downloadedLater = try WebsiteThreatCatalog(domains: rows, metadata: metadata())
        check(downloadedLater.isStale(at: updated.addingTimeInterval(31 * 86400)), "A newer retrieval date cannot make old threat data fresh")
        fields["retrievedAt"] = "2026-11-02T00:00:00Z"

        try rejected("Edited bytes are rejected before they can become a trusted catalog", .checksumMismatch, domains: Data("phishing.example\nxn--bcher-kva.example\nlogon.bad.example\n".utf8))
        try rejected("Wrong declared source digest is rejected", .checksumMismatch, changes: ["sha256": String(repeating: "0", count: 64)])
        try rejected("Missing metadata cannot become active protection", .invalidMetadata, rawMetadata: Data())
        try rejected("An oversized metadata document is bounded before decoding", .invalidMetadata, rawMetadata: Data(repeating: 32, count: 16_385))
        try rejected("Unknown catalog versions are rejected", .invalidMetadata, changes: ["formatVersion": 2])
        try rejected("An unexpected provider cannot replace the curated source", .invalidMetadata, changes: ["provider": "Other"])
        try rejected("A source revision must identify an immutable commit", .invalidMetadata, changes: ["sourceRevision": "main"])
        try rejected("A missing or malformed license digest is rejected", .invalidMetadata, changes: ["licenseSHA256": "missing"])
        try rejected("Invalid dates are rejected", .invalidMetadata, changes: ["sourceUpdatedAt": "yesterday"])
        try rejected("Content cannot be newer than its recorded retrieval", .invalidMetadata, changes: ["sourceUpdatedAt": "2026-12-01T00:00:00Z"])
        try rejected("An empty catalog is not active protection", .invalidMetadata, changes: ["domainCount": 0])
        try rejected("Declared entry counts must match validated data", .invalidDomains, changes: ["domainCount": 4])
        try rejected("Excessive declared entries cannot reserve unbounded memory", .invalidMetadata, changes: ["domainCount": 1_000_001])
        try rejected("Oversized source data is rejected before hashing/parsing", .tooLarge, domains: Data(repeating: 97, count: 8_388_609))
        let duplicates = Data("phishing.example\nphishing.example\n".utf8)
        try rejected("Duplicate rows are rejected even when the physical row count matches metadata", .invalidDomains, domains: duplicates, changes: ["sha256": SHA256.hash(data: duplicates).map { String(format: "%02x", $0) }.joined(), "domainCount": 2])
        for bad in ["https://phishing.example/\n", "com\n", "a..example\n", "-a.example\n", "a-.example\n", "a_b.example\n", "127.0.0.1\n", "a.example\n\n", String(repeating: "a", count: 64) + ".example\n"] {
            let bytes = Data(bad.utf8)
            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try rejected("Malformed or duplicate source rows are not silently skipped", .invalidDomains, domains: bytes, changes: ["sha256": sha, "domainCount": 1])
        }
        let invalidUTF8 = Data([0xff, 0xfe])
        try rejected("Non-UTF8 threat data is rejected", .invalidDomains, domains: invalidUTF8, changes: ["sha256": SHA256.hash(data: invalidUTF8).map { String(format: "%02x", $0) }.joined(), "domainCount": 1])

        if let path = CommandLine.arguments.dropFirst().first {
            let root = URL(fileURLWithPath: path)
            let source = try WebsiteThreatCatalog(domains: Data(contentsOf: root.appendingPathComponent("domains.txt")), metadata: Data(contentsOf: root.appendingPathComponent("source.json")))
            let license = try Data(contentsOf: root.appendingPathComponent("LICENSE.PhishDestroy.txt"))
            let digest = SHA256.hash(data: license).map { String(format: "%02x", $0) }.joined()
            check(source.domainCount > 0 && source.metadata.provider == "PhishDestroy", "The bundled curated source is nonempty and passes its declared integrity/count checks")
            print("WEBSITE_THREAT_BUNDLED_ENTRIES",source.domainCount,"SOURCE",source.metadata.sourceRevision)
            check(digest == source.metadata.licenseSHA256, "The redistributed license matches pinned provenance")
            for host in ["google.com", "github.com", "apple.com", "github.io", "appspot.com", "pages.dev", "vercel.app", "co.uk"] {
                check(source.threat(for: URL(string: "https://" + host + "/")!) == nil, "The pinned source does not classify a common shared/safe host: " + host)
            }
        }
        print("WEBSITE_THREAT_CORE_CHECKS", checks, "FAILURES", failures)
        if failures != 0 { exit(1) }
    }
}
