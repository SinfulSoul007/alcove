import AppKit
import ImageIO
import WebKit
import BrowserCore

@main struct EaselCaptureCoordinatorChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, checks = 0, fixtures: [OutputFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func fixture() throws -> OutputFixture { let f = try OutputFixture(); fixtures.append(f); return f }
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let pixels = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(red: 0.3, green: 0, blue: 1, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let data = NSMutableData(), encoder = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, pixels.makeImage()!, nil); precondition(CGImageDestinationFinalize(encoder))
        let raster = try EaselRaster(data: data as Data)
        let original = try fixture()
        var snapshots: [(Result<EaselRaster, Error>) -> Void] = []
        var choices: [(EaselCaptureChoice?) throws -> Void] = []
        let environment = EaselCaptureEnvironment(snapshot: { _, done in snapshots.append(done) }, preview: { _, _, _, done in choices.append(done); return {} })
        let coordinator = EaselCaptureCoordinator(environment: environment)
        coordinator.capture(web: original.web, store: original.store, window: original.window)
        coordinator.capture(web: original.web, store: original.store, window: original.window)
        check(snapshots.count == 1 && coordinator.isBusy(in: original.window), "One window cannot start duplicate page capture jobs")
        snapshots[0](.success(raster)); snapshots[0](.success(raster))
        check(choices.count == 1 && original.store.library.easels?.isEmpty != false, "A snapshot opens one preview without publishing before acceptance")
        try choices[0](nil)
        check(!coordinator.isBusy(in: original.window) && original.store.library.easels?.isEmpty != false, "Canceling preview saves no canvas or private image")
        coordinator.capture(web: original.web, store: original.store, window: original.window)
        snapshots[0](.success(raster))
        check(coordinator.isBusy(in: original.window) && choices.count == 1, "An old snapshot callback cannot replace a newer job")
        snapshots[1](.success(raster))
        try choices[1](EaselCaptureChoice(raster: raster, destination: .new(title: "Accepted once")))
        try choices[1](EaselCaptureChoice(raster: raster, destination: .new(title: "Duplicate")))
        check(original.store.library.easels?.count == 1 && original.store.library.easels?.first?.title == "Accepted once" && !coordinator.isBusy(in: original.window), "Repeated preview acceptance publishes exactly one native canvas")
        let stale = try fixture()
        coordinator.capture(web: stale.web, store: stale.store, window: stale.window)
        snapshots[2](.success(raster))
        stale.store.invalidateDocumentIdentity(for: stale.web)
        var rejected = false
        do { try choices[2](EaselCaptureChoice(raster: raster, destination: .new(title: "Stale"))) } catch { rejected = true }
        check(rejected && stale.store.library.easels?.isEmpty != false, "Navigation after preview cannot save stale page pixels")
        let retry = try fixture()
        coordinator.capture(web: retry.web, store: retry.store, window: retry.window)
        snapshots[3](.success(raster)); rejected = false
        do { try choices[3](EaselCaptureChoice(raster: raster, destination: .existing(id: UUID(), revision: UUID()))) } catch { rejected = true }
        check(rejected && coordinator.isBusy(in: retry.window) && retry.store.library.easels?.isEmpty != false, "A missing destination preserves the preview for an explicit retry")
        try choices[3](EaselCaptureChoice(raster: raster, destination: .new(title: "Retry saved")))
        check(retry.store.library.easels?.first?.title == "Retry saved", "A failed destination can be changed and retried with the same valid source")
        let beforeSnapshot = try fixture()
        coordinator.capture(web: beforeSnapshot.web, store: beforeSnapshot.store, window: beforeSnapshot.window)
        beforeSnapshot.store.invalidateEaselImages(for: BrowserProfile.defaultID); snapshots[4](.success(raster))
        check(beforeSnapshot.store.library.easels?.isEmpty != false && choices.count == 4, "Profile clear before snapshot completion cannot reopen a preview")
        let cropped = try raster.cropped(to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        check(cropped.pixelWidth == 60 && cropped.pixelHeight == 40, "Capture crop preserves the requested normalized image region")
        rejected = false
        do { _ = try raster.cropped(to: CGRect(x: -0.1, y: 0, width: 0.5, height: 1)) } catch { rejected = true }
        check(rejected, "Capture crop rejects bounds outside the preview")
        let command = try fixture()
        command.store.capturePageRequested = { web in coordinator.capture(web: web, store: command.store, window: command.window) }
        command.store.commandVisible = true
        command.store.runCommand(.capturePage)
        check(!command.store.commandVisible && coordinator.isBusy(in: command.window), "Command search closes its own chrome before capturing the intended page")
        snapshots[5](.success(raster)); try choices[4](EaselCaptureChoice(raster: raster, destination: .new(title: "Command capture")))
        check(command.store.library.easels?.first?.title == "Command capture", "The capture command reaches the real profile-bound save transaction")
        check(!command.store.availableCommands.contains(.capturePage), "A native Easel does not offer website capture for a hidden WebKit page")
        print("Easel capture coordinator checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
