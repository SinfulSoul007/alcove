import AppKit
import WebKit
import BrowserCore

struct BrowserExtensionCommandSummary {
    let extensionID:UUID,id:String,title:String,activationKey:String?,modifiers:NSEvent.ModifierFlags
}
enum BrowserExtensionTabTarget {case tab(UUID),view(WKWebView)}
struct BrowserExtensionMenuGroup:Identifiable {let id:UUID,label:String,items:[NSMenuItem]}

extension BrowserStore {
    func extensionCommandSummaries(for web:WKWebView) -> [BrowserExtensionCommandSummary] {
        guard let profile = profileID(for:web),!profileUnavailable(profile) else {return []}
        return extensionHosting?.commandSummaries(for:web,profileID:profile) ?? []
    }
    func performExtensionCommand(_ id:UUID,command:String,from web:WKWebView,anchor:NSView) throws {
        guard !isShuttingDown,let profile = profileID(for:web),!profileUnavailable(profile),let host = ensureExtensionHost() else {throw ExtensionHostError.stale}
        try host.performCommand(id,command:command,from:web,profileID:profile,anchor:anchor)
    }
    func performExtensionCommand(for event:NSEvent,from web:WKWebView,anchor:NSView) throws -> Bool {
        guard !isShuttingDown,let profile = profileID(for:web),!profileUnavailable(profile),let host = extensionHosting else {return false}
        return try host.performCommand(for:event,from:web,profileID:profile,anchor:anchor)
    }
    func extensionContextMenuGroups(for target:BrowserExtensionTabTarget) -> [BrowserExtensionMenuGroup] {
        let profile:UUID?
        switch target {case .tab(let id):profile = profileID(for:id);case .view(let web):profile = profileID(for:web)}
        guard let profile,!isShuttingDown,!profileUnavailable(profile) else {return []}
        return extensionHosting?.contextMenuGroups(for:target,profileID:profile) ?? []
    }
}

