import SwiftUI
import BrowserCore

struct UpdatesPanel: View {
    @ObservedObject var controller: UpdateController
    @Binding var channel: UpdateChannel
    var availableHeight: Double = 620
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
                }.frame(width: 250).disabled(controller.checking)
                Spacer()
                if controller.checking { ProgressView().controlSize(.small) }
                Button(controller.checking ? "Checking…" : "Check Now") {
                    Task { await controller.check(channel: channel) }
                }.disabled(controller.checking)
            }
            Text(channel == .preview ? "Preview includes early builds and stable releases. Early builds may have unfinished features." : "Stable includes releases marked stable. No stable release may be available yet.")
                .font(.caption).foregroundStyle(.secondary)
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
            Text("Checks contact GitHub and send no browsing history. Downloads open in your browser. Alcove never installs or launches an update automatically.")
                .font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Available: \(offer.tag)").font(.headline)
            ScrollView {
                Text(offer.notes.isEmpty ? "No release notes were provided." : offer.notes)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            Text("Unsigned preview: ad hoc signed, without Apple Developer ID signing or notarization. macOS may block it. Download only if you choose to test this build; keep system security enabled.")
                .font(.caption).foregroundStyle(.secondary)
            if let digest = offer.asset.sha256 {
                DisclosureGroup("Published SHA-256 checksum") {
                    Text(digest).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text("Compare this with your download’s checksum. A checksum detects changed bytes; it does not establish developer identity.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("GitHub did not publish a SHA-256 digest for this asset. Check the release’s SHA256SUMS.txt before opening it.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Link("Download \(offer.asset.filename.hasSuffix(".dmg") ? "DMG" : "ZIP")…", destination: offer.asset.downloadURL)
                Text(ByteCountFormatter.string(fromByteCount: offer.asset.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("Release Notes on GitHub", destination: offer.releaseURL)
            }
        }
    }
}
