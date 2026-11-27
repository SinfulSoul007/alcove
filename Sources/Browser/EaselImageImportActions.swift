import AppKit
import UniformTypeIdentifiers

private actor EaselImageFileReader {
    static let shared = EaselImageFileReader()
    func read(_ url: URL) throws -> EaselRaster {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try EaselRaster(contentsOf: url)
    }
}

extension EaselCanvasView {
    func requestImageImport() {
        guard activate(), let store, let window, window.attachedSheet == nil else { return }
        let destination: EaselImageDestination
        do { destination = try store.easelImageDestination(for: tabID) }
        catch { store.message = error.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.title = "Add Image to Easel"; panel.prompt = "Add Image"
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self, weak store] result in
            guard result == .OK, let url = panel.url, let self, let store,
                  store.isCurrentEaselImageDestination(destination), self.isCurrentPresentation else { return }
            Task { [weak self, weak store] in
                do {
                    let raster = try await EaselImageFileReader.shared.read(url)
                    guard let self, let store, store.isCurrentEaselImageDestination(destination), self.isCurrentPresentation else { return }
                    _ = try self.addImage(raster, to: destination)
                } catch { store?.message = "Couldn’t add this image. " + error.localizedDescription }
            }
        }
    }
}
