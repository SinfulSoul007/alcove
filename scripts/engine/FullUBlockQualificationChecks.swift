import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum FullUBlockQualificationError:Error {case prerequisite(String),failed(String)}

@main struct FullUBlockIntegratedChecks {
    static let archives = [
        "zip":"4b1b27ed82e734d508ae6d255933c334f62f256e8a8aece92724b826828e3d5f",
        "crx":"ee44e69bb7a0e162bf08632929a5059bd676dfaa3ae2267e3c4eb11cc949b21a",
    ]
    static func digest(_ file:URL) throws -> String {
        SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()
    }
    @MainActor static func require(_ value:Bool,_ description:String) throws {
        print("\(value ? "PASS":"FAIL"): \(description)")
        if !value {throw FullUBlockQualificationError.failed(description)}
    }
    @MainActor static func ready(_ page:WKWebView,_ address:URL) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if page.url == address,!page.isLoading,
               (try? await page.evaluateJavaScript("document.readyState==='complete'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(25))
        }
        throw URLError(.timedOut)
    }
    @MainActor static func message(_ options:WKWebView,_ request:[String:Any]) async throws -> Any? {
        print("UBO_DIAGNOSTIC_MESSAGE",request["what"] ?? "unknown","URL",options.url?.absoluteString ?? "nil","LOADING",options.isLoading)
        return try await options.callAsyncJavaScript("""
            if(typeof globalThis.vAPI?.messaging?.send!=='function') {
                let lastError='not-read';
                try { lastError=browser.runtime.lastError?.message??null; } catch(error) {lastError=String(error);}
                throw Error('Genuine dashboard messaging unavailable '+JSON.stringify({what:request.what,href:location.href,ready:document.readyState,visibility:document.visibilityState,top:self===self.top,vAPI:typeof globalThis.vAPI,browser:typeof globalThis.browser,runtime:typeof globalThis.browser?.runtime,timeOrigin:performance.timeOrigin,lastError,frames:Array.from(document.querySelectorAll('iframe'),frame=>frame.src)}));
            }
            return await Promise.race([
                vAPI.messaging.send('dashboard',request).then(value=>({reply:value??null})),
                new Promise((_,reject)=>setTimeout(()=>reject(Error('Genuine dashboard reply timed out')),5000))
            ]);
            """,arguments:["request":request],in:nil,contentWorld:.page)
    }
    @MainActor static func reply(_ options:WKWebView,_ request:[String:Any]) async throws -> Any? {
        (try await message(options,request) as? [String:Any])?["reply"]
    }
    @MainActor static func dashboardReady(_ options:WKWebView,_ expected:URL) async throws {
        let deadline=ContinuousClock.now + .seconds(35)
        var last=""
        while ContinuousClock.now<deadline {
            guard options.url?.path==expected.path,options.url?.host==expected.host else {
                throw FullUBlockQualificationError.failed("Dashboard left its document before any test message: "+(options.url?.absoluteString ?? "nil"))
            }
            let state=(try? await options.evaluateJavaScript("""
                (()=>{
                    const frame=document.querySelector('#iframe');
                    let href='',ready='',elements=0;
                    try{href=frame?.contentWindow?.location.href??'';ready=frame?.contentDocument?.readyState??'';elements=frame?.contentDocument?.body?.childElementCount??0;}catch{}
                    return {href:location.href,frame:href,ready,elements};
                })()
                """)) as? [String:Any] ?? [:]
            let frame=state["frame"] as? String ?? "",ready=state["ready"] as? String ?? "",elements=state["elements"] as? Int ?? 0
            let marker=(state["href"] as? String ?? "nil")+" FRAME "+frame+" READY "+ready+" ELEMENTS "+String(elements)
            if marker != last {print("UBO_OWN_DASHBOARD_STARTUP",marker);last=marker}
            if let frameURL=URL(string:frame),frameURL.scheme==expected.scheme,frameURL.host==expected.host,
               frameURL.path.hasSuffix(".html"),!["/blank.html","/background.html"].contains(frameURL.path),ready=="complete",elements>0 {
                try require(true,"The genuine dashboard finishes its own initial pane before test messages")
                return
            }
            try await Task.sleep(for:.milliseconds(25))
        }
        throw FullUBlockQualificationError.failed("The genuine dashboard did not finish its initial pane: "+last)
    }
    @MainActor static func startup(_ options:WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(35)
        var last = "No reply"
        while ContinuousClock.now < deadline {
            do {
                if let app = try await reply(options,["what":"getAppData"]) as? [String:Any],
                   app["name"] as? String == "uBlock Origin",app["version"] as? String == "1.76.4",
                   let lists = try await reply(options,["what":"getLists"]) as? [String:Any],
                   (lists["netFilterCount"] as? Int ?? 0) > 0 {
                    try require(true,"Unchanged full uBlock Origin returns genuine application and loaded-list replies")
                    return
                }
            } catch {last = String(describing:error)}
            try await Task.sleep(for:.milliseconds(100))
        }
        throw FullUBlockQualificationError.failed("Full uBO startup did not complete: " + last)
    }
    @MainActor static func count(_ server:URL,_ resource:URL) async throws -> Int {
        var endpoint = URLComponents(url:server.appendingPathComponent("__request_count"),resolvingAgainstBaseURL:false)!
        endpoint.queryItems = [URLQueryItem(name:"path",value:resource.path)]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration:configuration);defer {session.invalidateAndCancel()}
        let (data,response) = try await session.data(from:endpoint.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = Int(String(decoding:data,as:UTF8.self)) else {throw URLError(.badServerResponse)}
        return value
    }
    @MainActor static func sample(_ page:WKWebView,_ address:URL,_ server:URL) async throws -> (state:[String:Bool],control:Int,target:Int) {
        let control = address.appendingPathComponent("control.js"),target = address.appendingPathComponent("should-cancel.js")
        let beforeControl = try await count(server,control),beforeTarget = try await count(server,target)
        page.load(URLRequest(url:address,cachePolicy:.reloadIgnoringLocalCacheData));try await ready(page,address)
        let result = try await page.callAsyncJavaScript("""
            await new Promise(resolve=>setTimeout(resolve,1000));
            const element=document.getElementById('alcove-owned-sponsored');
            return {control:window.controlRequestLoaded===true,target:window.candidateRequestLoaded===true,
                    hidden:!!element && getComputedStyle(element).display==='none'};
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Bool]
        guard let result else {throw FullUBlockQualificationError.failed("Invalid page sample")}
        let controlDelta = try await count(server,control)-beforeControl,targetDelta = try await count(server,target)-beforeTarget
        print("UBO_ACTUAL_PAGE",result,"SERVER_DELTA",controlDelta,targetDelta)
        return (result,controlDelta,targetDelta)
    }
    @available(macOS 15.4,*)
    @MainActor static func exercise(_ asset:URL,server:URL,owned:OwnedWebsiteStores,controllers:OwnedExtensionControllers) async throws {
        guard let expected = archives[asset.pathExtension] else {throw FullUBlockQualificationError.prerequisite("Use the original ZIP or CRX")}
        try require(try digest(asset)==expected,"Original upstream \(asset.pathExtension.uppercased()) SHA256 matches the pinned release")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-integrated-full-ubo-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let key = SymmetricKey(data:Data(repeating:61,count:32))
        let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
        defer {store.shutdown()}
        let profile = try store.createProfile(name:"Owned full uBO qualification")
        try owned.register(profile);try controllers.register(store.profiles.first(where:{$0.id==profile})!.extensionControllerID!)
        let address = server.appendingPathComponent("native-fixture-"+UUID().uuidString)
        let tabID = store.newTab(url:address),page = store.view(for:tabID)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = page;store.registerExtensionWindow(window,kind:.primary)
        window.makeKeyAndOrderFront(nil);NSApplication.shared.activate()
        print("UBO_VISIBLE_WINDOW",window.isVisible)
        defer {store.unregisterExtensionWindow(kind:.primary);window.contentView=nil;window.close()}
        try await ready(page,address)
        let baseline = try await sample(page,address,server)
        try require(baseline.state==["control":true,"target":true,"hidden":false] && baseline.control==1 && baseline.target==1,"Before installation, the real app loads both scripts and shows the cosmetic target")
        let package = try ExtensionPackage.prepare(at:asset,stagingRoot:store.extensionStagingRoot)
        defer {try? package.discard()}
        try require(package.manifest.name=="uBlock Origin" && package.manifest.version=="1.76.4" && package.manifest.manifestVersion==2,"The app stages the unchanged full MV2 package")
        let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:package.manifest.requestedPermissions,hostPatterns:["http://127.0.0.1/*"],allowPrivate:false,enable:true)
        let id = try await store.installExtension(package,approval:approval)
        print("UBO_ACTUAL_APP_INSTALLED",id,"DIGEST",package.digest)
        print("UBO_ACTUAL_APP_NATIVE_PREPARE_BEGIN")
        try await store.prepareExtensions(profileID:profile)
        let optionsID = try await store.openExtensionOptions(id,profileID:profile)
        guard let options = store.views[optionsID],let url = (store.extensionHosting as? NativeBrowserExtensionHost)?.profiles[profile]?.contexts[id]?.optionsPageURL else {throw FullUBlockQualificationError.failed("The app did not open real options")}
        window.contentView=options;try await ready(options,url);try await dashboardReady(options,url)
        let capabilities = try await options.evaluateJavaScript("JSON.stringify({privacy:typeof browser.privacy,idle:typeof requestIdleCallback,updateEvent:typeof browser.runtime.onUpdateAvailable?.addListener,navigationTarget:typeof browser.webNavigation.onCreatedNavigationTarget?.addListener})") as? String ?? "null"
        print("UBO_NATIVE_CAPABILITIES",capabilities)
        try await startup(options)
        let rules = "|\(address.appendingPathComponent("should-cancel.js").absoluteString)|$script\n127.0.0.1###alcove-owned-sponsored\n"
        guard let saved = try await reply(options,["what":"writeUserFilters","content":rules,"enabled":true,"trusted":false]) as? [String:Any],saved["error"]==nil,
              let readBack = try await reply(options,["what":"readUserFilters"]) as? [String:Any],
              (readBack["content"] as? String)?.contains(rules.trimmingCharacters(in:.whitespacesAndNewlines))==true else {throw FullUBlockQualificationError.failed("Genuine dashboard filter write/readback failed")}
        _ = try await message(options,["what":"reloadAllFilters"])
        try require(true,"Genuine dashboard saves, reads and compiles untrusted user filters without package edits")
        store.select(tabID);window.contentView=page
        let filtered = try await sample(page,address,server)
        try require(filtered.control==1 && filtered.target==0 && filtered.state==["control":true,"target":false,"hidden":true],"Full uBlock Origin blocks the actual target request before the server and hides the cosmetic target while allowing the control")
        try store.setExtensionEnabled(id,profileID:profile,enabled:false)
        try await store.prepareExtensions(profileID:profile)
        let disabled = try await sample(page,address,server)
        try require(disabled.control==1 && disabled.target==1 && disabled.state==["control":true,"target":true,"hidden":false],"Disabling the genuine extension restores both network and cosmetic baseline")
        try store.setExtensionEnabled(id,profileID:profile,enabled:true);try await store.prepareExtensions(profileID:profile)
        let restoredID = try await store.openExtensionOptions(id,profileID:profile)
        guard let restored = store.views[restoredID],let restoredURL = (store.extensionHosting as? NativeBrowserExtensionHost)?.profiles[profile]?.contexts[id]?.optionsPageURL else {throw FullUBlockQualificationError.failed("Restored real options missing")}
        window.contentView=restored;try await ready(restored,restoredURL);try await dashboardReady(restored,restoredURL);try await startup(restored)
        store.select(tabID);window.contentView=page
        let reloaded = try await sample(page,address,server)
        try require(reloaded.control==1 && reloaded.target==0 && reloaded.state==["control":true,"target":false,"hidden":true],"Reloading a fresh genuine extension restores its saved effective rules")
        guard let record = store.extensionRecords(profileID:profile).first(where:{$0.id==id}) else {throw FullUBlockQualificationError.failed("Installed catalog missing")}
        _ = try ExtensionPackage.inspectInstalled(record:record,profileID:profile,packagesRoot:store.extensionPackagesRoot)
        let unchangedArchive = try digest(asset)==expected
        try require(record.packageDigest==package.digest && record.grants?.allowPrivate==false && record.grants?.hostPatterns==["http://127.0.0.1/*"] && unchangedArchive,"Installed code and original archive remain unchanged; only reviewed loopback access was granted")
        print("UNMODIFIED_FULL_UBO_ASSET_FILTERING_PROVEN",asset.pathExtension)
    }
    @MainActor static func run() async throws -> Int32 {
        NSApplication.shared.setActivationPolicy(.regular);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {throw FullUBlockQualificationError.prerequisite("macOS15.4 required")}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        if CommandLine.arguments.contains("--cleanup-owned-stores") {
            let nativeClean = await controllers.cleanup(),websiteClean = await owned.cleanup()
            return nativeClean && websiteClean ? 0:1
        }
        guard CommandLine.arguments.count>1,
              let raw = ProcessInfo.processInfo.environment["ALCOVE_UBO_LOOPBACK_URL"],let server = URL(string:raw),
              server.scheme=="http",server.host=="127.0.0.1",server.port != nil else {throw FullUBlockQualificationError.prerequisite("Owned loopback and macOS15.4 required")}
        let framework = Bundle(for:WKWebView.self).bundleURL.resolvingSymlinksInPath().path
        print("ACTUAL_WEBKIT_FRAMEWORK",framework)
        if let expected = ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] {
            let root = URL(fileURLWithPath:expected).resolvingSymlinksInPath().path
            guard framework.hasPrefix(root+"/") || framework==root else {throw FullUBlockQualificationError.prerequisite("Unexpected WebKit framework")}
        }
        guard await controllers.cleanup(),await owned.cleanup() else {return 1}
        var success = true
        do {
            for asset in CommandLine.arguments.dropFirst() {try await exercise(URL(fileURLWithPath:asset),server:server,owned:owned,controllers:controllers)}
        } catch {success=false;print("UNMODIFIED_FULL_UBO_QUALIFICATION_FAILED",String(describing:error))}
        let nativeClean = await controllers.cleanup(),websiteClean = await owned.cleanup()
        if !nativeClean || !websiteClean {success=false;print("FAIL: Owned native fixture storage cleanup")}
        if success {print("UNMODIFIED_FULL_UBO_INTEGRATED_FILTERING_PROVEN true")}
        return success ? 0:1
    }
    nonisolated(unsafe) static var completed = false
    @MainActor static func main() {
        setbuf(stdout,nil)
        atexit {
            if !FullUBlockIntegratedChecks.completed {
                fputs("UBO_APPLICATION_LOOP_PREMATURE_EXIT\n",stderr)
                _exit(86)
            }
        }
        _ = NSApplication.shared
        Task { @MainActor in
            print("UBO_NATIVE_APPLICATION_RUNNING", NSApp.isRunning)
            do {
                let status = try await run()
                completed = true
                exit(status)
            } catch {
                completed = true
                print("UBO_APPLICATION_LOOP_FAILED",String(describing:error))
                exit(1)
            }
        }
        NSApp.run()
    }
}
