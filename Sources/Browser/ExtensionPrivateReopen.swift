import AppKit
import WebKit
import BrowserCore

struct PrivateExtensionReopenReview {
    let profileName:String?,pageCount:Int,usesExtensions:Bool
    var title:String {usesExtensions ? "Reload private pages with extensions?" : "Reload private pages without extensions?"}
    var detail:String {
        let pages = pageCount == 1 ? "1 private page" : "\(pageCount) private pages"
        let scope = "This reloads \(pages) in this private session and closes its previews. Unsaved forms and page history will be lost. Private website cookies stay in this temporary session."
        return usesExtensions ? scope + " Extensions approved for private access in \(profileName ?? "this account") can read private browsing information and may retain or transmit it. Their extension settings and sign-ins are shared with that account." : scope
    }
}
@MainActor struct PrivateExtensionReopenPrompt {
    var confirm:(NSWindow,PrivateExtensionReopenReview,@escaping(Bool)->Void)->(()->Void)?
    static var live:Self {Self(confirm:{window,review,reply in
        guard window.attachedSheet == nil else {reply(false);return nil}
        let alert = NSAlert();alert.messageText = review.title;alert.informativeText = review.detail
        alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Reload Private Pages")
        alert.beginSheetModal(for:window){reply($0 == .alertSecondButtonReturn)}
        return {if window.attachedSheet === alert.window {window.endSheet(alert.window,returnCode:.abort)}}
    })}
}

@MainActor final class PrivateExtensionReopenPage {
    weak var web:WKWebView?
    let document:NSUUID,url:URL?,frame:CGRect
    init(_ web:WKWebView,client:BrowserStore) {self.web = web;document = client.documentIdentity(for:web);url = web.url;frame = web.frame}
    func matches(_ current:WKWebView?,client:BrowserStore) -> Bool {
        guard let web,current === web,client.documentIdentity(for:web) === document,web.url == url,
              web.configuration.websiteDataStore === client.privateDataStore else {return false}
        return true
    }
}
@MainActor final class PrivateExtensionReopenSource {
    weak var client:BrowserStore?,window:NSWindow?,host:(any BrowserExtensionHosting)?
    let hadHost:Bool,document:Data,contentController:WKUserContentController?
    let windows:[ExtensionWindowKind:ExtensionBrowserWindow],pages:[UUID:PrivateExtensionReopenPage],peeks:[PeekContext:PrivateExtensionReopenPage]
    static func encoded(_ client:BrowserStore) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(client.makeDocument())}
    init(client:BrowserStore,window:NSWindow) throws {
        guard client.isPrivate,!client.isShuttingDown,client.extensionWindows.values.contains(where:{$0.window === window}),window.attachedSheet == nil else {throw ExtensionHostError.stale}
        guard !client.profileDataOperationInProgress,!client.profileUnavailable(BrowserProfile.defaultID) else {throw ProfileError.busy}
        self.client = client;self.window = window;host = client.extensionHosting;hadHost = host != nil
        document = try Self.encoded(client);contentController = client.privateUserContentController;windows = client.extensionWindows
        pages = client.views.mapValues{PrivateExtensionReopenPage($0,client:client)}
        peeks = client.peekPages.mapValues{PrivateExtensionReopenPage($0.web,client:client)}
    }
    var current:Bool {
        guard let client,let window,!client.isShuttingDown,client.isPrivate,client.privateUserContentController === contentController,
              !client.profileDataOperationInProgress,!client.profileUnavailable(BrowserProfile.defaultID),
              client.extensionHosting === host,(!hadHost || host != nil),client.privateExtensionReopenJob?.source === self,
              client.extensionWindows.count == windows.count,client.views.count == pages.count,client.peekPages.count == peeks.count,
              windows.allSatisfy({client.extensionWindows[$0.key] === $0.value && $0.value.window != nil}),
              client.extensionWindows.values.contains(where:{$0.window === window}),
              pages.allSatisfy({$0.value.matches(client.views[$0.key],client:client)}),
              peeks.allSatisfy({$0.value.matches(client.peekPages[$0.key]?.web,client:client)}),
              (try? Self.encoded(client)) == document else {return false}
        return true
    }
}

