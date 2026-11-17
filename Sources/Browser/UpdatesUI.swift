import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

struct UpdatesPanel: View {
    @ObservedObject var controller: UpdateController
    @Binding var channel: UpdateChannel
    var availableHeight: Double = 620
    var canModifyChannel = true
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Alcove Updates").font(.title2.bold())
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("Installed: \(controller.installedTag)").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Picker("Release channel", selection: $channel) {
                    ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
                }.frame(width: 250).disabled(controller.checking || !canModifyChannel)
                Spacer()
                if controller.checking { ProgressView().controlSize(.small) }
                Button(controller.checking ? "Checking…" : "Check Now") {
                    Task { await controller.check(channel: channel) }
                }.disabled(controller.checking)
            }
            Text(channel == .preview ? "Preview includes early builds and stable releases. Early builds may have unfinished features." : "Stable includes releases marked stable. No stable release may be available yet.")
                .font(.caption).foregroundStyle(.secondary)
            if !canModifyChannel { Text("Unlock local data to change the saved release channel.").font(.caption).foregroundStyle(.secondary) }
            Divider()
            if controller.checkedChannel == channel {
                if let error = controller.error { Text(error).foregroundStyle(.orange) }
                if let offer = controller.offer {
                    offerView(offer)
                } else if controller.result == .upToDate {
                    Text("No newer compatible release was found for this channel.")
                    Spacer()
                } else {
                    Text(controller.checking ? "Reading public GitHub release information…" : "Check for an update when you’re ready.").foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Text("Check this channel to see available releases.").foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            Text("Update checks contact GitHub without sending browsing history. Download and install updates manually.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("All Releases on GitHub", destination: controller.releasePage)
                Spacer()
                if let date = controller.lastChecked {
                    Text("Last successful check \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(24).frame(width: 650, height: min(620, max(440, availableHeight)))
    }

    private func offerView(_ offer: UpdateOffer) -> some View {
        let authentication = controller.authenticatedUpdate
        let asset = controller.installerAsset ?? offer.asset
        return VStack(alignment: .leading, spacing: 12) {
            Text("Available: \(offer.tag)").font(.headline)
            if availableHeight >= 550 {
                ScrollView {
                    Text(offer.notes.isEmpty ? "No release notes were provided." : offer.notes)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
            }
            Text("This ad hoc–signed preview may be blocked by macOS Gatekeeper.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let digest = asset.sha256 {
                DisclosureGroup(authentication == nil ? "Published SHA-256 checksum" : "Signed installer SHA-256 checksum") {
                    Text(digest).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text(authentication == nil
                         ? "Verify your download against this checksum to check for changed bytes."
                         : "Alcove verified the release manifest’s signature. Verify the downloaded installer against its signed checksum.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 9) {
                    Button("Verify Download…") { chooseInstaller(for: asset) }
                        .disabled(controller.installerReview?.outcome == .verifying)
                    if let review = controller.installerReview {
                        installerStatus(review, isAuthenticated: authentication != nil)
                    }
                }
            } else {
                Text("GitHub did not publish a SHA-256 digest for this asset. Check the release’s SHA256SUMS.txt before opening it.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Link("Download \(asset.filename.hasSuffix(".dmg") ? "DMG" : "ZIP")…", destination: asset.downloadURL)
                Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Release Notes on GitHub", destination: offer.releaseURL)
            }
        }
    }

    private func chooseInstaller(for asset: UpdateAsset) {
        let panel = NSOpenPanel()
        let fileExtension = (asset.filename as NSString).pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Verify"
        panel.message = "Choose the downloaded Alcove installer."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await controller.verifyInstaller(at: url, for: asset) }
        }
    }

    @ViewBuilder private func installerStatus(_ review: UpdateInstallerReview, isAuthenticated: Bool) -> some View {
        if review.outcome == .verifying {
            ProgressView().controlSize(.small).accessibilityLabel("Verifying installer")
        } else {
            let message: String = switch review.outcome {
            case .matches:
                isAuthenticated ? "Matches the signed release." : "Matches the published checksum."
            case .sizeMismatch: "File size differs from the release."
            case .checksumMismatch: "File checksum differs from the release."
            case .unreadable: "Couldn’t verify this file. Choose a readable installer."
            case .verifying: ""
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(review.outcome == .matches ? Color.secondary : Color.orange)
                .help(review.filename)
        }
    }
}
