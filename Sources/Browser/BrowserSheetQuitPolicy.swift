import AppKit
import SwiftUI

extension BrowserPanel {
    var preventsApplicationTerminationWhenModal: Bool {
        switch self {
        case .library, .settings, .siteSearch, .links, .appearance, .profiles, .updates: false
        case .boosts, .spaces: true
        }
    }
}

/// Informational panels allow normal termination; native confirmations keep their own policy.
struct BrowserSheetQuitPolicy: NSViewRepresentable {
    let preventsTermination: Bool
    func makeNSView(context: Context) -> Host { Host(preventsTermination: preventsTermination) }
    func updateNSView(_ view: Host, context: Context) { view.setPolicy(preventsTermination) }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.shutdown() }

    final class Host: NSView {
        private final class Lease: NSObject {
            let original: Bool
            var owners: [UUID: Bool] = [:]
            init(original: Bool) { self.original = original }
        }
        private static let leases = NSMapTable<NSWindow, Lease>.weakToStrongObjects()
        private let owner = UUID()
        private var preventsTermination: Bool
        private var active = true
        private weak var leasedWindow: NSWindow?
        private var observations: [NSObjectProtocol] = []

        init(preventsTermination: Bool) {
            self.preventsTermination = preventsTermination
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func setPolicy(_ value: Bool) { preventsTermination = value; apply() }
        private func scheduleApply() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        private func apply() {
            guard active, let window, window.sheetParent != nil else { releaseLease(); return }
            if leasedWindow !== window { releaseLease(); leasedWindow = window }
            let lease = Self.leases.object(forKey: window) ?? Lease(original: window.preventsApplicationTerminationWhenModal)
            lease.owners[owner] = preventsTermination
            Self.leases.setObject(lease, forKey: window)
            // During a SwiftUI handoff, a draft-protecting owner takes precedence.
            window.preventsApplicationTerminationWhenModal = lease.owners.values.contains(true)
        }
        private func releaseLease() {
            guard let window = leasedWindow else { return }
            leasedWindow = nil
            guard let lease = Self.leases.object(forKey: window) else { return }
            lease.owners.removeValue(forKey: owner)
            if lease.owners.isEmpty {
                window.preventsApplicationTerminationWhenModal = lease.original
                Self.leases.removeObject(forKey: window)
            } else { window.preventsApplicationTerminationWhenModal = lease.owners.values.contains(true) }
        }
        private func stopObserving() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { stopObserving(); releaseLease() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard active, let window else { releaseLease(); return }
            for (name, object) in [(NSWindow.willBeginSheetNotification, nil), (NSWindow.didBecomeKeyNotification, window), (NSWindow.didEndSheetNotification, nil)] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.didEndSheetNotification { self?.apply() }
                        self?.scheduleApply()
                    }
                })
            }
            // SwiftUI may attach the native view before it attaches the sheet to its parent.
            scheduleApply()
        }
        func shutdown() { active = false; stopObserving(); releaseLease() }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}
