import Foundation

/// Installation priority is optional recovery metadata. Malformed approval and
/// identity fields keep their strict decoding; only this date may fall back.
@propertyWrapper public struct RecoverableExtensionDate:Codable,Equatable,Sendable {
    public var wrappedValue:Date?
    public init(wrappedValue:Date? = nil) {self.wrappedValue = wrappedValue}
    public init(from decoder:Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode(Date.self)
    }
    public func encode(to encoder:Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type:RecoverableExtensionDate.Type,forKey key:Key) throws -> RecoverableExtensionDate {
        try decodeIfPresent(type,forKey:key) ?? RecoverableExtensionDate()
    }
}
