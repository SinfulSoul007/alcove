import AppKit
import WebKit

@main struct PrivacyPageConstructionProbe {
    @MainActor static func main() async throws {
        setbuf(stdout,nil);NSApplication.shared.setActivationPolicy(.prohibited)
        guard #available(macOS 15.4,*) else {throw CocoaError(.featureUnsupported)}
        let actual = Bundle(for:WKWebView.self).bundleURL.resolvingSymlinksInPath().path
        guard let expected = ProcessInfo.processInfo.environment["ALCOVE_EXPECT_WEBKIT_ROOT"],actual.hasPrefix(expected+"/") else {throw CocoaError(.featureUnsupported)}
        print("PRIVACY_CONSTRUCTION_FRAMEWORK",actual)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-privacy-construction-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data(#"{"manifest_version":2,"name":"Owned privacy construction","version":"1.0","permissions":["privacy"],"options_page":"options.html"}"#.utf8).write(to:root.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Owned privacy construction</title>".utf8).write(to:root.appendingPathComponent("options.html"))
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration:configuration)
        let plugin = try await WKWebExtension(resourceBaseURL:root),context = WKWebExtensionContext(for:plugin)
        context.grantedPermissions = [WKWebExtension.Permission(rawValue:"privacy"):.distantFuture]
        context.hasAccessToPrivateData = true
        try controller.load(context);defer {try? controller.unload(context)}
        guard let optionsConfiguration = context.webViewConfiguration,let address = context.optionsPageURL else {throw CocoaError(.featureUnsupported)}
        let options = WKWebView(frame:.zero,configuration:optionsConfiguration)
        options.load(URLRequest(url:address))
        for _ in 0..<300 {
            if options.url == address,!options.isLoading,(try? await options.evaluateJavaScript("document.readyState")) as? String == "complete" {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let settings = try await options.callAsyncJavaScript("""
            await browser.privacy.network.networkPredictionEnabled.set({value:false});
            await browser.privacy.websites.hyperlinkAuditingEnabled.set({value:false});
            return {normal:await browser.privacy.network.networkPredictionEnabled.get({}),
                    private:await browser.privacy.network.networkPredictionEnabled.get({incognito:true})};
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        print("PRIVACY_CONSTRUCTION_EFFECTIVE",settings ?? [:])
        guard let normal = settings?["normal"] as? [String:Any],normal["value"] as? Bool == false,
              let incognito = settings?["private"] as? [String:Any],incognito["value"] as? Bool == false else {throw CocoaError(.validationMissingMandatoryProperty)}
        print("PRIVACY_NEW_PAGE_BEGIN")
        guard let freshConfiguration = context.webViewConfiguration else {throw CocoaError(.featureUnsupported)}
        let fresh = WKWebView(frame:.zero,configuration:freshConfiguration)
        print("PRIVACY_NEW_PAGE_CONSTRUCTED")
        fresh.load(URLRequest(url:address))
        for _ in 0..<300 {
            if fresh.url == address,!fresh.isLoading,(try? await fresh.evaluateJavaScript("document.readyState")) as? String == "complete" {
                print("PRIVACY_NEW_PAGE_LOADED true");return
            }
            try await Task.sleep(for:.milliseconds(20))
        }
        throw URLError(.timedOut)
    }
}
