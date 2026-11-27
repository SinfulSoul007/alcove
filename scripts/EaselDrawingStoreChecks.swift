import AppKit
import BrowserCore
import CryptoKit

@main struct EaselDrawingStoreChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checked = 0, failed = 0
        func check(_ value: Bool, _ name: String) { checked += 1; if !value { failed += 1 }; print("\(value ? "PASS" : "FAIL"): \(name)") }
        func ready(_ store: BrowserStore) async throws {
            for _ in 0..<1000 {
                if !store.awaitingInitialMetadata && !store.unlocking { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CocoaError(.fileReadUnknown)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.DrawingStore." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let original = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        defer { original.shutdown() }
        try await ready(original)
        let tab = try original.createEasel(title: "Owned normal drawing"), context = original.easelContext(for: tab)!
        let drawing = try EaselDrawing(kind: .arrow, viewBoxWidth: 100, viewBoxHeight: 80,
                                      points: [EaselDrawingPoint(x: 10, y: 40), EaselDrawingPoint(x: 90, y: 40)],
                                      style: EaselDrawingStyle(color: "#3466CC", lineWidth: 4, opacity: 0.75))
        let item = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 300, height: 200), content: .drawing(drawing))
        let saved = try original.editEasel(in: tab, expectedRevision: context.easel.revision, edits: [.insert(item)])
        check(original.easelContext(for: tab)?.easel == saved && saved.items == [item], "The real normal-profile writer commits the complete drawing")
        check(original.views[tab] == nil && original.primaryPageView(for: tab) == nil, "A saved drawing canvas remains outside website and extension views")
        let ciphertext = try Data(contentsOf: original.sessionURL)
        check(ciphertext.range(of: Data("Owned normal drawing".utf8)) == nil, "The actual browser session file protects its drawing metadata")
        original.shutdown()
        let restored = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        defer { restored.shutdown() }
        try await ready(restored)
        check(restored.easelContext(for: tab)?.easel == saved, "A fresh browser store restores the saved drawing and native tab")
        let prior = restored.easelContext(for: tab)!.easel
        let extra = try EaselItem(frame: item.frame, content: .drawing(drawing))
        let beforeFailure = try Data(contentsOf: restored.sessionURL), vault = restored.vault
        restored.vault = MetadataStore(url: root, key: key)
        do { _ = try restored.editEasel(in: tab, expectedRevision: prior.revision, edits: [.insert(extra)]); check(false, "A failed drawing save reports failure") }
        catch { check(true, "A failed drawing save reports failure") }
        let afterFailureBytes = try Data(contentsOf: restored.sessionURL)
        check(restored.easelContext(for: tab)?.easel == prior && afterFailureBytes == beforeFailure, "A failed save preserves the model, revision and encrypted bytes")
        restored.vault = vault
        let afterRetry = try restored.editEasel(in: tab, expectedRevision: prior.revision, edits: [.insert(extra)])
        check(afterRetry.items == [item, extra], "Retrying after a drawing save failure preserves both marks")
        let beforeBatch = try Data(contentsOf: restored.sessionURL)
        let third = try EaselItem(frame: item.frame, content: .drawing(drawing))
        do { _ = try restored.editEasel(in: tab, expectedRevision: afterRetry.revision, edits: [.insert(third), .remove([UUID()])]); check(false, "A mixed invalid drawing batch is refused") }
        catch EaselError.missingItem { check(true, "A mixed invalid drawing batch is refused") }
        let afterBatchBytes = try Data(contentsOf: restored.sessionURL)
        check(restored.easelContext(for: tab)?.easel == afterRetry && afterBatchBytes == beforeBatch, "A rejected batch cannot publish its earlier drawing insertion")
        let privateStore = BrowserStore(isPrivate: true); defer { privateStore.shutdown() }
        let privateTab = try privateStore.createEasel(title: "Owned private drawing"), privateBoard = privateStore.easelContext(for: privateTab)!.easel
        _ = try privateStore.editEasel(in: privateTab, expectedRevision: privateBoard.revision, edits: [.insert(item)])
        check(privateStore.easelContext(for: privateTab)?.easel.items == [item] && restored.easelContext(for: tab)?.easel == afterRetry,
              "Actual private drawing edits remain separate from the normal profile")
        print("Easel drawing store checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
