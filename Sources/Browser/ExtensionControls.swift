import AppKit
import SwiftUI
import WebKit
import BrowserCore

@MainActor private enum ExtensionNativeMenus {
    static func append(_ group:BrowserExtensionMenuGroup,to menu:NSMenu,label:String?=nil) {
        let title=label ?? group.label
        // WebKit may already return an extension-name parent. Keep that real
        // hierarchy rather than wrapping it in a second identical parent.
        if group.items.count==1,let root=group.items.first,root.title==group.label,root.submenu != nil {
            root.title=title;menu.addItem(root)
        } else {
            let submenu=NSMenu(title:title);submenu.autoenablesItems=false
            for item in group.items {submenu.addItem(item)}
            let parent=NSMenuItem(title:title,action:nil,keyEquivalent:"");parent.submenu=submenu;menu.addItem(parent)
        }
    }
}

@MainActor final class ExtensionTabMenuAnchor:ObservableObject {
    weak var view:NSView?
    func show(store:BrowserStore,tabID:UUID) {
        guard let view,let window=view.window else {return}
        // Let the sidebar's own context menu finish tracking before presenting
        // native items. Resolve their latest state for the requested tab now.
        DispatchQueue.main.async {[weak self,weak store,weak view,weak window] in
            MainActor.assumeIsolated {
                guard let self,let store,let view,let window,self.view === view,view.window === window,
                      !store.isShuttingDown,window.isKeyWindow,window.attachedSheet==nil,
                      store.extensionWindows.values.contains(where:{$0.window === window}) else {return}
                let menu=NSMenu(title:"Extension Tab Actions");menu.autoenablesItems=false
                for group in store.extensionContextMenuGroups(for:.tab(tabID)) where !group.items.isEmpty {
                    ExtensionNativeMenus.append(group,to:menu)
                }
                if menu.items.isEmpty {
                    let item=NSMenuItem(title:"No extension actions for this tab",action:nil,keyEquivalent:"");item.isEnabled=false;menu.addItem(item)
                }
                menu.popUp(positioning:nil,at:NSPoint(x:view.bounds.midX,y:view.bounds.maxY),in:view)
            }
        }
    }
}
struct ExtensionTabAnchorReader:NSViewRepresentable {
    let anchor:ExtensionTabMenuAnchor
    func makeNSView(context:Context)->NSView {let view=NSView();anchor.view=view;return view}
    func updateNSView(_ view:NSView,context:Context) {anchor.view=view}
}

/// AppKit supplies the actual popup anchor and preserves the native extension
/// menu hierarchy. Resolve action state each time the user opens this menu.
struct ExtensionControls:NSViewRepresentable {
    @ObservedObject var store:BrowserStore
    let web:WKWebView?
    var profileID:UUID?=nil
    func makeCoordinator() -> Coordinator {Coordinator()}
    func makeNSView(context:Context) -> NSButton {
        let button=NSButton(image:NSImage(systemSymbolName:"puzzlepiece.extension",accessibilityDescription:"Extensions")!,target:context.coordinator,action:#selector(Coordinator.open(_:)))
        button.isBordered=false;button.bezelStyle = .texturedRounded;button.imageScaling = .scaleProportionallyDown
        button.toolTip="Extensions";button.setAccessibilityLabel("Extensions")
        context.coordinator.button=button
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.store=store;context.coordinator.web=web;context.coordinator.profileID=profileID
        button.isEnabled = !store.isShuttingDown
    }
    @MainActor final class Coordinator:NSObject {
        weak var store:BrowserStore?,web:WKWebView?,button:NSButton?
        var profileID:UUID?
        private var actions:[UUID:()->Void]=[:]
        private func item(_ title:String,enabled:Bool=true,action:@escaping()->Void) -> NSMenuItem {
            let id=UUID(),item=NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=id;item.isEnabled=enabled;actions[id]=action;return item
        }
        @objc private func invoke(_ item:NSMenuItem) {if let id=item.representedObject as? UUID {actions[id]?()}}
        @objc func open(_ sender:NSButton) {
            guard let store,let source=sender.window,source.attachedSheet==nil else {return}
            actions.removeAll()
            let menu=NSMenu(title:"Extensions");menu.autoenablesItems=false
            if let web,web.window === source,store.isVisibleWebsite(web) {
                let actions=store.extensionActionSummaries(for:web)
                for action in actions {
                    let title=action.label+(action.badge.isEmpty ? "":" · "+action.badge)
                    let item=item(title,enabled:action.isEnabled){[weak self,weak store,weak web,weak source] in
                        guard let self,let store,let web,let source,let button=self.button,button.window === source,web.window === source else {return}
                        do {try store.performExtensionAction(action.id,from:web,anchor:button)} catch {store.message=error.localizedDescription}
                    }
                    item.image=action.icon;menu.addItem(item)
                }
                let commands=store.extensionCommandSummaries(for:web)
                if !commands.isEmpty {
                    let submenu=NSMenu(title:"Commands");submenu.autoenablesItems=false
                    for command in commands {
                        let item=item(command.title){[weak self,weak store,weak web,weak source] in
                            guard let self,let store,let web,let source,let button=self.button,button.window === source,web.window === source else {return}
                            do {try store.performExtensionCommand(command.extensionID,command:command.id,from:web,anchor:button)} catch {store.message=error.localizedDescription}
                        }
                        if let key=command.activationKey {item.keyEquivalent=key;item.keyEquivalentModifierMask=command.modifiers}
                        submenu.addItem(item)
                    }
                    let parent=NSMenuItem(title:"Commands",action:nil,keyEquivalent:"");parent.submenu=submenu;menu.addItem(parent)
                }
                for group in store.extensionContextMenuGroups(for:.view(web)) where !group.items.isEmpty {
                    ExtensionNativeMenus.append(group,to:menu,label:group.label+" Tab Actions")
                }
            }
            if !menu.items.isEmpty {menu.addItem(.separator())}
            let profile=profileID ?? web.flatMap{store.profileID(for:$0)} ?? store.activeProfileID
            menu.addItem(item("Manage Extensions…"){[weak store,weak source] in
                guard let store,let source else {return};store.requestExtensionManager(from:source,profileID:profile)
            })
            menu.popUp(positioning:nil,at:NSPoint(x:sender.bounds.minX,y:sender.bounds.maxY),in:sender)
        }
    }
}
