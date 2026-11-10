import SwiftUI
import AppKit
import BrowserCore

@MainActor struct BoostPanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: Double
    @StateObject private var editor: BoostEditor
    @State private var deleting: SiteBoost?
    @State private var query = ""
    private var scale: Double { store.appearance.textScale }
    private var profileName: String { store.isPrivate ? "Private" : store.profiles.first(where: { $0.id == editor.profileID })?.name ?? "Unavailable profile" }
    private var canSave: Bool { store.canEditBoosts && !store.profileUnavailable(editor.profileID) }
    private var current: SiteBoost? { store.boostCatalog(profileID: editor.profileID).entries.first(where: { $0.id == editor.draft.id }) }
    private var sourceCurrent: Bool { editor.source?.matches(store) == true && editor.source?.host == RoutingHost.normalized(editor.draft.content.host) }
    private var entries: [SiteBoost] {
        store.boostCatalog(profileID: editor.profileID).entries.filter {
            (editor.source == nil || $0.content.host == editor.source?.host) &&
            (query.isEmpty || $0.content.name.localizedCaseInsensitiveContains(query) || $0.content.host.localizedCaseInsensitiveContains(query))
        }
    }
    init(store: BrowserStore, availableHeight: Double = 720, editor: BoostEditor? = nil) {
        self.store = store; self.availableHeight = availableHeight
        _editor = StateObject(wrappedValue: editor ?? store.boostEditor ?? BoostEditor(store: store, profileID: store.activeProfileID))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Boosts", systemImage: "paintpalette").font(.system(size: 22 * scale, weight: .bold))
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { store.boostsEnabled }, set: { value in perform { try store.setBoostsEnabled(value) } }))
                    .toggleStyle(.switch).font(.system(size: 11 * scale)).fixedSize()
                    .disabled(!store.canEditBoosts).accessibilityLabel("Enable website Boosts")
                Button("Done") { Task { await editor.finish(in: store) } }.disabled(editor.isSaving).keyboardShortcut(.cancelAction).accessibilityIdentifier("boost-done")
            }
            HStack(spacing: 8) {
                if editor.source == nil && !store.isPrivate {
                    Picker("Profile", selection: Binding(get: { editor.profileID }, set: { _ = editor.changeProfile($0, in: store) })) {
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 260).disabled(editor.isSaving)
                } else {
                    Label(profileName, systemImage: store.isPrivate ? "hand.raised" : "person.crop.circle").lineLimit(1).help(profileName)
                    if let host = editor.source?.host { Text("·"); Text(host).lineLimit(1).truncationMode(.middle).help(host) }
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11 * scale)).foregroundStyle(.secondary)
            Text("Colors, fonts and sizing save as you choose. Save your name, site and code edits when you’re ready.")
                .font(.system(size: 11 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !canSave {
                        Text(store.savingEnabled || store.isPrivate ? "This profile is unavailable or a data operation is in progress." : "Saving is paused. Unlock local data to save your Boosts.").foregroundStyle(.orange)
                        if !store.savingEnabled && !store.isPrivate { Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking) }
                    }
                    if store.isPrivate { Text("Boosts and approvals in this private window are temporary. Normal profiles stay separate.").foregroundStyle(.secondary) }
                    savedLooks
                    GroupBox(editor.original?.content.name ?? "New Boost") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Name") { TextField("Personal look", text: $editor.draft.content.name).accessibilityIdentifier("boost-name") }
                            LabeledContent("Site") { TextField("example.com", text: $editor.draft.content.host).disabled(editor.source != nil).accessibilityIdentifier("boost-site") }
                            Text("Applies to this exact hostname across HTTP, HTTPS and ports. Other subdomains and frame contents keep their own styles.")
                                .font(.system(size: 10 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.textFieldStyle(.roundedBorder).padding(8)
                    }
                    appearanceControls.disabled(!canSave)
                    codeControls
                    hiddenElements
                }.font(.system(size: 12 * scale)).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(editor.isSaving)
            if editor.isSaving { ProgressView("Checking CSS…").controlSize(.small).font(.system(size: 11 * scale)) }
            if let error = editor.error { Text(error).font(.system(size: 11 * scale)).foregroundStyle(.red).lineLimit(3).help(error).accessibilityLabel("Boost error: \(error)") }
            HStack(spacing: 10) {
                Menu("Share Appearance") {
                    Button("Copy Appearance") { perform { try BoostClipboard.copy(editor.draft) } }
                    Button("Paste Appearance") { _ = editor.pasteAppearance(from: .general) }
                }.disabled(editor.isSaving)
                Spacer()
                if editor.isDirty { Button("Cancel Edit") { editor.cancel() }.help("Discard unsaved name, site and code edits. Appearance choices are already saved.") }
                Button("Save Changes") { Task { await editor.save(in: store) } }.buttonStyle(.borderedProminent).disabled(!canSave || editor.isSaving).accessibilityIdentifier("boost-save")
            }.font(.system(size: 11 * scale))
        }.padding(20).frame(width: 600, height: min(720, max(300, availableHeight)))
            .tint(store.activeTheme.accent).preferredColorScheme(store.activeTheme.isDark ? .dark : .light)
            .onAppear { if store.boostEditor == nil { store.boostEditor = editor } }
            .interactiveDismissDisabled(editor.isDirty || editor.isSaving)
            .confirmationDialog("Delete \(deleting?.content.name ?? "Boost")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                if let value = deleting { Button("Delete Boost", role: .destructive) { _ = editor.remove(value, in: store); deleting = nil } }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("Its custom code, appearance and hidden elements will be removed from this profile.") }
    }
    private var savedLooks: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    TextField("Find a Boost", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a saved Boost")
                    Button("New Boost") { editor.newBoost() }.disabled(!canSave)
                }
                ForEach(entries) { boost in
                    HStack(spacing: 10) {
                        Toggle("Enable \(boost.content.name)", isOn: Binding(get: { boost.enabled }, set: { enabled in perform { try store.setBoostEnabled(boost.id, profileID: editor.profileID, enabled: enabled) } }))
                            .labelsHidden().toggleStyle(.switch).disabled(!canSave)
                        Button { _ = editor.select(boost) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(boost.content.name).fontWeight(boost.id == editor.draft.id ? .semibold : .regular).lineLimit(1)
                                Text(boost.content.host).font(.system(size: 10 * scale)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { deleting = boost } label: { Image(systemName: "trash") }.help("Delete \(boost.content.name)").accessibilityLabel("Delete \(boost.content.name)").disabled(!canSave)
                    }.padding(8).background(Color.primary.opacity(boost.id == editor.draft.id ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                if entries.isEmpty { Text("No saved looks here yet. Choose colors below or add your own code.").foregroundStyle(.secondary) }
            }.padding(.top, 8)
        } label: { Text("Saved Boosts (\(entries.count))").fontWeight(.semibold) }
    }
    private var appearanceControls: some View {
        GroupBox("Make It Yours") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    colorControl("Background", keyPath: \.background, fallback: "#FFFFFF")
                    colorControl("Text", keyPath: \.text, fallback: "#202020")
                    colorControl("Links", keyPath: \.link, fallback: "#6550B8")
                }
                Picker("Font", selection: Binding(get: { editor.draft.content.appearance.font }, set: { value in changeAppearance { $0.font = value } })) {
                    Text("Website Default").tag(BoostFont.original); Text("System").tag(BoostFont.system); Text("Serif").tag(BoostFont.serif); Text("Monospaced").tag(BoostFont.mono); Text("Rounded").tag(BoostFont.rounded)
                }
                HStack {
                    Text("Text size"); Slider(value: Binding(get: { editor.draft.content.appearance.textScale }, set: { value in changeAppearance { $0.textScale = value } }), in: 0.75...1.75, step: 0.05).accessibilityLabel("Relative text size")
                    Text("\(Int((editor.draft.content.appearance.textScale * 100).rounded()))% relative").monospacedDigit().font(.system(size: 10 * scale)).fixedSize()
                }
                Text("Scales the website's root and rem-based text. Fixed-pixel text keeps its size.").font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                HStack {
                    Menu("Presets") { ForEach(BoostLookPreset.allCases) { preset in Button(preset.rawValue) { editor.setAppearance(preset.appearance, in: store) } } }
                    Button("Shuffle") { if let preset = BoostLookPreset.allCases.filter({ $0 != .original && $0.appearance != editor.draft.content.appearance }).randomElement() { editor.setAppearance(preset.appearance, in: store) } }
                    Spacer(); Button("Reset Look") { editor.setAppearance(BoostAppearance(), in: store) }
                }
            }.padding(8)
        }
    }
    private func colorControl(_ title: String, keyPath: WritableKeyPath<BoostAppearance, String?>, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11 * scale, weight: .medium))
            HStack {
                ColorPicker(title, selection: Binding(get: { Self.color(editor.draft.content.appearance[keyPath: keyPath] ?? fallback) }, set: { value in
                    let c = NSColor(value).usingColorSpace(.sRGB) ?? .gray
                    func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
                    let hex = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
                    changeAppearance { $0[keyPath: keyPath] = hex }
                }), supportsOpacity: false).labelsHidden().accessibilityLabel("Boost \(title.lowercased()) color")
                Text(editor.draft.content.appearance[keyPath: keyPath] ?? "Original").font(.system(size: 9 * scale, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Button("Reset") { changeAppearance { $0[keyPath: keyPath] = nil } }.font(.system(size: 10 * scale)).disabled(editor.draft.content.appearance[keyPath: keyPath] == nil).help("Use the website's original \(title.lowercased())")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var codeControls: some View {
        GroupBox("Custom Code") {
            VStack(alignment: .leading, spacing: 10) {
                Text("CSS").fontWeight(.medium)
                Text("Review pasted styles before enabling them. CSS can change the page and request resources.").font(.system(size: 10 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $editor.draft.content.css).font(.system(size: 11 * scale, design: .monospaced)).frame(height: 110).border(Color.primary.opacity(0.12)).accessibilityLabel("Boost CSS").accessibilityIdentifier("boost-css")
                Text("JavaScript").fontWeight(.medium)
                TextEditor(text: $editor.draft.content.javascript).font(.system(size: 11 * scale, design: .monospaced)).frame(height: 130).border(Color.primary.opacity(0.12)).accessibilityLabel("Boost JavaScript").accessibilityIdentifier("boost-javascript")
                Text("JavaScript needs approval and runs on future page loads. It can read and change data on this site. Turning it off does not undo script effects; reload the page if needed.")
                    .font(.system(size: 10 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(current?.isJavaScriptApproved == true ? "Saved script approved" : "Saved script not approved").font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Approve JavaScript…", action: approve).disabled(!canSave || !sourceCurrent || editor.draft.content.javascript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Text(sourceCurrent ? "" : "Open this site in this profile to approve, run or hide elements.").font(.system(size: 10 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Run on This Page", action: run).disabled(!canSave || !sourceCurrent || editor.isDirty || current?.isJavaScriptApproved != true || current?.enabled != true || !store.boostsEnabled)
                }
            }.padding(8)
        }
    }
    private var hiddenElements: some View {
        GroupBox("Hidden Elements") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Hide an Element…", action: zap).disabled(!canSave || !sourceCurrent || !store.boostsEnabled)
                    Spacer()
                    Button("Undo Last Hide") { perform { try store.undoBoostZap(editor.draft.id, profileID: editor.profileID) } }.disabled(!canSave || current?.hiddenSelectors.isEmpty != false)
                }
                if let current, !current.hiddenSelectors.isEmpty {
                    ForEach(current.hiddenSelectors, id: \.self) { selector in
                        HStack {
                            Text(selector).font(.system(size: 10 * scale, design: .monospaced)).lineLimit(1).help(selector)
                            Spacer(); Button("Unhide") { perform { try store.removeBoostZap(current.id, profileID: editor.profileID, selector: selector) } }.disabled(!canSave)
                        }
                    }
                    Button("Unhide All") { perform { try store.clearBoostZaps(current.id, profileID: editor.profileID) } }.disabled(!canSave)
                } else { Text("Choose an element on the page to hide it. Undo restores the same page element.").font(.system(size: 10 * scale)).foregroundStyle(.secondary) }
            }.padding(8)
        }
    }
    private func changeAppearance(_ change: (inout BoostAppearance) -> Void) { var value = editor.draft.content.appearance; change(&value); editor.setAppearance(value, in: store) }
    private func perform(_ action: () throws -> Void) { do { try action(); editor.error = nil } catch { editor.error = error.localizedDescription } }
    private func approve() {
        Task { @MainActor in
            guard await editor.save(in: store), let source = editor.source else { return }
            store.requestBoostJavaScriptApproval(editor.draft.id, source: source, onApproved: { [weak editor] in editor?.error = nil }, onError: { [weak editor] in editor?.error = $0.localizedDescription })
        }
    }
    private func run() {
        guard let source = editor.source else { return }
        let id = editor.draft.id
        Task { @MainActor [weak store, weak editor] in
            do { try await store?.executeApprovedBoostOnCurrentPage(id, source: source); editor?.error = nil }
            catch { editor?.error = error.localizedDescription }
        }
    }
    private func zap() {
        Task { @MainActor in
            guard await editor.save(in: store), let source = editor.source else { return }
            perform {
                if current?.enabled == false { try store.setBoostEnabled(editor.draft.id, profileID: editor.profileID, enabled: true) }
                try store.startBoostPicker(editor.draft.id, source: source)
                store.presentedPanel = nil
            }
        }
    }
    private static func color(_ hex: String) -> Color {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

@MainActor struct BoostPickerBanner: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var session: BoostPickerSession
    private var hiddenCount: Int { store.boostCatalog(profileID: session.source.profileID).entries.first(where: { $0.id == session.boostID })?.hiddenSelectors.count ?? 0 }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
            Text(session.ready ? "Choose an element to hide" : "Preparing element picker…").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button("Undo") { do { try store.undoBoostZap(session.boostID, profileID: session.source.profileID) } catch { store.message = error.localizedDescription } }.disabled(hiddenCount == 0 || !store.canEditBoosts)
            Button("Done") { store.cancelBoostPicker() }
        }.buttonStyle(.borderless).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).shadow(radius: 8)
            .accessibilityElement(children: .contain).accessibilityLabel("Element hiding controls").help("Press Escape to stop choosing elements")
    }
}
