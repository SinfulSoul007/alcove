import SwiftUI
import BrowserCore

struct ProfilesPanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: Double = 620

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profiles").font(.title2.bold())
                    Text(store.isPrivate ? "Private windows use temporary website storage." : "\(store.space.name) uses \(store.activeProfile.name)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { store.profilesVisible = false }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.isPrivate {
                        Text("Manage profiles from a normal window using Alcove → Manage Profiles. This private window’s tabs and website storage stay separate and are not saved.")
                    } else {
                        if !store.savingEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Local data is locked. Unlock it to change profiles or retry a pending operation.").font(.callout)
                                Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text("Spaces using the same profile share website logins, Favorites, bookmarks and history. Different profiles keep these separate. Profiles organize browsing within your macOS account; anyone using the unlocked app can switch between them.").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("New Profile…") { store.requestCreateProfile() }.disabled(!store.canManageProfiles)
                            Spacer()
                            if store.profileDataOperationInProgress { ProgressView().controlSize(.small); Text("Finishing profile operation…").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(store.profiles) { profile in profileRow(profile) }
                        Text("Website storage is managed by WebKit. Clearing a profile keeps its bookmarks and downloaded files. Deleting an unused profile permanently removes its library and website data.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 660, height: min(640, max(360, availableHeight)))
    }

    private func profileRow(_ profile: BrowserProfile) -> some View {
        let count = store.session.spaces.filter { $0.effectiveProfileID == profile.id }.count
        let current = store.activeProfileID == profile.id
        let available = !store.profileUnavailable(profile.id)
        let enabled = store.canManageProfiles && available
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: profile.icon).font(.title2).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(profile.name).font(.headline).lineLimit(2)
                        if profile.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        if current { Label("Current", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint) }
                    }
                    Text("\(count) \(count == 1 ? "Space" : "Spaces")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Rename…") { store.requestRenameProfile(profile.id) }.disabled(!enabled)
            }
            if profile.isPendingDeletion {
                Text("Deletion is unfinished. This profile is paused until its website data and saved entry can be removed.").font(.caption).foregroundStyle(.orange)
                Button("Retry Deletion…", role: .destructive) { store.requestDeleteProfile(profile.id) }.disabled(!store.canManageProfiles || count != 0)
            } else if profile.isPendingClear {
                Text("Website-data clearing is unfinished. Retry to finish clearing it and resume this profile. Links queued after the initial reset are kept.").font(.caption).foregroundStyle(.orange)
                Button("Retry Clear…") { store.requestClearProfileData(profile.id) }.disabled(!store.canManageProfiles)
            } else {
                if !available { Text("This profile is temporarily unavailable. Unlock local data or wait for its operation to finish.").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(current ? "Used by This Space" : "Use for This Space…") { store.requestAssignProfile(profile.id, to: store.space.id) }.disabled(!enabled || current || store.profileUnavailable(store.activeProfileID))
                    Button("New Space…") { store.requestNewSpace(profileID: profile.id) }.disabled(!enabled)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Clear Website Data…", role: .destructive) { store.requestClearProfileData(profile.id) }.disabled(!enabled)
                        if !profile.isDefault {
                            Button("Delete Profile…", role: .destructive) { store.requestDeleteProfile(profile.id) }.disabled(!enabled || count != 0)
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 20) }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Actions for \(profile.name)")
                }.controlSize(.small)
                if !profile.isDefault && count > 0 { Text("Assign its Spaces to another profile before deleting it.").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
