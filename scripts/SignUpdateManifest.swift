import CryptoKit
import Foundation

@main
struct SignUpdateManifest {
    enum InputError: LocalizedError {
        case arguments, signingKey

        var errorDescription: String? {
            switch self {
            case .arguments: "Usage: sign-update-manifest.sh TAG COMMIT RAW_PRIVATE_KEY NEW_OUTPUT_DIRECTORY INSTALLER [INSTALLER]"
            case .signingKey: "The signing key must contain exactly 32 raw Ed25519 private key bytes."
            }
        }
    }

    static func main() {
        do { try run() }
        catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard (6...7).contains(arguments.count) else { throw InputError.arguments }
        let tag = arguments[1]
        let commit = arguments[2]
        let keyURL = URL(fileURLWithPath: arguments[3])
        guard try keyURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InputError.signingKey
        }
        let keyFile = try FileHandle(forReadingFrom: keyURL)
        defer { try? keyFile.close() }
        guard let keyData = try keyFile.read(upToCount: 33), keyData.count == 32 else {
            throw InputError.signingKey
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let output = URL(fileURLWithPath: arguments[4], isDirectory: true)
        let installers = try arguments.dropFirst(5).map {
            try UpdateReleaseManifest.Installer(contentsOf: URL(fileURLWithPath: $0))
        }
        let payload = try UpdateReleaseManifest.makePayload(tag: tag, commit: commit, installers: installers)
        let signature = try key.signature(for: payload)

        let stage = output.deletingLastPathComponent().appendingPathComponent(".alcove-signing-\(UUID())", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: stage) }
        try payload.write(to: stage.appendingPathComponent(UpdateReleaseManifest.payloadFilename))
        try signature.write(to: stage.appendingPathComponent(UpdateReleaseManifest.signatureFilename))
        try files.moveItem(at: stage, to: output)
        print("Signed \(tag) for \(installers.count) installer(s).")
    }
}
