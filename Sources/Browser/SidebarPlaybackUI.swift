import SwiftUI

struct SidebarPlaybackButton: View {
    @ObservedObject var store: BrowserStore
    @State private var visible = false

    var body: some View {
        Button { visible.toggle() } label: {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0.65)
        .help("Playing Tabs")
        .accessibilityLabel("Playing Tabs")
        .popover(isPresented: $visible, arrowEdge: .bottom) {
            SidebarPlaybackPopover(store: store) { visible = false }
                .id(store.activeProfileID)
        }
    }
}

private struct SidebarPlaybackPopover: View {
    @ObservedObject var store: BrowserStore
    let dismiss: () -> Void
    @State private var entries: [SidebarPlaybackTab] = []
    @State private var hasSample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playing Tabs").font(.headline).accessibilityAddTraits(.isHeader)
            if !hasSample {
                ProgressView().controlSize(.small).accessibilityLabel("Checking playback")
            } else if entries.isEmpty {
                Text("No audio or video playing").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                Text(entry.title).lineLimit(1).help(entry.title)
                                Spacer(minLength: 0)
                                Button("Pause") {
                                    _ = store.pausePlaybackTab(entry)
                                    entries.removeAll { $0.id == entry.id }
                                }.accessibilityLabel("Pause \(entry.title)")
                                Button("Show Tab") {
                                    if store.showPlaybackTab(entry) { dismiss() }
                                    else { entries.removeAll { $0.id == entry.id } }
                                }.accessibilityLabel("Show Tab \(entry.title)")
                            }.frame(height: 28)
                        }
                    }
                }.frame(height: CGFloat(min(entries.count, 5) * 32 - 4))
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .task {
            while !Task.isCancelled {
                let current = await store.playingSidebarTabs()
                guard !Task.isCancelled else { return }
                if entries != current { entries = current }
                hasSample = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
