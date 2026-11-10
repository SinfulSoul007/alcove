import AppKit
import BrowserCore

@MainActor struct BoostJavaScriptPrompt {
    var confirm: (NSWindow, String, String, String, @escaping (Bool) -> Void) -> Void
    static func makeAlert(title: String, detail: String, code: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.alertStyle = .critical
        alert.icon = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Website JavaScript")
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Allow JavaScript")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.string = code; text.setAccessibilityLabel("JavaScript to approve")
        scroll.documentView = text; alert.accessoryView = scroll
        return alert
    }
    static var live: Self {
        Self(confirm: { window, title, detail, code, reply in
            makeAlert(title: title, detail: detail, code: code).beginSheetModal(for: window) { reply($0 == .alertSecondButtonReturn) }
        })
    }
}
@MainActor final class BoostApprovalJob {
    let request: BoostJavaScriptRequest
    weak var window: NSWindow?
    var closing: NSObjectProtocol?
    init(_ request: BoostJavaScriptRequest, window: NSWindow) { self.request = request; self.window = window }
}
extension BrowserStore {
    func finishBoostApproval(_ job: BoostApprovalJob, cancelled: Bool = false) {
        if let closing = job.closing { NotificationCenter.default.removeObserver(closing); job.closing = nil }
        if let key = boostApprovalJobs.first(where: { $0.value === job })?.key { boostApprovalJobs.removeValue(forKey: key) }
        if cancelled { job.request.consumed = true }
    }
    func cancelBoostApprovals() { for job in Array(boostApprovalJobs.values) { finishBoostApproval(job, cancelled: true) } }
    func requestBoostJavaScriptApproval(_ id: UUID, source: BoostEditSource, prompt: BoostJavaScriptPrompt? = nil, onApproved: (() -> Void)? = nil, onError: ((Error) -> Void)? = nil) {
        func report(_ error: Error) { if let onError { onError(error) } else { message = error.localizedDescription } }
        do {
            guard canEditBoosts, source.matches(self), let window = source.window,
                  let boost = boostCatalog(profileID: source.profileID).entries.first(where: { $0.id == id }),
                  boost.content.host == source.host, !boost.content.javascript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BoostError.stale }
            _ = try BoostScript.validatedBody(boost.content.javascript)
            let key = ObjectIdentifier(window)
            guard boostApprovalJobs[key] == nil,
                  window.attachedSheet == nil || (presentedPanel == .boosts && boostEditor?.source === source) else { throw ProfileError.busy }
            let request = BoostJavaScriptRequest(source: source, boost: boost), job = BoostApprovalJob(request, window: window)
            boostApprovalJobs[key] = job
            job.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak job] _ in
                MainActor.assumeIsolated { if let job { self?.finishBoostApproval(job, cancelled: true) } }
            }
            let profile = isPrivate ? "Private" : profiles.first(where: { $0.id == source.profileID })?.name ?? "Unavailable profile"
            let detail = "Profile: \(profile). This script can read and change page data on \(source.host), across HTTP, HTTPS and ports. Approval applies to future page loads. Reloading may be needed to undo script effects.\(isPrivate ? " Approval is temporary in this private window." : "")"
            (prompt ?? .live).confirm(window, "Allow JavaScript on \(source.host)?", detail, boost.content.javascript) { [weak self, weak job] allowed in
                guard let self, let job, self.boostApprovalJobs[key] === job else { return }
                self.finishBoostApproval(job, cancelled: !allowed)
                guard allowed else { return }
                do {
                    guard let window = job.window, source.window === window else { throw BoostError.stale }
                    try self.approveBoostJavaScript(request); onApproved?()
                } catch { if let onError { onError(error) } else { self.message = error.localizedDescription } }
            }
        } catch { report(error) }
    }
}