@MainActor struct PrivateExtensionReopenDestination {
    let profileName:String?,usesExtensions:Bool
    let current:()->Bool,prepare:()async throws->Void,publish:(BrowserStore)->Void,close:()->Void
    static var without:Self {Self(profileName:nil,usesExtensions:false,current:{true},prepare:{},publish:{$0.extensionHosting = nil},close:{})}
}
@MainActor final class PrivateExtensionReopenJob {
    let source:PrivateExtensionReopenSource,destination:PrivateExtensionReopenDestination
    private var completion:((Result<Void,Error>)->Void)?,dismiss:(()->Void)?,worker:Task<Void,Never>?,timeout:Task<Void,Never>?,closing:NSObjectProtocol?
    private(set) var committing = false
    private var accepted = false
    init(source:PrivateExtensionReopenSource,destination:PrivateExtensionReopenDestination,completion:@escaping(Result<Void,Error>)->Void) {self.source = source;self.destination = destination;self.completion = completion}
    var current:Bool {completion != nil && source.current && destination.current()}
    func start(prompt:PrivateExtensionReopenPrompt,duration:Duration) {
        guard let window = source.window else {finish(.failure(ExtensionHostError.stale));return}
        closing = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated {self?.finish(.failure(ExtensionHostError.closed))}}
        timeout = Task { @MainActor [weak self] in
            do {try await Task.sleep(for:min(.seconds(90),max(.milliseconds(1),duration)));self?.finish(.failure(ExtensionHostError.timedOut))} catch {}
        }
        let review = PrivateExtensionReopenReview(profileName:destination.profileName,pageCount:source.pages.count+source.peeks.count,usesExtensions:destination.usesExtensions)
        let dismiss = prompt.confirm(window,review){[weak self] in self?.reply($0)}
        if completion == nil || accepted {dismiss?()} else {self.dismiss = dismiss}
    }
    func reply(_ allowed:Bool) {
        guard completion != nil,!accepted else {return}
        guard allowed else {finish(.failure(CancellationError()));return}
        guard current else {finish(.failure(ExtensionHostError.stale));return}
        accepted = true;let dismiss = self.dismiss;self.dismiss = nil;dismiss?()
        worker = Task { @MainActor [weak self] in
            guard let self else {return}
            do {
                try await destination.prepare();try Task.checkCancellation()
                guard current,let client = source.client else {throw ExtensionHostError.stale}
                committing = true;timeout?.cancel();timeout = nil
                destination.publish(client)
                client.privateUserContentController = WKUserContentController()
                client.closeAllPeeks()
                for id in Array(client.views.keys) {client.discardView(id)}
                for (id,page) in source.pages {
                    let configuration = WKWebViewConfiguration();configuration.websiteDataStore = client.privateDataStore!
                    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                    client.configureExtensions(configuration,profileID:BrowserProfile.defaultID)
                    let web = WKWebView(frame:page.frame,configuration:configuration)
                    client.registerView(web,for:id,profile:BrowserProfile.defaultID)
                    if let url = page.url {web.load(URLRequest(url:url))}
                }
                client.revision += 1;client.extensionHosting?.refresh();finish(.success(()))
            } catch {finish(.failure(error))}
        }
    }
    func finish(_ result:Result<Void,Error>) {
        guard let completion else {return};self.completion = nil
        worker?.cancel();worker = nil;timeout?.cancel();timeout = nil
        if let closing {NotificationCenter.default.removeObserver(closing);self.closing = nil}
        if source.client?.privateExtensionReopenJob === self {source.client?.privateExtensionReopenJob = nil}
        let dismiss = self.dismiss;self.dismiss = nil;dismiss?();destination.close();completion(result)
    }
    deinit {if let closing {NotificationCenter.default.removeObserver(closing)}}
}

