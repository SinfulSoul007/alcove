import SwiftUI
import BrowserCore

struct WebsiteProtectionSettings: View {
    @ObservedObject var service: WebsiteProtectionService
    var showUpdates: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            GroupBox("Website protection") {
                VStack(alignment: .leading, spacing: 10) {
                    switch service.state {
                    case .loading:
                        Label("Loading phishing protection…", systemImage: "shield.lefthalf.filled")
                            .fontWeight(.medium)
                        Text("The local phishing list is being checked. Pages wait for this check before opening.")
                    case .ready(let catalog):
                        let stale = catalog.isStale(at: timeline.date)
                        Label(stale ? "Phishing list needs an update" : "Local phishing protection", systemImage: stale ? "shield.lefthalf.filled" : "checkmark.shield")
                            .fontWeight(.medium)
                            .foregroundStyle(stale ? Color.orange : Color.primary)
                        Text("Checks addresses against \(catalog.metadata.provider)’s phishing list on this Mac.")
                        Text("List updated \(catalog.metadata.sourceUpdatedAt, format: .dateTime.year().month(.wide).day()).")
                            .foregroundStyle(.secondary)
                        if stale {
                            Text("This list is more than 30 days old. List updates are included with Alcove updates.")
                                .foregroundStyle(.orange)
                        }
                    case .unavailable(let failure):
                        Label("Phishing protection unavailable", systemImage: "exclamationmark.shield")
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                        Text(failure.message + " Alcove asks before opening each unchecked address.")
                    }
                    Text("This local check doesn’t send browsing addresses to a lookup service. An unlisted address can still be harmful.")
                        .foregroundStyle(.secondary)
                    Button("Check for Updates…", action: showUpdates)
                        .accessibilityIdentifier("website-protection-updates")
                }
                .font(.system(size: 12))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
