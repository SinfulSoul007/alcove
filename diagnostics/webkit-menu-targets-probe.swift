import AppKit
import WebKit

@available(macOS 15.4,*)
@MainActor final class MenuProbeTab:NSObject,WKWebExtensionTab {
    let page:WKWebView
    weak var owner:MenuProbeWindow?
    init(_ page:WKWebView) {self.page=page}
    func webView(for context:WKWebExtensionContext) -> WKWebView? {page}
    func url(for context:WKWebExtensionContext) -> URL? {page.url}
    func window(for context:WKWebExtensionContext) -> (any WKWebExtensionWindow)? {owner}
    func isSelected(for context:WKWebExtensionContext) -> Bool {true}
}
@available(macOS 15.4,*)
@MainActor final class MenuProbeWindow:NSObject,WKWebExtensionWindow {
    let tab:MenuProbeTab
    init(_ tab:MenuProbeTab) {self.tab=tab;super.init();tab.owner=self}
    func tabs(for context:WKWebExtensionContext) -> [any WKWebExtensionTab] {[tab]}
    func activeTab(for context:WKWebExtensionContext) -> (any WKWebExtensionTab)? {tab}
}
@available(macOS 15.4,*)
@MainActor final class MenuProbeDelegate:NSObject,WKWebExtensionControllerDelegate {
    let window:MenuProbeWindow
    init(_ window:MenuProbeWindow) {self.window=window}
    func webExtensionController(_ controller:WKWebExtensionController,openWindowsFor context:WKWebExtensionContext) -> [any WKWebExtensionWindow] {[window]}
}
@MainActor final class NativeMenuCapture:NSObject {
    var waiting=false
    var menu:NSMenu?
    var finished=false
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(started),name:NSMenu.didBeginTrackingNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(ended),name:NSMenu.didEndTrackingNotification,object:nil)
    }
    deinit {NotificationCenter.default.removeObserver(self)}
    @objc func started(_ notification:Notification) {
        guard waiting,let menu=notification.object as? NSMenu else {return}
        self.menu=menu;waiting=false
        print("MENU_TRACKING_BEGIN",menu.items.count)
        DispatchQueue.main.async {menu.cancelTrackingWithoutAnimation()}
    }
    @objc func ended(_ notification:Notification) {
        guard let ended=notification.object as? NSMenu,ended===menu else {return}
        finished=true;print("MENU_TRACKING_END")
    }
    func find(_ title:String,in menu:NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title==title {return item}
            if let found=find(title,in:item.submenu) {return found}
        }
        return nil
    }
    func inspect(_ page:WKWebView,in window:NSWindow) async throws -> NSMenu {
        menu=nil;finished=false;waiting=true;defer {waiting=false}
        guard let rect=try await page.evaluateJavaScript("(()=>{const r=document.getElementById('target').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}})()") as? [String:Double],
              let x=rect["x"],let y=rect["y"] else {throw URLError(.cannotParseResponse)}
        let point=NSPoint(x:x,y:page.isFlipped ? y:page.bounds.height-y)
        guard let event=NSEvent.mouseEvent(with:.rightMouseDown,location:page.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) else {throw URLError(.unknown)}
        page.rightMouseDown(with:event)
        if let release=NSEvent.mouseEvent(with:.rightMouseUp,location:page.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0) {page.rightMouseUp(with:release)}
        let deadline=ContinuousClock.now + .seconds(4)
        while !finished,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
        guard finished,let menu else {throw URLError(.timedOut)}
        return menu
    }
}
@main struct MenuTargetProbe {
    @MainActor static func ready(_ page:WKWebView,_ url:URL) async throws {
        let deadline=ContinuousClock.now + .seconds(10)
        while ContinuousClock.now<deadline {
            if page.url==url,!page.isLoading,(try? await page.evaluateJavaScript("document.readyState==='complete'")) as? Bool==true {return}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw URLError(.timedOut)
    }
    @MainActor static func linkedImage(_ page:WKWebView,link:String,source:String) async throws {
        _ = try await page.callAsyncJavaScript("document.body.innerHTML='<a><img id=target width=160 height=80></a>';document.querySelector('a').href=link;document.getElementById('target').src=source;",arguments:["link":link,"source":source],in:nil,contentWorld:.page)
        for _ in 0..<100 {
            if (try await page.evaluateJavaScript("document.getElementById('target').complete && document.getElementById('target').naturalWidth>0")) as? Bool==true {return}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw URLError(.cannotDecodeContentData)
    }
    @MainActor static func create(_ options:WKWebView,_ properties:[String:Any]) async throws -> Bool {
        let result=try await options.callAsyncJavaScript("""
            return await Promise.race([
                new Promise(resolve=>{try{browser.contextMenus.create(properties,()=>resolve({ok:!browser.runtime.lastError,error:browser.runtime.lastError?.message??null}));}catch(e){resolve({ok:false,error:String(e)});}}),
                new Promise(resolve=>setTimeout(()=>resolve({ok:false,error:'timed out'}),2000))
            ]);
            """,arguments:["properties":properties],in:nil,contentWorld:.page) as? [String:Any]
        print("MENU_CREATE",properties["id"] ?? "missing",result ?? [:])
        guard let result,let ok=result["ok"] as? Bool else {throw URLError(.cannotParseResponse)}
        if ok {
            guard result["error"]==nil || result["error"] is NSNull else {throw URLError(.cannotParseResponse)}
            return true
        }
        guard let error=result["error"] as? String,
              error.contains("Invalid call to menus.create()."),error.contains("not a valid pattern") else {throw URLError(.cannotParseResponse)}
        for property in ["targetUrlPatterns","documentUrlPatterns"] {
            if error.contains("'"+property+"'"),let patterns=properties[property] as? [String],
               patterns.contains(where:{error.contains("'"+$0+"' is not a valid pattern")}) {return false}
        }
        throw URLError(.cannotParseResponse)
    }
    @MainActor static func main() async {
        do {let status=try await run();exit(status)}
        catch {print("MENU_PROBE_ERROR",String(describing:error));exit(1)}
    }
    @MainActor static func run() async throws -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory);setbuf(stdout,nil)
        guard #available(macOS 15.4,*),let raw=ProcessInfo.processInfo.environment["ALCOVE_MENU_FIXTURE_URL"],let address=URL(string:raw) else {throw URLError(.badURL)}
        let framework=Bundle(for:WKWebView.self).bundleURL.resolvingSymlinksInPath().path
        print("MENU_ACTUAL_WEBKIT_FRAMEWORK",framework)
        if let root=ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] {
            let expected=URL(fileURLWithPath:root).resolvingSymlinksInPath().path
            guard framework.hasPrefix(expected+"/") else {throw URLError(.cannotLoadFromNetwork)}
        }
        var failures=0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS":"FAIL"): \(name)");if !value {failures+=1}}
        let manager=FileManager.default,root=manager.temporaryDirectory.appendingPathComponent("alcove-menu-target-"+UUID().uuidString)
        try manager.createDirectory(at:root,withIntermediateDirectories:true);defer {try? manager.removeItem(at:root)}
        try Data(#"{"manifest_version":3,"name":"Owned opaque menus","version":"1","permissions":["contextMenus","storage"],"options_page":"options.html"}"#.utf8).write(to:root.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Owned opaque menu options</title>".utf8).write(to:root.appendingPathComponent("options.html"))
        let plugin=try await WKWebExtension(resourceBaseURL:root),context=WKWebExtensionContext(for:plugin)
        context.grantedPermissions=[WKWebExtension.Permission(rawValue:"contextMenus"):.distantFuture,WKWebExtension.Permission(rawValue:"storage"):.distantFuture]
        context.grantedPermissionMatchPatterns=[try WKWebExtension.MatchPattern(string:"http://127.0.0.1/*"):.distantFuture]
        let permissions=context.grantedPermissions,hosts=context.grantedPermissionMatchPatterns
        let configuration=WKWebExtensionController.Configuration.nonPersistent();configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller=WKWebExtensionController(configuration:configuration)
        try controller.load(context);defer {try? controller.unload(context)}
        guard let optionsConfiguration=context.webViewConfiguration,let optionsURL=context.optionsPageURL else {throw URLError(.unsupportedURL)}
        let options=WKWebView(frame:NSRect(x:0,y:0,width:600,height:400),configuration:optionsConfiguration)
        options.load(URLRequest(url:optionsURL));try await ready(options,optionsURL)
        _ = try await options.evaluateJavaScript("browser.contextMenus.onClicked.addListener(info=>browser.storage.local.set({ownedClick:{id:info.menuItemId,link:info.linkUrl}}));")
        let pageConfiguration=WKWebViewConfiguration();pageConfiguration.websiteDataStore=configuration.defaultWebsiteDataStore!;pageConfiguration.webExtensionController=controller
        let page=WKWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:pageConfiguration)
        let native=NSWindow(contentRect:page.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        native.isReleasedWhenClosed=false;native.contentView=page;defer {native.contentView=nil;native.close()}
        let tab=MenuProbeTab(page),window=MenuProbeWindow(tab),delegate=MenuProbeDelegate(window)
        controller.delegate=delegate;controller.didOpenWindow(window);controller.didFocusWindow(window);controller.didOpenTab(tab)
        defer {controller.didCloseTab(tab,windowIsClosing:true);controller.didCloseWindow(window);controller.delegate=nil;withExtendedLifetime(delegate){}}
        native.makeKeyAndOrderFront(nil);NSApp.activate()
        page.load(URLRequest(url:address));try await ready(page,address)
        _ = try await page.evaluateJavaScript("document.body.innerHTML='<a id=target style=\"display:block;padding:50px\" href=\"https://subscribe.adblockplus.org/control\">Owned menu target</a>';")
        do {
            _ = try await create(page,["id":"wrong-context","title":"Wrong context","targetUrlPatterns":["abp:"]])
            check(false,"A missing extension namespace cannot count as a rejected pattern")
        } catch {check(true,"A missing extension namespace cannot count as a rejected pattern")}
        let control=try await create(options,["id":"control","title":"Owned HTTPS control","contexts":["link"],"targetUrlPatterns":["https://subscribe.adblockplus.org/*"]])
        check(control,"An existing structured target creates through the real extension API")
        let capture=NativeMenuCapture()
        do {
            let menu=try await capture.inspect(page,in:native)
            check(capture.find("Owned HTTPS control",in:menu) != nil,"An actual right-click menu exposes the matching structured control")
        } catch {check(false,"Actual structured native menu inspection failed: \(error)")}
        let linked=try await create(options,["id":"linked","title":"Owned linked image","contexts":["link","image"],"targetUrlPatterns":["https://subscribe.adblockplus.org/*"]])
        check(linked,"A linked-media item with an existing structured target creates")
        let imageSource="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='160'%20height='80'%3E%3Crect%20width='160'%20height='80'%20fill='red'/%3E%3C/svg%3E"
        try await linkedImage(page,link:"https://subscribe.adblockplus.org/control",source:imageSource)
        let linkedMenu=try await capture.inspect(page,in:native)
        check(capture.find("Owned linked image",in:linkedMenu) != nil,"A linked image matches when either requested target context matches")
        _ = try await page.evaluateJavaScript("document.body.innerHTML='<a id=target style=\"display:block;padding:50px\" href=\"https://subscribe.adblockplus.org/control\">Owned menu target</a>';")
        let mixed=try await create(options,["id":"subscribe","title":"Owned Subscribe","contexts":["link"],"targetUrlPatterns":["abp:*","https://subscribe.adblockplus.org/*"]])
        check(mixed,"The exact unmodified uBO mixed target array creates natively")
        let slash=try await create(options,["id":"slash","title":"Owned slash path","contexts":["link"],"targetUrlPatterns":["abp:/folder/*"]])
        check(slash,"Chrome nonstandard scheme patterns permit a single-slash path")
        for (id,properties) in [
            ("empty",["targetUrlPatterns":["abp:"]]),("bad-http",["targetUrlPatterns":["http:bad"]]),
            ("wild-scheme",["targetUrlPatterns":["*:anything"]]),("hierarchy",["targetUrlPatterns":["abp://*/*"]]),
            ("nested-separator",["targetUrlPatterns":["abp:subscribe?location=https://lists.example/*"]]),
            ("special-websocket",["targetUrlPatterns":["ws:opaque"]]),
            ("extension-origin",["targetUrlPatterns":["webkit-extension:owned"]]),
            ("opaque-document",["documentUrlPatterns":["abp:*"]]),
        ] {
            var properties:[String:Any]=properties;properties["id"]=id;properties["title"]=id;properties["contexts"]=["link"]
            check(try await !create(options,properties),"Malformed or non-target opaque pattern remains rejected: \(id)")
        }
        if mixed {
            let structuredMenu=try await capture.inspect(page,in:native)
            check(capture.find("Owned Subscribe",in:structuredMenu) != nil && capture.find("Owned HTTPS control",in:structuredMenu) != nil,"The exact mixed array also matches its structured HTTPS target")
            let target="abp:subscribe?location=https%3A%2F%2Fexample.invalid%2Flist.txt#fragment"
            _ = try await page.callAsyncJavaScript("document.getElementById('target').href=target;",arguments:["target":target],in:nil,contentWorld:.page)
            let menu=try await capture.inspect(page,in:native),item=capture.find("Owned Subscribe",in:menu)
            check(item != nil && capture.find("Owned HTTPS control",in:menu)==nil,"An actual opaque-link menu matches only its native target category")
            if let item,let action=item.action {check(NSApp.sendAction(action,to:item.target,from:item),"The actual native opaque menu action dispatches")}
            var click:[String:Any]?
            for _ in 0..<100 {
                click=try await options.callAsyncJavaScript("return (await browser.storage.local.get('ownedClick')).ownedClick??null;",arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
                if click != nil {break};try await Task.sleep(for:.milliseconds(20))
            }
            check(click?["id"] as? String=="subscribe" && click?["link"] as? String==target,"The real extension receives its opaque menu ID and original link URL")
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('subscribe',{contexts:['link','image']});",arguments:[:],in:nil,contentWorld:.page)
            let media=try await create(options,["id":"opaque-media","title":"Owned opaque media","contexts":["link","image"],"targetUrlPatterns":["data:*"]])
            check(media,"An opaque media target creates through the native menu API")
            try await linkedImage(page,link:target,source:imageSource)
            let opaqueLinked=try await capture.inspect(page,in:native)
            check(capture.find("Owned Subscribe",in:opaqueLinked) != nil,"An opaque link target matches on an image with an unrelated source")
            try await linkedImage(page,link:"https://unrelated.invalid/list",source:imageSource)
            let opaqueSource=try await capture.inspect(page,in:native)
            check(capture.find("Owned opaque media",in:opaqueSource) != nil && capture.find("Owned Subscribe",in:opaqueSource)==nil,"A matching media target is sufficient when its enclosing link is unrelated")
            _ = try await page.evaluateJavaScript("document.body.innerHTML='<a id=target style=\"display:block;padding:50px\" href=\"https://unrelated.invalid/list\">Owned menu target</a>';")
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native))==nil,"The mixed array hides its item on an unrelated actual link")
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('subscribe',{targetUrlPatterns:['abp:subscribe?location=*']});",arguments:[:],in:nil,contentWorld:.page)
            _ = try await page.evaluateJavaScript("document.getElementById('target').href='https://subscribe.adblockplus.org/control';")
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native))==nil,"An opaque-only update clears the previous structured target set")
            _ = try await page.callAsyncJavaScript("document.getElementById('target').href=target;",arguments:["target":target],in:nil,contentWorld:.page)
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('subscribe',{targetUrlPatterns:[pattern]});",arguments:["pattern":String(target.split(separator:"#")[0])],in:nil,contentWorld:.page)
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native)) != nil,"An exact opaque path and query matches while excluding the link fragment")
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('subscribe',{targetUrlPatterns:['abp:subscribe?location=*']});",arguments:[:],in:nil,contentWorld:.page)
            _ = try await page.evaluateJavaScript("document.getElementById('target').href='abp:subscribeXlocation=example';")
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native))==nil,"A question mark in the opaque pattern is literal")
            _ = try await page.callAsyncJavaScript("document.getElementById('target').href=target;",arguments:["target":target],in:nil,contentWorld:.page)
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('subscribe',{targetUrlPatterns:['mailto:*']});",arguments:[:],in:nil,contentWorld:.page)
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native))==nil,"Updating targets removes the previous opaque pattern")
            _ = try await page.evaluateJavaScript("document.getElementById('target').href='mailto:subscriber@example.invalid';")
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native)) != nil,"Opaque target handling supports another URI scheme without registration")
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('subscribe',{targetUrlPatterns:['https://subscribe.adblockplus.org/*']});",arguments:[:],in:nil,contentWorld:.page)
            check(capture.find("Owned Subscribe",in:try await capture.inspect(page,in:native))==nil,"A structured-only update clears the entire previous opaque target set")
        }
        check(context.grantedPermissions==permissions && context.grantedPermissionMatchPatterns==hosts && !context.hasAccess(to:URL(string:"abp:subscribe?location=example")!),"Menu targets do not change grants or authorize opaque URLs")
        do {_ = try WKWebExtension.MatchPattern(string:"abp:*");check(false,"Opaque targets remain unavailable as host match patterns")} catch {check(true,"Opaque targets remain unavailable as host match patterns")}
        _ = try await options.callAsyncJavaScript("await browser.contextMenus.removeAll();",arguments:[:],in:nil,contentWorld:.page)
        try await linkedImage(page,link:"https://subscribe.adblockplus.org/control",source:imageSource)
        let removedMenu=try await capture.inspect(page,in:native)
        check(capture.find("Owned HTTPS control",in:removedMenu)==nil && capture.find("Owned Subscribe",in:removedMenu)==nil && capture.find("Owned linked image",in:removedMenu)==nil && capture.find("Owned opaque media",in:removedMenu)==nil,"Removing all menus leaves no stale actual link menu items")
        print("MENU_TARGET_FAILURES",failures)
        if failures==0 {print("NATIVE_OPAQUE_MENU_TARGETS_PROVEN true")}
        return failures==0 ? 0:1
    }
}
