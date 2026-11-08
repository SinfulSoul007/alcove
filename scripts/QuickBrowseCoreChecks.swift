import Foundation
import BrowserCore

var failures = 0
func check(_ result: Bool, _ name: String) { print("\(result ? "PASS" : "FAIL"): \(name)"); if !result { failures += 1 } }
let personal = BrowserProfile.defaultID
let work = BrowserProfile(name: "Work")
let paused = BrowserProfile(name: "Paused")
let choices = [QuickDomainChoice(host: "example.com", profileID: work.id), QuickDomainChoice(host: "paused.example", profileID: paused.id)]
let available: Set<UUID> = [personal, work.id]
check(QuickBrowseRouting.host(for: URL(string: "https://EXAMPLE.com.:8443/path?q=1")!) == "example.com", "External routing canonicalizes the actual hostname independently of path and port")
check(QuickBrowseRouting.profile(for: URL(string: "https://example.com/a")!, choices: choices, available: available, fallback: personal) == work.id, "A remembered exact hostname opens its chosen profile")
check(QuickBrowseRouting.profile(for: URL(string: "https://sub.example.com")!, choices: choices, available: available, fallback: personal) == personal, "Remembered routing does not capture unchosen subdomains")
check(QuickBrowseRouting.profile(for: URL(string: "https://example.com.evil.test")!, choices: choices, available: available, fallback: personal) == personal, "A lookalike hostname cannot inherit another site's profile")
check(QuickBrowseRouting.profile(for: URL(string: "https://paused.example")!, choices: choices, available: available, fallback: personal) == nil, "A paused remembered profile never silently falls back to another account")
for invalid in ["file:///tmp/example.com", "javascript://example.com", "https:example.com", "about:blank", "https://."] {
    check(QuickBrowseRouting.profile(for: URL(string: invalid)!, choices: choices, available: available, fallback: personal) == nil, "External dispatch rejects unsupported or hostless URL: \(invalid)")
}
check(QuickBrowseRouting.profile(for: URL(string: "http://127.0.0.1:9000/")!, choices: [], available: [], fallback: personal) == nil, "External dispatch refuses to create storage when no profile is available")
check(QuickBrowseRouting.profile(for: URL(string: "http://[::1]:9000/")!, choices: [QuickDomainChoice(host: "::1", profileID: work.id)], available: available, fallback: personal) == work.id, "IPv6 domain choices retain their profile independently of URL brackets and ports")
check(QuickBrowseRouting.host(for: URL(string: "https://bücher.example/")!) == "xn--bcher-kva.example", "Internationalized hostname routing uses its canonical DNS identity")
let now = Date(timeIntervalSince1970: 100_000)
check(QuickBrowsePolicy.archiveCutoff(hours: nil, now: now) == Date(timeIntervalSince1970: 78_400), "Default quick inactivity policy retains the most recent six hours")
check(QuickBrowsePolicy.archiveCutoff(hours: 0, now: now) == nil, "Disabling quick auto-archive leaves every window open")
check(QuickBrowsePolicy.archiveCutoff(hours: -1, now: now) == Date(timeIntervalSince1970: 78_400), "Corrupt negative archive preferences cannot immediately close all pages")
let regular = Tab(title: "Keep Space page", url: "https://example.com/regular")
var favorite = Tab(title: "Keep Favorite", url: "https://example.com/favorite", pinned: true); favorite.favorite = true
let source = Space(name: "Personal", tabs: [regular, favorite])
var quickTab = Tab(title: "Keep quick page", url: "https://example.com/quick"); quickTab.id = regular.id
let duplicate = QuickPage(tab: quickTab, intendedSpaceID: source.id, openedAt: now, lastActiveAt: now)
var otherQuick = duplicate; otherQuick.tab.title = "Keep second quick page"; otherQuick.tab.url = "https://example.com/second"
var library = BrowserLibrary(); library.quickPages = [duplicate, otherQuick]
var workLibrary = BrowserLibrary(); var workQuick = duplicate; workQuick.intendedSpaceID = source.id; workLibrary.quickPages = [workQuick]
var doc = BrowserDocument(profiles: [.defaultProfile, work], profileLibraries: [ProfileLibrary(profileID: personal, library: library), ProfileLibrary(profileID: work.id, library: workLibrary)])
doc.formatVersion = 2; doc.session.spaces = [source]; doc.session.selectedSpace = source.id
try doc.repairProfiles()
let allQuick = (doc.profileLibraries ?? []).flatMap { $0.library.quickPages ?? [] }
let ids = doc.session.spaces.flatMap(\.tabs).map(\.id) + allQuick.map(\.id)
check(doc.formatVersion == 3 && allQuick.count == 3 && Set(ids).count == ids.count, "Format-2 migration preserves colliding quick/live pages with globally unique native identities")
check(doc.session.spaces[0].tabs[0].url == regular.url && doc.library(for: personal).quickPages?.first?.tab.url == quickTab.url, "Quick-page repair cannot overwrite an existing Space tab")
check(doc.library(for: personal).quickPages?.first?.intendedSpaceID == source.id && doc.library(for: work.id).quickPages?.first?.intendedSpaceID == nil, "Quick destinations are retained only for Spaces in their actual owning profile")
let originalIDs = allQuick.map(\.id)
try doc.repairProfiles()
check((doc.profileLibraries ?? []).flatMap { $0.library.quickPages ?? [] }.map(\.id) == originalIDs, "Quick identity repair stays stable across repeated launches")
var repeatedLibrary = BrowserLibrary(); repeatedLibrary.quickPages = [duplicate, duplicate]
var repeatedDoc = BrowserDocument(profileLibraries: [ProfileLibrary(profileID: personal, library: repeatedLibrary)])
repeatedDoc.session.spaces = [source]; try repeatedDoc.repairProfiles()
check(repeatedDoc.library.quickPages?.count == 1, "Repairing a duplicated quick record colliding with a live tab opens only one recovered window")
let roundTrip = try JSONDecoder().decode(BrowserDocument.self, from: JSONEncoder().encode(doc))
check(roundTrip.library(for: work.id).quickPages?.first?.tab.url == quickTab.url, "Profile-owned quick pages survive encrypted-document encoding")
let orphan = UUID(); var orphanDoc = BrowserDocument(profileLibraries: [ProfileLibrary(profileID: orphan, library: workLibrary)])
try orphanDoc.repairProfiles()
check(orphanDoc.profiles?.contains(where: { $0.id == orphan }) == true && orphanDoc.library(for: orphan).quickPages?.count == 1, "An orphan quick library retains its original website-store identity")
var incomingLibrary = BrowserLibrary(); incomingLibrary.quickPages = [duplicate, otherQuick]
var merged = BrowserLibrary(); merged.quickPages = [duplicate]; merged.mergePreservingRecords(incomingLibrary)
check(merged.quickPages?.count == 2, "Duplicate library merge preserves distinct quick records without duplicating identical ones")
var collidingMerge = BrowserLibrary(); collidingMerge.quickPages = [duplicate]
var repeatedIncoming = BrowserLibrary(); repeatedIncoming.quickPages = [otherQuick, otherQuick]
collidingMerge.mergePreservingRecords(repeatedIncoming)
check(collidingMerge.quickPages?.count == 2, "Merging duplicate incoming quick records after an ID repair does not create extra windows")
var clean = BrowserDocument(profiles: [.defaultProfile, work]); clean.preferences.quickDomainChoices = [QuickDomainChoice(host: "EXAMPLE.com.", profileID: work.id), QuickDomainChoice(host: "example.com", profileID: personal), QuickDomainChoice(host: "gone.test", profileID: UUID()), QuickDomainChoice(host: "evil.test/path", profileID: personal)]
try clean.repairProfiles()
check(clean.preferences.quickDomainChoices?.count == 1 && clean.preferences.quickDomainChoices?.first?.host == "example.com" && clean.preferences.quickDomainChoices?.first?.profileID == work.id, "Routing repair removes invalid/deleted destinations and keeps the newest exact-host choice")
var future = doc; future.formatVersion = 999
var rejected = false
do { try future.repairProfiles() } catch { rejected = true }
check(rejected && future.formatVersion == 999, "Unknown future quick metadata refuses normalization without downgrading its version")
exit(failures == 0 ? 0 : 1)
