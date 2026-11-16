import Foundation
import CoreGraphics

public struct BrowserWindowFrame: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0 }

    public func constrained(to visibleFrame: CGRect, minimumSize: CGSize = .zero) -> CGRect? {
        guard isValid, visibleFrame.minX.isFinite, visibleFrame.minY.isFinite,
              visibleFrame.maxX.isFinite, visibleFrame.maxY.isFinite,
              visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        let width = min(max(CGFloat(width), minimumSize.width), visibleFrame.width)
        let height = min(max(CGFloat(height), minimumSize.height), visibleFrame.height)
        let x = min(max(CGFloat(x), visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(CGFloat(y), visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct BrowserWindowRestoreRecord: Codable, Equatable {
    public let selection: BrowserWindowSelection
    public let frame: BrowserWindowFrame?
    public let sidebarWidth: Double?
    public let sidebarVisible: Bool?
    public let splitGroups: [BrowserSplitLayout]?

    public init(selection: BrowserWindowSelection, frame: BrowserWindowFrame? = nil,
                sidebarWidth: Double? = nil, sidebarVisible: Bool? = nil, splitGroups: [BrowserSplitLayout]? = nil) {
        self.selection = selection
        self.frame = frame
        self.sidebarWidth = SidebarSizing.validSavedWidth(sidebarWidth)
        self.sidebarVisible = sidebarVisible
        self.splitGroups = splitGroups.flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey { case selection, frame, sidebarWidth, sidebarVisible, splitGroups }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var groups: [BrowserSplitLayout] = []
        if var entries = try? values.nestedUnkeyedContainer(forKey: .splitGroups) {
            while !entries.isAtEnd {
                let entry = try entries.superDecoder()
                if let group = try? BrowserSplitLayout(from: entry) { groups.append(group) }
            }
        }
        self.init(selection: try values.decode(BrowserWindowSelection.self, forKey: .selection),
                  frame: try values.decodeIfPresent(BrowserWindowFrame.self, forKey: .frame),
                  sidebarWidth: try? values.decodeIfPresent(Double.self, forKey: .sidebarWidth),
                  sidebarVisible: try? values.decodeIfPresent(Bool.self, forKey: .sidebarVisible), splitGroups: groups)
    }
}

public struct BrowserWindowRestoreState: Codable, Equatable {
    public static let maximumRestoredWindows = 64
    public let records: [BrowserWindowRestoreRecord]
    public let focusedWindowID: UUID?
    public let assignments: [UUID: UUID]

    public init(records: [BrowserWindowRestoreRecord], focusedWindowID: UUID?, assignments: [UUID: UUID]) {
        self.records = records
        self.focusedWindowID = focusedWindowID
        self.assignments = assignments
    }

    private enum CodingKeys: String, CodingKey { case records, focusedWindowID, assignments }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decode([BrowserWindowRestoreRecord].self, forKey: .records)
        focusedWindowID = try values.decodeIfPresent(UUID.self, forKey: .focusedWindowID)
        assignments = try values.decodeWindowUUIDMap(forKey: .assignments)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(records, forKey: .records)
        try values.encodeIfPresent(focusedWindowID, forKey: .focusedWindowID)
        try values.encodeWindowUUIDMap(assignments, forKey: .assignments)
    }

    func repaired(for session: Session) -> Self? {
        guard !session.spaces.isEmpty, session.spaces.allSatisfy({ !$0.tabs.isEmpty }) else { return nil }
        var uniqueRecords: [UUID: BrowserWindowRestoreRecord] = [:]
        var selections: [BrowserWindowSelection] = []
        for record in records {
            let id = record.selection.id
            guard uniqueRecords[id] == nil else { continue }
            if selections.count == Self.maximumRestoredWindows { break }
            uniqueRecords[id] = record
            selections.append(record.selection)
        }
        guard !selections.isEmpty, let model = try? BrowserWindowWorkspace(session: session, windows: selections,
                                                                          focusedWindowID: focusedWindowID, assignments: assignments) else { return nil }
        let records = model.windows.map { selection in
            let original = uniqueRecords[selection.id]
            let frame = original?.frame.flatMap { $0.isValid ? $0 : nil }
            let groups = BrowserSplitLayout.repairedGroups(original?.splitGroups ?? [], in: model.session.spaces) {
                model.assignedWindow(for: $0) == selection.id
            }
            return BrowserWindowRestoreRecord(selection: selection, frame: frame,
                                              sidebarWidth: original?.sidebarWidth, sidebarVisible: original?.sidebarVisible,
                                              splitGroups: groups)
        }
        return Self(records: records, focusedWindowID: model.focusedWindowID, assignments: model.assignments)
    }
}

extension KeyedDecodingContainer {
    func decodeWindowUUIDMap(forKey key: Key) throws -> [UUID: UUID] {
        try decode([String: UUID].self, forKey: key).reduce(into: [:]) { result, pair in
            if let id = UUID(uuidString: pair.key), id.uuidString == pair.key { result[id] = pair.value }
        }
    }
}

extension KeyedEncodingContainer {
    mutating func encodeWindowUUIDMap(_ map: [UUID: UUID], forKey key: Key) throws {
        try encode(Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) }), forKey: key)
    }
}
