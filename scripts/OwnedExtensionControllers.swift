import Foundation
import WebKit
import BrowserCore

/// Test-only ownership journal: cleanup is restricted to UUIDs this executable recorded.
@available(macOS 15.4,*) @MainActor final class OwnedExtensionControllers {
    let manifest:URL
    private var ids:[UUID]
    init() throws {
        manifest = URL(fileURLWithPath:CommandLine.arguments[0]).appendingPathExtension("owned-extension-controllers.json")
        ids = FileManager.default.fileExists(atPath:manifest.path) ? try JSONDecoder().decode([UUID].self,from:Data(contentsOf:manifest)) : []
        guard ids.allSatisfy({$0 != BrowserProfile.zeroID && $0 != BrowserProfile.defaultID}) else {throw CocoaError(.fileReadCorruptFile)}
    }
    func register(_ id:UUID) throws {
        guard id != BrowserProfile.zeroID && id != BrowserProfile.defaultID else {throw CocoaError(.fileWriteInvalidFileName)}
        if !ids.contains(id) {ids.append(id)}
        try JSONEncoder().encode(ids).write(to:manifest,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
    }
    func cleanup() async -> Bool {
        for id in ids {
            let configuration = WKWebExtensionController.Configuration(identifier:id)
            configuration.defaultWebsiteDataStore = .nonPersistent()
            let viewConfiguration = WKWebViewConfiguration(); viewConfiguration.websiteDataStore = configuration.defaultWebsiteDataStore
            configuration.webViewConfiguration = viewConfiguration
            let controller = WKWebExtensionController(configuration:configuration)
            // Session storage is in memory and dies with its unloaded context. WebKit reports
            // an error if session storage is queried on a controller without that context.
            let types = WKWebExtensionController.allExtensionDataTypes.subtracting([.session])
            let records = await controller.dataRecords(ofTypes:types)
            await controller.removeData(ofTypes:types,from:records)
            guard records.allSatisfy({$0.errors.isEmpty}) else {
                print("FAIL: Owned extension data removal reported errors: \(records.flatMap(\.errors))");return false
            }
            // The public API retains an empty State.plist (display name/ID), so an empty
            // record list is not the erasure contract. Actual extension storage must be zero.
            let remaining = await controller.dataRecords(ofTypes:types)
            guard remaining.allSatisfy({$0.errors.isEmpty && $0.totalSizeInBytes == 0}) else {
                print("FAIL: Owned extension data after removal: \(remaining.map { ($0.totalSizeInBytes,$0.errors) })");return false
            }
        }
        do {if FileManager.default.fileExists(atPath:manifest.path) {try FileManager.default.removeItem(at:manifest)}; ids = []; return true}
        catch {print("FAIL: Owned extension-controller cleanup journal was retained for recovery.");return false}
    }
}
