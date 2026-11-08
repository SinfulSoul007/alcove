import AppKit
import WebKit
import CryptoKit
import BrowserCore

@main struct ProfileLifecycleChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root.appendingPathComponent("lifecycle"), keyProvider: { _ in key })
        let id = try store.createProfile(name: "To remove")
        let assignedSpace = store.space.id
        var rejected = false
        do { try await store.deleteProfile(id, removeStore: { _ in fatalError("Deleted assigned profile") }) } catch { rejected = true }
        check(rejected && store.profiles.contains(where: { $0.id == id }), "A profile with assigned Spaces cannot be deleted")
        rejected = false
        do { try await store.deleteProfile(BrowserProfile.defaultID, removeStore: { _ in fatalError("Deleted default profile") }) } catch { rejected = true }
        check(rejected && store.profiles.contains(where: \.isDefault), "Default profile remains available after a deletion request")
        try store.assignProfile(BrowserProfile.defaultID, to: assignedSpace)
        var savedLibrary = BrowserLibrary(); savedLibrary.bookmark(title: "Recoverable", url: "https://example.com/recoverable")
        store.setLibrary(savedLibrary, for: id); store.flush()
        try? store.renameProfile(id, name: "Renamed")
        check(store.profiles.first(where: { $0.id == id })?.name == "Renamed", "Profile rename persists without renaming its Spaces")
        var sawDurableMarker = false
        do {
            try await store.deleteProfile(id, removeStore: { removingID in
                let saved = try MetadataStore(url: store.sessionURL, key: key).load(BrowserDocument.self)!
                sawDurableMarker = removingID == id && saved.profiles?.first(where: { $0.id == id })?.isPendingDeletion == true
                throw CocoaError(.fileWriteNoPermission)
            })
        } catch {}
        check(sawDurableMarker, "Deletion marker is encrypted before website data removal begins")
        check(store.profiles.first(where: { $0.id == id })?.isPendingDeletion == true && store.library(for: id).bookmarks.count == 1, "Failed deletion preserves a retryable profile and its library")
        check(!store.websiteDataStore(forProfile: id).isPersistent, "A pending deletion cannot recreate persistent website storage")
        do { try await store.deleteProfile(id, removeStore: { _ in }) } catch {}
        check(!store.profiles.contains(where: { $0.id == id }) && store.library(for: id).bookmarks.isEmpty, "Successful retry removes the profile only after website removal")
        let final = try MetadataStore(url: store.sessionURL, key: key).load(BrowserDocument.self)!
        check(final.profiles?.contains(where: { $0.id == id }) == false && final.profileLibraries?.contains(where: { $0.profileID == id }) == false, "Completed deletion removes encrypted registry and library entries")
        let failureStore = BrowserStore(dataRoot: root.appendingPathComponent("failed-save"), keyProvider: { _ in key })
        let failingID = try failureStore.createProfile(name: "Existing")
        let tabID = failureStore.selectedID!
        failureStore.update(tabID) { $0.url = "about:blank" }; failureStore.flush()
        var live: WKWebView? = failureStore.view(for: tabID)
        let bytes = try Data(contentsOf: failureStore.sessionURL)
        let blocked = root.appendingPathComponent("blocked-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        failureStore.vault = MetadataStore(url: blocked, key: key)
        do { try failureStore.assignProfile(BrowserProfile.defaultID, to: failureStore.space.id) } catch {}
        check(failureStore.activeProfileID == failingID && failureStore.views[tabID] === live && !failureStore.savingEnabled, "Failed profile assignment preserves the live page and original profile")
        check(try Data(contentsOf: failureStore.sessionURL) == bytes, "Failed profile assignment leaves encrypted metadata unchanged")
        failureStore.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where failureStore.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(failureStore.session.spaces.flatMap(\.tabs).filter { $0.url == "about:blank" }.count == 1, "Unlock after a failed profile save does not duplicate unchanged tabs")
        check(failureStore.views[tabID] === live, "Unlock preserves a live page when its saved identity and profile agree")
        let profileCount = failureStore.profiles.count
        failureStore.vault = MetadataStore(url: blocked, key: key)
        do { _ = try failureStore.createProfile(name: "Must not appear") } catch {}
        check(failureStore.profiles.count == profileCount && failureStore.activeProfileID == failingID, "Failed creation cannot expose a profile without durable metadata")
        failureStore.close(tabID)
        failureStore.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where failureStore.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(failureStore.session.spaces.flatMap(\.tabs).allSatisfy { $0.url.isEmpty }, "Unlock does not resurrect tabs closed while local saving was paused")
        let fresh = BrowserStore(dataRoot: root.appendingPathComponent("fresh-recovery"), keyProvider: { _ in key })
        fresh.preferences.suspendTabs = true; fresh.finishOnboarding()
        fresh.vault = MetadataStore(url: blocked, key: key); fresh.preferences.suspendTabs = false; fresh.flush()
        fresh.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where fresh.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(fresh.savingEnabled && !fresh.preferences.suspendTabs, "First-run recovery preserves the user's latest preference after a failed save")
        let finishing = BrowserStore(dataRoot: root.appendingPathComponent("finalize"), keyProvider: { _ in key })
        let finishingID = try finishing.createProfile(name: "Finalize"); try finishing.assignProfile(BrowserProfile.defaultID, to: finishing.space.id)
        do { try await finishing.deleteProfile(finishingID, removeStore: { _ in finishing.vault = MetadataStore(url: blocked, key: key) }) } catch {}
        let unfinished = try MetadataStore(url: finishing.sessionURL, key: key).load(BrowserDocument.self)!
        check(!finishing.savingEnabled && finishing.profiles.first(where: { $0.id == finishingID })?.isPendingDeletion == true && unfinished.profiles?.first(where: { $0.id == finishingID })?.isPendingDeletion == true, "Final-save failure keeps a durable deletion marker after website removal")
        finishing.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where finishing.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        try? await finishing.deleteProfile(finishingID, removeStore: { _ in })
        check(!finishing.profiles.contains(where: { $0.id == finishingID }), "Unlock and retry can finalize a previously removed website store")
        let clearing = BrowserStore(dataRoot: root.appendingPathComponent("clear"), keyProvider: { _ in key })
        let clearA = try clearing.createProfile(name: "A"); let clearSpaceA = clearing.space.id
        clearing.update(clearing.selectedID!) { $0.url = "about:blank" }
        var aLibrary = BrowserLibrary(); aLibrary.record(title: "A", url: "https://example.com/a"); aLibrary.bookmark(title: "Keep A", url: "https://example.com/keep-a")
        clearing.setLibrary(aLibrary, for: clearA)
        let clearB = try clearing.createProfile(name: "B"); let clearTabB = clearing.selectedID!
        var bLibrary = BrowserLibrary(); bLibrary.record(title: "B", url: "https://example.com/b"); clearing.setLibrary(bLibrary, for: clearB)
        var liveB: WKWebView? = clearing.view(for: clearTabB)
        try? await clearing.clearProfileData(clearA)
        check(clearing.library(for: clearA).history.isEmpty && clearing.library(for: clearA).bookmarks.count == 1 && clearing.session.spaces.first(where: { $0.id == clearSpaceA })!.tabs.allSatisfy { $0.url.isEmpty }, "Clearing one profile resets its tabs and history while keeping bookmarks")
        check(clearing.library(for: clearB).history.count == 1 && clearing.views[clearTabB] === liveB, "Clearing a profile preserves another profile's history and live page")
        let privateRoot = root.appendingPathComponent("private-clear")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in fatalError("Private clear requested key") })
        try? await privateStore.clearProfileData(BrowserProfile.defaultID)
        check(!FileManager.default.fileExists(atPath: privateRoot.path), "Private website clearing never creates normal metadata")
        let closingDelete = BrowserStore(dataRoot: root.appendingPathComponent("close-delete"), keyProvider: { _ in key })
        let closingDeleteID = try closingDelete.createProfile(name: "Close during deletion")
        try closingDelete.assignProfile(BrowserProfile.defaultID, to: closingDelete.space.id)
        try? await closingDelete.deleteProfile(closingDeleteID, removeStore: { _ in closingDelete.shutdown() })
        let closedDeleteDocument = try MetadataStore(url: closingDelete.sessionURL, key: key).load(BrowserDocument.self)!
        check(closedDeleteDocument.profiles?.first(where: { $0.id == closingDeleteID })?.isPendingDeletion == true, "Closing a window prevents late deletion callbacks from overwriting its durable recovery state")
        let closingClear = BrowserStore(dataRoot: root.appendingPathComponent("close-clear"), keyProvider: { _ in key })
        let closingClearID = try closingClear.createProfile(name: "Close during clear")
        var duplicateRemoval = false
        var overlappingStore: BrowserStore?
        try? await closingClear.clearProfileData(closingClearID, removeData: { _ in
            closingClear.shutdown()
            overlappingStore = BrowserStore(dataRoot: root.appendingPathComponent("close-clear"), keyProvider: { _ in key })
            try? await overlappingStore!.clearProfileData(closingClearID, removeData: { _ in duplicateRemoval = true })
        })
        check(!duplicateRemoval, "A reopened window cannot start a second clear while the original WebKit operation is still active")
        let closedClearDocument = try MetadataStore(url: closingClear.sessionURL, key: key).load(BrowserDocument.self)!
        let rawClear = try JSONSerialization.jsonObject(with: JSONEncoder().encode(closedClearDocument)) as! [String: Any]
        let clearingEntry = (rawClear["profiles"] as? [[String: Any]])?.first(where: { $0["id"] as? String == closingClearID.uuidString })
        check(clearingEntry?["pendingDataClear"] as? Bool == true, "Window closure leaves unfinished website clearing durably marked")
        let resumedClear = BrowserStore(dataRoot: root.appendingPathComponent("close-clear"), keyProvider: { _ in key })
        check(resumedClear.profileUnavailable(closingClearID) && !resumedClear.websiteDataStore(forProfile: closingClearID).isPersistent, "Reopening cannot use a profile whose data clear was interrupted")
        let queuedTab = resumedClear.newTab(url: URL(string: "https://example.com/queued-during-clear"))
        try? await resumedClear.clearProfileData(closingClearID, removeData: { _ in })
        check(resumedClear.tab(queuedTab)?.url == "https://example.com/queued-during-clear", "Retrying a pending clear preserves links queued after its initial tab reset")
        check(!resumedClear.profileUnavailable(closingClearID), "Retrying interrupted website clearing restores the same profile safely")
        let upgradeRoot = root.appendingPathComponent("versioned-upgrade")
        var oldSession = Session(); oldSession.spaces[0].tabs[0].url = "about:blank"
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserDocument(session: oldSession))) as! [String: Any]
        for field in ["profiles", "profileLibraries", "formatVersion"] { oldObject.removeValue(forKey: field) }
        let legacyDocument = try JSONDecoder().decode(BrowserDocument.self, from: JSONSerialization.data(withJSONObject: oldObject))
        let legacyFile = upgradeRoot.appendingPathComponent("session.sealed")
        try MetadataStore(url: legacyFile, key: key).save(legacyDocument)
        let legacyBytes = try Data(contentsOf: legacyFile)
        var keyCreationRequests: [Bool] = []
        let upgrade = BrowserStore(dataRoot: upgradeRoot, keyProvider: { create in keyCreationRequests.append(create); return key })
        let newProfile = try upgrade.createProfile(name: "Must survive older readers")
        upgrade.update(upgrade.selectedID!) { $0.url = "https://example.com/profile-versioned" }; upgrade.flush()
        check(keyCreationRequests == [false], "Upgrading encrypted metadata requires the existing key")
        check(try Data(contentsOf: legacyFile) == legacyBytes, "Profile-enabled saves leave the pre-profile file intact for older readers")
        try MetadataStore(url: legacyFile, key: key).save(legacyDocument)
        let returned = BrowserStore(dataRoot: upgradeRoot, keyProvider: { _ in key })
        check(returned.profiles.contains(where: { $0.id == newProfile }) && returned.session.spaces.flatMap(\.tabs).contains(where: { $0.url == "https://example.com/profile-versioned" }), "Returning from an older preview keeps named-profile metadata intact")
        var futureObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(returned.makeDocument())) as! [String: Any]
        futureObject["formatVersion"] = 999; futureObject["futureCriticalField"] = "must remain intact"
        let futureBytes = try AES.GCM.seal(JSONSerialization.data(withJSONObject: futureObject), using: key).combined!
        try futureBytes.write(to: returned.sessionURL, options: .atomic)
        let future = BrowserStore(dataRoot: upgradeRoot, keyProvider: { _ in key }); future.flush()
        let protectedFutureBytes = try Data(contentsOf: returned.sessionURL)
        check(!future.savingEnabled && protectedFutureBytes == futureBytes, "An unsupported future format cannot be silently downgraded or overwritten")
        let lockedUpgradeRoot = root.appendingPathComponent("locked-versioned-upgrade")
        try MetadataStore(url: lockedUpgradeRoot.appendingPathComponent("session.sealed"), key: key).save(legacyDocument)
        let lockedUpgrade = BrowserStore(dataRoot: lockedUpgradeRoot, keyProvider: { _ in throw CocoaError(.fileReadNoPermission) })
        lockedUpgrade.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where lockedUpgrade.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(lockedUpgrade.savingEnabled && lockedUpgrade.selectedTab?.url == "about:blank", "Unlock can complete an encrypted pre-profile format migration")
        check(lockedUpgrade.archiveTimer?.isValid == true, "Unlock after startup failure restarts automatic tab archiving")
        for current in [clearing, privateStore] { for id in Array(current.views.keys) { current.discardView(id) } }
        liveB = nil
        for id in Array(failureStore.views.keys) { failureStore.discardView(id) }
        live = nil; failureStore.namedDataStores.removeAll()
        for current in [store, failureStore, fresh, finishing, clearing, closingDelete, closingClear, resumedClear, overlappingStore!, upgrade, returned, future, lockedUpgrade] { current.archiveTimer?.invalidate(); current.namedDataStores.removeAll() }
        await Task.yield()
        for ownedID in [id, failingID, finishingID, clearA, clearB, closingClearID] { try? await WKWebsiteDataStore.remove(forIdentifier: ownedID) }
        exit(failures == 0 ? 0 : 1)
    }
}
