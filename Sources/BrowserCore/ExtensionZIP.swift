import Foundation
import CoreFoundation
import zlib

public struct ExtensionPackageLimits:Sendable {
    public let inputBytes:Int
    public let expandedBytes:Int
    public let fileBytes:Int
    public let entries:Int
    public static let `default` = Self()
    public init(inputBytes:Int = 128*1024*1024,expandedBytes:Int = 256*1024*1024,fileBytes:Int = 64*1024*1024,entries:Int = 10_000) {
        self.inputBytes = max(0,min(inputBytes,128*1024*1024)); self.expandedBytes = max(0,min(expandedBytes,256*1024*1024))
        self.fileBytes = max(0,min(fileBytes,64*1024*1024)); self.entries = max(0,min(entries,10_000))
    }
}
public struct ExtensionZIPEntry:Equatable,Sendable {
    public let path:String
    public let isDirectory:Bool
    public let data:Data
}

/// Validates every record and range before decoding resource data. It never writes imported names to disk.
public enum ExtensionZIP {
    public static func read(_ data:Data,limits:ExtensionPackageLimits = .default) throws -> [ExtensionZIPEntry] {
        guard data.count <= limits.inputBytes else { throw ExtensionValidationError.packageTooLarge }
        let bytes = ExtensionBytes(data:data)
        guard data.count >= 22 else { throw invalid("missing end record") }
        var end:Int?
        for offset in stride(from:data.count - 22,through:max(0,data.count - 22 - 65_535),by:-1) {
            if try bytes.u32(offset) == 0x06054b50, offset + 22 + Int(try bytes.u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end else { throw invalid("missing end record") }
        let count = Int(try bytes.u16(end + 10)), directorySize = Int(try bytes.u32(end + 12)), directoryOffset = Int(try bytes.u32(end + 16))
        guard try bytes.u16(end + 4) == 0, try bytes.u16(end + 6) == 0, try bytes.u16(end + 8) == count,
              count != 65_535, directorySize != Int(UInt32.max), directoryOffset != Int(UInt32.max),
              directoryOffset + directorySize == end else { throw invalid("multipart, ZIP64 or inconsistent central directory") }
        guard count <= limits.entries else { throw ExtensionValidationError.packageTooLarge }
        var records:[Record] = [], paths:[String:Bool] = [:], requiredDirectories = Set<String>(), filesystemEntries = Set<String>(), offset = directoryOffset, expanded = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try bytes.u32(offset) == 0x02014b50 else { throw invalid("invalid central header") }
            let flags = try bytes.u16(offset + 8), method = try bytes.u16(offset + 10), checksum = try bytes.u32(offset + 16)
            let compressed = Int(try bytes.u32(offset + 20)), size = Int(try bytes.u32(offset + 24))
            let nameLength = Int(try bytes.u16(offset + 28)), extraLength = Int(try bytes.u16(offset + 30)), commentLength = Int(try bytes.u16(offset + 32))
            let attributes = try bytes.u32(offset + 38), localOffset = Int(try bytes.u32(offset + 42))
            if flags & 1 != 0 { throw invalid("encrypted ZIP archives are unsupported") }
            guard try bytes.u16(offset + 6) <= 20, try bytes.u16(offset + 34) == 0,
                  flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  method != 0 || flags & 6 == 0, nameLength > 0, nameLength <= 4096,
                  offset + 46 + nameLength + extraLength + commentLength <= end,
                  localOffset < directoryOffset, compressed <= limits.inputBytes else { throw invalid("unsupported or inconsistent central entry") }
            guard size <= limits.fileBytes, expanded <= limits.expandedBytes - size else { throw ExtensionValidationError.packageTooLarge }
            expanded += size
            let rawName = try bytes.slice(offset + 46,nameLength)
            let extra = try extraFields(bytes.slice(offset + 46 + nameLength,extraLength),rawName:rawName)
            let encoding = flags & 0x800 != 0 ? String.Encoding.utf8 : String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
            guard let baseName = String(data:rawName,encoding:encoding), !baseName.contains("\0") else { throw invalid("invalid filename encoding") }
            let name = extra.unicodeName ?? baseName
            if flags & 0x800 != 0, let alternate = extra.unicodeName, alternate != baseName { throw invalid("conflicting Unicode filename") }
            let directory = name.hasSuffix("/")
            let path = try ExtensionResourcePath.normalized(directory ? String(name.dropLast()) : name)
            let key = collisionKey(path), kind = (attributes >> 16) & 0xf000
            if path == "manifest.json" && size > 1_048_576 { throw ExtensionValidationError.packageTooLarge }
            guard kind == 0 || kind == (directory ? 0x4000 : 0x8000), attributes & 0x10 == 0 || directory,
                  !directory || (size == 0 && checksum == 0), paths[key] == nil else { throw invalid("links, special files or duplicate paths") }
            if filesystemEntries.insert(key).inserted && filesystemEntries.count > limits.entries { throw ExtensionValidationError.packageTooLarge }
            var parent = key[...]
            while let slash = parent.lastIndex(of:"/") {
                parent = parent[..<slash]; let key = String(parent)
                if paths[key] == false { throw invalid("file/directory path collision") }
                requiredDirectories.insert(key)
                if filesystemEntries.insert(key).inserted && filesystemEntries.count > limits.entries { throw ExtensionValidationError.packageTooLarge }
            }
            if !directory && requiredDirectories.contains(key) { throw invalid("file/directory path collision") }
            paths[key] = directory
            guard try bytes.u32(localOffset) == 0x04034b50, try bytes.u16(localOffset + 4) <= 20,
                  try bytes.u16(localOffset + 6) == flags, try bytes.u16(localOffset + 8) == method else { throw invalid("local header disagrees with central entry") }
            let localNameLength = Int(try bytes.u16(localOffset + 26)), localExtraLength = Int(try bytes.u16(localOffset + 28))
            guard localNameLength == nameLength, try bytes.slice(localOffset + 30,localNameLength) == rawName else { throw invalid("local filename disagrees with central entry") }
            let localExtra = try extraFields(bytes.slice(localOffset + 30 + localNameLength,localExtraLength),rawName:rawName)
            if let alternate = localExtra.unicodeName, alternate != name { throw invalid("conflicting local Unicode filename") }
            let start = localOffset + 30 + localNameLength + localExtraLength, payloadEnd = start + compressed
            guard payloadEnd <= directoryOffset else { throw invalid("entry extends into central directory") }
            let localCRC = try bytes.u32(localOffset + 14), localCompressed = try bytes.u32(localOffset + 18), localSize = try bytes.u32(localOffset + 22)
            var recordEnd = payloadEnd
            if flags & 8 != 0 {
                guard (localCRC == 0 || localCRC == checksum), (localCompressed == 0 || localCompressed == compressed), (localSize == 0 || localSize == size) else { throw invalid("inconsistent streamed local sizes") }
                func descriptorMatches(_ position:Int) throws -> Bool {
                    guard position + 12 <= directoryOffset else { return false }
                    let crc = try bytes.u32(position), compressedSize = try bytes.u32(position + 4), expandedSize = try bytes.u32(position + 8)
                    return crc == checksum && compressedSize == compressed && expandedSize == size
                }
                var descriptor = payloadEnd
                if try !descriptorMatches(descriptor) {
                    guard try bytes.u32(descriptor) == 0x08074b50 else { throw invalid("inconsistent data descriptor") }
                    descriptor += 4
                    guard try descriptorMatches(descriptor) else { throw invalid("inconsistent data descriptor") }
                }
                recordEnd = descriptor + 12
            } else {
                guard localCRC == checksum, localCompressed == compressed, localSize == size else { throw invalid("local sizes or CRC disagree") }
            }
            if method == 0 && compressed != size { throw invalid("stored entry sizes disagree") }
            records.append(Record(path:path,directory:directory,method:method,checksum:checksum,size:size,payload:start..<payloadEnd,whole:localOffset..<recordEnd))
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard offset == end else { throw invalid("central directory size or entry count mismatch") }
        var expected = 0
        for record in records.sorted(by:{$0.whole.lowerBound < $1.whole.lowerBound}) {
            guard record.whole.lowerBound == expected else { throw invalid("overlapping or unreferenced local entries") }
            expected = record.whole.upperBound
        }
        guard expected == directoryOffset else { throw invalid("unreferenced bytes before central directory") }
        return try records.map { record in
            try Task.checkCancellation()
            let compressed = try bytes.slice(record.payload.lowerBound,record.payload.count)
            let contents = record.method == 0 ? compressed : try inflate(compressed,expectedSize:record.size)
            guard contents.count == record.size, crc(contents) == record.checksum else { throw invalid("resource CRC or expanded size mismatch") }
            return ExtensionZIPEntry(path:record.path,isDirectory:record.directory,data:contents)
        }
    }
    public static func collisionKey(_ path:String) -> String { path.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")).precomposedStringWithCanonicalMapping }
    private static func invalid(_ detail:String) -> ExtensionValidationError { .invalidArchive(detail) }
    private struct Record {
        var path:String; var directory:Bool; var method:UInt16; var checksum:UInt32; var size:Int; var payload:Range<Int>; var whole:Range<Int>
    }
    private static func crc(_ data:Data) -> UInt32 {
        data.withUnsafeBytes { buffer in UInt32(crc32(0,buffer.bindMemory(to:UInt8.self).baseAddress,uInt(buffer.count))) }
    }
    private static func extraFields(_ data:Data,rawName:Data) throws -> (unicodeName:String?,ids:Set<UInt16>) {
        let bytes = ExtensionBytes(data:data); var offset = 0, seen = Set<UInt16>(), name:String?
        while offset < data.count {
            let id = try bytes.u16(offset), size = Int(try bytes.u16(offset + 2)); offset += 4
            let value = try bytes.slice(offset,size); offset += size
            guard seen.insert(id).inserted, id != 0x0001, id != 0x9901 else { throw invalid("ambiguous, ZIP64 or encrypted extra fields") }
            if id == 0x7075 {
                let field = ExtensionBytes(data:value)
                guard value.count > 5, value.first == 1, try field.u32(1) == crc(rawName), let decoded = String(data:try field.slice(5,value.count - 5),encoding:.utf8) else { throw invalid("invalid Unicode path extra field") }
                name = decoded
            }
        }
        return (name,seen)
    }
    private static func inflate(_ data:Data,expectedSize:Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid("cannot initialize deflate reader") }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:UInt8.self).baseAddress); stream.avail_in = uInt(input.count)
            var result = Data(), buffer = [UInt8](repeating:0,count:32_768)
            while true {
                try Task.checkCancellation()
                let previousIn = stream.total_in, previousOut = stream.total_out
                let status = buffer.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress; stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream,Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard produced <= expectedSize - result.count else { throw invalid("deflate output exceeds declared size") }
                result.append(contentsOf:buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, result.count == expectedSize else { throw invalid("trailing or incomplete deflate data") }
                    return result
                }
                guard status == Z_OK, stream.total_in != previousIn || stream.total_out != previousOut else { throw invalid("invalid or truncated deflate stream") }
            }
        }
    }
}

struct ExtensionBytes {
    let data:Data
    func slice(_ offset:Int,_ count:Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { throw ExtensionValidationError.invalidArchive("truncated record") }
        return Data(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
    }
    func u16(_ offset:Int) throws -> UInt16 { UInt16(try integer(offset,2)) }
    func u32(_ offset:Int) throws -> UInt32 { UInt32(try integer(offset,4)) }
    private func integer(_ offset:Int,_ count:Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count, count <= data.count - offset else { throw ExtensionValidationError.invalidArchive("truncated record") }
        var result:UInt64 = 0
        for index in 0..<count { result |= UInt64(data[data.startIndex + offset + index]) << (index*8) }
        return result
    }
}
