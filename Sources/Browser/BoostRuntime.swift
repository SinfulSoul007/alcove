import AppKit
import WebKit
import BrowserCore

enum BoostRuntimeError: LocalizedError {
    case unavailable, timedOut, unapproved, alreadyRan
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This page is not ready for Boosts. Try again after it finishes loading."
        case .timedOut: return "The page did not respond to the Boost. Reload it if the script is still running."
        case .unapproved: return "Enable this Boost and approve its exact JavaScript before running it."
        case .alreadyRan: return "This script already ran on this page. Reload the page to run it again."
        }
    }
}
@MainActor final class BoostPageState {
    weak var web: WKWebView?
    var generation = 0, serial = 0, navigationSerial = 0
    var nonce: String?, pageNonce: String?
    var processedReady = false
    var ran = Set<String>(), jobs = Set<UUID>()
    var approvalDeferrals: [String: Int] = [:]
    init(_ web: WKWebView) { self.web = web }
}
@MainActor final class BoostRuntimeCall {
    let id = UUID()
    weak var page: BoostPageState?
    var continuation: CheckedContinuation<Any?, Error>?
    var timeout: Task<Void, Never>?
    init(page: BoostPageState, continuation: CheckedContinuation<Any?, Error>) { self.page = page; self.continuation = continuation }
    func finish(_ result: Result<Any?, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        page?.jobs.remove(id); BoostRuntime.calls.removeValue(forKey: id)
        continuation.resume(with: result)
    }
}
@MainActor final class BoostRuntimeBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { BoostRuntime.receive(message) }
}
@MainActor enum BoostRuntime {
    static let world = WKContentWorld.world(name: "AlcoveBoostRuntime")
    private static let bridge = BoostRuntimeBridge()
    private static let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private static let pages = NSMapTable<WKWebView, BoostPageState>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static var calls: [UUID: BoostRuntimeCall] = [:]
    struct Snapshot {
        let profile: UUID, origin: WebOrigin, document: NSUUID, boost: SiteBoost?
    }
    static func page(for web: WKWebView) -> BoostPageState {
        if let value = pages.object(forKey: web) { return value }
        let value = BoostPageState(web); pages.setObject(value, forKey: web); return value
    }
    static func install(on web: WKWebView) {
        let controller = web.configuration.userContentController
        if !controllers.contains(controller) {
            controller.add(bridge, contentWorld: world, name: "alcoveBoostBridge")
            controller.addUserScript(WKUserScript(source: BoostBridgeScript.page, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            controller.addUserScript(WKUserScript(source: BoostBridgeScript.isolated, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
            controllers.add(controller)
        }
        _ = page(for: web)
    }
    static func cancelCalls(_ page: BoostPageState) {
        for id in Array(page.jobs) { calls[id]?.finish(.failure(CancellationError())) }
    }
    static func invalidate(_ web: WKWebView) {
        guard let page = pages.object(forKey: web) else { return }
        page.generation += 1; cancelCalls(page)
        schedule(page, auto: true)
    }
    static func navigationStarted(_ web: WKWebView) { page(for: web).navigationSerial += 1 }
    static func deferNewApproval(_ boost: SiteBoost, profileID: UUID, store: BrowserStore) {
        let key = boost.id.uuidString + boost.scriptHash
        for web in Array(store.views.values) + store.peekPages.values.map(\.web) where store.profileID(for: web) == profileID {
            let page = page(for: web); page.approvalDeferrals[key] = page.navigationSerial
        }
    }
    static func forget(_ web: WKWebView) {
        guard let page = pages.object(forKey: web) else { return }
        page.generation += 1; cancelCalls(page); pages.removeObject(forKey: web)
    }
    static func query(_ page: BoostPageState, _ body: String, arguments: [String: Any] = [:], in contentWorld: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            guard let web = page.web else { continuation.resume(throwing: CancellationError()); return }
            let call = BoostRuntimeCall(page: page, continuation: continuation)
            calls[call.id] = call; page.jobs.insert(call.id)
            call.timeout = Task { @MainActor [weak call] in
                do { try await Task.sleep(for: .seconds(5)); call?.finish(.failure(BoostRuntimeError.timedOut)) } catch { }
            }
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: contentWorld) { [weak call] result in
                call?.finish(result.map { Optional($0) })
            }
        }
    }
    static func snapshot(_ page: BoostPageState) -> Snapshot? {
        guard let web = page.web, let store = web.navigationDelegate as? BrowserStore, !store.isShuttingDown,
              let owner = store.profileID(for: web), !store.profileUnavailable(owner),
              store.matchesBoostWebsiteDataStore(web, profileID: owner),
              let url = web.url, let origin = WebOrigin(url) else { return nil }
        return Snapshot(profile: owner, origin: origin, document: store.documentIdentity(for: web), boost: store.boostsEnabled ? store.boostCatalog(profileID: owner).matching(url) : nil)
    }
    static func matches(_ page: BoostPageState, _ value: Snapshot) -> Bool {
        guard let current = snapshot(page) else { return false }
        return current.profile == value.profile && current.origin == value.origin && current.document === value.document && current.boost == value.boost
    }
    static func readDocument(_ page: BoostPageState) async throws -> (nonce: String, pageNonce: String, ready: Bool) {
        let generation = page.generation
        guard let state = try await query(page, "const s=globalThis.__alcoveBoostState_v1;return s?{nonce:s.nonce,ready:s.ready}:null;", in: world) as? [String: Any],
              let nonce = state["nonce"] as? String, nonce.count == 32,
              let pageNonce = try await query(page, "return typeof __alcoveBoostPageNonce_v1==='string'?__alcoveBoostPageNonce_v1:null;", in: .page) as? String, pageNonce.count == 32,
              try await query(page, "return globalThis.__alcoveBoostState_v1?.nonce;", in: world) as? String == nonce,
              page.generation == generation else { throw BoostRuntimeError.unavailable }
        if page.nonce != nonce { page.nonce = nonce; page.ran = []; page.processedReady = false }
        page.pageNonce = pageNonce
        return (nonce, pageNonce, state["ready"] as? Bool == true)
    }
    static func refresh(store: BrowserStore) {
        var seen = Set<ObjectIdentifier>()
        for web in Array(store.views.values) + store.peekPages.values.map(\.web) where seen.insert(ObjectIdentifier(web)).inserted { schedule(page(for: web), auto: false) }
    }
    private static func schedule(_ page: BoostPageState, auto: Bool) {
        Task { @MainActor [weak page] in
            guard let page else { return }
            do { try await refreshPage(page, auto: auto) }
            catch is CancellationError { }
            catch BoostRuntimeError.unavailable { }
            catch { report(error, page: page) }
        }
    }
    static func report(_ error: Error, page: BoostPageState) {
        guard let web = page.web, let store = web.navigationDelegate as? BrowserStore, !store.isShuttingDown else { return }
        store.message = "Boost: \(String(error.localizedDescription.prefix(500)))"
    }
    private static func refreshPage(_ page: BoostPageState, auto: Bool) async throws {
        guard snapshot(page) != nil else { return }
        let document = try await readDocument(page)
        guard let value = snapshot(page) else { return }
        page.serial += 1
        _ = try await query(page, "return globalThis.__alcoveBoostState_v1?.apply(nonce,host,serial,appearance,css,selectors);", arguments: ["nonce": document.nonce, "host": value.origin.host, "serial": page.serial, "appearance": value.boost?.content.appearance.css ?? "", "css": value.boost?.content.css ?? "", "selectors": value.boost?.hiddenSelectors ?? []], in: world)
        guard matches(page, value), page.nonce == document.nonce else { return }
        if auto && document.ready && !page.processedReady {
            page.processedReady = true
            if let boost = value.boost, boost.isJavaScriptApproved {
                let key = boost.id.uuidString + boost.scriptHash
                if page.approvalDeferrals[key].map({ page.navigationSerial > $0 }) ?? true {
                    do { try await execute(boost, page: page, value: value, pageNonce: document.pageNonce) }
                    catch BoostRuntimeError.alreadyRan { }
                }
            }
        }
    }
    static func execute(_ boost: SiteBoost, page: BoostPageState, value: Snapshot, pageNonce: String) async throws {
        guard boost.isJavaScriptApproved, matches(page, value) else { throw BoostRuntimeError.unapproved }
        let key = boost.id.uuidString + boost.scriptHash
        guard !page.ran.contains(key) else { throw BoostRuntimeError.alreadyRan }
        let body = try BoostScript.validatedBody(boost.content.javascript)
        page.ran.insert(key)
        guard let nonce = page.nonce else { throw BoostRuntimeError.unavailable }
        guard try await query(page, "return globalThis.__alcoveBoostState_v1?.claim(nonce,host,key);", arguments: ["nonce": nonce, "host": boost.content.host, "key": key], in: world) as? Bool == true else { throw BoostRuntimeError.alreadyRan }
        guard matches(page, value), page.nonce == nonce else {
            _ = try? await query(page, "globalThis.__alcoveBoostState_v1?.release(nonce,key);", arguments: ["nonce": nonce, "key": key], in: world)
            throw BoostError.stale
        }
        _ = try await query(page, body, arguments: ["__alcoveHost": boost.content.host, "__alcoveNonce": pageNonce], in: .page)
    }
    static func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let web = message.webView, let store = web.navigationDelegate as? BrowserStore,
              !store.isShuttingDown, let page = pages.object(forKey: web), let value = snapshot(page),
              let payload = message.body as? [String: Any], let kind = payload["kind"] as? String,
              let nonce = payload["nonce"] as? String, nonce.count == 32,
              message.frameInfo.securityOrigin.protocol.lowercased() == value.origin.scheme,
              RoutingHost.normalized(message.frameInfo.securityOrigin.host) == value.origin.host,
              message.frameInfo.securityOrigin.port == value.origin.port || (message.frameInfo.securityOrigin.port == 0 && value.origin.port == (value.origin.scheme == "https" ? 443 : 80)) else { return }
        switch kind {
        case "start", "ready":
            Task { @MainActor [weak page] in
                guard let page else { return }
                do {
                    guard try await readDocument(page).nonce == nonce else { return }
                    try await refreshPage(page, auto: kind == "ready")
                } catch is CancellationError { } catch BoostRuntimeError.unavailable { } catch { report(error, page: page) }
            }
        case "picked", "cancelPicker", "pickerError": store.receiveBoostPickerMessage(payload, page: page)
        default: break
        }
    }
}

extension BrowserStore {
    func matchesBoostWebsiteDataStore(_ web: WKWebView, profileID: UUID) -> Bool {
        let actual = web.configuration.websiteDataStore
        if isPrivate { return profileID == BrowserProfile.defaultID && actual === privateDataStore }
        if let cached = namedDataStores[profileID] { return actual === cached }
        if profileID == BrowserProfile.defaultID { return actual.isPersistent && actual.identifier == nil }
        return actual.identifier == profileID
    }
    func refreshBoosts() { reconcileBoostPicker(); BoostRuntime.refresh(store: self) }
    func executeApprovedBoostOnCurrentPage(_ id: UUID, source: BoostEditSource) async throws {
        guard source.matches(self), let web = source.web else { throw BoostError.stale }
        let page = BoostRuntime.page(for: web)
        guard let initial = BoostRuntime.snapshot(page), let initialBoost = initial.boost, initialBoost.id == id, initialBoost.isJavaScriptApproved else { throw BoostRuntimeError.unapproved }
        let document = try await BoostRuntime.readDocument(page)
        guard source.matches(self), let value = BoostRuntime.snapshot(page), let boost = value.boost,
              boost.id == id, boost.scriptHash == initialBoost.scriptHash else { throw BoostError.stale }
        try await BoostRuntime.execute(boost, page: page, value: value, pageNonce: document.pageNonce)
    }
}
