import AppKit
import WebKit

@main struct RuntimeErrorProbe {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard #available(macOS 15.4,*) else {throw CocoaError(.featureUnsupported)}
        guard let raw=ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"] else {throw CocoaError(.featureUnsupported)}
        let expected=URL(fileURLWithPath:raw).resolvingSymlinksInPath().path
        let actual=Bundle(for:WKWebView.self).bundleURL.resolvingSymlinksInPath().path
        guard actual.hasPrefix(expected+"/") else {throw CocoaError(.featureUnsupported)}
        print("RUNTIME_ERROR_FRAMEWORK",actual)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("alcove-runtime-error-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data(#"{"manifest_version":2,"name":"Owned runtime errors","version":"1.0","permissions":["webRequest"],"options_page":"options.html"}"#.utf8).write(to:root.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Owned runtime errors</title>".utf8).write(to:root.appendingPathComponent("options.html"))
        let config=WKWebExtensionController.Configuration.nonPersistent()
        config.defaultWebsiteDataStore = .nonPersistent()
        let controller=WKWebExtensionController(configuration:config)
        let plugin=try await WKWebExtension(resourceBaseURL:root),context=WKWebExtensionContext(for:plugin)
        context.grantedPermissions=[WKWebExtension.Permission(rawValue:"webRequest"):.distantFuture]
        context.hasAccessToPrivateData=true // Only this owned ephemeral fixture.
        try controller.load(context)
        defer {try? controller.unload(context)}
        guard let configuration=context.webViewConfiguration,let address=context.optionsPageURL else {throw CocoaError(.featureUnsupported)}
        let page=WKWebView(frame:.zero,configuration:configuration)
        page.load(URLRequest(url:address))
        var ready=false
        for _ in 0..<300 {
            if page.url==address,!page.isLoading,(try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" {ready=true;break}
            try await Task.sleep(for:.milliseconds(20))
        }
        guard ready else {throw URLError(.timedOut)}
        var checks=0,failures=0
        func check(_ value:Bool,_ label:String) {checks+=1;print("\(value ? "PASS":"FAIL"): \(label)");if !value {failures+=1}}
        let baseline=try await page.evaluateJavaScript("({browser:browser.runtime.lastError===undefined,chrome:chrome.runtime.lastError===undefined,kind:typeof chrome.runtime.lastError,isNull:chrome.runtime.lastError===null})") as? [String:Any] ?? [:]
        print("RUNTIME_ERROR_BASELINE",baseline)
        check(baseline["browser"] as? Bool == true,"Browser namespace has no error outside a callback")
        check(baseline["chrome"] as? Bool == true,"Chrome namespace has no error outside a callback")
        let success=try await page.callAsyncJavaScript("""
            return await new Promise(resolve=>chrome.webRequest.handlerBehaviorChanged(function(){
                resolve({count:arguments.length,absent:chrome.runtime.lastError===undefined});
            }));
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any] ?? [:]
        check(success["count"] as? Int == 0,"The genuine successful callback receives no arguments")
        check(success["absent"] as? Bool == true,"The genuine successful callback has no runtime error")
        _=try await page.callAsyncJavaScript("for(let i=0;i<19;i++)await browser.webRequest.handlerBehaviorChanged();return true;",arguments:[:],in:nil,contentWorld:.page)
        let failure=try await page.callAsyncJavaScript("""
            return await new Promise(resolve=>chrome.webRequest.handlerBehaviorChanged(function(){
                const error=chrome.runtime.lastError;
                resolve({count:arguments.length,real:typeof error==='object'&&error!==null,
                    message:typeof error?.message==='string'&&error.message.toLowerCase().includes('too many')});
            }));
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any] ?? [:]
        print("RUNTIME_ERROR_CALLBACK",failure)
        check(failure["count"] as? Int == 0,"A genuine quota-error callback keeps its void callback shape")
        check(failure["real"] as? Bool == true && failure["message"] as? Bool == true,"A genuine API failure exposes its actual error message during the callback")
        check(try await page.evaluateJavaScript("chrome.runtime.lastError===undefined&&browser.runtime.lastError===undefined") as? Bool == true,"Callback error state is absent after the native callback returns")
        let promise=try await page.callAsyncJavaScript("""
            try {await browser.webRequest.handlerBehaviorChanged();return {rejected:false};}
            catch(error){return {rejected:typeof error?.message==='string'&&error.message.toLowerCase().includes('too many'),absent:browser.runtime.lastError===undefined};}
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any] ?? [:]
        check(promise["rejected"] as? Bool == true,"Promise-style API failure still rejects with its genuine error")
        check(promise["absent"] as? Bool == true,"Promise rejection does not publish callback error state")
        print("RUNTIME_ERROR_CHECKS",checks,"FAILURES",failures)
        if failures==0 {print("NATIVE_RUNTIME_ERROR_PROVEN true")}
        exit(failures==0 ? 0:1)
    }
}
