import Foundation
import WebKit

enum BrowserTabPresentation: Equatable {
    case owned
    case elsewhere(windowID: UUID)
    case pooled
    case unavailable

    var canBringHere: Bool {
        switch self {
        case .elsewhere, .pooled: return true
        case .owned, .unavailable: return false
        }
    }
}

extension BrowserStore {
    var pageStores: [BrowserStore] { windowGroup?.stores ?? [self] }

    func primaryPageView(for id: UUID) -> WKWebView? {
        guard !isShuttingDown else { return nil }
        if let windowGroup, windowGroup.presentation(tabID: id, in: self) != .owned { return nil }
        return view(for: id)
    }

    func discardSharedView(_ id: UUID) {
        if let windowGroup { windowGroup.discardPage(id) }
        else { discardView(id) }
    }
}
