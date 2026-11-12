import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedExtensionCommandError:Error {case missingFixture,timedOut}
@MainActor final class OwnedExtensionCommandWindow:NSWindow {
    var fixtureKey = true
    override var isKeyWindow:Bool {fixtureKey}
    override func makeKeyAndOrderFront(_ sender:Any?) {}
}
@main struct ExtensionCommandChecks {
    @MainActor static func ready(_ web:WKWebView,_ url:URL) async throws {
        for _ in 0..<700 {
            if web.url == url,!web.isLoading,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw OwnedExtensionCommandError.timedOut
    }
    @MainActor static func eventually(_ web:WKWebView,_ script:String) async throws -> Bool {
        for _ in 0..<700 {
            if (try? await web.callAsyncJavaScript(script,arguments:[:],in:nil,contentWorld:.page)) as? Bool == true {return true}
            try await Task.sleep(for:.milliseconds(10))
        }
        return false
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Extension command fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(),await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedExtensionCommandError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:149,count:32))
        defer {try? manager.removeItem(at:root)}
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func canonical(_ document:BrowserDocument) throws -> Data {let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(document)}
        func invoke(_ item:NSMenuItem) -> Bool {guard let action = item.action,let target = item.target else {return false};return NSApp.sendAction(action,to:target,from:item)}
        func find(_ title:String,in items:[NSMenuItem]) -> NSMenuItem? {
            for item in items {if item.title == title {return item};if let submenu = item.submenu,let nested = find(title,in:submenu.items) {return nested}}
            return nil
        }
        func exercise() async throws {
            let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let owner = BrowserWindowOwner(store:store),primary = try owner.acquirePrimary()
            defer {owner.release(primary)}
            let profile = try store.createProfile(name:"Owned command account")
            try owned.register(profile);try controllers.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let source = root.appendingPathComponent("source")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned commands","version":"1","permissions":["storage","activeTab","contextMenus"],"host_permissions":["http://127.0.0.1/*"],"action":{"default_title":"Owned command action","default_popup":"popup.html"},"commands":{"owned-command":{"suggested_key":{"default":"Ctrl+Shift+Y","mac":"Command+Shift+Y"},"description":"Owned command"},"_execute_action":{"suggested_key":{"default":"Alt+Shift+P"}}},"background":{"service_worker":"background.js"},"options_page":"options.html"}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><body data-owned-extension-page='ready'>Owned options".utf8).write(to:source.appendingPathComponent("options.html"))
            try Data("<!doctype html><body style='width:250px;height:100px'>Owned command popup".utf8).write(to:source.appendingPathComponent("popup.html"))
            try Data("""
            browser.commands.onCommand.addListener(async (id,t)=>{await browser.storage.local.set({ownedCommand:{id,url:t?.url,private:t?.incognito},ownedCommandCount:((await browser.storage.local.get('ownedCommandCount')).ownedCommandCount||0)+1});});
            browser.contextMenus.onClicked.addListener(async (i,t)=>{await browser.storage.local.set({ownedMenu:{id:i.menuItemId,url:t?.url,private:t?.incognito}});});
            browser.contextMenus.create({id:'owned-parent',title:'Owned parent',contexts:['tab']});
            browser.contextMenus.create({id:'owned-child',parentId:'owned-parent',title:'Owned child',contexts:['tab']});
            browser.contextMenus.create({id:'owned-disabled',title:'Owned disabled',contexts:['tab'],enabled:false});
            browser.storage.local.set({ownedMenusReady:true});
            """.utf8).write(to:source.appendingPathComponent("background.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging"))
            let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","activeTab","contextMenus"],hostPatterns:["http://127.0.0.1/*"],allowPrivate:true,enable:true)
            let id = try await store.installExtension(package,approval:approval),url = fixture.appendingPathComponent("command-source"),tabID = store.newTab(url:url),web = store.view(for:tabID)
            try await ready(web,url)
            let window = OwnedExtensionCommandWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = web;store.registerExtensionWindow(window,kind:.primary)
            defer {store.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            let optionsID = try await store.openExtensionOptions(id,profileID:profile),options = store.views[optionsID]!
            let host = store.extensionHosting as! NativeBrowserExtensionHost,context = host.profiles[profile]!.contexts[id]!
            try await ready(options,context.optionsPageURL!);store.select(tabID);host.synchronizeBrowserState()
            check(try await eventually(options,"return (await browser.storage.local.get('ownedMenusReady')).ownedMenusReady === true;"),"The real owned background registers its native commands and tab menus")
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep command form';true")
            let before = try canonical(store.makeDocument()),summaries = store.extensionCommandSummaries(for:web)
            check(summaries.contains{$0.extensionID == id && $0.id == "owned-command" && $0.title == "Owned command" && $0.activationKey?.lowercased() == "y" && $0.modifiers.contains([.command,.shift])},"Command summaries expose actual native titles and shortcuts for the source account")
            try store.performExtensionCommand(id,command:"owned-command",from:web,anchor:web)
            check(try await eventually(options,"const r=await browser.storage.local.get(['ownedCommand','ownedCommandCount']);return r.ownedCommandCount===1 && r.ownedCommand?.id==='owned-command' && r.ownedCommand?.url.endsWith('/command-source') && r.ownedCommand?.private===false;"),"The native command reaches the real background with its actual focused normal tab")
            let after = try canonical(store.makeDocument()),form = try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'keep command form'") as? Bool
            check(before == after && form == true,"Executing a command preserves its source view, unsaved form and saved session")
            var unknownDenied = false
            do {try store.performExtensionCommand(id,command:"missing-owned-command",from:web,anchor:web)} catch {unknownDenied = true}
            check(unknownDenied,"An unknown command cannot fall through to another extension action")
            window.fixtureKey = false
            var unfocusedDenied = false
            do {try store.performExtensionCommand(id,command:"owned-command",from:web,anchor:web)} catch {unfocusedDenied = true}
            check(unfocusedDenied,"An unfocused source cannot dispatch a command into the engine's other focused tab")
            window.fixtureKey = true;host.synchronizeBrowserState()
            func event(_ flags:NSEvent.ModifierFlags,repeatKey:Bool = false,number:Int? = nil) -> NSEvent {
                NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:number ?? window.windowNumber,context:nil,characters:"Y",charactersIgnoringModifiers:"y",isARepeat:repeatKey,keyCode:16)!
            }
            check(try store.performExtensionCommand(for:event([.command,.shift]),from:web,anchor:web),"A matching source-window event runs its actual native extension shortcut")
            check(try !store.performExtensionCommand(for:event([.command,.shift,.option]),from:web,anchor:web),"Additional modifiers cannot accidentally match a less-specific extension shortcut")
            check(try !store.performExtensionCommand(for:event([.command,.shift],repeatKey:true),from:web,anchor:web),"A repeated key event does not repeatedly execute an extension command")
            check(try !store.performExtensionCommand(for:event([.command,.shift],number:window.windowNumber+1000),from:web,anchor:web),"An event from a different native window cannot borrow the source tab")
            var presentations = 0
            host.actionPresenter = NativeExtensionActionPresenter(present:{_,anchor in presentations += 1;check(anchor === web,"An action command retains its actual source popup anchor")})
            try store.performExtensionCommand(id,command:"_execute_action",from:web,anchor:web)
            for _ in 0..<700 {if presentations == 1 {break};try await Task.sleep(for:.milliseconds(10))}
            check(presentations == 1 && host.actionJobs.count == 1,"The reserved action command uses the source-bound native popup lifecycle")
            host.cancelActionJobs()
            let backgroundURL = fixture.appendingPathComponent("background-menu"),backgroundID = store.newTab(url:backgroundURL,activate:false)
            store.select(tabID);host.synchronizeBrowserState()
            let menuBefore = try canonical(store.makeDocument()),groups = store.extensionContextMenuGroups(for:.tab(backgroundID))
            guard let group = groups.first,let parent = find("Owned parent",in:group.items),let child = parent.submenu?.items.first,let disabled = find("Owned disabled",in:group.items) else {throw OwnedExtensionCommandError.missingFixture}
            check(group.id == id && group.label == "Owned commands" && !disabled.isEnabled,"Native tab menus preserve their extension identity, hierarchy and disabled state")
            check(store.views[backgroundID] == nil,"Fetching an extension menu for a suspended tab does not create a website view")
            check(invoke(child),"The guarded nested menu forwards its actual public native target and action")
            check(try await eventually(options,"const r=(await browser.storage.local.get('ownedMenu')).ownedMenu;return r?.id==='owned-child' && r?.url.endsWith('/background-menu') && r?.private===false;"),"The real menu handler receives the requested background tab rather than the active tab")
            let menuAfter = try canonical(store.makeDocument())
            check(menuBefore == menuAfter && store.views[backgroundID] == nil,"Executing a background tab menu preserves its suspension and saved session")
            _ = try await options.callAsyncJavaScript("await browser.storage.local.remove('ownedMenu');return true;",arguments:[:],in:nil,contentWorld:.page)
            _ = invoke(disabled);try await Task.sleep(for:.milliseconds(120))
            check((try await options.callAsyncJavaScript("return (await browser.storage.local.get('ownedMenu')).ownedMenu === undefined;",arguments:[:],in:nil,contentWorld:.page)) as? Bool == true,"A disabled native menu remains inert even if its target is invoked directly")
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('owned-child',{title:'Owned updated child'});return true;",arguments:[:],in:nil,contentWorld:.page)
            let updatedGroups = store.extensionContextMenuGroups(for:.tab(backgroundID))
            check(find("Owned updated child",in:updatedGroups.flatMap(\.items)) != nil && find("Owned child",in:updatedGroups.flatMap(\.items)) == nil,"Opening the menu again fetches the actual extension's current menu state")
            _ = try await options.callAsyncJavaScript("await browser.contextMenus.update('owned-child',{title:'Owned child'});return true;",arguments:[:],in:nil,contentWorld:.page)
            store.update(backgroundID){$0.url = fixture.appendingPathComponent("changed-menu-source").absoluteString}
            _ = invoke(child)
            try await Task.sleep(for:.milliseconds(120))
            check((try await options.callAsyncJavaScript("return (await browser.storage.local.get('ownedMenu')).ownedMenu === undefined;",arguments:[:],in:nil,contentWorld:.page)) as? Bool == true,"A menu captured before a suspended tab's destination changes cannot execute afterward")
            let liveGroups = store.extensionContextMenuGroups(for:.view(web)),liveChild = find("Owned child",in:liveGroups.flatMap(\.items))
            store.webView(web,didStartProvisionalNavigation:nil)
            if let liveChild {_ = invoke(liveChild)}
            try await Task.sleep(for:.milliseconds(120))
            check((try await options.callAsyncJavaScript("return (await browser.storage.local.get('ownedMenu')).ownedMenu === undefined;",arguments:[:],in:nil,contentWorld:.page)) as? Bool == true,"A menu from the prior actual source document is denied immediately on navigation")
            let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in throw CocoaError(.fileReadNoPermission)})
            defer {privateStore.shutdown()}
            try privateStore.associateExtensions(with:owner,profileID:profile)
            let privateWeb = privateStore.view(for:privateStore.selectedID!),privateURL = fixture.appendingPathComponent("private-command")
            privateWeb.load(URLRequest(url:privateURL));try await ready(privateWeb,privateURL)
            let privateWindow = OwnedExtensionCommandWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            privateWindow.isReleasedWhenClosed = false;privateWindow.contentView = privateWeb;privateStore.registerExtensionWindow(privateWindow,kind:.primary);window.fixtureKey = false
            defer {privateStore.unregisterExtensionWindow(kind:.primary);privateWindow.contentView = nil;privateWindow.close()}
            host.synchronizeBrowserState()
            let privateBefore = try canonical(store.makeDocument())
            try privateStore.performExtensionCommand(id,command:"owned-command",from:privateWeb,anchor:privateWeb)
            check(try await eventually(options,"const r=(await browser.storage.local.get('ownedCommand')).ownedCommand;return r?.url.endsWith('/private-command') && r?.private===true;"),"An approved private command reaches the native handler with its actual private source")
            let privateGroups = privateStore.extensionContextMenuGroups(for:.view(privateWeb)),privateChild = find("Owned child",in:privateGroups.flatMap(\.items))
            if let privateChild {_ = invoke(privateChild)}
            check(try await eventually(options,"const r=(await browser.storage.local.get('ownedMenu')).ownedMenu;return r?.url.endsWith('/private-command') && r?.private===true;"),"A private tab menu forwards its transient source without substituting the normal tab")
            let privateAfter = try canonical(store.makeDocument())
            check(privateBefore == privateAfter && !privateWeb.configuration.websiteDataStore.isPersistent,"Private commands and menus do not serialize private URLs or change the temporary website store")
            privateWindow.fixtureKey = false;window.fixtureKey = true;host.synchronizeBrowserState()
            let collisionSource = root.appendingPathComponent("collision-source")
            try manager.copyItem(at:source,to:collisionSource)
            let collisionManifest = try String(contentsOf:collisionSource.appendingPathComponent("manifest.json"),encoding:.utf8).replacingOccurrences(of:"Owned commands",with:"Owned shortcut collision")
            try Data(collisionManifest.utf8).write(to:collisionSource.appendingPathComponent("manifest.json"))
            let collisionPackage = try ExtensionPackage.prepare(at:collisionSource,stagingRoot:root.appendingPathComponent("collision-staging"))
            let collisionApproval = try store.extensionInstallApproval(for:collisionPackage,profileID:profile,permissions:["storage","activeTab","contextMenus"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            _ = try await store.installExtension(collisionPackage,approval:collisionApproval);try await store.prepareExtensions(profileID:profile)
            check(try !store.performExtensionCommand(for:event([.command,.shift]),from:web,anchor:web),"A shortcut shared by two real loaded extensions is refused instead of choosing an arbitrary account action")
            try store.setExtensionEnabled(id,profileID:profile,enabled:false)
            check(privateStore.extensionCommandSummaries(for:privateWeb).isEmpty && privateStore.extensionContextMenuGroups(for:.view(privateWeb)).isEmpty,"Disabling the extension removes both private command and context-menu entry points")
        }
        do {try await exercise()} catch {check(false,"Owned command fixture failed: " + error.localizedDescription)}
        check(await controllers.cleanup(),"Command fixtures erase only their owned native extension storage")
        check(await owned.cleanup(),"Command fixtures release only their owned named website stores")
        print("Extension command checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
