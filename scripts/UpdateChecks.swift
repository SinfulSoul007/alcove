import Foundation
import BrowserCore

@main
struct UpdateChecks {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        // These literals follow SemVer's published precedence example.
        let precedence = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        let versions = precedence.compactMap(SemanticVersion.init)
        check(versions.count == precedence.count && zip(versions, versions.dropFirst()).allSatisfy { $0 < $1 }, "SemVer prerelease ordering follows the specification")
        check(SemanticVersion("v0.3.0-preview.10")! > SemanticVersion("0.3.0-preview.2")!, "Preview numbers compare numerically")
        check(SemanticVersion("1.10.0")! > SemanticVersion("1.9.99")!, "Minor versions compare numerically")
        check(SemanticVersion("1.0.0+build.1") == SemanticVersion("1.0.0+build.2"), "Build metadata does not change precedence")
        check(SemanticVersion("1.0.0-999999999999999999999999999999")! > SemanticVersion("1.0.0-99999999999999999999999999999")!, "Large prerelease numbers do not overflow")
        for malformed in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.3-01", "1.2.3-", "1.2.3-a..b", "1.2.3+", "1.2.3+one+two", "1.2.3/evil", " 1.2.3", "1.2.3\n", "V1.2.3", "1.2.3-é"] {
            check(SemanticVersion(malformed) == nil, "Malformed version rejected: \(String(reflecting: malformed))")
        }
        func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, assets: [[String: Any]]? = nil) throws -> Release {
            let base = String(tag.dropFirst(tag.hasPrefix("v") ? 1 : 0).split(separator: "-")[0])
            let filename = "Alcove-\(base)-universal-unsigned-preview.dmg"
            let object: [String: Any] = ["id": 1, "tag_name": tag, "name": "Release \(tag)", "body": "A changelog.\n- Fixes", "draft": draft, "prerelease": prerelease, "html_url": "https://untrusted.example/release", "assets": assets ?? [["name": filename, "browser_download_url": "https://github.com/SinfulSoul007/alcove/releases/download/\(tag)/\(filename)", "state": "uploaded", "size": 1234, "digest": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]]]
            return try JSONDecoder().decode(Release.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let stable = try release("v0.4.0")
        let preview = try release("v0.5.0-preview.2", prerelease: true)
        let drafts = try release("v9.0.0", draft: true)
        let releases = [drafts, preview, stable, try release("v0.5.0-preview.1", prerelease: true)]
        let stableOffer = try UpdateCatalog.latest(in: releases, installedTag: "v0.3.0-preview.1", channel: .stable)
        check(stableOffer?.tag == "v0.4.0", "Stable channel excludes preview releases and drafts")
        let previewOffer = try UpdateCatalog.latest(in: releases.reversed(), installedTag: "v0.3.0-preview.1", channel: .preview)
        check(previewOffer?.tag == "v0.5.0-preview.2", "Preview channel chooses greatest semantic version regardless of API order")
        check(stableOffer?.releaseURL.absoluteString == "https://github.com/SinfulSoul007/alcove/releases/tag/v0.4.0", "Release page is built from trusted repository, not API html_url")
        check(stableOffer?.notes == "A changelog.\n- Fixes", "GitHub changelog decoding preserves content")
        check(stableOffer?.asset.filename == "Alcove-0.4.0-universal-unsigned-preview.dmg", "Offer chooses the expected universal installer")
        check(stableOffer?.asset.verify(Data("abc".utf8)) == true && stableOffer?.asset.verify(Data("tampered".utf8)) == false, "Published SHA-256 accepts matching bytes and rejects tampering")
        check(try UpdateCatalog.latest(in: releases, installedTag: "v1.0.0", channel: .preview) == nil, "Update checks never offer a downgrade")
        check(try UpdateCatalog.latest(in: [stable], installedTag: "0.4.0+another-build", channel: .stable) == nil, "Same version with different build metadata is not an update")
        check(try UpdateCatalog.latest(in: [try release("v0.4.0-preview.1")], installedTag: "0.3.0", channel: .stable) == nil, "Semantic prerelease is excluded even if GitHub flag is false")
        check(try UpdateCatalog.latest(in: [try release("v0.4.0", prerelease: true)], installedTag: "0.3.0", channel: .stable) == nil, "GitHub prerelease flag excludes a stable-looking tag")
        var badInstalledRejected = false
        do { _ = try UpdateCatalog.latest(in: releases, installedTag: "unknown", channel: .preview) } catch { badInstalledRejected = true }
        check(badInstalledRejected, "Unknown installed version cannot cause an unsafe version comparison")
        let validDMG = "https://github.com/SinfulSoul007/alcove/releases/download/v0.4.0/Alcove-0.4.0-universal-unsigned-preview.dmg"
        let badURLs = [validDMG.replacingOccurrences(of: "https:", with: "http:"), validDMG.replacingOccurrences(of: "github.com/", with: "github.com.evil.example/"), validDMG.replacingOccurrences(of: "github.com/", with: "evil.example@github.com/"), validDMG + "?redirect=evil", validDMG + "#fragment", validDMG.replacingOccurrences(of: "github.com/", with: "github.com:443/"), validDMG.replacingOccurrences(of: "SinfulSoul007/alcove", with: "other/alcove"), validDMG.replacingOccurrences(of: "v0.4.0/", with: "v0.3.0/"), validDMG.replacingOccurrences(of: "/download/", with: "/download/x/../"), validDMG.replacingOccurrences(of: ".dmg", with: "%2Edmg")]
        for url in badURLs {
            let bad = try release("v0.4.0", assets: [["name": "Alcove-0.4.0-universal-unsigned-preview.dmg", "browser_download_url": url, "state": "uploaded", "size": 1234]])
            check(try UpdateCatalog.latest(in: [bad], installedTag: "0.3.0", channel: .preview) == nil, "Untrusted asset URL rejected: \(url)")
        }
        let zip = ["name": "Alcove-0.4.0-universal-unsigned-preview.zip", "browser_download_url": validDMG.replacingOccurrences(of: ".dmg", with: ".zip"), "state": "uploaded", "size": 1234] as [String: Any]
        let zipped = try release("v0.4.0", assets: [zip])
        check(try UpdateCatalog.latest(in: [zipped], installedTag: "0.3.0", channel: .preview)?.asset.filename.hasSuffix(".zip") == true, "ZIP is available when a DMG is absent")
        check(try UpdateCatalog.latest(in: [zipped], installedTag: "0.3.0", channel: .preview)?.asset.verify(Data()) == nil, "Missing digest is shown as unavailable, not verified")
        let invalidDigest = try release("v0.4.0", assets: [["name": "Alcove-0.4.0-universal-unsigned-preview.dmg", "browser_download_url": validDMG, "state": "uploaded", "size": 1234, "digest": "sha256:broken"]])
        check(try UpdateCatalog.latest(in: [invalidDigest], installedTag: "0.3.0", channel: .preview) == nil, "Malformed published digest rejects the installer")
        let invalidDMGWithZIP = try release("v0.4.0", assets: [zip, ["name": "Alcove-0.4.0-universal-unsigned-preview.dmg", "browser_download_url": validDMG, "state": "uploaded", "size": 1234, "digest": "sha256:broken"]])
        check(try UpdateCatalog.latest(in: [invalidDMGWithZIP], installedTag: "0.3.0", channel: .preview) == nil, "ZIP fallback requires an absent DMG, not a failed DMG validation")
        let incomplete = try release("v0.4.0", assets: [["name": "Alcove-0.4.0-universal-unsigned-preview.dmg", "browser_download_url": validDMG, "state": "new", "size": 0]])
        check(try UpdateCatalog.latest(in: [incomplete], installedTag: "0.3.0", channel: .preview) == nil, "An incomplete upload is never offered")
        let both = try release("v0.4.0", assets: [zip, ["name": "Alcove-0.4.0-universal-unsigned-preview.dmg", "browser_download_url": validDMG, "state": "uploaded", "size": 1234]])
        check(try UpdateCatalog.latest(in: [both], installedTag: "0.3.0", channel: .preview)?.asset.filename.hasSuffix(".dmg") == true, "DMG is preferred over ZIP")

        // Injection replaces only the external HTTP boundary; selection and decoding are real.
        let api = URL(string: "https://api.github.com/repos/SinfulSoul007/alcove/releases?per_page=100")!
        let fixture = Data("[{\"tag_name\":\"v0.4.0\",\"name\":null,\"body\":null,\"draft\":false,\"prerelease\":false,\"assets\":[{\"name\":\"Alcove-0.4.0-universal-unsigned-preview.zip\",\"browser_download_url\":\"https://github.com/SinfulSoul007/alcove/releases/download/v0.4.0/Alcove-0.4.0-universal-unsigned-preview.zip\",\"state\":\"uploaded\",\"size\":1234,\"digest\":null}]}]".utf8)
        var requests: [URLRequest] = []
        let controller = UpdateController(installedTag: "v0.3.0-preview.1", transport: { request in
            requests.append(request)
            return (fixture, HTTPURLResponse(url: api, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        check(requests.isEmpty && controller.result == nil, "Creating an update controller makes no network request")
        await controller.check(channel: .stable)
        check(controller.offer?.tag == "v0.4.0" && controller.error == nil && !controller.checking && controller.lastChecked != nil, "Successful update request publishes a decoded offer and completion time")
        check(requests.first?.url == api && requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "Update check uses public GitHub API without an account token")
        let rateLimited = UpdateController(installedTag: "0.3.0", transport: { _ in (Data(), HTTPURLResponse(url: api, statusCode: 403, httpVersion: nil, headerFields: nil)!) })
        await rateLimited.check(channel: .preview)
        check(rateLimited.error != nil && rateLimited.offer == nil && !rateLimited.checking, "GitHub errors leave no stale or unverified download offer")
        let corrupt = UpdateController(installedTag: "0.3.0", transport: { _ in (Data("not-json".utf8), HTTPURLResponse(url: api, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        await corrupt.check(channel: .preview)
        check(corrupt.error != nil && corrupt.result == nil, "Malformed release response reports an error")
        let redirected = UpdateController(installedTag: "0.3.0", transport: { _ in (fixture, HTTPURLResponse(url: URL(string: "https://evil.example/releases")!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        await redirected.check(channel: .preview)
        check(redirected.error != nil && redirected.offer == nil, "Response from a different API origin is rejected")
        var shouldFail = false
        let repeated = UpdateController(installedTag: "0.3.0", transport: { _ in (fixture, HTTPURLResponse(url: api, statusCode: shouldFail ? 429 : 200, httpVersion: nil, headerFields: nil)!) })
        await repeated.check(channel: .stable)
        shouldFail = true
        await repeated.check(channel: .preview)
        check(repeated.offer == nil && repeated.result == nil && repeated.error != nil, "A failed recheck clears the previous channel’s offer")
        let upToDate = UpdateController(installedTag: "0.5.0", transport: { _ in (fixture, HTTPURLResponse(url: api, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        await upToDate.check(channel: .stable)
        check(upToDate.result == .upToDate && upToDate.offer == nil, "Installed newer version yields an up-to-date result")
        let now = Date(timeIntervalSince1970: 1_000_000)
        check(UpdateCheckSchedule.isDue(lastAttempt: nil, now: now), "Opted-in installs can perform their first automatic check")
        check(!UpdateCheckSchedule.isDue(lastAttempt: now.addingTimeInterval(-86399), now: now), "Automatic attempts remain throttled through the first 24 hours")
        check(UpdateCheckSchedule.isDue(lastAttempt: now.addingTimeInterval(-86400), now: now), "Automatic checks become due again after a full day")
        check(UpdateCheckSchedule.isDue(lastAttempt: now.addingTimeInterval(600), now: now), "A clock rollback cannot suppress future automatic checks indefinitely")
        if failures > 0 { exit(1) }
        print("All update checks passed")
    }
}