extension BrowserStore {
    func requestReopenPrivateExtensions(with owner:BrowserWindowOwner,profileID:UUID,from window:NSWindow,confirmation:PrivateExtensionReopenPrompt? = nil,completion:@escaping(Result<Void,Error>)->Void) {
        guard privateExtensionReopenJob == nil else {completion(.failure(ProfileError.busy));return}
        do {
            let source = try PrivateExtensionReopenSource(client:self,window:window)
            guard #available(macOS 15.4,*) else {throw ExtensionHostError.unavailable}
            let target = try NativePrivateExtensionReopenTarget(client:self,owner:owner,profileID:profileID)
            beginPrivateExtensionReopen(source:source,destination:target.destination,confirmation:confirmation ?? .live,completion:completion)
        } catch {completion(.failure(error))}
    }
    func requestReopenPrivateWithoutExtensions(from window:NSWindow,confirmation:PrivateExtensionReopenPrompt? = nil,completion:@escaping(Result<Void,Error>)->Void) {
        guard privateExtensionReopenJob == nil else {completion(.failure(ProfileError.busy));return}
        do {
            guard extensionHosting != nil else {throw ExtensionHostError.stale}
            let source = try PrivateExtensionReopenSource(client:self,window:window)
            beginPrivateExtensionReopen(source:source,destination:.without,confirmation:confirmation ?? .live,completion:completion)
        } catch {completion(.failure(error))}
    }
    private func beginPrivateExtensionReopen(source:PrivateExtensionReopenSource,destination:PrivateExtensionReopenDestination,confirmation:PrivateExtensionReopenPrompt,completion:@escaping(Result<Void,Error>)->Void) {
        let job = PrivateExtensionReopenJob(source:source,destination:destination,completion:completion)
        privateExtensionReopenJob = job;job.start(prompt:confirmation,duration:privateExtensionReopenTimeout)
    }
    func reconcilePrivateExtensionReopen() {if let job = privateExtensionReopenJob,!job.committing,!job.current {job.finish(.failure(ExtensionHostError.stale))}}
}

@available(macOS 15.4,*) @MainActor final class NativePrivateExtensionReopenTarget {
    private weak var client:BrowserStore?
    private let owner:BrowserWindowOwner,server:NativeBrowserExtensionHost,profileID:UUID,controllerID:UUID,epoch:UUID,metadata:MetadataOwnershipLease,records:[BrowserExtensionRecord],lease:UUID,profileName:String
    private var prepared:AssociatedPrivateExtensionHost?,adopted = false,closed = false
    init(client:BrowserStore,owner:BrowserWindowOwner,profileID:UUID) throws {
        let normal = owner.store
        guard client.isPrivate,!client.isShuttingDown,!owner.isClosed,!normal.isPrivate,!normal.isShuttingDown,
              !normal.awaitingInitialMetadata,normal.vault != nil,!normal.profileUnavailable(profileID),
              let profile = normal.profiles.first(where:{$0.id == profileID}),let controllerID = profile.extensionControllerID,
              let metadata = normal.metadataOwnership,let server = normal.ensureExtensionHost() as? NativeBrowserExtensionHost else {throw ProfileError.locked}
        try metadata.validate()
        let records = normal.extensionRecords(profileID:profileID)
        guard records.contains(where:{$0.enabled && $0.pendingRemoval != true && $0.grants?.allowPrivate == true}) else {throw ExtensionActionError.invalidApproval}
        self.client = client;self.owner = owner;self.server = server;self.profileID = profileID;self.controllerID = controllerID
        self.metadata = metadata;self.records = records;profileName = profile.name;epoch = normal.extensionReviewEpoch(for:profileID)
        lease = try owner.acquireAuxiliary()
    }
    var current:Bool {
        let normal = owner.store
        return !closed && client?.isShuttingDown == false && !owner.isClosed && !normal.isShuttingDown && !normal.awaitingInitialMetadata &&
            normal.vault != nil && !normal.profileUnavailable(profileID) && normal.extensionHosting === server && normal.metadataOwnership === metadata &&
            (try? metadata.validate()) != nil && normal.profiles.first(where:{$0.id == profileID})?.extensionControllerID == controllerID &&
            normal.extensionReviewEpoch(for:profileID) == epoch && normal.extensionRecords(profileID:profileID) == records
    }
    var destination:PrivateExtensionReopenDestination {
        PrivateExtensionReopenDestination(profileName:profileName,usesExtensions:true,current:{self.current},prepare:{
            guard self.current else {throw ExtensionHostError.stale}
            try await self.server.prepare(profileID:self.profileID);try Task.checkCancellation()
            guard self.current,let client = self.client else {throw ExtensionHostError.stale}
            self.prepared = AssociatedPrivateExtensionHost(client:client,owner:self.owner,server:self.server,profileID:self.profileID,controllerID:self.controllerID,lease:self.lease)
        },publish:{client in
            guard let prepared = self.prepared else {preconditionFailure("Private association must be prepared before publication")}
            self.adopted = true;client.extensionHosting = prepared
            self.server.privateClients[client.extensionStoreID] = NativePrivateExtensionClient(store:client,association:prepared,profileID:self.profileID)
        },close:{
            guard !self.closed else {return};self.closed = true
            if !self.adopted {self.owner.release(self.lease)}
            self.prepared = nil
        })
    }
}
