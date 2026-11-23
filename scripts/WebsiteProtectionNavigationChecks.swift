import AppKit
import WebKit
import Network
import CryptoKit
import BrowserCore
import Darwin

@main struct WebsiteProtectionNavigationChecks {
    nonisolated(unsafe) static var returnedFromRun=false
    enum Failure:Error {case fixture,timeout,checks(Int)}
    @MainActor static func descendants(_ root:NSView) -> [NSView] { [root]+root.subviews.flatMap{descendants($0)} }
    @MainActor static func ready(_ web:WKWebView,host:String) async throws {
        for _ in 0..<750 {
            if web.url?.host==host,!web.isLoading,(try? await web.evaluateJavaScript("document.readyState==='complete'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw Failure.timeout
    }
    @MainActor static func run() async throws {
        guard let raw=ProcessInfo.processInfo.environment["ALCOVE_OWNED_PROXY_PORT"],let number=UInt16(raw),let port=NWEndpoint.Port(rawValue:number),let resources=Bundle.main.resourceURL?.appendingPathComponent("WebsiteProtection") else {throw Failure.fixture}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("alcove-browser-protection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let catalogRoot=root.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at:catalogRoot,withIntermediateDirectories:true)
        let domains=Data("listed.alcove.example\n".utf8)
        let license=try Data(contentsOf:resources.appendingPathComponent("LICENSE.PhishDestroy.txt"))
        let metadata=try JSONSerialization.data(withJSONObject:[
            "formatVersion":1,"provider":"PhishDestroy","sourceRevision":String(repeating:"1",count:40),
            "sourceUpdatedAt":"2026-11-01T00:00:00Z","retrievedAt":"2026-11-02T00:00:00Z",
            "sha256":SHA256.hash(data:domains).map{String(format:"%02x",$0)}.joined(),
            "licenseSHA256":SHA256.hash(data:license).map{String(format:"%02x",$0)}.joined(),"domainCount":1])
        try domains.write(to:catalogRoot.appendingPathComponent("domains.txt"))
        try metadata.write(to:catalogRoot.appendingPathComponent("source.json"))
        try license.write(to:catalogRoot.appendingPathComponent("LICENSE.PhishDestroy.txt"))
        let service=WebsiteProtectionService(loader:{try WebsiteProtectionService.loadCatalog(at:catalogRoot)})
        var checks=0,failures=0
        func check(_ value:Bool,_ label:String){checks+=1;print("\(value ? "PASS":"FAIL"): \(label)");if !value {failures+=1}}
        if case .listed=await service.assessment(for:URL(string:"http://listed.alcove.example/target")!) {check(true,"The actual injected catalog classifies the owned target")} else {throw Failure.fixture}
        let store=BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("metadata"),keyProvider:{_ in fatalError("Private fixture requested a metadata key")},websiteProtection:service)
        defer {store.shutdown()}
        let dataStore=store.websiteDataStore(forProfile:store.activeProfileID)
        var proxy=ProxyConfiguration(httpCONNECTProxy:.hostPort(host:"127.0.0.1",port:port));proxy.allowFailover=false
        dataStore.proxyConfigurations=[proxy]
        let initial=URL(string:"http://safe.alcove.example/form?case=browser-protection-baseline")!
        let id=store.newTab(url:initial)
        let web=store.view(for:id)
        let host=EdgeToEdgeWebHost(frame:NSRect(x:0,y:0,width:800,height:600))
        WebPane(webView:web,store:store).mount(in:host)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="Alcove Protection QA";window.contentView=host
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer {window.orderOut(nil);window.close()}
        try await ready(web,host:"safe.alcove.example")
        _=try await web.evaluateJavaScript("window.ownedOriginalDocument=true;document.getElementById('token').value='typed-owned';true")
        store.navigate("http://listed.alcove.example/target?case=browser-protection-block")
        for _ in 0..<250 {
            if descendants(host).contains(where:{$0.identifier?.rawValue=="AlcoveWebsiteProtection" && !$0.isHidden}) || web.url?.host=="listed.alcove.example" && !web.isLoading {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:"+raw+"/_events")!)
        let all=try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        let targets=all.filter{$0["case"] as? String=="browser-protection-block" && $0["host"] as? String=="listed.alcove.example"}
        let warning=descendants(host).first{$0.identifier?.rawValue=="AlcoveWebsiteProtection" && !$0.isHidden}
        check(targets.isEmpty,"A real BrowserStore policy keeps the listed target off the server")
        check(warning != nil,"A real mounted browser pane presents a native warning")
        if let warning {print("NATIVE_WARNING_GEOMETRY","overlay",warning.frame,"host",host.bounds,"layer",warning.wantsLayer,"window",window.isVisible)}
        if warning != nil,let raw=ProcessInfo.processInfo.environment["ALCOVE_VISUAL_WITNESS_SECONDS"],let seconds=Double(raw),seconds>0,seconds<=60 {
            print("NATIVE_WEBSITE_WARNING_VISUAL_READY")
            if ProcessInfo.processInfo.environment["ALCOVE_PHYSICAL_WARNING_SAFE"]=="1" {
                for _ in 0..<Int(seconds*50) {
                    if store.websiteProtectionTicket(for:web)==nil {break}
                    try await Task.sleep(for:.milliseconds(20))
                }
                check(store.websiteProtectionTicket(for:web)==nil,"A physical safe key cancels the warning before the fixture clicks")
            } else {try await Task.sleep(for:.seconds(seconds))}
        }
        if let button=warning.flatMap({descendants($0).first{$0.identifier?.rawValue=="AlcoveWebsiteProtectionSafe"} as? NSButton}) {
            button.performClick(nil)
            for _ in 0..<250 {if !web.isLoading {break};try await Task.sleep(for:.milliseconds(20))}
            check(try await web.evaluateJavaScript("window.ownedOriginalDocument===true&&document.getElementById('token')?.value==='typed-owned'") as? Bool==true,"The actual safe control keeps the mounted typed form")
            check(store.tab(id)?.url==initial.absoluteString,"The actual safe control restores the displayed tab address")
        } else {check(false,"The native warning has its safe control")}
        func targetRequests(_ name:String) async throws -> [[String:Any]] {
            let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:"+raw+"/_events")!)
            return (try JSONSerialization.jsonObject(with:data) as! [[String:Any]]).filter{$0["case"] as? String==name && $0["host"] as? String=="listed.alcove.example"}
        }
        for kind in ["direct","post307","frame"] {
            let name="browser-continue-"+kind
            web.load(URLRequest(url:URL(string:"http://safe.alcove.example/form?case=baseline-"+name)!))
            try await ready(web,host:"safe.alcove.example")
            _=try await web.evaluateJavaScript("window.ownedOriginalDocument=true;document.getElementById('token').value='typed-owned';true")
            let target="http://listed.alcove.example/target?case="+name
            switch kind {
            case "post307":
                _=try await web.evaluateJavaScript("document.getElementById('f').action='http://safe.alcove.example/redirect307?case="+name+"';document.getElementById('f').submit();true")
            case "frame":
                _=try await web.evaluateJavaScript("window.ownedFrameFinished=false;const frame=document.createElement('iframe');frame.onload=()=>window.ownedFrameFinished=true;frame.src='"+target+"';document.body.appendChild(frame);true")
            default:store.navigate(target)
            }
            var current:NSView?
            for _ in 0..<250 {
                current=descendants(host).first{$0.identifier?.rawValue=="AlcoveWebsiteProtection" && !$0.isHidden}
                if current != nil {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            check(try await targetRequests(name).isEmpty,name+": the warning holds the real target request")
            check((try? await web.evaluateJavaScript("window.ownedOriginalDocument===true&&document.getElementById('token')?.value==='typed-owned'")) as? Bool==true,name+": the typed document remains mounted while deciding")
            guard let button=current.flatMap({descendants($0).first{$0.identifier?.rawValue=="AlcoveWebsiteProtectionContinue"} as? NSButton}) else {check(false,name+": native continue control is present");continue}
            check(!button.isHidden,name+": native continue control is present")
            button.performClick(nil)
            if kind=="frame" {
                var completed=false
                for _ in 0..<750 {
                    if (try? await web.evaluateJavaScript("window.ownedFrameFinished===true")) as? Bool==true {completed=true;break}
                    try await Task.sleep(for:.milliseconds(20))
                }
                guard completed else {throw Failure.timeout}
            } else {try await ready(web,host:"listed.alcove.example")}
            let received=try await targetRequests(name)
            check(received.count==1,name+": native continue allows exactly the captured request")
            if kind=="post307" {check(received.first?["method"] as? String=="POST" && received.first?["body"] as? String=="token=typed-owned",name+": form method and body survive the redirect and warning")}
            if kind=="frame" {check((try? await web.evaluateJavaScript("window.ownedOriginalDocument===true&&document.getElementById('token')?.value==='typed-owned'")) as? Bool==true,name+": continuing the iframe preserves its parent form")}
        }
        for (native,allow) in [(false,false),(false,true),(true,false),(true,true)] {
            let name="browser-"+(native ? "native-":"")+"download-redirect-"+(allow ? "continue":"cancel")
            web.load(URLRequest(url:URL(string:"http://safe.alcove.example/form?case=baseline-"+name)!))
            try await ready(web,host:"safe.alcove.example")
            _=try await web.evaluateJavaScript("window.ownedOriginalDocument=true;document.getElementById('token').value='typed-owned';true")
            var nativeDownload:WKDownload?
            if native {
                web.startDownload(using:URLRequest(url:URL(string:"http://safe.alcove.example/redirect-download?case="+name)!)) { download in
                    nativeDownload=download
                    store.trackDownload(download,from:web)
                }
            } else {
                _=try await web.evaluateJavaScript("const link=document.createElement('a');link.href='http://safe.alcove.example/redirect-download?case="+name+"';link.download='owned.txt';document.body.appendChild(link);link.click();true")
            }
            var current:NSView?
            for _ in 0..<250 {
                current=descendants(host).first{$0.identifier?.rawValue=="AlcoveWebsiteProtection" && !$0.isHidden}
                if current != nil || NSApp.windows.contains(where:{$0 is NSSavePanel && $0.isVisible}) {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            check(try await targetRequests(name).isEmpty,name+": a download redirect is held before contacting its target")
            check(current != nil,name+": the download redirect has a native warning")
            let identifier=allow ? "AlcoveWebsiteProtectionContinue":"AlcoveWebsiteProtectionSafe"
            if let button=current.flatMap({descendants($0).first{$0.identifier?.rawValue==identifier} as? NSButton}) {button.performClick(nil)}
            if allow && current != nil {
                var offered=false
                for _ in 0..<750 {
                    if let panel=NSApp.windows.first(where:{$0 is NSSavePanel && $0.isVisible}) as? NSSavePanel {offered=true;panel.cancel(nil);break}
                    try await Task.sleep(for:.milliseconds(20))
                }
                check(offered,name+": the original native download reaches its actual destination chooser")
                check(try await targetRequests(name).count==1,name+": continue allows exactly the captured download redirect")
            } else {
                for panel in NSApp.windows.compactMap({$0 as? NSSavePanel}) {panel.cancel(nil)}
                if current != nil {check(try await targetRequests(name).isEmpty,name+": safe cancellation never starts the redirected request")}
            }
            check((try? await web.evaluateJavaScript("window.ownedOriginalDocument===true&&document.getElementById('token')?.value==='typed-owned'")) as? Bool==true,name+": download decisions keep the typed page")
            withExtendedLifetime(nativeDownload) {}
        }
        let shiftCase="browser-shift-peek"
        web.load(URLRequest(url:URL(string:"http://safe.alcove.example/form?case=baseline-"+shiftCase)!))
        try await ready(web,host:"safe.alcove.example")
        let coordinates=try await web.evaluateJavaScript("""
            window.ownedOriginalDocument=true;document.getElementById('token').value='typed-owned';
            const ownedLink=document.createElement('a');ownedLink.href='http://listed.alcove.example/target?case=browser-shift-peek';
            ownedLink.textContent='Owned preview';ownedLink.style.display='block';document.body.appendChild(ownedLink);
            ownedLink.addEventListener('click',event=>{window.ownedShiftClick={shift:event.shiftKey,trusted:event.isTrusted};});
            const ownedRect=ownedLink.getBoundingClientRect();[ownedRect.x+ownedRect.width/2,ownedRect.y+ownedRect.height/2];
            """) as? [Double]
        guard let coordinates,coordinates.count==2 else {throw Failure.fixture}
        let point=web.convert(NSPoint(x:coordinates[0],y:web.isFlipped ? coordinates[1]:web.bounds.height-coordinates[1]),to:nil)
        window.makeFirstResponder(web)
        for type:NSEvent.EventType in [.leftMouseDown,.leftMouseUp] {
            guard let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseDown ? 1:0) else {throw Failure.fixture}
            window.sendEvent(event)
        }
        for _ in 0..<250 {
            if store.primaryPeekView != nil || store.websiteProtectionTicket(for:web) != nil {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let trustedShift=(try? await web.evaluateJavaScript("window.ownedShiftClick?.shift===true&&window.ownedShiftClick?.trusted===true")) as? Bool==true
        check(trustedShift,"A real native shift-click reaches the owned page")
        guard trustedShift else {throw Failure.fixture}
        let peek=store.primaryPeekView
        check(peek != nil && store.websiteProtectionTicket(for:web)==nil,"Shift-click routes the request to Peek before presenting its website warning")
        let peekHost=EdgeToEdgeWebHost(frame:host.bounds)
        if let peek {WebPane(webView:peek,store:store).mount(in:peekHost);window.contentView=peekHost}
        var peekSafe:NSButton?
        for _ in 0..<250 {
            peekSafe=descendants(peekHost).first{$0.identifier?.rawValue=="AlcoveWebsiteProtectionSafe" && !$0.isHiddenOrHasHiddenAncestor} as? NSButton
            if peekSafe != nil || peek==nil {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        check(peekSafe != nil,"Only the actual Peek presents the native warning")
        check(try await targetRequests(shiftCase).isEmpty,"A blocked Peek request never contacts its target before choice")
        if let peekSafe {peekSafe.performClick(nil)} else {store.websiteProtectionTicket(for:web)?.cancel()}
        check(try await targetRequests(shiftCase).isEmpty,"Safe cancellation of the Peek keeps the target untouched")
        store.closePrimaryPeek();window.contentView=host
        check((try? await web.evaluateJavaScript("window.ownedOriginalDocument===true&&document.getElementById('token')?.value==='typed-owned'")) as? Bool==true,"Canceling a blocked Peek preserves its original parent form")
        web.load(URLRequest(url:URL(string:"http://listed.alcove.example/form?case=baseline-shift-download")!))
        var baselineContinue:NSButton?
        for _ in 0..<250 {
            baselineContinue=descendants(host).first{$0.identifier?.rawValue=="AlcoveWebsiteProtectionContinue" && !$0.isHiddenOrHasHiddenAncestor} as? NSButton
            if baselineContinue != nil {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        guard let baselineContinue else {throw Failure.fixture}
        baselineContinue.performClick(nil);try await ready(web,host:"listed.alcove.example")
        let downloadCoordinates=try await web.evaluateJavaScript("""
            window.ownedOriginalDocument=true;document.getElementById('token').value='typed-owned';
            const downloadLink=document.createElement('a');downloadLink.href='http://listed.alcove.example/target?case=browser-shift-download';
            downloadLink.download='owned-page.html';downloadLink.textContent='Owned download';downloadLink.style.display='block';document.body.appendChild(downloadLink);
            downloadLink.addEventListener('click',event=>{window.ownedDownloadClick=event.shiftKey&&event.isTrusted;});
            const downloadRect=downloadLink.getBoundingClientRect();[downloadRect.x+downloadRect.width/2,downloadRect.y+downloadRect.height/2];
            """) as? [Double]
        guard let downloadCoordinates,downloadCoordinates.count==2 else {throw Failure.fixture}
        let downloadPoint=web.convert(NSPoint(x:downloadCoordinates[0],y:web.isFlipped ? downloadCoordinates[1]:web.bounds.height-downloadCoordinates[1]),to:nil)
        window.makeFirstResponder(web)
        for type:NSEvent.EventType in [.leftMouseDown,.leftMouseUp] {
            guard let event=NSEvent.mouseEvent(with:type,location:downloadPoint,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:type == .leftMouseDown ? 1:0) else {throw Failure.fixture}
            window.sendEvent(event)
        }
        for _ in 0..<250 {
            if store.websiteProtectionTicket(for:web) != nil || store.primaryPeekView != nil {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let downloadClick=(try? await web.evaluateJavaScript("window.ownedDownloadClick===true")) as? Bool==true
        check(downloadClick,"A real native shift-download reaches the owned page")
        guard downloadClick else {throw Failure.fixture}
        let downloadTicket=store.websiteProtectionTicket(for:web)
        var downloadKind=false
        if let downloadTicket,case .download=downloadTicket.kind {downloadKind=true}
        check(downloadKind,"A native shift-download is captured as a download")
        var downloadContinue:NSButton?
        for _ in 0..<250 {
            downloadContinue=descendants(host).first{$0.identifier?.rawValue=="AlcoveWebsiteProtectionContinue" && !$0.isHiddenOrHasHiddenAncestor} as? NSButton
            if downloadContinue != nil || store.primaryPeekView != nil {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        downloadContinue?.performClick(nil)
        var downloadOffered=false
        for _ in 0..<750 {
            if let panel=NSApp.windows.first(where:{$0 is NSSavePanel && $0.isVisible}) as? NSSavePanel {downloadOffered=true;panel.cancel(nil);break}
            if store.primaryPeekView != nil {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        check(downloadOffered,"A shift-download continues to the original native destination chooser")
        check(store.primaryPeekView==nil,"A shift-download never becomes a Peek page")
        check(try await targetRequests("browser-shift-download").count==1,"A shift-download sends exactly its captured native request")
        store.closePrimaryPeek()
        check((try? await web.evaluateJavaScript("window.ownedOriginalDocument===true&&document.getElementById('token')?.value==='typed-owned'")) as? Bool==true,"A shift-download preserves its original page and typed form")
        check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("metadata").path),"Private warning browsing saves no metadata directory")
        print("BROWSER_WEBSITE_PROTECTION_CHECKS",checks,"FAILURES",failures)
        if failures>0 {throw Failure.checks(failures)}
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        atexit {
            if !WebsiteProtectionNavigationChecks.returnedFromRun {
                fputs("BROWSER_WEBSITE_PROTECTION_PREMATURE_EXIT\n",stderr)
                fputs(Thread.callStackSymbols.joined(separator:"\n")+"\n",stderr)
                _exit(86)
            }
        }
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do {try await run();returnedFromRun=true;exit(0)}
            catch {returnedFromRun=true;print("BROWSER_WEBSITE_PROTECTION_FAILED",error);exit(1)}
        }
        NSApp.run()
    }
}
