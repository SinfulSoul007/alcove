import Foundation
import CryptoKit
import Security

public struct VerifiedExtensionArchive:Sendable {
    public let archive:Data
    public let extensionID:String
    public let publisherVerified:Bool
}

/// CRX authentication is separate from ZIP validation and from permission/compatibility approval.
public enum ExtensionCRX {
    private static let publisherKeyHash = Data([
        0x61,0xf7,0xf2,0xa6,0xbf,0xcf,0x74,0xcd,0x0b,0xc1,0xfe,0x24,0x97,0xcc,0x9b,0x04,
        0x25,0x4c,0x65,0x8f,0x79,0xf2,0x14,0x53,0x92,0x86,0x7e,0xa8,0x36,0x63,0x67,0xcf])
    public static func verify(_ data:Data,expectedID:String? = nil,requireStoreProof:Bool = false,limits:ExtensionPackageLimits = .default) throws -> VerifiedExtensionArchive {
        try Task.checkCancellation()
        guard data.count <= limits.inputBytes else { throw ExtensionValidationError.packageTooLarge }
        if let expectedID, !BrowserExtensionRecord.validExternalID(expectedID) { throw invalid("invalid expected extension identity") }
        let bytes = ExtensionBytes(data:data)
        guard data.count >= 12, try bytes.slice(0,4) == Data("Cr24".utf8) else { throw invalid("missing CRX header") }
        guard try bytes.u32(4) == 3 else { throw invalid("only CRX3 packages are supported") }
        let headerSize = Int(try bytes.u32(8))
        guard headerSize <= 16*1024*1024 else { throw ExtensionValidationError.packageTooLarge }
        guard headerSize > 0, headerSize <= data.count - 12 else { throw invalid("truncated CRX header") }
        let header = try bytes.slice(12,headerSize), archive = try bytes.slice(12 + headerSize,data.count - 12 - headerSize)
        for token:Data in [Data([0x50,0x4b,0x05,0x06]),Data([0x50,0x4b,0x06,0x07]),Data([0x50,0x4b,0x06,0x06])] {
            guard header.range(of:token) == nil else { throw invalid("archive end-record token in CRX header") }
        }
        let fields = try Proto.fields(header), signed = try Proto.required(10_000,in:fields)
        let verifiedContents = fields.filter{$0.number == 4}
        guard verifiedContents.count <= 1, verifiedContents.allSatisfy({$0.wire == 2}) else { throw invalid("ambiguous verified contents") }
        let proofs = fields.filter{$0.number == 2 || $0.number == 3}
        guard !proofs.isEmpty, proofs.count <= 64, proofs.allSatisfy({$0.wire == 2}) else { throw invalid("missing, excessive or malformed signature proofs") }
        let declared = try Proto.required(1,in:Proto.fields(signed))
        guard declared.count == 16 else { throw invalid("invalid signed developer identity") }
        let identifier = declared.map { byte in String(UnicodeScalar(97 + UInt32(byte >> 4))!) + String(UnicodeScalar(97 + UInt32(byte & 15))!) }.joined()
        if let expectedID, expectedID != identifier { throw invalid("the package does not match the requested extension") }
        var hash = SHA256(); hash.update(data:Data("CRX3 SignedData\0".utf8))
        var size = UInt32(signed.count).littleEndian; withUnsafeBytes(of:&size) {hash.update(data:Data($0))}
        hash.update(data:signed); hash.update(data:archive); let digest = Data(hash.finalize())
        var developerFound = false, publisherFound = false, seenKeys = Set<Data>()
        for proof in proofs {
            try Task.checkCancellation()
            let fields = try Proto.fields(proof.value), spki = try Proto.required(1,in:fields), signature = try Proto.required(2,in:fields)
            guard spki.count <= 16_384, signature.count <= 4096 else { throw invalid("oversized key or signature") }
            let keyHash = Data(SHA256.hash(data:spki))
            guard seenKeys.insert(keyHash).inserted else { throw invalid("duplicate signature key") }
            let (key,algorithm) = try publicKey(spki,kind:proof.number)
            guard SecKeyIsAlgorithmSupported(key,.verify,algorithm) else { throw invalid("unsupported signature algorithm") }
            if proof.number == 3 { try validateECDSASignature(signature) }
            var error:Unmanaged<CFError>?
            guard SecKeyVerifySignature(key,algorithm,digest as CFData,signature as CFData,&error) else {
                _ = error?.takeRetainedValue(); throw invalid("signature verification failed")
            }
            developerFound = developerFound || keyHash.prefix(16) == declared
            publisherFound = publisherFound || keyHash == publisherKeyHash
        }
        guard developerFound else { throw invalid("a proof from the signed developer key is required") }
        guard !requireStoreProof || publisherFound else { throw invalid("the production Web Store publisher proof is missing") }
        return VerifiedExtensionArchive(archive:archive,extensionID:identifier,publisherVerified:publisherFound)
    }
    private static func invalid(_ text:String) -> ExtensionValidationError { .invalidArchive(text) }
    private static func publicKey(_ spki:Data,kind:Int) throws -> (SecKey,SecKeyAlgorithm) {
        var outer = DER(data:spki); let sequence = try outer.element(0x30); guard outer.finished else { throw invalid("trailing SPKI data") }
        var body = DER(data:sequence); let algorithm = try body.element(0x30), bitString = try body.element(0x03)
        guard body.finished, bitString.first == 0 else { throw invalid("invalid SPKI bit string") }
        let encodedKey = Data(bitString.dropFirst())
        let keyData:Data, attributes:[CFString:Any], signatureAlgorithm:SecKeyAlgorithm
        if kind == 2 {
            let rsaOID = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
            guard algorithm == rsaOID else { throw invalid("RSA proof must use an RSA SPKI") }
            var keyOuter = DER(data:encodedKey); let integers = try keyOuter.element(0x30); guard keyOuter.finished else { throw invalid("invalid RSA key") }
            var keyBody = DER(data:integers); let modulus = try keyBody.positiveInteger(), exponent = try keyBody.positiveInteger()
            guard keyBody.finished, !modulus.isEmpty, exponent.count <= 4 else { throw invalid("invalid RSA key integers") }
            let bits = modulus.count*8 - modulus.first!.leadingZeroBitCount
            let exponentValue = exponent.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard (2048...8192).contains(bits), exponentValue >= 3, exponentValue & 1 == 1 else { throw invalid("unsupported RSA key size or exponent") }
            keyData = encodedKey; attributes = [kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:kSecAttrKeyClassPublic,kSecAttrKeySizeInBits:bits]
            signatureAlgorithm = .rsaSignatureDigestPKCS1v15SHA256
        } else {
            let p256OID = Data([0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])
            guard kind == 3, algorithm == p256OID, encodedKey.count == 65, encodedKey.first == 4 else { throw invalid("ECDSA proof must use a named P-256 key") }
            keyData = encodedKey; attributes = [kSecAttrKeyType:kSecAttrKeyTypeECSECPrimeRandom,kSecAttrKeyClass:kSecAttrKeyClassPublic,kSecAttrKeySizeInBits:256]
            signatureAlgorithm = .ecdsaSignatureDigestX962SHA256
        }
        var error:Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData,attributes as CFDictionary,&error) else {
            _ = error?.takeRetainedValue(); throw invalid("invalid public key")
        }
        return (key,signatureAlgorithm)
    }
    private static func validateECDSASignature(_ data:Data) throws {
        var outer = DER(data:data); let body = try outer.element(0x30); guard outer.finished else { throw invalid("trailing ECDSA signature data") }
        var integers = DER(data:body); let first = try integers.positiveInteger(), second = try integers.positiveInteger()
        guard integers.finished, first.count <= 32, second.count <= 32 else { throw invalid("invalid ECDSA signature") }
    }
    private struct DER {
        let data:Data; var index = 0
        var finished:Bool { index == data.count }
        mutating func element(_ tag:UInt8) throws -> Data {
            guard index < data.count, data[data.startIndex+index] == tag else { throw invalid("invalid DER tag") }; index += 1
            guard index < data.count else { throw invalid("truncated DER length") }
            let initial = data[data.startIndex+index]; index += 1
            let length:Int
            if initial < 128 { length = Int(initial) }
            else {
                let count = Int(initial & 127)
                guard (1...4).contains(count), count <= data.count-index, data[data.startIndex+index] != 0 else { throw invalid("invalid DER length") }
                var value = 0
                for _ in 0..<count { value = (value << 8) | Int(data[data.startIndex+index]); index += 1 }
                guard value >= 128 else { throw invalid("nonminimal DER length") }; length = value
            }
            guard length <= data.count-index else { throw invalid("truncated DER value") }
            defer {index += length}; return Data(data[(data.startIndex+index)..<(data.startIndex+index+length)])
        }
        mutating func positiveInteger() throws -> Data {
            let bytes = try element(0x02)
            guard let first = bytes.first, first & 128 == 0 else { throw invalid("negative or empty DER integer") }
            if first == 0 {
                guard bytes.count > 1, bytes[bytes.startIndex+1] & 128 != 0 else { throw invalid("zero or nonminimal DER integer") }
                return Data(bytes.dropFirst())
            }
            return bytes
        }
    }
    private enum Proto {
        struct Field { let number:Int; let wire:UInt64; let value:Data }
        static func required(_ number:Int,in fields:[Field]) throws -> Data {
            let matches = fields.filter{$0.number == number}
            guard matches.count == 1, matches[0].wire == 2, !matches[0].value.isEmpty else { throw invalid("missing or duplicate protobuf field") }
            return matches[0].value
        }
        static func fields(_ data:Data) throws -> [Field] {
            var reader = Reader(data:data), result:[Field] = []
            while reader.index < data.count {
                guard result.count < 10_000 else { throw invalid("excessive protobuf fields") }
                let tag = try reader.varint(), number = tag >> 3, wire = tag & 7
                guard number > 0, number <= 0x1fff_ffff else { throw invalid("invalid protobuf tag") }
                let value:Data
                switch wire {
                case 0: _ = try reader.varint(); value = Data()
                case 1: value = try reader.bytes(8)
                case 2:
                    let length = try reader.varint(); guard length <= UInt64(data.count-reader.index) else { throw invalid("truncated protobuf field") }
                    value = try reader.bytes(Int(length))
                case 5: value = try reader.bytes(4)
                default: throw invalid("unsupported protobuf wire type")
                }
                result.append(Field(number:Int(number),wire:wire,value:value))
            }
            return result
        }
        private struct Reader {
            let data:Data; var index = 0
            mutating func varint() throws -> UInt64 {
                var value:UInt64 = 0
                for position in 0..<10 {
                    guard index < data.count else { throw invalid("truncated protobuf varint") }
                    let byte = data[data.startIndex+index]; index += 1
                    guard position < 9 || byte <= 1 else { throw invalid("overflowing protobuf varint") }
                    value |= UInt64(byte & 127) << (position*7)
                    if byte & 128 == 0 {
                        guard position == 0 || byte != 0 else { throw invalid("nonminimal protobuf varint") }; return value
                    }
                }
                throw invalid("overflowing protobuf varint")
            }
            mutating func bytes(_ count:Int) throws -> Data {
                guard count >= 0, count <= data.count-index else { throw invalid("truncated protobuf value") }
                defer {index += count}; return Data(data[(data.startIndex+index)..<(data.startIndex+index+count)])
            }
        }
    }
}
