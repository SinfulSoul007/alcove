import Foundation
import BrowserCore
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) { if value() { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 } }
let namedID = UUID()
var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserDocument())) as! [String: Any]
root["profiles"] = [["id": namedID.uuidString, "name": "Work", "icon": "briefcase.fill"]]
var namedLibrary = BrowserLibrary(); namedLibrary.bookmark(title: "Only in Work", url: "https://example.com/work-only")
root["profileLibraries"] = [["profileID": namedID.uuidString, "library": try JSONSerialization.jsonObject(with: JSONEncoder().encode(namedLibrary))]]
let incoming = try JSONSerialization.data(withJSONObject: root)
let decoded = try JSONDecoder().decode(BrowserDocument.self, from: incoming)
let encoded = try JSONEncoder().encode(decoded)
let outgoing = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
check((outgoing["profiles"] as? [[String: Any]])?.first?["id"] as? String == namedID.uuidString, "Profile registry survives encrypted-document encoding")
check(String(decoding: encoded, as: UTF8.self).contains("work-only"), "Named-profile library records survive document encoding")
var legacy = BrowserDocument(library: namedLibrary)
try legacy.repairProfiles()
check(legacy.profiles?.count == 1 && legacy.profiles?.first?.isDefault == true, "Legacy documents gain one default profile")
check(legacy.session.spaces.allSatisfy { $0.effectiveProfileID == BrowserProfile.defaultID }, "Existing Spaces retain the default website store")
check(legacy.library(for: BrowserProfile.defaultID).bookmarks.first?.url == "https://example.com/work-only", "Legacy library records survive default-profile migration")
let profile = BrowserProfile(name: "  Work  ", icon: "briefcase.fill")
var multi = BrowserDocument(library: namedLibrary, profiles: [.defaultProfile, profile])
try multi.repairProfiles()
check(multi.library(for: profile.id).bookmarks.isEmpty, "New profiles start without another profile's library")
var privateLibrary = BrowserLibrary(); privateLibrary.bookmark(title: "Work", url: "https://example.com/separate")
multi.setLibrary(privateLibrary, for: profile.id)
check(multi.library(for: BrowserProfile.defaultID).bookmarks.first?.url != multi.library(for: profile.id).bookmarks.first?.url, "Profile libraries stay independent")
check(multi.library.bookmarks.first?.url == "https://example.com/work-only", "Compatibility library exposes only default-profile records")
multi.setLibrary(BrowserLibrary(), for: BrowserProfile.defaultID)
try multi.repairProfiles()
check(multi.library.bookmarks.isEmpty && multi.library(for: BrowserProfile.defaultID).bookmarks.isEmpty, "An intentionally cleared profile never resurrects its compatibility snapshot")
let orphanID = UUID(); var orphanSpace = Space(name: "Missing registry"); orphanSpace.profileID = orphanID
var orphan = BrowserDocument(); orphan.session.spaces.append(orphanSpace); orphan.profileLibraries = [ProfileLibrary(profileID: namedID, library: namedLibrary)]
try orphan.repairProfiles()
check(orphan.profiles?.contains(where: { $0.id == orphanID }) == true && orphan.session.spaces.last?.profileID == orphanID, "Orphan Space preserves its cookie-store identifier")
check(orphan.profiles?.contains(where: { $0.id == namedID }) == true && orphan.library(for: namedID).bookmarks.count == 1, "Orphan library gains a recoverable profile without dropping records")
var zeroSpace = Space(name: "Invalid ID"); zeroSpace.profileID = BrowserProfile.zeroID
var invalid = BrowserDocument(profiles: [BrowserProfile(id: BrowserProfile.zeroID, name: "Invalid")], profileLibraries: [ProfileLibrary(profileID: BrowserProfile.zeroID, library: namedLibrary)])
invalid.session.spaces = [zeroSpace]; invalid.session.selectedSpace = zeroSpace.id
try invalid.repairProfiles()
let recoveredID = invalid.session.spaces[0].effectiveProfileID
check(recoveredID != BrowserProfile.zeroID && recoveredID != BrowserProfile.defaultID, "All-zero profile IDs recover into an isolated valid store")
check(invalid.profiles?.contains(where: { $0.id == recoveredID }) == true && invalid.library(for: recoveredID).bookmarks.count == 1, "Zero-ID repair keeps the Space, registry and library together")
try invalid.repairProfiles()
check(invalid.session.spaces[0].effectiveProfileID == recoveredID, "Profile normalization keeps recovered IDs stable")
var collidingLibrary = namedLibrary
collidingLibrary.bookmarks[0].url = "https://example.com/collision"
var duplicates = BrowserDocument(profiles: [profile, profile], profileLibraries: [ProfileLibrary(profileID: profile.id, library: namedLibrary), ProfileLibrary(profileID: profile.id, library: collidingLibrary)])
try duplicates.repairProfiles()
let preserved = duplicates.library(for: profile.id).bookmarks
check(duplicates.profiles?.filter { $0.id == profile.id }.count == 1, "Duplicate registry entries resolve to one profile")
check(preserved.count == 2 && Set(preserved.map(\.id)).count == 2, "Duplicate libraries preserve distinct records with colliding IDs")
var pending = profile; pending.pendingDeletion = true
duplicates.profiles = [profile, pending]; try duplicates.repairProfiles()
check(duplicates.profiles?.first(where: { $0.id == profile.id })?.isPendingDeletion == true, "Registry repair cannot clear a durable deletion marker")
let roundTrip = try JSONDecoder().decode(BrowserDocument.self, from: JSONEncoder().encode(duplicates))
check(roundTrip.library(for: profile.id).bookmarks.count == 2 && roundTrip.profiles?.contains(where: { $0.isPendingDeletion }) == true, "Named libraries and deletion state survive document relaunch")
check(BrowserProfile(name: "  ").name == "Profile" && BrowserProfile(name: String(repeating: "x", count: 100)).name.count == 60 && profile.name == "Work", "Profile names remain usable for native controls")
let repeatedTab = Tab(title: "Duplicated", url: "https://example.com")
var firstSpace = Space(name: "First", tabs: [repeatedTab])
var secondSpace = Space(name: "Second", tabs: [repeatedTab]); secondSpace.profileID = profile.id; secondSpace.id = firstSpace.id
var collisions = BrowserDocument(profiles: [.defaultProfile, profile]); collisions.session.spaces = [firstSpace, secondSpace]; collisions.session.selectedSpace = firstSpace.id
try collisions.repairProfiles()
check(Set(collisions.session.spaces.map(\.id)).count == 2, "Duplicate Space identities are repaired without dropping Spaces")
check(Set(collisions.session.spaces.flatMap(\.tabs).map(\.id)).count == 2 && collisions.session.spaces[1].selected == collisions.session.spaces[1].tabs[0].id, "Duplicate live tab identities cannot share a native view across profiles")
let regular = Tab(title: "Keep regular", url: "https://example.com/regular")
var shelfFavorite = Tab(title: "Keep Favorite", url: "https://example.com/favorite", pinned: true); shelfFavorite.id = regular.id; shelfFavorite.favorite = true
var shelfLibrary = BrowserLibrary(); shelfLibrary.favoriteTabs = [shelfFavorite]
var shelfCollision = BrowserDocument(library: shelfLibrary)
shelfCollision.session.spaces = [Space(name: "Regular", tabs: [regular])]
try shelfCollision.repairProfiles()
check(shelfCollision.session.spaces[0].tabs[0].url == regular.url && !shelfCollision.session.spaces[0].tabs[0].pinned, "A colliding Favorite identity cannot overwrite a regular tab")
check(shelfCollision.library.favoriteTabs?.first?.url == shelfFavorite.url && shelfCollision.library.favoriteTabs?.first?.id != regular.id, "A colliding unmounted Favorite is preserved under a fresh identity")
let repairedShelfID = shelfCollision.library.favoriteTabs?.first?.id
try shelfCollision.repairProfiles()
check(shelfCollision.library.favoriteTabs?.first?.id == repairedShelfID, "Favorite collision repair is stable on later launches")
exit(failures == 0 ? 0 : 1)
