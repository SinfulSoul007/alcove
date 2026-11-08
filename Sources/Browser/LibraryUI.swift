import SwiftUI
import BrowserCore

struct FindBar: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        HStack {
            FocusedInput(text: $store.findText, placeholder: "Find in page", size: 13, selectAll: true, onSubmit: { store.findNext() }, onCancel: { store.findVisible = false }, onMove: { store.findNext(backwards: $0 < 0) }).frame(width: 240, height: 24)
            Text(store.findResult).font(.caption).foregroundStyle(.secondary)
            Button { store.findNext(backwards: true) } label: { Image(systemName: "chevron.up") }.help("Previous match")
            Button { store.findNext() } label: { Image(systemName: "chevron.down") }.help("Next match")
            Spacer()
            Button { store.findVisible = false } label: { Image(systemName: "xmark") }.help("Close Find")
        }.buttonStyle(.plain).padding(10).onExitCommand { store.findVisible = false }
    }
}

struct LibraryPanel: View {
    @ObservedObject var store: BrowserStore
    @State private var section = "Bookmarks"
    @State private var search = ""
    var records: [PageRecord] {
        (section == "Bookmarks" ? store.library.bookmarks : store.library.history).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your Library").font(.title2.bold()); Spacer(); Button("Done") { store.libraryVisible = false }.keyboardShortcut(.cancelAction) }
            Picker("Collection", selection: $section) { ForEach(["Bookmarks", "History", "Archive", "Downloads"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if section == "Bookmarks" || section == "History" {
                TextField("Search \(section.lowercased())", text: $search).textFieldStyle(.roundedBorder)
                if records.isEmpty { empty("No \(section.lowercased()) yet.") }
                else {
                    List(records) { record in
                        HStack {
                            Button { _ = store.newTab(url: URL(string: record.url)); store.libraryVisible = false } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(record.title).lineLimit(1); Text(record.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if section == "Bookmarks" {
                                Button { store.library.bookmarks.removeAll { $0.id == record.id }; store.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove bookmark")
                            } else { Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5)
                    }
                }
                if section == "History" { Button("Clear History and Archive") { store.clearHistory() } }
            } else if section == "Archive" {
                if store.library.archive.isEmpty { empty("Archived tabs will appear here.") }
                else { List(store.library.archive) { tab in HStack { Text(tab.title).lineLimit(1); Spacer(); Button("Restore") { store.restoreArchived(tab.id); store.libraryVisible = false } } } }
            } else {
                if store.downloads.isEmpty { empty("Downloads from this window will appear here.") }
                else { List(store.downloads) { item in VStack(alignment: .leading, spacing: 4) { Text(item.name); Text(item.status).font(.caption).foregroundStyle(.secondary) } } }
                Text("Downloaded files stay on disk, including files saved from private windows. This list is kept only for this window’s lifetime.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 640, height: 480)
    }
    private func empty(_ text: String) -> some View { VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity) }
}

struct SettingsPanel: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Alcove Settings").font(.title2.bold()); Spacer(); Button("Done") { store.settingsVisible = false }.keyboardShortcut(.cancelAction) }
            GroupBox("Privacy") {
                VStack(alignment: .leading, spacing: 12) {
                    if !store.savingEnabled && !store.isPrivate {
                        Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking)
                        Text("Saving is paused. Existing data is preserved until Keychain access is restored.").foregroundStyle(.orange)
                    }
                    Text(store.isPrivate ? "Private window: cookies and website storage stay in memory. Sessions and history are not saved." : "Sessions, bookmarks and history are encrypted locally with a key held in macOS Keychain. Websites manage their own storage through WebKit.")
                    Text("No Alcove account, sync service or app analytics. Spaces share website logins; they are not separate profiles.")
                    Text("Camera and microphone requests require your permission. Location and notification features are not supported in this preview.")
                    HStack { Button("Clear History") { store.clearHistory() }; Button("Clear Website Data…") { store.clearWebsiteData() }.disabled(store.clearingData) }
                }.font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Tabs") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Suspend older background tabs after six live pages", isOn: $store.preferences.suspendTabs)
                    Text("May discard unsaved forms or stop background audio. Off by default.").font(.caption).foregroundStyle(.secondary)
                    Picker("Auto-archive inactive tabs", selection: $store.preferences.archiveAfterDays) {
                        Text("Off").tag(0); Text("After 1 day").tag(1); Text("After 7 days").tag(7); Text("After 30 days").tag(30)
                    }
                    Text("Pinned tabs and each Space’s selected tab are kept. Restore archived tabs from the Library.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(store.isPrivate)
            Text("Unsigned preview · Not notarized by Apple · Security review and broader compatibility testing remain in progress.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 600).onChange(of: store.preferences.suspendTabs) { _, _ in store.save() }.onChange(of: store.preferences.archiveAfterDays) { _, _ in store.archiveOldTabs(); store.save() }
    }
}
