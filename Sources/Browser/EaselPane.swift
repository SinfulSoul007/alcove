import AppKit
import SwiftUI
import BrowserCore

struct EaselPaneIdentity: Hashable {
    let tabID: UUID
    let profileID: UUID?
    let easelID: UUID?
}

struct EaselPane: View {
    @ObservedObject var store: BrowserStore
    let tabID: UUID
    @StateObject private var canvas: EaselCanvasView
    init(store: BrowserStore, tabID: UUID) {
        self.store = store; self.tabID = tabID
        _canvas = StateObject(wrappedValue: EaselCanvasView(store: store, tabID: tabID))
    }
    var body: some View {
        if let context = store.easelContext(for: tabID) {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    toolbar(title: context.easel.title, compact: false)
                    toolbar(title: context.easel.title, compact: true)
                }.padding(.horizontal, 14).padding(.vertical, 10).background(.thinMaterial)
                Divider()
                EaselCanvasRepresentable(canvas: canvas, theme: store.activeTheme)
                    .overlay {
                        if context.easel.items.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "square.stack.3d.up").font(.system(size: 34, weight: .light)).opacity(0.5)
                                Text("A place to think.").font(.system(size: 26, weight: .medium, design: .rounded))
                                Text("Collect notes, links and ideas on your canvas.").font(.callout).opacity(0.6)
                                Button("Add your first note") { canvas.addNote() }.buttonStyle(.borderedProminent)
                            }.padding(24).disabled(!store.canModifyLocalMetadata)
                        }
                    }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.slash").font(.largeTitle)
                Text("This Easel is unavailable").font(.headline)
                Text("It may have been deleted or belong to another profile.").font(.callout).foregroundStyle(.secondary)
                Button("Open Library") { store.librarySection = .easels; store.libraryVisible = true }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private func toolbar(title: String, compact: Bool) -> some View {
        if compact {
            HStack(spacing: 8) {
                Menu {
                    Button("Add Note") { canvas.addNote() }
                    Button("Add Link…") { canvas.requestLink() }
                    Button("Rename Easel…") { canvas.requestRename() }
                    Menu("Arrange Selected Cards") {
                        Button("Bring to Front") { canvas.bringSelectedToFront() }
                        Button("Move Left") { canvas.moveSelected(dx: -20, dy: 0) }
                        Button("Move Right") { canvas.moveSelected(dx: 20, dy: 0) }
                        Button("Move Up") { canvas.moveSelected(dx: 0, dy: -20) }
                        Button("Move Down") { canvas.moveSelected(dx: 0, dy: 20) }
                        Button("Wider") { canvas.moveSelected(dx: 20, dy: 0, resize: true) }
                        Button("Narrower") { canvas.moveSelected(dx: -20, dy: 0, resize: true) }
                        Button("Taller") { canvas.moveSelected(dx: 0, dy: 20, resize: true) }
                        Button("Shorter") { canvas.moveSelected(dx: 0, dy: -20, resize: true) }
                        Button("Delete Selected Cards", role: .destructive) { canvas.deleteSelected() }
                    }.disabled(canvas.selection.isEmpty)
                    Divider()
                    Button("Actual Size") { canvas.setZoom(1) }
                    Button("Fit Content") { canvas.fitContent() }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Canvas actions")
                Spacer(minLength: 0)
                Button { canvas.setZoom(canvas.magnification / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                Text("\(Int(canvas.zoom * 100))%").font(.caption).monospacedDigit().frame(width: 36)
                Button { canvas.setZoom(canvas.magnification * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
            }.controlSize(.small)
        } else {
        HStack(spacing: 10) {
            if !compact {
                Button { canvas.requestRename() } label: {
                    HStack(spacing: 6) { Image(systemName: "square.stack.3d.up"); Text(title).fontWeight(.medium).lineLimit(1) }
                }.buttonStyle(.plain).help("Rename Easel").frame(maxWidth: 220, alignment: .leading)
                Spacer(minLength: 6)
            }
            Button { canvas.addNote() } label: { Label("Note", systemImage: "note.text.badge.plus") }.help("Add a note")
            Button { canvas.requestLink() } label: { Label("Link", systemImage: "link.badge.plus") }.help("Add a link")
            Menu {
                Button("Bring to Front") { canvas.bringSelectedToFront() }
                Button("Move Left") { canvas.moveSelected(dx: -20, dy: 0) }
                Button("Move Right") { canvas.moveSelected(dx: 20, dy: 0) }
                Button("Move Up") { canvas.moveSelected(dx: 0, dy: -20) }
                Button("Move Down") { canvas.moveSelected(dx: 0, dy: 20) }
                Divider()
                Button("Wider") { canvas.moveSelected(dx: 20, dy: 0, resize: true) }
                Button("Narrower") { canvas.moveSelected(dx: -20, dy: 0, resize: true) }
                Button("Taller") { canvas.moveSelected(dx: 0, dy: 20, resize: true) }
                Button("Shorter") { canvas.moveSelected(dx: 0, dy: -20, resize: true) }
                Divider()
                Button("Delete Selected Cards", role: .destructive) { canvas.deleteSelected() }
            } label: { Label("Arrange", systemImage: "square.3.layers.3d") }.disabled(canvas.selection.isEmpty)
            Divider().frame(height: 18)
            Button { canvas.setZoom(canvas.magnification / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out").accessibilityLabel("Zoom out")
            Menu {
                Button("Actual Size") { canvas.setZoom(1) }
                Button("Fit Content") { canvas.fitContent() }
                ForEach([25, 50, 75, 100, 150, 200], id: \.self) { value in Button("\(value)%") { canvas.setZoom(CGFloat(value) / 100) } }
            } label: { Text("\(Int(canvas.zoom * 100))%").monospacedDigit().frame(width: 42) }.accessibilityLabel("Canvas magnification")
            Button { canvas.setZoom(canvas.magnification * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in").accessibilityLabel("Zoom in")
        }.controlSize(.small)
        }
    }
}

private struct EaselCanvasRepresentable: NSViewRepresentable {
    let canvas: EaselCanvasView
    let theme: AppearanceTheme
    func makeNSView(context: Context) -> EaselCanvasView { canvas }
    func updateNSView(_ view: EaselCanvasView, context: Context) {
        view.applyTheme(theme, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        view.reconcile()
    }
    static func dismantleNSView(_ view: EaselCanvasView, coordinator: ()) {
        for card in view.cards.values { card.finishEaselDraftEditing() }
    }
}
