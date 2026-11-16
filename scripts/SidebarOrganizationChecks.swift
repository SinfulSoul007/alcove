import AppKit
import WebKit
import CryptoKit
import BrowserCore

@MainActor final class OwnedSidebarApplication:NSApplication {
    var fixtureWindow:NSWindow?
    var quitRequests = 0
    override var keyWindow:NSWindow? {fixtureWindow}
    override var mainWindow:NSWindow? {fixtureWindow}
    override func terminate(_ sender:Any?) {quitRequests += 1}
}
@MainActor final class OwnedSidebarWindow:NSWindow {
    var closeRequests = 0
    override func performClose(_ sender:Any?) {closeRequests += 1}
    override func makeKeyAndOrderFront(_ sender:Any?) {}
}
@main struct SidebarOrganizationChecks {
    @MainActor static func ready(_ web:WKWebView,url:URL) async throws {
        for _ in 0..<700 {
            if web.url == url,(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    @MainActor static func main() async throws {
        let application = OwnedSidebarApplication.shared as! OwnedSidebarApplication
        application.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        var failures = 0
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func inWindow(_ body:(BrowserStore,OwnedSidebarWindow,AppDelegate)->Void) {
            let store = BrowserStore(isPrivate:true),delegate = AppDelegate()
            let window = OwnedSidebarWindow(contentRect:NSRect(x:0,y:0,width:900,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;application.fixtureWindow = window;delegate.windows[window] = store
            defer {application.fixtureWindow = nil;delegate.windows = [:];store.shutdown()}
            body(store,window,delegate)
        }
        inWindow {store,window,delegate in
            delegate.closeTab()
            check(window.closeRequests == 1,"Cmd-W closes an initially blank browser window")
            check(!delegate.applicationShouldTerminateAfterLastWindowClosed(application) && application.quitRequests == 0,"Closing an empty browser window leaves the application running")
            delegate.buildMenu()
            check(NSApp.mainMenu?.items.first(where:{$0.title == "File"})?.submenu?.items.contains(where:{$0.action == #selector(AppDelegate.newFolder)}) == true && store.availableCommands.contains(.newFolder) && BrowserCommand.newFolder.matches("new fol"),"Folder creation is discoverable in the native File menu and command search")
        }
        inWindow {store,window,delegate in
            let a = store.newTab(url: URL(string: "https://example.invalid/first-recent")!)
            let b = store.newTab(url: URL(string: "https://example.invalid/second-recent")!)
            let c = store.newTab(url: URL(string: "https://example.invalid/third-recent")!)
            store.select(b)
            store.select(c)
            store.select(a)
            delegate.nextTab()
            check(store.selectedID == c,
                  "Switching to the previous recent tab follows last use rather than sidebar order")
        }
        inWindow { store, window, delegate in
            let urls = (1...7).map { URL(string: "https://example.invalid/recent-\($0)")! }
            let ids = urls.map { store.newTab(url: $0) }
            let original = ids[6], previous = ids[5], earlier = ids[4]
            let view = store.view(for: original)
            @MainActor func key(_ code: UInt16, text: String, flags: NSEvent.ModifierFlags = .control,
                     type: NSEvent.EventType = .keyDown) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: text,
                                 charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            }
            let tab = key(48, text: "\t"), reverse = key(48, text: "\t", flags: [.control, .shift])
            let release = key(59, text: "", flags: [], type: .flagsChanged)
            check(delegate.handleRecentTabInput(tab) && store.visibleRecentTabSwitcher?.entries.map(\.id) == Array(ids.reversed().prefix(5)) &&
                  store.visibleRecentTabSwitcher?.selected.id == previous && store.selectedID == original && store.views[original] === view,
                  "Control-Tab highlights the previous of the five recent tabs and preserves the current live page")
            check(delegate.handleRecentTabInput(tab) && store.visibleRecentTabSwitcher?.selected.id == earlier &&
                  delegate.handleRecentTabInput(reverse) && store.visibleRecentTabSwitcher?.selected.id == previous,
                  "A held Control key cycles in both directions through the same five tabs")
            check(delegate.handleRecentTabInput(key(53, text: "\u{1b}")) && store.visibleRecentTabSwitcher == nil && store.selectedID == original,
                  "Escape cancels the recent-tab highlight without selecting its page")
            _ = delegate.handleRecentTabInput(tab)
            _ = delegate.handleRecentTabInput(release)
            check(store.selectedID == previous && store.visibleRecentTabSwitcher == nil && store.views[original] === view,
                  "Releasing Control selects the highlighted tab without replacing the original page")
            _ = delegate.handleRecentTabInput(tab)
            let highlighted = store.visibleRecentTabSwitcher?.selected.id
            check(highlighted == original && delegate.handleRecentTabInput(key(13, text: "w")) &&
                  store.tab(original) == nil && store.selectedID == previous && window.closeRequests == 0,
                  "Control-W closes the highlighted tab and leaves its browser window open")
            _ = delegate.handleRecentTabInput(tab)
            delegate.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
            _ = delegate.handleRecentTabInput(release)
            check(store.selectedID == previous && store.recentTabSwitcher == nil,
                  "A former key window drops the highlight before Control is released")
            _ = delegate.handleRecentTabInput(tab)
            store.showCommand()
            check(!delegate.handleRecentTabInput(key(36, text: "\r", flags: [])) && store.commandVisible &&
                  store.recentTabSwitcher == nil, "A hidden recent switcher passes Return to the command field")
            store.dismissCommand()
            _ = delegate.handleRecentTabInput(tab)
            let other = try! store.createSpace(name: "Another Space")
            store.selectSpace(other)
            _ = delegate.handleRecentTabInput(release)
            check(store.space.id == other && store.recentTabSwitcher == nil,
                  "A Space change cancels an in-progress recent-tab selection")
        }
        inWindow { store, _, _ in
            let a = store.newTab(url: URL(string: "about:blank#primary"))
            let b = store.newTab(url: URL(string: "about:blank#split"))
            let c = store.newTab(url: URL(string: "about:blank#hidden"))
            store.update(b) { $0.lastAccessed = .distantPast }
            store.update(c) { $0.lastAccessed = Date(timeIntervalSinceNow: -30) }
            store.select(a)
            store.splitID = b
            store.focusPane(b); store.focusPane(a)
            check(store.advanceRecentTab(1) && store.visibleRecentTabSwitcher?.selected.id == b,
                  "A focused split pane outranks an unvisited hidden tab")
            store.cancelRecentTabSwitcher()
            let firstSpace = store.space.id
            let secondSpace = try! store.createSpace(name: "Recent other")
            store.selectSpace(secondSpace)
            let restored = store.newTab(url: URL(string: "about:blank#restored"))
            store.update(restored) { $0.lastAccessed = .distantPast }
            store.selectSpace(firstSpace)
            store.selectSpace(secondSpace)
            store.selectSpace(firstSpace)
            check(store.advanceRecentTab(1) && store.visibleRecentTabSwitcher?.selected.id == restored,
                  "Returning from a Space ranks its remembered active tab by the actual visit")
        }
        inWindow {store,window,delegate in
            let id = store.newTab(url:URL(string:"https://example.invalid/last")!)
            delegate.closeTab()
            check(store.tab(id) == nil && window.closeRequests == 1,"Cmd-W closes the last regular tab and then its empty Space window")
        }
        inWindow {store,window,delegate in
            let first = store.newTab(url:URL(string:"https://example.invalid/first")!)
            let second = store.newTab(url:URL(string:"https://example.invalid/second")!)
            delegate.closeTab()
            check(store.tab(second) == nil && store.tab(first) != nil && window.closeRequests == 0,"Cmd-W keeps the window open when another regular tab remains")
        }
        inWindow {store,window,delegate in
            let id = store.newTab(url:URL(string:"https://example.invalid/pin")!);store.togglePin(id)
            delegate.closeTab()
            check(store.tab(id)?.pinned == true && store.tab(id)?.homeURL == "https://example.invalid/pin","Closing a saved page preserves its pinned definition and home address")
            check(window.closeRequests == 1,"Pinned definitions do not trap an otherwise empty window open")
        }
        inWindow {store,window,delegate in
            let parent = store.newTab(url:URL(string:"https://example.invalid/parent")!)
            let configuration = WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
            let preview = WKWebView(frame:.zero,configuration:configuration)
            store.peekPages[.primary] = PeekState(web:preview,profileID:BrowserProfile.defaultID,spaceID:store.space.id)
            delegate.closeTab()
            check(store.primaryPeekView == nil && store.tab(parent) != nil && window.closeRequests == 0,"Cmd-W closes the visible Peek while preserving its parent tab")
        }
        inWindow {store,window,delegate in
            store.presentedPanel = .settings;delegate.closeTab()
            check(store.presentedPanel == nil && window.closeRequests == 0,"Cmd-W dismisses the visible settings panel first")
        }
        inWindow {store,window,delegate in
            let first = store.newTab(url:URL(string:"https://example.invalid/main")!)
            let split = store.newTab(url:URL(string:"https://example.invalid/split")!)
            store.select(first);store.splitID = split;store.activePaneID = split;delegate.closeTab()
            check(store.tab(split) == nil && store.tab(first) != nil && window.closeRequests == 0,"Cmd-W closes the focused split without closing its other regular pane")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let pending = BrowserStore(dataRoot:root,metadataKeyAccess:MetadataKeyAccess{_,_ in throw CocoaError(.fileReadNoPermission)})
        let pendingWindow = OwnedSidebarWindow(contentRect:NSRect(x:0,y:0,width:900,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        pendingWindow.isReleasedWhenClosed = false
        let pendingDelegate = AppDelegate();pendingDelegate.windows[pendingWindow] = pending;application.fixtureWindow = pendingWindow
        let item = NSMenuItem(title:"Close",action:#selector(AppDelegate.closeTab),keyEquivalent:"w")
        check(pendingDelegate.validateMenuItem(item),"Cmd-W remains available while saved data is waiting to unlock")
        pendingDelegate.closeTab()
        check(pendingWindow.closeRequests == 1,"Cmd-W closes a waiting startup window without touching protected tabs")
        pending.shutdown();pendingDelegate.windows = [:];application.fixtureWindow = nil
        check(application.quitRequests == 0,"Every native close route leaves NSApplication termination untouched")
        func rejects(_ name:String,_ body:() throws -> Void) {do {try body();check(false,name)} catch {check(true,name)}}
        let key = SymmetricKey(size:.bits256),savedRoot = root.appendingPathComponent("folders")
        let saved = BrowserStore(dataRoot:savedRoot,keyProvider:{_ in key}),savedSpace = saved.space.id
        let folder = try saved.createTabFolder(name:"  Research  ",in:savedSpace)
        check(folder == "Research" && saved.space.folderNames == ["Research"] && saved.space.tabs.allSatisfy(\.url.isEmpty),"Creating an empty folder makes no dummy website tab")
        _ = try saved.createTabFolder(name:"Travel",in:savedSpace)
        rejects("Folder names reject case-insensitive duplicates") {_ = try saved.createTabFolder(name:"research",in:savedSpace)}
        rejects("Folder names reject blank names") {_ = try saved.createTabFolder(name:" \n ",in:savedSpace)}
        rejects("Folder names reject control characters") {_ = try saved.createTabFolder(name:"Bad\u{0001}Name",in:savedSpace)}
        rejects("Folder names reject excessive length") {_ = try saved.createTabFolder(name:String(repeating:"a",count:81),in:savedSpace)}
        saved.shutdown()
        let reopened = BrowserStore(dataRoot:savedRoot,keyProvider:{_ in key})
        check(reopened.space.folderNames == ["Research","Travel"],"Empty folders survive encrypted relaunch in their original order")
        let bytes = try Data(contentsOf:reopened.sessionURL)
        check(bytes.range(of:Data("Research".utf8)) == nil,"Saved folder names remain inside encrypted metadata")
        reopened.shutdown()
        var legacy = Space(name:"Legacy"),legacyTab = BrowserCore.Tab(title:"Legacy pin",url:"https://example.invalid/legacy",pinned:true)
        legacyTab.folder = "Imported";legacy.tabs = [legacyTab]
        let legacyRoundTrip = try JSONDecoder().decode(Space.self,from:JSONEncoder().encode(legacy))
        check(legacyRoundTrip.folderNames == ["Imported"],"Legacy tab memberships remain visible without explicit folder definitions")
        let topologyFixture = Space(name: "Hierarchy")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(topologyFixture)) as! [String: Any]
        json["folders"] = ["Research", "Papers", "Drafts"]
        json["folderParents"] = ["Papers": "Research", "Drafts": "Papers"]
        let importedHierarchy = try JSONDecoder().decode(Space.self, from: JSONSerialization.data(withJSONObject: json))
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(importedHierarchy)) as! [String: Any]
        check(reencoded["folderParents"] as? [String: String] == ["Papers": "Research", "Drafts": "Papers"],
              "Saving a Space round-trips its nested folder structure")
        let nestedRoot = root.appendingPathComponent("nested-folders")
        let nested = BrowserStore(dataRoot: nestedRoot, keyProvider: { _ in key })
        let nestedSpace = nested.space.id
        let pinned = nested.newTab(url: URL(string: "https://example.invalid/subfolder")!)
        let pinnedView = nested.view(for: pinned)
        try nested.createTabFolder(name: "Research", in: nestedSpace)
        try nested.createTabFolder(name: "Papers", in: nestedSpace, parent: "Research", adding: pinned)
        try nested.createTabFolder(name: "Drafts: Notes", in: nestedSpace, parent: "Papers")
        var tree = SidebarFolderTree(space: nested.space)
        check(tree.path(to: "Drafts: Notes") == ["Research", "Papers", "Drafts: Notes"] &&
              nested.tab(pinned)?.folder == "Papers" && nested.views[pinned] === pinnedView,
              "Subfolder creation puts the original tab in its nested destination without replacing its live page")
        check(tree.visibleFolders(collapsed: ["Research"]).map(\.name) == ["Research"],
              "Collapsing a folder hides its descendants from the saved-sidebar layout")
        rejects("A folder cannot be moved into its descendant") { try nested.moveTabFolder("Research", under: "Drafts: Notes", in: nestedSpace) }
        rejects("A subfolder cannot be created under a missing parent") { try nested.createTabFolder(name: "Orphan", in: nestedSpace, parent: "Missing") }
        try nested.setTabFolderExpanded("Papers", expanded: false, in: nestedSpace)
        try nested.renameTabFolder("Papers", to: "Reading", in: nestedSpace)
        tree = SidebarFolderTree(space: nested.space)
        check(nested.tab(pinned)?.folder == "Reading" && nested.space.collapsedFolders == ["Reading"] &&
              tree.path(to: "Drafts: Notes") == ["Research", "Reading", "Drafts: Notes"],
              "Renaming a nested folder updates its tabs, descendants and disclosure state together")
        let drag = SidebarFolderDrag(spaceID: nestedSpace, name: "Drafts: Notes")
        let rootDrop = TabDrop(store: nested, section: .pinned)
        check(SidebarFolderDrag(drag.text) == drag &&
              !rootDrop.accept(SidebarFolderDrag(spaceID: UUID(), name: drag.name).text, in: nestedSpace, profile: BrowserProfile.defaultID),
              "Folder drag payloads round-trip punctuation and reject moves from another Space")
        let nestedDrop = TabDrop(store: nested, section: .pinned, folder: "Reading")
        check(rootDrop.accept(drag.text, in: nestedSpace, profile: BrowserProfile.defaultID) &&
              SidebarFolderTree(space: nested.space).parents[drag.name] == nil &&
              nestedDrop.accept(drag.text, in: nestedSpace, profile: BrowserProfile.defaultID),
              "Pinned sidebar drop routing can move a folder to the top level and nest it again")
        let movingPin = nested.newTab(url: URL(string: "https://example.invalid/drag")!)
        let oldRowTarget = TabDrop(store: nested, section: .pinned, before: pinned, folder: "Reading")
        try nested.moveTabToFolder(pinned, folder: "Drafts: Notes", in: nestedSpace)
        check(!oldRowTarget.accept(movingPin.uuidString, in: nestedSpace, profile: BrowserProfile.defaultID) &&
              nested.tab(movingPin)?.pinned == false, "An asynchronous drop cannot reuse a tab anchor that moved to another folder")
        try nested.moveTabToFolder(pinned, folder: "Reading", in: nestedSpace)
        try nested.removeTabFolder("Reading", in: nestedSpace)
        check(nested.tab(pinned)?.folder == "Research" && nested.views[pinned] === pinnedView &&
              SidebarFolderTree(space: nested.space).parents[drag.name] == "Research",
              "Removing a nested folder promotes its pins and subfolders to the parent")
        var importedHierarchySession = Session()
        importedHierarchySession.spaces = [importedHierarchy]
        try nested.importSession(importedHierarchySession, into: BrowserProfile.defaultID)
        let importedTree = nested.session.spaces.first(where: { $0.name == "Imported Hierarchy" }).map(SidebarFolderTree.init(space:))
        check(importedTree?.path(to: "Drafts") == ["Research", "Papers", "Drafts"],
              "Session import preserves folder hierarchy")
        nested.shutdown()
        let reopenedHierarchy = BrowserStore(dataRoot: nestedRoot, keyProvider: { _ in key })
        check(reopenedHierarchy.tab(pinned)?.folder == "Research" &&
              SidebarFolderTree(space: reopenedHierarchy.space).path(to: drag.name) == ["Research", drag.name],
              "The nested folder and pin survive encrypted relaunch")
        reopenedHierarchy.shutdown()
        var broken = importedHierarchy
        broken.folderParents = ["Research": "Papers", "Papers": "Research", "Drafts": "Unknown"]
        let repairedTree = SidebarFolderTree(space: broken)
        check(Set(repairedTree.visibleFolders(collapsed: []).map(\.name)) == Set(broken.folderNames) &&
              repairedTree.parents["Drafts"] == nil && repairedTree.parents.count == 1,
              "Repair preserves every folder and removes cyclic and stale parent links")
        let legacyRoot = root.appendingPathComponent("legacy-folder")
        var legacyDocument = BrowserDocument();legacyDocument.session.spaces = [legacy];legacyDocument.session.selectedSpace = legacy.id
        try MetadataStore(url:legacyRoot.appendingPathComponent("session-v2.sealed"),key:key).save(legacyDocument)
        let legacyStore = BrowserStore(dataRoot:legacyRoot,keyProvider:{_ in key})
        try legacyStore.moveTabToFolder(legacyTab.id,folder:nil,in:legacy.id)
        check(legacyStore.space.folderNames == ["Imported"],"A migrated older folder stays visible after its last tab moves out")
        legacyStore.shutdown()
        var privateKeys = 0
        let privateRoot = root.appendingPathComponent("private-folders"),temporary = BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in privateKeys += 1;return key})
        let target = temporary.space.id,id = temporary.newTab(url:URL(string:"https://example.invalid/folder")!),web = temporary.view(for:id)
        _ = try temporary.createTabFolder(name:"Work",in:target)
        rejects("Creating a folder with a vanished tab fails atomically") {_ = try temporary.createTabFolder(name:"Phantom",in:target,adding:UUID())}
        check(!temporary.space.folderNames.contains("Phantom"),"Failed create-and-move leaves no phantom empty folder")
        try temporary.moveTabToFolder(id,folder:"Work",in:target)
        check(temporary.tab(id)?.pinned == true && temporary.tab(id)?.folder == "Work" && temporary.views[id] === web,"Moving Today into a folder pins the original tab without replacing its live view")
        temporary.session.spaces[temporary.spaceIndex].collapsedFolders = ["Work"]
        try temporary.renameTabFolder("Work",to:"Projects",in:target)
        check(temporary.space.folderNames == ["Projects"] && temporary.tab(id)?.folder == "Projects" && temporary.space.collapsedFolders == ["Projects"],"Renaming updates the folder, its tabs and disclosure state together")
        _ = try temporary.createTabFolder(name:"Other",in:target)
        rejects("Renaming cannot overwrite another folder") {try temporary.renameTabFolder("Projects",to:"OTHER",in:target)}
        try temporary.removeTabFolder("Projects",in:target)
        check(temporary.tab(id)?.folder == nil && temporary.tab(id)?.pinned == true && temporary.tab(id)?.url == "https://example.invalid/folder" && temporary.views[id] === web,"Removing a folder retains its saved tabs and live views")
        rejects("Moving into a removed folder cannot silently recreate it") {try temporary.moveTabToFolder(id,folder:"Projects",in:target)}
        try temporary.moveTabToFolder(id,folder:nil,in:target)
        check(temporary.tab(id)?.pinned == true,"Moving out of a folder keeps the tab pinned")
        check(privateKeys == 0 && temporary.vault == nil && !FileManager.default.fileExists(atPath:privateRoot.path),"Private folders use no Keychain key or persistent files")
        temporary.shutdown()
        rejects("A stale folder action cannot mutate a closed Store") {_ = try temporary.createTabFolder(name:"Stale",in:target)}
        let failed = BrowserStore(dataRoot:root.appendingPathComponent("failed-folder"),keyProvider:{_ in key}),failedSpace = failed.space.id
        _ = try failed.createTabFolder(name:"Keep",in:failedSpace)
        let failedTab = failed.newTab(url:URL(string:"https://example.invalid/failed-drop")!);failed.flush()
        let originalBytes = try Data(contentsOf:failed.sessionURL),obstruction = root.appendingPathComponent("not-directory")
        try Data().write(to:obstruction);failed.vault = MetadataStore(url:obstruction.appendingPathComponent("metadata.sealed"),key:key)
        rejects("A failed folder save is reported") {try failed.renameTabFolder("Keep",to:"Unsaved",in:failedSpace)}
        let failedBytes = try Data(contentsOf:failed.sessionURL)
        check(failed.space.folderNames == ["Keep"] && failedBytes == originalBytes,"Failed folder persistence leaves both live state and the original ciphertext intact")
        failed.savingEnabled = true
        check(!failed.placeTab(failedTab,in:failedSpace,section:.pinned,folder:"Keep") && failed.tab(failedTab)?.pinned == false,"A failed drag placement cannot publish an unsaved pin or folder membership")
        failed.shutdown()
        let accounts = BrowserStore(dataRoot:root.appendingPathComponent("accounts"),keyProvider:{_ in key}),personal = accounts.space.id
        let account = try accounts.createProfile(name:"Work"),otherSpace = accounts.space.id
        let otherTab = accounts.newTab(url:URL(string:"https://example.invalid/account")!)
        _ = try accounts.createTabFolder(name:"Personal only",in:personal)
        check(accounts.space.id == otherSpace && accounts.session.spaces.first(where:{$0.id == personal})?.folderNames == ["Personal only"],"A captured Space action stays with that Space after the selection changes")
        rejects("Folder moves cannot silently cross profile boundaries") {try accounts.moveTabToFolder(otherTab,folder:"Personal only",in:personal)}
        accounts.profiles[accounts.profiles.firstIndex(where:{$0.id == account})!].pendingDataClear = true
        rejects("An unavailable profile cannot acquire folder changes") {_ = try accounts.createTabFolder(name:"Blocked",in:otherSpace)}
        accounts.shutdown()
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw CocoaError(.fileNoSuchFile)}
        let bookmarks = BrowserStore(dataRoot:root.appendingPathComponent("bookmarks"),keyProvider:{_ in key})
        let sourceProfile = try bookmarks.createProfile(name:"Owned source"),sourceSpace = bookmarks.space.id
        bookmarks.namedDataStores[sourceProfile] = .nonPersistent()
        let liveID = bookmarks.newTab(url:fixture),liveWeb = bookmarks.view(for:liveID)
        try await ready(liveWeb,url:fixture);_ = try await liveWeb.evaluateJavaScript("document.getElementById('owned-form').value='keep-form'")
        let otherProfile = try bookmarks.createProfile(name:"Owned other"),selectedSpace = bookmarks.space.id
        bookmarks.namedDataStores[otherProfile] = .nonPersistent()
        try bookmarks.bookmarkWebsite(liveWeb)
        let form = try await liveWeb.evaluateJavaScript("document.getElementById('owned-form').value") as? String
        check(bookmarks.tab(liveID)?.pinned == true && bookmarks.views[liveID] === liveWeb && form == "keep-form","Bookmarking pins the existing main tab without reloading its form")
        check(bookmarks.space.id == selectedSpace && bookmarks.library(for:sourceProfile).bookmarks.contains(where:{$0.url == fixture.absoluteString}) && bookmarks.library(for:otherProfile).bookmarks.isEmpty,"Bookmarking uses the source profile and Space even after another account is selected")
        try bookmarks.bookmarkWebsite(liveWeb)
        check(bookmarks.session.spaces.first(where:{$0.id == sourceSpace})!.tabs.filter({$0.url == fixture.absoluteString}).count == 1,"Repeated bookmarking does not duplicate the saved tab")
        let quickURL = fixture.appendingPathComponent("quick"),quick = try bookmarks.openQuickPage(url:quickURL,profileID:sourceProfile,intendedSpaceID:sourceSpace)
        let quickWeb = bookmarks.view(for:quick);try await ready(quickWeb,url:quickURL)
        _ = try await quickWeb.evaluateJavaScript("document.getElementById('owned-form').value='quick-form'")
        try bookmarks.bookmarkQuickPage(quick)
        let quickForm = try await quickWeb.evaluateJavaScript("document.getElementById('owned-form').value") as? String
        check(bookmarks.session.spaces.first(where:{$0.id == sourceSpace})!.tabs.contains(where:{$0.pinned && $0.url == quickURL.absoluteString}) && bookmarks.quickPage(quick) != nil && bookmarks.views[quick] === quickWeb && quickForm == "quick-form","Bookmarking Quick Browse adds a source-Space pin and preserves its compact page")
        let peekURL = fixture.appendingPathComponent("peek")
        bookmarks.openPeek(peekURL,from:quickWeb)
        let peekWeb = bookmarks.quickPeekView(quick)!;try await ready(peekWeb,url:peekURL)
        _ = try await peekWeb.evaluateJavaScript("document.getElementById('owned-form').value='peek-form'")
        try bookmarks.bookmarkWebsite(peekWeb)
        let peekForm = try await peekWeb.evaluateJavaScript("document.getElementById('owned-form').value") as? String
        check(bookmarks.session.spaces.first(where:{$0.id == sourceSpace})!.tabs.contains(where:{$0.pinned && $0.url == peekURL.absoluteString}) && bookmarks.quickPeekView(quick) === peekWeb && peekForm == "peek-form","Bookmarking Peek preserves its form and pins only in the captured source Space")
        bookmarks.closeQuickPeek(quick)
        let failureBefore = bookmarks.makeDocument(),bookmarkBytes = try Data(contentsOf:bookmarks.sessionURL)
        bookmarks.vault = MetadataStore(url:obstruction.appendingPathComponent("metadata.sealed"),key:key)
        let quick2URL = fixture.appendingPathComponent("unsaved")
        quickWeb.load(URLRequest(url:quick2URL));try await ready(quickWeb,url:quick2URL)
        rejects("A bookmark save failure does not publish a phantom pin") {try bookmarks.bookmarkWebsite(quickWeb)}
        let afterBookmarkBytes = try Data(contentsOf:bookmarks.sessionURL)
        check(!bookmarks.session.spaces.flatMap(\.tabs).contains(where:{$0.url == quick2URL.absoluteString}) && bookmarks.library(for:sourceProfile).bookmarks == failureBefore.library(for:sourceProfile).bookmarks && afterBookmarkBytes == bookmarkBytes && bookmarks.views[quick] === quickWeb,"Bookmark persistence failure keeps saved pins, Library, ciphertext and live views intact")
        bookmarks.shutdown()
        print("Sidebar organization checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
