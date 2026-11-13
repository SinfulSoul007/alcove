import AppKit
import WebKit
import BrowserCore

struct NativeExtensionPermissionReview {
    let extensionName:String,profileName:String,isPrivate:Bool,values:[String]
}
@MainActor struct NativeExtensionPermissionPrompt {
    var present:(NSWindow,NativeExtensionPermissionReview,@escaping(Bool)->Void)->(()->Void)?
    static var live:Self {
        Self(present:{window,review,reply in
            let alert = NSAlert();alert.messageText = "Allow \(review.extensionName) additional access?"
            alert.informativeText = "Profile: \(review.profileName). Access lasts up to five minutes and ends when this source page or window closes.\(review.isPrivate ? " This extension shares its temporary permissions across its approved normal and private pages. Nothing is added to your saved permission choices." : " Your saved permission choices are kept.")"
            alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Allow for 5 Minutes")
            let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:420,height:160))
            scroll.hasVerticalScroller = true;scroll.borderType = .bezelBorder
            let text = NSTextView(frame:scroll.bounds)
            text.isEditable = false;text.isSelectable = true;text.isRichText = false
            text.font = .systemFont(ofSize:13);text.textContainerInset = NSSize(width:8,height:8)
            text.isHorizontallyResizable = false;text.isVerticallyResizable = true
            text.autoresizingMask = [.width];text.textContainer?.widthTracksTextView = true
            text.string = review.values.joined(separator:"\n");text.setAccessibilityLabel("Requested extension access")
            scroll.documentView = text;alert.accessoryView = scroll
            alert.beginSheetModal(for:window){reply($0 == .alertSecondButtonReturn)}
            return { [weak window,weak alert] in
                guard let window,let sheet = alert?.window,sheet.sheetParent === window else {return}
                window.endSheet(sheet,returnCode:.cancel)
            }
        })
    }
}

@available(macOS 15.4,*) enum NativeExtensionPermissionKind {
    case permissions(Set<WKWebExtension.Permission>),urls(Set<URL>),patterns(Set<WKWebExtension.MatchPattern>)
    var values:[String] {
        switch self {
        case .permissions(let values):return values.map(\.rawValue).sorted()
        case .urls(let values):return values.compactMap(Self.sitePattern).sorted()
        case .patterns(let values):return values.map(\.string).sorted()
        }
    }
    private static func sitePattern(_ url:URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),["http","https"].contains(scheme),url.user == nil,url.password == nil,let host = url.host,!host.isEmpty else {return nil}
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        return scheme + "://" + authority + "/*"
    }
    @MainActor func scope(for source:NativeExtensionSource) -> (Set<WKWebExtension.Permission>,Set<WKWebExtension.MatchPattern>)? {
        guard source.current,let context = source.context,let grant = source.record.grants else {return nil}
        switch self {
        case .permissions(let permissions):
            let raw = Set(permissions.map(\.rawValue))
            guard !raw.isEmpty,raw.count <= 128,raw.allSatisfy({$0.utf8.count <= 128}),
                  raw.isSubset(of:Set(source.record.requestedPermissions + source.record.optionalPermissions)),
                  raw.isDisjoint(with:ExtensionCatalog.unavailablePermissions),raw.isDisjoint(with:Set(grant.deniedPermissions ?? [])),
                  permissions.allSatisfy({!context.hasPermission($0)}) else {return nil}
            return (permissions,[])
        case .urls(let urls):
            guard !urls.isEmpty,urls.count <= 128 else {return nil}
            let patterns = urls.compactMap(Self.sitePattern)
            guard patterns.count == urls.count else {return nil}
            return siteScope(patterns,source:source,context:context,grant:grant)
        case .patterns(let patterns):
            guard !patterns.isEmpty,patterns.count <= 128 else {return nil}
            return siteScope(patterns.map(\.string),source:source,context:context,grant:grant)
        }
    }
    @MainActor private func siteScope(_ raw:[String],source:NativeExtensionSource,context:WKWebExtensionContext,grant:ExtensionGrantSet) -> (Set<WKWebExtension.Permission>,Set<WKWebExtension.MatchPattern>)? {
        let declared = (source.record.hostPermissions + source.record.optionalHostPermissions).compactMap(ExtensionMatchPattern.init)
        let denied = (grant.deniedHostPatterns ?? []).compactMap(ExtensionMatchPattern.init)
        let existing = context.grantedPermissionMatchPatterns.keys.compactMap{ExtensionMatchPattern($0.string)}
        var result = Set<WKWebExtension.MatchPattern>()
        for value in raw {
            guard let candidate = ExtensionMatchPattern(value),candidate.schemes.isSubset(of:["http","https"]),
                  declared.contains(where:{$0.covers(candidate)}),
                  !denied.contains(where:{$0.covers(candidate) || candidate.covers($0)}),
                  !existing.contains(where:{$0.covers(candidate)}),let native = try? WKWebExtension.MatchPattern(string:candidate.string) else {return nil}
            result.insert(native)
        }
        return ([],result)
    }
}

