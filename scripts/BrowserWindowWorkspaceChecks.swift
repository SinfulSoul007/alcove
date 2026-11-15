import Foundation
import BrowserCore
import CoreGraphics
import CryptoKit

@main enum BrowserWindowWorkspaceChecks {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if value() { print("PASS: \(label)") }
            else { failures += 1; print("FAIL: \(label)") }
        }
        func rejects(_ error: BrowserWindowWorkspaceError, _ label: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, label) }
            catch let actual as BrowserWindowWorkspaceError { check(actual == error, label) }
            catch { check(false, label) }
        }
        var original = Session()
        let personal = original.spaces[0].id, first = original.spaces[0].tabs[0].id
        original.spaces[0].tabs[0].title = "First"
        original.spaces[0].tabs[0].url = "https://first.invalid/"
        let second = Tab(title: "Second", url: "https://second.invalid/")
        original.spaces[0].tabs.append(second)
        let work = Space(name: "Work", tabs: [Tab(title: "Work page", url: "https://work.invalid/")])
        original.spaces.append(work)
        let a = UUID(), b = UUID()
        var model = try BrowserWindowWorkspace(session: original)
        _ = try model.openWindow(id: a)
        _ = try model.openWindow(id: b, copying: a)
        check(model.windows.map(\.id) == [a, b], "New normal windows retain independent identities")
        check(model.focusedWindowID == b, "The newly opened window becomes the focused model window")
        check(model.session(for: a)?.spaces[0].selected == first && model.session(for: b)?.spaces[0].selected == first, "A new window copies the invoking window's selection")
        check(model.assignedWindow(for: first) == b, "New Window explicitly claims the selected logical tab")
        check(model.assignedWindow(for: second.id) == a, "Opening a window does not move unrelated logical tabs")

        var edit = model.session(for: a)!
        edit.spaces[0].selected = second.id
        try model.apply(edit, from: a)
        check(model.session(for: a)?.spaces[0].selected == second.id && model.session(for: b)?.spaces[0].selected == first, "Selecting in one window does not select in the other")
        check(model.session.spaces[0].selected == first, "An unfocused window edit cannot replace the focused persistence selection")
        edit = model.session(for: a)!
        edit.spaces[0].name = "Personal updated"
        edit.spaces[0].folders = ["Research"]
        edit.spaces[0].tabs[1].folder = "Research"
        edit.spaces[0].tabs[1].url = "https://second.invalid/changed"
        edit.spaces[0].tabs[1].title = "Changed café 雨"
        edit.spaces.swapAt(0, 1)
        try model.apply(edit, from: a)
        let inB = model.session(for: b)!
        let personalB = inB.spaces.first { $0.id == personal }!
        check(inB.spaces.map(\.id) == [work.id, personal], "Space reorder is shared across normal windows")
        check(personalB.name == "Personal updated" && personalB.folders == ["Research"], "Space and folder edits are shared")
        check(personalB.tabs.first { $0.id == second.id }?.url == "https://second.invalid/changed" && personalB.tabs.first { $0.id == second.id }?.title == "Changed café 雨", "Shared page edits retain exact URL and Unicode title")
        check(personalB.selected == first, "Shared data publication retains the receiver's tab selection")
        check(model.focusWindow(a) && model.session.selectedSpace == personal && model.session.spaces.first { $0.id == personal }?.selected == second.id, "Focusing a window projects its selection into legacy persistence")
        check(model.assignedWindow(for: first) == b, "Focus alone does not steal a handed-off tab")
        check(model.claim(second.id, for: b) && model.assignedWindow(for: second.id) == b, "An explicit claim moves one logical tab assignment")
        check(model.session(for: a)?.spaces.first { $0.id == personal }?.selected == second.id, "A presentation claim does not erase the old window's selection")
        check(model.focusWindow(b), "The existing second window remains focusable")

        let created = Tab(title: "New", url: "https://new.invalid/")
        edit = model.session(for: a)!
        let p = edit.spaces.firstIndex { $0.id == personal }!
        edit.spaces[p].tabs.append(created)
        try model.apply(edit, from: a)
        check(model.assignedWindow(for: created.id) == a, "A new background-window tab belongs to its actual creating window")
        check(model.session(for: b)?.spaces.first { $0.id == personal }?.tabs.contains { $0.id == created.id } == true, "New tabs appear in every shared sidebar")

        edit = model.session(for: a)!
        edit.selectedSpace = work.id
        try model.apply(edit, from: a)
        check(model.session(for: a)?.selectedSpace == work.id && model.session(for: b)?.selectedSpace == personal, "Space selection is local to each normal window")
        edit = model.session(for: a)!
        edit.spaces.removeAll { $0.id == work.id }
        try model.apply(edit, from: a)
        check(model.session(for: a)?.selectedSpace == personal && model.session(for: b)?.selectedSpace == personal, "Deleting a selected Space repairs only invalid selections")
        check(model.assignedWindow(for: work.tabs[0].id) == nil, "Deleted Space tabs leave the logical assignment catalog")

        edit = model.session(for: a)!
        edit.spaces[0].tabs.removeAll { $0.id == first }
        try model.apply(edit, from: a)
        check(model.session(for: b)?.spaces[0].selected == second.id, "A removed selected tab repairs the receiving window to a surviving tab")
        check(model.assignedWindow(for: first) == nil, "A removed tab cannot retain a stale window assignment")
        check(!model.claim(first, for: b), "A claim cannot resurrect a closed tab")
        check(!model.claim(second.id, for: UUID()) && !model.focusWindow(UUID()), "Unknown windows cannot claim tabs or become focused")
        rejects(.missingWindow, "A closed or unknown window cannot publish a stale session") { try model.apply(original, from: UUID()) }
        check(model.session.spaces[0].tabs.contains { $0.id == first } == false, "Rejected stale publication leaves the newer library intact")
        rejects(.duplicateWindow, "Opening an existing window identity is rejected") { _ = try model.openWindow(id: a) }
        rejects(.missingWindow, "Copying an unknown window fails before creating anything") { _ = try model.openWindow(id: UUID(), copying: UUID()) }
        check(model.windows.count == 2, "Failed window requests do not create phantom records")

        var invalid = model.session(for: a)!
        invalid.spaces.append(invalid.spaces[0])
        rejects(.invalidSession, "Duplicate Space identities are rejected atomically") { try model.apply(invalid, from: a) }
        invalid = model.session(for: a)!
        invalid.spaces[0].tabs.append(invalid.spaces[0].tabs[0])
        rejects(.invalidSession, "Duplicate tab identities cannot create ambiguous page ownership") { try model.apply(invalid, from: a) }
        check(model.windows.count == 2 && model.session.spaces.count == 1, "Invalid data cannot partially replace a valid workspace")

        var restored = try BrowserWindowWorkspace(session: model.session, windows: model.windows, focusedWindowID: model.focusedWindowID, assignments: model.assignments)
        check(restored.session(for: a)?.selectedSpace == model.session(for: a)?.selectedSpace && restored.session(for: b)?.spaces[0].selected == model.session(for: b)?.spaces[0].selected, "Restoration retains each window's own selection")
        check(restored.assignedWindow(for: second.id) == b, "Restoration retains a valid handed-off logical assignment")
        check(restored.closeWindow(b) && restored.focusedWindowID == a, "Closing the focused window retains a surviving normal window")
        check(restored.assignedWindow(for: second.id) == a, "Closing a presenter reassigns its logical tabs without changing their IDs")
        check(restored.session(for: b) == nil && !restored.closeWindow(b), "A closed window has no projection and cannot close twice")
        rejects(.missingWindow, "A closed window cannot publish after its replacement is active") { try restored.apply(original, from: b) }
        check(restored.closeWindow(a) && restored.windows.isEmpty && restored.focusedWindowID == nil && restored.assignments.isEmpty, "Closing the last window clears only window/assignment state")
        check(restored.session.spaces[0].tabs.contains { $0.id == second.id }, "The shared tab library survives the last window closing")
        let reopened = UUID()
        _ = try restored.openWindow(id: reopened)
        check(restored.session(for: reopened)?.spaces[0].selected == second.id, "Reopening a normal window uses the preserved last selection")

        var bad = BrowserWindowSelection(id: UUID(), session: original)
        bad.spaceID = UUID()
        bad.selectedTabsBySpace = [personal: UUID(), UUID(): first]
        let repaired = try BrowserWindowWorkspace(session: original, windows: [bad], focusedWindowID: UUID(), assignments: [UUID(): a, first: UUID()])
        check(repaired.session(for: bad.id)?.selectedSpace == personal && repaired.session(for: bad.id)?.spaces[0].selected == first, "Invalid restored selection references repair against current tabs and Spaces")
        check(repaired.focusedWindowID == bad.id && repaired.assignments.count == original.spaces.flatMap(\.tabs).count, "Unusable restored focus/assignment references resolve only to valid window/tab identities")
        rejects(.duplicateWindow, "Duplicate restored window identities are rejected") { _ = try BrowserWindowWorkspace(session: original, windows: [bad, bad]) }
        var empty = Session(); empty.spaces = []
        var emptyWorkspace = try BrowserWindowWorkspace(session: empty)
        let blankWindow = try emptyWorkspace.openWindow(id: UUID())
        check(emptyWorkspace.session(for: blankWindow.id)?.spaces.first?.tabs.count == 1, "An empty session repairs to the existing usable blank-tab behavior")
        check(original.spaces[0].tabs[0].title == "First" && original.spaces.count == 2 && original.spaces[0].tabs[1].folder == nil, "Window projections and edits never mutate the caller's original value")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-window-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = MetadataStore(url: temp.appendingPathComponent("session.sealed"), key: SymmetricKey(size: .bits256))
        var legacy = BrowserDocument(session: original)
        legacy.formatVersion = 5
        legacy.preferences.archiveAfterDays = 3
        try storage.save(legacy)
        var migrated = try storage.load(BrowserDocument.self)!
        try migrated.repairProfiles()
        check(migrated.formatVersion == 6 && migrated.windowRestore == nil && migrated.session == original && migrated.preferences.archiveAfterDays == 3,
              "An encrypted format-5 document migrates to format 6 with its tabs and preferences intact")

        let bounds = CGRect(x: -1400, y: 24, width: 1400, height: 850)
        let outside = BrowserWindowFrame(x: -10_000, y: 10_000, width: 4000, height: 600)
        let clipped = outside.constrained(to: bounds)
        check(clipped.map { bounds.contains($0) && $0.width <= bounds.width } == true,
              "A stored window outside the current display is fully contained on the selected display")
        let invalidFrame = BrowserWindowFrame(x: .infinity, y: 0, width: 500, height: -1)
        check(invalidFrame.constrained(to: bounds) == nil,
              "A non-finite or non-positive stored frame requests the default window position")

        let firstRecord = BrowserWindowRestoreRecord(selection: bad, frame: invalidFrame)
        let secondRecord = BrowserWindowRestoreRecord(selection: BrowserWindowSelection(id: b, session: original), frame: outside,
                                                      sidebarWidth: 308, sidebarVisible: false)
        let staleTab = UUID()
        migrated.windowRestore = BrowserWindowRestoreState(records: [firstRecord, secondRecord, secondRecord],
                                                            focusedWindowID: b, assignments: [first: b, staleTab: b])
        try migrated.repairProfiles()
        try storage.save(migrated)
        let encrypted = try Data(contentsOf: storage.url)
        let restoredDocument = try storage.load(BrowserDocument.self)!
        let windows = restoredDocument.windowRestore!
        check(windows.records.map(\.selection.id) == [bad.id, b] && windows.focusedWindowID == b,
              "Encrypted restoration keeps valid window order and focus and drops duplicate window IDs")
        check(windows.records[0].selection.spaceID == personal && windows.records[0].selection.selectedTabsBySpace[personal] == first && windows.records[0].frame == nil,
              "Bad selection references and geometry repair without discarding the window")
        check(windows.assignments[first] == b && windows.assignments[staleTab] == nil && windows.records[1].frame == outside,
              "A valid assignment and geometry survive encryption while a nonexistent tab assignment is removed")
        check(windows.records[0].sidebarWidth == nil && windows.records[0].sidebarVisible == nil &&
              windows.records[1].sidebarWidth == 308 && windows.records[1].sidebarVisible == false,
              "Older records default their sidebar layout and new records preserve width and visibility through encryption")
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let canonical = try canonicalEncoder.encode(windows)
        let canonicallyRestored = try JSONDecoder().decode(BrowserWindowRestoreState.self, from: canonical)
        let reencoded = try canonicalEncoder.encode(canonicallyRestored)
        check(canonical == reencoded, "Window selections and assignments have stable canonical serialization after relaunch")
        check(encrypted.range(of: Data("https://first.invalid/".utf8)) == nil && restoredDocument.session.spaces.flatMap(\.tabs).count == 3,
              "Window restoration data uses the existing encrypted vault and leaves the tab library intact")

        let encoded = try JSONEncoder().encode(migrated)
        var malformed = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var restoreObject = malformed["windowRestore"] as! [String: Any]
        var records = restoreObject["records"] as! [[String: Any]]
        records[0]["sidebarWidth"] = "wide"
        records[1]["sidebarWidth"] = 99999
        records[1]["sidebarVisible"] = "closed"
        restoreObject["records"] = records
        malformed["windowRestore"] = restoreObject
        var repairedLayout = try JSONDecoder().decode(BrowserDocument.self, from: JSONSerialization.data(withJSONObject: malformed))
        try repairedLayout.repairProfiles()
        check(repairedLayout.windowRestore?.records.count == 2 && repairedLayout.windowRestore?.focusedWindowID == b &&
              repairedLayout.windowRestore?.records.allSatisfy { $0.sidebarWidth == nil && $0.sidebarVisible == nil } == true &&
              repairedLayout.windowRestore?.records[1].frame == outside,
              "Malformed sidebar options fall back to default without dropping saved windows or geometry")
        malformed["windowRestore"] = 47
        var recovered = try JSONDecoder().decode(BrowserDocument.self, from: JSONSerialization.data(withJSONObject: malformed))
        try recovered.repairProfiles()
        check(recovered.windowRestore == nil && recovered.session.spaces.flatMap(\.tabs).count == 3,
              "An unreadable window block falls back to one default window while the tab library remains recoverable")

        print("Window workspace checks: \(checks) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
