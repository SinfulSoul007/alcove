import AppKit
import SwiftUI

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
                                Label("Your note has unsaved changes", systemImage: "exclamationmark.circle").font(.headline)
                                Text(draft.failure ?? "Your complete draft was kept.").font(.callout)
                                Text(draft.text).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Button("Copy Draft") {
                                        guard let current = drafts.recoveryState(draft, from: store) else { return }
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(current.text, forType: .string)
                                    }
                                    Button(store.easelContext(for: draft.key.tabID) == nil ? "Save in New Easel" : "Save as New Note") {
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
                    .confirmationDialog("Discard this unsaved note draft?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })) {
                        Button("Discard Draft", role: .destructive) {
                            if let pendingDiscard { drafts.discard(pendingDiscard, from: store) }
                            pendingDiscard = nil
                        }
                        Button("Keep Draft", role: .cancel) { pendingDiscard = nil }
                    } message: { Text("The saved note stays in its canvas. This removes only the unsaved draft shown above.") }
            } else if let message = store.message {
                BrowserStatusBanner(store: store, message: message).shadow(radius: 10).padding(24)
            }
        }.frame(maxWidth: .infinity)
            .alert("Recover your note in a new Easel", isPresented: Binding(get: { pendingRecovery != nil }, set: { if !$0 { pendingRecovery = nil } })) {
                TextField("Easel name", text: $recoveryTitle)
                Button("Save Note") {
                    if let pendingRecovery {
                        do { _ = try drafts.saveAsNewNote(pendingRecovery, from: store, recoveredTitle: recoveryTitle) }
                        catch { store.message = error.localizedDescription }
                    }
                    pendingRecovery = nil
                }
                Button("Cancel", role: .cancel) { pendingRecovery = nil }
            } message: { Text("Your original canvas is unavailable. This creates a new canvas in the same profile and keeps the complete note.") }
    }
}
