import AppKit
import WebKit

/// Browser and native editing shortcuts take priority. Only otherwise unclaimed
/// shortcuts may reach the extension attached to this window's foreground page.
@MainActor class ExtensionCommandWindow:NSWindow {
    weak var extensionStore:BrowserStore?
    var extensionCommandSource:(()->WKWebView?)?
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if super.performKeyEquivalent(with:event) {return true}
        guard attachedSheet==nil,isKeyWindow,
              !(firstResponder is NSTextView),!(firstResponder is NSTextField),
              (firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              !Self.menuClaims(event,in:NSApp.mainMenu),
              let store=extensionStore,!store.commandVisible,!store.onboardingVisible,store.presentedPanel==nil,
              let web=extensionCommandSource?(),web.window === self else {return false}
        do {return try store.performExtensionCommand(for:event,from:web,anchor:web)}
        catch {store.message=error.localizedDescription;return false}
    }
    private static func menuClaims(_ event:NSEvent,in menu:NSMenu?) -> Bool {
        guard let menu else {return false}
        let flags:NSEvent.ModifierFlags=[.command,.control,.option,.shift]
        let key=event.charactersIgnoringModifiers?.lowercased()
        for item in menu.items {
            if !item.keyEquivalent.isEmpty,item.keyEquivalent.lowercased()==key,
               item.keyEquivalentModifierMask.intersection(flags)==event.modifierFlags.intersection(flags) {return true}
            if menuClaims(event,in:item.submenu) {return true}
        }
        return false
    }
}
