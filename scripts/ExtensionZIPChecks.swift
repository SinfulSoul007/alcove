import Foundation
import BrowserCore
import zlib

// Hand-written records and independent zlib fixture bytes keep archive expectations separate from the reader.
struct OwnedZIPFile {
    var name:String = "hello.txt"
    var rawName:Data? = nil
    var contents = Data("hello".utf8)
    var compressed:Data? = nil
    var method:UInt16 = 0
    var flags:UInt16 = 0x800
    var checksum:UInt32 = 0x3610a686
    var mode:UInt32 = 0o100644 << 16
    var descriptor = false
    var descriptorSignature = true
}
func ownedZIP(_ files:[OwnedZIPFile]) -> Data {
    var result = Data(), central = Data()
    func le(_ value:UInt32,_ bytes:Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
    func u16(_ value:UInt16) -> Data { le(UInt32(value),2) }
    for file in files {
        let name = file.rawName ?? Data(file.name.utf8), payload = file.compressed ?? file.contents, flags = file.flags | (file.descriptor ? 8 : 0)
        let offset = UInt32(result.count)
        result += le(0x04034b50,4) + u16(20) + u16(flags) + u16(file.method) + le(0,4)
        result += le(file.descriptor ? 0 : file.checksum,4) + le(file.descriptor ? 0 : UInt32(payload.count),4) + le(file.descriptor ? 0 : UInt32(file.contents.count),4)
        result += u16(UInt16(name.count)) + u16(0) + name + payload
        if file.descriptor { if file.descriptorSignature {result += le(0x08074b50,4)}; result += le(file.checksum,4) + le(UInt32(payload.count),4) + le(UInt32(file.contents.count),4) }
        central += le(0x02014b50,4) + u16(0x0314) + u16(20) + u16(flags) + u16(file.method) + le(0,4)
        central += le(file.checksum,4) + le(UInt32(payload.count),4) + le(UInt32(file.contents.count),4)
        central += u16(UInt16(name.count)) + le(0,4) + u16(0) + u16(0) + le(file.mode,4) + le(offset,4) + name
    }
    let offset = UInt32(result.count); result += central
    result += le(0x06054b50,4) + le(0,4) + u16(UInt16(files.count)) + u16(UInt16(files.count)) + le(UInt32(central.count),4) + le(offset,4) + u16(0)
    return result
}

func runExtensionZIPChecks(_ check:(Bool,String)->Void) throws {
    let stored = ownedZIP([OwnedZIPFile()])
    let files = try ExtensionZIP.read(stored)
    check(files.count == 1 && files.first?.path == "hello.txt" && files.first?.data == Data("hello".utf8),"Stored ZIP bytes survive CRC-checked extraction")
    var deflated = OwnedZIPFile(); deflated.method = 8; deflated.compressed = Data([0xcb,0x48,0xcd,0xc9,0xc9,0x07,0x00]); deflated.descriptor = true
    check(try ExtensionZIP.read(ownedZIP([deflated])).first?.data == Data("hello".utf8),"Raw-deflated ZIPs with signed data descriptors are decoded")
    var unsignedDescriptor = deflated; unsignedDescriptor.descriptorSignature = false
    check(try ExtensionZIP.read(ownedZIP([unsignedDescriptor])).first?.data == Data("hello".utf8),"Unsigned data descriptors are accepted alongside signed descriptors")
    var signatureCRC = OwnedZIPFile(); signatureCRC.contents = Data([0xac,0x0a,0x7a,0xd5]); signatureCRC.checksum = 0x08074b50; signatureCRC.descriptor = true; signatureCRC.descriptorSignature = false
    var signatureCRCValid = false
    do {signatureCRCValid = try ExtensionZIP.read(ownedZIP([signatureCRC])).first?.data == signatureCRC.contents} catch {}
    check(signatureCRCValid,"A descriptor CRC equal to the optional signature token remains unambiguous")
    var unicode = OwnedZIPFile(); unicode.name = "café.txt"
    check(try ExtensionZIP.read(ownedZIP([unicode])).first?.path == "café.txt","UTF-8 ZIP names retain their normalized Unicode identity")
    var legacy = OwnedZIPFile(); legacy.flags = 0; legacy.rawName = Data([0x63,0x61,0x66,0x82,0x2e,0x74,0x78,0x74])
    check(try ExtensionZIP.read(ownedZIP([legacy])).first?.path == "café.txt","Unflagged legacy ZIP names use CP437 instead of lossy UTF-8")
    var empty = OwnedZIPFile(); empty.contents = Data(); empty.checksum = 0; empty.compressed = Data([3,0]); empty.method = 8
    check(try ExtensionZIP.read(ownedZIP([empty])).first?.data.isEmpty == true,"An empty deflated resource is valid")
    var directory = empty; directory.name = "assets/"; directory.mode = 0o040755 << 16; directory.method = 0; directory.compressed = nil
    var nested = OwnedZIPFile(); nested.name = "assets/hello.txt"
    check(try ExtensionZIP.read(ownedZIP([directory,nested])).filter({!$0.isDirectory}).first?.path == "assets/hello.txt","Directory records and nested files retain their intended structure")
    func rejected(_ input:Data,limits:ExtensionPackageLimits = .default) -> Bool { do { _ = try ExtensionZIP.read(input,limits:limits); return false } catch { return true } }
    for name in ["../escape","/tmp/escape","C:/escape","a\\escape","a/../escape","a//escape","a/./escape"] {
        var unsafe = OwnedZIPFile(); unsafe.name = name
        check(rejected(ownedZIP([unsafe])),"ZIP paths cannot escape or ambiguously alias their root: " + name)
    }
    var lower = OwnedZIPFile(), upper = OwnedZIPFile(); lower.name = "hello.txt"; upper.name = "HELLO.txt"
    check(rejected(ownedZIP([lower,upper])),"Case-equivalent ZIP names cannot overwrite one another on Mac filesystems")
    var composed = OwnedZIPFile(), decomposed = OwnedZIPFile(); composed.name = "café.txt"; decomposed.name = "cafe\u{301}.txt"
    check(rejected(ownedZIP([composed,decomposed])),"Canonically equivalent Unicode ZIP names are rejected")
    var parent = OwnedZIPFile(); parent.name = "assets"
    check(rejected(ownedZIP([parent,nested])) && rejected(ownedZIP([nested,parent])),"A file cannot also be a parent directory, regardless of record order")
    var symlink = OwnedZIPFile(); symlink.mode = 0o120777 << 16
    check(rejected(ownedZIP([symlink])),"ZIP symlinks are rejected before filesystem writes")
    var special = OwnedZIPFile(); special.mode = 0o020666 << 16
    check(rejected(ownedZIP([special])),"ZIP device and special files are rejected")
    var encrypted = OwnedZIPFile(); encrypted.flags |= 1
    check(rejected(ownedZIP([encrypted])),"Encrypted ZIPs are explicitly unsupported")
    var unsupported = OwnedZIPFile(); unsupported.method = 12
    check(rejected(ownedZIP([unsupported])),"Unsupported ZIP compression cannot be interpreted as stored data")
    var crc = stored; crc[30 + "hello.txt".utf8.count] ^= 1
    check(rejected(crc),"Changed resource bytes fail their declared CRC")
    var localName = stored; localName[30] = 0x6a
    check(rejected(localName),"Central and local filenames must agree")
    var localSize = stored; localSize[22] = 4
    check(rejected(localSize),"Central and local expanded sizes must agree")
    var descriptor = ownedZIP([deflated]); descriptor[30 + "hello.txt".utf8.count + 7 + 4] ^= 1
    check(rejected(descriptor),"A mismatched data-descriptor CRC is rejected")
    var truncated = deflated; truncated.compressed = Data([0xcb,0x48])
    check(rejected(ownedZIP([truncated])),"Truncated deflate streams fail without unbounded retries")
    var trailing = deflated; trailing.compressed?.append(0)
    check(rejected(ownedZIP([trailing])),"Trailing bytes cannot hide inside a declared deflate resource")
    var expanding = deflated; expanding.contents = Data("h".utf8)
    check(rejected(ownedZIP([expanding])),"Actual inflated output cannot exceed the declared expanded size")
    var overlap = ownedZIP([lower,upper]); let secondCentral = 30 + 9 + 5 + 30 + 9 + 5 + 46 + 9
    for index in 0..<4 { overlap[secondCentral + 42 + index] = 0 }
    check(rejected(overlap),"Local ZIP entry ranges cannot overlap")
    var multipart = stored; multipart[multipart.count - 22 + 4] = 1
    check(rejected(multipart),"Multipart ZIP archives are rejected")
    var huge = stored; let central = 30 + 9 + 5
    for index in 0..<4 { huge[central + 24 + index] = 0xff }
    check(rejected(huge),"Impossible expanded-size declarations are rejected before allocation")
    var oversizedManifest = OwnedZIPFile(); oversizedManifest.name = "manifest.json"; oversizedManifest.contents = Data(repeating:32,count:1_048_577)
    // Independent fixture CRC is computed by system zlib; the reader must reject this before resource decoding.
    oversizedManifest.checksum = oversizedManifest.contents.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt($0.count))) }
    check(rejected(ownedZIP([oversizedManifest])),"Manifest expansion is limited separately from ordinary resource files")
    check(rejected(stored,limits:ExtensionPackageLimits(inputBytes:stored.count - 1)),"The complete input cap is checked before archive parsing")
    check(rejected(stored,limits:ExtensionPackageLimits(fileBytes:4)),"Per-file expanded limits are enforced")
    check(rejected(ownedZIP([lower,nested]),limits:ExtensionPackageLimits(expandedBytes:9)),"The sum of expanded resources is bounded")
    check(rejected(ownedZIP([lower,nested]),limits:ExtensionPackageLimits(entries:1)),"ZIP entry counts are bounded before resource allocation")
    check(rejected(ownedZIP([nested]),limits:ExtensionPackageLimits(entries:1)),"Implicit parent directories count toward the expanded filesystem entry limit")
}
