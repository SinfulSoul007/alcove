import Foundation
import CryptoKit
import Security
import zlib
import BrowserCore

private struct OwnedCRXSigner {
    var spki:Data
    var kind:UInt64
    var sign:(Data)throws -> Data
    var idBytes:Data { Data(SHA256.hash(data:spki).prefix(16)) }
    var id:String { let alphabet = Array("abcdefghijklmnop"); return idBytes.flatMap{[alphabet[Int($0)/16],alphabet[Int($0)%16]]}.map(String.init).joined() }
}
private func ownedVarint(_ input:UInt64) -> Data {
    var value = input, bytes = Data()
    repeat { var byte = UInt8(value & 127); value >>= 7; if value != 0 { byte |= 128 }; bytes.append(byte) } while value != 0
    return bytes
}
private func ownedField(_ number:UInt64,_ value:Data) -> Data { ownedVarint(number*8+2) + ownedVarint(UInt64(value.count)) + value }
private func ownedLE32(_ value:UInt32) -> Data { Data((0..<4).map{UInt8(truncatingIfNeeded:value >> ($0*8))}) }
private func ownedDER(_ tag:UInt8,_ contents:Data) -> Data {
    let length:Data
    if contents.count < 128 { length = Data([UInt8(contents.count)]) }
    else { var number = contents.count, bytes:[UInt8] = []; while number != 0 { bytes.insert(UInt8(number & 255),at:0); number >>= 8 }; length = Data([0x80 | UInt8(bytes.count)] + bytes) }
    return Data([tag]) + length + contents
}
private func ownedSignatureInput(_ signed:Data,_ archive:Data) -> Data {
    Data([0x43,0x52,0x58,0x33,0x20,0x53,0x69,0x67,0x6e,0x65,0x64,0x44,0x61,0x74,0x61,0x00]) + ownedLE32(UInt32(signed.count)) + signed + archive
}
private func ownedCRX(_ signers:[OwnedCRXSigner],archive:Data,declaredID:Data? = nil,signedExtra:Data = Data(),headerExtra:Data = Data()) throws -> Data {
    let signed = ownedField(1,declaredID ?? signers[0].idBytes) + signedExtra
    let message = ownedSignatureInput(signed,archive)
    var header = Data()
    for signer in signers { header += ownedField(signer.kind,ownedField(1,signer.spki) + ownedField(2,try signer.sign(message))) }
    header += ownedField(10_000,signed) + headerExtra
    return Data("Cr24".utf8) + ownedLE32(3) + ownedLE32(UInt32(header.count)) + header + archive
}
private func ownedRSA() throws -> (signer:OwnedCRXSigner,key:SecKey) {
    var error:Unmanaged<CFError>?
    let attributes:[CFString:Any] = [kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeySizeInBits:2048,kSecAttrIsPermanent:false]
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary,&error), let publicKey = SecKeyCopyPublicKey(key), let bytes = SecKeyCopyExternalRepresentation(publicKey,&error) as Data? else { throw error!.takeRetainedValue() }
    let algorithm = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
    let spki = ownedDER(0x30,ownedDER(0x30,algorithm) + ownedDER(0x03,Data([0]) + bytes))
    return (OwnedCRXSigner(spki:spki,kind:2,sign:{ message in
        var error:Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key,.rsaSignatureMessagePKCS1v15SHA256,message as CFData,&error) as Data? else { throw error!.takeRetainedValue() }; return signature
    }),key)
}

/// Shared generated package for network-pipeline tests; it deliberately has no
/// production publisher proof and is never loaded into an extension context.
func ownedDownloadPackageFixture() throws -> (id:String,bytes:Data,updatedBytes:Data) {
    let key = P256.Signing.PrivateKey(),signer = OwnedCRXSigner(spki:key.publicKey.derRepresentation,kind:3,sign:{try key.signature(for:$0).derRepresentation})
    func revision(_ version:String) throws -> Data {
        var manifest = OwnedZIPFile();manifest.name = "manifest.json"
        manifest.contents = try JSONSerialization.data(withJSONObject:["manifest_version":3,"name":"Owned Download Fixture","version":version])
        manifest.checksum = manifest.contents.withUnsafeBytes{UInt32(crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt($0.count)))}
        return try ownedCRX([signer],archive:ownedZIP([manifest]))
    }
    return (signer.id,try revision("1"),try revision("2"))
}

