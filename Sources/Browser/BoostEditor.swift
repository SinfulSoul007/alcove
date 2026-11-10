import AppKit
import Combine
import WebKit
import BrowserCore

@MainActor final class BoostEditor: ObservableObject {
    weak var owner: BrowserStore?
    let source: BoostEditSource?
    @Published private(set) var profileID: UUID
    @Published var draft: SiteBoost
    @Published private(set) var original: SiteBoost?
    @Published var error: String?
    @Published private(set) var isSaving = false
    private var saveGeneration = UUID()
    private var initialContent: BoostContent
    private var newIntent = false
    init(store: BrowserStore, profileID: UUID, source: BoostEditSource? = nil, initial: SiteBoost? = nil) {
        owner = store; self.profileID = profileID; self.source = source
        let value = initial ?? SiteBoost(content: BoostContent(name: "Personal look", host: source?.host ?? ""))
        draft = value; original = initial; initialContent = value.content
    }
    var isDirty: Bool { original.map { draft.content != $0.content } ?? (newIntent || draft.content != initialContent) }
    private func requireOwner(_ store: BrowserStore) throws {
        guard owner === store, !store.isShuttingDown else { throw CancellationError() }
        if let source { guard source.store === store, source.profileID == profileID, RoutingHost.normalized(draft.content.host) == source.host else { throw BoostError.stale } }
    }
    @discardableResult func save(in store: BrowserStore) async -> Bool {
        guard !isSaving else { return false }
        let generation = UUID(); saveGeneration = generation
        do {
            try requireOwner(store)
            if let original, !isDirty {
                guard store.boostCatalog(profileID: profileID).entries.contains(where: { $0.id == original.id && $0.content == original.content }) else { throw BoostError.stale }
                return true
            }
            let proposed = draft, expected = original, profile = profileID
            _ = try proposed.validated()
            isSaving = true
            defer { isSaving = false }
            let validation = try await BoostCSS.checked(proposed.content.css)
            guard saveGeneration == generation else { return false }
            guard draft == proposed, original == expected, profileID == profile else { throw BoostError.stale }
            try requireOwner(store)
            try store.saveBoost(proposed, profileID: profile, expected: expected, cssValidation: validation)
            guard let saved = store.boostCatalog(profileID: profileID).entries.first(where: { $0.id == draft.id }) else { throw BoostError.missing }
            original = saved; draft = saved; initialContent = saved.content; newIntent = false; error = nil
            return true
        } catch { if saveGeneration == generation { self.error = error.localizedDescription }; return false }
    }
    @discardableResult func finish(in store: BrowserStore) async -> Bool {
        guard owner === store, !isSaving else { return false }
        if isDirty, !(await save(in: store)) { return false }
        guard store.boostEditor === self, store.presentedPanel == .boosts else { return false }
        store.presentedPanel = nil
        if store.boostEditor === self { store.boostEditor = nil }
        return true
    }
    func cancel() {
        saveGeneration = UUID()
        if let original { draft = original }
        else { draft = SiteBoost(content: initialContent); newIntent = false }
        error = nil
    }
    @discardableResult func select(_ value: SiteBoost) -> Bool {
        guard !isSaving else { return false }
        guard !isDirty else { error = "Save or cancel your unsaved edits before choosing another Boost."; return false }
        guard source == nil || value.content.host == source?.host else { error = BoostError.stale.localizedDescription; return false }
        original = value; draft = value; initialContent = value.content; newIntent = false; error = nil; return true
    }
    @discardableResult func newBoost() -> Bool {
        guard !isSaving else { return false }
        guard !isDirty else { error = "Save or cancel your unsaved edits before creating another Boost."; return false }
        let content = BoostContent(name: "Personal look", host: source?.host ?? "")
        original = nil; draft = SiteBoost(content: content); initialContent = content; newIntent = true; error = nil; return true
    }
    @discardableResult func changeProfile(_ id: UUID, in store: BrowserStore) -> Bool {
        guard owner === store, source == nil, !isDirty, !isSaving,
              store.isPrivate ? id == BrowserProfile.defaultID : store.profiles.contains(where: { $0.id == id }) else {
            error = "Finish this draft before opening Boosts for another profile."; return false
        }
        profileID = id; original = nil; newIntent = false
        let value = store.boostCatalog(profileID: id).entries.first ?? SiteBoost(content: BoostContent(name: "Personal look", host: ""))
        if store.boostCatalog(profileID: id).entries.first != nil { original = value }
        draft = value; initialContent = value.content; error = nil; return true
    }
    @discardableResult func setAppearance(_ appearance: BoostAppearance, in store: BrowserStore) -> Bool {
        guard !isSaving else { return false }
        do {
            try requireOwner(store)
            let appearance = try appearance.validated()
            var value = original ?? SiteBoost(id: draft.id, content: BoostContent(name: draft.content.name, host: draft.content.host), enabled: draft.enabled, hiddenSelectors: draft.hiddenSelectors)
            if let original, RoutingHost.normalized(draft.content.host) != original.content.host { throw BoostError.stale }
            value.content.appearance = appearance
            try store.saveBoost(value, profileID: profileID, expected: original)
            guard let saved = store.boostCatalog(profileID: profileID).entries.first(where: { $0.id == value.id }) else { throw BoostError.missing }
            original = saved; draft.content.appearance = saved.content.appearance; newIntent = false; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func pasteAppearance(from board: NSPasteboard) -> Bool {
        guard !isSaving else { return false }
        guard !isDirty else { error = "Save or cancel the current draft before pasting another appearance."; return false }
        do {
            let imported = try BoostClipboard.read(from: board)
            guard source == nil || imported.content.host == source?.host else { throw BoostError.stale }
            original = nil; draft = imported; newIntent = true; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func remove(_ value: SiteBoost, in store: BrowserStore) -> Bool {
        do {
            guard owner === store, store.boostCatalog(profileID: profileID).entries.first(where: { $0.id == value.id })?.content == value.content else { throw BoostError.stale }
            if draft.id == value.id && isDirty { throw BoostError.stale }
            try store.removeBoost(value.id, profileID: profileID)
            if draft.id == value.id {
                original = nil; let content = BoostContent(name: "Personal look", host: source?.host ?? "")
                draft = SiteBoost(content: content); initialContent = content; newIntent = false
            }
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

enum BoostLookPreset: String, CaseIterable, Identifiable {
    case parchment = "Parchment", midnight = "Midnight", rose = "Rose", ocean = "Ocean", original = "Website Default"
    var id: String { rawValue }
    var appearance: BoostAppearance {
        switch self {
        case .parchment: return BoostAppearance(background: "#F6EED8", text: "#443322", link: "#884422", font: .serif)
        case .midnight: return BoostAppearance(background: "#171920", text: "#EEE8ED", link: "#B8A9FF", font: .system)
        case .rose: return BoostAppearance(background: "#F8E7E8", text: "#44303E", link: "#A53768", font: .rounded)
        case .ocean: return BoostAppearance(background: "#132931", text: "#D5ECEC", link: "#80D7D8", font: .system)
        case .original: return BoostAppearance()
        }
    }
}

extension BrowserStore {
    func requestBoostEditor(for web: WKWebView? = nil) throws {
        guard !isShuttingDown else { throw CancellationError() }
        if let editor = boostEditor, editor.isDirty || presentedPanel == .boosts {
            presentedPanel = .boosts
            if web != nil { editor.error = "Finish or cancel this draft before opening Boosts for another page." }
            return
        }
        let profile: UUID, source: BoostEditSource?
        if let web {
            guard let owner = profileID(for: web) else { throw BoostError.stale }
            profile = owner
            source = web.url.flatMap(WebOrigin.init) == nil ? nil : try BoostEditSource(store: self, web: web)
        } else { profile = activeProfileID; source = nil }
        let entries = boostCatalog(profileID: profile).entries
        let initial = source.map { s in entries.first(where: { $0.enabled && $0.content.host == s.host }) ?? entries.first(where: { $0.content.host == s.host }) } ?? entries.first
        boostEditor = BoostEditor(store: self, profileID: profile, source: source, initial: initial)
        presentedPanel = .boosts
    }
    @discardableResult func finishBoostEditor() async -> Bool {
        if let boostEditor { return await boostEditor.finish(in: self) }
        presentedPanel = nil; return true
    }
    func removeBoostZap(_ id: UUID, profileID: UUID, selector: String) throws { try changeBoostZaps(id, profileID: profileID) { $0.removeAll { $0 == selector } } }
    func clearBoostZaps(_ id: UUID, profileID: UUID) throws { try changeBoostZaps(id, profileID: profileID) { $0 = [] } }
    private func changeBoostZaps(_ id: UUID, profileID: UUID, _ change: (inout [String]) -> Void) throws {
        guard canEditBoosts else { throw ProfileError.locked }
        try requireQuickProfile(profileID)
        guard !isPrivate || profileID == BrowserProfile.defaultID else { throw ProfileError.missing }
        let catalog = boostCatalog(profileID: profileID)
        guard var value = catalog.entries.first(where: { $0.id == id }) else { throw BoostError.missing }
        change(&value.hiddenSelectors)
        var candidate = makeDocument(), records = candidate.library(for: profileID)
        records.siteBoosts = try catalog.upserting(value); candidate.setLibrary(records, for: profileID)
        try commitQuickDocument(candidate)
    }
}
