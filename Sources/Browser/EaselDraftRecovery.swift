import AppKit
import SwiftUI
import BrowserCore

/// Kept at window scope so a failed note remains recoverable after leaving its tab.
struct EaselDraftRecovery: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var drafts: EaselDraftCoordinator
    @State private var pendingDiscard: EaselDraftState?
    @State private var pendingRecovery: EaselDraftState?
    @State private var recoveryTitle = "Recovered Easel"
    init(store: BrowserStore) {
        self.store = store; self.drafts = store.easelDrafts
    }
    var body: some View {
        let failures = drafts.failures(in: store)
        VStack {
            Spacer()
            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(failures, id: \.key) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(draft.pendingDrawing == nil ? "Your note has unsaved changes" : "Your drawing has unsaved changes", systemImage: "exclamationmark.circle").font(.headline)
                                Text(draft.failure ?? "Your complete draft was kept.").font(.callout)
                                if let item = draft.pendingDrawing, case .drawing(let drawing) = item.content {
                                    EaselRetainedDrawingPreview(drawing: drawing).frame(height: 100)
                                        .accessibilityLabel("Unsaved " + drawing.kind.rawValue + " drawing")
                                } else {
                                    Text(draft.text).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack {
                                    if draft.pendingDrawing == nil {
                                        Button("Copy Draft") {
                                            guard let current = drafts.recoveryState(draft, from: store) else { return }
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(current.text, forType: .string)
                                        }
                                    }
                                    Button(store.easelContext(for: draft.key.tabID) == nil ? "Save in New Easel" : (draft.pendingDrawing == nil ? "Save as New Note" : "Save as New Drawing")) {
                                        if store.easelContext(for: draft.key.tabID) == nil { recoveryTitle = "Recovered Easel"; pendingRecovery = draft }
                                        else { do { _ = try drafts.saveAsNewNote(draft, from: store) } catch { store.message = error.localizedDescription } }
                                    }.disabled(!store.canModifyLocalMetadata)
                                    Button("Retry") { drafts.retry(draft, from: store) }.disabled(!store.canModifyLocalMetadata)
                                    Button("Discard Draft", role: .destructive) { pendingDiscard = draft }
                                }.controlSize(.small)
                            }
                        }
                        if !store.isPrivate && !store.savingEnabled {
                            Button(store.unlocking ? "Retrying Saving…" : "Retry Saving") { store.unlockLocalData() }.disabled(store.unlocking)
                        }
                    }.padding(16)
                }.frame(maxWidth: 600, maxHeight: min(300, CGFloat(failures.count) * 170 + 40))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).shadow(radius: 10).padding(24)
                    .confirmationDialog("Discard this unsaved canvas draft?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })) {
                        Button("Discard Draft", role: .destructive) {
                            if let pendingDiscard { drafts.discard(pendingDiscard, from: store) }
                            pendingDiscard = nil
                        }
                        Button("Keep Draft", role: .cancel) { pendingDiscard = nil }
                    } message: { Text("Saved canvas items stay in place. This removes only the unsaved draft shown above.") }
            } else if let message = store.message {
                BrowserStatusBanner(store: store, message: message).shadow(radius: 10).padding(24)
            }
        }.frame(maxWidth: .infinity)
            .alert("Recover your draft in a new Easel", isPresented: Binding(get: { pendingRecovery != nil }, set: { if !$0 { pendingRecovery = nil } })) {
                TextField("Easel name", text: $recoveryTitle)
                Button("Save Draft") {
                    if let pendingRecovery {
                        do { _ = try drafts.saveAsNewNote(pendingRecovery, from: store, recoveredTitle: recoveryTitle) }
                        catch { store.message = error.localizedDescription }
                    }
                    pendingRecovery = nil
                }
                Button("Cancel", role: .cancel) { pendingRecovery = nil }
            } message: { Text("Your original canvas is unavailable. This creates a new canvas in the same profile and keeps the complete draft.") }
    }
}

private struct EaselRetainedDrawingPreview: NSViewRepresentable {
    let drawing: EaselDrawing
    func makeNSView(context: Context) -> RetainedDrawingView { RetainedDrawingView(drawing: drawing) }
    func updateNSView(_ view: RetainedDrawingView, context: Context) { view.drawing = drawing; view.needsDisplay = true }
}
private final class RetainedDrawingView: NSView {
    var drawing: EaselDrawing
    override var isFlipped: Bool { true }
    init(drawing: EaselDrawing) { self.drawing = drawing; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(max(1, bounds.width - 16) / drawing.viewBoxWidth, max(1, bounds.height - 16) / drawing.viewBoxHeight)
        let width = drawing.viewBoxWidth * scale, height = drawing.viewBoxHeight * scale
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        EaselDrawingRenderer.draw(drawing, in: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height), context: context)
    }
}
