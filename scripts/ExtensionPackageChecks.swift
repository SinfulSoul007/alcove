import Foundation
import Darwin
import zlib
import BrowserCore

@MainActor func runExtensionPackageChecks(_ check:@MainActor (Bool,String)->Void) async throws {
    let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer { try? manager.removeItem(at:root) }
    let source = root.appendingPathComponent("source"), stage = root.appendingPathComponent("stage"), packages = root.appendingPathComponent("packages")
    try manager.createDirectory(at:source,withIntermediateDirectories:true)
    let manifest = Data(#"{"manifest_version":3,"name":"Owned Package","version":"1","content_scripts":[{"matches":["https://example.com/*"],"js":["content.js"]}]}"#.utf8)
    try manifest.write(to:source.appendingPathComponent("manifest.json"))
    try Data("owned code".utf8).write(to:source.appendingPathComponent("content.js"))
    try manager.createDirectory(at:source.appendingPathComponent(".git"),withIntermediateDirectories:true)
    try Data("excluded".utf8).write(to:source.appendingPathComponent(".git/config"))
    let prepared = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    defer { try? prepared.discard() }
    check(prepared.source == .folder && prepared.manifest.name == "Owned Package" && prepared.digest.count == 64,"Folder inspection creates an unsigned, content-addressed package")
    let snapshotBytes = try Data(contentsOf:prepared.stagingURL.appendingPathComponent("content.js"))
    check(prepared.stagingURL != source && snapshotBytes == Data("owned code".utf8),"A prepared extension owns a resource snapshot rather than a live source folder")
    check(!manager.fileExists(atPath:prepared.stagingURL.appendingPathComponent(".git").path),"Folder import excludes source-control metadata")
    try Data("changed source".utf8).write(to:source.appendingPathComponent("content.js"))
    let id = UUID(), profile = BrowserProfile.defaultID
    let installed = try ExtensionPackage.publish(prepared,profileID:profile,extensionID:id,packagesRoot:packages)
    let installedBytes = try Data(contentsOf:installed.url.appendingPathComponent("content.js"))
    check(installed.created && installedBytes == Data("owned code".utf8),"Publication preserves the inspected code snapshot after source changes")
    check(installed.url.lastPathComponent == prepared.digest && installed.url.deletingLastPathComponent().lastPathComponent == id.uuidString && installed.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == profile.uuidString,"Installed paths contain only controlled account, package and digest components")
    try Data("owned code".utf8).write(to:source.appendingPathComponent("content.js"))
    let duplicate = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    let existing = try ExtensionPackage.publish(duplicate,profileID:profile,extensionID:id,packagesRoot:packages)
    check(!existing.created && existing.url == installed.url,"Publishing an existing immutable revision does not claim ownership of its cleanup")
    try duplicate.discard()
    check(manager.fileExists(atPath:installed.url.appendingPathComponent("manifest.json").path),"Discarding a duplicate preview cannot remove a published revision")
    let cancelled = try ExtensionPackage.prepare(at:source,stagingRoot:stage), cancelledURL = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    let cancelledPath = cancelled.stagingURL; try cancelled.discard(); try cancelled.discard(); try cancelledURL.discard()
    check(!manager.fileExists(atPath:cancelledPath.path),"Cancelling a preview removes only its owned staging directory and is repeatable")
    func rejected(_ body:()throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    let replacedRoot = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    let retired = root.appendingPathComponent("retired-stage")
    try manager.moveItem(at:stage,to:retired); try manager.createDirectory(at:stage,withIntermediateDirectories:true)
    let foreign = stage.appendingPathComponent(replacedRoot.stagingURL.lastPathComponent)
    try manager.createDirectory(at:foreign,withIntermediateDirectories:true)
    try Data("replacement directory".utf8).write(to:foreign.appendingPathComponent("sentinel"))
    check(rejected {_ = try ExtensionPackage.publish(replacedRoot,profileID:profile,extensionID:UUID(),packagesRoot:packages)},"Replacing a staging root invalidates its pending publication")
    try replacedRoot.discard()
    let foreignBytes = try Data(contentsOf:foreign.appendingPathComponent("sentinel"))
    check(foreignBytes == Data("replacement directory".utf8) && !manager.fileExists(atPath:retired.appendingPathComponent(replacedRoot.stagingURL.lastPathComponent).path),"Cleanup after a root replacement stays bound to its original owned directory")
    let beforeCancel = try manager.contentsOfDirectory(atPath:stage.path).sorted(), gate = OwnedExtensionPreparationGate()
    let operation = Task.detached { () -> Bool in
        await gate.wait()
        do { _ = try ExtensionPackage.prepare(at:source,stagingRoot:stage); return false }
        catch is CancellationError { return true }
        catch { return false }
    }
    operation.cancel(); await gate.open()
    let cancellationObserved = await operation.value, afterCancel = try manager.contentsOfDirectory(atPath:stage.path).sorted()
    check(cancellationObserved && beforeCancel == afterCancel,"A cancelled preparation task creates no preview or staging residue")
    let tampered = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    try Data("unreviewed code".utf8).write(to:tampered.stagingURL.appendingPathComponent("content.js"))
    check(rejected {_ = try ExtensionPackage.publish(tampered,profileID:profile,extensionID:UUID(),packagesRoot:packages)},"Changed staging bytes cannot be published under an earlier inspection digest")
    try tampered.discard()
    try Data("corrupted install".utf8).write(to:installed.url.appendingPathComponent("content.js"))
    let repair = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    check(rejected {_ = try ExtensionPackage.publish(repair,profileID:profile,extensionID:id,packagesRoot:packages)},"An existing damaged revision is reported without silently replacing its contents")
    try repair.discard()
    let outside = root.appendingPathComponent("outside"); try manager.createDirectory(at:outside,withIntermediateDirectories:true)
    let sentinel = outside.appendingPathComponent("sentinel"); try Data("untouched".utf8).write(to:sentinel)
    let rootLink = root.appendingPathComponent("source-link"); try manager.createSymbolicLink(at:rootLink,withDestinationURL:source)
    check(rejected {_ = try ExtensionPackage.prepare(at:rootLink,stagingRoot:stage)},"A selected source-directory symlink is rejected")
    let nestedLink = source.appendingPathComponent("linked.txt"); try manager.createSymbolicLink(at:nestedLink,withDestinationURL:sentinel)
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stage)},"Nested source links are rejected rather than copied from outside the selection")
    try manager.removeItem(at:nestedLink)
    let hardLink = source.appendingPathComponent("hardlink.txt"); try manager.linkItem(at:sentinel,to:hardLink)
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stage)},"Multiply linked source files cannot import an outside inode")
    try manager.removeItem(at:hardLink)
    let stageLink = root.appendingPathComponent("stage-link"); try manager.createSymbolicLink(at:stageLink,withDestinationURL:outside)
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stageLink)},"A staging-root symlink cannot redirect package writes")
    let redirected = root.appendingPathComponent("redirected-packages"); try manager.createDirectory(at:redirected,withIntermediateDirectories:true)
    try manager.createSymbolicLink(at:redirected.appendingPathComponent(profile.uuidString),withDestinationURL:outside)
    let redirectPreview = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    check(rejected {_ = try ExtensionPackage.publish(redirectPreview,profileID:profile,extensionID:UUID(),packagesRoot:redirected)},"An account-directory symlink cannot redirect publication")
    try redirectPreview.discard()
    let sentinelBytes = try Data(contentsOf:sentinel), outsideNames = try manager.contentsOfDirectory(atPath:outside.path)
    check(sentinelBytes == Data("untouched".utf8) && outsideNames == ["sentinel"],"Rejected package paths leave outside files untouched")
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stage,expectedStoreID:String(repeating:"a",count:32))},"An unsigned folder cannot impersonate a requested store identity")
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stage,requireStoreProof:true)},"Unsigned resources cannot claim a Web Store publisher proof")
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stage,limits:ExtensionPackageLimits(fileBytes:4))},"Source-file reads obey their actual byte cap")
    try manager.removeItem(at:source.appendingPathComponent("content.js"))
    check(rejected {_ = try ExtensionPackage.prepare(at:source,stagingRoot:stage)},"Manifest entry resources must exist before preview publication")
    try Data("owned code".utf8).write(to:source.appendingPathComponent("content.js"))
    func checksum(_ data:Data) -> UInt32 { data.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt($0.count))) } }
    var archiveManifest = OwnedZIPFile(); archiveManifest.name = "manifest.json"; archiveManifest.contents = manifest; archiveManifest.checksum = checksum(manifest)
    var archiveCode = OwnedZIPFile(); archiveCode.name = "content.js"; archiveCode.contents = Data("owned code".utf8); archiveCode.checksum = checksum(archiveCode.contents)
    let zip = root.appendingPathComponent("owned.zip"); try ownedZIP([archiveManifest,archiveCode]).write(to:zip)
    let zipped = try ExtensionPackage.prepare(at:zip,stagingRoot:stage)
    check(zipped.source == .zip && zipped.digest == prepared.digest,"Folder and ZIP copies of identical resources use the same deterministic content digest")
    try zipped.discard()
    var retainedLibrary = BrowserLibrary()
    retainedLibrary.extensions = [BrowserExtensionRecord(id:id,name:"Retained",version:"1",manifestVersion:3,packageDigest:prepared.digest,source:.folder)]
    let activePreview = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    let orphanPreview = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    let orphan = try ExtensionPackage.publish(orphanPreview,profileID:profile,extensionID:UUID(),packagesRoot:packages)
    let abandoned = stage.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at:abandoned,withIntermediateDirectories:true)
    try Data("abandoned".utf8).write(to:abandoned.appendingPathComponent("unused.txt"))
    let unknown = packages.appendingPathComponent("unrecognized-note")
    try Data("keep unknown files".utf8).write(to:unknown)
    let removed = try ExtensionPackage.reconcile(packagesRoot:packages,stagingRoot:stage,libraries:[ProfileLibrary(profileID:profile,library:retainedLibrary)])
    check(removed >= 2 && !manager.fileExists(atPath:orphan.url.path) && !manager.fileExists(atPath:abandoned.path),"Reconciliation removes only unreferenced controlled revisions and abandoned previews")
    check(manager.fileExists(atPath:installed.url.path) && manager.fileExists(atPath:activePreview.stagingURL.path) && manager.fileExists(atPath:unknown.path),"Reconciliation preserves catalog references, active previews and unrecognized files")
    try activePreview.discard()
    let linkedPackage = packages.appendingPathComponent(profile.uuidString).appendingPathComponent(UUID().uuidString)
    try manager.createSymbolicLink(at:linkedPackage,withDestinationURL:outside)
    check(rejected {_ = try ExtensionPackage.reconcile(packagesRoot:packages,stagingRoot:stage,libraries:[ProfileLibrary(profileID:profile,library:retainedLibrary)])},"Recognized package-directory links cannot redirect reconciliation")
    try manager.removeItem(at:linkedPackage)
    let retiredSource = root.appendingPathComponent("retired-source")
    var movedSource = false, sourceMutationError:Error?
    check(rejected {
        let value = try ExtensionPackage.prepare(at:source,stagingRoot:stage,progress:{ _ in
            if !movedSource {
                movedSource = true
                do {
                    try manager.moveItem(at:source,to:retiredSource)
                    try manager.createDirectory(at:source,withIntermediateDirectories:true)
                    try Data("replacement source".utf8).write(to:source.appendingPathComponent("sentinel"))
                } catch {sourceMutationError = error}
            }
        })
        try value.discard()
    },"A source-folder replacement after opening is rejected before staging publication")
    if let sourceMutationError {throw sourceMutationError}
    let replacementSourceBytes = try Data(contentsOf:source.appendingPathComponent("sentinel"))
    check(movedSource && replacementSourceBytes == Data("replacement source".utf8),"Pinned source import leaves a replacement folder untouched")
    try manager.removeItem(at:source); try manager.moveItem(at:retiredSource,to:source)
    var changedLink = false, linkMutationError:Error?
    check(rejected {
        let value = try ExtensionPackage.prepare(at:source,stagingRoot:stage,progress:{ _ in
            if !changedLink {
                changedLink = true
                do {try manager.removeItem(at:source.appendingPathComponent("content.js")); try manager.createSymbolicLink(at:source.appendingPathComponent("content.js"),withDestinationURL:sentinel)} catch {linkMutationError = error}
            }
        })
        try value.discard()
    },"A source file switched to an outside link during import is never followed")
    if let linkMutationError {throw linkMutationError}
    try manager.removeItem(at:source.appendingPathComponent("content.js")); try Data("owned code".utf8).write(to:source.appendingPathComponent("content.js"))
    let deepPreview = try ExtensionPackage.prepare(at:source,stagingRoot:stage)
    var deepPath = deepPreview.stagingURL
    for _ in 0..<65 { deepPath.appendPathComponent("nested") }
    try manager.createDirectory(at:deepPath,withIntermediateDirectories:true)
    check(rejected {try deepPreview.discard()},"Cleanup rejects an injected directory tree beyond the validated depth bound")
}

private actor OwnedExtensionPreparationGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true; continuation?.resume(); continuation = nil
    }
}
