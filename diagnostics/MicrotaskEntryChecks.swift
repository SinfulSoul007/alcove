import AppKit
import WebKit
import JavaScriptCore
import Darwin

@MainActor final class OwnedRealmPopupController:NSObject,WKUIDelegate {
    private var child:WKWebView?
    private weak var releasedChild:WKWebView?
    private(set) var closeCount=0
    var closedAndReleased:Bool {closeCount==1 && releasedChild==nil}
    func reset() {child?.stopLoading();child?.uiDelegate=nil;child=nil;releasedChild=nil;closeCount=0}
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures) -> WKWebView? {
        guard child==nil,action.request.url?.host=="127.0.0.1",action.request.url?.scheme=="http" else {return nil}
        let view=WKWebView(frame:NSRect(x:0,y:0,width:400,height:300),configuration:configuration)
        view.uiDelegate=self;child=view;releasedChild=view;return view
    }
    func webViewDidClose(_ webView:WKWebView) {
        guard child === webView else {return}
        closeCount+=1;webView.uiDelegate=nil;webView.stopLoading();child=nil
    }
}

@main struct CrossRealmPromiseChecks {
    enum Failure:Error {case prerequisite,checks(Int)}
    nonisolated(unsafe) static var completed=false
    @MainActor static func run() async throws {
        guard let raw=ProcessInfo.processInfo.environment["ALCOVE_REALM_LOOPBACK"],let base=URL(string:raw),base.host=="127.0.0.1",base.scheme=="http" else {throw Failure.prerequisite}
        let framework=Bundle(for:WKWebView.self).bundleURL.resolvingSymlinksInPath().path
        let javascriptCore=Bundle(for:JSContext.self).bundleURL.resolvingSymlinksInPath().path
        print("CROSS_REALM_FRAMEWORK",framework,"JAVASCRIPTCORE",javascriptCore)
        if let expected=ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] {
            guard framework.hasPrefix(expected+"/"),javascriptCore.hasPrefix(expected+"/") else {throw Failure.prerequisite}
        } else {guard ProcessInfo.processInfo.environment["ALCOVE_SYSTEM_WEBKIT_CONTROL"]=="1",framework.hasPrefix("/System/"),javascriptCore.hasPrefix("/System/") else {throw Failure.prerequisite}}
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically=true
        let page=WKWebView(frame:NSRect(x:0,y:0,width:780,height:550),configuration:config)
        let popups=OwnedRealmPopupController();page.uiDelegate=popups
        let window=NSWindow(contentRect:page.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="Alcove owned cross-realm promise checks";window.contentView=page
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer {popups.reset();page.uiDelegate=nil;page.stopLoading();window.contentView=nil;window.close()}
        let regressionOnly=CommandLine.arguments.contains("--review-regressions-only")
        let detachedOnly=CommandLine.arguments.contains("--diagnostic-detached-only")
        let modes=detachedOnly ? ["detached"]:regressionOnly ? ["closed-value","closed-error","finally-child-fast"]:
            ["same","sync","then","await","all","reject","settled","bound","proxy","finally-child-fast","finally-parent-fast","finally-child-generic","finally-parent-generic","revoked","revoked-settled","detached","empty-value","empty-error","closed-value","closed-error","thenable-parent","thenable-child","broadcast-await","broadcast-then","await-thenable-parent","await-thenable-child"]
        var failures=0
        for mode in modes {
            popups.reset()
            var parts=URLComponents(url:base.appendingPathComponent("options.html"),resolvingAgainstBaseURL:false)!
            parts.queryItems=[URLQueryItem(name:"mode",value:mode)]
            page.load(URLRequest(url:parts.url!))
            let stateCheck:String?
            let completionCheck:String?
            if mode=="detached" {
                completionCheck="window.ownedDetachedFinished===true"
                stateCheck="window.ownedDetachedFinished===true&&window.ownedDetachedRan===true&&window.ownedDetachedError===undefined&&document.querySelector('iframe')===null&&location.hash===''"
            } else if mode.hasPrefix("empty-") || mode.hasPrefix("closed-") {
                completionCheck="window.ownedPassThroughFinished===true"
                stateCheck="window.ownedPassThroughParentPromise===true&&window.ownedPassThroughObserved==='owned'"
            } else if mode.hasPrefix("revoked") {
                let check="window.ownedRegistrationReturned===true&&window.ownedRejection==='TypeError'&&window.ownedSyncError!==true"
                completionCheck=check;stateCheck=check
            } else {completionCheck=nil;stateCheck=nil}
            let deadline=ContinuousClock.now + .seconds(12)
            while ContinuousClock.now<deadline {
                if let completionCheck {
                    if (try? await page.evaluateJavaScript(completionCheck)) as? Bool==true,
                       !mode.hasPrefix("closed-") || popups.closedAndReleased {break}
                } else if page.url?.fragment==mode,!page.isLoading {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            let expected=mode=="sync" || (mode=="thenable-child" || mode=="await-thenable-child") || mode.hasPrefix("finally-child-") ? "/background.html":"/options.html"
            let good:Bool
            if let stateCheck {
                let state=(try? await page.evaluateJavaScript(stateCheck)) as? Bool==true
                good=page.url?.path==expected && state && (!mode.hasPrefix("closed-") || popups.closedAndReleased)
            } else {good=page.url?.path==expected && page.url?.fragment==mode}
            print(good ? "PASS:":"FAIL:",mode,"expected",expected,"actual",page.url?.absoluteString ?? "nil")
            if mode=="detached" {
                let detail=try? await page.evaluateJavaScript("JSON.stringify({finished:window.ownedDetachedFinished===true,ran:window.ownedDetachedRan===true,error:window.ownedDetachedError??null,iframePresent:document.querySelector('iframe')!==null})")
                print("DETACHED_PAGE_STATE",detail as? String ?? "unavailable")
            }
            if mode.hasPrefix("closed-") {
                let detail=try? await page.evaluateJavaScript("JSON.stringify({finished:window.ownedPassThroughFinished===true,observed:window.ownedPassThroughObserved??null,parentPromise:window.ownedPassThroughParentPromise===true})")
                print("CLOSED_PAGE_STATE",mode,popups.closeCount,popups.closedAndReleased,detail as? String ?? "unavailable")
            }
            if !good {failures+=1}
        }
        print("CROSS_REALM_PROMISE_CHECKS",modes.count,"FAILURES",failures)
        if failures>0 {throw Failure.checks(failures)}
    }
    @MainActor static func main() {
        setbuf(stdout,nil);atexit{if !CrossRealmPromiseChecks.completed {_exit(86)}}
        NSApplication.shared.setActivationPolicy(.regular)
        Task{@MainActor in
            do {try await run();completed=true;exit(0)}
            catch {completed=true;print("CROSS_REALM_FAILED",error);exit(1)}
        }
        NSApp.run()
    }
}
