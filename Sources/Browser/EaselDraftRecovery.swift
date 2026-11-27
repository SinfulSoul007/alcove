import AppKit
import SwiftUI

/// Kept at window scope so a failed note remains recoverable after leaving its tab.
struct EaselDraftRecovery: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var drafts: EaselDraftCoordinator
    @State private var pendingDiscard: EaselDraftState?
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
                                        guard let current = drafts.state(for: draft.key) else { return }
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(current.text, forType: .string)
                                    }
                                    Button("Save as New Note") {
                                        do { _ = try drafts.saveAsNewNote(draft) } catch { store.message = error.localizedDescription }
                                    }.disabled(!store.canModifyLocalMetadata)
                                    Button("Retry") { drafts.retry(draft) }.disabled(!store.canModifyLocalMetadata)
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
                            if let pendingDiscard { drafts.discard(pendingDiscard) }
                            pendingDiscard = nil
                        }
                        Button("Keep Draft", role: .cancel) { pendingDiscard = nil }
                    } message: { Text("The saved note stays in its canvas. This removes only the unsaved draft shown above.") }
            } else if let message = store.message {
                BrowserStatusBanner(store: store, message: message).shadow(radius: 10).padding(24)
            }
        }.frame(maxWidth: .infinity)
    }
}
