import AppKit
import Combine
import WebKit
import BrowserCore

@MainActor private final class ExtensionRecoveryDocument:NSView {
    override var isFlipped:Bool {true}
}
@MainActor private final class ExtensionRecoveryButton:NSButton {
    var invoke:(()->Void)?
    init(_ title:String,identifier:String,action:@escaping()->Void) {
        super.init(frame:.zero);self.title=title;self.identifier=NSUserInterfaceItemIdentifier("extension.recovery."+identifier)
        bezelStyle = .rounded;target=self;self.action=#selector(pressed)
        cell?.wraps=true;cell?.lineBreakMode = .byWordWrapping;invoke=action
    }
    required init?(coder:NSCoder) {return nil}
    @objc private func pressed() {invoke?()}
}

/// This overlay never replaces or shrinks the WKWebView. Each native button
/// captures a particular page/problem, so a queued click cannot target a newer one.
@MainActor final class ExtensionRecoveryBanner:NSVisualEffectView {
    private weak var store:BrowserStore?,web:WKWebView?,container:EdgeToEdgeWebHost?
    private var subscription:AnyCancellable?,worker:Task<Void,Never>?
    private let scroll=NSScrollView(),document=ExtensionRecoveryDocument(),titleLabel=NSTextField(labelWithString:""),detail=NSTextField(wrappingLabelWithString:"")
    private var controls:[NSButton]=[],key="",scale=1.0,busy=false
    init(container:EdgeToEdgeWebHost) {
        self.container=container;super.init(frame:.zero)
        identifier=NSUserInterfaceItemIdentifier("extension.recovery.banner")
        material = .popover;blendingMode = .withinWindow;state = .active
        wantsLayer=true;layer?.cornerRadius=10;layer?.masksToBounds=true
        scroll.drawsBackground=false;scroll.borderType = .noBorder;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        scroll.documentView=document;addSubview(scroll)
        titleLabel.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines=0;detail.isSelectable=true
        document.addSubview(titleLabel);document.addSubview(detail);isHidden=true
    }
    required init?(coder:NSCoder) {return nil}
    func bind(store:BrowserStore,webView:WKWebView) {
        if self.store !== store {
            subscription?.cancel();self.store=store
            subscription=store.objectWillChange.sink {[weak self] _ in Task {@MainActor [weak self] in self?.refresh()}}
        }
        if web !== webView {web=webView;key=""}
        refresh()
    }
    func refresh() {
        guard let store,let web,!store.isShuttingDown,let profile=store.profileID(for:web),let host=store.extensionHosting else {isHidden=true;return}
        let problem=store.extensionNavigationProblem.flatMap{$0.source.web === web && $0.source.currentWeb != nil ? $0:nil}
        let title:String,text:String,mode:String
        if let problem {
            title=problem.recoveryNotice==nil ? "Extensions need attention":"Page kept"
            text=problem.recoveryNotice ?? (problem.detail+" Your current page and form have been kept.")
            mode=problem.recoveryNotice==nil ? "problem":"notice"
        } else {
            switch store.extensionStates[profile] {
            case .failed(let reason):title="Extensions are not running";text=reason;mode="status"
            case .preparing:title="Starting extensions…";text="Your existing page stays mounted while setup finishes.";mode="preparing"
            default:isHidden=true;key="";return
            }
        }
        scale=store.appearance.normalized.textScale
        let source=problem?.source ?? ExtensionNavigationSource(store:store,web:web,host:host,profileID:profile)
        let next=[mode,problem?.id.uuidString ?? "",source.document.uuidString,source.epoch.uuidString,title,text,String(scale),String(busy)].joined(separator:"|")
        isHidden=false
        guard key != next else {container?.layoutRecovery();return};key=next
        titleLabel.stringValue=title;detail.stringValue=text;detail.toolTip=text
        titleLabel.font = .systemFont(ofSize:12*scale,weight:.semibold);detail.font = .systemFont(ofSize:11*scale)
        for button in controls {button.removeFromSuperview()};controls=[]
        func add(_ label:String,_ id:String,_ accessibility:String?=nil) {
            let expectedNotice=problem?.recoveryNotice,requiresProblem=problem != nil
            let button=ExtensionRecoveryButton(label,identifier:id) {[weak self,weak store,weak problem] in
                guard let self,let store,!self.busy,source.currentWeb != nil,
                      !requiresProblem || (problem != nil && store.extensionNavigationProblem === problem && problem?.recoveryNotice==expectedNotice) else {return}
                self.perform(id,store:store,source:source,problem:problem)
            }
            button.font = .systemFont(ofSize:11*scale);button.isEnabled = !busy
            button.setAccessibilityLabel(accessibility ?? label)
            controls.append(button);document.addSubview(button)
        }
        if mode=="notice" {add("Keep Page","dismiss")}
        else if mode=="preparing" {add("Keep Page","cancel")}
        else {
            add("Retry","retry","Retry extension setup and the original safe navigation")
            if problem != nil,!store.isPrivate {add("Continue Without","without","Continue Without Extensions")}
            add(store.isPrivate ? "Manage / Reload…":"Extensions…","manage")
            if problem != nil {add("Keep Page","dismiss")}
        }
        container?.layoutRecovery()
    }
    private func perform(_ action:String,store:BrowserStore,source:ExtensionNavigationSource,problem:ExtensionNavigationProblem?) {
        switch action {
        case "without":
            guard let problem else {return}
            do {try store.continueWithoutExtensions(expected:problem)} catch {store.message=error.localizedDescription}
            refresh()
        case "dismiss":if let problem {store.dismissExtensionNavigationProblem(problem)};refresh()
        case "cancel":if let web=source.currentWeb {store.cancelExtensionNavigations(for:web)}
        case "manage":if let window=source.currentWeb?.window {store.requestExtensionManager(from:window,profileID:source.profileID)}
        case "retry":
            busy=true;refresh()
            worker=Task {@MainActor [weak self,weak store] in
                guard let store else {return}
                do {
                    if let problem {try await store.retryExtensionNavigation(expected:problem)}
                    else {guard source.currentWeb != nil else {throw ExtensionHostError.stale};try await store.retryExtensions(profileID:source.profileID)}
                } catch {if source.currentWeb != nil {store.message=error.localizedDescription}}
                self?.busy=false;self?.worker=nil;self?.refresh()
            }
        default:break
        }
    }
    func measuredHeight(width:CGFloat,maximum:CGFloat) -> CGFloat {
        let inner=max(20,width-24),font=detail.font ?? NSFont.systemFont(ofSize:11)
        titleLabel.frame=NSRect(x:12,y:10,width:inner,height:ceil(18*scale))
        let textHeight=ceil((detail.stringValue as NSString).boundingRect(with:NSSize(width:inner,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font]).height)+4
        detail.frame=NSRect(x:12,y:titleLabel.frame.maxY+5,width:inner,height:textHeight)
        var y=detail.frame.maxY+8
        for control in controls {
            let h=ceil((control.title as NSString).boundingRect(with:NSSize(width:max(10,inner-16),height:500),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:control.font ?? font]).height)+12
            control.frame=NSRect(x:12,y:y,width:inner,height:max(26,h));y=control.frame.maxY+5
        }
        document.frame=NSRect(x:0,y:0,width:width,height:y+7)
        return min(maximum,y+7)
    }
    override func layout() {super.layout();scroll.frame=bounds}
}
