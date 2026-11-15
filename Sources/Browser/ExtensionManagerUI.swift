import AppKit
import SwiftUI
import Combine
import BrowserCore

@MainActor final class ExtensionManagerModel:ObservableObject {
    let session:ExtensionManagerSession
    weak var window:NSWindow?
    @Published var storeInput=""
    @Published var busy=false
    @Published var error:String?
    @Published var notice:String?
    @Published var permissions=Set<String>()
    @Published var sites=Set<String>()
    @Published var allowPrivate=false
    @Published var privateProfileID:UUID?
    @Published private(set) var marketplace: ExtensionMarketplaceBrowser?
    @Published var showsMarketplace = false
    @Published private var revision=0
    private var subscription:AnyCancellable?,normalSubscription:AnyCancellable?,task:Task<Void,Never>?,picker:NSOpenPanel?
    private weak var privateOwner:BrowserWindowOwner?
    private let privateOwnerProvider:@MainActor ()->BrowserWindowOwner?
    private var operationID=UUID(),closed=false
    var store:BrowserStore? {session.store}
    var profiles:[BrowserProfile] {store?.profiles.filter{!$0.isPendingDeletion} ?? []}
    var records:[BrowserExtensionRecord] {store?.extensionRecords(profileID:session.profileID) ?? []}
    var privateProfiles:[BrowserProfile] {
        guard let owner=privateOwner,!owner.isClosed,!owner.store.isShuttingDown,!owner.store.isPrivate,
              !owner.store.awaitingInitialMetadata,owner.store.savingEnabled,owner.store.vault != nil else {return []}
        return owner.store.profiles.filter {profile in
            !owner.store.profileUnavailable(profile.id) && owner.store.extensionRecords(profileID:profile.id).contains {
                $0.enabled && $0.pendingRemoval != true && $0.grants?.allowPrivate==true
            }
        }
    }
    var privateAccessIssue:String? {
        guard let owner=privateOwner,let profile=privateProfileID else {return nil}
        return owner.store.extensionRecords(profileID:profile).filter{$0.enabled && $0.pendingRemoval != true && $0.grants?.allowPrivate==true}.compactMap{BrowserExtensionCompatibility.privateAccessIssue(for:$0)}.first
    }
    init(session:ExtensionManagerSession,privateOwnerProvider:(@MainActor ()->BrowserWindowOwner?)? = nil) {
        self.session=session;self.privateOwnerProvider=privateOwnerProvider ?? {(NSApp.delegate as? AppDelegate)?.normalOwner}
        subscription=session.store?.objectWillChange.sink{[weak self] _ in self?.revision &+= 1}
        refreshPrivateOwner()
    }
    func refreshPrivateOwner() {
        guard !closed,store?.isPrivate==true else {return}
        // This provider only observes an already-open owner. It never creates a
        // normal store or asks Keychain to unlock one on behalf of Private.
        let owner=privateOwnerProvider()
        if privateOwner !== owner {
            privateOwner=owner;normalSubscription=nil
            normalSubscription=owner?.store.objectWillChange.sink {[weak self] _ in
                Task {@MainActor [weak self] in self?.refreshPrivateOwner()}
            }
        }
        let candidates=privateProfiles
        if !candidates.contains(where:{$0.id==privateProfileID}) {privateProfileID=candidates.first?.id}
        revision &+= 1
    }
    func cancel() {
        operationID=UUID();task?.cancel();task=nil;picker?.cancel(nil);picker=nil
        session.cancelReview();busy=false
    }
    func close() {closed=true;cancel();session.close();marketplace?.webView.stopLoading();marketplace=nil;subscription=nil;normalSubscription=nil;privateOwner=nil}
    func browseMarketplace() {
        guard !closed, !busy, session.canManage else { return }
        if marketplace == nil {
            marketplace = ExtensionMarketplaceBrowser()
            if let window, let screen = window.screen {
                let visible = screen.visibleFrame.insetBy(dx: 16, dy: 12)
                var frame = window.frame
                let width = min(1120, visible.width)
                if frame.width < width {
                    frame.origin.x = min(max(frame.midX - width / 2, visible.minX), visible.maxX - width)
                    frame.size.width = width
                    window.setFrame(frame, display: true, animate: false)
                }
            }
        }
        showsMarketplace = true
    }
    func reviewMarketplaceListing(_ listing: ExtensionStoreLocation) {
        guard !closed, !busy, showsMarketplace, session.canManage, marketplace?.listing == listing else { return }
        reviewStore(location: listing)
    }
    func openNormalWindow() {
        window?.performClose(nil)
        (NSApp.delegate as? AppDelegate)?.openMain()
    }
    func reloadPrivate(withExtensions:Bool) {
        refreshPrivateOwner()
        guard let store,store.isPrivate,let source=session.source.window,!store.isShuttingDown else {return}
        let owner=privateOwner,profile=privateProfileID
        if withExtensions,owner==nil || !privateProfiles.contains(where:{$0.id==profile}) {error=ExtensionActionError.invalidApproval.localizedDescription;return}
        if withExtensions,let issue=privateAccessIssue {error=issue;return}
        window?.performClose(nil);source.makeKeyAndOrderFront(nil)
        let completion:(Result<Void,Error>)->Void = {[weak store] result in
            if case .failure(let error)=result,!(error is CancellationError),store?.isShuttingDown==false {store?.message=error.localizedDescription}
        }
        if withExtensions,let owner,let profile {store.requestReopenPrivateExtensions(with:owner,profileID:profile,from:source,completion:completion)}
        else {store.requestReopenPrivateWithoutExtensions(from:source,completion:completion)}
    }
    func selectProfile(_ id:UUID) {
        guard !busy else {return}
        do {try session.selectProfile(id);error=nil;notice=nil} catch {self.error=error.localizedDescription}
    }
    func run(_ body:@escaping @MainActor ()async throws->Void) {
        guard !busy,!closed else {return};busy=true;error=nil;notice=nil
        let id=UUID();operationID=id
        task=Task {@MainActor [weak self] in
            do {try await body()}
            catch {if let self,self.operationID==id,!self.closed,!(error is CancellationError) {self.error=error.localizedDescription}}
            if let self,self.operationID==id {self.busy=false;self.task=nil}
        }
    }
    func prepareChoices(manifest:ExtensionManifest,supported:[String],grants:ExtensionGrantSet?=nil) {
        permissions=Set(grants?.permissions ?? manifest.requestedPermissions).intersection(supported)
        sites=Set(grants?.hostPatterns ?? manifest.hostPermissions)
        allowPrivate=grants?.allowPrivate==true && manifest.incognito=="spanning"
    }
    func reviewStore(replacing:BrowserExtensionRecord?=nil, location: ExtensionStoreLocation? = nil) {
        let input=replacing?.storeID ?? location?.id ?? storeInput
        run {[weak self] in
            guard let self else {return}
            let review=try await self.session.reviewWebStore(input,replacing:replacing?.id)
            self.prepareChoices(manifest:review.manifest,supported:review.supportedPermissions,grants:replacing?.grants)
        }
    }
    func chooseFile(replacing:BrowserExtensionRecord?=nil) {
        guard !busy,session.canManage,let window else {return}
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false;panel.resolvesAliases=false
        panel.title=replacing==nil ? "Choose an Extension":"Choose an Extension Update"
        panel.message="Select an extension folder, ZIP, or CRX3 package. You will review its permissions before installation."
        panel.prompt="Review Extension";picker=panel
        panel.beginSheetModal(for:window){[weak self,weak panel] reply in
            guard let self,!self.closed else {return};self.picker=nil
            guard reply == .OK,let url=panel?.url else {return}
            self.run {[weak self] in
                guard let self else {return}
                let review=try await self.session.reviewFile(url,replacing:replacing?.id)
                self.prepareChoices(manifest:review.manifest,supported:review.supportedPermissions,grants:replacing?.grants)
            }
        }
    }
    func reviewPermissions(_ record:BrowserExtensionRecord) {
        run {[weak self] in
            guard let self else {return}
            let review=try await self.session.reviewInstalled(record.id)
            self.prepareChoices(manifest:review.manifest,supported:review.supportedPermissions,grants:record.grants)
        }
    }
    func save() {
        let install=session.currentReview,existing=session.currentPermissions
        let permissions=Array(self.permissions),sites=Array(self.sites),allowPrivate=self.allowPrivate
        run {[weak self] in
            guard let self else {return}
            if let install {
                _ = try await self.session.approve(install,permissions:permissions,hostPatterns:sites,allowPrivate:allowPrivate)
                self.showsMarketplace = false
            }
            else if let existing {try await self.session.savePermissions(existing,permissions:permissions,hostPatterns:sites,allowPrivate:allowPrivate)}
            else {throw ExtensionActionError.stale}
            self.notice=install==nil ? "Permissions saved.":"Extension installed."
            await self.activate()
        }
    }
    private func activate() async {
        guard let store,!closed else {return}
        do {try await store.retryExtensions(profileID:session.profileID)}
        catch {notice="Your changes were saved. Extensions need attention: "+error.localizedDescription}
    }
    func setEnabled(_ record:BrowserExtensionRecord,_ value:Bool) {
        guard session.canManage else {return}
        if value && record.grants==nil {reviewPermissions(record);return}
        run {[weak self] in
            guard let self else {return}
            let store = try self.session.managementStore()
            try store.setExtensionEnabled(record.id,profileID:self.session.profileID,enabled:value)
            await self.activate()
        }
    }
    func retry() {run {[weak self] in await self?.activate()}}
    func options(_ record:BrowserExtensionRecord) {
        run {[weak self] in
            guard let self,let store=self.store else {return}
            _ = try await store.openExtensionOptions(record.id,profileID:self.session.profileID)
            store.extensionWindows[.primary]?.window?.makeKeyAndOrderFront(nil)
        }
    }
    func remove(_ record:BrowserExtensionRecord) {
        run {[weak self] in
            guard let self else {return}
            let store = try self.session.managementStore()
            if record.pendingRemoval != true {try store.beginRemoveExtension(record.id,profileID:self.session.profileID)}
            _ = try await store.finishRemoveExtension(record.id,profileID:self.session.profileID)
            self.notice="Extension and its saved data removed."
            await self.activate()
        }
    }
}

