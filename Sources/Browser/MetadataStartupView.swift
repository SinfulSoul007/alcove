import SwiftUI

struct MetadataStartupView: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text(store.profileInUse ? "Your data is open in another Alcove" : (store.unlocking ? "Opening your Alcove" : "Your saved data is locked")).font(.title.bold())
            Text(store.unlocking
                 ? "Waiting for macOS Keychain. Complete any Keychain prompt on your Mac to open your saved tabs."
                 : (store.profileInUse ? "Close the other copy of Alcove, then try again. You can use a private window meanwhile." : "Your encrypted tabs and profiles are preserved. Unlock local data to continue."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 430)
            if store.unlocking { ProgressView().controlSize(.small) }
            else {
                Button(store.profileInUse ? "Try Again" : "Unlock Local Data…") { store.unlockLocalData() }.buttonStyle(.borderedProminent)
                if let error = store.metadataLoadError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: 480) }
            }
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: 480) }
            Button("Open Private Window") { store.privateWindowRequested?() }
            Text("Private browsing uses temporary website storage and does not need your saved-data key.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)).accessibilityIdentifier("metadata-startup")
    }
}