@available(macOS 15.4,*) @MainActor final class NativeExtensionSessionGrant {
    let id = UUID(),source:NativeExtensionSource,expiration:Date
    private let deadline:ContinuousClock.Instant
    let permissions:Set<WKWebExtension.Permission>,patterns:Set<WKWebExtension.MatchPattern>
    private var appliedPermissions:[WKWebExtension.Permission:Date] = [:],appliedPatterns:[WKWebExtension.MatchPattern:Date] = [:]
    private var expiry:Task<Void,Never>?
    init(source:NativeExtensionSource,permissions:Set<WKWebExtension.Permission>,patterns:Set<WKWebExtension.MatchPattern>,expiration:Date) {
        self.source = source;self.permissions = permissions;self.patterns = patterns;self.expiration = expiration
        deadline = ContinuousClock.now.advanced(by:.seconds(min(300,max(0,expiration.timeIntervalSinceNow))))
    }
    func expired(at instant:ContinuousClock.Instant = .now) -> Bool {instant >= deadline || expiration <= Date()}
    func apply() {
        guard let context = source.context else {return}
        for permission in permissions {context.setPermissionStatus(.grantedExplicitly,for:permission,expirationDate:expiration)}
        for pattern in patterns {context.setPermissionStatus(.grantedExplicitly,for:pattern,expirationDate:expiration)}
        // WebKit round-trips dates through Unix time, which can lose sub-microsecond
        // precision. Compare ownership using the actual native value, never the input Date.
        let nativePermissions = context.grantedPermissions,nativePatterns = context.grantedPermissionMatchPatterns
        for permission in permissions {appliedPermissions[permission] = nativePermissions[permission]}
        for pattern in patterns {appliedPatterns[pattern] = nativePatterns[pattern]}
        let deadline = self.deadline
        expiry = Task { @MainActor [weak self] in
            do {try await ContinuousClock().sleep(until:deadline);self?.source.host?.reconcilePermissionRequests()} catch {}
        }
    }
    func revoke() {
        expiry?.cancel();expiry = nil
        guard let context = source.context else {return}
        var allowed = context.grantedPermissions,sites = context.grantedPermissionMatchPatterns
        for (permission,date) in appliedPermissions where allowed[permission] == date {allowed.removeValue(forKey:permission)}
        for (pattern,date) in appliedPatterns where sites[pattern] == date {sites.removeValue(forKey:pattern)}
        context.grantedPermissions = allowed;context.grantedPermissionMatchPatterns = sites
        let activeTab = WKWebExtension.Permission(rawValue:"activeTab")
        if permissions.contains(activeTab),context.isLoaded,!context.hasPermission(activeTab) {
            // A same-origin navigation need not expire WebKit's per-tab gesture. The
            // temporary approval has ended, so its derived tab access must end too.
            for value in context.openTabs as NSSet {
                if let tab = value as? any WKWebExtensionTab {context.clearUserGesture(in:tab)}
            }
        }
    }
}

@available(macOS 15.4,*) @MainActor final class NativeExtensionPermissionTicket {
    let id = UUID(),source:NativeExtensionSource,kind:NativeExtensionPermissionKind
    var dismiss:(()->Void)?
    private var reply:((Bool,Date?)->Void)?,timeout:Task<Void,Never>?
    private var deadline:ContinuousClock.Instant?
    init(source:NativeExtensionSource,kind:NativeExtensionPermissionKind,reply:@escaping(Bool,Date?)->Void) {self.source = source;self.kind = kind;self.reply = reply}
    var pending:Bool {reply != nil}
    func start(duration:Duration) {
        let deadline = ContinuousClock.now.advanced(by:min(.seconds(90),max(.milliseconds(1),duration)))
        self.deadline = deadline
        timeout = Task { @MainActor [weak self] in
            do {try await ContinuousClock().sleep(until:deadline);self?.finish(false)} catch {}
        }
    }
    func finish(_ allowed:Bool) {
        guard let reply else {return}
        self.reply = nil;timeout?.cancel();timeout = nil
        source.host?.permissionTickets.removeValue(forKey:id)
        let dismiss = self.dismiss;self.dismiss = nil;dismiss?()
        guard allowed,deadline.map({ContinuousClock.now < $0}) == true,let host = source.host,let scope = kind.scope(for:source) else {reply(false,nil);return}
        let expiration = Date().addingTimeInterval(300)
        let grant = NativeExtensionSessionGrant(source:source,permissions:scope.0,patterns:scope.1,expiration:expiration)
        host.permissionSessionGrants[grant.id] = grant;grant.apply();reply(true,expiration)
    }
}