@MainActor private final class WeakExtensionManager {
    weak var value:ExtensionManagerWindowController?
    init(_ value:ExtensionManagerWindowController) {self.value=value}
}
@MainActor final class ExtensionManagerWindowController:NSWindowController,NSWindowDelegate {
    let id=UUID(),model:ExtensionManagerModel
    private var sourceObserver:NSObjectProtocol?
    private static var registry:[ObjectIdentifier:WeakExtensionManager]=[:]
    static var active:ExtensionManagerWindowController? {
        guard let window=NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow else {return nil}
        return registry[ObjectIdentifier(window)]?.value
    }
    init(session:ExtensionManagerSession) {
        model=ExtensionManagerModel(session:session)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Extensions · Alcove";window.minSize=NSSize(width:500,height:360);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self;model.window=window
        window.contentView=NSHostingView(rootView:ExtensionManagerView(model:model,session:session))
        Self.registry[ObjectIdentifier(window)]=WeakExtensionManager(self)
        if let source=session.source.window {
            window.setFrameOrigin(NSPoint(x:source.frame.midX-window.frame.width/2,y:source.frame.midY-window.frame.height/2))
            sourceObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:source,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.close()}}
        } else {window.center()}
    }
    required init?(coder:NSCoder) {fatalError("Extension manager windows are not restored")}
    deinit {if let sourceObserver {NotificationCenter.default.removeObserver(sourceObserver)}}
    func surface() {window?.makeKeyAndOrderFront(nil)}
    func windowDidBecomeKey(_ notification:Notification) {model.refreshPrivateOwner()}
    func windowWillClose(_ notification:Notification) {
        model.close()
        if let window {Self.registry.removeValue(forKey:ObjectIdentifier(window))}
        model.store?.extensionManagers.removeValue(forKey:id)
    }
    func escape() {
        if model.busy || model.session.currentReview != nil || model.session.currentPermissions != nil {model.cancel()}
        else {close()}
    }
    func closeFrontmost() {
        if let picker=window?.attachedSheet as? NSOpenPanel {picker.cancel(nil)}
        else {close()}
    }
}

