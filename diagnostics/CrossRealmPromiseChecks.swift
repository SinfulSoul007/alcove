import AppKit
import WebKit
import JavaScriptCore
import Darwin

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
        let page=WKWebView(frame:NSRect(x:0,y:0,width:780,height:550),configuration:config)
        let window=NSWindow(contentRect:page.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="Alcove owned cross-realm promise checks";window.contentView=page
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer {page.stopLoading();window.contentView=nil;window.close()}
        let regressionOnly=CommandLine.arguments.contains("--review-regressions-only")
        let modes=regressionOnly ? ["empty-value","empty-error","finally-child-fast"]:
            ["same","sync","then","await","all","reject","settled","bound","proxy","finally-child-fast","finally-parent-fast","finally-child-generic","finally-parent-generic","revoked","revoked-settled","detached","empty-value","empty-error"]
        var failures=0
        for mode in modes {
            var parts=URLComponents(url:base.appendingPathComponent("options.html"),resolvingAgainstBaseURL:false)!
            parts.queryItems=[URLQueryItem(name:"mode",value:mode)]
            page.load(URLRequest(url:parts.url!))
            let stateCheck:String?
            let completionCheck:String?
            if mode=="detached" {
                completionCheck="window.ownedDetachedFinished===true"
                stateCheck="window.ownedDetachedFinished===true&&window.ownedDetachedRan!==true"
            } else if mode.hasPrefix("empty-") {
                completionCheck="window.ownedPassThroughFinished===true"
                stateCheck="window.ownedPassThroughParentPromise===true&&window.ownedPassThroughObserved==='owned'"
            } else if mode.hasPrefix("revoked") {
                let check="window.ownedRegistrationReturned===true&&window.ownedRejection==='TypeError'&&window.ownedSyncError!==true"
                completionCheck=check;stateCheck=check
            } else {completionCheck=nil;stateCheck=nil}
            let deadline=ContinuousClock.now + .seconds(12)
            while ContinuousClock.now<deadline {
                if let completionCheck {
                    if (try? await page.evaluateJavaScript(completionCheck)) as? Bool==true {break}
                } else if page.url?.fragment==mode,!page.isLoading {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            let expected=mode=="sync" || mode.hasPrefix("finally-child-") ? "/background.html":"/options.html"
            let good:Bool
            if let stateCheck {
                let state=(try? await page.evaluateJavaScript(stateCheck)) as? Bool==true
                good=page.url?.path==expected && state
            } else {good=page.url?.path==expected && page.url?.fragment==mode}
            print(good ? "PASS:":"FAIL:",mode,"expected",expected,"actual",page.url?.absoluteString ?? "nil")
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
