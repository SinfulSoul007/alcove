import SwiftUI
import BrowserCore

@MainActor final class LinkRoutingEditor: ObservableObject {
    @Published var kind: LinkRuleKind = .contains
    @Published var pattern = ""
    @Published var destination: LinkDestination = .mostRecentSpace
    @Published var error: String?
    private(set) var editingID: UUID?
    private var original: LinkRule?
    var isDirty: Bool {
        if let original { return kind != original.kind || pattern != original.pattern || destination != original.destination }
        return !pattern.isEmpty || kind != .contains || destination != .mostRecentSpace
    }
    @discardableResult func finish(in store: BrowserStore) -> Bool {
        guard !isDirty || save(in:store) else { return false }
        store.presentedPanel = nil; return true
    }
    func edit(_ rule: LinkRule) { editingID = rule.id; original = rule; kind = rule.kind; pattern = rule.pattern; destination = rule.destination; error = nil }
    func cancel() { editingID = nil; original = nil; kind = .contains; pattern = ""; destination = .mostRecentSpace; error = nil }
    @discardableResult func save(in store: BrowserStore) -> Bool {
        do {
            var draft = LinkRule(id:editingID ?? UUID(),kind:kind,pattern:pattern,destination:destination)
            if let editingID {
                guard let current = store.linkRuleCatalog.entries.first(where:{$0.id == editingID}) else { throw LinkRuleError.missingRule }
                draft.enabled = current.enabled
            }
            try store.saveLinkRule(draft); cancel(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
@MainActor struct LinkRoutingPanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: Double
    @StateObject private var editor: LinkRoutingEditor
    @State private var testURL = ""
    private var scale: Double { store.appearance.textScale }
    init(store: BrowserStore, availableHeight: Double = 620, editor: LinkRoutingEditor? = nil) {
        self.store = store; self.availableHeight = availableHeight; _editor = StateObject(wrappedValue:editor ?? LinkRoutingEditor())
    }
    static func scopeDescription(in store: BrowserStore) -> String {
        store.isPrivate ? "Private windows use their own temporary account. Normal link routes are unavailable here." : "Choose where links from other apps, archived tabs and Peeks open. Rules run in order; the first enabled match wins."
    }
    static func destinationTitle(_ destination: LinkDestination, in store: BrowserStore) -> String {
        switch destination {
        case .quickBrowse: return "Quick Browse"
        case .mostRecentSpace: return "Most Recent Space"
        case .space(let id):
            guard let space = store.session.spaces.first(where:{$0.id == id}) else { return "Unavailable Space" }
            let profile = store.profiles.first(where:{$0.id == space.effectiveProfileID})?.name ?? "Unavailable Profile"
            return "\(space.name) · \(profile)" + (store.profileUnavailable(space.effectiveProfileID) ? " (paused)" : "")
        }
    }
    static func preview(_ input: String, in store: BrowserStore) -> String {
        guard !input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return "Enter a web URL to see its destination. This preview stays on your Mac." }
        guard let url = URL(string:input.trimmingCharacters(in:.whitespacesAndNewlines)) else { return "Enter a complete HTTP or HTTPS URL." }
        do {
            let decision = try store.linkDecision(for:url)
            let chosen = decision.rule?.destination ?? store.effectiveDefaultLinkDestination
            return (decision.rule == nil ? "Default → " : "Matching route → ") + destinationTitle(chosen,in:store)
        } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("Link Routing").font(.system(size:21 * scale,weight:.bold)); Spacer()
                Button("Done") { editor.finish(in:store) }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("link-routing-done")
            }
            Text(Self.scopeDescription(in:store)).font(.system(size:12 * scale)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if !store.canEditLinkRules && !store.isPrivate {
                        Text(store.savingEnabled ? "Finish the pending profile operation before changing routes." : "Saving is paused. Unlock local data to change routes.").foregroundStyle(.orange)
                        if !store.savingEnabled { Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking) }
                    }
                    GroupBox("Default for Links from Other Apps") {
                        VStack(alignment:.leading,spacing:8) {
                            destinations(selection:Binding(get:{store.effectiveDefaultLinkDestination},set:{ value in
                                do { try store.setDefaultLinkDestination(value); editor.error = nil } catch { editor.error = error.localizedDescription }
                            }))
                            Text("Quick Browse and Most Recent Space use the remembered account for the hostname. A named Space uses its own profile.").foregroundStyle(.secondary).font(.system(size:11 * scale)).fixedSize(horizontal:false,vertical:true)
                        }.padding(8)
                    }.disabled(!store.canEditLinkRules)
                    VStack(alignment:.leading,spacing:10) {
                        Text("Routes").fontWeight(.semibold)
                        ForEach(Array(store.linkRuleCatalog.entries.enumerated()),id:\.element.id) { index,rule in routeRow(rule,index:index) }
                        if store.linkRuleCatalog.entries.isEmpty { Text("No routes yet. Links from other apps use your default.").foregroundStyle(.secondary) }
                    }
                    GroupBox(editor.editingID == nil ? "Add a Route" : "Edit Route") {
                        VStack(alignment:.leading,spacing:12) {
                            Picker("Link URL",selection:$editor.kind) { Text("Contains").tag(LinkRuleKind.contains); Text("Equals").tag(LinkRuleKind.equals) }.pickerStyle(.segmented)
                            TextField(editor.kind == .contains ? "example.com or part of a URL" : "https://example.com/page",text:$editor.pattern).textFieldStyle(.roundedBorder).onSubmit { editor.save(in:store) }.accessibilityIdentifier("link-routing-pattern")
                            destinations(selection:$editor.destination)
                            Text("Contains matches literal text, without regular expressions. Equals matches a web address. An unavailable matching Space blocks the link until you edit the route.").font(.system(size:11 * scale)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            HStack { if editor.editingID != nil || editor.isDirty { Button("Cancel Edit") { editor.cancel() } }; Spacer(); Button("Save Route") { editor.save(in:store) }.buttonStyle(.borderedProminent) }
                        }.padding(8)
                    }.disabled(!store.canEditLinkRules)
                    if let error = editor.error { Text(error).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true).accessibilityLabel("Link routing error: \(error)") }
                    GroupBox("Test a URL") {
                        VStack(alignment:.leading,spacing:8) {
                            TextField("https://example.com/page",text:$testURL).textFieldStyle(.roundedBorder).accessibilityIdentifier("link-routing-test-url")
                            Text(Self.preview(testURL,in:store)).font(.system(size:11 * scale)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                        }.padding(8)
                    }.disabled(store.isPrivate)
                }.font(.system(size:12 * scale)).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(24).frame(width:600,height:min(620,max(300,availableHeight)))
            .tint(store.activeTheme.accent).preferredColorScheme(store.activeTheme.isDark ? .dark : .light)
    }
    private func destinations(selection: Binding<LinkDestination>) -> some View {
        Picker("Open in",selection:selection) {
            Text("Quick Browse").tag(LinkDestination.quickBrowse)
            Text("Most Recent Space").tag(LinkDestination.mostRecentSpace)
            ForEach(store.session.spaces) { space in Text(Self.destinationTitle(.space(space.id),in:store)).tag(LinkDestination.space(space.id)) }
            if case .space(let id) = selection.wrappedValue, !store.session.spaces.contains(where:{$0.id == id}) { Text("Unavailable Space").tag(LinkDestination.space(id)) }
        }.frame(maxWidth:.infinity)
    }
    private func routeRow(_ rule: LinkRule, index: Int) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                Toggle("Enable route \(rule.pattern)",isOn:Binding(get:{rule.enabled},set:{ enabled in var value = rule; value.enabled = enabled; perform { try store.saveLinkRule(value) } })).labelsHidden().toggleStyle(.switch)
                Text(rule.kind == .contains ? "Contains" : "Equals").foregroundStyle(.secondary); Spacer()
                Button("Edit") { editor.edit(rule) }
                Button { perform { try store.moveLinkRule(rule.id,by:-1) } } label: { Image(systemName:"arrow.up") }.disabled(index == 0).help("Move route up")
                Button { perform { try store.moveLinkRule(rule.id,by:1) } } label: { Image(systemName:"arrow.down") }.disabled(index == store.linkRuleCatalog.entries.count-1).help("Move route down")
                Button { perform { try store.removeLinkRule(rule.id); if editor.editingID == rule.id { editor.cancel() } } } label: { Image(systemName:"trash") }.help("Delete route")
            }
            Text(rule.pattern).font(.system(size:12 * scale,design:.monospaced)).lineLimit(2).textSelection(.enabled)
            Text("→ " + Self.destinationTitle(rule.destination,in:store)).foregroundStyle(.secondary).lineLimit(2)
        }.padding(10).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:9)).disabled(!store.canEditLinkRules)
    }
    private func perform(_ action: () throws -> Void) { do { try action(); editor.error = nil } catch { editor.error = error.localizedDescription } }
}
