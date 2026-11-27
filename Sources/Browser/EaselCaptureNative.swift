import AppKit
import WebKit
import SwiftUI
import ImageIO
import BrowserCore

extension EaselRaster {
    static func png(_ image: CGImage) throws -> EaselRaster {
        guard image.width > 0, image.height > 0, image.width <= 16384, image.height <= 16384,
              image.width <= 40_000_000 / image.height else { throw EaselImageError.size }
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else { throw EaselImageError.damaged }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw EaselImageError.damaged }
        return try EaselRaster(data: bytes as Data)
    }
    func cropped(to unit: CGRect) throws -> EaselRaster {
        guard [unit.minX, unit.minY, unit.width, unit.height].allSatisfy(\.isFinite),
              unit.minX >= 0, unit.minY >= 0, unit.width > 0, unit.height > 0,
              unit.maxX <= 1, unit.maxY <= 1 else { throw EaselImageError.size }
        if unit == CGRect(x: 0, y: 0, width: 1, height: 1) { return self }
        let image = try thumbnail(maxPixelSize: min(8192, max(pixelWidth, pixelHeight)))
        let rect = CGRect(x: unit.minX * CGFloat(image.width), y: unit.minY * CGFloat(image.height),
                          width: unit.width * CGFloat(image.width), height: unit.height * CGFloat(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: rect), !rect.isEmpty else { throw EaselImageError.damaged }
        return try Self.png(cropped)
    }
}

@MainActor struct EaselCaptureNative {
    var environment: EaselCaptureEnvironment {
        EaselCaptureEnvironment(snapshot: { web, done in
            let bounds = web.bounds, backing = max(1, web.window?.backingScaleFactor ?? 1)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { done(.failure(EaselImageError.size)); return }
            let ratio = bounds.height / bounds.width
            let pixels = min(4096, 4096 / ratio, sqrt(16_000_000 / ratio), bounds.width * backing)
            guard pixels.isFinite, pixels >= 1 else { done(.failure(EaselImageError.size)); return }
            let configuration = WKSnapshotConfiguration(); configuration.rect = bounds
            configuration.snapshotWidth = NSNumber(value: Double(pixels / backing)); configuration.afterScreenUpdates = true
            web.takeSnapshot(with: configuration) { image, error in
                if let error { done(.failure(error)); return }
                guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { done(.failure(EaselImageError.damaged)); return }
                do { done(.success(try EaselRaster.png(cg))) } catch { done(.failure(error)) }
            }
        }, preview: { source, raster, window, accept in
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Save Page to Easel"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: EaselCapturePreview(source: source, raster: raster, accept: accept))
            window.beginSheet(panel)
            return { [weak window] in
                if window?.attachedSheet === panel { window?.endSheet(panel, returnCode: .cancel) }
                panel.orderOut(nil)
            }
        })
    }
}

private struct EaselCaptureBoard: Identifiable { let id: UUID, title: String, revision: UUID }
private struct EaselCapturePreview: View {
    let source: EaselCaptureSource, raster: EaselRaster
    let accept: (EaselCaptureChoice?) throws -> Void
    private let boards: [EaselCaptureBoard]
    private let preview: NSImage?
    private let previewSize: CGSize
    @State private var destination: UUID?
    @State private var name = "Page capture"
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var error: String?
    @State private var saving = false
    init(source: EaselCaptureSource, raster: EaselRaster, accept: @escaping (EaselCaptureChoice?) throws -> Void) {
        self.source = source; self.raster = raster; self.accept = accept
        boards = (source.store?.library(for: source.profileID).easels ?? []).map { EaselCaptureBoard(id: $0.id, title: $0.title, revision: $0.revision) }
        if let image = try? raster.thumbnail(maxPixelSize: 1024) { preview = NSImage(cgImage: image, size: NSSize(width: raster.pixelWidth, height: raster.pixelHeight)) } else { preview = nil }
        let scale = min(660 / CGFloat(raster.pixelWidth), 300 / CGFloat(raster.pixelHeight))
        previewSize = CGSize(width: CGFloat(raster.pixelWidth) * scale, height: CGFloat(raster.pixelHeight) * scale)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Keep this page.").font(.title2.bold()); Text(source.title).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Cancel") { try? accept(nil) }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            HStack { Spacer(); cropPreview; Spacer() }.frame(height: 300)
            HStack {
                Text("Drag over the preview to crop.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(max(1, Int(CGFloat(raster.pixelWidth) * crop.width))) × \(max(1, Int(CGFloat(raster.pixelHeight) * crop.height))) px").font(.caption).monospacedDigit()
                Button("Reset Crop") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
            }
            Picker("Save to", selection: $destination) {
                Text("New Easel").tag(UUID?.none)
                ForEach(boards) { Text($0.title).tag(Optional($0.id)) }
            }
            if destination == nil { TextField("Easel name", text: $name).textFieldStyle(.roundedBorder) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Text(source.store?.isPrivate == true ? "Private · Kept only for this browsing session" : "Saved in this page’s profile").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(saving ? "Saving…" : "Save to Easel") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(24).frame(width: 740, height: 640)
    }
    private var cropPreview: some View {
        ZStack(alignment: .topLeading) {
            if let preview { Image(nsImage: preview).resizable().frame(width: previewSize.width, height: previewSize.height) }
            Rectangle().fill(.black.opacity(0.2))
            Rectangle().stroke(.white, lineWidth: 2)
                .frame(width: previewSize.width * crop.width, height: previewSize.height * crop.height)
                .offset(x: previewSize.width * crop.minX, y: previewSize.height * crop.minY)
        }.frame(width: previewSize.width, height: previewSize.height).clipped().contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: min(1, max(0, p.x / previewSize.width)), y: min(1, max(0, p.y / previewSize.height))) }
                let a = point(value.startLocation), b = point(value.location)
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                if rect.width * CGFloat(raster.pixelWidth) >= 1, rect.height * CGFloat(raster.pixelHeight) >= 1 { crop = rect }
            }).accessibilityLabel("Page capture preview. Use Reset Crop to keep the whole page.")
    }
    private func save() {
        saving = true; error = nil
        let destination: EaselCaptureDestination
        if let id = self.destination, let board = boards.first(where: { $0.id == id }) { destination = .existing(id: board.id, revision: board.revision) }
        else { destination = .new(title: name) }
        do { try accept(EaselCaptureChoice(raster: raster.cropped(to: crop), destination: destination)) }
        catch { self.error = error.localizedDescription; saving = false }
    }
}
