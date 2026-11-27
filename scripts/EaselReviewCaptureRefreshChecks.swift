import AppKit
import BrowserCore

@main struct EaselReviewCaptureRefreshChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let f = try OutputFixture(); defer { f.close() }
        let website = f.store.selectedID!, tab = try f.store.createEasel(title: "Destination")
        let board = f.store.easelContext(for: tab)!.easel
        f.store.select(website)
        let source = try EaselCaptureSource(web: f.web, store: f.store, window: f.window)
        let cg = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.3, green: 0.1, blue: 1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let raster = try EaselRaster.png(cg.makeImage()!)
        let preview = EaselCapturePreviewState(source: source, raster: raster)
        preview.destination = board.id; preview.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let oldChoice = try preview.choice()
        _ = try f.store.editEasel(in: tab, expectedRevision: board.revision, edits: [.rename("Renamed while previewing")])
        var rejected = false
        do { _ = try f.store.publishEaselCapture(oldChoice.raster, from: source, destination: oldChoice.destination) } catch { rejected = true }
        check(rejected, "A changed destination requires explicit confirmation before saving a capture")
        try preview.refreshDestinations()
        check(preview.destination == board.id && preview.crop == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) && preview.boards.first(where: { $0.id == board.id })?.title == "Renamed while previewing", "Refreshing the same destination keeps the exact crop and shows its updated name")
        let current = try preview.choice()
        let saved = try f.store.publishEaselCapture(current.raster, from: source, destination: current.destination)
        check(saved == board.id && current.raster.pixelWidth == 60 && current.raster.pixelHeight == 40 && f.store.library.easels?.first?.items.count == 1, "An explicitly refreshed destination saves the original selected crop without restarting capture")
        print("Easel capture destination refresh checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
