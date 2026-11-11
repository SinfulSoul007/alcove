import AppKit
import BrowserCore
import CryptoKit

@main struct WriterOwnershipChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout,nil)
        let key = SymmetricKey(data:Data(repeating:7,count:32)) // Owned fixture only; never a real Keychain key.
        let args = CommandLine.arguments
        if args.count == 3, ["hold","probe"].contains(args[1]) {
            let root = URL(fileURLWithPath:args[2])
            let store = BrowserStore(dataRoot:root,keyProvider:{_ in key})
            if args[1] == "probe" { let owned = store.savingEnabled; store.shutdown(); exit(owned ? 0 : 2) }
            guard store.savingEnabled else { exit(3) }
            store.session.spaces[0].tabs[0].url = "https://example.com/owner"; store.flush()
            try Data().write(to:root.appendingPathComponent("ready"))
            let deadline = ContinuousClock.now.advanced(by:.seconds(60))
            while !FileManager.default.fileExists(atPath:root.appendingPathComponent("stop").path), ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
            store.shutdown(); exit(0)
        }
        var failures = 0
        func check(_ value:Bool,_ name:String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var children:[Process] = []
        defer { for child in children where child.isRunning { child.terminate() } }
        func launch(_ mode:String,_ path:URL) throws -> Process {
            let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); child.arguments = [mode,path.path]
            child.standardOutput = Pipe(); child.standardError = child.standardOutput; try child.run(); children.append(child); return child
        }
        func ready(_ child:Process,_ path:URL) async throws {
            for _ in 0..<500 where child.isRunning && !FileManager.default.fileExists(atPath:path.appendingPathComponent("ready").path) { try await Task.sleep(for:.milliseconds(10)) }
            guard child.isRunning && FileManager.default.fileExists(atPath:path.appendingPathComponent("ready").path) else { throw CocoaError(.executableLoad) }
        }
        func finish(_ child:Process) async throws -> Int32 {
            for _ in 0..<500 where child.isRunning { try await Task.sleep(for:.milliseconds(10)) }
            if child.isRunning { child.terminate(); throw CocoaError(.executableRuntimeMismatch) }
            return child.terminationStatus
        }
        let shared = root.appendingPathComponent("shared")
        let holder = try launch("hold",shared); try await ready(holder,shared)
        let sealed = shared.appendingPathComponent("session-v2.sealed"), before = try Data(contentsOf:sealed)
        var keyRequests = 0
        let contender = BrowserStore(dataRoot:shared,keyProvider:{ _ in keyRequests += 1; return key })
        check(!contender.savingEnabled && contender.awaitingInitialMetadata && contender.profileInUse && keyRequests == 0, "A second process cannot claim saved data or request its key")
        var refusedRetries = 0
        for _ in 0..<20 { if !contender.unlockLocalData(keyProvider:{ keyRequests += 1; return key }) { refusedRetries += 1 } }
        check(refusedRetries == 20 && keyRequests == 0 && !contender.unlocking, "Repeated busy retries never start a key lookup")
        let lockPath = shared.appendingPathComponent("metadata-writer.lock")
        let lockAttributes = try FileManager.default.attributesOfItem(atPath:lockPath.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath:shared.path)
        check((lockAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Ownership files and profile directories remain accessible only to their owner")
        var refused = false
        do { try MetadataStore(url:sealed,key:key).save(BrowserDocument()) } catch { refused = true }
        check(refused, "Direct metadata saves cooperate with another process's ownership")
        contender.session.spaces[0].tabs[0].url = "https://example.com/contender"; contender.flush()
        check(try Data(contentsOf:sealed) == before, "Blocked secondary writes preserve the current owner's ciphertext")
        var privateKeys = 0
        let privateStore = BrowserStore(isPrivate:true,dataRoot:shared,keyProvider:{ _ in privateKeys += 1; return key })
        check(privateKeys == 0 && privateStore.privateDataStore?.isPersistent == false, "Private browsing stays independent of another process's ownership")
        privateStore.shutdown()
        try Data().write(to:shared.appendingPathComponent("stop")); check(try await finish(holder) == 0, "The original process closes normally")
        check(contender.unlockLocalData(keyProvider:{key}), "The secondary process can retry when the owner exits")
        for _ in 0..<500 where contender.unlocking { try await Task.sleep(for:.milliseconds(10)) }
        check(contender.savingEnabled && contender.selectedTab?.url == "https://example.com/owner", "Retry restores the original saved session without the blocked draft")
        contender.shutdown()
        let released = try launch("probe",shared)
        check(try await finish(released) == 0, "Shutdown releases ownership even while the closed store is retained")
        let aliases = root.appendingPathComponent("aliases")
        let first = BrowserStore(dataRoot:aliases,keyProvider:{ _ in key })
        let second = BrowserStore(dataRoot:aliases.appendingPathComponent("../aliases"),keyProvider:{ _ in key })
        check(first.savingEnabled && second.savingEnabled, "Same-process owners share one canonical-directory lease")
        first.shutdown()
        let stillHeld = try launch("probe",aliases)
        check(try await finish(stillHeld) == 2, "Closing one in-process lease cannot unlock another live owner")
        second.shutdown()
        let lastReleased = try launch("probe",aliases)
        check(try await finish(lastReleased) == 0, "The last in-process lease releases the OS lock")
        let crashRoot = root.appendingPathComponent("crash")
        let crashing = try launch("hold",crashRoot); try await ready(crashing,crashRoot); crashing.terminate(); _ = try await finish(crashing)
        let afterCrash = BrowserStore(dataRoot:crashRoot,keyProvider:{ _ in key })
        check(afterCrash.savingEnabled, "An ungraceful process exit does not leave a stale ownership lock")
        afterCrash.shutdown()
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at:unsafe,withIntermediateDirectories:true)
        let sentinel = root.appendingPathComponent("sentinel"); try Data("keep".utf8).write(to:sentinel)
        try FileManager.default.createSymbolicLink(at:unsafe.appendingPathComponent("metadata-writer.lock"),withDestinationURL:sentinel)
        var unsafeKeys = 0
        let symlinked = BrowserStore(dataRoot:unsafe,keyProvider:{ _ in unsafeKeys += 1; return key })
        check(!symlinked.savingEnabled && unsafeKeys == 0, "An unsafe symlink lock fails closed before requesting a key")
        symlinked.shutdown(); check(try String(contentsOf:sentinel,encoding:.utf8) == "keep", "Unsafe ownership files are never followed or overwritten")
        let hardlinked = root.appendingPathComponent("hardlink")
        try FileManager.default.createDirectory(at:hardlinked,withIntermediateDirectories:true)
        try FileManager.default.linkItem(at:sentinel,to:hardlinked.appendingPathComponent("metadata-writer.lock"))
        var hardlinkKeys = 0
        let aliasedFile = BrowserStore(dataRoot:hardlinked,keyProvider:{ _ in hardlinkKeys += 1; return key })
        check(!aliasedFile.savingEnabled && hardlinkKeys == 0, "A hard-linked control file fails closed before key access")
        aliasedFile.shutdown()
        check(FileManager.default.fileExists(atPath:lockPath.path), "Releasing ownership preserves the lock inode for future processes")
        for replaceDirectory in [false,true] {
            let changed = root.appendingPathComponent(replaceDirectory ? "replaced-directory" : "replaced-lock")
            let original = BrowserStore(dataRoot:changed,keyProvider:{_ in key})
            if replaceDirectory { try FileManager.default.moveItem(at:changed,to:root.appendingPathComponent("old-directory")) }
            else { try FileManager.default.moveItem(at:changed.appendingPathComponent("metadata-writer.lock"),to:changed.appendingPathComponent("old-lock")) }
            let replacement = try launch("hold",changed); try await ready(replacement,changed)
            let replacementURL = changed.appendingPathComponent("session-v2.sealed")
            let replacementBytes = try Data(contentsOf:replacementURL)
            var browserRefused = false, rawRefused = false
            do { try original.renameSpace(original.space.id,name:"Stale overwrite") } catch { browserRefused = true }
            do { try MetadataStore(url:replacementURL,key:key).save(BrowserDocument()) } catch { rawRefused = true }
            check(browserRefused && rawRefused, "Settled \(replaceDirectory ? "directory" : "lock inode") replacement invalidates the original writer")
            check(try Data(contentsOf:replacementURL) == replacementBytes, "A replacement owner's ciphertext survives every stale save attempt")
            try Data().write(to:changed.appendingPathComponent("stop")); _ = try await finish(replacement)
            original.shutdown()
        }
        let targetA = root.appendingPathComponent("target-a"), targetB = root.appendingPathComponent("target-b")
        let destination = BrowserStore(dataRoot:targetB,keyProvider:{_ in key}); destination.shutdown()
        let untouched = try Data(contentsOf:targetB.appendingPathComponent("session-v2.sealed"))
        try FileManager.default.createDirectory(at:targetA,withIntermediateDirectories:true)
        let alias = root.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:targetA)
        let bound = BrowserStore(dataRoot:alias,keyProvider:{_ in key})
        let stableAlias = BrowserStore(dataRoot:targetA,keyProvider:{_ in key})
        check(bound.savingEnabled && stableAlias.savingEnabled, "A stable symlink alias shares canonical ownership")
        stableAlias.shutdown()
        try FileManager.default.removeItem(at:alias); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:targetB)
        bound.session.spaces[0].name = "Still target A"; bound.flush()
        let savedA = try MetadataStore(url:targetA.appendingPathComponent("session-v2.sealed"),key:key).load(BrowserDocument.self)
        let savedB = try Data(contentsOf:targetB.appendingPathComponent("session-v2.sealed"))
        check(savedA?.session.spaces[0].name == "Still target A" && savedB == untouched, "Retargeting a root alias cannot redirect the loaded session into another folder")
        bound.shutdown()
        let replacedRoot = root.appendingPathComponent("replaced-by-alias")
        let displaced = BrowserStore(dataRoot:replacedRoot,keyProvider:{_ in key})
        try FileManager.default.moveItem(at:replacedRoot,to:root.appendingPathComponent("displaced-folder"))
        try FileManager.default.createSymbolicLink(at:replacedRoot,withDestinationURL:targetB)
        var displacedRefused = false
        do { try displaced.renameSpace(displaced.space.id,name:"Do not write to B") } catch { displacedRefused = true }
        let afterDisplacement = try Data(contentsOf:targetB.appendingPathComponent("session-v2.sealed"))
        check(displacedRefused && afterDisplacement == untouched, "Replacing the canonical directory with a symlink cannot transfer a loaded writer")
        var retryKeys = 0
        let retryStarted = displaced.unlockLocalData(keyProvider:{ retryKeys += 1; return key })
        for _ in 0..<500 where displaced.unlocking { try await Task.sleep(for:.milliseconds(10)) }
        check(!retryStarted && retryKeys == 0 && !displaced.savingEnabled, "Retry after directory replacement refuses before requesting a key")
        check(try Data(contentsOf:targetB.appendingPathComponent("session-v2.sealed")) == untouched, "A rejected unlock retry preserves the replacement folder's ciphertext")
        displaced.shutdown()
        exit(failures == 0 ? 0 : 1)
    }
}
