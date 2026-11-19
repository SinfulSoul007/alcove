import AppKit
import WebKit
import CryptoKit
import BrowserCore

@main struct ExtensionIdleChecks {
    @MainActor static func ready(_ page:WKWebView,_ address:URL) async throws {
        for _ in 0..<500 {
            if page.url == address,!page.isLoading,(try? await page.evaluateJavaScript("document.readyState==='complete'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw URLError(.timedOut)
    }
    static let qualify = """
        const result={idleType:typeof self.requestIdleCallback,cancelType:typeof self.cancelIdleCallback};
        if(result.idleType==='function' && result.cancelType==='function') {
            result.nativeSource=Function.prototype.toString.call(self.requestIdleCallback).includes('[native code]');
            let cancelled=false;
            const token=requestIdleCallback(()=>{cancelled=true;},{timeout:20});cancelIdleCallback(token);
            const ordinary=Promise.race([
                new Promise(resolve=>requestIdleCallback(d=>resolve({called:true,didTimeout:d.didTimeout,remaining:d.timeRemaining()}))),
                new Promise(resolve=>setTimeout(()=>resolve({called:false}),2000))
            ]);
            const timed=Promise.race([
                new Promise(resolve=>{
                    requestIdleCallback(d=>resolve({called:true,didTimeout:d.didTimeout,remaining:d.timeRemaining()}),{timeout:1});
                    const end=performance.now()+40;while(performance.now()<end){}
                }),
                new Promise(resolve=>setTimeout(()=>resolve({called:false}),2000))
            ]);
            result.ordinary=await ordinary;result.timed=await timed;
            await new Promise(resolve=>setTimeout(resolve,80));result.cancelledFired=cancelled;
        }
        return result;
        """
    static func native(_ facts:[String:Any]?) -> Bool {
        facts?["idleType"] as? String == "function" && facts?["cancelType"] as? String == "function" && facts?["nativeSource"] as? Bool == true
    }
    static func schedules(_ facts:[String:Any]?) -> Bool {
        guard let ordinary = facts?["ordinary"] as? [String:Any],let timed = facts?["timed"] as? [String:Any],
              let remaining = ordinary["remaining"] as? Double else {return false}
        return ordinary["called"] as? Bool == true && ordinary["didTimeout"] as? Bool == false && remaining.isFinite && (0...50).contains(remaining)
            && timed["called"] as? Bool == true && timed["didTimeout"] as? Bool == true && timed["remaining"] as? Double == 0 && facts?["cancelledFired"] as? Bool == false
    }
    @MainActor static func background(_ options:WKWebView,launch:Int) async throws -> [String:Any]? {
        for _ in 0..<500 {
            if let result = try await options.callAsyncJavaScript("return (await browser.storage.local.get('idleResult')).idleResult ?? null;",arguments:[:],in:nil,contentWorld:.page) as? [String:Any],
               (result["launch"] as? Int ?? 0) >= launch {return result}
            try await Task.sleep(for:.milliseconds(20))
        }
        return nil
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Native extensions require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        if CommandLine.arguments.contains("--cleanup-owned-stores") {
            let nativeClean = await controllers.cleanup(),sitesClean = await owned.cleanup()
            exit(nativeClean && sitesClean ? 0:1)
        }
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let text = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:text) else {throw CocoaError(.fileReadInvalidFileName)}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:61,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ label:String) {print("\(value ? "PASS":"FAIL"): \(label)");if !value {failures += 1}}
        func exercise() async throws {
            let baselineConfiguration = WKWebViewConfiguration();baselineConfiguration.websiteDataStore = .nonPersistent()
            let baseline = WKWebView(frame:.zero,configuration:baselineConfiguration)
            let controlURL = fixture.appendingPathComponent("idle-baseline");baseline.load(URLRequest(url:controlURL));try await ready(baseline,controlURL)
            let baselineType = try await baseline.evaluateJavaScript("typeof requestIdleCallback") as? String
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key});defer {store.shutdown()}
            let profile = try store.createProfile(name:"Owned idle account")
            try owned.register(profile);try controllers.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let source = root.appendingPathComponent("source");try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":2,"name":"Owned native idle","description":"Native scheduling fixture","version":"1","permissions":["storage","http://127.0.0.1/*"],"background":{"scripts":["background.js"],"persistent":true},"options_page":"options.html","content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}]}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><meta charset='utf-8'><title>Owned idle options</title><body>Owned idle options".utf8).write(to:source.appendingPathComponent("options.html"))
            let script = """
                (async()=>{
                    const previous=(await browser.storage.local.get('idleResult')).idleResult;
                    const facts=await(async()=>{\(qualify)})();facts.launch=(previous?.launch??0)+1;
                    await browser.storage.local.set({idleResult:facts});
                })().catch(async e=>{await browser.storage.local.set({idleResult:{error:String(e),launch:999}});});
                """
            try Data(script.utf8).write(to:source.appendingPathComponent("background.js"))
            try Data("""
                if(typeof requestIdleCallback==='function') {
                    const native=Function.prototype.toString.call(requestIdleCallback).includes('[native code]');
                    requestIdleCallback(()=>{document.documentElement.dataset.ownedIdleContent=native?'native-called':'other';},{timeout:701});
                } else {document.documentElement.dataset.ownedIdleContent='missing';}
                """.utf8).write(to:source.appendingPathComponent("content.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging"))
            let normalURL = fixture.appendingPathComponent("idle-normal"),normalID = store.newTab(url:normalURL),normal = store.view(for:normalID)
            try await ready(normal,normalURL)
            check((try await normal.evaluateJavaScript("typeof requestIdleCallback")) as? String == "function","Ordinary Alcove websites expose native idle scheduling before any extension is installed")
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = normal;store.registerExtensionWindow(window,kind:.primary)
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await store.installExtension(package,approval:approval)
            try await store.prepareExtensions(profileID:profile)
            let injectedURL = fixture.appendingPathComponent("idle-injected");normal.load(URLRequest(url:injectedURL));try await ready(normal,injectedURL)
            for _ in 0..<200 {
                if (try? await normal.evaluateJavaScript("document.documentElement.dataset.ownedIdleContent")) as? String == "native-called" {break}
                try await Task.sleep(for:.milliseconds(10))
            }
            check((try await normal.evaluateJavaScript("document.documentElement.dataset.ownedIdleContent")) as? String == "native-called","An approved real content script executes the native idle callback in its isolated world")
            let optionsID = try await store.openExtensionOptions(id,profileID:profile),options = store.views[optionsID]!
            let host = store.extensionHosting as! NativeBrowserExtensionHost,context = host.profiles[profile]!.contexts[id]!
            try await ready(options,context.optionsPageURL!)
            let before = store.extensionRecords(profileID:profile)
            let optionFacts = try await options.callAsyncJavaScript(qualify,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
            check(native(optionFacts),"Actual app extension options expose native idle scheduling functions")
            check(schedules(optionFacts),"Actual app extension options run ordinary and timeout callbacks and honor cancellation")
            let backgroundFacts = try await background(options,launch:1)
            check(native(backgroundFacts),"An approved app MV2 background exposes native idle scheduling functions")
            check(schedules(backgroundFacts),"An approved app background runs ordinary and timeout callbacks and honors cancellation")
            let freshURL = fixture.appendingPathComponent("idle-fresh-normal"),freshID = store.newTab(url:freshURL),fresh = store.view(for:freshID)
            try await ready(fresh,freshURL)
            check((try await fresh.evaluateJavaScript("typeof requestIdleCallback")) as? String == "function","Fresh ordinary Alcove websites expose the same native idle API")
            _ = try await normal.evaluateJavaScript("document.cookie='owned_idle_cookie=normal;path=/';localStorage.setItem('owned_idle_site','normal');true")
            var privateKeys = 0
            let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in privateKeys += 1;return key})
            defer {privateStore.shutdown()}
            let privateURL = fixture.appendingPathComponent("idle-private"),privateID = privateStore.newTab(url:privateURL),privatePage = privateStore.view(for:privateID)
            try await ready(privatePage,privateURL)
            check((try await privatePage.evaluateJavaScript("typeof requestIdleCallback")) as? String == "function","Standalone private Alcove pages expose native idle scheduling without normal extension access")
            let privateIsolated = try await privatePage.evaluateJavaScript("!document.cookie.includes('owned_idle_cookie') && localStorage.getItem('owned_idle_site') === null && document.documentElement.dataset.ownedIdleContent === undefined") as? Bool
            check(privateKeys == 0 && privateIsolated == true,"Native scheduling shares no normal website storage, private key or unapproved content script")
            let rawConfiguration = WKWebViewConfiguration();rawConfiguration.websiteDataStore = .nonPersistent()
            let raw = WKWebView(frame:.zero,configuration:rawConfiguration),rawURL = fixture.appendingPathComponent("idle-raw-default")
            raw.load(URLRequest(url:rawURL));try await ready(raw,rawURL)
            check((try await raw.evaluateJavaScript("typeof requestIdleCallback")) as? String == baselineType,"Alcove configuration does not change unconfigured WebKit defaults")
            check(store.extensionRecords(profileID:profile) == before,"Native idle callbacks change no saved extension identity or approval")
            try store.setExtensionEnabled(id,profileID:profile,enabled:false);try store.setExtensionEnabled(id,profileID:profile,enabled:true)
            try await store.prepareExtensions(profileID:profile)
            let reloadedID = try await store.openExtensionOptions(id,profileID:profile),reloaded = store.views[reloadedID]!
            let newContext = host.profiles[profile]!.contexts[id]!
            try await ready(reloaded,newContext.optionsPageURL!)
            let reloadedFacts = try await background(reloaded,launch:2)
            check(newContext !== context && native(reloadedFacts) && schedules(reloadedFacts),"Reload creates a fresh native background with working idle callbacks rather than reusing stored results")
            baseline.stopLoading()
        }
        do {try await exercise()} catch {check(false,"Native idle app exercise failed: \(error)")}
        check(await controllers.cleanup(),"Idle fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Idle fixtures release only their owned named website stores")
        print("Extension idle checks: \(failures) failures");exit(failures == 0 ? 0:1)
    }
}