extension BrowserStore {
    func requestExtensionManager(from window:NSWindow?=nil,profileID:UUID?=nil) {
        let source=window ?? NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        guard let source,let reference=extensionWindows.values.first(where:{$0.window === source}) else {message=ExtensionHostError.closed.localizedDescription;return}
        if let existing=extensionManagers.values.first(where:{$0.model.session.source === reference}) {existing.surface();return}
        guard extensionManagers.count<16 else {message="Close an extension manager before opening another.";return}
        do {
            let session=try ExtensionManagerSession(store:self,sourceWindow:source,profileID:profileID ?? activeProfileID)
            let controller=ExtensionManagerWindowController(session:session)
            extensionManagers[controller.id]=controller;controller.surface()
        } catch {message=error.localizedDescription}
    }
    func closeExtensionManagers() {
        for manager in Array(extensionManagers.values) {manager.close()}
        extensionManagers.removeAll()
    }
}

private struct ExtensionManagerView:View {
    @ObservedObject var model:ExtensionManagerModel
    @ObservedObject var session:ExtensionManagerSession
    @State private var removing:BrowserExtensionRecord?
    private var manifest:ExtensionManifest? {session.currentReview?.manifest ?? session.currentPermissions?.manifest}
    private var supported:[String] {session.currentReview?.supportedPermissions ?? session.currentPermissions?.supportedPermissions ?? []}
    private var unsupported:[String] {session.currentReview?.unsupportedPermissions ?? session.currentPermissions?.unsupportedPermissions ?? []}
    private var diagnostics:[String] {session.currentReview?.diagnostics ?? session.currentPermissions?.diagnostics ?? []}
    private var reviewing:Bool {manifest != nil}
    private var browsing: Bool { model.showsMarketplace && !reviewing && session.canManage }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label(reviewing ? "Review Extension" : (browsing ? "Chrome Web Store" : "Extensions"), systemImage: "puzzlepiece.extension").font(.title2.weight(.semibold))
                Spacer()
                if model.busy {ProgressView().controlSize(.small);Button("Cancel",action:model.cancel)}
                else {Button(reviewing ? "Cancel Review":"Done") {if reviewing {model.cancel()} else {model.window?.performClose(nil)}}}
            }.padding(20)
            HStack {
                Picker("Profile",selection:Binding(get:{session.profileID},set:model.selectProfile)) {
                    ForEach(model.profiles) {profile in Text(profile.name).tag(profile.id)}
                }.disabled(model.busy || reviewing || !session.canManage)
                if model.store?.isPrivate==true {Text("Private window").foregroundStyle(.secondary)}
            }.padding(.horizontal,20).padding(.bottom,16)
            Divider()
            if browsing, let marketplace = model.marketplace {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).padding(12)
                }
                ExtensionMarketplaceView(
                    browser: marketplace,
                    busy: model.busy,
                    openInstalled: { model.showsMarketplace = false },
                    review: model.reviewMarketplaceListing
                )
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        if let error=model.error {Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)}
                        if let notice=model.notice {Text(notice).foregroundStyle(.secondary).textSelection(.enabled)}
                        if model.store?.isPrivate==true {
                            Text("Install and change extensions in a normal window. Only extensions explicitly approved for private browsing can run here. Private access shares the extension’s settings and approved permissions with its normal profile.")
                            if model.store?.extensionHosting != nil {
                                Text("This private session currently uses extensions.").font(.headline)
                                Button("Reload Private Pages Without Extensions…"){model.reloadPrivate(withExtensions:false)}
                            }
                            if model.privateProfiles.isEmpty {
                                Text("No open, unlocked normal profile has enabled extensions approved for private browsing.").foregroundStyle(.secondary)
                            } else {
                                Picker("Extensions from",selection:$model.privateProfileID) {
                                    ForEach(model.privateProfiles) {profile in Text(profile.name).tag(Optional(profile.id))}
                                }
                                Button("Reload Private Pages With These Extensions…"){model.reloadPrivate(withExtensions:true)}.disabled(model.privateAccessIssue != nil)
                                if let issue=model.privateAccessIssue {Text(issue).font(.caption).foregroundStyle(.secondary)}
                                Text("You will confirm before reloading. Unsaved forms and page state can be lost; the private website store remains temporary.").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Open Normal Browser Window",action:model.openNormalWindow)
                        } else if #available(macOS 15.4,*) {
                            if !session.canManage {Text("Unlock this profile and finish any data operation before managing extensions.")}
                            else if let manifest {review(manifest)}
                            else {catalog}
                        } else {Text("Native extensions require macOS 15.4 or later. You can continue browsing on this version of macOS.")}
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            if reviewing {
                Divider()
                HStack {
                    Text("Only the access you select is approved.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(session.currentPermissions==nil ? "Approve and Install":"Save Permissions",action:model.save).buttonStyle(.borderedProminent).disabled(model.busy || !session.canManage)
                }.padding(16)
            }
        }.frame(minWidth:480,minHeight:300)
        .confirmationDialog("Remove \(removing?.name ?? "extension") and its saved data?",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}}),titleVisibility:.visible) {
            if let removing {Button("Remove Extension",role:.destructive){model.remove(removing);self.removing=nil}}
        } message:{Text("This removes the extension’s local settings and website data from this profile. It cannot be undone.")}
    }
    private var catalog:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Add an extension").font(.headline)
            Button(action: model.browseMarketplace) {
                Label("Browse Chrome Web Store", systemImage: "storefront")
            }.buttonStyle(.borderedProminent)
            Text("Review compatibility and permissions before installing an extension.").foregroundStyle(.secondary)
            HStack {
                TextField("Chrome Web Store link or extension ID",text:$model.storeInput).textFieldStyle(.roundedBorder).accessibilityLabel("Chrome Web Store link or extension ID")
                Button("Review Link"){model.reviewStore()}.disabled(model.storeInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Choose Folder, ZIP or CRX…"){model.chooseFile()}
                Button("Get uBlock Origin Lite") {model.storeInput="ddkjiahejlhfcafbddmgiahcphecmpfh";model.reviewStore()}
            }
            Text("uBlock Origin Lite is a separate extension from full uBlock Origin. Full uBlock Origin is not supported by this WebKit browser.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {Text("Installed in this profile").font(.headline);Spacer();Button("Retry Loading",action:model.retry)}
            if model.records.isEmpty {Text("No extensions installed yet.").foregroundStyle(.secondary).padding(.vertical,20)}
            ForEach(model.records) {record in
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading) {Text(record.name).font(.headline);Text("Version \(record.version) · \(sourceLabel(record.source,verified:record.publisherVerified==true))").font(.caption).foregroundStyle(.secondary)}
                        Spacer()
                        Toggle("Enabled",isOn:Binding(get:{record.enabled},set:{model.setEnabled(record,$0)})).toggleStyle(.switch).disabled(record.pendingRemoval==true).accessibilityLabel("Enable \(record.name)")
                    }
                    if record.pendingRemoval==true {Text("Removal needs to finish. This extension is disabled.").foregroundStyle(.secondary)}
                    if let messages=model.store?.extensionDiagnostics[session.profileID]?[record.id],!messages.isEmpty {Text(messages.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary)}
                    HStack {
                        if record.pendingRemoval==true {Button("Retry Removal"){model.remove(record)}}
                        else {
                            Button("Permissions…"){model.reviewPermissions(record)}
                            Button("Options…"){model.options(record)}.disabled(!record.enabled)
                            Menu("Update") {
                                if record.source == .webStore {Button("Review Latest Store Version"){model.reviewStore(replacing:record)}}
                                Button("Choose Updated Package…"){model.chooseFile(replacing:record)}
                            }.fixedSize()
                            Spacer()
                            Button("Remove…",role:.destructive){removing=record}
                        }
                    }
                }.padding(14).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
            }
        }.disabled(model.busy)
    }
    private func review(_ manifest:ExtensionManifest) -> some View {
        VStack(alignment:.leading,spacing:16) {
            Text(manifest.name).font(.title.weight(.semibold))
            Text("Version \(manifest.version) · Manifest \(manifest.manifestVersion)").foregroundStyle(.secondary)
            if let summary=manifest.summary {Text(summary)}
            if let preview=session.currentReview {
                Text(sourceLabel(preview.package.source,verified:preview.package.publisherVerified)).font(.callout)
                if let old=preview.previous {Text("Updating \(old.name) \(old.version). Previous permissions remain in place until this review is approved.").font(.callout).foregroundStyle(.secondary)}
                Text("SHA-256: \(preview.package.digest)").font(.caption.monospaced()).textSelection(.enabled)
            } else if let existing=session.currentPermissions {Text(sourceLabel(existing.record.source,verified:existing.record.publisherVerified==true)).font(.callout)}
            if !unsupported.isEmpty {Label("Unavailable APIs: "+unsupported.joined(separator:", ")+". Features depending on these may not work.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
            if !manifest.warnings.isEmpty {Text(manifest.warnings.joined(separator:"\n")).font(.callout).foregroundStyle(.secondary)}
            if !diagnostics.isEmpty {Text(diagnostics.joined(separator:"\n")).font(.callout).foregroundStyle(.secondary)}
            Divider()
            Text("API permissions").font(.headline)
            if supported.isEmpty {Text("No supported API permissions requested.").foregroundStyle(.secondary)}
            ForEach(supported,id:\.self) {value in
                Toggle(isOn:choice(value,in:$model.permissions)) {Text(value+(manifest.optionalPermissions.contains(value) ? " (optional)":""))}
            }
            Text("Website access").font(.headline)
            Text("Approved sites may be read or changed by this extension. All-sites access covers HTTP and HTTPS; local files are excluded.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(Set(manifest.hostPermissions+manifest.optionalHostPermissions)).sorted(),id:\.self) {value in
                Toggle(isOn:choice(value,in:$model.sites)) {Text(value).textSelection(.enabled)}
            }
            let privateIssue=BrowserExtensionCompatibility.privateAccessIssue(permissions:manifest.requestedPermissions+manifest.optionalPermissions,webKitBuild:BrowserExtensionCompatibility.webKitBuild)
            Toggle("Allow in private browsing",isOn:$model.allowPrivate).disabled(manifest.incognito != "spanning" || (privateIssue != nil && !model.allowPrivate))
            if manifest.incognito=="spanning",let privateIssue {Text(privateIssue).font(.caption).foregroundStyle(.secondary)}
            Text(manifest.incognito=="spanning" ? "Off by default. When allowed, the extension shares settings, storage and approved permissions between this profile’s normal and private pages. The extension can transmit information it can access.":"This extension’s private browsing mode is unavailable in Alcove.").font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }
    private func choice(_ value:String,in values:Binding<Set<String>>) -> Binding<Bool> {
        Binding(get:{values.wrappedValue.contains(value)},set:{if $0 {values.wrappedValue.insert(value)} else {values.wrappedValue.remove(value)}})
    }
    private func sourceLabel(_ source:ExtensionSourceKind,verified:Bool) -> String {
        switch source {
        case .webStore:return verified ? "Chrome Web Store · Publisher verified":"Chrome Web Store · Unverified"
        case .crx3:return "CRX3 · Signed package (store publisher not verified)"
        case .zip:return "ZIP · Unsigned local package"
        case .folder:return "Folder · Unsigned local package"
        }
    }
}
