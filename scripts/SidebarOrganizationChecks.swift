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
