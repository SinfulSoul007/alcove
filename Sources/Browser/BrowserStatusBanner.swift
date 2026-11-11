import SwiftUI

struct BrowserStatusBanner: View {
    @ObservedObject var store: BrowserStore
    let message: String
    var body: some View {
        HStack {
            if !store.savingEnabled && !store.isPrivate { Button(store.unlocking ? "Unlocking…" : "Unlock") { store.unlockLocalData() }.disabled(store.unlocking) }
            Text(message).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            if store.canUndoSpaceDeletion { Button("Undo") { store.undoSpaceDeletion() }.help("Restore the last deleted Space") }
            Button { store.message = nil } label: { Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
}
