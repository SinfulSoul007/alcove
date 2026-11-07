import Foundation
import BrowserCore
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    if value() { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
}
check(Address.resolve("example.com")?.absoluteString == "https://example.com", "Domain defaults to HTTPS")
check(Address.resolve("localhost:8080")?.absoluteString == "http://localhost:8080", "Local development uses HTTP")
check(Address.resolve("https://example.com/a?q=x")?.absoluteString == "https://example.com/a?q=x", "Explicit URL preserved")
check(Address.resolve("cats & dogs")?.absoluteString.contains("q=cats%20%26%20dogs") == true, "Search escapes query separators")
check(Address.resolve("  ") == nil, "Empty address rejected")
check(Address.resolve("javascript:alert(1)") == nil, "JavaScript address rejected")
check(Address.resolve("file:///etc/passwd") == nil, "File address rejected")
var session = Session()
let original = session.spaces[0].tabs[0].id
session.close(original, in: session.selectedSpace)
check(session.spaces[0].tabs.count == 1 && session.spaces[0].tabs[0].id != original, "Closing last tab creates usable empty tab")
check(session.spaces[0].selected == session.spaces[0].tabs[0].id, "Selection repaired after close")
session.spaces[0].tabs.append(Tab(title: "Docs", url: "https://webkit.org", pinned: true))
let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
check(decoded.spaces[0].tabs == session.spaces[0].tabs && decoded.selectedSpace == session.selectedSpace, "Session persists URLs, pins and selection")
exit(failures == 0 ? 0 : 1)
