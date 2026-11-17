import Foundation

public enum OpenSearchDescription {
    public static let maximumBytes = 64 * 1024

    public static func advertisedURL(_ href: String, on page: URL) -> URL? {
        let text = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 8192,
              let address = URL(string: text, relativeTo: page)?.absoluteURL,
              address.fragment == nil, isSameOrigin(address, as: page) else { return nil }
        return address
    }

    public static func siteSearch(from data: Data, at descriptor: URL, keyword: String) throws -> SiteSearch {
        guard !data.isEmpty, data.count <= maximumBytes,
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.localName == "OpenSearchDescription",
              root.uri == nil || root.uri == "http://a9.com/-/spec/opensearch/1.1/" else {
            throw DescriptionError.invalidDocument
        }
        let elements = (root.children ?? []).compactMap { $0 as? XMLElement }
        let shortName = elements.first(where: { $0.localName == "ShortName" })?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = shortName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? descriptor.host ?? "Site Search"

        for element in elements where element.localName == "Url" {
            guard let type = element.attribute(forName: "type")?.stringValue?.split(separator: ";").first,
                  type.trimmingCharacters(in: .whitespaces).lowercased() == "text/html",
                  (element.attribute(forName: "method")?.stringValue?.uppercased() ?? "GET") == "GET",
                  (element.attribute(forName: "rel")?.stringValue ?? "results").split(whereSeparator: \.isWhitespace).contains("results"),
                  let raw = element.attribute(forName: "template")?.stringValue,
                  let template = searchTemplate(raw, relativeTo: descriptor) else { continue }
            if let site = try? SiteSearch(name: name, keyword: keyword, template: template).validated() { return site }
        }
        throw DescriptionError.noSearchURL
    }

    private static func searchTemplate(_ raw: String, relativeTo descriptor: URL) -> String? {
        let token = "alcove-search-query-placeholder"
        guard raw.utf8.count <= 8192, !raw.contains(token) else { return nil }
        let text = raw.replacingOccurrences(of: "{searchTerms?}", with: "{searchTerms}")
            .replacingOccurrences(of: "{searchTerms}", with: token)
            .replacingOccurrences(of: #"\{[A-Za-z_][A-Za-z0-9_.:-]*\?\}"#, with: "", options: .regularExpression)
        guard text.components(separatedBy: token).count == 2, !text.contains("{"), !text.contains("}"),
              let url = URL(string: text, relativeTo: descriptor)?.absoluteURL, isSameOrigin(url, as: descriptor) else { return nil }
        return url.absoluteString.replacingOccurrences(of: token, with: "%s")
    }

    private static func isSameOrigin(_ url: URL, as base: URL) -> Bool {
        guard let origin = WebOrigin(base), WebOrigin(url) == origin,
              url.user == nil, url.password == nil, base.user == nil, base.password == nil else { return false }
        // WebOrigin normalizes trailing dots for routing. A document origin distinguishes them.
        return url.host?.hasSuffix(".") == base.host?.hasSuffix(".")
    }

    private enum DescriptionError: LocalizedError {
        case invalidDocument, noSearchURL

        var errorDescription: String? {
            switch self {
            case .invalidDocument: "This site’s search description couldn’t be read."
            case .noSearchURL: "This site doesn’t offer a compatible search shortcut."
            }
        }
    }
}
