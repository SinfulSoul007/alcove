import Foundation

/// Generates owned local HTML for a plain headless --dump-dom invocation. No
/// debugger/automation port, existing browser profile or app window is involved.
@main struct ReaderStyleFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let style = try ReaderResources.styleScript(at: root)
        let checks = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let prose = String(repeating: "A patient reader follows the river through the mountains. Each sentence describes the landscape and the people who live here. ", count: 20)
        let article = (0..<60).map { "<p id='passage-\($0)'>Passage \($0). \(prose)</p>" }.joined()
        var html = ReaderDocument.html(title: "Owned passage checks", byline: "Local fixture", site: "Owned", direction: "ltr", content: article)
        // Only this owned test document permits the trusted driving script. The
        // actual ReaderDocument producer keeps script-src 'none' in the app.
        html = html.replacingOccurrences(of: "script-src 'none'", with: "script-src 'unsafe-inline'")
        let driver = "function applyStyle(paper,ink,muted,link,size,width,font) {\n" + style + "\n}\n" + checks
        html = html.replacingOccurrences(of: "</body>", with: "<script>" + driver + "</script></body>")
        try html.write(toFile: CommandLine.arguments[3], atomically: true, encoding: .utf8)
    }
}
