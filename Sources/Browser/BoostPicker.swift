import AppKit
import WebKit
import Combine
import BrowserCore

@MainActor final class BoostPickerSession: ObservableObject, Identifiable {
    let id = UUID()
    let source: BoostEditSource
    let boostID: UUID
    var expected: SiteBoost
    var selectionID = UUID()
    @Published var ready = false
    init(source: BoostEditSource, boost: SiteBoost) { self.source = source; boostID = boost.id; expected = boost }
}

extension BrowserStore {
    func startBoostPicker(_ id: UUID, source: BoostEditSource) throws {
        guard canEditBoosts, boostsEnabled, source.matches(self),
              let boost = boostCatalog(profileID: source.profileID).entries.first(where: { $0.id == id }),
              boost.enabled, boost.content.host == source.host else { throw BoostError.stale }
        cancelBoostPicker()
        let session = BoostPickerSession(source: source, boost: boost)
        boostPicker = session; Self.configureBoostPicker(session)
    }
    func cancelBoostPicker() {
        guard let session = boostPicker else { return }
        boostPicker = nil
        guard let web = session.source.web else { return }
        let page = BoostRuntime.page(for: web), id = session.id.uuidString
        Task { @MainActor [weak page] in
            guard let page else { return }
            _ = try? await BoostRuntime.query(page, "const s=globalThis.__alcoveBoostState_v1;if(s?.picker?.id===id)s.stopPicker();", arguments: ["id": id], in: BoostRuntime.world)
        }
    }
    func reconcileBoostPicker() {
        guard let session = boostPicker else { return }
        guard canEditBoosts, boostsEnabled, session.source.matches(self),
              let current = boostCatalog(profileID: session.source.profileID).entries.first(where: { $0.id == session.boostID }),
              current.enabled, current.content == session.expected.content else { cancelBoostPicker(); return }
        if current != session.expected {
            session.expected = current; session.selectionID = UUID(); Self.configureBoostPicker(session)
        }
    }
    private static func pickerArguments(_ session: BoostPickerSession, nonce: String) -> [String: Any]? {
        guard let store = session.source.store, store.boostPicker === session, session.source.matches(store), store.canEditBoosts, store.boostsEnabled,
              let current = store.boostCatalog(profileID: session.source.profileID).entries.first(where: { $0.id == session.boostID }), current == session.expected, current.enabled else { return nil }
        return ["nonce": nonce, "host": session.source.host, "id": session.id.uuidString, "selection": session.selectionID.uuidString]
    }
    private static func configureBoostPicker(_ session: BoostPickerSession) {
        guard let web = session.source.web else { return }
        let page = BoostRuntime.page(for: web)
        Task { @MainActor [weak session, weak page] in
            guard let session, let page else { return }
            do {
                let document = try await BoostRuntime.readDocument(page)
                guard let arguments = pickerArguments(session, nonce: document.nonce) else { return }
                guard try await BoostRuntime.query(page, "return globalThis.__alcoveBoostState_v1?.startPicker(nonce,host,id,selection);", arguments: arguments, in: BoostRuntime.world) as? Bool == true else { throw BoostRuntimeError.unavailable }
                if session.source.store?.boostPicker === session { session.ready = true }
            } catch is CancellationError { }
            catch {
                if let store = session.source.store, store.boostPicker === session { store.cancelBoostPicker(); store.message = "Boost: \(error.localizedDescription)" }
            }
        }
    }
    func receiveBoostPickerMessage(_ payload: [String: Any], page: BoostPageState) {
        guard let session = boostPicker, session.source.web === page.web,
              let nonce = payload["nonce"] as? String, payload["picker"] as? String == session.id.uuidString,
              let kind = payload["kind"] as? String else { return }
        let selection = payload["selection"] as? String
        let selector = payload["selector"] as? String
        guard kind == "cancelPicker" || selection == session.selectionID.uuidString else { return }
        if kind == "picked" {
            guard let selector, !selector.isEmpty, selector.utf8.count <= 1024, !selector.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return }
        }
        Task { @MainActor [weak session, weak page] in
            guard let session, let page else { return }
            do {
                guard try await BoostRuntime.readDocument(page).nonce == nonce,
                      Self.pickerArguments(session, nonce: nonce) != nil else { return }
                if kind == "cancelPicker" { session.source.store?.cancelBoostPicker(); return }
                guard selection == session.selectionID.uuidString else { return }
                if kind == "pickerError" { session.source.store?.message = "Choose an element inside the main page. The page background cannot be hidden."; return }
                guard let selector,
                      try await BoostRuntime.query(page, "return globalThis.__alcoveBoostState_v1?.validatePick(nonce,host,selection,selector);", arguments: ["nonce": nonce, "host": session.source.host, "selection": selection ?? "", "selector": selector], in: BoostRuntime.world) as? Bool == true,
                      selection == session.selectionID.uuidString, let store = session.source.store,
                      store.boostPicker === session, session.source.matches(store) else { return }
                session.selectionID = UUID()
                do { try store.addBoostZap(session.boostID, profileID: session.source.profileID, selector: selector, expected: session.expected) }
                catch { Self.configureBoostPicker(session); throw error }
            } catch is CancellationError { }
            catch { if let store = session.source.store, store.boostPicker === session { store.message = "Boost: \(error.localizedDescription)" } }
        }
    }
}
