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
    var availableHeight: Double = 480
    @State private var section = "Bookmarks"
    @State private var search = ""
    @State private var archiveFilter = "All"
    @State private var archiveError: String?
    private var archivedTabs: [BrowserCore.Tab] { store.library.archive.filter { archiveFilter == "All" || $0.archiveSource == "quickBrowse" } }
    var records: [PageRecord] {
        (section == "Bookmarks" ? store.library.bookmarks : store.library.history).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(store.isPrivate ? "Private Library" : "Your Library").font(.title2.bold()); Spacer(); Button("Done") { store.libraryVisible = false }.keyboardShortcut(.cancelAction) }
            Text(store.isPrivate ? "Temporary records from this private window." : "\(store.activeProfile.name) profile · Bookmarks, history and archive are shared by its Spaces.").font(.caption).foregroundStyle(.secondary)
            if !store.isPrivate && !store.savingEnabled {
                HStack { Text("Unlock local data to change saved records.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Unlock…") { store.unlockLocalData() }.disabled(store.unlocking) }
            }
            Picker("Collection", selection: $section) { ForEach(["Bookmarks", "History", "Archive", "Downloads"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if section == "Bookmarks" || section == "History" {
                TextField("Search \(section.lowercased())", text: $search).textFieldStyle(.roundedBorder)
                if records.isEmpty { empty("No \(section.lowercased()) yet.") }
                else {
                    List(records) { record in
                        HStack {
                            Button { _ = store.newTab(url: URL(string: record.url)); store.libraryVisible = false } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(record.title).lineLimit(1); Text(record.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!store.isPrivate && store.profileUnavailable(store.activeProfileID))
                            if section == "Bookmarks" {
                                Button { store.library.bookmarks.removeAll { $0.id == record.id }; store.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove bookmark").disabled(!store.canModifyLocalMetadata || (!store.isPrivate && store.profileUnavailable(store.activeProfileID)))
                            } else { Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5)
                    }
                }
                if section == "History" { Button("Clear History and Archive") { store.clearHistory() }.disabled(!store.canModifyLocalMetadata || (!store.isPrivate && store.profileUnavailable(store.activeProfileID))) }
            } else if section == "Archive" {
                Picker("Archive source", selection: $archiveFilter) { Text("All Tabs").tag("All"); Text("Quick Browse").tag("Quick Browse") }.pickerStyle(.segmented)
                if let archiveError { Text(archiveError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if archivedTabs.isEmpty { empty(archiveFilter == "All" ? "Archived tabs will appear here." : "Archived Quick Browse pages will appear here.") }
                else { List(archivedTabs) { tab in archiveRow(tab, profileID: store.activeProfileID) } }
            } else {
                if store.downloads.isEmpty { empty("Downloads from this window will appear here.") }
                else { List(store.downloads) { item in VStack(alignment: .leading, spacing: 4) { Text(item.name); Text(item.status).font(.caption).foregroundStyle(.secondary) } } }
                Text("Downloaded files stay on disk, including files saved from private windows. This list is kept only for this window’s lifetime.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 640, height: min(520, max(360, availableHeight)))
    }
    private func archiveRow(_ tab: BrowserCore.Tab, profileID: UUID) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title).lineLimit(1)
                Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if tab.archiveSource == "quickBrowse" { Text("Quick Browse").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if tab.archiveSource == "quickBrowse" {
                Button("Quick Browse") {
                    do { _ = try store.restoreQuickArchive(tab.id, profileID: profileID); store.libraryVisible = false }
                    catch { archiveError = error.localizedDescription }
                }.help("Restore in a compact window")
                Button("Open in Space") {
                    do { _ = try store.restoreQuickArchiveInSpace(tab.id, profileID: profileID); store.libraryVisible = false }
                    catch { archiveError = error.localizedDescription }
                }
            } else { Button("Restore") { store.restoreArchived(tab.id); store.libraryVisible = false } }
        }.padding(.vertical, 4).disabled(!store.canModifyLocalMetadata || store.profileUnavailable(profileID))
    }
    private func empty(_ text: String) -> some View { VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity) }
}

struct SettingsPanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: Double = 620
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Alcove Settings").font(.title2.bold()); Spacer(); Button("Done") { store.settingsVisible = false }.keyboardShortcut(.cancelAction) }
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Customize Appearance…") { store.appearanceVisible = true }.disabled(!store.canModifyLocalMetadata)
                Button("Site Search…") { store.presentedPanel = .siteSearch }
                Button("Links…") { store.presentedPanel = .links }.accessibilityIdentifier("link-routing-settings")
                Button("Welcome Tour") { store.presentedPanel = nil; store.onboardingVisible = true }.disabled(store.isPrivate || !store.savingEnabled)
                Spacer()
                Button("Updates…") { store.updatesVisible = true }
            }
            GroupBox("Privacy") {
                VStack(alignment: .leading, spacing: 12) {
                    if !store.savingEnabled && !store.isPrivate {
                        Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking)
                        Text("Saving is paused. Existing data is preserved until Keychain access is restored.").foregroundStyle(.orange)
                    }
                    Text(store.isPrivate ? "Private window: cookies and website storage stay in memory. Sessions and history are not saved." : "Sessions, profile libraries and preferences are encrypted locally with a key held in macOS Keychain. Website storage is managed separately by WebKit.")
                    if store.isPrivate {
                        Text("This window has temporary website storage, separate from normal profiles. Manage normal profiles using Alcove → Manage Profiles.")
                    } else {
                        HStack { Text("Current profile: \(store.activeProfile.name)").fontWeight(.medium); Spacer(); Button("Manage Profiles…") { store.profilesVisible = true } }
                        Text("Spaces using the same profile share website logins, Favorites, bookmarks and history. Different profiles keep these separate.")
                    }
                    Text("No Alcove account, sync service or app analytics.")
                    Text("Camera and microphone requests require your permission. Location and notification features are not supported in this preview.")
                    HStack {
                        Button("Clear History") { store.clearHistory() }.disabled(!store.canModifyLocalMetadata || (!store.isPrivate && store.profileUnavailable(store.activeProfileID)))
                        Button(!store.isPrivate && store.activeProfile.isPendingClear ? "Retry Website Data Clear…" : "Clear Website Data…") { store.requestClearProfileData(store.activeProfileID) }
                            .disabled(!store.canModifyLocalMetadata || store.profileDataOperationInProgress || (!store.isPrivate && (store.activeProfile.isPendingDeletion || (!store.activeProfile.isPendingClear && store.profileUnavailable(store.activeProfileID)))))
                    }
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
            }.disabled(store.isPrivate || !store.savingEnabled)
            GroupBox("Quick Browse") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Open links from other apps in compact windows", isOn: Binding(get: { store.effectiveDefaultLinkDestination == .quickBrowse }, set: { value in do { try store.setDefaultLinkDestination(value ? .quickBrowse : .mostRecentSpace) } catch { store.message = error.localizedDescription } }))
                        .disabled(!store.canEditLinkRules)
                    Text("Uses your normal profile or the profile remembered for that exact hostname. Select Alcove as your default web browser in macOS to receive other apps’ web links.").font(.caption).foregroundStyle(.secondary)
                    Picker("Auto-archive inactive quick pages", selection: Binding(get: { let value = store.preferences.quickBrowseArchiveHours ?? 6; return [0, 6, 12, 24].contains(value) ? value : 6 }, set: { store.preferences.quickBrowseArchiveHours = $0; store.save() })) {
                        Text("Off").tag(0); Text("After 6 hours").tag(6); Text("After 12 hours").tag(12); Text("After 24 hours").tag(24)
                    }
                    Text("Keeps focused or loading pages, active playback/capture and open dialogs. Archiving closes the live page and can discard unsaved forms. Restore it from Library → Archive → Quick Browse, or choose Off to keep pages open.").font(.caption).foregroundStyle(.secondary)
                    if !store.isPrivate, let choices = store.preferences.quickDomainChoices, !choices.isEmpty {
                        Divider()
                        Text("Remembered profiles").font(.system(size: 12, weight: .medium))
                        ForEach(choices) { choice in
                            HStack {
                                Text(choice.host).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(store.profiles.first { $0.id == choice.profileID }?.name ?? "Unavailable").foregroundStyle(.secondary).lineLimit(1)
                                Button("Forget") { store.preferences.quickDomainChoices?.removeAll { $0.host == choice.host }; store.save() }.help("Forget the profile for \(choice.host)")
                            }.font(.system(size: 12))
                        }
                    }
                    if store.isPrivate { Text("Quick Browse settings and archived pages in this private owner are temporary.").font(.caption).foregroundStyle(.secondary) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!store.canModifyLocalMetadata)
            GroupBox("Updates") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Check for updates automatically", isOn: Binding(get: { store.preferences.automaticUpdateChecks ?? false }, set: { store.setAutomaticUpdateChecks($0) }))
                    Text("When enabled, Alcove contacts GitHub at most once a day. Browsing history is never sent, and installers are opened only when you choose.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(store.isPrivate || !store.savingEnabled)
            Text("Unsigned preview · Not notarized by Apple · Security review and broader compatibility testing remain in progress.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 600, height: min(620, max(400, availableHeight))).onChange(of: store.preferences.suspendTabs) { _, _ in store.save() }.onChange(of: store.preferences.archiveAfterDays) { _, _ in store.archiveOldTabs(); store.save() }
    }
}
