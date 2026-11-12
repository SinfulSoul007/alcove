import Foundation
import CoreFoundation

public enum ExtensionValidationError:LocalizedError,Equatable {
    case invalidManifest(String), invalidResourcePath, packageTooLarge, invalidArchive(String), unsupportedPackage
    public var errorDescription:String? {
        switch self {
        case .invalidManifest(let detail): return "Invalid extension manifest: " + detail
        case .invalidResourcePath: return "Extension resources must use safe relative paths inside the package."
        case .packageTooLarge: return "The extension exceeds Alcove's package limits."
        case .invalidArchive(let detail): return "Invalid extension archive: " + detail
        case .unsupportedPackage: return "Choose an extension folder, ZIP or CRX3 package."
        }
    }
}

public enum ExtensionResourcePath {
    public static func normalized(_ raw:String) throws -> String {
        let path = raw.precomposedStringWithCanonicalMapping
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"), !path.contains("%"), !path.contains("?"), !path.contains("#"),
              !path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw ExtensionValidationError.invalidResourcePath }
        let parts = path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw ExtensionValidationError.invalidResourcePath }
        return path
    }
}

public struct ExtensionManifest:Equatable,Sendable {
    public let manifestVersion:Int
    public let name:String
    public let version:String
    public let versionName:String?
    public let summary:String?
    public let defaultLocale:String?
    public let requestedPermissions:[String]
    public let optionalPermissions:[String]
    public let hostPermissions:[String]
    public let optionalHostPermissions:[String]
    public let resourcePaths:[String]
    public let actionPopup:String?
    public let optionsPage:String?
    public let incognito:String
    public let warnings:[String]

