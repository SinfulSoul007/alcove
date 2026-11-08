import Foundation

public struct PageRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var url: String
    public var date: Date
    public init(title: String, url: String, date: Date = Date()) { id = UUID(); self.title = title; self.url = url; self.date = date }
}
public struct BrowserLibrary: Codable {
    public var favoriteTabs: [Tab]?
    public var quickPages: [QuickPage]?
    public var bookmarks: [PageRecord] = []
    public var history: [PageRecord] = []
    public var closedTabs: [Tab] = []
    public var archive: [Tab] = []
    public init() {}
    public mutating func record(title: String, url: String) {
        guard let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        if history.first?.url == url { history.removeFirst() }
        history.insert(PageRecord(title: title, url: url), at: 0)
        history = Array(history.prefix(1000))
    }
    public mutating func bookmark(title: String, url: String) {
        guard let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        bookmarks.removeAll { $0.url == url }
        bookmarks.insert(PageRecord(title: title, url: url), at: 0)
    }
}
public struct Preferences: Codable {
    public var suspendTabs = false
    public var archiveAfterDays = 0
    public var appearance: AppearanceSettings?
    public var onboardingCompleted: Bool? = false
    public var automaticUpdateChecks: Bool? = false
    public var updateChannel: String? = "preview"
    public var quickBrowseExternalLinks: Bool? = true
    public var quickBrowseArchiveHours: Int? = 6
    public var quickDomainChoices: [QuickDomainChoice]?
    public init() {}
}
public struct BrowserDocument: Codable {
    public var formatVersion: Int?
    public var session: Session
    public var library: BrowserLibrary
    public var preferences: Preferences
    public var profiles: [BrowserProfile]?
    public var profileLibraries: [ProfileLibrary]?
    public init(session: Session = Session(), library: BrowserLibrary = BrowserLibrary(), preferences: Preferences = Preferences(), profiles: [BrowserProfile]? = nil, profileLibraries: [ProfileLibrary]? = nil) {
        formatVersion = 3; self.session = session; self.library = library; self.preferences = preferences; self.profiles = profiles; self.profileLibraries = profileLibraries
    }
}
