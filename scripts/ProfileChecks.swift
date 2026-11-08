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
legacy.repairProfiles()
check(legacy.profiles?.count == 1 && legacy.profiles?.first?.isDefault == true, "Legacy documents gain one default profile")
check(legacy.session.spaces.allSatisfy { $0.effectiveProfileID == BrowserProfile.defaultID }, "Existing Spaces retain the default website store")
check(legacy.library(for: BrowserProfile.defaultID).bookmarks.first?.url == "https://example.com/work-only", "Legacy library records survive default-profile migration")
let profile = BrowserProfile(name: "  Work  ", icon: "briefcase.fill")
var multi = BrowserDocument(library: namedLibrary, profiles: [.defaultProfile, profile])
multi.repairProfiles()
check(multi.library(for: profile.id).bookmarks.isEmpty, "New profiles start without another profile's library")
var privateLibrary = BrowserLibrary(); privateLibrary.bookmark(title: "Work", url: "https://example.com/separate")
multi.setLibrary(privateLibrary, for: profile.id)
check(multi.library(for: BrowserProfile.defaultID).bookmarks.first?.url != multi.library(for: profile.id).bookmarks.first?.url, "Profile libraries stay independent")
check(multi.library.bookmarks.first?.url == "https://example.com/work-only", "Compatibility library exposes only default-profile records")
multi.setLibrary(BrowserLibrary(), for: BrowserProfile.defaultID)
multi.repairProfiles()
check(multi.library.bookmarks.isEmpty && multi.library(for: BrowserProfile.defaultID).bookmarks.isEmpty, "An intentionally cleared profile never resurrects its compatibility snapshot")
let orphanID = UUID(); var orphanSpace = Space(name: "Missing registry"); orphanSpace.profileID = orphanID
var orphan = BrowserDocument(); orphan.session.spaces.append(orphanSpace); orphan.profileLibraries = [ProfileLibrary(profileID: namedID, library: namedLibrary)]
orphan.repairProfiles()
check(orphan.profiles?.contains(where: { $0.id == orphanID }) == true && orphan.session.spaces.last?.profileID == orphanID, "Orphan Space preserves its cookie-store identifier")
check(orphan.profiles?.contains(where: { $0.id == namedID }) == true && orphan.library(for: namedID).bookmarks.count == 1, "Orphan library gains a recoverable profile without dropping records")
var zeroSpace = Space(name: "Invalid ID"); zeroSpace.profileID = BrowserProfile.zeroID
var invalid = BrowserDocument(profiles: [BrowserProfile(id: BrowserProfile.zeroID, name: "Invalid")], profileLibraries: [ProfileLibrary(profileID: BrowserProfile.zeroID, library: namedLibrary)])
invalid.session.spaces = [zeroSpace]; invalid.session.selectedSpace = zeroSpace.id
invalid.repairProfiles()
let recoveredID = invalid.session.spaces[0].effectiveProfileID
check(recoveredID != BrowserProfile.zeroID && recoveredID != BrowserProfile.defaultID, "All-zero profile IDs recover into an isolated valid store")
check(invalid.profiles?.contains(where: { $0.id == recoveredID }) == true && invalid.library(for: recoveredID).bookmarks.count == 1, "Zero-ID repair keeps the Space, registry and library together")
invalid.repairProfiles()
check(invalid.session.spaces[0].effectiveProfileID == recoveredID, "Profile normalization keeps recovered IDs stable")
var collidingLibrary = namedLibrary
collidingLibrary.bookmarks[0].url = "https://example.com/collision"
var duplicates = BrowserDocument(profiles: [profile, profile], profileLibraries: [ProfileLibrary(profileID: profile.id, library: namedLibrary), ProfileLibrary(profileID: profile.id, library: collidingLibrary)])
duplicates.repairProfiles()
let preserved = duplicates.library(for: profile.id).bookmarks
check(duplicates.profiles?.filter { $0.id == profile.id }.count == 1, "Duplicate registry entries resolve to one profile")
check(preserved.count == 2 && Set(preserved.map(\.id)).count == 2, "Duplicate libraries preserve distinct records with colliding IDs")
var pending = profile; pending.pendingDeletion = true
duplicates.profiles = [profile, pending]; duplicates.repairProfiles()
check(duplicates.profiles?.first(where: { $0.id == profile.id })?.isPendingDeletion == true, "Registry repair cannot clear a durable deletion marker")
let roundTrip = try JSONDecoder().decode(BrowserDocument.self, from: JSONEncoder().encode(duplicates))
check(roundTrip.library(for: profile.id).bookmarks.count == 2 && roundTrip.profiles?.contains(where: { $0.isPendingDeletion }) == true, "Named libraries and deletion state survive document relaunch")
check(BrowserProfile(name: "  ").name == "Profile" && BrowserProfile(name: String(repeating: "x", count: 100)).name.count == 60 && profile.name == "Work", "Profile names remain usable for native controls")
exit(failures == 0 ? 0 : 1)
