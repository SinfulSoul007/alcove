import SwiftUI
import BrowserCore

struct SiteSearchPill: View {
    let site: SiteSearch
    var maximumWidth: CGFloat = 180
    var scale: Double = 1
    let fill: Color
    let onClear: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(site.name).lineLimit(1).truncationMode(.tail)
            Button(action: onClear) { Image(systemName: "xmark.circle.fill").opacity(0.6) }
                .buttonStyle(.plain).focusable(false).fixedSize()
                .help("Exit \(site.name) search").accessibilityLabel("Exit \(site.name) search")
        }.font(.system(size: 11 * scale, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 4).frame(maxWidth: maximumWidth)
            .background(fill, in: Capsule()).help("Search \(site.name)")
            .accessibilityElement(children: .contain).accessibilityLabel("\(site.name) site search")
    }
}

@MainActor struct SiteSearchPanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: Double = 620
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = ""
    @State private var error: String?
    private var scale: Double { store.appearance.textScale }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Site Search").font(.system(size: 21 * scale, weight: .bold))
                Spacer()
                Button("Done") { store.presentedPanel = nil }.keyboardShortcut(.cancelAction)
            }
            Text(store.isPrivate ? "Shortcuts in this private window are temporary. Normal search settings stay separate." : "Shortcuts are shared across normal profiles and encrypted with preferences. Searches use the account of the window or Space where you type.")
                .font(.system(size: 12 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Type a shortcut, press Tab, then enter your query. Nothing is sent until you search.")
                        .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                    if !store.canEditSiteSearches {
                        Text(store.savingEnabled || store.isPrivate ? "Finish the pending profile operation before editing shortcuts." : "Saving is paused. Unlock local data to edit search shortcuts.")
                            .foregroundStyle(.orange).font(.system(size: 12 * scale))
                        if !store.isPrivate && !store.savingEnabled {
                            Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking)
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.siteSearchCatalog.entries) { site in
                            HStack(spacing: 12) {
                                Toggle("Enable \(site.name)", isOn: Binding(get: { site.enabled }, set: { value in
                                    var edited = site; edited.enabled = value
                                    do { try store.saveSiteSearch(edited); error = nil } catch { self.error = error.localizedDescription }
                                })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Enable \(site.name)")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(site.name).fontWeight(.medium).lineLimit(1)
                                    Text(site.keyword).font(.system(size: 11 * scale, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("Edit") { edit(site) }
                                Button { remove(site) } label: { Image(systemName: "trash") }
                                    .help("Remove \(site.name)").accessibilityLabel("Remove \(site.name)")
                            }.font(.system(size: 12 * scale)).padding(10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                                .disabled(!store.canEditSiteSearches)
                        }
                        if store.siteSearchCatalog.entries.isEmpty {
                            Text("No site shortcuts. Add one below to use Tab to search a site.")
                                .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox(editingID == nil ? "Add a Shortcut" : "Edit Shortcut") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Name") { TextField("YouTube", text: $name).accessibilityIdentifier("site-search-name") }
                            LabeledContent("Shortcut") { TextField("yt", text: $keyword).accessibilityIdentifier("site-search-keyword") }
                            LabeledContent("Search URL") { TextField("https://example.com/search?q=%s", text: $template).onSubmit(save).accessibilityIdentifier("site-search-template") }
                            Text("Use one %s where the query belongs in the URL. HTTP and HTTPS are supported; sign-in credentials are not stored in the template.")
                                .font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                            HStack {
                                Menu("Use a Preset") {
                                    ForEach(SiteSearch.defaults) { site in Button(site.name) { var copy = site; copy.id = UUID(); edit(copy, isNew: true) } }
                                }
                                Spacer()
                                if editingID != nil { Button("Cancel Edit", action: clearEditor) }
                                Button("Save Shortcut", action: save).buttonStyle(.borderedProminent)
                            }
                        }.font(.system(size: 12 * scale)).textFieldStyle(.roundedBorder).padding(8)
                    }.disabled(!store.canEditSiteSearches)
                    if let error { Text(error).font(.system(size: 12 * scale)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Search shortcut error: \(error)") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 600, height: min(620, max(360, availableHeight)))
            .tint(store.activeTheme.accent).preferredColorScheme(store.activeTheme.isDark ? .dark : .light)
    }
    private func edit(_ site: SiteSearch, isNew: Bool = false) {
        editingID = isNew ? nil : site.id; name = site.name; keyword = site.keyword; template = site.template; error = nil
    }
    private func clearEditor() { editingID = nil; name = ""; keyword = ""; template = ""; error = nil }
    static func saveDraft(_ draft: SiteSearch, in store: BrowserStore) throws {
        var value = draft
        if let current = store.siteSearchCatalog.entries.first(where: { $0.id == draft.id }) { value.enabled = current.enabled }
        try store.saveSiteSearch(value)
    }
    private func save() {
        do { try Self.saveDraft(SiteSearch(id: editingID ?? UUID(), name: name, keyword: keyword, template: template), in: store); clearEditor() }
        catch { self.error = error.localizedDescription }
    }
    private func remove(_ site: SiteSearch) {
        do { try store.removeSiteSearch(site.id); if editingID == site.id { clearEditor() }; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
