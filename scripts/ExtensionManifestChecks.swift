import Foundation
import BrowserCore

func runExtensionManifestChecks(_ check:(Bool,String)->Void) throws {
    func data(_ object:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:object) }
    let minimal:[String:Any] = ["manifest_version":3,"name":"Owned Fixture","version":"1.2.3"]
    func rejects(_ object:[String:Any]) -> Bool { do { _ = try ExtensionManifest.parse(data(object)); return false } catch { return true } }
    var complete = minimal
    complete["permissions"] = ["storage","activeTab"]; complete["optional_permissions"] = ["tabs"]
    complete["host_permissions"] = ["https://example.com/*"]; complete["optional_host_permissions"] = ["https://*.example.org/*"]
    complete["action"] = ["default_popup":"popup.html","default_icon":["16":"icons/16.png"]]
    complete["options_ui"] = ["page":"options.html","open_in_tab":true]
    complete["background"] = ["service_worker":"worker.js","type":"module"]
    complete["content_scripts"] = [["matches":["https://content.example/*"],"js":["content.js"],"css":["content.css"]]]
    let parsed = try ExtensionManifest.parse(data(complete))
    check(parsed.name == "Owned Fixture" && parsed.version == "1.2.3" && parsed.manifestVersion == 3,"MV3 manifest exposes its actual display identity")
    check(Set(parsed.requestedPermissions) == ["storage","activeTab"] && parsed.optionalPermissions == ["tabs"],"Required and optional APIs stay distinct for review")
    check(Set(parsed.hostPermissions) == ["https://example.com/*","https://content.example/*"] && parsed.optionalHostPermissions == ["https://*.example.org/*"],"Static content-script sites participate in permission review")
    check(parsed.actionPopup == "popup.html" && parsed.optionsPage == "options.html" && Set(parsed.resourcePaths) == ["popup.html","icons/16.png","options.html","worker.js","content.js","content.css"],"Manifest entry points retain their package-relative resource references")
    var legacy = minimal; legacy["manifest_version"] = 2
    legacy["permissions"] = ["storage","https://legacy.example/*"]; legacy["optional_permissions"] = ["https://optional.example/*","tabs"]
    legacy["background"] = ["scripts":["one.js","two.js"],"persistent":false]; legacy["page_action"] = ["default_popup":"legacy.html"]
    let mv2 = try ExtensionManifest.parse(data(legacy))
    check(mv2.manifestVersion == 2 && mv2.requestedPermissions == ["storage"] && mv2.hostPermissions == ["https://legacy.example/*"] && mv2.optionalPermissions == ["tabs"] && mv2.optionalHostPermissions == ["https://optional.example/*"],"MV2 host strings are classified as sites rather than API names")
    check(mv2.actionPopup == "legacy.html" && Set(mv2.resourcePaths) == ["one.js","two.js","legacy.html"],"MV2 background scripts and page actions are inspected without execution")
    var localized = minimal; localized["name"] = "__MSG_ext_name__"; localized["description"] = "A __MSG_detail__"; localized["default_locale"] = "en_US"
    let messages = try data(["ext_name":["message":"Owned Localized"],"detail":["message":"local test"]])
    let local = try ExtensionManifest.parse(data(localized),readResource:{ path in path == "_locales/en_US/messages.json" ? messages : nil })
    check(local.name == "Owned Localized" && local.summary == "A local test" && local.resourcePaths.contains("_locales/en_US/messages.json"),"Default-locale manifest messages resolve through a bounded package resource")
    var missingLocale = localized; missingLocale.removeValue(forKey:"default_locale")
    check(rejects(missingLocale),"Localized identity without a default locale is rejected")
    check(rejects(localized),"Missing locale messages cannot masquerade as a resolved identity")
    var unsafeLocale = localized; unsafeLocale["default_locale"] = "../en"
    check(rejects(unsafeLocale),"A locale name cannot escape its package directory")
    var privateOff = minimal; privateOff["incognito"] = "not_allowed"
    check(try ExtensionManifest.parse(data(privateOff)).incognito == "not_allowed","An extension's private-browsing prohibition survives inspection")
    var unsupported = minimal; unsupported["permissions"] = ["nativeMessaging"]; unsupported["devtools_page"] = "tools.html"; unsupported["host_permissions"] = ["file:///*"]
    let limits = try ExtensionManifest.parse(data(unsupported))
    check(limits.requestedPermissions == ["nativeMessaging"] && limits.hostPermissions == ["file:///*"] && !limits.warnings.isEmpty,"Unsupported privileged capabilities remain visible without an approval")
    for (key,value,title) in [
        ("manifest_version",true,"A Boolean is not a manifest version"),
        ("manifest_version",4,"An unknown manifest version is rejected"),
        ("permissions",[1],"Permission arrays must contain strings"),
        ("action","popup.html","An action must be an object"),
        ("content_scripts",[["matches":["https://example.com/*"],"js":["../escape.js"]]],"Content-script resource traversal is rejected"),
        ("icons",["16":"/tmp/icon.png"],"Absolute icon paths are rejected"),
        ("background",["service_worker":"https://example.com/code.js"],"Background code must be inside the package"),
        ("options_page","a%2f..%2fescape.html","Encoded path separators cannot escape the package"),
        ("version","01.2","Ambiguous leading-zero extension versions are rejected"),
        ("version","65536","Overflowing extension versions are rejected"),
        ("version","0.0","An all-zero extension version is rejected"),
        ("incognito","sometimes","Unknown private-browsing declarations are rejected")
    ] as [(String,Any,String)] {
        var invalid = minimal; invalid[key] = value; check(rejects(invalid),title)
    }
    for raw in [
        #"{"manifest_version":3,"name":"Owned","version":"1","permissions":["storage"],"permissions":["cookies"]}"#,
        #"{"manifest_version":3,"name":"Owned","version":"1","action":{"default_popup":"a.html","default_popup":"b.html"}}"#,
        #"{"manifest_version":3,"name":"Owned","version":"1","permi\u0073sions":[],"permissions":["tabs"]}"#
    ] {
        var rejected = false; do { _ = try ExtensionManifest.parse(Data(raw.utf8)) } catch { rejected = true }
        check(rejected,"Duplicate JSON keys cannot give the reviewer and engine different declarations")
    }
    var ruleManifest = minimal
    ruleManifest["declarative_net_request"] = ["rule_resources":[["id":"owned","enabled":true,"path":"rules.json"]]]
    check(try ExtensionManifest.parse(data(ruleManifest)).resourcePaths.contains("rules.json"),"Declarative rule files are included in entry-resource validation")
    var unsafeRules = minimal
    unsafeRules["declarative_net_request"] = ["rule_resources":[["id":"owned","enabled":true,"path":"../outside.json"]]]
    check(rejects(unsafeRules),"Declarative rule paths cannot escape the package")
    var unsafeExposure = minimal
    unsafeExposure["web_accessible_resources"] = [["resources":["../outside"],"matches":["https://example.com/*"]]]
    check(rejects(unsafeExposure),"Public resource patterns cannot expose an outside directory")
    var sandbox = minimal; sandbox["sandbox"] = ["pages":["sandbox.html"]]
    check(try ExtensionManifest.parse(data(sandbox)).resourcePaths.contains("sandbox.html"),"Sandboxed document paths are included in entry-resource validation")
    sandbox["sandbox"] = ["pages":["../outside.html"]]
    check(rejects(sandbox),"Sandboxed document declarations cannot read outside resources")
    var oversized = minimal; oversized["description"] = String(repeating:"x",count:1_048_577)
    check(rejects(oversized),"Manifest byte limits apply before decoding")
}
