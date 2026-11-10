import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum BoostWebsiteCheckError: Error { case failed, fixtureMissing }
@MainActor final class BoostLifetimeProbe {
    weak var store: BrowserStore?
    weak var web: WKWebView?
    init(store: BrowserStore?, web: WKWebView?) { self.store = store; self.web = web }
}
@main struct BoostWebsiteChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        guard let raw = ProcessInfo.processInfo.environment["ALCOVE_BOOST_FIXTURE_URL"], let origin = URL(string: raw), origin.host == "127.0.0.1", origin.port != nil else { throw BoostWebsiteCheckError.fixtureMissing }
        var failures = 0, fixtures: [SiteSearchStoreFixture] = [], windows: [NSWindow] = []
        defer { windows.forEach { $0.contentView = nil }; fixtures.forEach { $0.close() } }
        let world = WKContentWorld.world(name: "AlcoveBoostRuntime")
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func js(_ web: WKWebView, _ code: String, world: WKContentWorld? = nil) async throws -> Any? {
            try await web.callAsyncJavaScript(code, in: nil, contentWorld: world ?? .page)
        }
        func eventually(_ name: String, _ condition: () async throws -> Bool) async throws {
            for _ in 0..<400 {
                if (try? await condition()) == true { check(true, name); return }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(false, name)
        }
        func fixture(_ privateMode: Bool = false, controller: WKUserContentController? = nil) throws -> (SiteSearchStoreFixture, WKWebView) {
            let f = try SiteSearchStoreFixture(isPrivate: privateMode); fixtures.append(f)
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = f.store.websiteDataStore(forProfile: f.profile)
            if let controller { configuration.userContentController = controller }
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            f.store.registerView(web, for: f.store.selectedID!, profile: f.profile)
            let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = web; windows.append(window); return (f, web)
        }
        func load(_ web: WKWebView, path: String = "strict", base: URL? = nil) async throws {
            let old = try? await js(web, "return typeof __alcoveBoostPageNonce_v1 === 'string' ? __alcoveBoostPageNonce_v1 : null;") as? String
            web.load(URLRequest(url: (base ?? origin).appendingPathComponent(path)))
            try await eventually("Owned page receives a fresh document-start nonce") {
                guard let token = try await js(web, "return document.readyState === 'complete' && typeof __alcoveBoostPageNonce_v1 === 'string' ? __alcoveBoostPageNonce_v1 : null;") as? String else { return false }
                return token != old && !web.isLoading
            }
        }
        let (f, web) = try fixture(), store = f.store
        var look = SiteBoost(content: BoostContent(name: "Strict site", host: "127.0.0.1", appearance: BoostAppearance(background: "#F0EEDD", font: .serif, textScale: 1.25), css: "#target{color:#123456!important}", javascript: "window.scriptRuns=(window.scriptRuns||0)+1; document.getElementById('target').textContent=String(window.siteGlobal+1); await Promise.resolve(); document.body.dataset.awaited='yes';"))
        try await store.saveValidatedBoost(look, profileID: f.profile)
        try await load(web)
        try await eventually("Constructed Boost CSS applies on a site that rejects inline styles") { try await js(web, "return getComputedStyle(document.getElementById('target')).color;") as? String == "rgb(18, 52, 86)" }
        check(try await js(web, "return getComputedStyle(document.documentElement).fontSize;") as? String == "20px", "No-code relative text scale reaches the real layout engine")
        check(try await js(web, "return getComputedStyle(document.body).fontFamily.includes('Georgia');") as? Bool == true, "The chosen font reaches the real document")
        try await eventually("Cross-origin child frame retains its original text color") { try await js(web, "return window.frameColor;") as? String == "rgb(0, 0, 0)" }
        check(try await js(web, "return window.scriptRuns === undefined;") as? Bool == true, "Unapproved custom code never runs on load")
        _ = try await js(web, "window.keptInput=document.getElementById('keep'); keptInput.value='unsaved form'; window.scrollTo(0,300); return true;")
        let source = try BoostEditSource(store: store, web: web)
        let approval = BoostJavaScriptRequest(source: source, boost: store.boostCatalog(profileID: f.profile).entries[0])
        try store.approveBoostJavaScript(approval)
        try await Task.sleep(for: .milliseconds(60))
        check(try await js(web, "return window.scriptRuns === undefined;") as? Bool == true, "Approving future execution does not unexpectedly run or reload the current page")
        try await store.executeApprovedBoostOnCurrentPage(look.id, source: source)
        check(try await js(web, "return window.scriptRuns===1 && document.getElementById('target').textContent==='18' && document.body.dataset.awaited==='yes';") as? Bool == true, "Approved page-world code accesses site globals and supports await under strict CSP")
        try? await store.executeApprovedBoostOnCurrentPage(look.id, source: source)
        _ = try await js(web, "webkit.messageHandlers.alcoveBoostBridge.postMessage({kind:'ready',nonce:__alcoveBoostState_v1.nonce});", world: world)
        try await Task.sleep(for: .milliseconds(60))
        check(try await js(web, "return window.scriptRuns;") as? Int == 1, "Repeated ready events and explicit Run cannot execute the same script twice per document")
        let current = store.boostCatalog(profileID: f.profile).entries[0]
        look = current; look.content.css = "#target{color:#AABBCC!important}"
        try await store.saveValidatedBoost(look, profileID: f.profile, expected: current)
        try await eventually("Custom CSS edits update the current document without navigation") { try await js(web, "return getComputedStyle(document.getElementById('target')).color;") as? String == "rgb(170, 187, 204)" }
        check(try await js(web, "return keptInput===document.getElementById('keep') && keptInput.value==='unsaved form' && window.scriptRuns===1 && window.scrollY===300;") as? Bool == true, "Editing styles preserves the same input node, unsaved form, scroll and script state")
        try store.setBoostsEnabled(false)
        try await eventually("Global off removes only Alcove's current styles") { try await js(web, "return getComputedStyle(document.getElementById('target')).color;") as? String == "rgb(0, 0, 0)" }
        try store.setBoostsEnabled(true)
        try await eventually("Global on restores saved styles without rerunning code") { try await js(web, "return getComputedStyle(document.getElementById('target')).color==='rgb(170, 187, 204)' && window.scriptRuns===1;") as? Bool == true }
        try store.startBoostPicker(look.id, source: source)
        try await eventually("Picker attaches to the frozen owned document") { try await js(web, "return !!__alcoveBoostState_v1.picker;", world: world) as? Bool == true }
        _ = try await js(web, "__alcoveBoostState_v1.pick(document.getElementById('ad'));__alcoveBoostState_v1.pick(document.getElementById('ad'));", world: world)
        try await eventually("Picker saves and hides the selected element through the isolated native bridge") {
            let display = try await js(web, "return getComputedStyle(document.getElementById('ad')).display;") as? String
            return store.boostCatalog(profileID: f.profile).entries[0].hiddenSelectors == ["#ad"] && display == "none"
        }
        try await Task.sleep(for: .milliseconds(60))
        check(store.message == nil, "Duplicate picker clicks do not produce stale-save errors")
        try store.undoBoostZap(look.id, profileID: f.profile)
        try await eventually("Undo restores the same hidden DOM node and unsaved input") { try await js(web, "return getComputedStyle(document.getElementById('ad')).display!=='none' && keptInput===document.getElementById('keep') && keptInput.value==='unsaved form';") as? Bool == true }
        store.cancelBoostPicker()
        try await eventually("Cancel removes the picker overlay and keeps the page usable") { try await js(web, "return !__alcoveBoostState_v1.picker && !document.querySelector('[data-alcove-zap-overlay]');", world: world) as? Bool == true }
        check(try await js(web, "return !window.webkit?.messageHandlers?.alcoveBoostBridge;") as? Bool == true, "Page scripts cannot call the isolated Boost bridge")
        let oldNonce = try await js(web, "return __alcoveBoostPageNonce_v1;") as! String
        try await load(web)
        try await eventually("A future document runs its approved code once") { try await js(web, "return window.scriptRuns===1 && document.body.dataset.awaited==='yes';") as? Bool == true }
        let beforeBack = try await js(web, "return __alcoveBoostPageNonce_v1;") as! String
        try await load(web, path: "history")
        try await eventually("A second history document runs approved code once") { try await js(web, "return window.scriptRuns===1;") as? Bool == true }
        web.goBack()
        try await eventually("History restoration retains one execution per actual document") { try await js(web, "return location.pathname==='/strict' && window.scriptRuns===1;") as? Bool == true }
        let restored = try await js(web, "return __alcoveBoostPageNonce_v1;") as? String
        print("INFO: History used \(restored == beforeBack ? "the retained document" : "a fresh document"); one-execution assertion applies to the observed path")
        check(store.message == nil, "Normal back/forward restoration does not display a spurious script error")
        let guarded = try BoostScript.validatedBody("function location(){}; function __alcoveHost(){}; window.wrongGuard=true;")
        let liveNonce = try await js(web, "return __alcoveBoostPageNonce_v1;") as! String
        _ = try await web.callAsyncJavaScript(guarded, arguments: ["__alcoveHost": "other.test", "__alcoveNonce": liveNonce], in: nil, contentWorld: .page)
        let staleBody = try BoostScript.validatedBody("window.staleGuard=true;")
        _ = try await web.callAsyncJavaScript(staleBody, arguments: ["__alcoveHost": "127.0.0.1", "__alcoveNonce": oldNonce], in: nil, contentWorld: .page)
        check(try await js(web, "return window.wrongGuard===undefined && window.staleGuard===undefined;") as? Bool == true, "The actual page engine rejects hoisted guard shadows and old same-URL document nonces")
        _ = try await web.callAsyncJavaScript("try{Object.defineProperty(window,'__alcoveBoostPageNonce_v1',{value:old});}catch{}", arguments: ["old": oldNonce], in: nil, contentWorld: .page)
        check(try await js(web, "return __alcoveBoostPageNonce_v1;") as? String == liveNonce, "A page cannot replace its document-start nonce with the previous document's token")
        do { _ = try BoostScript.validatedBody("});window.escaped=true;(()=>{"); check(false, "Native execution rejects a wrapper escape before dispatch") }
        catch { check(true, "Native execution rejects a wrapper escape before dispatch") }
        store.openPeek(origin.appendingPathComponent("peek"), from: web)
        if let peek = store.primaryPeekView {
            try await eventually("A separately constructed Peek receives its profile's styles and approved code") { try await js(peek, "return getComputedStyle(document.getElementById('target')).color==='rgb(170, 187, 204)' && window.scriptRuns===1;") as? Bool == true }
            store.closePrimaryPeek()
        } else { check(false, "A separately constructed Peek receives its profile's styles and approved code") }
        let quickID = try store.openQuickPage(url: origin.appendingPathComponent("quick"), profileID: f.profile)
        let quickWeb = store.view(for: quickID)
        try await eventually("Quick Browse uses the same profile-scoped Boost runtime") { try await js(quickWeb, "return getComputedStyle(document.getElementById('target')).color==='rgb(170, 187, 204)' && window.scriptRuns===1;") as? Bool == true }

        let shared = web.configuration.userContentController
        shared.addUserScript(WKUserScript(source: "window.unrelatedScriptAlive=42;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let (other, otherWeb) = try fixture(controller: shared)
        try await other.store.saveValidatedBoost(SiteBoost(content: BoostContent(name: "Other profile", host: "127.0.0.1", css: "#target{color:#AA0000!important}")), profileID: other.profile)
        BoostRuntime.install(on: otherWeb); BoostRuntime.install(on: otherWeb)
        try await load(otherWeb)
        try await eventually("A shared popup content controller resolves the receiving view's real profile") { try await js(otherWeb, "return getComputedStyle(document.getElementById('target')).color;") as? String == "rgb(170, 0, 0)" }
        check(try await js(otherWeb, "return window.unrelatedScriptAlive;") as? Int == 42, "Idempotent installation preserves unrelated configuration scripts")
        check(!store.matchesBoostWebsiteDataStore(web, profileID: other.profile) && !store.matchesBoostWebsiteDataStore(web, profileID: BrowserProfile.defaultID), "Foreign and unnamed temporary stores cannot impersonate a normal default/profile cookie store")
        check(try await js(otherWeb, "return window.scriptRuns===undefined;") as? Bool == true, "A shared controller never carries another profile's approved code")
        check(try await js(web, "return getComputedStyle(document.getElementById('target')).color;") as? String == "rgb(170, 187, 204)", "Refreshing a shared controller's second profile preserves the first profile's look")
        let localhost = URL(string: "http://localhost:\(origin.port!)/")!
        try await load(otherWeb, base: localhost)
        check(try await js(otherWeb, "return getComputedStyle(document.getElementById('target')).color==='rgb(0, 0, 0)' && window.scriptRuns===undefined;") as? Bool == true, "A real different-host document does not inherit same-server Boosts")
        let (privateFixture, privateWeb) = try fixture(true, controller: shared)
        try await load(privateWeb)
        check(try await js(privateWeb, "return getComputedStyle(document.getElementById('target')).color==='rgb(0, 0, 0)' && window.scriptRuns===undefined;") as? Bool == true, "A private view sharing generic infrastructure inherits no normal definitions or code")
        check(privateFixture.reads.count == 0 && !FileManager.default.fileExists(atPath: privateFixture.store.sessionURL.path), "Private runtime does not request keys or create a normal metadata file")
        let (slow, slowWeb) = try fixture()
        let slowLook = SiteBoost(content: BoostContent(name: "Load approval", host: "127.0.0.1", javascript: "window.earlyExecution=(window.earlyExecution||0)+1;"))
        try await slow.store.saveValidatedBoost(slowLook, profileID: slow.profile)
        slowWeb.load(URLRequest(url: origin.appendingPathComponent("slow")))
        try await eventually("Approval fixture exposes its page before DOM ready") { try await js(slowWeb, "return !!document.getElementById('target') && document.readyState!=='complete';") as? Bool == true }
        try slow.store.approveBoostJavaScript(BoostJavaScriptRequest(source: BoostEditSource(store: slow.store, web: slowWeb), boost: slow.store.boostCatalog(profileID: slow.profile).entries[0]))
        try await eventually("The in-flight document finishes loading") { try await js(slowWeb, "return document.readyState==='complete' && window.slowFinished===true;") as? Bool == true }
        try await Task.sleep(for: .milliseconds(80))
        check(try await js(slowWeb, "return window.earlyExecution===undefined;") as? Bool == true, "Consent during an in-flight load does not run code on that current document")
        try await load(slowWeb)
        try await eventually("The next provisional navigation can use the newly approved code") { try await js(slowWeb, "return window.earlyExecution===1;") as? Bool == true }
        let (failed, failedWeb) = try fixture()
        let failedLook = SiteBoost(content: BoostContent(name: "Rollback", host: "127.0.0.1"))
        try await failed.store.saveValidatedBoost(failedLook, profileID: failed.profile)
        try await load(failedWeb)
        try failed.store.startBoostPicker(failedLook.id, source: BoostEditSource(store: failed.store, web: failedWeb))
        try await eventually("Rollback fixture picker is ready") { try await js(failedWeb, "return !!__alcoveBoostState_v1.picker;", world: world) as? Bool == true }
        let originalBytes = try Data(contentsOf: failed.store.sessionURL)
        let badDestination = failed.root.appendingPathComponent("directory-instead-of-file")
        try FileManager.default.createDirectory(at: badDestination, withIntermediateDirectories: false)
        failed.store.vault = MetadataStore(url: badDestination, key: failed.key)
        _ = try await js(failedWeb, "__alcoveBoostState_v1.pick(document.getElementById('second'));", world: world)
        try await eventually("Picker reports a failed save before hiding anything") { !failed.store.savingEnabled }
        check(try await js(failedWeb, "return getComputedStyle(document.getElementById('second')).display!=='none';") as? Bool == true && failed.store.boostCatalog(profileID: failed.profile).entries[0].hiddenSelectors.isEmpty, "A failed picker save preserves both the DOM and selector catalog")
        check(try Data(contentsOf: failed.store.sessionURL) == originalBytes, "A failed picker save preserves previous encrypted bytes")
        failed.store.cancelBoostPicker()
        let (closing, closingWeb) = try fixture()
        let closingLook = SiteBoost(content: BoostContent(name: "Closing picker", host: "127.0.0.1"))
        try await closing.store.saveValidatedBoost(closingLook, profileID: closing.profile)
        try await load(closingWeb)
        try closing.store.startBoostPicker(closingLook.id, source: BoostEditSource(store: closing.store, web: closingWeb))
        try await eventually("Window-close fixture picker is ready") { try await js(closingWeb, "return !!__alcoveBoostState_v1.picker;", world: world) as? Bool == true }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: closingWeb.window!)
        check(closing.store.boostPicker == nil, "A native source-window close immediately cancels its picker")
        try await eventually("Closing a source window removes its page overlay") { try await js(closingWeb, "return !__alcoveBoostState_v1.picker && !document.querySelector('[data-alcove-zap-overlay]');", world: world) as? Bool == true }
        var ephemeralStore: BrowserStore? = BrowserStore(isPrivate: true)
        ephemeralStore!.onboardingVisible = false
        let ephemeralConfig = WKWebViewConfiguration(); ephemeralConfig.websiteDataStore = ephemeralStore!.privateDataStore!
        ephemeralConfig.userContentController = shared
        var ephemeralWeb: WKWebView? = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: ephemeralConfig)
        let retired = BoostLifetimeProbe(store: ephemeralStore, web: ephemeralWeb)
        ephemeralStore!.registerView(ephemeralWeb!, for: ephemeralStore!.selectedID!, profile: BrowserProfile.defaultID)
        try await load(ephemeralWeb!)
        ephemeralStore!.shutdown(); ephemeralWeb = nil; ephemeralStore = nil
        try await eventually("Shared scripts, handlers and native call jobs release a closed owner and web view") { retired.store == nil && retired.web == nil }
        let (review, reviewWeb) = try fixture()
        var reviewedLook = SiteBoost(content: BoostContent(name: "Review regression", host: "127.0.0.1", css: "#target{color:#FF0000!important}"))
        try await review.store.saveValidatedBoost(reviewedLook, profileID: review.profile)
        try await load(reviewWeb, path: "review")
        try await eventually("Review fixture begins with the saved working style") { try await js(reviewWeb, "return getComputedStyle(document.getElementById('target')).color==='rgb(255, 0, 0)';") as? Bool == true }
        for css in ["#target{color:", "#target{color:blue} p{background:", "#target ??? {color:blue}", "#target{color:not-a-color}", "#target{color:blue;display:inexistent}"] {
            let rejected = try await reviewWeb.callAsyncJavaScript("const s=__alcoveBoostState_v1;try{s.apply(s.nonce,location.hostname,s.serial,'',css,[]);return false;}catch(e){return String(e).includes('CSS');}", arguments: ["css": css], in: nil, contentWorld: world) as? Bool
            let unchangedColor = try await js(reviewWeb, "return getComputedStyle(document.getElementById('target')).color==='rgb(255, 0, 0)';") as? Bool
            check(rejected == true && unchangedColor == true, "Actual WebKit rejects malformed/partial CSS without replacing the working sheets")
            _ = try await js(reviewWeb, "const s=__alcoveBoostState_v1;s.apply(s.nonce,location.hostname,s.serial,'','#target{color:red!important}',[]);return true;", world: world)
        }
        _ = try await js(reviewWeb, "window.reviewInput=document.getElementById('keep');reviewInput.value='kept form';window.reviewAd=document.getElementById('ad');return true;")
        for css in ["", "@layer custom {#ad{display:block!important}}"] {
            let base = review.store.boostCatalog(profileID: review.profile).entries[0]
            reviewedLook = base; reviewedLook.content.css = css; try await review.store.saveValidatedBoost(reviewedLook, profileID: review.profile, expected: base)
            _ = try await js(reviewWeb, "reviewAd.style.setProperty('display','inline-flex','important');return true;")
            let saved = review.store.boostCatalog(profileID: review.profile).entries[0]
            try review.store.addBoostZap(saved.id, profileID: review.profile, selector: "#ad", expected: saved)
            try await eventually("Zap dominates site/custom layers and inline-important display") { try await js(reviewWeb, "return getComputedStyle(reviewAd).display==='none' && reviewInput.value==='kept form';") as? Bool == true }
            try review.store.undoBoostZap(saved.id, profileID: review.profile)
            try await eventually("Undo restores exact inline display/priority and the original live nodes") { try await js(reviewWeb, "return reviewAd===document.getElementById('ad') && reviewAd.style.display==='inline-flex' && reviewAd.style.getPropertyPriority('display')==='important' && reviewInput===document.getElementById('keep') && reviewInput.value==='kept form';") as? Bool == true }
        }
        let dynamicBase = review.store.boostCatalog(profileID: review.profile).entries[0]
        try review.store.addBoostZap(dynamicBase.id, profileID: review.profile, selector: ".dynamic-ad", expected: dynamicBase)
        try await eventually("A saved selector remains active before matching elements appear") { try await js(reviewWeb, "return __alcoveBoostState_v1.hideSelectors?.includes('.dynamic-ad')===true;", world: world) as? Bool == true }
        _ = try await js(reviewWeb, "window.dynamicAd=document.createElement('div');dynamicAd.className='dynamic-ad';dynamicAd.style.setProperty('display','block','important');document.body.append(dynamicAd);return true;")
        try await eventually("New matching elements are hidden despite inline-important styles") { try await js(reviewWeb, "return getComputedStyle(dynamicAd).display==='none';") as? Bool == true }
        _ = try await js(reviewWeb, "dynamicAd.style.setProperty('display','grid','important');return true;")
        try await eventually("Page display changes stay hidden while updating the reversible baseline") { try await js(reviewWeb, "return getComputedStyle(dynamicAd).display==='none';") as? Bool == true }
        try review.store.undoBoostZap(dynamicBase.id, profileID: review.profile)
        try await eventually("Undo preserves the page's latest inline display and original form node") { try await js(reviewWeb, "return dynamicAd.style.display==='grid' && dynamicAd.style.getPropertyPriority('display')==='important' && reviewInput===document.getElementById('keep') && reviewInput.value==='kept form';") as? Bool == true }
        let reviewSource = try BoostEditSource(store: review.store, web: reviewWeb)
        try review.store.startBoostPicker(reviewedLook.id, source: reviewSource)
        try await eventually("Propagation regression has a real picker overlay") { try await js(reviewWeb, "return !!document.querySelector('[data-alcove-zap-overlay]');") as? Bool == true }
        _ = try await js(reviewWeb, "const overlay=document.querySelector('[data-alcove-zap-overlay]');for(const type of ['pointerdown','mousedown','pointerup','mouseup','click','dblclick','contextmenu','touchstart','touchend'])overlay.dispatchEvent(new Event(type,{bubbles:true,cancelable:true}));return true;")
        check(try await js(reviewWeb, "return captureCount===0 && reviewInput.value==='kept form' && location.pathname==='/review';") as? Bool == true, "Picker input cannot activate ancestor page handlers or change a live form")
        review.store.cancelBoostPicker()
        try await eventually("Picker interception is disabled after cancellation") { try await js(reviewWeb, "return !document.querySelector('[data-alcove-zap-overlay]');") as? Bool == true }
        _ = try await js(reviewWeb, "document.getElementById('target').dispatchEvent(new Event('pointerdown',{bubbles:true,cancelable:true}));return true;")
        check(try await js(reviewWeb, "return captureCount===2 && reviewInput.value==='page activated';") as? Bool == true, "Normal page pointer input resumes after picker cancellation")
        for rootSize in [24, 10] {
            _ = try await reviewWeb.callAsyncJavaScript("const site=new CSSStyleSheet();site.replaceSync('html{font-size:'+size+'px!important}');document.adoptedStyleSheets=[...document.adoptedStyleSheets,site];return true;", arguments: ["size": rootSize], in: nil, contentWorld: .page)
            for (scale, expected) in [(0.75, Double(rootSize)*0.75), (1.0, Double(rootSize)), (1.25, Double(rootSize)*1.25), (1.25, Double(rootSize)*1.25)] {
                let base = review.store.boostCatalog(profileID: review.profile).entries[0]
                reviewedLook = base; reviewedLook.content.appearance.textScale = scale
                try await review.store.saveValidatedBoost(reviewedLook, profileID: review.profile, expected: base)
                try await eventually("Relative text scale \(scale) preserves the \(rootSize)px site baseline without compounding") { try await js(reviewWeb, "return parseFloat(getComputedStyle(document.documentElement).fontSize);") as? Double == expected }
                check(try await js(reviewWeb, "return getComputedStyle(document.getElementById('fixed')).fontSize;") as? String == "13px", "Relative root/rem scaling leaves explicit fixed-pixel descendants unchanged")
            }
            try review.store.setBoostsEnabled(false)
            try await eventually("Disabling relative text size restores the site's \(rootSize)px root") { try await js(reviewWeb, "return parseFloat(getComputedStyle(document.documentElement).fontSize);") as? Int == rootSize }
            try review.store.setBoostsEnabled(true)
        }
        store.shutdown()
        let selectorCount = store.boostCatalog(profileID: f.profile).entries.first?.hiddenSelectors.count
        _ = try? await js(web, "webkit.messageHandlers.alcoveBoostBridge.postMessage({kind:'picked',nonce:__alcoveBoostState_v1.nonce,picker:'old',selection:'old',selector:'#second'});", world: world)
        check(store.boostCatalog(profileID: f.profile).entries.first?.hiddenSelectors.count == selectorCount && store.boostPicker == nil, "Closing an owner cancels picker state and rejects old bridge messages")
        if failures != 0 { throw BoostWebsiteCheckError.failed }
    }
}