    /// Inspection only. Resource code is neither evaluated nor loaded by this reader.
    public static func parse(_ data:Data,readResource:(String)throws -> Data? = {_ in nil}) throws -> Self {
        let manifest = try ExtensionJSON.object(data,limit:1_048_576)
        func invalid(_ key:String) -> ExtensionValidationError { .invalidManifest(key) }
        func string(_ value:Any?,_ key:String,required:Bool = false) throws -> String? {
            guard let value else { if required { throw invalid(key + " is required") }; return nil }
            guard let result = value as? String, result.utf8.count <= 65_536 else { throw invalid(key + " must be a bounded string") }
            return result
        }
        func object(_ value:Any?,_ key:String) throws -> [String:Any]? {
            guard let value else { return nil }; guard let result = value as? [String:Any] else { throw invalid(key + " must be an object") }; return result
        }
        func strings(_ value:Any?,_ key:String) throws -> [String] {
            guard let value else { return [] }
            guard let values = value as? [String], values.count <= 2048, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw invalid(key + " must be a bounded string array") }
            return values
        }
        func bool(_ value:Any?,_ key:String) throws {
            guard let value else { return }; guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid(key + " must be a Boolean") }
        }
        guard let number = manifest["manifest_version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), [2.0,3.0].contains(number.doubleValue) else { throw invalid("supported manifest versions are 2 and 3") }
        let manifestVersion = number.intValue
        let version = try string(manifest["version"],"version",required:true)!
        let components = version.split(separator:".",omittingEmptySubsequences:false)
        guard (1...4).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy({48...57 ~= $0}) && ($0.count == 1 || !$0.hasPrefix("0")) && UInt16($0) != nil
        }), components.contains(where:{$0 != "0"}) else { throw invalid("version must contain one to four integers from 0 to 65535") }
        let locale = try string(manifest["default_locale"],"default_locale")
        var resources = Set<String>(), messages:[String:String] = [:], warnings = Set<String>()
        if let locale {
            guard !locale.isEmpty, locale.utf8.count <= 64, locale.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45}) else { throw invalid("invalid default_locale") }
            let path = "_locales/" + locale + "/messages.json"
            guard let bytes = try readResource(path) else { throw invalid("missing default-locale messages") }
            let values = try ExtensionJSON.object(bytes,limit:1_048_576)
            for (key,value) in values {
                guard let entry = value as? [String:Any], let message = entry["message"] as? String, message.utf8.count <= 65_536, messages[key.lowercased()] == nil else { throw invalid("invalid or ambiguous locale message") }
                messages[key.lowercased()] = message
            }
            resources.insert(path)
        }
        func localized(_ value:String) throws -> String {
            var result = "", remainder = value[...]
            while let start = remainder.range(of:"__MSG_") {
                result += remainder[..<start.lowerBound]
                let tail = remainder[start.upperBound...]
                guard let end = tail.range(of:"__"), let message = messages[String(tail[..<end.lowerBound]).lowercased()] else { throw invalid("unresolved localized identity") }
                result += message; remainder = tail[end.upperBound...]
                guard result.utf8.count <= 65_536 else { throw invalid("localized value is too long") }
            }
            result += remainder; return result
        }
        let name = try localized(string(manifest["name"],"name",required:true)!)
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.count <= 75,
              !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw invalid("name must contain 1 to 75 visible characters") }
        let summary = try string(manifest["description"],"description").map(localized)
        let versionName = try string(manifest["version_name"],"version_name").map(localized)
        let incognito = try string(manifest["incognito"],"incognito") ?? "spanning"
        guard ["spanning","split","not_allowed"].contains(incognito) else { throw invalid("unknown incognito mode") }
        if incognito == "split" {warnings.insert("Private access is unavailable for extensions requiring separate private runtimes. Normal browsing can be approved separately.")}
        func resource(_ value:Any?,_ key:String,allowEmpty:Bool = false) throws -> String? {
            guard let raw = try string(value,key) else { return nil }
            if raw.isEmpty && allowEmpty { return nil }
            let path = try ExtensionResourcePath.normalized(raw); resources.insert(path); return path
        }
        func icons(_ value:Any?,_ key:String) throws {
            guard let value else { return }
            if value is String { _ = try resource(value,key); return }
            guard let dictionary = try object(value,key) else { return }
            for (size,path) in dictionary {
                guard size == "any" || UInt16(size).map({$0 > 0}) == true else { throw invalid("invalid icon size") }
                _ = try resource(path,key)
            }
        }
        func declaration(_ value:String) throws -> String {
            if let pattern = ExtensionMatchPattern(value) {
                if value == "<all_urls>" { warnings.insert("All-sites access in Alcove excludes local files and browser pages.") }
                return pattern.string
            }
            if value.hasPrefix("file:///"), !value.contains("\\"), !value.contains("#"), value.utf8.allSatisfy({33...126 ~= $0}) {
                warnings.insert("Local-file extension access is unavailable."); return value
            }
            // Retain a well-formed FTP request visibly, without allowing it to earn a grant.
            if value.hasPrefix("ftp://"), ExtensionMatchPattern("https://" + value.dropFirst(6)) != nil {
                warnings.insert("FTP extension access is unavailable."); return value
            }
            throw invalid("invalid website match pattern")
        }
        func permissions(_ key:String) throws -> (apis:[String],hosts:[String]) {
            var apis:[String] = [], hosts:[String] = []
            for value in try strings(manifest[key],key) {
                if value == "<all_urls>" || value.contains("://") { hosts.append(try declaration(value)) }
                else {
                    guard value.utf8.count <= 128, value.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95}) else { throw invalid("invalid API permission name") }
                    apis.append(value)
                    if value == "nativeMessaging" || value == "debugger" || value == "sidePanel" { warnings.insert(value + " is unavailable in Alcove.") }
                }
            }
            return (apis,hosts)
        }
        let required = try permissions("permissions"), optional = try permissions("optional_permissions")
        var hosts = required.hosts + (try strings(manifest["host_permissions"],"host_permissions").map(declaration))
        let optionalHosts = optional.hosts + (try strings(manifest["optional_host_permissions"],"optional_host_permissions").map(declaration))
        if let entries = manifest["content_scripts"] {
            guard let entries = entries as? [[String:Any]], entries.count <= 2048 else { throw invalid("content_scripts must be a bounded object array") }
            for entry in entries {
                let matches = try strings(entry["matches"],"content-script matches")
                guard !matches.isEmpty else { throw invalid("content scripts need matches") }
                hosts += try matches.map(declaration)
                _ = try strings(entry["exclude_matches"],"exclude_matches").map(declaration)
                for key in ["js","css"] { for path in try strings(entry[key],key) { _ = try resource(path,key) } }
                for key in ["all_frames","match_about_blank","match_origin_as_fallback"] { try bool(entry[key],key) }
                if let runAt = try string(entry["run_at"],"run_at"), !["document_start","document_end","document_idle"].contains(runAt) { throw invalid("invalid content-script run_at") }
            }
        }
        try icons(manifest["icons"],"icons")
        let actionKeys = ["action","browser_action","page_action"].filter { manifest[$0] != nil }
        guard actionKeys.count <= 1 else { throw invalid("ambiguous action declarations") }
        var popup:String?
        if let key = actionKeys.first, let action = try object(manifest[key],key) {
            popup = try resource(action["default_popup"],"default_popup",allowEmpty:true)
            try icons(action["default_icon"],"default_icon")
            _ = try string(action["default_title"],"default_title").map(localized)
        }
        var optionsPage = try resource(manifest["options_page"],"options_page")
        if let options = try object(manifest["options_ui"],"options_ui") {
            guard let page = try resource(options["page"],"options_ui.page") else { throw invalid("options_ui needs a page") }
            optionsPage = page; try bool(options["open_in_tab"],"open_in_tab")
        }
        if let background = try object(manifest["background"],"background") {
            let worker = try resource(background["service_worker"],"service_worker"), page = try resource(background["page"],"background.page")
            let scripts = try strings(background["scripts"],"background.scripts")
            guard [worker != nil,page != nil,!scripts.isEmpty].filter({$0}).count <= 1 else { throw invalid("ambiguous background declarations") }
            for path in scripts { _ = try resource(path,"background.scripts") }
            try bool(background["persistent"],"background.persistent")
            if let kind = try string(background["type"],"background.type"), !["module","classic"].contains(kind) { throw invalid("invalid background type") }
        }
        if manifest["devtools_page"] != nil { _ = try resource(manifest["devtools_page"],"devtools_page"); warnings.insert("Developer-tool integration is unavailable in Alcove.") }
        if let panel = try object(manifest["side_panel"],"side_panel") { _ = try resource(panel["default_path"],"side_panel.default_path"); warnings.insert("Extension side panels are unavailable in Alcove.") }
        if let overrides = try object(manifest["chrome_url_overrides"],"chrome_url_overrides") {
            for (_,path) in overrides { _ = try resource(path,"chrome_url_overrides") }
            warnings.insert("Browser-page overrides are unavailable in Alcove.")
        }
        if let rules = try object(manifest["declarative_net_request"],"declarative_net_request") {
            guard let entries = rules["rule_resources"] as? [[String:Any]], entries.count <= 2048 else { throw invalid("rule_resources must be a bounded object array") }
            var identifiers = Set<String>()
            for entry in entries {
                guard let id = try string(entry["id"],"ruleset.id"), !id.isEmpty, id.utf8.count <= 256, identifiers.insert(id).inserted,
                      entry["enabled"] != nil, try resource(entry["path"],"ruleset.path") != nil else { throw invalid("invalid or duplicate ruleset") }
                try bool(entry["enabled"],"ruleset.enabled")
            }
        }
        if let sandbox = try object(manifest["sandbox"],"sandbox") {
            for path in try strings(sandbox["pages"],"sandbox.pages") { _ = try resource(path,"sandbox.pages") }
        }
        if let exposed = manifest["web_accessible_resources"] {
            func pattern(_ raw:String) throws { _ = try ExtensionResourcePath.normalized(raw) }
            if manifestVersion == 2 {
                for path in try strings(exposed,"web_accessible_resources") { try pattern(path) }
            } else {
                guard let entries = exposed as? [[String:Any]], entries.count <= 2048 else { throw invalid("web_accessible_resources must be a bounded object array") }
                for entry in entries {
                    let paths = try strings(entry["resources"],"web_accessible_resources.resources")
                    guard !paths.isEmpty else { throw invalid("web-accessible resources need resource patterns") }
                    for path in paths { try pattern(path) }
                    let matches = try strings(entry["matches"],"web_accessible_resources.matches")
                    for value in matches { _ = try declaration(value) }
                    let extensions = try strings(entry["extension_ids"],"web_accessible_resources.extension_ids")
                    guard extensions.allSatisfy({$0 == "*" || BrowserExtensionRecord.validExternalID($0)}), !matches.isEmpty || !extensions.isEmpty else { throw invalid("web-accessible resources need valid origin or extension selectors") }
                    try bool(entry["use_dynamic_url"],"web_accessible_resources.use_dynamic_url")
                }
            }
        }
        guard resources.count <= 10_000 else { throw ExtensionValidationError.packageTooLarge }
        func unique(_ values:[String]) -> [String] { Array(Set(values)).sorted() }
        return Self(manifestVersion:manifestVersion,name:name,version:version,versionName:versionName,summary:summary,defaultLocale:locale,
                    requestedPermissions:unique(required.apis),optionalPermissions:unique(optional.apis),hostPermissions:unique(hosts),optionalHostPermissions:unique(optionalHosts),
                    resourcePaths:resources.sorted(),actionPopup:popup,optionsPage:optionsPage,incognito:incognito,warnings:warnings.sorted())
    }
}

