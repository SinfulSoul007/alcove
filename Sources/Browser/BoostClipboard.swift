import AppKit
import BrowserCore

enum BoostClipboardError: LocalizedError {
    case empty, unavailable
    var errorDescription: String? {
        switch self {
        case .empty: return "Copy an Alcove appearance before pasting. JavaScript is never included in appearance sharing."
        case .unavailable: return "The clipboard could not be updated. Try copying the appearance again."
        }
    }
}
@MainActor enum BoostClipboard {
    static let type = NSPasteboard.PasteboardType("org.alcove.boost-appearance")
    static func copy(_ boost: SiteBoost, to pasteboard: NSPasteboard? = nil) throws {
        var appearanceOnly = boost; appearanceOnly.content.javascript = ""; appearanceOnly.approvedJavaScriptHash = nil
        let data = try appearanceOnly.portableData()
        guard let string = String(data: data, encoding: .utf8) else { throw BoostError.invalidImport }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: type), item.setString(string, forType: .string) else { throw BoostClipboardError.unavailable }
        let board = pasteboard ?? .general; board.clearContents()
        guard board.writeObjects([item]) else { throw BoostClipboardError.unavailable }
    }
    static func read(from pasteboard: NSPasteboard? = nil) throws -> SiteBoost {
        let board = pasteboard ?? .general
        if let data = board.data(forType: type) { return try SiteBoost.importing(data) }
        guard let text = board.string(forType: .string) else { throw BoostClipboardError.empty }
        guard text.utf8.count <= 1048576 else { throw BoostError.payloadTooLarge }
        return try SiteBoost.importing(Data(text.utf8))
    }
}
