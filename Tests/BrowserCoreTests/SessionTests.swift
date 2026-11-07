import XCTest
@testable import BrowserCore
final class SessionTests: XCTestCase {
    func testAddressesAndSearch() {
        XCTAssertEqual(Address.resolve("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(Address.resolve("localhost:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(Address.resolve("https://example.com/a?q=x")?.absoluteString, "https://example.com/a?q=x")
        XCTAssertTrue(Address.resolve("cats & dogs")?.absoluteString.contains("q=cats%20%26%20dogs") == true)
        XCTAssertNil(Address.resolve("  "))
        XCTAssertNil(Address.resolve("javascript:alert(1)"))
        XCTAssertNil(Address.resolve("file:///etc/passwd"))
    }
    func testClosingSelectedTabKeepsUsableSpace() {
        var session = Session()
        let spaceID = session.selectedSpace
        let tabID = session.spaces[0].tabs[0].id
        session.close(tabID, in: spaceID)
        XCTAssertEqual(session.spaces[0].tabs.count, 1)
        XCTAssertNotEqual(session.spaces[0].tabs[0].id, tabID)
        XCTAssertEqual(session.spaces[0].selected, session.spaces[0].tabs[0].id)
    }
    func testSessionRoundTripRetainsPinnedTabs() throws {
        var session = Session()
        session.spaces[0].tabs[0] = Tab(title: "Docs", url: "https://webkit.org", pinned: true)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded.spaces[0].tabs, session.spaces[0].tabs)
        XCTAssertEqual(decoded.selectedSpace, session.selectedSpace)
    }
}