func runExtensionCRXChecks(_ check:(Bool,String)->Void) throws {
    let (rsa,rsaKey) = try ownedRSA(), ecKey = P256.Signing.PrivateKey()
    let ec = OwnedCRXSigner(spki:ecKey.publicKey.derRepresentation,kind:3,sign:{try ecKey.signature(for:$0).derRepresentation})
    let archive = ownedZIP([OwnedZIPFile()]), rsaBytes = try ownedCRX([rsa],archive:archive), ecBytes = try ownedCRX([ec],archive:archive)
    let rsaResult = try ExtensionCRX.verify(rsaBytes), ecResult = try ExtensionCRX.verify(ecBytes)
    check(rsaResult.extensionID == rsa.id && rsaResult.archive == archive && !rsaResult.publisherVerified,"CRX3 RSA identity and archive are authenticated with PKCS1 SHA256")
    check(ecResult.extensionID == ec.id && ecResult.archive == archive && !ecResult.publisherVerified,"CRX3 P-256 signatures authenticate an independent developer identity")
    let multiple = try ExtensionCRX.verify(ownedCRX([rsa,ec],archive:archive))
    check(multiple.extensionID == rsa.id,"Every proof can validate while the signed developer ID selects its own key")
    check(try ExtensionCRX.verify(ecBytes,expectedID:ec.id).extensionID == ec.id,"An expected extension ID is bound to the signed developer key")
    func rejected(_ bytes:Data,expected:String? = nil,publisher:Bool = false,limits:ExtensionPackageLimits = .default) -> Bool {
        do { _ = try ExtensionCRX.verify(bytes,expectedID:expected,requireStoreProof:publisher,limits:limits); return false } catch { return true }
    }
    check(rejected(ecBytes,expected:String(repeating:"a",count:32)),"A valid package cannot impersonate a different requested extension ID")
    check(rejected(ecBytes,publisher:true),"A developer signature cannot substitute for the production Web Store publisher proof")
    check(rejected(try ownedCRX([rsa,ec],archive:archive),publisher:true),"An unrelated second valid proof cannot impersonate the pinned publisher")
    var pss = rsa
    pss.sign = { message in
        var error:Unmanaged<CFError>?
        guard let result = SecKeyCreateSignature(rsaKey,.rsaSignatureMessagePSSSHA256,message as CFData,&error) as Data? else { throw error!.takeRetainedValue() }; return result
    }
    check(rejected(try ownedCRX([pss],archive:archive)),"CRX's stale PSS schema comment does not change the actual RSA verification algorithm")
    var badArchive = ecBytes; badArchive[badArchive.count-1] ^= 1
    check(rejected(badArchive),"Changing any signed archive byte invalidates CRX authentication")
    check(rejected(try ownedCRX([ec],archive:archive,declaredID:Data(repeating:0,count:16))),"Valid signatures still require a developer-key hash matching the signed ID")
    var wrongProof = ec
    wrongProof.sign = { message in var bytes = try ec.sign(message); bytes[bytes.count-1] ^= 1; return bytes }
    check(rejected(try ownedCRX([rsa,wrongProof],archive:archive)),"An invalid extra proof cannot hide behind a valid developer signature")
    var confused = ec; confused.kind = 2
    check(rejected(try ownedCRX([confused],archive:archive)),"The proof field's algorithm must match its public key type")
    var trailingKey = rsa; trailingKey.spki.append(0)
    check(rejected(try ownedCRX([trailingKey],archive:archive)),"SPKI parsing rejects trailing bytes even when the underlying key signs correctly")
    var unknownCurve = ec
    let curve = Data([0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])
    if let range = unknownCurve.spki.range(of:curve) { unknownCurve.spki[range.upperBound-1] = 8 } else { throw NSError(domain:"OwnedFixture",code:1) }
    check(rejected(try ownedCRX([unknownCurve],archive:archive)),"EC SPKI cannot select a different named curve")
    let signed = ownedField(1,ec.idBytes), message = ownedSignatureInput(signed,archive)
    let duplicateKey = ownedField(3,ownedField(1,ec.spki) + ownedField(1,ec.spki) + ownedField(2,try ec.sign(message)))
    let duplicateProofHeader = duplicateKey + ownedField(10_000,signed)
    let duplicateProof = Data("Cr24".utf8) + ownedLE32(3) + ownedLE32(UInt32(duplicateProofHeader.count)) + duplicateProofHeader + archive
    check(rejected(duplicateProof),"Duplicate public-key fields cannot create an ambiguous proof")
    check(rejected(try ownedCRX([ec],archive:archive,headerExtra:ownedField(10_000,signed))),"Duplicate signed-header fields are rejected")
    check(rejected(try ownedCRX([ec],archive:archive,signedExtra:ownedField(1,ec.idBytes))),"Duplicate signed IDs are rejected even when the bytes were signed")
    check(rejected(try ownedCRX([ec],archive:archive,headerExtra:ownedField(4,Data([0x50,0x4b,0x05,0x06])))),"Archive end-record tokens cannot hide in a CRX header")
    let proof = ownedField(3,ownedField(1,ec.spki) + ownedField(2,try ec.sign(message)))
    let many = (0..<65).reduce(into:Data()) { value,_ in value += proof } + ownedField(10_000,signed)
    check(rejected(Data("Cr24".utf8) + ownedLE32(3) + ownedLE32(UInt32(many.count)) + many + archive),"Signature-proof counts are bounded before cryptographic work")
    var old = ecBytes; old[4] = 2
    check(rejected(old),"CRX2 packages receive an unsupported-format result")
    check(rejected(Data("Cr24".utf8) + ownedLE32(3) + ownedLE32(16*1024*1024 + 1)),"Oversized CRX headers are rejected before allocation")
    check(rejected(Data("Cr24".utf8) + ownedLE32(3) + ownedLE32(2) + Data([0x82,0xf1])),"Truncated protobuf varints are rejected")
    check(rejected(ecBytes,limits:ExtensionPackageLimits(inputBytes:ecBytes.count-1)),"The full CRX input cap precedes header processing")
    let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer { try? manager.removeItem(at:root) }
    var manifest = OwnedZIPFile(); manifest.name = "manifest.json"; manifest.contents = Data(#"{"manifest_version":3,"name":"Owned Signed Package","version":"1"}"#.utf8)
    manifest.checksum = manifest.contents.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt($0.count))) }
    let signedPackage = root.appendingPathComponent("owned.crx"), staging = root.appendingPathComponent("stage")
    try ownedCRX([ec],archive:ownedZIP([manifest])).write(to:signedPackage)
    var prepared:PreparedExtensionPackage?
    do { prepared = try ExtensionPackage.prepare(at:signedPackage,stagingRoot:staging,expectedStoreID:ec.id) } catch { }
    check(prepared?.source == .crx3 && prepared?.signerID == ec.id && prepared?.storeID == nil && prepared?.publisherVerified == false && prepared?.manifest.name == "Owned Signed Package","Signed-package inspection preserves its authenticated local source identity")
    try prepared?.discard()
    var badZIP = ownedZIP([manifest]); badZIP[30 + 13] ^= 1
    try ownedCRX([ec],archive:badZIP).write(to:signedPackage)
    var rejectedBadZIP = false
    do { let value = try ExtensionPackage.prepare(at:signedPackage,stagingRoot:staging); try value.discard() } catch { rejectedBadZIP = true }
    check(rejectedBadZIP,"A valid CRX signature never bypasses ZIP resource validation")
    let webStage = root.appendingPathComponent("unverified-store-stage"),developerPackage = try ownedCRX([ec],archive:ownedZIP([manifest]))
    func rejectsWebPackage(_ bytes:Data,id:String,limits:ExtensionPackageLimits = .default) -> Bool {
        do {let package = try ExtensionPackage.prepareWebStoreArchive(bytes,expectedID:id,stagingRoot:webStage,limits:limits);try package.discard();return false} catch {return true}
    }
    check(rejectsWebPackage(developerPackage,id:ec.id),"A downloaded developer-signed package cannot bypass the required production publisher proof")
    check(rejectsWebPackage(developerPackage,id:String(repeating:"a",count:32)),"A downloaded package cannot bypass the expected Web Store identity")
    check(rejectsWebPackage(developerPackage,id:ec.id,limits:ExtensionPackageLimits(inputBytes:developerPackage.count-1)),"Downloaded package bytes are capped before signature and extraction work")
    check(!manager.fileExists(atPath:webStage.path),"An unverified store response cannot create staged package files")
}
