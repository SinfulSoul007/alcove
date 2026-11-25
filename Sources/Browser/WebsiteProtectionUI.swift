import AppKit
import Combine
import WebKit
import BrowserCore

@MainActor final class WebsiteProtectionOverlay:NSView {
    private final class Content:NSView {override var isFlipped:Bool {true}}
    @MainActor private final class Actions:NSObject {
        weak var ticket:WebsiteProtectionTicket?
        let revision:UUID
        init(ticket:WebsiteProtectionTicket) {self.ticket=ticket;revision=ticket.revision}
        @objc func goBack() {guard let ticket,ticket.revision==revision else {return};ticket.cancel()}
        @objc func openAnyway() {ticket?.approve(expectedRevision:revision)}
    }
    private var actions:Actions?

    private weak var store:BrowserStore?,web:WKWebView?,ticket:WebsiteProtectionTicket?
    private var subscription:AnyCancellable?,boundRevision=UUID()
    private let scroll=NSScrollView(),content=Content()
    private let heading=NSTextField(wrappingLabelWithString:""),body=NSTextField(wrappingLabelWithString:"")
    private let hostname=NSTextField(wrappingLabelWithString:""),provenance=NSTextField(wrappingLabelWithString:"")
    private var safe=NSButton(title:"Go back",target:nil,action:nil)
    private var proceed=NSButton(title:"Open anyway",target:nil,action:nil)
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true
        identifier=NSUserInterfaceItemIdentifier("AlcoveWebsiteProtection");isHidden=true
        heading.font = .preferredFont(forTextStyle:.title2)
        body.font = .preferredFont(forTextStyle:.body)
        hostname.font = .monospacedSystemFont(ofSize:NSFont.preferredFont(forTextStyle:.body).pointSize,weight:.medium)
        hostname.lineBreakMode = .byCharWrapping
        provenance.font = .preferredFont(forTextStyle:.caption1);provenance.textColor = .secondaryLabelColor
        for label in [heading,body,hostname,provenance] {label.isSelectable=true;content.addSubview(label)}
        scroll.documentView=content;scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        addSubview(scroll)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is unavailable")}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();refresh()}
    override func viewDidMoveToSuperview() {super.viewDidMoveToSuperview();refresh()}
    func bind(store:BrowserStore,web:WKWebView) {
        if self.store !== store || self.web !== web {
            self.store=store;self.web=web;subscription?.cancel()
            subscription=store.objectWillChange.sink{[weak self] in Task{@MainActor in self?.refresh()}}
        }
        refresh()
    }
    private func invalidateControls() {
        for button in [safe,proceed] {button.target=nil;button.action=nil;button.isEnabled=false}
        actions=nil
    }
    private func replaceControls(for ticket:WebsiteProtectionTicket) {
        invalidateControls()
        safe.removeFromSuperview();proceed.removeFromSuperview()
        safe=NSButton(title:"Go back",target:nil,action:nil)
        proceed=NSButton(title:"Open anyway",target:nil,action:nil)
        let binding=Actions(ticket:ticket);actions=binding
        for button in [safe,proceed] {button.bezelStyle = .rounded;button.font = .preferredFont(forTextStyle:.body);button.target=binding;addSubview(button)}
        safe.action=#selector(Actions.goBack);safe.keyEquivalent="\r";safe.identifier=NSUserInterfaceItemIdentifier("AlcoveWebsiteProtectionSafe")
        proceed.action=#selector(Actions.openAnyway);proceed.identifier=NSUserInterfaceItemIdentifier("AlcoveWebsiteProtectionContinue")
        safe.nextKeyView=proceed;proceed.nextKeyView=safe
    }
    private func refresh() {
        guard let store,let web,let parent=superview,parent === web.superview,
              let next=store.websiteProtectionTicket(for:web),next.canPresent else {ticket=nil;invalidateControls();isHidden=true;return}
        let changed=ticket !== next || boundRevision != next.revision || isHidden
        if changed {replaceControls(for:next)}
        ticket=next;boundRevision=next.revision;isHidden=false;next.presented(in:self)
        hostname.stringValue=WebOrigin(next.url)?.host ?? "This website"
        safe.title="Go back";proceed.title="Open anyway";proceed.isHidden=false
        if case .download=next.kind {safe.title="Cancel";proceed.title="Continue"}
        switch next.assessment {
        case .none:
            heading.stringValue="Checking website…"
            body.stringValue="Alcove is keeping your current page while it checks this address."
            provenance.stringValue="";proceed.isHidden=true
        case .listed(_,let source,let stale):
            switch next.kind {
            case .download:heading.stringValue="Download blocked"
            case .navigation(let main):heading.stringValue=main ? "Website blocked":"Embedded page blocked"
            }
            body.stringValue="This address appears on a phishing list. Opening it could put your information at risk."
            provenance.stringValue=source.provider+" · Updated "+DateFormatter.localizedString(from:source.sourceUpdatedAt,dateStyle:.medium,timeStyle:.none)+(stale ? "\nThis list is more than 30 days old.":"")
        case .unavailable(let failure):
            heading.stringValue="Website check unavailable"
            body.stringValue=failure.message+" You can go back, or open this address anyway."
            provenance.stringValue="This website has not been checked."
        case .unlisted:
            isHidden=true;return
        }
        safe.nextKeyView=proceed.isHidden ? safe:proceed
        if changed,let window,window.isKeyWindow,
           !((window.firstResponder as? NSTextView)?.isFieldEditor ?? false) {window.makeFirstResponder(safe)}
        needsLayout=true;needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {NSColor.windowBackgroundColor.setFill();bounds.fill()}
    override func layout() {
        super.layout()
        let width=max(1,min(540,bounds.width-24)),x=(bounds.width-width)/2
        let buttonHeight=max(30,(safe.font?.pointSize ?? 13)+16),gap:CGFloat=8
        let vertical = !proceed.isHidden && width<360
        let footerHeight=vertical ? buttonHeight*2+gap:buttonHeight
        let footerY=max(0,bounds.height-footerHeight-12)
        if vertical {
            safe.frame=NSRect(x:x,y:footerY,width:width,height:buttonHeight)
            proceed.frame=NSRect(x:x,y:footerY+buttonHeight+gap,width:width,height:buttonHeight)
        } else {
            let buttonWidth=proceed.isHidden ? width:(width-gap)/2
            safe.frame=NSRect(x:x,y:footerY,width:buttonWidth,height:buttonHeight)
            proceed.frame=NSRect(x:x+buttonWidth+gap,y:footerY,width:buttonWidth,height:buttonHeight)
        }
        let top:CGFloat=bounds.height>400 ? 24:10
        scroll.frame=NSRect(x:x,y:top,width:width,height:max(0,footerY-top-12))
        let textWidth=max(1,scroll.contentSize.width-4)
        var y:CGFloat=0
        for label in [heading,body,hostname,provenance] {
            guard !label.stringValue.isEmpty else {label.frame = .zero;continue}
            let measured=label.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:textWidth,height:10_000)).height ?? 24
            let height=max(20,min(10_000,ceil(measured)))
            label.frame=NSRect(x:0,y:y,width:textWidth,height:height);y += height+14
        }
        content.frame=NSRect(x:0,y:0,width:scroll.contentSize.width,height:max(y,scroll.contentSize.height))
    }
    override func cancelOperation(_ sender:Any?) {ticket?.cancel()}
    override func keyDown(with event:NSEvent) {
        if [36,53,76].contains(event.keyCode) {ticket?.cancel()} else {super.keyDown(with:event)}
    }
    override func mouseDown(with event:NSEvent) {window?.makeFirstResponder(safe)}
}