/// Validate duplicate keys before Foundation decodes them. Both reviewer and engine see one declaration.
enum ExtensionJSON {
    static func object(_ data:Data,limit:Int) throws -> [String:Any] {
        guard data.count <= limit else { throw ExtensionValidationError.packageTooLarge }
        var scanner = Scanner(bytes:Array(data)); try scanner.value(depth:0); scanner.whitespace()
        guard scanner.index == scanner.bytes.count, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ExtensionValidationError.invalidManifest("expected a JSON object") }
        return object
    }
    private struct Scanner {
        let bytes:[UInt8]; var index = 0; var count = 0
        var invalid:ExtensionValidationError { .invalidManifest("invalid, deeply nested or duplicate-key JSON") }
        mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte:UInt8) throws { whitespace(); guard index < bytes.count, bytes[index] == byte else { throw invalid }; index += 1 }
        mutating func string() throws -> String {
            whitespace(); let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<index])) }
                if byte == 92 { guard index < bytes.count else { throw invalid }; index += 1 }
                else if byte < 32 { throw invalid }
            }
            throw invalid
        }
        mutating func value(depth:Int) throws {
            whitespace(); count += 1
            guard depth <= 64, count <= 50_000, index < bytes.count else { throw invalid }
            if bytes[index] == 34 { _ = try string(); return }
            if bytes[index] == 123 {
                index += 1; whitespace(); var keys = Set<String>()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw invalid }
                    try take(58); try value(depth:depth + 1); whitespace()
                    guard index < bytes.count else { throw invalid }
                    if bytes[index] == 125 { index += 1; return }; try take(44)
                }
            }
            if bytes[index] == 91 {
                index += 1; whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth:depth + 1); whitespace(); guard index < bytes.count else { throw invalid }
                    if bytes[index] == 93 { index += 1; return }; try take(44)
                }
            }
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw invalid }
        }
    }
}
