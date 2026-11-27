import Foundation

public struct EaselExportLayout: Equatable, Sendable {
    public let originX: Double, originY: Double, width: Double, height: Double
    public let pixelWidth: Int, pixelHeight: Int, scale: Double
    public init(easel: Easel) {
        if easel.items.isEmpty { originX = 0; originY = 0; width = 960; height = 640 }
        else {
            let left = easel.items.map(\.frame.x).min()! - 48, top = easel.items.map(\.frame.y).min()! - 48
            let right = easel.items.map { $0.frame.x + $0.frame.width }.max()! + 48
            let bottom = easel.items.map { $0.frame.y + $0.frame.height }.max()! + 48
            originX = left; originY = top; width = right - left; height = bottom - top
        }
        let bound = min(2, 8192 / width, 8192 / height, sqrt(16_000_000 / (width * height)))
        pixelWidth = max(1, Int((width * bound).rounded(.down)))
        pixelHeight = max(1, Int((height * bound).rounded(.down)))
        scale = min(Double(pixelWidth) / width, Double(pixelHeight) / height)
    }
}

public enum EaselExportError: LocalizedError {
    case invalidImage, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "A saved canvas image could not be prepared for export. Existing cards were kept."
        case .tooLarge: return "This portable HTML file would exceed 128 MiB. Export a smaller canvas or use PNG. Existing cards were kept."
        }
    }
}

/// The native renderer supplies validated, normalized PNGs sequentially. This
/// formatter embeds only data URLs and escaped text; no page code is exported.
public struct EaselHTMLExport: Sendable {
    public let data: Data
    public init(easel: Easel, background: ThemeColor? = nil, pngForAsset: (UUID) throws -> Data) throws {
        let maximum = 128 * 1024 * 1024
        var output = Data(), images: [UUID: String] = [:]
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        func append(_ text: String) throws {
            guard text.utf8.count <= maximum - output.count else { throw EaselExportError.tooLarge }
            output.append(contentsOf: text.utf8)
        }
        func link(_ title: String, _ url: String) -> String {
            "<a href=\"" + escaped(url) + "\" target=\"_blank\" rel=\"noopener noreferrer\">" + escaped(title) + "</a>"
        }
        let layout = EaselExportLayout(easel: easel)
        let backgroundRule = background.map { value -> String in
            let color = ThemeColor(value.red, value.green, value.blue)
            return "body,main{background:rgb(\(Int((color.red * 255).rounded())),\(Int((color.green * 255).rounded())),\(Int((color.blue * 255).rounded())))}"
        } ?? ""
        try append("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
        try append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; object-src 'none'\">")
        try append("<title>" + escaped(easel.title) + "</title><style>body{margin:0;background:#eceef2;color:#18212b;font:14px -apple-system,BlinkMacSystemFont,sans-serif;color-scheme:light}header{padding:24px;font-size:22px;font-weight:600}main{position:relative;background:#f8f9fb;margin:0 24px 24px;border-radius:16px}.card{position:absolute;box-sizing:border-box;border:1px solid #d5dae0;border-radius:12px;background:white;padding:14px;overflow:auto;white-space:pre-wrap;unicode-bidi:plaintext;line-height:1.4}.drawing{border:0;background:none;padding:0;overflow:hidden}.drawing>svg{display:block;width:100%;height:100%}.image{display:block;width:100%;height:calc(100% - 24px);object-fit:contain}.source{font-size:11px;margin-top:5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}a{color:#245c88}\(backgroundRule)</style></head><body>")
        try append("<header>" + escaped(easel.title) + "</header><main aria-label=\"Canvas\" style=\"width:\(layout.width)px;height:\(layout.height)px\">")
        for item in easel.items {
            try Task.checkCancellation()
            let f = item.frame
            let cardClass: String
            if case .drawing = item.content { cardClass = "card drawing" } else { cardClass = "card" }
            try append("<section class=\"\(cardClass)\" dir=\"auto\" style=\"left:\(f.x - layout.originX)px;top:\(f.y - layout.originY)px;width:\(f.width)px;height:\(f.height)px\">")
            switch item.content {
            case .note(let text): try append(escaped(text))
            case .link(let title, let url): try append(link(title, url))
            case .drawing(let drawing): try append(EaselDrawingSVG.markup(for: drawing))
            case .image(let id, _, _, let url, let title):
                let encoded: String
                if let existing = images[id] { encoded = existing }
                else {
                    let png = try pngForAsset(id)
                    guard png.starts(with: [137,80,78,71,13,10,26,10]), png.count <= 64 * 1024 * 1024 else { throw EaselExportError.invalidImage }
                    encoded = png.base64EncodedString(); images[id] = encoded
                }
                try append("<img class=\"image\" loading=\"lazy\" decoding=\"async\" alt=\"" + escaped(title ?? "Saved canvas image") + "\" src=\"data:image/png;base64," + encoded + "\">")
                if let url { try append("<div class=\"source\">" + link(title ?? url, url) + "</div>") }
            }
            try append("</section>")
        }
        try append("</main></body></html>")
        data = output
    }
}