/// Retains the real public native item and forwards only while its captured source
/// is current. Never resolve a nil target through another window's responder chain.
@available(macOS 15.4,*) @MainActor final class NativeExtensionGuardedMenuItem:NSMenuItem,NSMenuItemValidation {
    private let source:NativeExtensionSource,original:NSMenuItem,expires:ContinuousClock.Instant
    init(_ original:NSMenuItem,source:NativeExtensionSource,expires:ContinuousClock.Instant,depth:Int,budget:inout Int) {
        self.original = original;self.source = source;self.expires = expires
        super.init(title:original.title,action:nil,keyEquivalent:original.keyEquivalent)
        keyEquivalentModifierMask = original.keyEquivalentModifierMask
        image = original.image;state = original.state;isEnabled = original.isEnabled;isHidden = original.isHidden
        indentationLevel = original.indentationLevel;toolTip = original.toolTip
        if original.action != nil,original.target != nil {action = #selector(invoke);target = self}
        if let originalMenu = original.submenu,depth < 16,budget > 0 {
            let menu = NSMenu(title:originalMenu.title);menu.autoenablesItems = false
            for item in originalMenu.items where budget > 0 {
                budget -= 1
                if item.isSeparatorItem {menu.addItem(.separator())}
                else {menu.addItem(NativeExtensionGuardedMenuItem(item,source:source,expires:expires,depth:depth+1,budget:&budget))}
            }
            submenu = menu
        }
    }
    required init(coder:NSCoder) {fatalError("Native extension menu items are not restored from archives")}
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {source.current && .now < expires && original.isEnabled && !original.isHidden}
    @objc private func invoke(_ sender:NSMenuItem) {
        guard validateMenuItem(self),let action = original.action,let target = original.target else {return}
        NSApp.sendAction(action,to:target,from:original)
    }
}

@available(macOS 15.4,*) @MainActor extension NativeBrowserExtensionHost {
    func commandSummaries(for web:WKWebView,profileID:UUID) -> [BrowserExtensionCommandSummary] {
        guard let owner else {return []};return commandSummaries(for:web,profileID:profileID,client:owner)
    }
    func commandSummaries(for web:WKWebView,profileID:UUID,client:BrowserStore) -> [BrowserExtensionCommandSummary] {
        guard let runtime = profiles[profileID],let tab = tabsByView[ObjectIdentifier(web)],tab.web === web,tab.key.storeID == client.extensionStoreID,tab.key.profileID == profileID else {return []}
        return owner?.extensionRecords(profileID:profileID).flatMap {record -> [BrowserExtensionCommandSummary] in
            guard let context = runtime.contexts[record.id],tab.live(context) === client else {return []}
            return context.commands.map{BrowserExtensionCommandSummary(extensionID:record.id,id:$0.id,title:$0.title,activationKey:$0.activationKey,modifiers:$0.modifierFlags)}
        } ?? []
    }
    func performCommand(_ id:UUID,command:String,from web:WKWebView,profileID:UUID,anchor:NSView) throws {
        guard let owner else {throw ExtensionHostError.closed};try performCommand(id,command:command,from:web,profileID:profileID,client:owner,anchor:anchor)
    }
    func performCommand(_ id:UUID,command:String,from web:WKWebView,profileID:UUID,client:BrowserStore,anchor:NSView) throws {
        synchronizeBrowserState()
        guard let runtime = profiles[profileID],let context = runtime.contexts[id],let tab = tabsByView[ObjectIdentifier(web)],
              tab.key.storeID == client.extensionStoreID,tab.key.profileID == profileID,tab.web === web,
              let source = NativeExtensionSource(host:self,controller:runtime.controller,context:context,tab:tab),source.current,
              let window = tab.browserWindow,window.isFocusedInClient,window.activeKey == tab.key,
              context.focusedWindow === window,anchor.window === source.window,source.window?.attachedSheet == nil,
              let actual = context.commands.first(where:{$0.id == command}),actual.webExtensionContext === context else {throw ExtensionHostError.stale}
        if ["_execute_action","_execute_browser_action","_execute_page_action"].contains(command) {
            try performAction(id,from:web,profileID:profileID,client:client,anchor:anchor)
        } else {context.performCommand(actual)}
    }
    func performCommand(for event:NSEvent,from web:WKWebView,profileID:UUID,anchor:NSView) throws -> Bool {
        guard let owner else {return false};return try performCommand(for:event,from:web,profileID:profileID,client:owner,anchor:anchor)
    }
    func performCommand(for event:NSEvent,from web:WKWebView,profileID:UUID,client:BrowserStore,anchor:NSView) throws -> Bool {
        guard event.type == .keyDown,!event.isARepeat,event.windowNumber == web.window?.windowNumber,
              let runtime = profiles[profileID],let tab = tabsByView[ObjectIdentifier(web)],tab.key.storeID == client.extensionStoreID,tab.key.profileID == profileID,tab.web === web else {return false}
        let relevant:NSEvent.ModifierFlags = [.command,.control,.option,.shift]
        let matches = runtime.contexts.compactMap {id,context -> (UUID,WKWebExtension.Command)? in
            guard tab.live(context) === client,let command = context.command(for:event),command.modifierFlags.intersection(relevant) == event.modifierFlags.intersection(relevant) else {return nil}
            return (id,command)
        }
        guard matches.count == 1,let match = matches.first else {return false}
        try performCommand(match.0,command:match.1.id,from:web,profileID:profileID,client:client,anchor:anchor);return true
    }
    func contextMenuGroups(for target:BrowserExtensionTabTarget,profileID:UUID) -> [BrowserExtensionMenuGroup] {
        guard let owner else {return []};return contextMenuGroups(for:target,profileID:profileID,client:owner)
    }
    func contextMenuGroups(for target:BrowserExtensionTabTarget,profileID:UUID,client:BrowserStore) -> [BrowserExtensionMenuGroup] {
        synchronizeBrowserState()
        guard let runtime = profiles[profileID] else {return []}
        let tab:NativeExtensionTab?
        switch target {
        case .tab(let id):tab = nativeTabs[NativeExtensionTabKey(storeID:client.extensionStoreID,profileID:profileID,id:id,isPeek:false)]
        case .view(let web):tab = tabsByView[ObjectIdentifier(web)].flatMap{$0.web === web ? $0 : nil}
        }
        guard let tab,tab.key.storeID == client.extensionStoreID,tab.key.profileID == profileID else {return []}
        var budget = 256
        let expires = ContinuousClock.now.advanced(by:.seconds(90))
        return owner?.extensionRecords(profileID:profileID).compactMap {record in
            guard budget > 0,let context = runtime.contexts[record.id],tab.live(context) === client,
                  let source = NativeExtensionSource(host:self,controller:runtime.controller,context:context,tab:tab,requiresMountedView:false) else {return nil}
            var items:[NSMenuItem] = []
            for item in context.menuItems(for:tab) where budget > 0 {
                budget -= 1
                if item.isSeparatorItem {items.append(.separator())}
                else {items.append(NativeExtensionGuardedMenuItem(item,source:source,expires:expires,depth:0,budget:&budget))}
            }
            return items.isEmpty ? nil : BrowserExtensionMenuGroup(id:record.id,label:record.name,items:items)
        } ?? []
    }
}