@available(macOS 15.4,*) @MainActor extension NativeBrowserExtensionHost {
    func hasApprovedPermission(_ permission:WKWebExtension.Permission,context:WKWebExtensionContext,profileID:UUID) -> Bool {
        guard let owner,authorized(context,profileID:profileID,client:owner),context.hasPermission(permission),
              let id = profiles[profileID]?.contexts.first(where:{$0.value === context})?.key,
              let grant = owner.extensionRecords(profileID:profileID).first(where:{$0.id == id})?.grants,
              grant.deniedPermissions?.contains(permission.rawValue) != true else {return false}
        if grant.permissions.contains(permission.rawValue) {return true}
        return permissionSessionGrants.values.contains {
            $0.source.context === context && $0.source.key.profileID == profileID && $0.source.current && !$0.expired() && $0.permissions.contains(permission)
        }
    }
    func reconcilePermissionRequests(at instant:ContinuousClock.Instant = .now) {
        for ticket in Array(permissionTickets.values) where !ticket.source.current {ticket.finish(false)}
        for grant in Array(permissionSessionGrants.values) where !grant.source.current || grant.expired(at:instant) {grant.revoke();permissionSessionGrants.removeValue(forKey:grant.id)}
    }
    func cancelPermissionRequests() {
        for ticket in Array(permissionTickets.values) {ticket.finish(false)}
        for grant in permissionSessionGrants.values {grant.revoke()};permissionSessionGrants = [:]
    }
    private func reviewPermission(_ kind:NativeExtensionPermissionKind,controller:WKWebExtensionController,tab:(any WKWebExtensionTab)?,context:WKWebExtensionContext,reply:@escaping(Bool,Date?)->Void) {
        reconcilePermissionRequests()
        guard permissionTickets.count < 64,let tab = tab as? NativeExtensionTab,
              let source = NativeExtensionSource(host:self,controller:controller,context:context,tab:tab),kind.scope(for:source) != nil,
              let window = source.window,window.attachedSheet == nil,
              !permissionTickets.values.contains(where:{$0.source.window === window}) else {reply(false,nil);return}
        let ticket = NativeExtensionPermissionTicket(source:source,kind:kind,reply:reply)
        permissionTickets[ticket.id] = ticket;ticket.start(duration:permissionRequestTimeout)
        let review = NativeExtensionPermissionReview(extensionName:source.record.name,profileName:owner?.profiles.first(where:{$0.id == source.key.profileID})?.name ?? "Unavailable",isPrivate:source.client?.isPrivate == true,values:kind.values)
        let dismiss = permissionPrompt.present(window,review){ [weak ticket] in ticket?.finish($0) }
        if ticket.pending {ticket.dismiss = dismiss} else {dismiss?()}
    }
    func webExtensionController(_ controller:WKWebExtensionController,promptForPermissions permissions:Set<WKWebExtension.Permission>,in tab:(any WKWebExtensionTab)?,for context:WKWebExtensionContext,completionHandler:@escaping(Set<WKWebExtension.Permission>,Date?)->Void) {
        reviewPermission(.permissions(permissions),controller:controller,tab:tab,context:context){completionHandler($0 ? permissions : [],$1)}
    }
    func webExtensionController(_ controller:WKWebExtensionController,promptForPermissionToAccess urls:Set<URL>,in tab:(any WKWebExtensionTab)?,for context:WKWebExtensionContext,completionHandler:@escaping(Set<URL>,Date?)->Void) {
        reviewPermission(.urls(urls),controller:controller,tab:tab,context:context){completionHandler($0 ? urls : [],$1)}
    }
    func webExtensionController(_ controller:WKWebExtensionController,promptForPermissionMatchPatterns patterns:Set<WKWebExtension.MatchPattern>,in tab:(any WKWebExtensionTab)?,for context:WKWebExtensionContext,completionHandler:@escaping(Set<WKWebExtension.MatchPattern>,Date?)->Void) {
        reviewPermission(.patterns(patterns),controller:controller,tab:tab,context:context){completionHandler($0 ? patterns : [],$1)}
    }
}
